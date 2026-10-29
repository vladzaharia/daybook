import DaybookCore
import Foundation

/// The notes and bookmarks of one shared recording, kept in step with the other devices recording it
/// over the local link (docs/multipoint.md, "Notes and bookmarks during a shared recording"). It holds
/// what this device last shared or was sent, by ID, so a change made here goes out once and one that
/// arrived is never sent back: the device diffs its notes against it after every change, and records
/// what arrives before applying it.
///
/// Notes and bookmarks that were there before the shared recording began aren't sent: sync carries them.
@MainActor
public final class SharedNotesTracker {
    public private(set) var conversationID: UUID?
    /// Each shared paragraph's text, by anchor ID.
    private var notes: [UUID: String] = [:]
    /// Each shared bookmark's label, by ID.
    private var bookmarks: [UUID: String] = [:]
    /// The latest change applied to each item, on this device's clock: an older one arriving late loses.
    private var changedAt: [UUID: Date] = [:]
    /// Paragraphs that just arrived, by when: an editor writing its text back a moment later may not
    /// have shown them yet (`keepingArrivals`).
    private var arrived: [UUID: Date] = [:]

    /// How long a paragraph that arrived is kept from an editor that may not have shown it yet.
    public static let arrivalGrace: TimeInterval = 1

    public init() {}

    public var isActive: Bool { conversationID != nil }

    /// Starts following a shared recording, with what its notes and bookmarks hold now.
    public func begin(_ id: UUID, notes anchors: [TimedNote], bookmarks highlights: [Highlight]) {
        guard conversationID != id else { return }
        conversationID = id
        notes = Dictionary(anchors.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        bookmarks = Dictionary(highlights.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        changedAt = [:]
        arrived = [:]
    }

    public func end() {
        conversationID = nil
        notes = [:]
        bookmarks = [:]
        changedAt = [:]
        arrived = [:]
    }

    /// The text an editor wrote back, with any paragraph that arrived a moment ago and isn't in it put
    /// back at the end: the editor took its text before the paragraph reached it, so it can't have
    /// deleted it. `anchors` are the notes as they stand (the paragraph's text, by its ID).
    public func keepingArrivals(_ text: String, anchors: [TimedNote], at now: Date = Date()) -> String {
        arrived = arrived.filter { now.timeIntervalSince($0.value) < Self.arrivalGrace }
        guard !arrived.isEmpty else { return text }
        let present = Set(text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var kept = text
        for anchor in anchors where arrived[anchor.id] != nil && !present.contains(anchor.text) {
            if !kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !kept.hasSuffix("\n") { kept += "\n" }
            kept += anchor.text
        }
        return kept
    }

    // MARK: Changes made here

    /// The notes as they stand here now: paragraphs written, edited, or deleted since they were last
    /// shared, to send. Remembered as shared.
    public func notesChanged(_ anchors: [TimedNote], at now: Date = Date()) -> [SharedNote] {
        guard isActive else { return [] }
        var changes: [SharedNote] = []
        var seen = Set<UUID>()
        for anchor in anchors where seen.insert(anchor.id).inserted {
            guard notes[anchor.id] != anchor.text else { continue }
            notes[anchor.id] = anchor.text
            changedAt[anchor.id] = now
            changes.append(SharedNote(id: anchor.id, text: anchor.text, time: anchor.time))
        }
        for (id, text) in notes where !seen.contains(id) {
            notes[id] = nil
            changedAt[id] = now
            changes.append(SharedNote(id: id, text: text, time: nil, deleted: true))
        }
        return changes
    }

    /// The bookmarks as they stand here now: ones made since (to send whole), and shared ones whose
    /// label changed or that were deleted. Only bookmarks on the conversation's timeline (no track) are
    /// made here; one a recording brought with it travels through sync.
    public func bookmarksChanged(_ highlights: [Highlight], at now: Date = Date())
        -> (made: [Highlight], changed: [Highlight], deleted: [UUID]) {
        guard isActive else { return ([], [], []) }
        var made: [Highlight] = [], changed: [Highlight] = []
        var seen = Set<UUID>()
        for mark in highlights where seen.insert(mark.id).inserted {
            if let label = bookmarks[mark.id] {
                guard label != mark.text else { continue }
                bookmarks[mark.id] = mark.text
                changedAt[mark.id] = now
                changed.append(mark)
            } else if mark.trackID == nil {
                bookmarks[mark.id] = mark.text
                changedAt[mark.id] = now
                made.append(mark)
            }
        }
        var deleted: [UUID] = []
        for id in bookmarks.keys where !seen.contains(id) {
            bookmarks[id] = nil
            changedAt[id] = now
            deleted.append(id)
        }
        return (made, changed, deleted.sorted { $0.uuidString < $1.uuidString })
    }

    /// A bookmark made here that was sent on its own (the moment it was made).
    public func bookmarkShared(_ mark: Highlight, at now: Date = Date()) {
        guard isActive else { return }
        bookmarks[mark.id] = mark.text
        changedAt[mark.id] = now
    }

    // MARK: Changes that arrived

    /// A paragraph another device wrote, edited, or deleted (`changedAt` on this device's clock):
    /// whether to apply it here. A change older than the last one applied to that paragraph is dropped.
    /// Remembered as shared, so it isn't sent back.
    public func received(_ note: SharedNote, changedAt when: Date) -> Bool {
        guard isActive else { return false }
        if let last = changedAt[note.id], last > when { return false }
        changedAt[note.id] = when
        let text = Self.paragraph(note.text)
        notes[note.id] = note.deleted || text.isEmpty ? nil : text
        arrived[note.id] = note.deleted || text.isEmpty ? nil : Date()
        return true
    }

    /// A bookmark another device made: whether to add it here (not already known).
    public func received(bookmark mark: Highlight, at when: Date) -> Bool {
        guard isActive, bookmarks[mark.id] == nil else { return false }
        bookmarks[mark.id] = mark.text
        changedAt[mark.id] = when
        return true
    }

    /// A bookmark's label changed, or it was deleted, on another device: whether to apply it here.
    public func received(bookmarkChange id: UUID, label: String?, deleted: Bool, changedAt when: Date) -> Bool {
        guard isActive else { return false }
        if let last = changedAt[id], last > when { return false }
        changedAt[id] = when
        if deleted { bookmarks[id] = nil } else if let label { bookmarks[id] = label }
        return true
    }

    /// A paragraph as `NoteTimeline.applying` keeps it: one line, trimmed.
    private static func paragraph(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
