import Foundation

/// A device's meter readings on their way to the devices recording the same conversation that draw them (`LinkLevels`):
/// gathered as its meter reads them, about fifteen a second, and sent a few at a time about five times a second, so the
/// link carries a few small messages a second rather than one per reading. An iPhone sends its microphone's readings; a
/// Mac the louder of its microphone's and its computer audio's, each tick.
public struct LevelShare: Sendable {
    public static let interval: TimeInterval = 0.2

    public private(set) var pending: [Double] = []
    private var sentAt: Date?

    public init() {}

    /// Adds a reading; returns the readings to send when it's time (the first at once).
    public mutating func add(_ value: Double, at now: Date) -> [Double]? {
        // Two places say as much as a meter can show, and keep the message short.
        pending.append((min(1, max(0, value.isFinite ? value : 0)) * 100).rounded() / 100)
        if pending.count > LinkLevels.maximumValues { pending.removeFirst(pending.count - LinkLevels.maximumValues) }
        if let sentAt, now.timeIntervalSince(sentAt) < Self.interval { return nil }
        sentAt = now
        defer { pending = [] }
        return pending
    }
}

/// The input levels other devices send while they record a conversation with this one (`LinkLevels`, a few readings a
/// few times a second), kept for a meter to play back at its own pace: a reading a tick, the last one fading between
/// messages, and none from a device quiet for `lifetime`. The Mac plays back each iPhone's (`PhoneLevels`), the iPhone
/// each Mac's.
public struct LevelPlayback: Sendable {
    private struct Feed: Sendable {
        var conversationID: UUID
        var pending: [Double] = []
        var last: Double = 0
        var heardAt: Date
    }

    /// How long a device's level counts as current after its last message.
    public static let lifetime: TimeInterval = 1.5
    /// The most readings waiting per device, about a second's: older ones go first, so the meter keeps up.
    public static let backlog = 15

    private var feeds: [UUID: Feed] = [:]

    public init() {}

    public mutating func receive(_ message: LinkLevels, from device: UUID, at now: Date = Date()) {
        var feed = feeds[device].flatMap { $0.conversationID == message.conversationID ? $0 : nil }
            ?? Feed(conversationID: message.conversationID, heardAt: now)
        feed.pending.append(contentsOf: message.values)
        if feed.pending.count > Self.backlog { feed.pending.removeFirst(feed.pending.count - Self.backlog) }
        feed.heardAt = now
        feeds[device] = feed
    }

    /// The device's next reading for `conversation`; nil when it hasn't sent one lately (a device that doesn't send
    /// levels, or one that stopped). Between messages the last reading fades.
    public mutating func next(_ device: UUID, conversation: UUID, at now: Date = Date()) -> Double? {
        guard var feed = current(device, conversation: conversation, at: now) else { return nil }
        if feed.pending.isEmpty {
            feed.last *= 0.8
        } else {
            feed.last = feed.pending.removeFirst()
        }
        feeds[device] = feed
        return feed.last
    }

    /// The device's newest reading for `conversation`, leaving the meter's queue as it is; nil when it hasn't sent one
    /// lately. Live captions compare it with other sources' (`LiveCaptionMixer`).
    public func last(_ device: UUID, conversation: UUID, at now: Date = Date()) -> Double? {
        guard let feed = current(device, conversation: conversation, at: now) else { return nil }
        return feed.pending.last ?? feed.last
    }

    public mutating func reset() { feeds = [:] }

    private func current(_ device: UUID, conversation: UUID, at now: Date) -> Feed? {
        guard let feed = feeds[device], feed.conversationID == conversation, now.timeIntervalSince(feed.heardAt) < Self.lifetime else { return nil }
        return feed
    }
}
