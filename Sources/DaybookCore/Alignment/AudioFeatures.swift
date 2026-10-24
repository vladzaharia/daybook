import Accelerate
import AVFoundation
import Foundation

public enum AudioAlignmentError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case empty(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Daybook couldn’t read the audio in \(name)."
        case .empty(let name): return "\(name) contains no audio."
        }
    }
}

/// Low-rate acoustic features that survive codecs, gain changes, room reverb, and different
/// microphones. One frame covers 10 ms of the recording's own clock.
///
/// - `onset`: spectral flux of gated log-band energies (rises only), square-root compressed and
///   centered with a one-second moving average. Log bands make it independent of gain; the gate
///   keeps background noise from producing onsets; rises survive reverb tails.
/// - `level`: frame level in dB (uncalibrated), used for activity and signal-to-noise estimates.
public struct AudioFeatures: Equatable, Sendable {
    /// Bumped whenever the extraction changes so cached features are recomputed.
    public static let currentVersion = 1
    public static let frameRate: Double = 100
    public var version: Int
    public var sourceSampleRate: Double
    /// Seconds of audio in the file's own clock.
    public var duration: TimeInterval
    public var onset: [Float]
    public var level: [Float]
    public var frameCount: Int { onset.count }

    public init(version: Int = AudioFeatures.currentVersion, sourceSampleRate: Double, duration: TimeInterval,
                onset: [Float], level: [Float]) {
        self.version = version; self.sourceSampleRate = sourceSampleRate; self.duration = duration
        self.onset = onset; self.level = level
    }

    /// Reads a file in bounded chunks: decode, downmix, resample to 8 kHz, and keep only frame-rate
    /// features. Memory stays proportional to the feature arrays (about 800 bytes per second).
    public static func extract(from url: URL) throws -> AudioFeatures {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw AudioAlignmentError.unreadable(url.lastPathComponent) }
        guard file.length > 0 else { throw AudioAlignmentError.empty(url.lastPathComponent) }
        let input = file.processingFormat
        let sampleRate = input.sampleRate
        let channels = Int(input.channelCount)
        guard sampleRate > 0, channels > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: FeatureAccumulator.analysisRate,
                                         channels: 1, interleaved: false) else {
            throw AudioAlignmentError.unreadable(url.lastPathComponent)
        }
        let chunkFrames: AVAudioFrameCount = 32_768
        guard let chunk = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunkFrames),
              let monoChunk = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunkFrames) else {
            throw AudioAlignmentError.unreadable(url.lastPathComponent)
        }
        let accumulator = FeatureAccumulator()
        var readError: Error?
        var finished = false
        /// Reads the next chunk and averages its channels into `monoChunk`. False at the end.
        func readMono() -> Bool {
            guard !finished, file.framePosition < file.length else { finished = true; return false }
            let frames = AVAudioFrameCount(min(Int64(chunkFrames), file.length - file.framePosition))
            do { try file.read(into: chunk, frameCount: frames) } catch { readError = error; finished = true; return false }
            let count = Int(chunk.frameLength)
            guard count > 0, let source = chunk.floatChannelData, let destination = monoChunk.floatChannelData else {
                finished = true; return false
            }
            if channels == 1 {
                destination[0].update(from: source[0], count: count)
            } else {
                vDSP_mmov(source[0], destination[0], vDSP_Length(count), 1, vDSP_Length(count), vDSP_Length(count))
                for channel in 1..<channels { vDSP_vadd(destination[0], 1, source[channel], 1, destination[0], 1, vDSP_Length(count)) }
                var scale = 1 / Float(channels)
                vDSP_vsmul(destination[0], 1, &scale, destination[0], 1, vDSP_Length(count))
            }
            monoChunk.frameLength = AVAudioFrameCount(count)
            return true
        }

        if sampleRate == FeatureAccumulator.analysisRate {
            while readMono(), let data = monoChunk.floatChannelData {
                accumulator.append(UnsafeBufferPointer(start: data[0], count: Int(monoChunk.frameLength)))
            }
        } else {
            guard let converter = AVAudioConverter(from: mono, to: target),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else {
                throw AudioAlignmentError.unreadable(url.lastPathComponent)
            }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            while true {
                var conversionError: NSError?
                output.frameLength = 0
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    if readMono() { inputStatus.pointee = .haveData; return monoChunk }
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let data = output.floatChannelData, output.frameLength > 0 {
                    accumulator.append(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
                }
                if status == .error { throw AudioAlignmentError.unreadable(url.lastPathComponent) }
                if status == .endOfStream || (status == .inputRanDry && finished) { break }
            }
        }
        if readError != nil { throw AudioAlignmentError.unreadable(url.lastPathComponent) }
        let result = accumulator.finish()
        guard !result.onset.isEmpty else { throw AudioAlignmentError.empty(url.lastPathComponent) }
        return AudioFeatures(sourceSampleRate: sampleRate, duration: Double(file.length) / sampleRate,
                             onset: result.onset, level: result.level)
    }

    // MARK: Derived measures

    /// The level below which a frame counts as background: the 10th percentile of frame levels.
    public var noiseFloor: Float {
        guard !level.isEmpty else { return -100 }
        let stride = Swift.max(1, level.count / 20_000)
        var sample = Swift.stride(from: 0, to: level.count, by: stride).map { level[$0] }
        sample.sort()
        return sample[sample.count / 10]
    }

    /// Prefix counts of frames at least `margin` dB above the noise floor, for fast window activity.
    func activityPrefix(margin: Float = 12) -> [Int32] {
        let threshold = noiseFloor + margin
        var prefix = [Int32](repeating: 0, count: level.count + 1)
        var running: Int32 = 0
        level.withUnsafeBufferPointer { values in
            for index in 0..<values.count {
                if values[index] >= threshold { running += 1 }
                prefix[index + 1] = running
            }
        }
        return prefix
    }

    // MARK: Binary form for the on-disk cache

    private static let magic: UInt32 = 0x4442_4146 // "DBAF"
    func serialized() -> Data {
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(Self.magic); append(UInt32(version)); append(sourceSampleRate); append(duration); append(UInt64(onset.count))
        onset.withUnsafeBytes { data.append(contentsOf: $0) }
        level.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    init?(serialized data: Data) {
        let header = 4 + 4 + 8 + 8 + 8
        guard data.count >= header else { return nil }
        var cursor = data.startIndex
        func read<T>(_: T.Type) -> T {
            let size = MemoryLayout<T>.size
            defer { cursor += size }
            return data[cursor..<(cursor + size)].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }
        guard read(UInt32.self) == Self.magic else { return nil }
        let version = Int(read(UInt32.self))
        let rate = read(Double.self), duration = read(Double.self)
        let count = Int(read(UInt64.self))
        guard version == Self.currentVersion, count >= 0, data.count == header + count * 8, rate.isFinite, duration.isFinite else { return nil }
        func floats() -> [Float] {
            let bytes = count * 4
            defer { cursor += bytes }
            return data[cursor..<(cursor + bytes)].withUnsafeBytes { raw in
                (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
        }
        let onset = floats(), level = floats()
        self.init(version: version, sourceSampleRate: rate, duration: duration, onset: onset, level: level)
    }
}

/// Turns 8 kHz mono samples into frame features in batches, using vDSP for every per-sample step.
final class FeatureAccumulator {
    static let analysisRate = 8_000.0
    static let frameLength = 256
    static let hop = 80
    static let bands = 24
    private static let batchFrames = 512
    private static let log2n: vDSP_Length = 8
    private static let gateDB: Float = 6
    private static let floorRisePerBatch: Float = 3
    /// A 20 ms analysis window inside the 256-point FFT: shorter windows keep reverberant onsets
    /// sharp (a 32 ms window biased a reverberant room recording about 13 ms late, 20 ms about 8 ms).
    private static let windowLength = 160

    private let setup: FFTSetup
    private let window: [Float]
    /// Bin-major filterbank (128 bins × bands) for one matrix multiply per batch.
    private let filterbank: [Float]
    private var pending: [Float] = []
    private var pendingStart = 0
    private var bandFloor: [Float]?
    private var previousRows: [Float]?
    private var flux: [Float] = []
    private var levels: [Float] = []

    init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.windowLength, isHalfWindow: false)
            + [Float](repeating: 0, count: Self.frameLength - Self.windowLength)
        // Triangular mel bands from 100 Hz to 3.8 kHz over the 128 non-Nyquist bins.
        func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
        let low = mel(100), high = mel(3_800)
        let edges = (0...(Self.bands + 1)).map { hz(low + (high - low) * Double($0) / Double(Self.bands + 1)) }
        let binHz = Self.analysisRate / Double(Self.frameLength)
        var weights = [Float](repeating: 0, count: 128 * Self.bands)
        for band in 0..<Self.bands {
            let (left, center, right) = (edges[band], edges[band + 1], edges[band + 2])
            var total: Float = 0
            for bin in 1..<128 {
                let frequency = Double(bin) * binHz
                let value: Double
                if frequency <= left || frequency >= right { value = 0 }
                else if frequency <= center { value = (frequency - left) / max(1e-9, center - left) }
                else { value = (right - frequency) / max(1e-9, right - center) }
                weights[bin * Self.bands + band] = Float(value); total += Float(value)
            }
            if total == 0 { // Narrow low bands: use the nearest bin so every band carries energy.
                let bin = min(127, max(1, Int((center / binHz).rounded())))
                weights[bin * Self.bands + band] = 1
            }
        }
        filterbank = weights
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0 else { return }
        pending.append(contentsOf: samples)
        processAvailable()
    }

    func finish() -> (onset: [Float], level: [Float]) {
        processAvailable(final: true)
        guard !flux.isEmpty else { return ([], []) }
        // Square-root compression keeps loud onsets from dominating, then a one-second moving
        // average is removed so slow loudness changes don't correlate.
        var onset = [Float](repeating: 0, count: flux.count)
        var count = Int32(flux.count)
        vvsqrtf(&onset, flux, &count)
        let radius = Int(AudioFeatures.frameRate / 2)
        var prefix = [Double](repeating: 0, count: onset.count + 1)
        for index in 0..<onset.count { prefix[index + 1] = prefix[index] + Double(onset[index]) }
        var centered = [Float](repeating: 0, count: onset.count)
        for index in 0..<onset.count {
            let lo = max(0, index - radius), hi = min(onset.count, index + radius + 1)
            centered[index] = onset[index] - Float((prefix[hi] - prefix[lo]) / Double(hi - lo))
        }
        return (centered, levels)
    }

    private func processAvailable(final: Bool = false) {
        while true {
            let available = pending.count - pendingStart
            guard available >= Self.frameLength else { break }
            let possible = (available - Self.frameLength) / Self.hop + 1
            guard possible >= Self.batchFrames || (final && possible > 0) else { break }
            let frames = min(possible, Self.batchFrames)
            processBatch(frames: frames)
            pendingStart += frames * Self.hop
        }
        if pendingStart > 1 << 16 {
            pending.removeFirst(pendingStart)
            pendingStart = 0
        }
    }

    private func processBatch(frames: Int) {
        let n = Self.frameLength, half = n / 2, bands = Self.bands
        var windowed = [Float](repeating: 0, count: frames * n)
        var real = [Float](repeating: 0, count: frames * half)
        var imaginary = [Float](repeating: 0, count: frames * half)
        var power = [Float](repeating: 0, count: frames * half)
        pending.withUnsafeBufferPointer { samples in
            windowed.withUnsafeMutableBufferPointer { output in
                for frame in 0..<frames {
                    vDSP_vmul(samples.baseAddress! + pendingStart + frame * Self.hop, 1, window, 1, output.baseAddress! + frame * n, 1, vDSP_Length(n))
                }
            }
        }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let complex = raw.bindMemory(to: DSPComplex.self)
                    for frame in 0..<frames {
                        var row = DSPSplitComplex(realp: split.realp + frame * half, imagp: split.imagp + frame * half)
                        vDSP_ctoz(complex.baseAddress! + frame * half, 2, &row, 1, vDSP_Length(half))
                    }
                }
                vDSP_fftm_zrip(setup, &split, 1, vDSP_Stride(half), Self.log2n, vDSP_Length(frames), FFTDirection(kFFTDirection_Forward))
                // Bin 0 holds DC and Nyquist packed together; the filterbank ignores it.
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(frames * half))
            }
        }
        var energy = [Float](repeating: 0, count: frames * bands)
        vDSP_mmul(power, 1, filterbank, 1, &energy, 1, vDSP_Length(frames), vDSP_Length(bands), vDSP_Length(half))
        var levelRows = [Float](repeating: 0, count: frames)
        let ones = [Float](repeating: 1, count: half)
        vDSP_mmul(power, 1, ones, 1, &levelRows, 1, vDSP_Length(frames), 1, vDSP_Length(half))
        toDecibels(&energy)
        toDecibels(&levelRows)
        levels.append(contentsOf: levelRows)

        // Track each band's background level (a low percentile that may rise slowly) and lift
        // anything below floor + gate to that gate, so noise can't create onsets.
        var floors = bandFloor ?? [Float](repeating: .infinity, count: bands)
        var column = [Float](repeating: 0, count: frames)
        for band in 0..<bands {
            energy.withUnsafeBufferPointer { values in
                vDSP_mmov(values.baseAddress! + band, &column, 1, vDSP_Length(frames), vDSP_Length(bands), 1)
            }
            vDSP_vsort(&column, vDSP_Length(frames), 1)
            let percentile = column[frames / 10]
            floors[band] = bandFloor == nil ? percentile : min(floors[band] + Self.floorRisePerBatch, percentile)
            var gate = floors[band] + Self.gateDB
            energy.withUnsafeMutableBufferPointer { values in
                vDSP_vthr(values.baseAddress! + band, vDSP_Stride(bands), &gate, values.baseAddress! + band, vDSP_Stride(bands), vDSP_Length(frames))
            }
        }
        bandFloor = floors

        // Spectral flux with a two-frame lag: positive band rises summed across bands.
        let previous = previousRows ?? Array(energy[0..<bands]) + Array(energy[0..<bands])
        let history = previous + energy
        var rises = [Float](repeating: 0, count: frames * bands)
        vDSP_vsub(history, 1, Array(history[(2 * bands)...]), 1, &rises, 1, vDSP_Length(frames * bands))
        var zero: Float = 0
        vDSP_vthres(rises, 1, &zero, &rises, 1, vDSP_Length(frames * bands))
        var frameFlux = [Float](repeating: 0, count: frames)
        let bandOnes = [Float](repeating: 1 / Float(bands), count: bands)
        vDSP_mmul(rises, 1, bandOnes, 1, &frameFlux, 1, vDSP_Length(frames), 1, vDSP_Length(bands))
        flux.append(contentsOf: frameFlux)
        previousRows = Array(history[(history.count - 2 * bands)...])
    }

    private func toDecibels(_ values: inout [Float]) {
        var floor: Float = 1e-10
        vDSP_vsadd(values, 1, &floor, &values, 1, vDSP_Length(values.count))
        var count = Int32(values.count)
        vvlog10f(&values, values, &count)
        var ten: Float = 10
        vDSP_vsmul(values, 1, &ten, &values, 1, vDSP_Length(values.count))
    }
}
