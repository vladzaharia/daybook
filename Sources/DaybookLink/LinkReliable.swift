import Foundation

// Notes and bookmarks are owed until the other side says it has them. A session can be dead before it times out (15 s,
// or a minute while an iPhone records in the background), and a send into it doesn't fail; so each session numbers the
// notes and bookmarks it sends (the frame's `seq`), the peer's heartbeats carry the highest number it has received
// (`Heartbeat.acked`), and what the session ends without hearing acknowledged is sent again, once the same device
// connects again. Notes and bookmarks are kept by their IDs on both apps, so one that arrives twice changes nothing.

extension LinkMessage {
    /// A note or a bookmark: kept until the peer acknowledges it, and sent again on the device's next session.
    var isReliable: Bool {
        switch self {
        case .note, .bookmark, .bookmarkChange: return true
        default: return false
        }
    }
}

/// A note or bookmark sent, waiting to be acknowledged.
struct LinkReliableMessage: Sendable, Equatable {
    var message: LinkMessage
    /// When it was first sent, on this device's clock.
    var firstSentAt: Date
    /// How many times it has been sent, across sessions.
    var sends: Int
}

/// One session's notes and bookmarks on their way: numbered as sent, and dropped as the peer acknowledges them.
struct LinkReliableOutbox {
    /// The most a session keeps waiting for an acknowledgement; past it, the oldest goes.
    static let capacity = 256

    private(set) var lastSequence: UInt64 = 0
    private(set) var unacknowledged: [(sequence: UInt64, item: LinkReliableMessage)] = []
    /// Whether the peer acknowledges: nil until its first heartbeat says (an older build's carries no `acked`).
    private(set) var peerAcknowledges: Bool?

    init(peerAcknowledges: Bool? = nil) { self.peerAcknowledges = peerAcknowledges }

    /// Numbers a message about to be sent, and keeps it unless the peer is known not to acknowledge.
    mutating func number(_ item: LinkReliableMessage) -> UInt64 {
        lastSequence += 1
        if peerAcknowledges != false {
            unacknowledged.append((lastSequence, item))
            if unacknowledged.count > Self.capacity { unacknowledged.removeFirst(unacknowledged.count - Self.capacity) }
        }
        return lastSequence
    }

    /// The peer's heartbeat: everything up to `acked` arrived. None at all: it doesn't acknowledge, and nothing is kept.
    mutating func heard(acked: UInt64?) {
        guard let acked else {
            peerAcknowledges = false
            unacknowledged.removeAll()
            return
        }
        peerAcknowledges = true
        unacknowledged.removeAll { $0.sequence <= acked }
    }

    /// What the session ended without hearing acknowledged, oldest first.
    var leftover: [LinkReliableMessage] { unacknowledged.map(\.item) }
}

/// What a device's ended sessions left unacknowledged, kept by the service or client to send on its next session.
/// Bounded: at most `capacity` per device, none older than `lifetime`, and each sent at most `maximumSends` times (twice
/// to a device not yet known to acknowledge, so an older build gets a note again at most once).
struct LinkReliableKeep {
    static let capacity = 256
    static let lifetime: TimeInterval = 60 * 60
    static let maximumSends = 3

    private var kept: [UUID: [LinkReliableMessage]] = [:]
    /// Devices whose heartbeats acknowledged, and those whose didn't (an older build), as last heard.
    private var acknowledging: [UUID: Bool] = [:]

    /// Whether a device acknowledges, as its last session said.
    func peerAcknowledges(_ device: UUID) -> Bool? { acknowledging[device] }

    /// Kept for a device now (tests, diagnostics).
    func count(for device: UUID) -> Int { kept[device]?.count ?? 0 }

    /// A session with `device` ended: what it left unacknowledged is kept for the next.
    mutating func sessionEnded(with device: UUID, outbox: LinkReliableOutbox, now: Date) {
        if let acknowledges = outbox.peerAcknowledges { acknowledging[device] = acknowledges }
        guard acknowledging[device] != false else { kept[device] = nil; return }
        let limit = acknowledging[device] == true ? Self.maximumSends : 2
        var items = (kept[device] ?? []) + outbox.leftover
        items.removeAll { $0.sends >= limit || now.timeIntervalSince($0.firstSentAt) > Self.lifetime }
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        kept[device] = items.isEmpty ? nil : items
    }

    /// What to send a device's new session first, oldest first; no longer kept here (the session keeps it now).
    mutating func take(for device: UUID, now: Date) -> [LinkReliableMessage] {
        let items = kept.removeValue(forKey: device) ?? []
        return items.filter { now.timeIntervalSince($0.firstSentAt) <= Self.lifetime }
    }

    /// The pair is gone.
    mutating func forget(_ device: UUID) {
        kept[device] = nil
        acknowledging[device] = nil
    }
}
