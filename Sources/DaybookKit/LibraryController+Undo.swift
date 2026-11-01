import DaybookCore
import Foundation

extension LibraryController {
    /// The keys of a conversation's stored form that undo never restores: its history only grows (Version History
    /// keeps what was replaced), and its time stamp is the change's own.
    nonisolated static let undoKeepsKeys: Set<String> = ["revisions", "updatedAt"]

    /// Changes a conversation as `update` does, and lets `undoManager` take it back under `actionName` ("Move to
    /// Folder", "Rename"): undo puts back what the change replaced, field by field, and nothing it didn't touch,
    /// so a sync or a summary that arrived meanwhile stays. The undo is a change of its own, newer than the one it
    /// takes back (`updatedAt`), so it syncs the same way, and redo is its undo. What the change wrote to Version
    /// History stays, with the undo written beside it. Nothing is registered when nothing changed.
    @discardableResult
    public func update(_ id: UUID, actionName: String, undoManager: UndoManager?, _ change: (inout Meeting) -> Void) -> Bool {
        guard let before = meeting(id) else { return false }
        var changed = false
        update(id) { meeting in
            change(&meeting)
            changed = meeting != before
        }
        guard changed, let after = meeting(id), let undoManager else { return changed }
        guard let restore = Self.undoing(from: before, to: after) else { return changed }
        undoManager.registerUndo(withTarget: self) { controller in
            controller.update(id, actionName: actionName, undoManager: undoManager) { meeting in restore(&meeting) }
        }
        undoManager.setActionName(actionName)
        return changed
    }

    /// What takes `after` back to `before`: each field the change touched gets its earlier value, and each Version
    /// History entry it wrote gets its reverse. Nil when nothing can be taken back.
    nonisolated static func undoing(from before: Meeting, to after: Meeting) -> ((inout Meeting) -> Void)? {
        guard let old = fields(of: before), let new = fields(of: after) else { return nil }
        let keys = Set(old.keys).union(new.keys).subtracting(undoKeepsKeys).filter { old[$0] != new[$0] }
        let written = after.revisions.filter { revision in !before.revisions.contains { $0.id == revision.id } }
        guard !keys.isEmpty || !written.isEmpty else { return nil }
        return { meeting in
            guard var current = Self.fields(of: meeting) else { return }
            for key in keys { current[key] = old[key] }
            guard let restored = Self.meeting(from: current) else { return }
            let revisions = meeting.revisions + written.reversed().map {
                MeetingRevision(field: $0.field, oldValue: $0.newValue, newValue: $0.oldValue)
            }
            meeting = restored
            meeting.revisions = revisions
        }
    }

    /// A conversation's stored fields, each as its own JSON, so a field can be compared and put back alone.
    nonisolated private static func fields(of meeting: Meeting) -> [String: Data]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(meeting),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var fields: [String: Data] = [:]
        for (key, value) in object {
            fields[key] = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        }
        return fields
    }

    nonisolated private static func meeting(from fields: [String: Data]) -> Meeting? {
        var object: [String: Any] = [:]
        for (key, data) in fields {
            guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
            object[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Meeting.self, from: data)
    }
}
