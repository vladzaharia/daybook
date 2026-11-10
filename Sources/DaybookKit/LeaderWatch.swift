import DaybookCore
import Foundation

/// A device recording because another asked it to (docs/multipoint.md, "Who stops whom") follows that device on
/// evidence, not on silence. The same rule on the Mac (a phone leads) and the iPhone (a Mac leads):
///
/// - Silent on the link for `noticeAfter` (about two minutes): it says so, without stopping ("Alex’s iPhone is out of
///   reach. This Mac keeps recording.").
/// - The leader's sync presence says it records the same conversation: it keeps going. Presence written since the link
///   went quiet that says it doesn't: it stops, as the leader's stop would have.
/// - Silent for `silenceLimit` (30 minutes) with no evidence either way: it stops only if its own input has also been
///   quiet (below speech) for `quietRoom` (10 minutes). Otherwise it keeps recording, with the notice up.
public enum LeaderWatch {
    /// Silent this long, the follower says the leader is out of reach.
    public static let noticeAfter: TimeInterval = 2 * 60
    /// Silent this long with no evidence, a quiet room ends the recording.
    public static let silenceLimit: TimeInterval = 30 * 60
    /// The follower's own input below speech for this long is a quiet room.
    public static let quietRoom: TimeInterval = 10 * 60
    /// Presence must have been heard this long after the link went quiet to say the leader stopped since, so a record
    /// written just before (or two clocks a little apart) never reads as new.
    static let presenceMargin: TimeInterval = 60

    /// What the leader's presence says about the recording it leads.
    public enum Evidence: Equatable, Sendable {
        /// It records the conversation (its activity hasn't expired).
        case recording
        /// Written since the link went quiet, it records something else, or nothing.
        case stopped
        /// Nothing new: no presence, or a record from before the link went quiet whose activity has expired.
        case unknown
    }

    /// What the follower does now.
    public enum Verdict: Equatable, Sendable {
        /// The leader is connected, or quiet too briefly to mention.
        case following
        /// Out of reach: say so, and keep recording.
        case outOfReach
        /// Stop, as the leader's stop would have: its presence says it stopped.
        case leaderStopped
        /// Stop: silent for `silenceLimit`, with no evidence, in a quiet room.
        case quietAndUnreachable
    }

    /// The evidence in a leader's presence (`KnownSyncDevice`, from `knownDevices()`), for the recording of
    /// `conversation`, given when the link went quiet. Every time is on the reader's clock.
    public static func evidence(_ leader: KnownSyncDevice?, conversation: UUID, silentSince: Date, now: Date) -> Evidence {
        guard let leader, let lastSeen = leader.lastSeen else { return .unknown }
        if let activity = leader.activity, activity.expiresAt > now, activity.recordingConversationID == conversation {
            return .recording
        }
        // A record that keeps its activity to itself (its device waits for an encrypted library's key, or this one can't
        // open it) says nothing about the recording: its name goes with it.
        guard leader.displayName != nil else { return .unknown }
        // When this device heard the record change (its own clock), else when its writer says it wrote it.
        let heard = leader.lastHeard ?? lastSeen
        return heard > silentSince.addingTimeInterval(presenceMargin) ? .stopped : .unknown
    }

    /// The verdict, from when the link went quiet (nil: connected), the presence evidence, and when the follower's own
    /// input last heard something as loud as speech (nil: never, so since `recordingSince`).
    public static func verdict(silentSince: Date?, evidence: Evidence, lastHeardSpeech: Date?, recordingSince: Date?,
                               now: Date) -> Verdict {
        guard let silentSince else { return .following }
        let silence = now.timeIntervalSince(silentSince)
        guard silence >= noticeAfter else { return .following }
        switch evidence {
        case .recording: return .outOfReach
        case .stopped: return .leaderStopped
        case .unknown:
            guard silence > silenceLimit else { return .outOfReach }
            let heard = lastHeardSpeech ?? recordingSince ?? silentSince
            return now.timeIntervalSince(heard) >= quietRoom ? .quietAndUnreachable : .outOfReach
        }
    }

    // MARK: Words

    /// The notice while the leader is out of reach: "Alex’s iPhone is out of reach. This Mac keeps recording." `here` is
    /// how this device calls itself in a sentence ("this Mac", "this iPhone").
    public static func outOfReach(_ leader: String, here: String) -> String {
        "\(leader) is out of reach. \(capitalized(here)) keeps recording."
    }

    /// The chip's short label: "Out of reach".
    public static let outOfReachLabel = "Out of reach"

    /// Why the follower stopped: "Alex’s iPhone stopped recording, so this Mac stopped too."
    public static func leaderStopped(_ leader: String, here: String) -> String {
        "\(leader) stopped recording, so \(here) stopped too."
    }

    /// Why the follower stopped on its own: "Alex’s iPhone couldn’t be reached for 30 minutes and the room was quiet, so
    /// this Mac stopped recording."
    public static func stoppedUnreachable(_ leader: String, here: String) -> String {
        "\(leader) couldn’t be reached for \(Int(silenceLimit / 60)) minutes and the room was quiet, so \(here) stopped recording."
    }

    static func capitalized(_ words: String) -> String { words.prefix(1).uppercased() + words.dropFirst() }
}
