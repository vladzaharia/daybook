import DaybookLink
import Foundation

/// This iPhone's meter readings on their way to the Macs recording the same conversation that draw
/// them (`LinkLevels`): gathered as the meter reads them, about fifteen a second, and sent a few at a
/// time about five times a second, so the link carries a few small messages a second rather than one
/// per reading.
struct LevelShare {
    static let interval: TimeInterval = 0.2

    private(set) var pending: [Double] = []
    private var sentAt: Date?

    /// Adds a reading; returns the readings to send when it's time (the first at once).
    mutating func add(_ value: Double, at now: Date) -> [Double]? {
        // Two places say as much as a meter can show, and keep the message short.
        pending.append((min(1, max(0, value)) * 100).rounded() / 100)
        if pending.count > LinkLevels.maximumValues { pending.removeFirst(pending.count - LinkLevels.maximumValues) }
        if let sentAt, now.timeIntervalSince(sentAt) < Self.interval { return nil }
        sentAt = now
        defer { pending = [] }
        return pending
    }
}
