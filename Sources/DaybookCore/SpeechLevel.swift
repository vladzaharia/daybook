import Foundation

/// How loud a recording's speech is, and the one gain that brings speech far quieter than a normal level up to it before
/// the speech models hear it (docs/architecture.md, "Input levels"). Pure: the same samples give the same answer on every
/// device, block boundaries or not.
///
/// The speech level is the 95th percentile of the recording's 100 ms RMS levels, counting only windows above −70 dBFS:
/// pauses and silence don't pull it down (a whole-file mean would), and a click or a cough doesn't push it up (the peak
/// would), as long as speech fills more than 5% of what's audible.
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

        public init() {}

        public static let standard = Policy()
    }

    /// What a recording measured, dBFS.
    public struct Measurement: Equatable, Sendable {
        /// The speech level; nil with less audible sound than `Policy.minimumSoundSeconds`.
        public var speech: Double?
        /// The highest sample magnitude in any channel; nil for digital silence.
        public var peak: Double?

        public init(speech: Double?, peak: Double?) {
            self.speech = speech; self.peak = peak
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
        /// Each audible window's RMS level, dBFS.
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
                    let level = 10 * log10(sum / Double(windowLength))
                    if level >= policy.silenceFloor { levels.append(level) }
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
            guard !levels.isEmpty, Double(levels.count * windowLength) / sampleRate >= policy.minimumSoundSeconds else {
                return Measurement(speech: nil, peak: peakLevel)
            }
            let sorted = levels.sorted()
            // Nearest rank: the smallest level with at least `percentile` of the windows at or below it.
            let rank = Int((policy.percentile * Double(sorted.count)).rounded(.up)) - 1
            return Measurement(speech: sorted[min(sorted.count - 1, max(0, rank))], peak: peakLevel)
        }
    }

    /// The gain for a measured recording: when its speech is below `actBelow`, enough to bring it to `target`, at most
    /// `maximumGain`, and no more than keeps its peak at `peakCeiling`; never negative. Gains come in 0.1 dB steps,
    /// rounded down (so the ceiling holds), and one under `minimumGain` is none.
    public static func adjustment(for measurement: Measurement, policy: Policy = .standard) -> LevelAdjustment {
        func tenth(_ value: Double?) -> Double? { value.map { ($0 * 10).rounded() / 10 } }
        var gain = 0.0
        if let speech = measurement.speech, let peak = measurement.peak, speech < policy.actBelow {
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
