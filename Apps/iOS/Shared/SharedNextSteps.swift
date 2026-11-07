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

    @discardableResult
    func save(to container: URL? = SharedWidgetCache.groupContainer) -> Bool {
        Self.cache.save(Self(items), to: container)
    }
}
