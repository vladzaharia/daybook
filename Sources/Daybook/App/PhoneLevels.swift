import DaybookLink
import Foundation

/// The input levels paired iPhones send while they record a conversation with this Mac (`LinkLevels`,
/// a few readings a few times a second), kept for Floating Notes' meters to play back at their own
/// pace, a reading a tick. Not observable: only the meters read it, fifteen times a second.
@MainActor
final class PhoneLevels {
    private struct Feed {
        var conversationID: UUID
        var pending: [Double] = []
        var last: Double = 0
        var heardAt: Date
    }

    /// How long a phone's level counts as current after its last message.
    static let lifetime: TimeInterval = 1.5
    /// The most readings waiting per phone, about a second's: older ones go first, so the meter keeps up.
    static let backlog = 15

    private var feeds: [UUID: Feed] = [:]

    func receive(_ message: LinkLevels, from phone: UUID, at now: Date = Date()) {
        var feed = feeds[phone].flatMap { $0.conversationID == message.conversationID ? $0 : nil }
            ?? Feed(conversationID: message.conversationID, heardAt: now)
        feed.pending.append(contentsOf: message.values)
        if feed.pending.count > Self.backlog { feed.pending.removeFirst(feed.pending.count - Self.backlog) }
        feed.heardAt = now
        feeds[phone] = feed
    }

    /// The phone's next reading for `conversation`; nil when it hasn't sent one lately (an iPhone that
    /// doesn't send levels, or one that stopped). Between messages the last reading fades.
    func next(_ phone: UUID, conversation: UUID, at now: Date = Date()) -> Double? {
        guard var feed = feeds[phone], feed.conversationID == conversation, now.timeIntervalSince(feed.heardAt) < Self.lifetime else { return nil }
        if feed.pending.isEmpty {
            feed.last *= 0.8
        } else {
            feed.last = feed.pending.removeFirst()
        }
        feeds[phone] = feed
        return feed.last
    }

    func reset() { feeds = [:] }
}

extension AppState {
    /// A paired iPhone recording this conversation too sent its input level: Floating Notes draws it.
    func phoneLevelled(_ message: LinkLevels, from phone: UUID) {
        guard let id = recordingID, message.conversationID == id else { return }
        phoneLevels.receive(message, from: phone)
    }
}
