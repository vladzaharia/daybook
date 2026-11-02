import DaybookCore
import Foundation

/// Filing that Edit › Undo takes back (and Redo applies again), on both apps: moving conversations into a folder or
/// out of one, into Work or Personal, their tags, and a folder made, renamed, or deleted. Each conversation's change
/// goes through `update(_:actionName:undoManager:)`, so undo puts back only what the filing changed. Several made in
/// one event (a drop of three rows, a batch action) are one step, as the undo manager groups an event's changes.
/// Without an undo manager each is the plain edit.
extension LibraryController {
    /// The Undo menu's name for filing into Work, Personal, or where the conversation's kind puts it.
    public static func filingActionName(_ placement: LibraryPlacement?) -> String {
        switch placement {
        case .work?: return "Move to Work"
        case .personal?: return "Move to Personal"
        case nil: return "Move"
        }
    }

    /// Files conversations in a folder, or in none ("Move to Folder").
    public func moveToFolder(_ ids: [UUID], _ folder: UUID?, undoManager: UndoManager?) {
        guard let undoManager else { moveToFolder(ids, folder); return }
        for id in ids { update(id, actionName: "Move to Folder", undoManager: undoManager) { $0.folderID = folder } }
    }

    /// Shows conversations in Work or Personal, or where their kind puts them (nil).
    public func setPlacement(_ ids: [UUID], _ placement: LibraryPlacement?, undoManager: UndoManager?) {
        guard let undoManager else { setPlacement(ids, placement); return }
        for id in ids {
            update(id, actionName: Self.filingActionName(placement), undoManager: undoManager) { $0.placement = placement }
        }
    }

    /// A conversation's tags from comma-separated text, as `setTags(_:text:)` reads it ("Tags").
    public func setTags(_ id: UUID, text: String, undoManager: UndoManager?) {
        guard let undoManager else { setTags(id, text: text); return }
        let tags = Self.tags(from: text)
        update(id, actionName: "Tags", undoManager: undoManager) { $0.tags = tags }
    }

    /// A new folder, with `ids` moved into it ("New Folder"). Undo moves them back where they were and removes it.
    @discardableResult
    public func createFolder(named name: String, moving ids: [UUID], undoManager: UndoManager?) -> UUID {
        guard let undoManager else { return createFolder(named: name, moving: ids) }
        let folder = LibraryFolder(name: name)
        saveFolder(folder)
        registerFolderUndo(folder, created: true, undoManager: undoManager)
        for id in ids { update(id, actionName: "New Folder", undoManager: undoManager) { $0.folderID = folder.id } }
        undoManager.setActionName("New Folder")
        return folder.id
    }

    /// A folder's new name ("Rename Folder").
    public func renameFolder(_ id: UUID, to name: String, undoManager: UndoManager?) {
        guard let old = folders.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old.name else { return }
        var renamed = old
        renamed.name = trimmed
        saveFolder(renamed)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { controller in
            controller.renameFolder(id, to: old.name, undoManager: undoManager)
        }
        undoManager.setActionName("Rename Folder")
    }

    /// Deletes a folder; its conversations stay in the library, outside any folder ("Delete Folder"). Undo brings
    /// the folder back with the conversations that were in it, unless one has been filed somewhere else since.
    public func removeFolder(_ id: UUID, undoManager: UndoManager?) {
        guard let undoManager, let folder = folders.first(where: { $0.id == id }) else { removeFolder(id); return }
        let filed = meetings.filter { $0.folderID == id }.map(\.id)
        removeFolder(id)
        undoManager.registerUndo(withTarget: self) { controller in
            controller.saveFolder(folder)
            for meeting in controller.meetings where filed.contains(meeting.id) && meeting.folderID == nil {
                controller.update(meeting.id) { $0.folderID = id }
            }
            undoManager.registerUndo(withTarget: controller) { $0.removeFolder(id, undoManager: undoManager) }
            undoManager.setActionName("Delete Folder")
        }
        undoManager.setActionName("Delete Folder")
    }

    /// Undo for a folder made (`created`): removing it (its conversations are back where they were by then, as
    /// their moves are undone first), with redo making it again; and the same the other way round.
    private func registerFolderUndo(_ folder: LibraryFolder, created: Bool, undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { controller in
            if created { controller.removeFolder(folder.id) } else { controller.saveFolder(folder) }
            controller.registerFolderUndo(folder, created: !created, undoManager: undoManager)
        }
    }

    /// Tags from comma-separated text: trimmed, without duplicates that differ only in case.
    nonisolated static func tags(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
