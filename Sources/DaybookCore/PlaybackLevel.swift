import Foundation

/// The one constant gain a recording plays with so that moving between a conversation's recordings doesn't jump in
/// loudness (docs/architecture.md, "Playback levels"). Like `SpeechLevel`, the rule is pure: the same measurements give
/// the same gain on every device. The stored recording is never changed; the player applies the gain as its volume.
///
/// The reference is the conversation: its recordings' speech levels are brought toward the quietest of them. A player
/// whose volume tops out at 1 (`AVAudioPlayer`) can't raise anything, so the quietest plays as captured and the others
/// come down to it, by at most `maximumCut`; there's no level a recording is brought to in every conversation.
public enum PlaybackLevel {
    public struct Policy: Equatable, Sendable {
        /// The most a recording is lowered, dB. Past this a recording is a hot capture, and lowering it further would
        /// only make the whole conversation quieter.
        public var maximumCut = 12.0
        /// Recordings whose speech levels are within this of each other, dB, play as captured. About the smallest
        /// difference heard as a change in loudness; ordinary differences between microphones and call apps are as
        /// large, and changing the volume for them would only be noticed as the volume changing.
        public var deadBand = 3.0
        /// The speech level must stand at least this far, dB, above the quiet level, as for `SpeechLevel.Policy`: a
        /// recording of noise has no speech level to match. Applied only when the quiet level is known.
        public var minimumRange = SpeechLevel.Policy.standard.minimumRange

        public init() {}

        public static let standard = Policy()
    }

    /// What playback knows of a conversation's levels when it plays one of its recordings.
    public struct Conversation: Equatable, Sendable {
        public var id: UUID
        /// The playing recording's recorded level, when it has one.
        public var own: SpeechLevel.Measurement?
        /// The recorded levels of the conversation's other recordings.
        public var others: [SpeechLevel.Measurement]

        public init(id: UUID, own: SpeechLevel.Measurement?, others: [SpeechLevel.Measurement]) {
            self.id = id; self.own = own; self.others = others
        }
    }

    /// The speech level of a measurement that has speech-like dynamics, dBFS; nil with none to match.
    static func usableSpeech(_ measurement: SpeechLevel.Measurement, policy: Policy) -> Double? {
        guard let speech = measurement.speech, speech.isFinite else { return nil }
        if let quiet = measurement.quiet, speech - quiet < policy.minimumRange { return nil }
        return speech
    }

    /// The gain, dB, for a recording that measured `level` among the conversation's `levels` (its own included or not;
    /// those without a usable level are ignored): 0 or negative. The target is the quietest speech level, but no more
    /// than `maximumCut` under the loudest; the gain is what brings `level` to it. 0 for a recording with no usable
    /// level, for fewer than two usable levels, and for levels within `deadBand` of each other.
    public static func gain(for level: SpeechLevel.Measurement, among levels: [SpeechLevel.Measurement], policy: Policy = .standard) -> Double {
        guard let own = usableSpeech(level, policy: policy) else { return 0 }
        let speeches = levels.compactMap { usableSpeech($0, policy: policy) }
        guard speeches.count >= 2, let quietest = speeches.min(), let loudest = speeches.max(),
              loudest - quietest >= policy.deadBand else { return 0 }
        let target = max(quietest, loudest - policy.maximumCut)
        return min(0, max(target - own, -policy.maximumCut))
    }

    /// The gain as a factor on the samples.
    public static func factor(for level: SpeechLevel.Measurement, among levels: [SpeechLevel.Measurement], policy: Policy = .standard) -> Float {
        Float(pow(10, gain(for: level, among: levels, policy: policy) / 20))
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

    /// What playback knows of this conversation's levels when it plays `trackID`.
    public func playbackLevels(ofTrack trackID: UUID) -> PlaybackLevel.Conversation {
        PlaybackLevel.Conversation(id: id, own: recordedLevel(ofTrack: trackID),
                                   others: presentTracks.filter { $0.id != trackID }.compactMap { recordedLevel(ofTrack: $0.id) })
    }
}
