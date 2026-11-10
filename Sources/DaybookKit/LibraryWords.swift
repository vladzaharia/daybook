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
            return EmptyPlace(title: "No Conversations", symbol: section.systemImage)
        case .folder:
            let how = platform == .mac ? "Drag conversations here, or choose Move to Folder." : "Choose Move to Folder… on a conversation."
            return EmptyPlace(title: "No Conversations", symbol: "folder", description: how)
        case .trash:
            return EmptyPlace(title: "No Conversations", symbol: "trash")
        }
    }

    /// The Trash's name, in the sidebar, the places menu, and over its list.
    public static let trash = "Trash"

    /// A conversation with no title, wherever one is listed.
    public static let untitled = "Untitled Conversation"

    /// The library search field's prompt on both apps.
    public static let searchPrompt = "Titles, notes, transcripts"

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
}
