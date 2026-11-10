import DaybookCore
import Foundation

/// What Spotlight lists of the library, the same on both apps: every conversation that isn't Personal (by the person's
/// placement, or the kind it was found to be), by title and date, newest first, kept in step as the library changes.
/// Personal ones, and those in the Trash, are never listed, and leave the list when they become so.
///
/// This is the plan; each app carries out its passes with its own `ConversationEntity`, since App Intents reads an
/// entity's metadata from the target that declares it.
public struct SpotlightPlan: Sendable {
    /// A conversation as Spotlight lists it: never what was said, which would sit outside the library's encryption.
    public struct Entry: Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var date: Date

        public init(id: UUID, title: String, date: Date) {
            self.id = id
            self.title = title
            self.date = date
        }

        public init(_ meeting: Meeting) {
            self.init(id: meeting.id, title: meeting.title, date: meeting.date)
        }
    }

    /// What one pass asks of the index, in order: start over (whatever this app listed before goes, so what changed
    /// while it wasn't running never stays listed), take out what went, then list what's new or changed.
    public struct Pass: Equatable, Sendable {
        public var startsOver: Bool
        public var removed: [UUID]
        public var listed: [Entry]
    }

    /// What the index has now, by conversation; nil until this run's first pass.
    public private(set) var listed: [UUID: Entry]?

    public init() {}

    /// Whether Daybook may name the conversation outside the app (Spotlight, Siri's suggestions, Shortcuts' search, a
    /// widget): anything not Personal.
    public static func isShown(_ meeting: Meeting) -> Bool { meeting.effectivePlacement != .personal }

    /// The conversations Spotlight lists, newest first: none that's Personal.
    public static func entries(_ meetings: [Meeting]) -> [Entry] {
        meetings.filter(isShown).sorted { $0.date > $1.date }.map(Entry.init)
    }

    /// The pass that brings the index to `entries` (`entries(_:)`), and takes them as what it has; nil when nothing
    /// changed. A run's first pass starts over.
    public mutating func pass(to entries: [Entry]) -> Pass? {
        let wanted = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let startsOver = listed == nil
        let before = listed ?? [:]
        let changed = entries.filter { before[$0.id] != $0 }
        let gone = before.keys.filter { wanted[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
        listed = wanted
        guard startsOver || !changed.isEmpty || !gone.isEmpty else { return nil }
        return Pass(startsOver: startsOver, removed: gone, listed: changed)
    }
}
