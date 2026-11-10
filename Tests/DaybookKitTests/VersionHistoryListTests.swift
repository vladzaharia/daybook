import DaybookCore
import XCTest
@testable import DaybookKit

/// Version History's list as both apps draw it (DaybookUI's `VersionHistoryScreen`): newest first under each day, and
/// the line under a change's title.
final class VersionHistoryListTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testBehaviorChangesAreNewestFirstUnderTheirDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = MeetingRevision(date: now.addingTimeInterval(-86_400 - 600), field: "notes", oldValue: "", newValue: "Agenda")
        let earlier = MeetingRevision(date: now.addingTimeInterval(-3_600), field: "notes", oldValue: "Agenda", newValue: "Agenda, dates")
        let latest = MeetingRevision(date: now.addingTimeInterval(-60), kind: .summary, oldValue: "", newValue: "")
        let days = VersionHistoryList.days([older, earlier, latest], now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.day), ["Today", "Yesterday"])
        XCTAssertEqual(days[0].revisions.map(\.id), [latest.id, earlier.id], "newest first")
        XCTAssertEqual(days[1].revisions.map(\.id), [older.id])
        XCTAssertTrue(VersionHistoryList.days([], now: now, calendar: calendar).isEmpty)
    }

    func testBehaviorTheLineUnderATitleSaysWhatItsAboutOrWhatItSaysNow() {
        var meeting = Meeting(title: "Sync", unifiedTranscript: [TranscriptSegment(trackID: UUID(), start: 83, end: 85, text: "The sink fix")])
        meeting.correctSegment(id: meeting.unifiedTranscript[0].id, text: "The sync fix")
        XCTAssertEqual(VersionHistoryList.detail(meeting.revisions[0], in: meeting), "Passage at 1:23", "what it's about")

        let notes = MeetingRevision(field: "notes", oldValue: "Agenda", newValue: "Agenda\nDates")
        XCTAssertEqual(VersionHistoryList.detail(notes, in: meeting), "Agenda Dates", "what it says now, on one line")
        let emptied = MeetingRevision(field: "notes", oldValue: "Agenda", newValue: "")
        XCTAssertEqual(VersionHistoryList.detail(emptied, in: meeting), VersionHistoryWords.empty)

        let photo = MeetingRevision(field: "photo:\(UUID().uuidString)", oldValue: "", newValue: "added")
        XCTAssertNil(VersionHistoryList.detail(photo, in: meeting), "\"added\" only repeats \"Photo added\"")
    }
}
