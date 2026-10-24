import Accelerate
import Foundation

/// Kaiser-windowed sinc interpolation table for arbitrary-ratio resampling.
final class SincTable {
    let halfWidth: Int
    let phases: Int
    let taps: Int
    private let storage: FloatBuffer

    /// `ratio` is input rate / output rate. The cutoff sits just below the lower Nyquist frequency.
    init(ratio: Double, zeroCrossings: Int = 16, phases: Int = 256, beta: Double = 8.6) {
        let cutoff = 0.5 * min(1, 1 / ratio) * 0.92 // cycles per input sample
        halfWidth = Int((Double(zeroCrossings) / (2 * cutoff)).rounded(.up))
        self.phases = phases
        taps = 2 * halfWidth
        storage = FloatBuffer((phases + 1) * taps)
        let denominator = besselI0(beta)
        for phase in 0...phases {
            let fraction = Double(phase) / Double(phases)
            var sum = 0.0
            var row = [Double](repeating: 0, count: taps)
            for tap in 0..<taps {
                let tau = Double(tap - halfWidth + 1) - fraction
                let x = 2 * cutoff * tau
                let sinc = abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                let ratio = tau / Double(halfWidth)
                let window = abs(ratio) >= 1 ? 0 : besselI0(beta * (1 - ratio * ratio).squareRoot()) / denominator
                row[tap] = 2 * cutoff * sinc * window
                sum += row[tap]
            }
            // Unity gain at DC for every phase.
            for tap in 0..<taps { storage[phase * taps + tap] = Float(row[tap] / sum) }
        }
    }

    func row(_ phase: Int) -> UnsafeMutablePointer<Float> { storage.pointer + phase * taps }

    private func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        for k in 1..<50 {
            term *= (x / (2 * Double(k))) * (x / (2 * Double(k)))
            sum += term
            if term < sum * 1e-12 { break }
        }
        return sum
    }
}

/// Produces a track as mono samples on the session timeline at a fixed output rate, correcting
/// the device clock's drift with the track's `TrackClock`. Times before the track starts or after
/// it ends read as silence. Output sample `n` is the track at session time `startTime + n / outputRate`.
public final class SessionTimelineReader {
    public let outputRate: Double
    public let startTime: TimeInterval
    private let source: PCMSampleSource
    private let clock: TrackClock
    private let weights: [Float]
    private let table: SincTable
    private var produced: Int64 = 0
    // Mono window over the source: storage[i] is source frame windowStart + i.
    private var storage: UnsafeMutablePointer<Float>
    private var capacity: Int
    private var stored = 0
    private var windowStart: Int64 = 0
    private var sourcePosition: Int64 = 0
    private let chunk = 8_192
    private let channelScratch: [FloatBuffer]
    private let mixed: FloatBuffer
    private let taps: FloatBuffer

    /// `channelWeights` mixes source channels to mono; nil averages them all.
    public init(source: PCMSampleSource, clock: TrackClock, outputRate: Double, startTime: TimeInterval,
                channelWeights: [Float]? = nil) throws {
        self.source = source
        self.clock = clock
        self.outputRate = outputRate
        self.startTime = startTime
        let count = max(1, source.channelCount)
        weights = channelWeights ?? [Float](repeating: 1 / Float(count), count: count)
        table = SincTable(ratio: source.sampleRate / outputRate)
        channelScratch = (0..<count).map { _ in FloatBuffer(8_192) }
        mixed = FloatBuffer(8_192)
        taps = FloatBuffer(table.taps)
        capacity = 8 * 8_192
        storage = .allocate(capacity: capacity)
        let first = Int64(clock.frame(atTime: startTime).rounded(.down)) - Int64(table.halfWidth) - 1
        windowStart = max(0, min(first, source.frameCount))
        sourcePosition = windowStart
        try source.seek(toFrame: windowStart)
    }

    deinit { storage.deallocate() }

    /// Fills `count` samples.
    public func read(_ count: Int, into output: UnsafeMutablePointer<Float>) throws {
        let H = Int64(table.halfWidth), T = table.taps, phases = Double(table.phases)
        let total = source.frameCount
        var index = 0
        while index < count {
            // Positions advance linearly within one clock piece; handle a run of them at once.
            let time = startTime + Double(produced + Int64(index)) / outputRate
            let piece = clock.pieces.last { $0.startTime <= time } ?? clock.pieces[0]
            var run = min(count - index, 4_096)
            if let next = clock.pieces.first(where: { $0.startTime > time }) {
                run = max(1, min(run, Int(((next.startTime - time) * outputRate).rounded(.up))))
            }
            let step = piece.framesPerSecond / outputRate
            let first = Double(piece.startFrame) + (time - piece.startTime) * piece.framesPerSecond
            let lastHigh = Int64((first + step * Double(run - 1)).rounded(.down)) + H
            if lastHigh >= 0 && first - Double(H) < Double(total) {
                try ensureWindow(through: min(lastHigh, total - 1))
                dropBefore(max(0, Int64(first.rounded(.down)) - H + 1))
            }
            for offset in 0..<run {
                let position = first + step * Double(offset)
                let base = Int64(position.rounded(.down))
                let low = base - H + 1, high = base + H
                guard high >= 0, low < total else { output[index + offset] = 0; continue }
                let phase = (position - Double(base)) * phases
                let row = min(table.phases - 1, Int(phase))
                let fraction = Float(phase - Double(row))
                let pointer: UnsafePointer<Float>
                if low >= windowStart && high < windowStart + Int64(stored) {
                    pointer = UnsafePointer(storage + Int(low - windowStart))
                } else {
                    // Edges of the recording: frames outside it read as silence.
                    for tap in 0..<T {
                        let frame = low + Int64(tap), offset = frame - windowStart
                        taps[tap] = frame >= 0 && frame < total && offset >= 0 && offset < Int64(stored) ? storage[Int(offset)] : 0
                    }
                    pointer = UnsafePointer(taps.pointer)
                }
                let a = SpectralMath.dot(pointer, table.row(row), count: T)
                let b = SpectralMath.dot(pointer, table.row(row + 1), count: T)
                output[index + offset] = a + (b - a) * fraction
            }
            index += run
        }
        produced += Int64(count)
    }

    public func read(_ count: Int) throws -> [Float] {
        var result = [Float](repeating: 0, count: count)
        try result.withUnsafeMutableBufferPointer { try read(count, into: $0.baseAddress!) }
        return result
    }

    private func ensureWindow(through frame: Int64) throws {
        while windowStart + Int64(stored) <= frame && sourcePosition < source.frameCount {
            let read = try source.read(frames: chunk, into: channelScratch.map(\.pointer))
            guard read > 0 else { break }
            mixed.zero()
            for (channel, scratch) in channelScratch.enumerated() where weights[channel] != 0 {
                var weight = weights[channel]
                vDSP_vsma(scratch.pointer, 1, &weight, mixed.pointer, 1, mixed.pointer, 1, vDSP_Length(read))
            }
            if stored + read > capacity {
                let grown = max(capacity * 2, stored + read)
                let replacement = UnsafeMutablePointer<Float>.allocate(capacity: grown)
                replacement.update(from: storage, count: stored)
                storage.deallocate()
                storage = replacement
                capacity = grown
            }
            (storage + stored).update(from: mixed.pointer, count: read)
            stored += read
            sourcePosition += Int64(read)
        }
    }

    private func dropBefore(_ frame: Int64) {
        let excess = Int(frame - windowStart)
        // Compact occasionally rather than per sample.
        guard excess > 4 * chunk, excess <= stored else { return }
        memmove(storage, storage + excess, (stored - excess) * MemoryLayout<Float>.size)
        stored -= excess
        windowStart += Int64(excess)
    }
}

/// Picks microphone channels worth mixing: those within 30 dB of the loudest, so a silent extra
/// input on a multichannel interface does not dilute the voice.
public enum ChannelSelection {
    public static func weights(for source: PCMSampleSource, analysisFrames: Int = 960_000) throws -> [Float] {
        let channels = source.channelCount
        guard channels > 1 else { return [1] }
        try source.seek(toFrame: 0)
        let scratch = (0..<channels).map { _ in FloatBuffer(16_384) }
        var energies = [Double](repeating: 0, count: channels)
        var remaining = analysisFrames
        while remaining > 0 {
            let read = try source.read(frames: min(16_384, remaining), into: scratch.map(\.pointer))
            guard read > 0 else { break }
            for channel in 0..<channels { energies[channel] += Double(SpectralMath.energy(scratch[channel].pointer, count: read)) }
            remaining -= read
        }
        try source.seek(toFrame: 0)
        let loudest = energies.max() ?? 0
        guard loudest > 0 else { return [Float](repeating: 1 / Float(channels), count: channels) }
        let selected = energies.map { $0 >= loudest * 1e-3 }
        let count = Float(selected.filter { $0 }.count)
        return selected.map { $0 ? 1 / count : 0 }
    }
}
