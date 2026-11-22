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

    func testBehaviorPhotosAddedAMomentApartReadAsOneRow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func photo(_ seconds: TimeInterval, _ what: String) -> MeetingRevision {
            MeetingRevision(date: now.addingTimeInterval(-seconds), field: "photo:\(UUID().uuidString)", oldValue: "", newValue: what)
        }
        let notes = MeetingRevision(date: now.addingTimeInterval(-900), field: "notes", oldValue: "", newValue: "Agenda")
        let first = photo(300, "added"), second = photo(280, "added"), third = photo(260, "added")
        let later = photo(60, "added"), deleted = photo(50, "removed")
        let entries = VersionHistoryList.entries([notes, first, second, third, later, deleted], now: now, calendar: calendar)[0].entries
        XCTAssertEqual(entries.map(\.count), [1, 1, 3, 1], "newest first: the deletion alone, the later photo alone (a different minute), three together, the notes")
        XCTAssertEqual(entries[2].id, third.id, "a merged row stands for its newest change")
        let meeting = Meeting(title: "Sync")
        XCTAssertEqual(RevisionText.title(third, count: 3, in: meeting), "3 Photos added")
        XCTAssertEqual(RevisionText.title(deleted, count: 2, in: meeting), "2 Photos deleted")
        XCTAssertEqual(RevisionText.title(third, count: 1, in: meeting), "Photo added")
    }

    func testBehaviorChangesWithWordsAreNeverMerged() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let edits = (0..<3).map { MeetingRevision(date: now.addingTimeInterval(-Double($0) * 5), field: "notes", oldValue: "a", newValue: "b") }
        XCTAssertEqual(VersionHistoryList.entries(edits, now: now, calendar: calendar)[0].entries.map(\.count), [1, 1, 1])
        let pages = (0..<2).map { MeetingRevision(date: now.addingTimeInterval(-Double($0) * 5), field: "page:\(UUID().uuidString)", oldValue: "", newValue: "added") }
        XCTAssertEqual(RevisionText.title(pages[0], count: 2, in: Meeting(title: "x")), "2 Pages added")
    }
}
