import Foundation

// Rules both apps share for a recording made on several devices at once (docs/multipoint.md), so the
// Mac and the iPhone place it, and name it, the same way.

/// Where a shared recording's timeline begins.
public enum MultipointTimeline {
    /// The conversation's timeline zero on this device's clock, from what the device leading the
    /// recording said: its timeline zero (earlier than its own start when it records into a conversation
    /// that already had recordings) or, from an older device that didn't say, its own recording's start,
    /// both on its clock, moved onto this device's by `clockOffset` (the leader's clock − this one's) when
    /// that's known. Nil when the leader said neither.
    public static func zero(timelineStart: Date?, leadStartedAt: Date?, clockOffset: TimeInterval?) -> Date? {
        guard let start = timelineStart ?? leadStartedAt else { return nil }
        return clockOffset.map { start.addingTimeInterval(-$0) } ?? start
    }

    /// Seconds into the conversation's timeline where a recording that started at `start` (this device's
    /// clock) begins; nil when the timeline's zero isn't known.
    public static func offset(of start: Date, from zero: Date?) -> TimeInterval? {
        zero.map { start.timeIntervalSince($0) }
    }
}

extension Meeting {
    /// The title of a conversation that starts with nothing to name it by: "Conversation at 10:15 AM", or a
    /// recorder's "Soundcore Work at 10:02 AM". The same on the Mac and the iPhone.
    public static func defaultTitle(_ name: String = "Conversation", startingAt date: Date = Date()) -> String {
        "\(name) at \(date.formatted(date: .omitted, time: .shortened))"
    }
}
