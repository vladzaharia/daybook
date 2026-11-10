import DaybookCore
import Foundation

// Handwriting in a conversation's notes (`NoteInk.swift`). Each change saves with the conversation, like the notes.
extension LibraryController {
    /// A new block of handwriting, as a new paragraph after the nonempty paragraph at `index`, or at the end when nil.
    public func addInk(_ block: NoteInk, to id: UUID, after index: Int?) {
        update(id) { $0.addInk(block, after: index) }
    }

    /// New strokes, size, or words for a block.
    public func updateInk(_ block: NoteInk, in id: UUID) {
        update(id) { $0.updateInk(block) }
    }

    /// Takes a block out, its paragraph going or staying as typed words. Returns what puts it back.
    public func removeInk(_ blockID: UUID, from id: UUID, keepingWords: Bool) -> (() -> Void)? {
        var removal: InkRemoval?
        update(id) { removal = $0.removeInk(blockID, keepingWords: keepingWords) }
        return removal.map { removal in
            { [weak self] in self?.update(id) { $0.restoreInk(removal) } }
        }
    }
}
