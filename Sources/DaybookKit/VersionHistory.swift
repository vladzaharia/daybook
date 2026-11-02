import DaybookCore
import Foundation

/// Puts back the text from before one change. The change it makes is itself recorded, so the
/// text it replaces stays in Version History.
public enum RevisionRestore {
    /// True when the change can be undone and the earlier text differs from what's there now.
    public static func canRestore(_ revision: MeetingRevision, in meeting: Meeting) -> Bool {
        switch revision.kind {
        case .notes: return meeting.notes != revision.oldValue
        case .segment(let id):
            guard let segment = meeting.unifiedTranscript.first(where: { $0.id == id }) else { return false }
            return segment.text != revision.oldValue
        case .speaker(let id):
            guard let speaker = meeting.speakers.first(where: { $0.id == id }) else { return false }
            return speaker.name != revision.oldValue && !revision.oldValue.trimmingCharacters(in: .whitespaces).isEmpty
        case .summary:
            guard let summary = decodedSummary(revision.oldValue) else { return false }
            return summary != meeting.summary
        case .photo(let id):
            // A deleted photo can be put back; adding one isn't undone from here (delete it instead).
            guard revision.newValue == "removed", let photo = meeting.photo(id) else { return false }
            return photo.isRemoved
        case .bookmark: return meeting.canRestoreBookmark(revision)
        case .photoCaption, .correctionTransfer, .source, .sync, .unknown: return false
        }
    }

    public static func apply(_ revision: MeetingRevision, to meeting: inout Meeting) {
        guard canRestore(revision, in: meeting) else { return }
        switch revision.kind {
        case .notes:
            let previous = meeting.timedNotes ?? NoteTimeline.reconcile(previous: [], text: meeting.notes, captureTime: nil)
            meeting.timedNotes = NoteTimeline.reconcile(previous: previous, text: revision.oldValue, captureTime: nil)
            meeting.setNotes(revision.oldValue)
        case .segment(let id): meeting.correctSegment(id: id, text: revision.oldValue)
        case .speaker(let id): meeting.renameSpeaker(id: id, name: revision.oldValue)
        case .summary:
            if let summary = decodedSummary(revision.oldValue) { meeting.setSummary(summary) }
        case .photo(let id): meeting.restorePhoto(id)
        case .bookmark: meeting.restoreBookmark(revision)
        case .photoCaption, .correctionTransfer, .source, .sync, .unknown: break
        }
    }

    private static func decodedSummary(_ value: String) -> MeetingSummary? {
        value.data(using: .utf8).flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: $0) }
    }
}

/// How Version History describes one change.
public enum RevisionText {
    public static func title(_ revision: MeetingRevision, in meeting: Meeting) -> String {
        switch revision.kind {
        case .notes: return "Notes edited"
        case .segment: return "Passage corrected"
        case .speaker: return "Speaker renamed"
        case .summary: return hasBefore(revision) ? "Summary replaced" : "Summary written"
        case .correctionTransfer: return "Correction reviewed"
        case .sync: return "Edited on two devices"
        case .source: return revision.newValue
        case .photo:
            switch revision.newValue {
            case "added": return "Photo added"
            case "removed": return "Photo deleted"
            default: return "Photo put back"
            }
        case .photoCaption: return "Photo caption edited"
        case .bookmark: return revision.newValue == MeetingRevision.bookmarkRemoved ? "Bookmark deleted" : "Bookmark put back"
        case .unknown: return "Edited"
        }
    }

    /// Whether there was text before the change to show. A conversation's first summary was
    /// written, not replaced: it shows on its own, with no empty Before (and nothing to restore).
    public static func hasBefore(_ revision: MeetingRevision) -> Bool {
        !(revision.kind == .summary && revision.oldValue.isEmpty)
    }

    public static func subject(_ revision: MeetingRevision, in meeting: Meeting) -> String {
        switch revision.kind {
        case .segment(let id):
            if let segment = meeting.unifiedTranscript.first(where: { $0.id == id }) {
                return "Passage at \(TimeLabel.short(segment.start))" + (meeting.speakerName(segment.speakerID).map { " · \($0)" } ?? "")
            }
        case .speaker: return "\(revision.oldValue) → \(revision.newValue)"
        case .bookmark:
            if let bookmark = revision.bookmark {
                let time = "Bookmark at \(TimeLabel.short(meeting.alignedTime(for: bookmark) ?? bookmark.time))"
                return bookmark.text.isEmpty ? time : "\(time) · \(bookmark.text)"
            }
        default: break
        }
        return title(revision, in: meeting)
    }

    /// One outline family, like the search results' location glyphs.
    public static func symbol(_ revision: MeetingRevision) -> String {
        switch revision.kind {
        case .notes: return "note.text"
        case .segment: return "pencil"
        case .speaker: return "person"
        case .summary: return "text.alignleft"
        case .correctionTransfer: return "checkmark.circle"
        case .source: return "waveform"
        case .photo: return "photo"
        case .photoCaption: return "text.below.photo"
        case .bookmark: return "bookmark"
        case .sync, .unknown: return "arrow.triangle.branch"
        }
    }

    /// A change's text, plain. Summaries are stored as JSON: their words show, without Markdown's marks.
    public static func readable(_ value: String, field: String) -> String {
        if let summary = summary(value, field: field) { return String(text(of: summary).characters) }
        switch RevisionField(rawValue: field) {
        case .correctionTransfer:
            if value == "dismissed" { return "Kept in Version History only" }
            if value.hasPrefix("applied:") { return "Applied to a passage in the new transcript" }
        case .bookmark:
            // The entry keeps the whole bookmark: its words show, and its time is in the subject.
            if value == MeetingRevision.bookmarkRemoved { return "Deleted" }
            if let bookmark = MeetingRevision.bookmark(from: value) { return bookmark.text }
        default: break
        }
        return value
    }

    /// A change's text as Version History shows it. A summary's Markdown is drawn as the page draws it:
    /// bold and italics, "•" for bullets, headings bold, no marks left, and links dropped
    /// (`ModelText.inlineMarkdown`). Other text shows as it was written.
    public static func styled(_ value: String, field: String) -> AttributedString {
        if let summary = summary(value, field: field) { return text(of: summary) }
        return AttributedString(readable(value, field: field))
    }

    /// A summary change, or the other version two devices' summaries left in history.
    private static func summary(_ value: String, field: String) -> MeetingSummary? {
        let kind = RevisionField(rawValue: field)
        guard kind == .summary || kind == .sync(RevisionField.summary.rawValue), let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    /// The overview, then each section's heading over its body.
    private static func text(of summary: MeetingSummary) -> AttributedString {
        var parts = [ModelText.inlineMarkdown(summary.overview)]
        for section in summary.sections {
            parts.append(bold(ModelText.inlineMarkdown(section.heading)) + AttributedString("\n") + body(section.body))
        }
        return parts.dropFirst().reduce(parts[0]) { $0 + AttributedString("\n\n") + $1 }
    }

    /// A section's lines as the page reads them: bullets as "•", numbered items kept, subheadings bold.
    private static func body(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: .newlines).map { raw -> AttributedString in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                return AttributedString("• ") + ModelText.inlineMarkdown(String(line[marker.upperBound...]))
            }
            if let marker = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                return AttributedString(String(line[..<marker.upperBound])) + ModelText.inlineMarkdown(String(line[marker.upperBound...]))
            }
            if let marker = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                return bold(ModelText.inlineMarkdown(String(line[marker.upperBound...])))
            }
            return ModelText.inlineMarkdown(line)
        }
        return lines.dropFirst().reduce(lines.first ?? AttributedString()) { $0 + AttributedString("\n") + $1 }
    }

    private static func bold(_ text: AttributedString) -> AttributedString {
        var text = text
        text[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] = .stronglyEmphasized
        return text
    }
}

/// What changed between two versions of a text, word by word, for both apps' Version History. Whitespace
/// stays with the word before it, so the text reads unchanged.
public enum WordChanges {
    /// Above this many words a diff stops being readable, so both versions show plain.
    public static let limit = 4_000

    public static func tokens(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex, index = text.startIndex, inSpace = false
        while index < text.endIndex {
            let space = text[index].isWhitespace
            if !space && inSpace && start < index { result.append(text[start..<index]); start = index }
            inSpace = space
            index = text.index(after: index)
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    /// Indices of removed tokens in `old` and inserted tokens in `new`, compared ignoring trailing whitespace.
    public static func changes(old: [Substring], new: [Substring]) -> (removed: IndexSet, inserted: IndexSet) {
        let difference = new.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .difference(from: old.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var removed = IndexSet(), inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        return (removed, inserted)
    }

    /// `old` with its removed words given `removed`, and `new` with its inserted words given `inserted`. The
    /// texts' own attributes (a summary's bold) stay; only the words are marked, not the space after them.
    public static func marked(old: AttributedString, new: AttributedString, removed: AttributeContainer,
                              inserted: AttributeContainer) -> (old: AttributedString, new: AttributedString) {
        let before = tokens(String(old.characters)), after = tokens(String(new.characters))
        guard before.count + after.count <= limit, !before.isEmpty, !after.isEmpty else { return (old, new) }
        let changes = changes(old: before, new: after)
        return (mark(old, tokens: before, at: changes.removed, with: removed), mark(new, tokens: after, at: changes.inserted, with: inserted))
    }

    private static func mark(_ text: AttributedString, tokens: [Substring], at marked: IndexSet, with attributes: AttributeContainer) -> AttributedString {
        var result = AttributedString()
        var index = text.startIndex
        for (offset, token) in tokens.enumerated() {
            let end = text.characters.index(index, offsetBy: token.count)
            if marked.contains(offset) {
                let wordEnd = text.characters.index(index, offsetBy: token.trimmingCharacters(in: .whitespacesAndNewlines).count)
                var word = AttributedString(text[index..<wordEnd])
                word.mergeAttributes(attributes)
                result += word
                result += text[wordEnd..<end]
            } else {
                result += text[index..<end]
            }
            index = end
        }
        return result
    }
}
