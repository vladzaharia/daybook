import Foundation

/// The one constant gain a recording plays with so that moving from one recording to the next, or from one conversation
/// to the next, doesn't jump in loudness (docs/architecture.md, "Playback levels"). Like `SpeechLevel`, the rule is pure:
/// the same measurement gives the same gain on every device. The stored recording is never changed; the player applies
/// the gain as its volume.
///
/// `AVAudioPlayer.volume` tops out at 1, so playback only ever brings loud recordings down to `target`; one already
/// quieter than that plays as it was captured. `maximumBoost` is 0 for that reason, and is a number rather than a
/// missing case so a player that can boost (an `AVAudioEngine` mixer) changes one value.
public enum PlaybackLevel {
    public struct Policy: Equatable, Sendable {
        /// The speech level (`SpeechLevel`'s measure), dBFS, every recording is brought down to. Well under where clear
        /// meeting speech sits (−23), so that most recordings are above it and the quieter ones are close to it.
        public var target = -32.0
        /// The most a recording is raised, dB. 0: the player can't.
        public var maximumBoost = 0.0
        /// The most a recording is lowered, dB: past this a recording is a hot capture, and lowering it further would
        /// only hide how far apart the others are.
        public var maximumCut = 12.0
        /// A raise is lowered until the loudest sample stays at or under this, dBFS: no limiter, no compression.
        public var peakCeiling = -1.0
        /// The speech level must stand at least this far, dB, above the quiet level, as for `SpeechLevel.Policy`: a
        /// recording of noise has no speech level to match. Applied only when the quiet level is known.
        public var minimumRange = SpeechLevel.Policy.standard.minimumRange

        public init() {}

        public static let standard = Policy()
    }

    /// The gain, dB, for a recording that measured `measurement`: positive raises, negative lowers, 0 leaves it. 0
    /// for a recording with no measurable speech or none like speech.
    public static func gain(for measurement: SpeechLevel.Measurement, policy: Policy = .standard) -> Double {
        guard let speech = measurement.speech, speech.isFinite else { return 0 }
        if let quiet = measurement.quiet, speech - quiet < policy.minimumRange { return 0 }
        let wanted = policy.target - speech
        if wanted >= 0 {
            let ceiling = measurement.peak.map { policy.peakCeiling - $0 } ?? 0
            return max(0, min(wanted, policy.maximumBoost, ceiling))
        }
        return max(wanted, -policy.maximumCut)
    }

    /// The gain as a factor on the samples.
    public static func factor(for measurement: SpeechLevel.Measurement, policy: Policy = .standard) -> Float {
        Float(pow(10, gain(for: measurement, policy: policy) / 20))
    }
}

extension LevelAdjustment {
    /// What a processed recording recorded of its level, as a measurement: without the quiet level, which isn't kept.
    public var measurement: SpeechLevel.Measurement { SpeechLevel.Measurement(speech: speechLevel, peak: peak) }
}

extension Meeting {
    /// The level a recording's latest processing recorded (`ProcessingSettings.levelAdjustment`), so playback needn't
    /// measure it. Nil when it was processed before levels were recorded, or not at all.
    public func recordedLevel(ofTrack trackID: UUID) -> SpeechLevel.Measurement? {
        transcripts.filter { $0.trackID == trackID }
            .compactMap(\.processingSettings)
            .filter { $0.levelAdjustment != nil }
            .max { $0.createdAt < $1.createdAt }?
            .levelAdjustment?.measurement
    }
}
