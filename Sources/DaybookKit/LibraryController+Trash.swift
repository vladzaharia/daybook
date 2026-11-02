import DaybookCore
import Foundation

extension LibraryController {
    /// The conversations in the Trash, newest first, as their last saved copies: what the Trash lists on both
    /// apps, with Restore (`restoreFromTrash`). Read off the main actor; a folder whose copy can't be read is left
    /// out. Moving a conversation to the Trash or restoring one changes `revision`, which is when to read again.
    public func trashedMeetings() async -> [Meeting] {
        let root = rootURL
        return await Task.detached(priority: .userInitiated) { Self.trashedMeetings(in: root) }.value
    }

    /// One conversation in the Trash, as its last saved copy; nil once it's restored or gone.
    public func trashedMeeting(_ id: UUID) async -> Meeting? {
        let root = rootURL
        return await Task.detached(priority: .userInitiated) { Self.trashedMeeting(id, in: root) }.value
    }

    /// Whether anything is in the Trash, looked up off the main actor: the Mac's sidebar lists the Trash once it is.
    public func hasTrashedMeetings() async -> Bool {
        let root = rootURL
        return await Task.detached(priority: .utility) { !Self.trashedIDs(in: root).isEmpty }.value
    }

    /// The Trash's conversations under a library's root, newest first.
    nonisolated public static func trashedMeetings(in root: URL) -> [Meeting] {
        trashedIDs(in: root).compactMap { trashedMeeting($0, in: root) }.sorted { $0.date > $1.date }
    }

    /// A conversation's last saved copy in the Trash under a library's root. The recovery copy stands in when the
    /// main one is missing or torn, as it does when the library loads.
    nonisolated static func trashedMeeting(_ id: UUID, in root: URL) -> Meeting? {
        let folder = root.appendingPathComponent("Trash", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        let decoder = JSONDecoder()
        for name in ["meeting.json", "meeting.recovery.json"] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
               let meeting = try? decoder.decode(Meeting.self, from: data), meeting.id == id {
                return meeting
            }
        }
        return nil
    }

    /// The IDs of the folders in the Trash.
    nonisolated static func trashedIDs(in root: URL) -> [UUID] {
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }
}
