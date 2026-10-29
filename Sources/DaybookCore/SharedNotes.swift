import Foundation

// Notes and bookmarks shared live between two devices recording one conversation (docs/multipoint.md,
// "Notes and bookmarks during a shared recording"). A paragraph of the notes is identified by its
// anchor ID (`TimedNote.id`) and a bookmark by its `Highlight.id` on every device, so the copy that
// travels over the local link and the copy that arrives through sync later are the same item, and the
// library's merge (by ID) keeps it once.

/// One paragraph of the notes as it travels between devices: written or edited (its text now), or
/// deleted. `time` is where the device that wrote it files it in the conversation.
public struct SharedNote: Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var time: TimeInterval?
    public var deleted: Bool

    public init(id: UUID, text: String, time: TimeInterval?, deleted: Bool = false) {
        self.id = id
        self.text = text
        self.time = time
        self.deleted = deleted
    }
}

extension NoteTimeline {
    /// One anchor per nonempty paragraph of `text`, in order: the saved anchors where they match, new
    /// ones (untimed) where they don't.
    public static func anchors(_ anchors: [TimedNote]?, text: String) -> [TimedNote] {
        reconcile(previous: anchors ?? [], text: text, captureTime: nil)
    }

    /// The paragraphs that changed between two versions of the notes, by anchor ID: one written or
    /// edited, with its text now, and one deleted. A paragraph whose text didn't change isn't a change,
    /// whatever its time.
    public static func changes(from old: [TimedNote], to new: [TimedNote]) -> [SharedNote] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        var changes: [SharedNote] = []
        for note in new where before[note.id]?.text != note.text {
            changes.append(SharedNote(id: note.id, text: note.text, time: note.time))
        }
        for note in old where !after.contains(note.id) {
            changes.append(SharedNote(id: note.id, text: note.text, time: note.time, deleted: true))
        }
        return changes
    }

    /// The notes with one paragraph written, edited, or deleted by its ID, the rest of the text as it
    /// was (blank lines and all). An edited paragraph keeps its place; a new one goes at the end, so a
    /// paragraph arriving while the person types moves nothing they're writing. Returns the text and
    /// its anchors, one per nonempty paragraph.
    public static func applying(_ note: SharedNote, to text: String, anchors saved: [TimedNote]?) -> (text: String, anchors: [TimedNote]) {
        var anchors = Self.anchors(saved, text: text)
        var lines = text.components(separatedBy: "\n")
        let paragraphs = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // One paragraph is one line: line breaks inside what arrives are spaces here.
        let clean = note.text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let index = anchors.firstIndex { $0.id == note.id }
        if note.deleted || clean.isEmpty {
            guard let index, index < paragraphs.count else { return (text, anchors) }
            lines.remove(at: paragraphs[index])
            anchors.remove(at: index)
            return (lines.joined(separator: "\n"), anchors)
        }
        if let index, index < paragraphs.count {
            lines[paragraphs[index]] = clean
            anchors[index].text = clean
            anchors[index].time = note.time.flatMap { $0.isFinite ? $0 : nil } ?? anchors[index].time
            return (lines.joined(separator: "\n"), anchors)
        }
        var updated = text
        if !updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated = "" }
        updated += clean
        anchors.append(TimedNote(id: note.id, time: note.time, text: clean))
        return (updated, anchors)
    }
}

extension Meeting {
    /// A paragraph written, edited, or deleted on another device recording this conversation, applied
    /// by its ID (`NoteTimeline.applying`). Its time is kept as that device filed it.
    public mutating func applySharedNote(_ note: SharedNote) {
        let applied = NoteTimeline.applying(note, to: notes, anchors: timedNotes)
        guard applied.text != notes || applied.anchors != (timedNotes ?? []) else { return }
        notes = applied.text
        timedNotes = applied.anchors
        updatedAt = Date()
    }

    /// A bookmark another device recording this conversation made, kept by its ID (at most once).
    @discardableResult
    public mutating func addSharedBookmark(_ mark: Highlight) -> Bool {
        guard mark.time.isFinite, !highlights.contains(where: { $0.id == mark.id }) else { return false }
        highlights.append(mark)
        updatedAt = Date()
        return true
    }

    /// A bookmark's label changed on another device, or it was deleted there.
    public mutating func applySharedBookmarkChange(id: UUID, label: String?, deleted: Bool) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        if deleted { highlights.remove(at: index) }
        else if let label, highlights[index].text != label { highlights[index].text = label }
        else { return }
        updatedAt = Date()
    }
}
