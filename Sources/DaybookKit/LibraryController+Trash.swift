import DaybookCore
import Foundation

extension LibraryController {
    /// The conversations in the Trash, newest first, as their last saved copies: what the Trash lists on both
    /// apps, with Restore (`restoreFromTrash`), and what Empty Trash deletes and counts. Read off the main actor; a
    /// folder whose copy can't be read, or that a newer Daybook wrote, is left out (and never deleted), as is a
    /// conversation deleted for good (its tombstone). Moving a conversation to the Trash, restoring one, or deleting
    /// one changes `revision`, which is when to read again.
    public func trashedMeetings() async -> [Meeting] {
        let root = rootURL
        return await Task.detached(priority: .userInitiated) { Self.trashedMeetings(in: root) }.value
    }

    /// One conversation in the Trash, as its last saved copy; nil once it's restored or gone.
    public func trashedMeeting(_ id: UUID) async -> Meeting? {
        let root = rootURL
        return await Task.detached(priority: .userInitiated) { Self.trashedMeeting(id, in: root) }.value
    }

    /// Whether the Trash lists anything (`trashedMeetings`), looked up off the main actor: the Mac's sidebar lists the
    /// Trash once it does, and the iPhone's More menu offers Empty Trash.
    public func hasTrashedMeetings() async -> Bool {
        let root = rootURL
        return await Task.detached(priority: .utility) { Self.trashedIDs(in: root).contains { Self.trashedMeeting($0, in: root) != nil } }.value
    }

    /// Deletes conversations in the Trash for good (Delete Now, Empty Trash), those of `ids` still in it: one restored
    /// since is left alone, and one this version can't read is kept. Each leaves its tombstone in the Trash
    /// (`MeetingStore.deleteFromTrash`), from which sync publishes the deletion whenever it next runs, so nothing waits
    /// for sync. One that fails doesn't stop the rest; the result says which went and which didn't.
    @discardableResult
    public func deleteFromTrash(_ ids: [UUID]) async throws -> TrashDeletion {
        await acquireLock()
        defer { releaseLock() }
        guard let store else { throw DaybookError.libraryUnavailable }
        var result = TrashDeletion()
        // Whatever happened, what the Trash lists is read again.
        defer { if !result.deleted.isEmpty || !result.failed.isEmpty { revision &+= 1 } }
        for id in ids {
            do {
                switch try await store.deleteFromTrash(id) {
                case .deleted: result.deleted.append(id)
                case .notInTrash: continue
                case .kept: result.failed.append(id)
                }
            } catch {
                result.failed.append(id)
            }
        }
        return result
    }

    /// What compression follows a voice profile's audio through beyond the library (`RecordingCompressionPlanner.Inputs.lineage`):
    /// every conversation in the Trash it can decode, and every one deleted from it for good, as its tombstone keeps it.
    /// Read off the main actor.
    public func compressionLineage() async -> [Meeting] {
        let root = rootURL
        return await Task.detached(priority: .utility) { () -> [Meeting] in
            let trash = root.appendingPathComponent("Trash", isDirectory: true)
            let decoder = JSONDecoder()
            return Self.folderIDs(in: root).compactMap { id in
                let folder = trash.appendingPathComponent(id.uuidString, isDirectory: true)
                if TrashTombstone.marks(folder) { return TrashTombstone.read(folder)?.lineage }
                return ["meeting.json", "meeting.recovery.json"].lazy.compactMap { name in
                    (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? decoder.decode(Meeting.self, from: $0) }
                }.first { $0.id == id }
            }
        }.value
    }

    /// The Trash's conversations under a library's root, newest first.
    nonisolated public static func trashedMeetings(in root: URL) -> [Meeting] {
        trashedIDs(in: root).compactMap { trashedMeeting($0, in: root) }.sorted { $0.date > $1.date }
    }

    /// A conversation's last saved copy in the Trash under a library's root, as the Trash lists it
    /// (`MeetingStore.readableTrashedMeeting`).
    nonisolated static func trashedMeeting(_ id: UUID, in root: URL) -> Meeting? {
        MeetingStore.readableTrashedMeeting(id, in: root.appendingPathComponent("Trash/\(id.uuidString)", isDirectory: true))
    }

    /// The IDs of the folders in the Trash, less the tombstones of those deleted from it for good.
    nonisolated static func trashedIDs(in root: URL) -> [UUID] {
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        return folderIDs(in: root).filter { !TrashTombstone.marks(trash.appendingPathComponent($0.uuidString, isDirectory: true)) }
    }

    /// Every conversation's folder in the Trash: there, or deleted from it for good.
    nonisolated static func folderIDs(in root: URL) -> [UUID] {
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    /// Whether conversation `id` was deleted for good from the Trash of the library at `root`: its tombstone is there.
    /// A recording left behind for it (a Mac's staging, an iPhone's leftover) is never filed back.
    nonisolated public static func isDeletedForGood(_ id: UUID, in root: URL) -> Bool {
        TrashTombstone.marks(root.appendingPathComponent("Trash/\(id.uuidString)", isDirectory: true))
    }
}

/// What Delete Now and Empty Trash did: the conversations deleted, and those that couldn't be (still in the Trash).
public struct TrashDeletion: Equatable, Sendable {
    public var deleted: [UUID] = []
    public var failed: [UUID] = []
    public init() {}
}
