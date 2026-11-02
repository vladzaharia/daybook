import DaybookCore
import Foundation

/// Deleting a speaker profile, removing a voiceprint, and forgetting what a profile learned, each with Undo (both
/// apps' Speaker Profiles). They change library settings, which sync record by record and newest first
/// (`LibraryValue`), so an undo writes back each record the change replaced as a newer change of its own: the
/// profile and its voiceprints return on every device, and redo is the undo's undo.
extension LibraryController {
    /// Deletes a profile and its voiceprints (`deleteSpeakerProfile`); Undo puts them back.
    public func deleteSpeakerProfile(_ profileID: UUID, undoManager: UndoManager?, at now: Date = Date()) {
        undoableSpeakerSettings(actionName: "Delete Profile", undoManager: undoManager, at: now) { deleteSpeakerProfile(profileID, at: now) }
    }

    /// Takes one voiceprint out of its profile (`removeVoiceprint`); Undo puts it back.
    public func removeVoiceprint(_ voiceprintID: String, undoManager: UndoManager?, at now: Date = Date()) {
        undoableSpeakerSettings(actionName: "Remove Voiceprint", undoManager: undoManager, at: now) { removeVoiceprint(voiceprintID, at: now) }
    }

    /// Forgets the voiceprints a profile learned on its own (`forgetLearnedVoiceprints`); Undo puts them back.
    public func forgetLearnedVoiceprints(of profileID: UUID, undoManager: UndoManager?, at now: Date = Date()) {
        undoableSpeakerSettings(actionName: "Forget Learned Voiceprints", undoManager: undoManager, at: now) {
            forgetLearnedVoiceprints(of: profileID, at: now)
        }
    }

    /// Runs `change`, then registers an undo that writes back every profile and voiceprint record it replaced.
    func undoableSpeakerSettings(actionName: String, undoManager: UndoManager?, at now: Date, _ change: () -> Void) {
        let profiles = metadata.speakerProfiles ?? [], prints = metadata.voiceprints ?? []
        change()
        let changedProfiles = Self.replaced(profiles, now: metadata.speakerProfiles ?? [])
        let changedPrints = Self.replaced(prints, now: metadata.voiceprints ?? [])
        guard let undoManager, !changedProfiles.isEmpty || !changedPrints.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { controller in
            let stamp = max(Date(), now)
            controller.undoableSpeakerSettings(actionName: actionName, undoManager: undoManager, at: stamp) {
                controller.updateMetadata { metadata in
                    metadata.speakerProfiles = Self.restoring(changedProfiles, in: metadata.speakerProfiles ?? [], at: stamp)
                    metadata.voiceprints = Self.restoring(changedPrints, in: metadata.voiceprints ?? [], at: stamp)
                }
            }
        }
        undoManager.setActionName(actionName)
    }

    /// The records of `before` that differ in `after` (changed, or gone), as they were.
    nonisolated static func replaced<T>(_ before: [LibraryValue<T>], now after: [LibraryValue<T>]) -> [LibraryValue<T>] {
        let current = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return before.filter { record in current[record.id].map { $0.value != record.value || $0.isDeletion != record.isDeletion } ?? true }
    }

    /// `records` written back over `current`, each newer than the record it replaces, so it wins wherever it syncs.
    nonisolated static func restoring<T>(_ records: [LibraryValue<T>], in current: [LibraryValue<T>], at stamp: Date) -> [LibraryValue<T>] {
        var result = current
        for record in records {
            var restored = record
            let replacing = result.first { $0.id == record.id }
            restored.modifiedAt = max(stamp, (replacing?.modifiedAt ?? .distantPast).addingTimeInterval(0.001))
            result.removeAll { $0.id == record.id }
            result.append(restored)
        }
        return result.sorted { $0.id < $1.id }
    }
}
