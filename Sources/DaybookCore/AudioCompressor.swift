import AudioToolbox
import AVFoundation
import Foundation

/// Makes and checks the lossy copy that replaces an older recording (docs/architecture.md, "Compressing older
/// recordings"). AAC-LC in M4A, through AVFoundation, which every reader of a recording already opens: measured on this
/// encoder, a copy keeps the source's exact frame count, seeks exactly, and lines up with the source with no lag in the
/// alignment features. A copy is used only once `verify` passes; anything else keeps the original.
/// What each kind of recording is encoded as: one table, so changing the encoding is an edit here. Every copy records
/// the rule it was made under (`TrackEncoding.rule`); bump `rule` whenever a row changes.
public enum RecordingCompressionTable {
    /// The rule copies are made under now.
    public static let rule = 1

    public enum Codec: String, Sendable {
        case aacLC = "aac-lc"
        var formatID: AudioFormatID {
            switch self {
            case .aacLC: return kAudioFormatMPEG4AAC
            }
        }
    }

    /// A recording's shape: its rate (wide: 44.1 or 48 kHz; narrow: 16 kHz) and channels (stereo whose two channels are
    /// one sound counts as alike).
    public enum Shape: String, CaseIterable, Sendable {
        case wideMono, wideStereoAlike, wideStereo, narrowMono, narrowStereoAlike, narrowStereo
    }

    public struct Row: Equatable, Sendable {
        public var codec: Codec
        public var bitRate: Int
        /// The rate the copy is written at; nil keeps the recording's. A lower rate is resampled to before encoding.
        public var sampleRate: Double?
        public var channels: Int
        public init(codec: Codec, bitRate: Int, sampleRate: Double? = nil, channels: Int) {
            self.codec = codec; self.bitRate = bitRate; self.sampleRate = sampleRate; self.channels = channels
        }
    }

    public static func row(_ shape: Shape) -> Row {
        switch shape {
        case .wideMono, .wideStereoAlike: return Row(codec: .aacLC, bitRate: 64_000, channels: 1)
        case .wideStereo: return Row(codec: .aacLC, bitRate: 96_000, channels: 2)
        case .narrowMono, .narrowStereoAlike: return Row(codec: .aacLC, bitRate: 32_000, channels: 1)
        case .narrowStereo: return Row(codec: .aacLC, bitRate: 64_000, channels: 2)
        }
    }
}

public enum AudioCompressor {
    /// How one recording is encoded.
    public struct Plan: Equatable, Sendable {
        public var codec: RecordingCompressionTable.Codec
        /// The copy's rate.
        public var sampleRate: Double
        /// The recording's rate: the copy is resampled when they differ.
        public var sourceSampleRate: Double
        /// Channels written: 1, or 2 for a stereo recording whose channels differ.
        public var channels: Int
        public var bitRate: Int
        /// The source's channels are averaged into one.
        public var downmixes: Bool
        /// The table's rule (`RecordingCompressionTable.rule`).
        public var rule: Int
        public var resamples: Bool { sampleRate != sourceSampleRate }
        /// `TrackEncoding.method`: "aac-lc-64", "aac-lc-96-stereo", "aac-lc-32-16k".
        public var method: String {
            "\(codec.rawValue)-\(bitRate / 1_000)" + (channels == 2 ? "-stereo" : "") + (resamples ? "-\(Int(sampleRate / 1_000))k" : "")
        }

        public init(codec: RecordingCompressionTable.Codec = .aacLC, sampleRate: Double, sourceSampleRate: Double? = nil, channels: Int,
                    bitRate: Int, downmixes: Bool, rule: Int = RecordingCompressionTable.rule) {
            self.codec = codec; self.sampleRate = sampleRate; self.sourceSampleRate = sourceSampleRate ?? sampleRate
            self.channels = channels; self.bitRate = bitRate; self.downmixes = downmixes; self.rule = rule
        }

        /// The copy's frame count for a recording of `frames` frames.
        public func expectedFrames(from frames: Int64) -> Int64 {
            resamples ? Int64((Double(frames) * sampleRate / sourceSampleRate).rounded()) : frames
        }
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case unreadable, notLossless, unsupportedLayout(String)
        case encodingFailed(String)
        case wrongFormat(String), frameCount(source: Int64, copy: Int64), quiet(Double), dropout(TimeInterval), envelope(Double),
             level(TimeInterval), notSilent, lag(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The recording couldn’t be read."
            case .notLossless: return "The recording is already compressed."
            case .unsupportedLayout(let layout): return "The recording’s layout isn’t compressed (\(layout))."
            case .encodingFailed(let reason): return "Encoding failed: \(reason)"
            case .wrongFormat(let format): return "The copy isn’t the expected format (\(format))."
            case .frameCount(let source, let copy): return "The copy has \(copy) frames; it should have \(source)."
            case .quiet(let share): return "The copy is quiet where the recording isn’t (\(Int(share * 1_000)) per mille of windows)."
            case .dropout(let at): return "The copy drops out at \(Int(at)) s."
            case .envelope(let correlation): return "The copy’s loudness doesn’t follow the recording’s (correlation \(correlation))."
            case .level(let at): return "The copy’s level differs from the recording’s at \(Int(at)) s."
            case .notSilent: return "The recording is silent and the copy isn’t."
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

    /// A recording's shape (`RecordingCompressionTable.Shape`); 44.1/48 or 16 kHz, one or two channels, or it isn't
    /// compressed. Reads a stereo file through once to compare its channels.
    public static func shape(of url: URL, isCancelled: () -> Bool = { false }) throws -> RecordingCompressionTable.Shape {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { throw Refusal.unreadable }
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
        guard file.length > 0 else { throw Refusal.unreadable }
        let wide = rate == 44_100 || rate == 48_000
        guard wide || rate == 16_000 else { throw Refusal.unsupportedLayout("\(Int(rate)) Hz") }
        guard channels == 1 || channels == 2 else { throw Refusal.unsupportedLayout("\(channels) channels") }
        if channels == 1 { return wide ? .wideMono : .narrowMono }
        let similarity = try channelSimilarity(file, isCancelled: isCancelled)
        let alike = similarity.correlation >= sameChannelsCorrelation && abs(similarity.levelDifference) <= sameChannelsLevelDifference
        return wide ? (alike ? .wideStereoAlike : .wideStereo) : (alike ? .narrowStereoAlike : .narrowStereo)
    }

    /// The plan for a recording: its shape's row in `RecordingCompressionTable`.
    public static func plan(for url: URL, isCancelled: () -> Bool = { false }) throws -> Plan {
        let shape = try shape(of: url, isCancelled: isCancelled)
        guard let file = try? AVAudioFile(forReading: url) else { throw Refusal.unreadable }
        let row = RecordingCompressionTable.row(shape)
        let rate = file.processingFormat.sampleRate
        return Plan(codec: row.codec, sampleRate: row.sampleRate ?? rate, sourceSampleRate: rate, channels: row.channels,
                    bitRate: row.bitRate, downmixes: row.channels < Int(file.processingFormat.channelCount))
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

    /// Writes `source` encoded by `plan` to `destination` (a new file), a chunk at a time, then flushes it to storage:
    /// channels averaged when the plan downmixes, resampled when it changes the rate (to exactly `expectedFrames`).
    /// Stops with `CancellationError` once `isCancelled`; the caller deletes what was written.
    public static func encode(_ source: URL, to destination: URL, plan: Plan, isCancelled: () -> Bool = { false }) throws {
        guard let input = try? AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false) else { throw Refusal.unreadable }
        let settings: [String: Any] = [AVFormatIDKey: plan.codec.formatID, AVSampleRateKey: plan.sampleRate,
                                       AVNumberOfChannelsKey: plan.channels, AVEncoderBitRateKey: plan.bitRate]
        guard let staged = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.processingFormat.sampleRate,
                                         channels: AVAudioChannelCount(plan.channels), interleaved: false),
              let stagedBuffer = AVAudioPCMBuffer(pcmFormat: staged, frameCapacity: chunkFrames),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: plan.sampleRate,
                                         channels: AVAudioChannelCount(plan.channels), interleaved: false) else {
            throw Refusal.encodingFailed("no buffer")
        }
        let expected = plan.expectedFrames(from: input.length)
        do {
            // Closed (and its header written) before it's flushed, at the end of this scope.
            do {
                let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                var written: Int64 = 0
                /// Writes no more than the copy's frame count.
                func put(_ buffer: AVAudioPCMBuffer) throws {
                    let room = expected - written
                    guard room > 0, buffer.frameLength > 0 else { return }
                    if Int64(buffer.frameLength) > room { buffer.frameLength = AVAudioFrameCount(room) }
                    try output.write(from: buffer)
                    written += Int64(buffer.frameLength)
                }
                let converter = plan.resamples ? AVAudioConverter(from: staged, to: target) : nil
                if plan.resamples, converter == nil { throw Refusal.encodingFailed("no converter") }
                let capacity = AVAudioFrameCount(Double(chunkFrames) * plan.sampleRate / staged.sampleRate) + 4_096
                guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw Refusal.encodingFailed("no buffer") }
                func convert(_ chunk: AVAudioPCMBuffer?) throws {
                    guard let converter else { return }
                    var supplied = false
                    while true {
                        converted.frameLength = 0
                        var failure: NSError?
                        let status = converter.convert(to: converted, error: &failure) { _, state in
                            guard let chunk, !supplied else {
                                state.pointee = chunk == nil ? .endOfStream : .noDataNow
                                return nil
                            }
                            supplied = true
                            state.pointee = .haveData
                            return chunk
                        }
                        if let failure { throw failure }
                        try put(converted)
                        if status != .haveData { break }
                    }
                }
                try readChunks(input, isCancelled: isCancelled) { buffer in
                    let frames = Int(buffer.frameLength)
                    guard let data = buffer.floatChannelData, let out = stagedBuffer.floatChannelData else { return }
                    let channels = Int(buffer.format.channelCount)
                    for index in 0..<frames {
                        if plan.downmixes {
                            var sum: Float = 0
                            for channel in 0..<channels { sum += data[channel][index] }
                            out[0][index] = sum / Float(channels)
                        } else {
                            for channel in 0..<plan.channels { out[channel][index] = data[channel][index] }
                        }
                    }
                    stagedBuffer.frameLength = buffer.frameLength
                    if plan.resamples { try convert(stagedBuffer) } else { try put(stagedBuffer) }
                }
                if plan.resamples { try convert(nil) }
                // A resampler's last frames short of the count are silence, so the copy is exactly as long.
                while written < expected {
                    let frames = AVAudioFrameCount(min(Int64(capacity), expected - written))
                    guard let pad = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { break }
                    pad.frameLength = frames
                    for channel in 0..<plan.channels { pad.floatChannelData![channel].update(repeating: 0, count: Int(frames)) }
                    try put(pad)
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
        /// The lowest per-minute envelope correlation; nil when no minute had enough audible windows for one.
        public var envelopeCorrelation: Double?
        /// Share of the source's audible windows where the copy is much quieter.
        public var quietShare: Double
        /// Audible windows in the source; 0 for a silent recording.
        public var audibleWindows: Int
        public var lag: Int?
    }

    /// The bars a copy must clear, over 50 ms windows of loudness (dBFS, channels averaged):
    /// - A window is audible when it's within 30 dB of the recording's own 95th-percentile window and above -80 dBFS,
    ///   about the quietest a 16-bit recording's noise reaches; relative, so quiet speech (-55 dBFS) counts, and sparse
    ///   speech in a long silence counts however little of it there is.
    /// - In an audible window the copy must not be 12 dB quieter, in more than one window in 200 over the whole file,
    ///   and never in more than 2 windows in a row: an AAC frame (1,024 samples: 21 ms at 48 kHz, 64 ms at 16 kHz) smears
    ///   an onset into at most the window either side, so 150 ms of quiet is a dropout, not the codec.
    /// - The copy's loudness must follow the recording's with a correlation of at least 0.95 in every minute that has
    ///   20 or more audible windows; in a minute with fewer, each audible window's level must be within 9 dB.
    /// - A recording with no audible window at all needs only a copy that's silent too.
    /// AAC at these rates scores above 0.99 on speech, music, and noise (AudioCompressorTests), so a copy that misses is
    /// damaged: silent, cut short, shifted, or another recording.
    public static let window: TimeInterval = 0.05
    public static let audibleRange = 30.0
    public static let audibleFloor = -80.0
    public static let quieterBy = 12.0
    public static let quietAllowance = 0.005
    public static let longestQuietRun = 2
    public static let block = 1_200
    public static let blockMinimumAudible = 20
    public static let levelTolerance = 9.0
    public static let minimumEnvelopeCorrelation = 0.95
    /// The alignment features' lag is searched this many frames (10 ms each) either way.
    public static let lagSearch = 50

    /// Checks a copy against its recording before it may replace it: it opens with the planned codec, rate, and
    /// channels, has exactly the frame count the plan gives (the recording's, or its resampled length) as AVAudioFile
    /// reports it, passes the loudness bars above, and lines up with the recording at lag 0 in the alignment features.
    /// Throws the first check that fails.
    @discardableResult
    public static func verify(source: URL, copy: URL, plan: Plan, isCancelled: () -> Bool = { false }) throws -> Verification {
        guard let original = try? AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false) else { throw Refusal.unreadable }
        guard let encoded = try? AVAudioFile(forReading: copy, commonFormat: .pcmFormatFloat32, interleaved: false) else {
            throw Refusal.wrongFormat("unreadable")
        }
        let description = encoded.fileFormat.streamDescription.pointee
        guard description.mFormatID == plan.codec.formatID, encoded.fileFormat.sampleRate == plan.sampleRate,
              Int(encoded.fileFormat.channelCount) == plan.channels else {
            throw Refusal.wrongFormat("\(description.mFormatID), \(Int(encoded.fileFormat.sampleRate)) Hz, \(encoded.fileFormat.channelCount) ch")
        }
        let expected = plan.expectedFrames(from: original.length)
        guard encoded.length == expected else { throw Refusal.frameCount(source: expected, copy: encoded.length) }
        let (sourceLevels, copyLevels) = try windowLevels(original, encoded, isCancelled: isCancelled)
        let judged = try judge(sourceLevels, copyLevels)
        if judged.audible == 0 {
            return Verification(frames: encoded.length, envelopeCorrelation: nil, quietShare: 0, audibleWindows: 0, lag: nil)
        }
        if isCancelled() { throw CancellationError() }
        let lag = try featureLag(source: source, copy: copy)
        guard lag == 0 else { throw Refusal.lag(lag) }
        return Verification(frames: encoded.length, envelopeCorrelation: judged.correlation, quietShare: judged.quietShare,
                            audibleWindows: judged.audible, lag: lag)
    }

    /// The loudness bars, on two files' window levels (see `verify`).
    static func judge(_ source: [Double], _ copy: [Double]) throws -> (audible: Int, quietShare: Double, correlation: Double?) {
        let sorted = source.sorted()
        let p95 = sorted.isEmpty ? -160 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let threshold = max(p95 - audibleRange, audibleFloor)
        let audible = source.map { $0 > threshold }
        let audibleCount = audible.filter { $0 }.count
        guard audibleCount > 0 else {
            // Silent throughout (an unused computer-audio track): the copy must be silent too.
            guard (copy.max() ?? -160) <= max((source.max() ?? -160) + 6, audibleFloor) else { throw Refusal.notSilent }
            return (0, 0, nil)
        }
        var quiet = 0, run = 0
        for index in source.indices {
            if audible[index] && copy[index] < source[index] - quieterBy {
                quiet += 1; run += 1
                if run > longestQuietRun { throw Refusal.dropout(Double(index - run + 1) * window) }
            } else {
                run = 0
            }
        }
        let quietShare = Double(quiet) / Double(audibleCount)
        guard quietShare <= quietAllowance else { throw Refusal.quiet(quietShare) }
        var lowest: Double?
        for start in stride(from: 0, to: source.count, by: block) {
            let range = start..<min(source.count, start + block)
            let audibleHere = range.filter { audible[$0] }
            let a = range.map { amplitude(source[$0]) }, b = range.map { amplitude(copy[$0]) }
            if audibleHere.count >= blockMinimumAudible, let correlation = pearson(a, b) {
                guard correlation >= minimumEnvelopeCorrelation else { throw Refusal.envelope(correlation) }
                lowest = min(lowest ?? correlation, correlation)
            } else {
                // Too few to correlate (or a flat envelope): each audible window's level, one by one.
                for index in audibleHere where abs(copy[index] - source[index]) > levelTolerance {
                    throw Refusal.level(Double(index) * window)
                }
            }
        }
        return (audibleCount, quietShare, lowest)
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

    /// Nil when either side doesn't vary.
    private static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        let count = Double(min(a.count, b.count))
        guard count > 1 else { return nil }
        let meanA = a.reduce(0, +) / count, meanB = b.reduce(0, +) / count
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for (x, y) in zip(a, b) {
            covariance += (x - meanA) * (y - meanB); varianceA += (x - meanA) * (x - meanA); varianceB += (y - meanB) * (y - meanB)
        }
        guard varianceA > 1e-18, varianceB > 1e-18 else { return nil }
        return covariance / (varianceA * varianceB).squareRoot()
    }
}
