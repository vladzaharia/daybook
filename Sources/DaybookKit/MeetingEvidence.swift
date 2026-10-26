import DaybookCore
import Foundation

/// User annotations keep their own provenance and are never presented as spoken words.
public enum MeetingEvidence {
    public static func transcript(_ meeting: Meeting) -> String {
        meeting.unifiedTranscript.map { segment in
            let name = meeting.speakers.first { $0.id == segment.speakerID }?.name ?? "Unknown speaker"
            return "[\(TimeLabel.format(segment.start))] \(name): \(segment.text)"
        }.joined(separator: "\n")
    }

    public static func notes(_ meeting: Meeting) -> String {
        let anchors = (meeting.timedNotes ?? []).map { note in
            let position = note.time.map { "written at meeting time \(TimeLabel.format($0))" } ?? "written outside recording; time unknown"
            return "[USER NOTE — \(position)] \(note.text)"
        }.joined(separator: "\n")
        return "User's original notes (intent and context, not a spoken quotation):\n\(meeting.notes)"
            + (anchors.isEmpty ? "" : "\n\nTiming of those same notes (not additional evidence):\n\(anchors)")
    }

    public static func highlights(_ meeting: Meeting) -> String? {
        let contexts = meeting.highlightContexts()
        guard !contexts.isEmpty else { return nil }
        return contexts.map { context in
            let basis = context.isAligned ? "meeting timeline" : "unaligned source-local timeline; do not imply overlap with other sources"
            let speech = context.speechContext.map { "[\(TimeLabel.format($0.start))] \($0.text)" }.joined(separator: "\n")
            return """
            MARKED MOMENT [\(TimeLabel.format(context.markerTime))], \(context.sourceName), \(basis)
            User annotation: \(context.highlight.text)
            Context window: \(TimeLabel.format(context.rangeStart))–\(TimeLabel.format(context.rangeEnd)).
            Recorded speech: \(speech.isEmpty ? "No transcribed speech is available for this marker. Do not invent details." : speech)
            """
        }.joined(separator: "\n\n")
    }
}

public enum MeetingTimelineItem: Identifiable {
    case speech(TranscriptSegment), note(TimedNote), highlight(Highlight, Double)
    /// A photo at the moment it was taken (`Meeting.timelineTime(of:)`).
    case photo(MeetingPhoto, Double)
    public var id: String {
        switch self {
        case .speech(let value): return "speech:\(value.id)"
        case .note(let value): return "note:\(value.id)"
        case .highlight(let value, _): return "highlight:\(value.id)"
        case .photo(let value, _): return "photo:\(value.id)"
        }
    }
    public var time: Double {
        switch self {
        case .speech(let value): return value.start
        case .note(let value): return value.time ?? 0
        case .highlight(_, let value): return value
        case .photo(_, let value): return value
        }
    }
    public static func items(in meeting: Meeting) -> [Self] {
        let speech = meeting.unifiedTranscript.map(Self.speech)
        let notes = (meeting.timedNotes ?? []).filter { $0.time != nil }.map(Self.note)
        let highlights = meeting.highlights.compactMap { value in meeting.alignedTime(for: value).map { Self.highlight(value, $0) } }
        let photos = meeting.visiblePhotos.compactMap { value in meeting.timelineTime(of: value).map { Self.photo(value, $0) } }
        return (speech + notes + highlights + photos).sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }
}

public struct MeetingPlaybackPosition {
    public let trackID: UUID
    public let seconds: Double
    public static func resolve(_ meetingSeconds: Double, in meeting: Meeting) -> Self? {
        guard meetingSeconds.isFinite else { return nil }
        for track in meeting.tracks {
            let alignment = meeting.alignmentReports.first { $0.trackID == track.id }
            if alignment?.method == .unaligned { continue }
            guard alignment != nil || track.offset != nil else { continue }
            let rate = alignment?.rate ?? 1, offset = alignment?.offset ?? track.offset ?? 0
            guard rate.isFinite, rate > 0, offset.isFinite else { continue }
            let seconds = (meetingSeconds - offset) / rate
            guard seconds >= 0, seconds <= (track.duration ?? .infinity) else { continue }
            return .init(trackID: track.id, seconds: seconds)
        }
        return nil
    }
}

// Automatic classification remains separate from the user's template selection.
