import Foundation

/// Photos that couldn't be read, and when each may be tried again: after a minute, then ten, an
/// hour, six hours, and then once a day, so one unreadable photo doesn't load the photo models at
/// every sync pass. A photo that reads is cleared; a new photo isn't held back. Kept for the app's
/// session: after a relaunch each is tried once more.
public struct PhotoReadingBackoff: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var attempts: Int
        public var retryAt: Date
        public var reason: String
    }

    public static let delays: [TimeInterval] = [60, 600, 3_600, 21_600, 86_400]
    private var failures: [UUID: Failure] = [:]

    public init() {}

    public mutating func failed(_ photoID: UUID, reason: String, at now: Date = Date()) {
        let attempts = (failures[photoID]?.attempts ?? 0) + 1
        let delay = Self.delays[min(attempts, Self.delays.count) - 1]
        failures[photoID] = Failure(attempts: attempts, retryAt: now.addingTimeInterval(delay), reason: reason)
    }

    public mutating func read(_ photoID: UUID) { failures[photoID] = nil }

    public func failure(_ photoID: UUID) -> Failure? { failures[photoID] }

    /// Whether a photo may be read now: it never failed, or its wait is over.
    public func mayRead(_ photoID: UUID, at now: Date = Date()) -> Bool {
        failures[photoID].map { $0.retryAt <= now } ?? true
    }

    /// The soonest moment one of `photoIDs` that's waiting may be read again.
    public func nextRetry<S: Sequence>(among photoIDs: S) -> Date? where S.Element == UUID {
        photoIDs.compactMap { failures[$0]?.retryAt }.min()
    }
}
