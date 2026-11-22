import Foundation

/// The moment after Stop on the watch (docs/watch.md, "After Stop"): "Saved · 12:03" with where the recording is going
/// for a few seconds, then, until `keepWindow` has passed since the Stop, Keep Recording beside Record. It is the watch's
/// own record of the Stop (when, which recording, which conversation), kept in its preferences, so lowering the wrist or
/// relaunching the app inside the window changes nothing. Pure, so the Mac tests it.
public struct WatchAfterStop: Codable, Equatable, Sendable {
    /// How long the summary holds the screen.
    public static let holds: TimeInterval = 10
    /// How long after a Stop Keep Recording is offered.
    public static let keepWindow: TimeInterval = 5 * 60

    public var recordingID: String
    /// The conversation Keep Recording records into: the one the recording joined. Nil when it never joined one (the
    /// iPhone wasn't reached), and nothing is offered.
    public var conversationID: UUID?
    public var duration: TimeInterval
    public var stoppedAt: Date

    /// Nil when nothing was recorded or the recording didn't end by a Stop (it ended on its own: its problem is on the
    /// screen instead; or it was closed at launch).
    public init?(recordingID: String, conversationID: UUID?, duration: TimeInterval, stoppedAt: Date, change: WatchChange) {
        guard duration >= 1, change == .stoppedOnWatch || change == .stoppedByPhone else { return nil }
        self.recordingID = recordingID
        self.conversationID = conversationID
        self.duration = duration
        self.stoppedAt = stoppedAt
    }

    /// Whether the summary still shows at `now`.
    public func isShowing(at now: Date) -> Bool { now.timeIntervalSince(stoppedAt) < Self.holds }

    /// When Keep Recording stops being offered.
    public var keepEnds: Date { stoppedAt.addingTimeInterval(Self.keepWindow) }

    /// Whether Keep Recording may be offered at `now`: inside the window, for a conversation. The iPhone has the last
    /// word (`WatchMessage.keep`).
    public func isKeepOpen(at now: Date) -> Bool {
        conversationID != nil && now >= stoppedAt && now < keepEnds
    }

    /// "Saved · 12:03".
    public var title: String { WatchWords.saved(duration) }
}
