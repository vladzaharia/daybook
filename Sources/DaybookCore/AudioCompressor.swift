import AudioToolbox
import AVFoundation
import Foundation

/// Makes and checks the lossy copy that replaces an older recording (docs/architecture.md, "Compressing older
/// recordings"). AAC-LC in M4A, through AVFoundation, which every reader of a recording already opens: measured on this
/// encoder, a copy keeps the source's exact frame count, seeks exactly, and lines up with the source with no lag in the
/// alignment features. A copy is used only once `verify` passes; anything else keeps the original.
public enum AudioCompressor {
    /// How one recording is encoded.
    public struct Plan: Equatable, Sendable {
        public var sampleRate: Double
        /// Channels written: 1, or 2 for a stereo recording whose channels differ.
        public var channels: Int
        public var bitRate: Int
        /// The source's channels are averaged into one.
        public var downmixes: Bool
        /// `TrackEncoding.method`.
        public var method: String { "aac-lc-\(bitRate / 1_000)" + (channels == 2 ? "-stereo" : "") }

        public init(sampleRate: Double, channels: Int, bitRate: Int, downmixes: Bool) {
            self.sampleRate = sampleRate; self.channels = channels; self.bitRate = bitRate; self.downmixes = downmixes
        }
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case unreadable, notLossless, unsupportedLayout(String)
        case encodingFailed(String)
        case wrongFormat(String), frameCount(source: Int64, copy: Int64), quiet(Double), envelope(Double), lag(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The recording couldn’t be read."
            case .notLossless: return "The recording is already compressed."
            case .unsupportedLayout(let layout): return "The recording’s layout isn’t compressed (\(layout))."
            case .encodingFailed(let reason): return "Encoding failed: \(reason)"
            case .wrongFormat(let format): return "The copy isn’t the expected format (\(format))."
            case .frameCount(let source, let copy): return "The copy has \(copy) frames; the recording has \(source)."
            case .quiet(let share): return "The copy is quiet where the recording isn’t (\(Int(share * 1_000)) per mille of windows)."
            case .envelope(let correlation): return "The copy’s loudness doesn’t follow the recording’s (correlation \(correlation))."
            case .lag(let frames): return "The copy is offset from the recording by \(frames) feature frames."
            }
        }
    }

    // MARK: Reading the source

    /// How a file is stored: lossless (PCM, Apple Lossless, FLAC), lossy, or something the encoder doesn't take.
    public static func storage(of url: URL) -> RecordingCompressionEligibility.Storage {
        guard let file = try? AVAudioFile(forReading: url) else { return .unsupported }
        switch file.fileFormat.streamDescription.pointee.mFormatID {
        case kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC:
            return (try? plan(for: url)) != nil ? .lossless : .unsupported
        default:
            return .lossy
        }
    }

    /// The source's format in words, for `TrackEncoding.sourceFormat`.
    public static func describe(_ url: URL) -> String {
        guard let file = try? AVAudioFile(forReading: url) else { return "unreadable" }
        let format = file.fileFormat.streamDescription.pointee
        let kind: String
        switch format.mFormatID {
        case kAudioFormatLinearPCM:
            let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            kind = "Linear PCM, \(format.mBitsPerChannel)-bit \(float ? "float" : "integer")"
        case kAudioFormatAppleLossless: kind = "Apple Lossless"
        case kAudioFormatFLAC: kind = "FLAC"
        default: kind = "format \(format.mFormatID)"
        }
        let channels = Int(format.mChannelsPerFrame)
        return "\(kind), \(Int(format.mSampleRate)) Hz, \(channels) channel\(channels == 1 ? "" : "s")"
    }

    /// Two channels this alike (Pearson correlation over the whole file, and within this many dB of each other) are
    /// one sound written twice (an app's mono call mixed down to stereo) and are kept as one. Anything less keeps both.
    public static let sameChannelsCorrelation = 0.98
    public static let sameChannelsLevelDifference = 1.0

    /// The encoding for a recording: its own sample rate when it's 44.1 or 48 kHz (64 kbit/s), or 16 kHz (32 kbit/s);
    /// mono, or stereo at 96 kbit/s (64 at 16 kHz) when its two channels differ materially. Other rates and more than two
    /// channels aren't compressed. Reads a stereo file through once to compare its channels.
    public static func plan(for url: URL, isCancelled: () -> Bool = { false }) throws -> Plan {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { throw Refusal.unreadable }
        let format = file.processingFormat
        let rate = format.sampleRate, channels = Int(format.channelCount)
        guard file.length > 0 else { throw Refusal.unreadable }
        let wide = rate == 44_100 || rate == 48_000
        guard wide || rate == 16_000 else { throw Refusal.unsupportedLayout("\(Int(rate)) Hz") }
        guard channels == 1 || channels == 2 else { throw Refusal.unsupportedLayout("\(channels) channels") }
        if channels == 1 { return Plan(sampleRate: rate, channels: 1, bitRate: wide ? 64_000 : 32_000, downmixes: false) }
        let similarity = try channelSimilarity(file, isCancelled: isCancelled)
        if similarity.correlation >= sameChannelsCorrelation && abs(similarity.levelDifference) <= sameChannelsLevelDifference {
            return Plan(sampleRate: rate, channels: 1, bitRate: wide ? 64_000 : 32_000, downmixes: true)
        }
        return Plan(sampleRate: rate, channels: 2, bitRate: wide ? 96_000 : 64_000, downmixes: false)
    }

    /// How alike a stereo file's channels are: their correlation (1 when silent in both) and level difference in dB.
    public static func channelSimilarity(of url: URL) throws -> (correlation: Double, levelDifference: Double) {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.processingFormat.channelCount == 2 else { throw Refusal.unreadable }
        return try channelSimilarity(file, isCancelled: { false })
    }

    private static func channelSimilarity(_ file: AVAudioFile, isCancelled: () -> Bool) throws -> (correlation: Double, levelDifference: Double) {
        var sumL = 0.0, sumR = 0.0, sumLL = 0.0, sumRR = 0.0, sumLR = 0.0, count = 0.0
        try readChunks(file, isCancelled: isCancelled) { buffer in
            let frames = Int(buffer.frameLength)
            guard let data = buffer.floatChannelData else { return }
            for index in 0..<frames {
                let l = Double(data[0][index]), r = Double(data[1][index])
                sumL += l; sumR += r; sumLL += l * l; sumRR += r * r; sumLR += l * r
            }
            count += Double(frames)
        }
        file.framePosition = 0
        guard count > 0 else { return (1, 0) }
        let varL = sumLL / count - (sumL / count) * (sumL / count), varR = sumRR / count - (sumR / count) * (sumR / count)
        let level = 10 * log10(max(sumLL / count, 1e-20) / max(sumRR / count, 1e-20))
        // Silence in both is the same sound; silence in one is two different ones.
        if varL < 1e-14 && varR < 1e-14 { return (1, 0) }
        if varL < 1e-14 || varR < 1e-14 { return (0, level) }
        let covariance = sumLR / count - (sumL / count) * (sumR / count)
        return (covariance / (varL * varR).squareRoot(), level)
    }

    // MARK: Encoding

    /// Writes `source` encoded by `plan` to `destination` (a new file), a chunk at a time, then flushes it to storage.
    /// Stops with `CancellationError` once `isCancelled`; the caller deletes what was written.
    public static func encode(_ source: URL, to destination: URL, plan: Plan, isCancelled: () -> Bool = { false }) throws {
        guard let input = try? AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false) else { throw Refusal.unreadable }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: plan.sampleRate,
                                       AVNumberOfChannelsKey: plan.channels, AVEncoderBitRateKey: plan.bitRate]
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: plan.sampleRate, channels: 1, interleaved: false),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunkFrames) else { throw Refusal.encodingFailed("no buffer") }
        do {
            // Closed (and its header written) before it's flushed, at the end of this scope.
            do {
                let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try readChunks(input, isCancelled: isCancelled) { buffer in
                    if plan.downmixes, let data = buffer.floatChannelData, let out = monoBuffer.floatChannelData {
                        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
                        for index in 0..<frames {
                            var sum: Float = 0
                            for channel in 0..<channels { sum += data[channel][index] }
                            out[0][index] = sum / Float(channels)
                        }
                        monoBuffer.frameLength = buffer.frameLength
                        try output.write(from: monoBuffer)
                    } else {
                        try output.write(from: buffer)
                    }
                }
            }
            try DurableFiles.synchronize([destination])
        } catch let error as CancellationError {
            throw error
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw Refusal.encodingFailed(error.localizedDescription)
        }
    }

    /// A verified copy waiting to replace its recording: a hidden file beside it, flushed to storage.
    public struct PreparedCopy: Equatable, Sendable {
        public var url: URL
        public var sha256: String
        public var size: Int64
        public var plan: Plan
        public var sourceFormat: String
        public var sourceSize: Int64
        public var verification: Verification
    }

    /// The source's bytes didn't have the SHA-256 the track names: nothing is encoded from them.
    public struct SourceChanged: Error, Equatable {}

    /// Makes and verifies a copy of `source` in `folder`, off the caller's actor (on a file-work queue), checking first
    /// that its bytes still have `expectedSHA256`. On any failure, or cancellation, nothing is left behind.
    public static func prepareCopy(of source: URL, expectedSHA256: String, in folder: URL) async throws -> PreparedCopy {
        let temporary = folder.appendingPathComponent("\(RecordingCompression.temporaryPrefix)\(UUID().uuidString).m4a")
        do {
            return try await BlockingFileWork.run { isCancelled in
                guard try AudioDigest.sha256(fileURL: source, isCancelled: isCancelled) == expectedSHA256 else { throw SourceChanged() }
                let plan = try Self.plan(for: source, isCancelled: isCancelled)
                try Self.encode(source, to: temporary, plan: plan, isCancelled: isCancelled)
                let verification = try Self.verify(source: source, copy: temporary, plan: plan, isCancelled: isCancelled)
                let digest = try AudioDigest.sha256(fileURL: temporary, isCancelled: isCancelled)
                func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
                return PreparedCopy(url: temporary, sha256: digest, size: size(temporary), plan: plan,
                                    sourceFormat: Self.describe(source), sourceSize: size(source), verification: verification)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: Verifying

    /// What `verify` measured, for the log and tests.
    public struct Verification: Equatable, Sendable {
        public var frames: Int64
        public var envelopeCorrelation: Double?
        /// Share of the source's audible windows where the copy is much quieter.
        public var quietShare: Double
        public var lag: Int?
    }

    /// Short windows (50 ms) whose loudness is compared, and the bars a copy must clear: every window where the recording
    /// is audible (above -50 dBFS) must be within 12 dB of it in the copy, but for one in 200 (AAC smears a hard onset into
    /// the window before it); and the copy's loudness must follow the recording's with a correlation of at least 0.95. AAC
    /// at these rates scores above 0.99 on speech, music, and noise (AudioCompressorTests), so a copy that misses is
    /// damaged: silent, truncated, shifted, or another recording.
    public static let window: TimeInterval = 0.05
    public static let audible = -50.0
    public static let quieterBy = 12.0
    public static let quietAllowance = 0.005
    public static let minimumEnvelopeCorrelation = 0.95
    /// The alignment features' lag is searched this many frames (10 ms each) either way.
    public static let lagSearch = 50

    /// Checks a copy against its recording before it may replace it: it opens as AAC at the planned rate and channels,
    /// has exactly the recording's frame count (as AVAudioFile reports it, priming handled by the decoder), isn't quiet
    /// where the recording isn't, follows its loudness, and lines up with it at lag 0 in the alignment features. A
    /// recording that's silent throughout needs only a copy that's silent too. Throws the first check that fails.
    @discardableResult
    public static func verify(source: URL, copy: URL, plan: Plan, isCancelled: () -> Bool = { false }) throws -> Verification {
        guard let original = try? AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false) else { throw Refusal.unreadable }
        guard let encoded = try? AVAudioFile(forReading: copy, commonFormat: .pcmFormatFloat32, interleaved: false) else {
            throw Refusal.wrongFormat("unreadable")
        }
        let description = encoded.fileFormat.streamDescription.pointee
        guard description.mFormatID == kAudioFormatMPEG4AAC, encoded.fileFormat.sampleRate == plan.sampleRate,
              Int(encoded.fileFormat.channelCount) == plan.channels else {
            throw Refusal.wrongFormat("\(description.mFormatID), \(Int(encoded.fileFormat.sampleRate)) Hz, \(encoded.fileFormat.channelCount) ch")
        }
        guard encoded.length == original.length else { throw Refusal.frameCount(source: original.length, copy: encoded.length) }
        let (sourceLevels, copyLevels) = try windowLevels(original, encoded, isCancelled: isCancelled)
        var audible = 0, quiet = 0
        for (index, level) in sourceLevels.enumerated() where level > Self.audible {
            audible += 1
            if copyLevels[index] < level - quieterBy { quiet += 1 }
        }
        let quietShare = audible > 0 ? Double(quiet) / Double(audible) : 0
        // Silent throughout (an unused computer-audio track): nothing to line up, but the copy must be silent too.
        if audible < max(1, sourceLevels.count / 100) {
            let loudest = copyLevels.max() ?? -160, sourceLoudest = sourceLevels.max() ?? -160
            guard loudest <= max(sourceLoudest + 6, -60) else { throw Refusal.envelope(0) }
            return Verification(frames: encoded.length, envelopeCorrelation: nil, quietShare: quietShare, lag: nil)
        }
        guard quietShare <= quietAllowance else { throw Refusal.quiet(quietShare) }
        let correlation = pearson(sourceLevels.map(amplitude), copyLevels.map(amplitude))
        guard correlation >= minimumEnvelopeCorrelation else { throw Refusal.envelope(correlation) }
        if isCancelled() { throw CancellationError() }
        let lag = try featureLag(source: source, copy: copy)
        guard lag == 0 else { throw Refusal.lag(lag) }
        return Verification(frames: encoded.length, envelopeCorrelation: correlation, quietShare: quietShare, lag: lag)
    }

    /// Where the copy's onset envelope (`AudioFeatures`, what alignment compares) best matches the recording's, in
    /// frames; 0 is in place.
    static func featureLag(source: URL, copy: URL) throws -> Int {
        let a = try AudioFeatures.extract(from: source).onset, b = try AudioFeatures.extract(from: copy).onset
        let count = min(a.count, b.count)
        guard count > 2 * lagSearch else { return 0 }
        let meanA = a.prefix(count).reduce(0, +) / Float(count), meanB = b.prefix(count).reduce(0, +) / Float(count)
        var best = (lag: 0, score: -Double.infinity)
        for lag in -lagSearch...lagSearch {
            var score = 0.0
            for index in max(0, -lag)..<min(count, count - lag) {
                score += Double(a[index] - meanA) * Double(b[index + lag] - meanB)
            }
            // Ties go to the smaller shift, so a flat envelope reads as in place.
            if score > best.score + 1e-9 || (abs(score - best.score) <= 1e-9 && abs(lag) < abs(best.lag)) { best = (lag, score) }
        }
        return best.lag
    }

    private static let chunkFrames: AVAudioFrameCount = 32_768

    private static func readChunks(_ file: AVAudioFile, isCancelled: () -> Bool, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { throw Refusal.unreadable }
        while file.framePosition < file.length {
            if isCancelled() { throw CancellationError() }
            try autoreleasepool {
                let frames = AVAudioFrameCount(min(Int64(chunkFrames), file.length - file.framePosition))
                try file.read(into: buffer, frameCount: frames)
            }
            guard buffer.frameLength > 0 else { break }
            try body(buffer)
        }
    }

    /// Each file's loudness (dBFS, channels averaged) in consecutive `window`s, read side by side.
    private static func windowLevels(_ a: AVAudioFile, _ b: AVAudioFile, isCancelled: () -> Bool) throws -> ([Double], [Double]) {
        func levels(_ file: AVAudioFile) throws -> [Double] {
            let size = max(1, Int(file.processingFormat.sampleRate * window))
            var result: [Double] = [], sum = 0.0, filled = 0
            try readChunks(file, isCancelled: isCancelled) { buffer in
                guard let data = buffer.floatChannelData else { return }
                let channels = Int(buffer.format.channelCount)
                for index in 0..<Int(buffer.frameLength) {
                    var sample: Float = 0
                    for channel in 0..<channels { sample += data[channel][index] }
                    let value = Double(sample) / Double(channels)
                    sum += value * value; filled += 1
                    if filled == size {
                        result.append(10 * log10(max(sum / Double(size), 1e-16)))
                        sum = 0; filled = 0
                    }
                }
            }
            return result
        }
        let first = try levels(a), second = try levels(b)
        let count = min(first.count, second.count)
        return (Array(first.prefix(count)), Array(second.prefix(count)))
    }

    private static func amplitude(_ decibels: Double) -> Double { pow(10, decibels / 20) }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let count = Double(min(a.count, b.count))
        guard count > 1 else { return 1 }
        let meanA = a.reduce(0, +) / count, meanB = b.reduce(0, +) / count
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for (x, y) in zip(a, b) {
            covariance += (x - meanA) * (y - meanB); varianceA += (x - meanA) * (x - meanA); varianceB += (y - meanB) * (y - meanB)
        }
        guard varianceA > 0, varianceB > 0 else { return varianceA == varianceB ? 1 : 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }
}
