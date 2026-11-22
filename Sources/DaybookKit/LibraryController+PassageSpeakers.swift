import DaybookCore
import Foundation

// Who said a passage (DaybookCore's PassageSpeakers.swift), as the transcript's Speaker ▸ changes it. Undo takes back
// each passage alone, in the conversation as it is when it runs: a passage whose speaker changed again since (a sync,
// processing again) stays as it is, and so does everything else the conversation took in meanwhile.

extension LibraryController {
    /// Gives passages to a speaker of the conversation (`Meeting.giveSpeaker`). Undo ("Undo Change Speaker") gives each one
    /// back the speaker it had while it still has the one it was given, as a Version History entry of its own, as the move
    /// was; redo gives them again.
    @discardableResult
    public func giveSpeaker(_ speakerID: String, toPassages passageIDs: [UUID], in id: UUID, undoManager: UndoManager?) -> Bool {
        moveSpeakers(in: id, undoManager: undoManager) { $0.giveSpeaker(speakerID, toPassages: passageIDs) }
    }

    /// Gives passages to the speaker called `name`, made when the conversation has none (`Meeting.giveSpeaker(named:)`).
    /// The person's own profile, picked in the name list (`picked`) or typed, marks that speaker as them too, as a rename
    /// does (`namesMe`). Undo takes the passages back; a speaker it made then has none, and isn't listed.
    @discardableResult
    public func giveNewSpeaker(named name: String, picked: UUID? = nil, toPassages passageIDs: [UUID], in id: UUID,
                               undoManager: UndoManager?) -> Bool {
        var speakerID: String?
        guard moveSpeakers(in: id, undoManager: undoManager, {
            speakerID = $0.giveSpeaker(named: name, toPassages: passageIDs)
            return speakerID != nil
        }) else { return false }
        if let speakerID, namesMe(name, picked: picked) { markSpeakerAsMe([speakerID], in: id, undoManager: undoManager) }
        return true
    }

    private func moveSpeakers(in id: UUID, undoManager: UndoManager?, _ move: (inout Meeting) -> Bool) -> Bool {
        guard let before = meeting(id) else { return false }
        var moved = false
        update(id) { moved = move(&$0) }
        guard moved else { return false }
        if let undoManager, let after = meeting(id) {
            registerSpeakerUndo(after.revisions.filter { entry in !before.revisions.contains { $0.id == entry.id } }, in: id, undoManager: undoManager)
        }
        return true
    }

    /// Undo for the moves `entries` recorded (`.segmentSpeaker`): each passage that still has the speaker it was given
    /// gets the one it had, which records the move back. Its redo is the same for the moves back.
    private func registerSpeakerUndo(_ entries: [MeetingRevision], in id: UUID, undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { library in
            guard let before = library.meeting(id) else { return }
            library.update(id) { meeting in
                for entry in entries {
                    guard case .segmentSpeaker(let passage) = entry.kind,
                          meeting.unifiedTranscript.contains(where: { $0.id == passage && ($0.speakerID ?? "") == entry.newValue }) else { continue }
                    // After the entry it takes back whatever the clock says, so the latest word is this one.
                    meeting.giveSpeaker(entry.oldValue, toPassages: [passage], at: max(Date(), entry.date.addingTimeInterval(0.001)))
                }
            }
            guard let after = library.meeting(id) else { return }
            let back = after.revisions.filter { entry in !before.revisions.contains { $0.id == entry.id } }
            if !back.isEmpty { library.registerSpeakerUndo(back, in: id, undoManager: undoManager) }
        }
        undoManager.setActionName("Change Speaker")
    }
}
