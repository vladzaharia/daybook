import DaybookCore
import Foundation

/// "Last time" for a recurring meeting (docs/capture.md, "Calendar"): the most recent earlier conversation that is the
/// same meeting, with its date and the next steps still open. The library keeps no calendar identity with a
/// conversation, only its title, so the meeting is the same when its title is, without the " at 10:15 AM" Daybook
/// adds, compared without case or accents. A title that only starts the same way is another meeting.
public struct LastTime: Equatable, Sendable {
    public let meetingID: UUID
    public let date: Date
    /// Its next steps not done yet, in the summary's order.
    public let openSteps: [ActionItem]

    /// The conversation as it is now: its date and the steps it still has open.
    public init(_ meeting: Meeting) {
        self.init(meetingID: meeting.id, date: meeting.date, openSteps: (meeting.summary?.actionItems ?? []).filter { !$0.completed })
    }

    public init(meetingID: UUID, date: Date, openSteps: [ActionItem]) {
        self.meetingID = meetingID; self.date = date; self.openSteps = openSteps
    }

    /// How many steps a card lists; the rest are counted.
    public static let listed = 3

    /// A meeting's title without the time Daybook appends, folded for comparing; empty when nothing is left.
    public static func seriesKey(_ title: String) -> String {
        let time = #"\s+at\s+\d{1,2}[:.]\d{2}(?:[\s\x{202F}\x{00A0}]?[AaPp]\.?[Mm]\.?)?\s*$"#
        let bare = title.replacingOccurrences(of: time, with: "", options: .regularExpression)
        return SpeakerProfile.normalizedName(bare)
    }

    /// The conversation before `startedAt` that is the same meeting as `title`, newest first among those that match;
    /// nil when there is none. `meetings` are the library's, so the Trash is not in them. Never the recording itself
    /// (`excluding`), one still recording, or one placed in the other of Work and Personal than `placement`.
    /// `isAllowed` is the lock and Focus: the newest match is the one shown, so a Personal one the lock hides is
    /// never shown, and never swapped for an older one that would read as last time.
    public static func find(title: String, startedAt: Date, excluding: UUID?, placement: LibraryPlacement?, in meetings: [Meeting],
                            isAllowed: (Meeting) -> Bool = { _ in true }) -> LastTime? {
        let key = seriesKey(title)
        guard !key.isEmpty else { return nil }
        let match = meetings
            .filter { meeting in
                meeting.id != excluding && meeting.date < startedAt && meeting.status != .recording && seriesKey(meeting.title) == key
                    && (placement == nil || meeting.effectivePlacement == nil || meeting.effectivePlacement == placement)
            }
            .max { $0.date < $1.date }
        guard let match, isAllowed(match) else { return nil }
        return LastTime(match)
    }
}
