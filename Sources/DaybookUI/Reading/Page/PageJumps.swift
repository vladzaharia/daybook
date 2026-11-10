import Foundation

/// Where a page should go next, asked for from elsewhere (a search hit, a next step's evidence, a bookmark, Show in Your
/// Notes): a block or a passage, with a token so asking for the same one twice still moves the page. Both apps' reading
/// state keeps one for each page (the iPhone's `ReadingSession`, the Mac's `LibraryWindowModel`), and the page moves
/// once per token.
public struct ScrollRequest: Equatable, Sendable {
    public var target: String
    public var token: Int
    public var flash: Bool

    public init(target: String, token: Int, flash: Bool) {
        self.target = target
        self.token = token
        self.flash = flash
    }
}

/// Stable IDs for the summary page's blocks, for scroll positions and jumps.
public enum SummaryBlockID {
    public static let header = "header"
    public static let lede = "lede"
    public static let nextSteps = "next-steps"
    public static let notes = "notes"
    public static let bookmarks = "bookmarks"
    public static let colophon = "colophon"
    public static func section(_ id: UUID) -> String { "section:\(id.uuidString)" }
}
