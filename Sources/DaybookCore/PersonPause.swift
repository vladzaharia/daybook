import Foundation

/// A stretch of a recording the person paused (docs/capture.md, "Pausing"), in that recording's seconds. What was said
/// then was never kept: the recording is silent there. The pause holds for the whole conversation, not only the
/// recording that made it: nothing heard in it is transcribed (`keepsWord`), and no other device's recording joins the
/// conversation over it (`admits`), since none of them paused with it.
public struct PersonPause: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start; self.end = max(start, end)
    }

    /// How far another device's clock and its recording's start may be from this one's: a recording that comes within
    /// this of a pause is taken to overlap it.
    public static let margin: TimeInterval = 30

    /// Whether a word (or a passage without words) from `start` to `end` in the recording is kept: one wholly inside a
    /// pause was heard in silence, so a model made it up.
    public static func keepsWord(start: TimeInterval, end: TimeInterval, in pauses: [PersonPause]) -> Bool {
        !pauses.contains { start >= $0.start && end <= $0.end }
    }

    /// Whether a recording from another device (a recorder's, an iPhone's, a Watch's, a file matched by time) may join
    /// `meeting`: always, when the conversation was never paused; otherwise only when its start is known (on the
    /// conversation's clock) and it comes nowhere near a pause, within `margin`. One that can't be placed that surely
    /// is its own conversation: its audio in a pause can't be found reliably enough to silence it.
    public static func admits(start: Date?, duration: TimeInterval, into meeting: Meeting) -> Bool {
        guard let spans = meeting.personPauseSpans else { return true }
        guard let start, duration.isFinite else { return false }
        let from = start.addingTimeInterval(-margin), to = start.addingTimeInterval(max(0, duration) + margin)
        return !spans.contains { $0.start < to && $0.end > from }
    }
}

public extension Meeting {
    /// The person's pauses on the wall clock, from the recordings that made them; nil when none was paused. A paused
    /// recording whose start isn't known makes the whole conversation's time a pause.
    var personPauseSpans: [DateInterval]? {
        let paused = tracks.filter { !($0.capture?.pauses ?? []).isEmpty }
        guard !paused.isEmpty else { return nil }
        return paused.flatMap { track -> [DateInterval] in
            guard let startedAt = track.startedAt else { return [DateInterval(start: .distantPast, end: .distantFuture)] }
            return (track.capture?.pauses ?? []).map {
                DateInterval(start: startedAt.addingTimeInterval($0.start), end: startedAt.addingTimeInterval($0.end))
            }
        }
    }
}
