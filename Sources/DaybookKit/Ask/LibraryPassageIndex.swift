import DaybookCore
import Foundation
import Synchronization

/// The keyword index over what the library holds, for asking questions across conversations (docs/architecture.md,
/// "Ask across conversations"). One small index per conversation, kept in memory only: never written to disk, never
/// synced, so it always matches the library the device holds and a conversation that left (trashed, deleted elsewhere,
/// merged) is simply not asked about. A conversation's piece is rebuilt when its content changes (a key of its ID, when
/// it last changed, and a hash of what is indexed, as `SummaryEvidenceIndex` does: a sync merge can change a
/// conversation without moving `updatedAt`).
///
/// A locked Personal place is never read: its conversations are not indexed while the lock is locked, and an index built
/// while it was unlocked is dropped (`dropPersonal`). Safe from any thread; building a conversation's piece happens off
/// the main actor, between conversations a cancelled task stops.
public final class LibraryPassageIndex: Sendable {
    private struct Key: Hashable {
        var id: UUID
        var updatedAt: Date
        var passages: Int
        /// Everything indexed: passages with their speakers and times, speakers' names, notes with their times,
        /// bookmarks, and the summary's lines.
        var content: Int

        init(_ meeting: Meeting) {
            id = meeting.id; updatedAt = meeting.updatedAt; passages = meeting.unifiedTranscript.count
            var hasher = Hasher()
            for segment in meeting.unifiedTranscript {
                hasher.combine(segment.id); hasher.combine(segment.text); hasher.combine(segment.speakerID); hasher.combine(segment.start)
            }
            for speaker in meeting.speakers { hasher.combine(speaker.id); hasher.combine(speaker.name) }
            hasher.combine(meeting.notes)
            for time in meeting.paragraphTimes() { hasher.combine(time) }
            for highlight in meeting.highlights { hasher.combine(highlight.id); hasher.combine(highlight.text); hasher.combine(highlight.time) }
            if let summary = meeting.summary {
                hasher.combine(summary.overview)
                for section in summary.sections { hasher.combine(section.body) }
                for item in summary.actionItems { hasher.combine(item.text); hasher.combine(item.owner) }
            }
            content = hasher.finalize()
        }
    }

    private struct Entry: Sendable {
        var key: Key
        var isPersonal: Bool
        var index: ConversationAskIndex
    }

    private let entries = Mutex<[UUID: Entry]>([:])

    public init() {}

    /// Conversations with an index now.
    public var conversationCount: Int { entries.withLock { $0.count } }

    /// Whether `id` has an index now.
    public func contains(_ id: UUID) -> Bool { entries.withLock { $0[id] != nil } }

    /// Brings the index in step with `meetings`: builds what is new or changed, drops what left, and reads no Personal
    /// conversation `personal` doesn't allow. Run it off the main actor once the library has loaded, and again when a
    /// conversation changes, so the first question doesn't wait for it.
    public func update(_ meetings: [Meeting], personal: AskScope.Personal) {
        let present = Set(meetings.map(\.id))
        entries.withLock { entries in
            for (id, entry) in entries where !present.contains(id) || (entry.isPersonal && !personal.allowsPersonal) { entries[id] = nil }
        }
        for meeting in meetings where meeting.effectivePlacement != .personal || personal.allowsPersonal {
            if Task.isCancelled { return }
            _ = index(for: meeting)
        }
    }

    /// Drops every Personal conversation's index: the lock locked.
    public func dropPersonal() {
        entries.withLock { entries in entries = entries.filter { !$0.value.isPersonal } }
    }

    /// The index of `meeting`, built now when it isn't current.
    func index(for meeting: Meeting) -> ConversationAskIndex {
        let key = Key(meeting)
        if let hit = entries.withLock({ $0[meeting.id].flatMap { $0.key == key ? $0.index : nil } }) { return hit }
        let index = ConversationAskIndex(meeting)
        entries.withLock { $0[meeting.id] = Entry(key: key, isPersonal: meeting.effectivePlacement == .personal, index: index) }
        return index
    }
}
