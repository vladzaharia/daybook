import DaybookCore
import Foundation

// Undo for an edit to one item of a conversation: a bookmark, a next step, the recordings it waits for. Undo takes
// back that item alone, in the conversation as it is when it runs, so whatever else changed meanwhile stays: a bookmark
// added while recording or synced from another device, a newer summary, a recording that arrived on a link. (Undo for
// a field the person owns whole, such as the title or the folder, puts the field back: `update(_:actionName:
// undoManager:_:)`.) Like any edit, an undo is a newer change, so it syncs; redo makes the edit again.

extension LibraryController {
    /// Deletes a bookmark (`removeBookmark`). Undo puts that bookmark back as it was, if it's still gone.
    public func removeBookmark(_ highlightID: UUID, in id: UUID, undoManager: UndoManager?) {
        guard let bookmark = meeting(id)?.highlights.first(where: { $0.id == highlightID }) else { return }
        edit(id, actionName: "Delete Bookmark", undoManager: undoManager, change: { $0.removeBookmark(highlightID, in: id) }) { meeting in
            guard !meeting.highlights.contains(where: { $0.id == highlightID }) else { return }
            meeting.highlights.append(bookmark)
        }
    }

    /// A bookmark's label (`setBookmarkText`). Undo sets the label back, unless it has changed again since.
    public func setBookmarkText(_ highlightID: UUID, text: String, in id: UUID, undoManager: UndoManager?) {
        guard let old = meeting(id)?.highlights.first(where: { $0.id == highlightID })?.text else { return }
        edit(id, actionName: "Bookmark Label", undoManager: undoManager, change: { $0.setBookmarkText(highlightID, text: text, in: id) }) { meeting in
            guard let index = meeting.highlights.firstIndex(where: { $0.id == highlightID }), meeting.highlights[index].text == text else { return }
            meeting.highlights[index].text = old
        }
    }

    /// Ticks a next step, or clears its tick. Undo sets that step back while the summary still has it, so a summary
    /// written meanwhile stays as it came.
    public func setNextStep(_ itemID: UUID, done: Bool, in id: UUID, undoManager: UndoManager?) {
        func mark(_ done: Bool) -> (inout Meeting) -> Void {
            { meeting in
                guard let index = meeting.summary?.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
                meeting.summary?.actionItems[index].completed = done
            }
        }
        let change = mark(done)
        edit(id, actionName: done ? "Mark as Done" : "Mark as Not Done", undoManager: undoManager,
             change: { $0.update(id, change) }, undo: mark(!done))
    }

    /// Don't Wait: stops waiting for the recordings it waits for now (`Meeting.stopWaitingForRecordings`). Undo waits
    /// for those again, by their links, and leaves what the links say otherwise as it is now.
    public func stopWaitingForRecordings(in id: UUID, undoManager: UndoManager?, at now: Date = Date()) {
        guard let links = meeting(id)?.awaitedLinks(now: now), !links.isEmpty else { return }
        edit(id, actionName: "Don’t Wait", undoManager: undoManager,
             change: { $0.update(id) { $0.stopWaitingForRecordings(at: now, links: links) } }) { $0.waitAgain(for: links) }
    }

    /// Makes `change` to conversation `id`, and lets `undoManager` take it back under `actionName` with `undo`, which
    /// acts on the conversation as it is when it runs. What `change` wrote to Version History stays, and the undo
    /// writes each entry's reverse beside it, as the field-by-field undo does. Redo makes the change again. Nothing is
    /// registered when nothing changed.
    private func edit(_ id: UUID, actionName: String, undoManager: UndoManager?, change: @escaping (LibraryController) -> Void,
                      undo: @escaping (inout Meeting) -> Void) {
        guard let before = meeting(id) else { return }
        change(self)
        guard let undoManager, let after = meeting(id), after != before else { return }
        let written = after.revisions.filter { revision in !before.revisions.contains { $0.id == revision.id } }
        undoManager.registerUndo(withTarget: self) { library in
            library.takeBack(id, actionName: actionName, undoManager: undoManager, undo: undo, written: written, redo: change)
        }
        undoManager.setActionName(actionName)
    }

    /// The undo `edit` registers; its redo is the change again.
    private func takeBack(_ id: UUID, actionName: String, undoManager: UndoManager, undo: @escaping (inout Meeting) -> Void,
                          written: [MeetingRevision], redo: @escaping (LibraryController) -> Void) {
        guard let before = meeting(id) else { return }
        update(id) { meeting in
            let edited = meeting
            undo(&meeting)
            guard meeting != edited else { return }
            meeting.revisions += written.reversed().map { MeetingRevision(field: $0.field, oldValue: $0.newValue, newValue: $0.oldValue) }
        }
        guard meeting(id) != before else { return }
        undoManager.registerUndo(withTarget: self) { library in
            library.edit(id, actionName: actionName, undoManager: undoManager, change: redo, undo: undo)
        }
        undoManager.setActionName(actionName)
    }
}
