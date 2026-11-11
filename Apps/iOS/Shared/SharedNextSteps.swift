import Foundation

/// Only the six displayed action items: no summary, notes, transcript, owner, or audio.
struct SharedNextSteps: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let meetingID: UUID
        let title: String
        let date: Date
        let text: String
    }

    static let limit = 6
    static let widgetKind = "local.daybook.phone.next-steps"
    static let cache = SharedWidgetCache(fileName: "next-steps.json")

    private(set) var items: [Item]

    init(_ items: [Item] = []) {
        self.items = Array(items.prefix(Self.limit))
    }

    /// Nil until the app has published a loaded library, or when the snapshot cannot be read safely.
    static func load(from container: URL? = SharedWidgetCache.groupContainer) -> Self? {
        guard let snapshot = cache.load(Self.self, from: container) else { return nil }
        return Self(snapshot.items)
    }

    /// The snapshot as the widget reads it: there, not there, or there but locked away until the iPhone is unlocked.
    static func read(from container: URL? = SharedWidgetCache.groupContainer) -> SharedWidgetCache.Read<Self> {
        switch cache.read(Self.self, from: container) {
        case .value(let snapshot): return .value(Self(snapshot.items))
        case .missing: return .missing
        case .locked: return .locked
        }
    }

    /// `protects`: "Protect while iPhone is locked" (`SharedWidgetCache.save`).
    @discardableResult
    func save(to container: URL? = SharedWidgetCache.groupContainer, protects: Bool = false) -> Bool {
        Self.cache.save(Self(items), to: container, protects: protects)
    }
}
