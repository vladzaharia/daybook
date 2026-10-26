import DaybookCore
import Foundation

/// Puts back the text from before one change. The change it makes is itself recorded, so the
/// text it replaces stays in Version History.
public enum RevisionRestore {
    private static func kind(_ revision: MeetingRevision) -> Substring { revision.field.split(separator: ":").first ?? Substring(revision.field) }
    private static func id(_ revision: MeetingRevision) -> String { String(revision.field.drop { $0 != ":" }.dropFirst()) }

    /// True when the change can be undone and the earlier text differs from what's there now.
    public static func canRestore(_ revision: MeetingRevision, in meeting: Meeting) -> Bool {
        switch kind(revision) {
        case "notes": return meeting.notes != revision.oldValue
        case "segment":
            guard let uuid = UUID(uuidString: id(revision)), let segment = meeting.unifiedTranscript.first(where: { $0.id == uuid }) else { return false }
            return segment.text != revision.oldValue
        case "speaker":
            guard let speaker = meeting.speakers.first(where: { $0.id == id(revision) }) else { return false }
            return speaker.name != revision.oldValue && !revision.oldValue.trimmingCharacters(in: .whitespaces).isEmpty
        case "summary":
            guard let summary = decodedSummary(revision.oldValue) else { return false }
            return summary != meeting.summary
        case "photo":
            // A deleted photo can be put back; adding one isn't undone from here (delete it instead).
            guard revision.newValue == "removed", let uuid = UUID(uuidString: id(revision)), let photo = meeting.photo(uuid) else { return false }
            return photo.isRemoved
        default: return false
        }
    }

    public static func apply(_ revision: MeetingRevision, to meeting: inout Meeting) {
        guard canRestore(revision, in: meeting) else { return }
        switch kind(revision) {
        case "notes":
            let previous = meeting.timedNotes ?? NoteTimeline.reconcile(previous: [], text: meeting.notes, captureTime: nil)
            meeting.timedNotes = NoteTimeline.reconcile(previous: previous, text: revision.oldValue, captureTime: nil)
            meeting.setNotes(revision.oldValue)
        case "segment":
            if let uuid = UUID(uuidString: id(revision)) { meeting.correctSegment(id: uuid, text: revision.oldValue) }
        case "speaker":
            meeting.renameSpeaker(id: id(revision), name: revision.oldValue)
        case "summary":
            if let summary = decodedSummary(revision.oldValue) { meeting.setSummary(summary) }
        case "photo":
            if let uuid = UUID(uuidString: id(revision)) { meeting.restorePhoto(uuid) }
        default: break
        }
    }

    private static func decodedSummary(_ value: String) -> MeetingSummary? {
        value.data(using: .utf8).flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: $0) }
    }
}

/// How Version History describes one change.
public enum RevisionText {
    private static func kind(_ revision: MeetingRevision) -> String { revision.field.split(separator: ":").first.map(String.init) ?? revision.field }

    public static func title(_ revision: MeetingRevision, in meeting: Meeting) -> String {
        switch kind(revision) {
        case "notes": return "Notes edited"
        case "segment": return "Passage corrected"
        case "speaker": return "Speaker renamed"
        case "summary": return "Summary replaced"
        case "correction-transfer": return "Correction reviewed"
        case "sync": return "Edited on two Macs"
        case "source": return revision.newValue
        case "photo":
            switch revision.newValue {
            case "added": return "Photo added"
            case "removed": return "Photo deleted"
            default: return "Photo put back"
            }
        case "photo-caption": return "Photo caption edited"
        default: return "Edited"
        }
    }

    public static func subject(_ revision: MeetingRevision, in meeting: Meeting) -> String {
        if kind(revision) == "segment", let id = UUID(uuidString: String(revision.field.dropFirst("segment:".count))),
           let segment = meeting.unifiedTranscript.first(where: { $0.id == id }) {
            return "Passage at \(TimeLabel.short(segment.start))" + (meeting.speakerName(segment.speakerID).map { " · \($0)" } ?? "")
        }
        if kind(revision) == "speaker" { return "\(revision.oldValue) → \(revision.newValue)" }
        return title(revision, in: meeting)
    }

    /// One outline family, like the search results' location glyphs.
    public static func symbol(_ revision: MeetingRevision) -> String {
        switch kind(revision) {
        case "notes": return "note.text"
        case "segment": return "pencil"
        case "speaker": return "person"
        case "summary": return "text.alignleft"
        case "correction-transfer": return "checkmark.circle"
        case "source": return "waveform"
        case "photo": return "photo"
        case "photo-caption": return "text.below.photo"
        default: return "arrow.triangle.branch"
        }
    }

    /// Summaries are stored as JSON; show their text instead.
    public static func readable(_ value: String, field: String) -> String {
        if field == "summary", let data = value.data(using: .utf8), let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
            return ([summary.overview] + summary.sections.map { "\($0.heading)\n\($0.body)" }).joined(separator: "\n\n")
        }
        if field.hasPrefix("correction-transfer") {
            if value == "dismissed" { return "Kept in Version History only" }
            if value.hasPrefix("applied:") { return "Applied to a passage in the new transcript" }
        }
        return value
    }
}
