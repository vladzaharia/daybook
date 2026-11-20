import AVFoundation
import Foundation

/// How loud a recording's speech is, and the one gain that brings speech far quieter than a normal level up to it before
/// the speech models hear it (docs/architecture.md, "Input levels"). The measure is pure: the same samples give the same
/// answer on every device, block boundaries or not. `Meter` takes samples as they come; `measure(url:)` reads a file.
///
/// The speech level is the 95th percentile of the recording's 100 ms RMS levels, counting only windows above −70 dBFS:
/// pauses and silence don't pull it down (a whole-file mean would), and a click or a cough doesn't push it up (the peak
/// would), as long as speech fills more than 5% of what's audible. When it doesn't (a line of noise, or a few words
/// over a long hum), the 95th percentile is the noise; so a recording is raised only when that level stands at least
/// 10 dB above the quietest tenth of it, as speech does over the pauses between words and stationary noise doesn't.
public enum SpeechLevel {
    /// The rule's numbers.
    public struct Policy: Equatable, Sendable {
        /// The speech level a recording is brought to, dBFS: about where clearly recorded meeting speech sits on this
        /// measure, and EBU R128's loudness target.
        public var target = -23.0
        /// Only a recording whose speech measures below this, dBFS (12 dB under the target), is changed: ordinary
        /// differences between microphones and call apps stay as they were captured.
        public var actBelow = -35.0
        /// The most a recording is raised, dB: speech at −53 dBFS reaches the target; below that a recording holds
        /// little more than noise, which more gain only makes louder.
        public var maximumGain = 30.0
        /// The gain is lowered until the loudest sample stays at or under this, dBFS, rather than clipped or limited.
        public var peakCeiling = -1.0
        /// A gain smaller than this, dB, changes nothing a model would notice, so the recording is left as it is.
        public var minimumGain = 1.0
        /// The RMS window, seconds.
        public var windowSeconds = 0.1
        /// The share of audible windows at or below the speech level.
        public var percentile = 0.95
        /// Windows below this, dBFS, are silence: digital silence, dither, a muted line.
        public var silenceFloor = -70.0
        /// Less audible sound than this, seconds, isn't measured.
        public var minimumSoundSeconds = 1.0
        /// The share of all windows, silent ones included, at or below the recording's quiet level.
        public var quietPercentile = 0.1
        /// The speech level must stand at least this far, dB, above the quiet level for the recording to be raised.
        /// Stationary noise measures within about 1 dB between the two, and noise that ebbs and flows (a fan, traffic,
        /// comfort noise) a few dB; speech, even quiet speech in a noisy room, 15 dB and more between syllables and the
        /// gaps between them. 10 dB keeps a margin both ways, and is where speech no longer stands clear of the noise
        /// it would be raised with.
        public var minimumRange = 10.0

        public init() {}

        public static let standard = Policy()
    }

    /// What a recording measured, dBFS.
    public struct Measurement: Equatable, Sendable {
        /// The speech level; nil with less audible sound than `Policy.minimumSoundSeconds`.
        public var speech: Double?
        /// The highest sample magnitude in any channel; nil for digital silence.
        public var peak: Double?
        /// The quiet level: `Policy.quietPercentile` of every window, silent ones included (−∞ for digital silence);
        /// nil when there was no window, or too little sound to measure. Nil never lets a recording be raised.
        public var quiet: Double?

        public init(speech: Double?, peak: Double?, quiet: Double? = nil) {
            self.speech = speech; self.peak = peak; self.quiet = quiet
        }
    }

    /// Measures a recording fed to it in order, block by block, at its own sample rate. Channels are averaged for the
    /// level; the peak is any channel's. Sums are kept in `Double`, in sample order, so the result doesn't depend on the
    /// device or on where blocks break.
    public struct Meter: Sendable {
        public let policy: Policy
        public let sampleRate: Double
        let windowLength: Int
        private var sum = 0.0
        private var filled = 0
        /// Every window's RMS level, dBFS (−∞ for digital silence).
        private var levels: [Double] = []
        private var peak: Float = 0

        public init(sampleRate: Double, policy: Policy = .standard) {
            self.policy = policy
            self.sampleRate = sampleRate
            windowLength = max(1, Int((sampleRate * policy.windowSeconds).rounded()))
        }

        /// The next frames: one array per channel, the same length each (a longer channel's extra frames are ignored).
        public mutating func add(_ channels: [[Float]]) {
            guard !channels.isEmpty, let frames = channels.map(\.count).min(), frames > 0 else { return }
            let share = 1 / Double(channels.count)
            for frame in 0..<frames {
                var mixed = 0.0
                for channel in channels {
                    let value = channel[frame].isFinite ? channel[frame] : 0
                    peak = max(peak, abs(value))
                    mixed += Double(value)
                }
                mixed *= share
                sum += mixed * mixed
                filled += 1
                if filled == windowLength {
                    levels.append(10 * log10(sum / Double(windowLength)))
                    sum = 0
                    filled = 0
                }
            }
        }

        /// One channel's next samples.
        public mutating func add(_ samples: [Float]) { add([samples]) }

        /// The level of everything added so far. A last window shorter than the others isn't counted.
        public func measurement() -> Measurement {
            let peakLevel = peak > 0 ? 20 * log10(Double(peak)) : nil
            let sorted = levels.sorted()
            // Audible windows are the loudest ones: those from the first at or above the floor.
            let firstAudible = sorted.firstIndex { $0 >= policy.silenceFloor } ?? sorted.count
            let audible = sorted.count - firstAudible
            guard audible > 0, Double(audible * windowLength) / sampleRate >= policy.minimumSoundSeconds else {
                return Measurement(speech: nil, peak: peakLevel)
            }
            // Nearest rank: the smallest level with at least that share of the windows at or below it.
            func rank(_ share: Double, of count: Int) -> Int { min(count - 1, max(0, Int((share * Double(count)).rounded(.up)) - 1)) }
            return Measurement(speech: sorted[firstAudible + rank(policy.percentile, of: audible)], peak: peakLevel,
                               quiet: sorted[rank(policy.quietPercentile, of: sorted.count)])
        }
    }

    /// Measures the recording at `url` at its own sample rate, block by block so memory stays bounded, stopping with
    /// `CancellationError` between blocks once the task is cancelled. For work already off the main actor.
    public static func measure(contentsOf url: URL, policy: Policy = .standard) throws -> Measurement {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var meter = Meter(sampleRate: format.sampleRate, policy: policy)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition)))
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            meter.add((0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) })
        }
        return meter.measurement()
    }

    /// The same, off the caller's actor at the caller's priority, and cancelled with the caller.
    public static func measure(url: URL, policy: Policy = .standard) async throws -> Measurement {
        try Task.checkCancellation()
        return try await detachedWork(priority: Task.currentPriority) { try measure(contentsOf: url, policy: policy) }
    }

    /// The gain for a measured recording: when its speech is below `actBelow` and at least `minimumRange` above its
    /// quiet level, enough to bring it to `target`, at most `maximumGain`, and no more than keeps its peak at
    /// `peakCeiling`; never negative. Gains come in 0.1 dB steps, rounded down (so the ceiling holds), and one under
    /// `minimumGain` is none. A recording left alone still has its level and peak recorded, with a gain of 0.
    public static func adjustment(for measurement: Measurement, policy: Policy = .standard) -> LevelAdjustment {
        func tenth(_ value: Double?) -> Double? { value.map { ($0 * 10).rounded() / 10 } }
        var gain = 0.0
        if let speech = measurement.speech, let peak = measurement.peak, let quiet = measurement.quiet, speech < policy.actBelow,
           speech - quiet >= policy.minimumRange {
            let wanted = min(policy.target - speech, policy.maximumGain, policy.peakCeiling - peak)
            let stepped = (wanted * 10).rounded(.down) / 10
            if stepped >= policy.minimumGain { gain = stepped }
        }
        return LevelAdjustment(speechLevel: tenth(measurement.speech), peak: tenth(measurement.peak), gain: gain)
    }
}

/// What was done to a recording's level before the speech models heard it (`SpeechLevel`). It's kept with the run's
/// settings (`ProcessingSettings.levelAdjustment`), so a transcript and its speakers say how their audio was prepared.
public struct LevelAdjustment: Codable, Equatable, Sendable {
    /// The rule that decided (`SpeechLevel.Policy.standard`); a different rule is a new version.
    public static let currentVersion = 1
    public var version: Int
    /// The recording's speech level, dBFS, to 0.1 dB; nil when there was too little sound to measure.
    public var speechLevel: Double?
    /// Its loudest sample, dBFS, to 0.1 dB; nil for digital silence.
    public var peak: Double?
    /// The one constant gain the models heard it with, dB, in 0.1 dB steps; 0 when it was left as it was.
    public var gain: Double

    public init(version: Int = LevelAdjustment.currentVersion, speechLevel: Double?, peak: Double?, gain: Double) {
        self.version = version; self.speechLevel = speechLevel; self.peak = peak; self.gain = gain
    }

    /// The gain as a factor on the samples.
    public var factor: Float { Float(pow(10, gain / 20)) }
}
