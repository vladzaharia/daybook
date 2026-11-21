import DaybookCore
import Foundation

extension LibraryWords {
    /// What an empty place in the library says (docs/interface.md, "Window structure"): its glyph and one line, and
    /// for a folder how to fill it.
    public struct EmptyPlace: Equatable, Sendable {
        public var title: String
        public var symbol: String
        public var description: String?
        /// Daybook's own mark rather than the place's glyph (the empty library).
        public var showsMark: Bool

        public init(title: String, symbol: String, description: String? = nil, showsMark: Bool = false) {
            self.title = title; self.symbol = symbol; self.description = description; self.showsMark = showsMark
        }
    }

    /// An empty place: "No Conversations" with the section's glyph, a folder with how to fill it ("Drag
    /// conversations here, or choose Move to Folder." on a Mac; "Choose Move to Folder… on a conversation." on an
    /// iPhone, which has no drag), and the Trash with its own. An empty library is welcomed with the mark once: on a
    /// Mac by the page, its list saying "No Conversations" as any empty place does; on an iPhone by its one-column
    /// list. A recorder's page lists recordings, not conversations.
    public static func emptyPlace(_ place: LibraryPlace, libraryIsEmpty: Bool, platform: ConversationAction.Platform) -> EmptyPlace? {
        switch place {
        case .device:
            return nil
        case .section(let section):
            if section == .all && libraryIsEmpty && platform != .mac {
                return EmptyPlace(title: "No Conversations Yet", symbol: "waveform", showsMark: true)
            }
            // Work and Personal say how to fill them, as a folder does.
            let move = section == .work ? "Move to Work" : "Move to Personal"
            let how: String? = switch section {
            case .all: nil
            case .work, .personal: platform == .mac ? "Drag conversations here, or choose \(move)." : "Choose \(move) on a conversation."
            }
            return EmptyPlace(title: "No Conversations", symbol: section.systemImage, description: how)
        case .folder:
            let how = platform == .mac ? "Drag conversations here, or choose Move to Folder." : "Choose Move to Folder… on a conversation."
            return EmptyPlace(title: "No Conversations", symbol: "folder", description: how)
        case .trash:
            return EmptyPlace(title: "No Conversations", symbol: "trash")
        }
    }

    /// What an import says when some of its files didn't read: how many came in, and each that didn't ("Couldn’t import
    /// “Memo.m4a”."), or only the count when there are several.
    public static func importSummary(imported: Int, failed: [String]) -> [String] {
        var lines: [String] = []
        if imported > 0 { lines.append(imported == 1 ? "Imported 1 recording." : "Imported \(imported) recordings.") }
        if failed.count == 1 { lines.append("Couldn’t import “\(failed[0])”.") }
        else if failed.count > 1 { lines.append("Couldn’t import \(failed.count) files.") }
        return lines
    }

    /// The question's line under Move to Trash: the Trash keeps what goes into it until it's restored.
    public static func trashMessage(count: Int) -> String {
        count > 1 ? "You can restore them from the Trash." : "You can restore it from the Trash."
    }

    /// The Trash's name, in the sidebar, the places menu, and over its list.
    public static let trash = "Trash"
    /// The Trash's two ways to delete for good, each asking first (`deleteNowTitle`, `emptyTrashTitle`).
    public static let deleteNow = "Delete Now…"
    public static let emptyTrash = "Empty Trash…"

    /// A conversation with no title, wherever one is listed.
    public static let untitled = "Untitled Conversation"

    /// The library search field's prompt on both apps.
    public static let searchPrompt = "Search"

    /// What an empty library says on an iPhone while this install's first sync pass is still bringing the library
    /// in (`isGettingConversations`), in place of "No Conversations Yet", with a spinner.
    public static let gettingConversations = "Getting your conversations…"

    /// Whether an empty library is still arriving: sync is checking for the library, or connected and this install
    /// hasn't finished a pass (`lastSync`, kept across launches), or its last pass stopped with more to bring.
    public static func isGettingConversations(libraryIsEmpty: Bool, checking: Bool, connected: Bool, lastSync: Date?,
                                              hasMoreWork: Bool) -> Bool {
        guard libraryIsEmpty else { return false }
        if checking { return true }
        return connected && (lastSync == nil || hasMoreWork)
    }

    /// The list's line while sync needs the person, in the words Settings › Library says it with: a problem's
    /// sentence, or what keeps it from syncing ("Waiting for this library’s key."). Signed out, or with iCloud Drive
    /// off, it speaks only on a device that has synced before (`hasSynced`): one that never used iCloud isn't
    /// told about it in its list. Nil while it syncs, waits on its own, or is off by choice.
    public static func syncAttention(_ status: SyncStatus, hasSynced: Bool) -> String? {
        if let problem = status.problem { return problem.text }
        switch status {
        case .waitingForKey: return status.shortText + "."
        case .signedOut, .iCloudDriveOff: return hasSynced ? status.text + "." : nil
        default: return nil
        }
    }

    /// What the sync line is, for VoiceOver and the glyph's tooltip.
    public static let notSyncing = "Not syncing"

    /// The notice once Restore has put a conversation back: "Restored “Old standup”."
    public static func restored(_ meeting: Meeting) -> String {
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Restored a conversation." : "Restored “\(title)”."
    }

    /// Where search found a saved live caption, under the result, so it never passes for the transcript: "Live
    /// captions · tentative · 0:12".
    public static func captionLocation(start: TimeInterval) -> String {
        "Live captions · tentative · \(TimeLabel.short(start))"
    }

    /// Move to Trash's question: "Move “Weekly sync” to the Trash?", "Move 3 conversations to the Trash?", and for one
    /// without a title, "Move this conversation to the Trash?".
    public static func trashTitle(_ meetings: [Meeting]) -> String {
        if meetings.count > 1 { return "Move \(meetings.count) conversations to the Trash?" }
        let title = meetings.first?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Move this conversation to the Trash?" : "Move “\(title)” to the Trash?"
    }

    /// Delete Now's question, for conversations in the Trash: "Delete “Weekly sync” now?", "Delete 3 conversations now?",
    /// and for one without a title, or one the Personal lock hides (`hidden`), "Delete this conversation now?".
    public static func deleteNowTitle(_ meetings: [Meeting], hidden: (Meeting) -> Bool = { _ in false }) -> String {
        if meetings.count > 1 { return "Delete \(meetings.count) conversations now?" }
        let title = meetings.first.flatMap { hidden($0) ? nil : $0.title.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return title.isEmpty ? "Delete this conversation now?" : "Delete “\(title)” now?"
    }

    /// Empty Trash's question, with how many it deletes: "Delete 12 conversations now?".
    public static func emptyTrashTitle(count: Int) -> String {
        count == 1 ? "Delete 1 conversation now?" : "Delete \(count) conversations now?"
    }

    /// Beneath either question.
    public static let deleteNowMessage = "This can’t be undone."

    /// The notice once they're gone: "Deleted 3 conversations.", and, for any that wait until sync has told the other
    /// devices, "2 are waiting for sync."
    public static func deletedNow(deleted: Int, waiting: Int) -> [String] {
        var lines: [String] = []
        if deleted > 0 { lines.append(deleted == 1 ? "Deleted 1 conversation." : "Deleted \(deleted) conversations.") }
        if waiting > 0 { lines.append(waiting == 1 ? "1 is waiting for sync." : "\(waiting) are waiting for sync.") }
        return lines
    }

    /// Details for an import that skipped files: one line each, "Memo.m4a: The file isn’t valid audio."
    public static func importFailureDetails(_ failures: [(name: String, reason: String)]) -> String {
        failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
    }

    /// Merge…'s question, naming the conversation that stays (the earliest, whose title wins): "Merge 3 conversations into
    /// “Weekly sync”?". Without a title to name, or while the Personal lock hides it (`hidden`), "Merge 3 conversations?".
    public static func mergeTitle(_ ids: [UUID], in meetings: [Meeting], hidden: (Meeting) -> Bool = { _ in false }) -> String {
        let selected = ConversationMerge.ordered(meetings.filter { ids.contains($0.id) })
        let count = Set(ids).count
        guard let survivor = selected.first, !hidden(survivor) else { return "Merge \(count) conversations?" }
        let title = survivor.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Merge \(count) conversations?" : "Merge \(count) conversations into “\(title)”?"
    }
    /// Beneath it, what it costs: the summaries are written again only when the merge transcribes the whole again (it has a
    /// recording, `LibraryController.mergeConversations`).
    public static func mergeMessage(_ ids: [UUID], in meetings: [Meeting]) -> String {
        let reprocesses = meetings.contains { ids.contains($0.id) && !$0.presentTracks.isEmpty }
        return (reprocesses ? "Their summaries are written again from the whole. " : "") + "This can’t be undone."
    }
    /// The conversation a merged-away one in the Trash went into: the one in `meetings` that folded it in and that the Personal
    /// lock doesn't hide (`hidden`). Not one that was restored and trashed again since: that one has a recording of its own, or
    /// changed after the merge.
    public static func mergedInto(_ trashed: Meeting, in meetings: [Meeting], hidden: (Meeting) -> Bool = { _ in false }) -> Meeting? {
        guard trashed.presentTracks.isEmpty else { return nil }
        let field = ConversationMerge.revisionField(trashed.id).rawValue
        for survivor in meetings where survivor.id != trashed.id {
            guard let fold = survivor.revisions.first(where: { $0.field == field }) else { continue }
            guard trashed.updatedAt <= fold.date.addingTimeInterval(120), !hidden(survivor) else { return nil }
            return survivor
        }
        return nil
    }
    /// A merged-away conversation's status in the Trash, with Show: "Merged into “Weekly sync”".
    public static func mergedInto(_ title: String) -> String { "Merged into “\(title)”" }
    /// Beneath it, what it costs.
    public static let mergeMessage = "Their summaries are written again from the whole. This can’t be undone."
}
