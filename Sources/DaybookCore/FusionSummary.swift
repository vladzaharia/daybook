import Foundation

/// What a recording contributes, inferred from how it was captured.
public enum FusionSourceRole: String, Codable, Sendable {
    /// Computer audio: the call's remote participants, as delivered.
    case call
    /// The Mac's microphone (or its echo-cancelled copy): the owner, plus anyone close by.
    case microphone
    /// A recorder in the room, or an imported file: whoever was in the room.
    case room
    /// No recording metadata was available.
    case unknown

    public init(_ source: AudioSource?) {
        switch source {
        case .systemAudio: self = .call
        case .microphone: self = .microphone
        case .soundcore, .imported: self = .room
        case nil: self = .unknown
        }
    }
}

/// How one recording took part in the unified transcript.
public struct FusionSourceReport: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { trackID }
    public var trackID: UUID
    public var role: FusionSourceRole
    /// The transcription run that was fused (the latest for the recording).
    public var transcriptID: UUID?
    /// False for unaligned recordings and for originals transcribed through a derived copy.
    public var included: Bool
    public var method: TrackAlignment.Method
    /// The recording the timing was measured against, when it wasn't the timeline itself.
    public var referenceTrackID: UUID?
    /// Meeting time = offset + rate × recording time.
    public var offset: TimeInterval
    public var rate: Double
    public var confidence: Double?
    /// Words in this recording's transcript.
    public var words: Int
    /// Words of the unified transcript whose wording came from this recording.
    public var wordsUsed: Int
    /// Words of the unified transcript this recording agreed with, alongside at least one other.
    public var wordsCorroborated: Int
    /// This recording's words that repeated speech another recording also captured, merged instead of shown twice.
    public var wordsMerged: Int
    /// This recording's words that lost a vote to other recordings.
    public var wordsOverruled: Int
    public var note: String?

    public var driftPPM: Double { (rate - 1) * 1_000_000 }

    public init(trackID: UUID, role: FusionSourceRole, transcriptID: UUID? = nil, included: Bool, method: TrackAlignment.Method,
                referenceTrackID: UUID? = nil, offset: TimeInterval = 0, rate: Double = 1, confidence: Double? = nil,
                words: Int = 0, wordsUsed: Int = 0, wordsCorroborated: Int = 0, wordsMerged: Int = 0, wordsOverruled: Int = 0,
                note: String? = nil) {
        self.trackID = trackID; self.role = role; self.transcriptID = transcriptID; self.included = included; self.method = method
        self.referenceTrackID = referenceTrackID; self.offset = offset; self.rate = rate; self.confidence = confidence
        self.words = words; self.wordsUsed = wordsUsed; self.wordsCorroborated = wordsCorroborated
        self.wordsMerged = wordsMerged; self.wordsOverruled = wordsOverruled; self.note = note
    }
}

/// A speaker label from one recording shown as another speaker in the unified transcript.
public struct FusionSpeakerMapping: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The microphone's main local voice, absent from the call: the person recording.
        case owner
        /// Both recordings heard the same words, and this label mostly coincided with that speaker.
        case sharedSpeech
    }
    public var sourceSpeakerID: String?
    public var trackID: UUID
    public var speakerID: String
    public var reason: Reason
    /// Share of this label's corroborated words that coincided with `speakerID` (0–1).
    public var share: Double
    public init(sourceSpeakerID: String?, trackID: UUID, speakerID: String, reason: Reason, share: Double) {
        self.sourceSpeakerID = sourceSpeakerID; self.trackID = trackID; self.speakerID = speakerID
        self.reason = reason; self.share = share
    }
}

/// What multi-source fusion did, for the interface and the processing pipeline. Deterministic for
/// the same inputs, so two Macs fusing the same recordings store the same value.
public struct FusionSummary: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var sources: [FusionSourceReport]
    public var words: Int
    /// Words heard in at least two recordings.
    public var corroboratedWords: Int
    /// Words where recordings disagreed and a vote decided.
    public var disputedWords: Int
    /// The speaker used for the person recording, when it could be inferred from the microphone.
    public var ownerSpeakerID: String?
    public var speakerMappings: [FusionSpeakerMapping]
    public init(version: Int = FusionSummary.currentVersion, sources: [FusionSourceReport], words: Int, corroboratedWords: Int,
                disputedWords: Int, ownerSpeakerID: String? = nil, speakerMappings: [FusionSpeakerMapping] = []) {
        self.version = version; self.sources = sources; self.words = words; self.corroboratedWords = corroboratedWords
        self.disputedWords = disputedWords; self.ownerSpeakerID = ownerSpeakerID; self.speakerMappings = speakerMappings
    }
}

public struct FusionOptions: Equatable, Sendable {
    /// Audio alignments below this confidence are ignored in favour of the next method.
    public var minimumAudioConfidence: Double
    /// Speaker ID and default name used for the person recording.
    public var ownerSpeakerID: String
    public var ownerName: String
    public init(minimumAudioConfidence: Double = 0.3, ownerSpeakerID: String = "owner", ownerName: String = "Me") {
        self.minimumAudioConfidence = minimumAudioConfidence; self.ownerSpeakerID = ownerSpeakerID; self.ownerName = ownerName
    }
}

/// Evidence for fusion beyond the transcripts. Everything is optional; with none of it fusion
/// still aligns by transcript text and votes on wording.
/// A recording's place on the meeting timeline decided elsewhere (by the processing pipeline from
/// an audio alignment, shared phrases, clocks, or the person): meeting time = offset + rate × recording time.
public struct TrackPlacement: Equatable, Sendable {
    public var offset: TimeInterval
    public var rate: Double
    /// How the placement was found: `.audio`, `.anchors`, `.timestamps`, or `.provided` (manual or capture).
    public var method: TrackAlignment.Method
    public var confidence: Double?
    public var referenceTrackID: UUID?
    public var explanation: String?
    public init(offset: TimeInterval, rate: Double = 1, method: TrackAlignment.Method, confidence: Double? = nil,
                referenceTrackID: UUID? = nil, explanation: String? = nil) {
        self.offset = offset; self.rate = rate; self.method = method; self.confidence = confidence
        self.referenceTrackID = referenceTrackID; self.explanation = explanation
    }
}

public struct FusionInputs: Sendable {
    /// Placements decided by the caller. They take precedence over everything but the timeline
    /// reference, and a derived recording without its own follows its original's. Pass the rate
    /// here rather than scaling segment times.
    public var placements: [UUID: TrackPlacement] = [:]
    /// Measured by `MeetingAudioAlignment` / `AudioAligner` (normally `Meeting.audioAlignments`).
    public var audioAlignments: [TrackAudioAlignment]
    /// Per-recording signal-to-noise profiles from `AudioAligner.signalQuality(of:)`.
    public var signalQuality: [UUID: SignalQualityProfile]
    /// Wall-clock recording starts, used only when sound and text can't place a recording.
    public var recordingStartDates: [UUID: Date]
    /// The meeting's speakers, so existing identities are reused.
    public var speakers: [Speaker]
    /// Speakers the person renamed: their labels are never remapped to someone else.
    public var namedSpeakerIDs: Set<String>
    public var options: FusionOptions
    public init(placements: [UUID: TrackPlacement] = [:], audioAlignments: [TrackAudioAlignment] = [],
                signalQuality: [UUID: SignalQualityProfile] = [:], recordingStartDates: [UUID: Date] = [:],
                speakers: [Speaker] = [], namedSpeakerIDs: Set<String> = [], options: FusionOptions = .init()) {
        self.placements = placements; self.audioAlignments = audioAlignments; self.signalQuality = signalQuality
        self.recordingStartDates = recordingStartDates; self.speakers = speakers; self.namedSpeakerIDs = namedSpeakerIDs
        self.options = options
    }

    /// Everything a meeting already stores: audio alignments, speakers, and renamed speakers.
    public init(meeting: Meeting, placements: [UUID: TrackPlacement] = [:], signalQuality: [UUID: SignalQualityProfile] = [:],
                recordingStartDates: [UUID: Date] = [:], options: FusionOptions = .init()) {
        let renamed = Set(meeting.revisions.filter { $0.field.hasPrefix("speaker:") }.map { String($0.field.dropFirst(8)) })
        self.init(placements: placements, audioAlignments: meeting.audioAlignments ?? [], signalQuality: signalQuality,
                  recordingStartDates: recordingStartDates, speakers: meeting.speakers, namedSpeakerIDs: renamed, options: options)
    }
}
