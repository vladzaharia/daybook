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
    /// iPhone, which has no drag). An empty library says so once: on a Mac the page does, so its list says nothing
    /// (nil); an iPhone's one-column list is where it's said. A recorder's page lists recordings, not conversations.
    public static func emptyPlace(_ place: LibraryPlace, libraryIsEmpty: Bool, platform: ConversationAction.Platform) -> EmptyPlace? {
        switch place {
        case .device:
            return nil
        case .section(let section):
            if section == .all && libraryIsEmpty {
                return platform == .mac ? nil : EmptyPlace(title: "No Conversations Yet", symbol: "waveform", showsMark: true)
            }
            return EmptyPlace(title: "No Conversations", symbol: section.systemImage)
        case .folder:
            let how = platform == .mac ? "Drag conversations here, or choose Move to Folder." : "Choose Move to Folder… on a conversation."
            return EmptyPlace(title: "No Conversations", symbol: "folder", description: how)
        }
    }

    /// Move to Trash's question: "Move “Weekly sync” to the Trash?", "Move 3 conversations to the Trash?", and for one
    /// without a title, "Move this conversation to the Trash?".
    public static func trashTitle(_ meetings: [Meeting]) -> String {
        if meetings.count > 1 { return "Move \(meetings.count) conversations to the Trash?" }
        let title = meetings.first?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Move this conversation to the Trash?" : "Move “\(title)” to the Trash?"
    }
}
