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
        /// Filed in Personal now: a conversation moved there is a different piece, built again under the lock's rules.
        var isPersonal: Bool

        init(_ meeting: Meeting) {
            id = meeting.id; updatedAt = meeting.updatedAt; passages = meeting.unifiedTranscript.count
            isPersonal = meeting.effectivePlacement == .personal
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
        var index: ConversationAskIndex
    }

    private struct State: Sendable {
        var entries: [UUID: Entry] = [:]
        /// Bumped whenever Personal pieces are dropped, so one being built meanwhile isn't kept.
        var generation = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Conversations with an index now.
    public var conversationCount: Int { state.withLock { $0.entries.count } }

    /// Whether `id` has an index now.
    public func contains(_ id: UUID) -> Bool { state.withLock { $0.entries[id] != nil } }

    /// Brings the index in step with `meetings`: builds what is new or changed, drops what left, and reads no Personal
    /// conversation `personal` doesn't allow. Run it off the main actor once the library has loaded, and again when a
    /// conversation changes, so the first question doesn't wait for it.
    public func update(_ meetings: [Meeting], personal: AskScope.Personal) {
        let present = Set(meetings.map(\.id))
        // What isn't allowed goes by the conversation's placement now, not the one it was indexed under.
        let barred = Set(meetings.filter { $0.effectivePlacement == .personal && !personal.allowsPersonal }.map(\.id))
        state.withLock { state in
            for id in state.entries.keys where !present.contains(id) || barred.contains(id) { state.entries[id] = nil }
            if !barred.isEmpty { state.generation += 1 }
        }
        for meeting in meetings where !barred.contains(meeting.id) {
            if Task.isCancelled { return }
            _ = index(for: meeting)
        }
    }

    /// Drops every conversation indexed as Personal: the lock locked. A piece being built at this moment isn't kept.
    /// Prefer `dropPersonal(in:)`, which also drops a conversation moved to Personal since it was indexed.
    public func dropPersonal() {
        state.withLock { state in
            state.entries = state.entries.filter { !$0.value.key.isPersonal }
            state.generation += 1
        }
    }

    /// The same, going by `meetings`' placements now as well: a conversation moved into Personal is dropped too.
    public func dropPersonal(in meetings: [Meeting]) {
        let personal = Set(meetings.filter { $0.effectivePlacement == .personal }.map(\.id))
        state.withLock { state in
            state.entries = state.entries.filter { !$0.value.key.isPersonal && !personal.contains($0.key) }
            state.generation += 1
        }
    }

    /// The index of `meeting`, built now when it isn't current.
    func index(for meeting: Meeting, afterBuild: () -> Void = {}) -> ConversationAskIndex {
        let key = Key(meeting)
        let (hit, generation) = state.withLock { ($0.entries[meeting.id].flatMap { $0.key == key ? $0.index : nil }, $0.generation) }
        if let hit { return hit }
        let index = ConversationAskIndex(meeting)
        afterBuild()
        state.withLock { state in
            // A Personal piece whose lock locked while it was built is not kept.
            guard !key.isPersonal || state.generation == generation else { return }
            state.entries[meeting.id] = Entry(key: key, index: index)
        }
        return index
    }
}
