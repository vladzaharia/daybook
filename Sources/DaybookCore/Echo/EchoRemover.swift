import Accelerate
import AVFoundation
import Foundation

/// Why echo removal did not produce a cleaned microphone track.
public enum EchoRemovalSkipReason: String, Codable, Equatable, Sendable {
    case noCallTrack, headphones, callSilent, microphoneSilent, noEchoDetected, disabled

    public var explanation: String {
        switch self {
        case .noCallTrack: return "No call audio was recorded, so there is nothing to remove from the microphone."
        case .headphones: return "Headphones were in use for the whole recording, so the call could not reach the microphone."
        case .callSilent: return "The call track was silent, so it could not have echoed into the microphone."
        case .microphoneSilent: return "The microphone track was silent."
        case .noEchoDetected: return "The call was not audible in the microphone (headphones, a muted speaker, or very low volume)."
        case .disabled: return "Echo removal is turned off."
        }
    }
}

public struct EchoRemovalReport: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case applied, skipped, failed }
    /// One stretch processed with a single bulk delay; a new delay starts a fresh filter.
    public struct Segment: Codable, Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var delaySeconds: Double
        public var confidence: Double
    }

    @Extensible public var outcome: Outcome
    @ExtensibleOptional public var skipReason: EchoRemovalSkipReason?
    /// Human-readable reason for a skip or failure.
    public var detail: String?
    public var processingSampleRate: Double?
    /// Echo delay found across the whole recording (positive: the microphone hears the call later).
    public var delay: EchoDelayEstimate?
    public var segments: [Segment]?
    /// Device clock drift against the host clock, in parts per million.
    public var microphoneDriftPPM: Double?
    public var callDriftPPM: Double?
    /// Echo return loss enhancement measured on converged call-only stretches.
    public var echoReturnLossEnhancementDB: Double?
    /// Share of call-active time in which the near end talked over the call.
    public var doubleTalkFraction: Double?
    public var callActiveSeconds: Double?
    public var durationSeconds: Double?

    public init(outcome: Outcome, skipReason: EchoRemovalSkipReason? = nil, detail: String? = nil) {
        self.outcome = outcome; self.skipReason = skipReason
        self.detail = detail ?? skipReason?.explanation
    }

    public static func skipped(_ reason: EchoRemovalSkipReason) -> EchoRemovalReport { .init(outcome: .skipped, skipReason: reason) }
    public static func failed(_ detail: String) -> EchoRemovalReport { .init(outcome: .failed, detail: detail) }
    public var relativeDriftPPM: Double? {
        guard let microphoneDriftPPM, let callDriftPPM else { return nil }
        return callDriftPPM - microphoneDriftPPM
    }
}

public struct EchoRemovalConfiguration: Codable, Equatable, Sendable {
    /// Rate of the analysis and of the cleaned track. Speech recognition and speaker models consume
    /// 16 kHz, and laptop speakers put little echo energy above 8 kHz.
    public var processingRate: Double
    public var canceller: EchoCancellerConfiguration
    /// Call audio quieter than this (per 20 ms) counts as silence.
    public var callActivityThresholdDB: Double
    /// Less audible call than this skips processing.
    public var minimumCallActivitySeconds: Double
    /// The delay is also measured per window, so a route change gets its own bulk delay.
    public var delayWindowSeconds: Double
    /// Filter span kept ahead of the measured direct path, absorbing small delay changes.
    public var delayMarginSeconds: Double
    /// Windows whose delay differs by more than this start a new segment.
    public var delayChangeTolerance: Double
    /// Each segment's filter first converges on up to this much of it, then the segment is processed
    /// from its start, so greetings at the top of a call are cleaned too.
    public var convergencePreRollSeconds: Double

    public init(processingRate: Double = 16_000, canceller: EchoCancellerConfiguration? = nil,
                callActivityThresholdDB: Double = -55, minimumCallActivitySeconds: Double = 2,
                delayWindowSeconds: Double = 30, delayMarginSeconds: Double = 0.032, delayChangeTolerance: Double = 0.012,
                convergencePreRollSeconds: Double = 30) {
        self.processingRate = processingRate
        self.canceller = canceller ?? EchoCancellerConfiguration(sampleRate: processingRate)
        self.callActivityThresholdDB = callActivityThresholdDB
        self.minimumCallActivitySeconds = minimumCallActivitySeconds
        self.delayWindowSeconds = delayWindowSeconds
        self.delayMarginSeconds = delayMarginSeconds
        self.delayChangeTolerance = delayChangeTolerance
        self.convergencePreRollSeconds = convergencePreRollSeconds
    }
}

/// Receives the cleaned microphone.
public protocol PCMSampleSink: AnyObject {
    func write(_ samples: UnsafePointer<Float>, count: Int) throws
}

public final class ArraySampleSink: PCMSampleSink {
    public private(set) var samples: [Float] = []
    public init() {}
    public func write(_ samples: UnsafePointer<Float>, count: Int) throws {
        self.samples.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
    }
}

/// Writes mono Float32 PCM to a CAF file.
public final class AudioFileSampleSink: PCMSampleSink {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    public init(url: URL, sampleRate: Double) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { throw CocoaError(.fileWriteUnknown) }
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.buffer = buffer
    }

    public func write(_ samples: UnsafePointer<Float>, count: Int) throws {
        var written = 0
        while written < count {
            let frames = min(count - written, Int(buffer.frameCapacity))
            buffer.frameLength = AVAudioFrameCount(frames)
            buffer.floatChannelData![0].update(from: samples + written, count: frames)
            try file.write(from: buffer)
            written += frames
        }
    }
}

/// Removes the call's echo from the microphone, offline and deterministically.
///
/// 1. Both tracks are resampled to `processingRate` on the shared session timeline, using each
///    track's measured clock, so device drift cannot smear the echo path.
/// 2. A first pass measures call activity and the echo delay (GCC-PHAT) globally and per window.
/// 3. A second pass runs `EchoCanceller` with the reference shifted by the bulk delay of each segment.
///
/// The output covers the microphone's span and starts at the microphone's first sample time.
public enum EchoRemover {
    public static func run(microphone: PCMSampleSource, microphoneClock: TrackClock,
                           call: PCMSampleSource, callClock: TrackClock,
                           sink: PCMSampleSink, configuration: EchoRemovalConfiguration = .init(),
                           isCancelled: () -> Bool = { false }) throws -> EchoRemovalReport {
        let rate = configuration.processingRate
        let start = microphoneClock.time(atFrame: 0)
        let end = microphoneClock.time(atFrame: Double(microphone.frameCount))
        let total = max(0, Int(((end - start) * rate).rounded()))
        var report = EchoRemovalReport(outcome: .skipped)
        report.processingSampleRate = rate
        report.microphoneDriftPPM = microphoneClock.driftPPM
        report.callDriftPPM = callClock.driftPPM
        report.durationSeconds = Double(total) / rate
        let micWeights = try ChannelSelection.weights(for: microphone)

        // Pass 1: activity and delay.
        let analysis = try analyse(microphone: microphone, microphoneClock: microphoneClock, micWeights: micWeights,
                                   call: call, callClock: callClock, start: start, total: total,
                                   configuration: configuration, isCancelled: isCancelled)
        report.callActiveSeconds = analysis.callActiveSeconds
        func skip(_ reason: EchoRemovalSkipReason) -> EchoRemovalReport {
            var skipped = report
            skipped.outcome = .skipped; skipped.skipReason = reason; skipped.detail = reason.explanation
            return skipped
        }
        guard analysis.microphoneEnergy > 0 else { return skip(.microphoneSilent) }
        guard analysis.callActiveSeconds >= configuration.minimumCallActivitySeconds else { return skip(.callSilent) }
        report.delay = analysis.global
        guard let global = analysis.global, global.isEcho else { return skip(.noEchoDetected) }
        let segments = plan(windows: analysis.windows, global: global, total: total, configuration: configuration)
        report.segments = segments.map {
            .init(start: start + Double($0.start) / rate, end: start + Double($0.end) / rate,
                  delaySeconds: $0.delay.delaySeconds, confidence: $0.delay.confidence)
        }

        // Pass 2: cancellation.
        var statistics: [EchoCancellerStatistics] = []
        for segment in segments {
            let stats = try cancel(segment: segment, microphone: microphone, microphoneClock: microphoneClock, micWeights: micWeights,
                                   call: call, callClock: callClock, start: start, sink: sink,
                                   configuration: configuration, isCancelled: isCancelled)
            statistics.append(stats)
        }
        let input = statistics.map(\.echoOnlyInputEnergy).reduce(0, +)
        let output = statistics.map(\.echoOnlyOutputEnergy).reduce(0, +)
        let echoOnly = statistics.map(\.echoOnlyBlocks).reduce(0, +)
        if echoOnly >= 10, input > 0 { report.echoReturnLossEnhancementDB = 10 * log10(input / max(output, input * 1e-9)) }
        let far = statistics.map(\.farEndBlocks).reduce(0, +)
        report.doubleTalkFraction = far > 0 ? Double(statistics.map(\.doubleTalkBlocks).reduce(0, +)) / Double(far) : 0
        report.outcome = .applied
        report.skipReason = nil
        report.detail = nil
        return report
    }

    // MARK: - Analysis

    struct Analysis {
        var callActiveSeconds: Double
        var microphoneEnergy: Double
        var global: EchoDelayEstimate?
        /// Per window: first output sample, last (exclusive), and estimate.
        var windows: [(start: Int, end: Int, estimate: EchoDelayEstimate?)]
    }

    static func analyse(microphone: PCMSampleSource, microphoneClock: TrackClock, micWeights: [Float],
                        call: PCMSampleSource, callClock: TrackClock, start: TimeInterval, total: Int,
                        configuration: EchoRemovalConfiguration, isCancelled: () -> Bool) throws -> Analysis {
        let rate = configuration.processingRate
        let frame = 16_384
        let micReader = try SessionTimelineReader(source: microphone, clock: microphoneClock, outputRate: rate,
                                                  startTime: start, channelWeights: micWeights)
        let callReader = try SessionTimelineReader(source: call, clock: callClock, outputRate: rate, startTime: start)
        let windowFrames = max(1, Int(configuration.delayWindowSeconds * rate) / frame)
        var windows: [(start: Int, end: Int, estimator: EchoDelayEstimator)] = []
        let mic = FloatBuffer(frame), ref = FloatBuffer(frame)
        let hop = Int(0.02 * rate)
        let threshold = Float(pow(10, configuration.callActivityThresholdDB / 10)) * Float(hop)
        var activeHops = 0
        var micEnergy = 0.0
        var position = 0
        var index = 0
        while position < total {
            if isCancelled() { throw CancellationError() }
            let count = min(frame, total - position)
            mic.zero(); ref.zero()
            try micReader.read(count, into: mic.pointer)
            try callReader.read(count, into: ref.pointer)
            micEnergy += Double(SpectralMath.energy(mic.pointer, count: count))
            var hopsActive = 0
            var offset = 0
            while offset + hop <= count {
                if SpectralMath.energy(ref.pointer + offset, count: hop) > threshold { hopsActive += 1 }
                offset += hop
            }
            activeHops += hopsActive
            if index % windowFrames == 0 {
                windows.append((position, position, EchoDelayEstimator(sampleRate: rate, frameSize: frame)))
            }
            windows[windows.count - 1].end = position + count
            // Only frames where the call is mostly audible inform the delay.
            if count == frame && hopsActive * hop * 4 >= count {
                windows[windows.count - 1].estimator.add(reference: ref.pointer, microphone: mic.pointer)
            }
            position += count
            index += 1
        }
        let global = EchoDelayEstimator(sampleRate: rate, frameSize: frame)
        for window in windows { global.merge(window.estimator) }
        return Analysis(callActiveSeconds: Double(activeHops * hop) / rate, microphoneEnergy: micEnergy,
                        global: global.estimate(), windows: windows.map { ($0.start, $0.end, $0.estimator.estimate()) })
    }

    /// Groups windows into segments with one bulk delay each. Windows without a confident estimate
    /// follow their neighbours; the whole recording uses the global delay unless confident windows disagree.
    static func plan(windows: [(start: Int, end: Int, estimate: EchoDelayEstimate?)], global: EchoDelayEstimate,
                     total: Int, configuration: EchoRemovalConfiguration) -> [(start: Int, end: Int, delay: EchoDelayEstimate)] {
        let block = configuration.canceller.blockSize
        let confident = windows.filter { $0.estimate?.isEcho == true }
        let disagree = confident.contains { abs($0.estimate!.delaySeconds - global.delaySeconds) > configuration.delayChangeTolerance }
        guard disagree else { return [(0, total, global)] }
        var segments: [(start: Int, end: Int, delay: EchoDelayEstimate)] = []
        var current = confident.first!.estimate!
        for window in windows {
            if let estimate = window.estimate, estimate.isEcho { current = estimate }
            if let last = segments.last, abs(last.delay.delaySeconds - current.delaySeconds) <= configuration.delayChangeTolerance {
                segments[segments.count - 1].end = window.end
            } else {
                // Block-aligned boundaries keep the canceller's frames contiguous.
                let boundary = segments.isEmpty ? 0 : (window.start / block) * block
                if !segments.isEmpty { segments[segments.count - 1].end = boundary }
                segments.append((boundary, window.end, current))
            }
        }
        segments[segments.count - 1].end = total
        return segments.filter { $0.end > $0.start }
    }

    // MARK: - Cancellation

    static func cancel(segment: (start: Int, end: Int, delay: EchoDelayEstimate), microphone: PCMSampleSource,
                       microphoneClock: TrackClock, micWeights: [Float], call: PCMSampleSource, callClock: TrackClock,
                       start: TimeInterval, sink: PCMSampleSink, configuration: EchoRemovalConfiguration,
                       isCancelled: () -> Bool) throws -> EchoCancellerStatistics {
        let rate = configuration.processingRate
        let block = configuration.canceller.blockSize
        let bulk = segment.delay.delaySeconds - configuration.delayMarginSeconds
        let length = segment.end - segment.start
        func readers(from sample: Int) throws -> (SessionTimelineReader, SessionTimelineReader) {
            let time = start + Double(sample) / rate
            return (try SessionTimelineReader(source: microphone, clock: microphoneClock, outputRate: rate,
                                              startTime: time, channelWeights: micWeights),
                    try SessionTimelineReader(source: call, clock: callClock, outputRate: rate, startTime: time - bulk))
        }
        let chunkBlocks = 64
        let mic = FloatBuffer(chunkBlocks * block), ref = FloatBuffer(chunkBlocks * block), out = FloatBuffer(chunkBlocks * block)
        /// Runs `blocks` blocks through `canceller`, handing each chunk's output to `consume`.
        func run(_ canceller: EchoCanceller, from sample: Int, blocks: Int, consume: (UnsafePointer<Float>, Int) throws -> Void) throws {
            let (micReader, callReader) = try readers(from: sample)
            var processed = 0
            while processed < blocks {
                if isCancelled() { throw CancellationError() }
                let count = min(chunkBlocks, blocks - processed)
                try micReader.read(count * block, into: mic.pointer)
                try callReader.read(count * block, into: ref.pointer)
                for index in 0..<count {
                    canceller.process(microphone: mic.pointer + index * block, reference: ref.pointer + index * block,
                                      output: out.pointer + index * block)
                }
                try consume(out.pointer, count * block)
                processed += count
            }
        }

        let canceller = EchoCanceller(configuration: configuration.canceller)
        // Converge on the opening stretch first, then process from the start with that filter.
        let preRoll = min(length, Int(configuration.convergencePreRollSeconds * rate)) / block
        if preRoll * block >= Int(2 * rate) {
            let warm = EchoCanceller(configuration: configuration.canceller)
            try run(warm, from: segment.start, blocks: preRoll) { _, _ in }
            canceller.adoptConvergedState(from: warm)
        }
        // One warm-up block before the segment primes the overlap buffers; the suppressor's latency
        // is dropped from the front so the output lines up with the microphone.
        let warmUp = block
        var skip = warmUp + canceller.latency
        var remaining = length
        let blocks = (warmUp + length + canceller.latency + block - 1) / block
        try run(canceller, from: segment.start - warmUp, blocks: blocks) { pointer, count in
            let offset = min(skip, count)
            skip -= offset
            let keep = min(count - offset, remaining)
            if keep > 0 { try sink.write(pointer + offset, count: keep); remaining -= keep }
        }
        if remaining > 0 {
            let zeros = [Float](repeating: 0, count: remaining)
            try zeros.withUnsafeBufferPointer { try sink.write($0.baseAddress!, count: remaining) }
        }
        return canceller.statistics
    }
}
