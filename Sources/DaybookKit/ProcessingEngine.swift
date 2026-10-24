import DaybookCore
import DaybookDevices
import Foundation

/// How far processing has got, for a progress line.
public struct ProcessingProgress: Sendable, Equatable {
    public var fraction: Double
    public var message: String
    public init(fraction: Double, message: String) { self.fraction = fraction; self.message = message }
}

public typealias ProcessingProgressHandler = @Sendable (ProcessingProgress) -> Void

/// One recording to transcribe.
public struct TrackProcessingInput: Sendable {
    public var meetingID: UUID
    public var track: RecordingTrack
    /// Where its bytes are (`LibraryController.audioURL`).
    public var audioURL: URL
    public var mode: ProcessingRequest.Mode
    /// The recording's latest transcript run. `speakerRefresh` identifies speakers again from it
    /// instead of transcribing.
    public var previousTranscript: TrackTranscript?
    /// Words to spell the way the person does.
    public var vocabulary: [String]

    public init(meetingID: UUID, track: RecordingTrack, audioURL: URL, mode: ProcessingRequest.Mode,
                previousTranscript: TrackTranscript? = nil, vocabulary: [String] = []) {
        self.meetingID = meetingID; self.track = track; self.audioURL = audioURL; self.mode = mode
        self.previousTranscript = previousTranscript; self.vocabulary = vocabulary
    }
}

/// What processing one recording produced: a new transcript run and the speakers it found.
public struct TrackProcessingOutput: Sendable {
    /// The run, its passages labelled with speaker IDs namespaced to it.
    public var transcript: TrackTranscript
    /// One per speaker label in the run. `Meeting.apply` names them ("Speaker 3") and may match
    /// them to speakers already in the conversation.
    public var speakers: [Speaker]
    /// The voice-profile model, when speaker detection produced reusable profiles.
    public var speakerEmbeddingModelID: String?
    /// The recording's measured length.
    public var duration: Double
    /// What the person should know (speaker detection failed, an older transcript lacked word timings).
    public var notices: [String]

    public init(transcript: TrackTranscript, speakers: [Speaker], speakerEmbeddingModelID: String? = nil,
                duration: Double, notices: [String] = []) {
        self.transcript = transcript; self.speakers = speakers; self.speakerEmbeddingModelID = speakerEmbeddingModelID
        self.duration = duration; self.notices = notices
    }
}

/// A conversation's new summary, with the terms it suggests for the vocabulary.
public struct SummaryProcessingOutput: Sendable {
    public var summary: MeetingSummary
    public var suggestedTerms: [String]
    public var warnings: [String]

    public init(summary: MeetingSummary, suggestedTerms: [String] = [], warnings: [String] = []) {
        self.summary = summary; self.suggestedTerms = suggestedTerms; self.warnings = warnings
    }
}

/// Everything one pass over a conversation produced (`ProcessingEngine.process`).
public struct ProcessingOutput: Sendable {
    /// The conversation with the new runs, speakers, fusion, and summary applied.
    public var meeting: Meeting
    public var transcripts: [TrackTranscript]
    public var speakers: [Speaker]
    /// Nil when nothing was said, so there was nothing to summarize.
    public var summary: MeetingSummary?
    public var suggestedTerms: [String]
    public var notices: [String]
}

/// Turns recordings into transcripts, speakers, and a summary. The Mac's local models implement it
/// (`InferenceProcessingEngine` in DaybookIntelligence); the iPhone registers none, so its requests
/// wait for a Mac. An on-device engine later is another conformance, not a restructuring.
///
/// Engines are configured when they're made (models, speaker options) and work on values: they
/// never touch the library. Callers apply results with `Meeting.apply(_:matching:allowSameSource:)`
/// and `Meeting.setSummary(_:)`, or use `process(_:tracks:…)` for the whole pass.
public protocol ProcessingEngine: Sendable {
    /// Transcribes one recording and identifies its speakers.
    func transcribe(_ input: TrackProcessingInput, progress: @escaping ProcessingProgressHandler) async throws -> TrackProcessingOutput
    /// Summarizes a conversation from its transcript, notes, and bookmarks, with a template (nil for Automatic).
    func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                   progress: @escaping ProcessingProgressHandler) async throws -> SummaryProcessingOutput
}

extension ProcessingEngine {
    /// One whole pass for a device without the Mac's queue: each transcribable recording `mode`
    /// calls for, fusion, then a summary. `tracks` pairs recordings with their audio
    /// (`LibraryController.audioURL`). Nothing is saved; the caller applies `meeting`.
    public func process(_ meeting: Meeting, tracks: [(track: RecordingTrack, url: URL)], mode: ProcessingRequest.Mode,
                        template: SummaryTemplate?, vocabulary: [String] = [], matching: SpeakerMatchingConfiguration? = nil,
                        progress: @escaping ProcessingProgressHandler = { _ in }) async throws -> ProcessingOutput {
        var working = meeting
        var transcripts: [TrackTranscript] = [], speakers: [Speaker] = [], notices: [String] = []
        if mode != .summaryOnly {
            for (track, url) in tracks where meeting.transcribableTracks.contains(where: { $0.id == track.id }) {
                try Task.checkCancellation()
                let previous = working.transcripts.filter { $0.trackID == track.id }.max { $0.createdAt < $1.createdAt }
                if mode == .newAudio && previous != nil { continue }
                let output = try await transcribe(TrackProcessingInput(meetingID: meeting.id, track: track, audioURL: url, mode: mode,
                                                                       previousTranscript: previous, vocabulary: vocabulary), progress: progress)
                let known = Set(working.speakers.map(\.id))
                working.apply(output, matching: matching, allowSameSource: previous != nil)
                transcripts.append(output.transcript)
                speakers += working.speakers.filter { !known.contains($0.id) }
                notices += output.notices
            }
            let fusion = SourceFusion.fuse(working)
            working.applyFusion(fusion.fusion)
            working.applyPlacements(fusion.settled)
        }
        try Task.checkCancellation()
        guard !MeetingEvidence.transcript(working).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ProcessingOutput(meeting: working, transcripts: transcripts, speakers: speakers, summary: nil, suggestedTerms: [], notices: notices)
        }
        let summary = try await summarize(working, template: template, vocabulary: vocabulary, progress: progress)
        working.setSummary(summary.summary)
        return ProcessingOutput(meeting: working, transcripts: transcripts, speakers: speakers, summary: working.summary,
                                suggestedTerms: summary.suggestedTerms, notices: notices + summary.warnings)
    }
}

extension Meeting {
    /// Adds one recording's processing result: its transcript run; its speakers, numbered after the
    /// conversation's ("Speaker 3") and, with `matching`, matched by voice to speakers already here
    /// so their passages carry those names; and the recording's measured length. `allowSameSource`
    /// lets a new run of a recording match that recording's earlier speakers.
    public mutating func apply(_ output: TrackProcessingOutput, matching: SpeakerMatchingConfiguration?, allowSameSource: Bool) {
        var segments = output.transcript.segments
        let labels = Set(segments.compactMap(\.speakerID)).sorted()
        let incoming = labels.enumerated().map { index, label in
            var speaker = output.speakers.first { $0.id == label } ?? Speaker(id: label, name: "")
            speaker.name = "Speaker \(speakers.count + index + 1)"
            speaker.sourceTrackID = speaker.sourceTrackID ?? output.transcript.trackID
            return speaker
        }
        if let matching, output.speakerEmbeddingModelID != nil {
            let matches = SpeakerMatcher.match(incoming: incoming, in: self, configuration: matching, allowSameSource: allowSameSource)
            speakerMatches = (speakerMatches ?? []) + matches
            let accepted = Dictionary(matches.compactMap { match -> (String, String)? in
                guard let target = match.targetSpeakerID else { return nil }; return (match.sourceSpeakerID, target)
            }, uniquingKeysWith: { first, _ in first })
            for index in segments.indices {
                if let speaker = segments[index].speakerID, let target = accepted[speaker] { segments[index].speakerID = target }
            }
        }
        speakers += incoming
        var transcript = output.transcript
        transcript.segments = segments
        transcripts.append(transcript)
        if let index = tracks.firstIndex(where: { $0.id == transcript.trackID }) { tracks[index].duration = output.duration }
    }
}
