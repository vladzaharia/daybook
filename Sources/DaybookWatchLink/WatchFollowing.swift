import Foundation

/// How the watch follows the iPhone's shared recording (docs/watch.md, "Following the iPhone"): when to join it as
/// Daybook opens on the watch, which conversation a recording belongs to, and when the iPhone's word stops it. Pure
/// values, so the Mac tests it; the watch app keeps one (with the newest context and the conversations it left) and
/// does what it decides.
///
/// - Joining and adopting take a fresh context only (`isFresh`): the answer to `.context`, or one sent within
///   `freshness` of the watch's now. A context that waited while the watch was away may name a recording that has ended.
/// - A recording with no conversation yet (started on the wrist, or by a `.start` for none) adopts the shared recording
///   of a fresh context that arrived after it started, with Record Along on: the one the iPhone sends once it knows of
///   the recording. A context the watch already had when it started is never adopted, nor one with Record Along off
///   (the iPhone ignores the watch's button then, and records nothing along with it).
/// - A recording with a conversation stops once a newer context no longer shares it (none, or another one), fresh or
///   not. A context sent before that shared recording started can't know it yet, so it never stops it. The watch's own
///   recording (`Recording.isOwn`) never stops for a context: the iPhone counts it as recording already, and never stops
///   it with the shared recording.
/// - With no recording, Daybook opening (or a context arriving while it's open) joins the shared recording when the
///   iPhone has Record Along on for the watch.
/// - A conversation the watch left (stopped on the wrist, stopped by the iPhone's `.stop`, or ended on its own) is
///   never joined or adopted again on its own, nor is a shared recording that started before a recording with no
///   conversation stopped (the iPhone may have started it for that recording). Only the iPhone's `.start` for it brings
///   the watch back.
public struct WatchFollowing: Codable, Equatable, Sendable {
    /// The recording on the watch, as following sees it.
    public struct Recording: Equatable, Sendable {
        public var id: String
        public var conversationID: UUID?
        /// When its conversation's shared recording started, on the iPhone's clock, when the watch knows it.
        public var conversationStartedAt: Date?
        /// When it started, on the watch's clock: a recording with no conversation adopts only a context that arrived
        /// after it.
        public var startedAt: Date?
        /// The watch's own: the iPhone's `.start` for no conversation started it (`WatchRecordingJournal.isOwn`).
        public var isOwn: Bool

        public init(id: String, conversationID: UUID? = nil, conversationStartedAt: Date? = nil, startedAt: Date? = nil,
                    isOwn: Bool = false) {
            self.id = id
            self.conversationID = conversationID
            self.conversationStartedAt = conversationStartedAt
            self.startedAt = startedAt
            self.isOwn = isOwn
        }
    }

    /// What a context means for the watch.
    public enum Decision: Equatable, Sendable {
        case none
        /// Start recording along with this shared recording (`WatchChange.joined`).
        case join(WatchSharedRecording)
        /// The recording belongs to this shared recording from now on.
        case adopt(WatchSharedRecording)
        /// Stop the recording (`WatchChange.stoppedByPhone`).
        case stop
    }

    /// What the iPhone's `.start` means for the watch.
    public enum StartDecision: Equatable, Sendable {
        /// The recording already records along with that conversation (or, for a start with none, records on its own).
        case recording
        /// The recording (started on the wrist, with no conversation yet) belongs to it from now on.
        case adopt
        /// Start a recording for it (`WatchChange.startedByPhone`).
        case start
        /// Stop the recording, which belongs to another conversation, and start one for it.
        case replace
        /// The watch can't start now: these words go back to the iPhone.
        case refuse(String)
    }

    /// The newest context the iPhone sent.
    public private(set) var context: PhoneContext?
    /// When the newest context arrived, on the watch's clock.
    public private(set) var receivedAt: Date?
    /// When the newest context arrived as the answer to `.context` (fresh as it arrived, whatever the clocks say). Nil
    /// for the application context.
    public private(set) var answeredAt: Date?
    /// Conversations the watch left, oldest first, the most recent `remembered`.
    public private(set) var left: [UUID] = []
    /// When a recording with no conversation last stopped, on the watch's clock: a shared recording that started before
    /// it is left too.
    public private(set) var leftBefore: Date?

    public static let remembered = 20
    /// How long a context counts as fresh: from its answer's arrival, or from its `sentAt`.
    public static let freshness: TimeInterval = 60
    /// How far apart the iPhone's and the watch's clocks may be when a shared recording's start is weighed against the
    /// watch's stop (`leftBefore`).
    public static let clockSlack: TimeInterval = 5
    /// The answer to a `.start` that arrives while Daybook isn't open on the watch: recording must start there.
    public static let openToRecord = "Open Daybook on your Apple Watch to record there too."

    public init() {}

    /// A context arrived: the application context, or the answer to `.context` (`answered`). What to do now. One older
    /// than the newest seen changes nothing; the same one again keeps when it first arrived. `canStart` is whether the
    /// watch may start recording (Daybook is open on it).
    public mutating func received(_ context: PhoneContext, answered: Bool = false, at now: Date = Date(),
                                  recording: Recording?, canStart: Bool) -> Decision {
        if let newest = self.context, context.sentAt < newest.sentAt { return .none }
        if context != self.context {
            self.context = context
            receivedAt = now
            answeredAt = nil
        }
        if answered { answeredAt = now }
        return follow(recording: recording, canStart: canStart, at: now)
    }

    /// Whether the newest context can be joined or adopted now: its answer arrived, or it was sent, within `freshness`.
    public func isFresh(at now: Date = Date()) -> Bool {
        guard let context else { return false }
        return abs(now.timeIntervalSince(answeredAt ?? context.sentAt)) <= Self.freshness
    }

    /// What the newest context means now: as Daybook opens, once a recording has started, or after one stopped.
    public func follow(recording: Recording?, canStart: Bool, at now: Date = Date()) -> Decision {
        guard let context else { return .none }
        let shared = context.sharedRecording
        if let recording {
            guard let conversation = recording.conversationID else {
                guard let shared, context.recordsAlong, isFresh(at: now), !hasLeft(shared) else { return .none }
                if let started = recording.startedAt, let receivedAt, receivedAt < started { return .none }
                return .adopt(shared)
            }
            if shared?.conversationID == conversation || recording.isOwn { return .none }
            if let began = recording.conversationStartedAt {
                if context.sentAt < began { return .none }
            } else if let started = recording.startedAt, let receivedAt, receivedAt < started {
                // Not knowing when its shared recording started, a context that came before the recording can't stop it.
                return .none
            }
            return .stop
        }
        guard canStart, context.recordsAlong, let shared, isFresh(at: now), !hasLeft(shared) else { return .none }
        return .join(shared)
    }

    /// Whether the watch left this shared recording: its conversation, or a recording with no conversation stopped
    /// after it started.
    public func hasLeft(_ shared: WatchSharedRecording) -> Bool {
        if left.contains(shared.conversationID) { return true }
        guard let leftBefore else { return false }
        return shared.startedAt < leftBefore.addingTimeInterval(Self.clockSlack)
    }

    /// The iPhone asked the watch to record along with a conversation, or on its own (`conversationID` nil). An explicit
    /// start brings the watch back to a conversation it left.
    public mutating func start(_ start: WatchStart, recording: Recording?, canStart: Bool) -> StartDecision {
        let decision: StartDecision
        if let recording {
            if recording.conversationID == start.conversationID {
                decision = .recording
            } else if recording.conversationID == nil {
                decision = .adopt
            } else {
                decision = canStart ? .replace : .refuse(Self.openToRecord)
            }
        } else {
            decision = canStart ? .start : .refuse(Self.openToRecord)
        }
        if case .refuse = decision { return decision }
        left.removeAll { $0 == start.conversationID }
        return decision
    }

    /// Whether the iPhone's `.stop` is for this recording: only the one it names, and only one made for the
    /// conversation it names. A `.stop` that arrives while a recording is starting waits for it, then asks this.
    public func stops(_ stop: WatchStop, recording: Recording?) -> Bool {
        guard let recording else { return false }
        if let id = stop.recordingID, id != recording.id { return false }
        if let conversation = stop.conversationID, conversation != recording.conversationID { return false }
        return true
    }

    /// The watch stopped a recording (the person stopped on the wrist, the iPhone's `.stop`, or it ended on its own):
    /// its conversation isn't joined again on its own. With no conversation, no shared recording that started before
    /// `now` is.
    public mutating func leave(_ conversationID: UUID?, at now: Date = Date()) {
        guard let conversationID else {
            leftBefore = max(leftBefore ?? .distantPast, now)
            return
        }
        left.removeAll { $0 == conversationID }
        left.append(conversationID)
        if left.count > Self.remembered { left.removeFirst(left.count - Self.remembered) }
    }
}
