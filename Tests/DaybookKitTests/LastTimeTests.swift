import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Which earlier conversation is "last time" for a meeting that starts recording.
@MainActor
final class LastTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(_ title: String, daysAgo: Double, steps: [(String, Bool)] = [], placement: LibraryPlacement? = nil,
                         status: MeetingStatus = .ready) -> Meeting {
        var meeting = Meeting(title: title)
        meeting.date = now.addingTimeInterval(-daysAgo * 86_400)
        meeting.placement = placement
        meeting.status = status
        if !steps.isEmpty {
            meeting.summary = MeetingSummary(overview: "", actionItems: steps.map { ActionItem(text: $0.0, completed: $0.1) })
        }
        return meeting
    }

    private func find(_ title: String, in meetings: [Meeting], placement: LibraryPlacement? = nil, excluding: UUID? = nil,
                      isAllowed: (Meeting) -> Bool = { _ in true }) -> LastTime? {
        LastTime.find(title: title, startedAt: now, excluding: excluding, placement: placement, in: meetings, isAllowed: isAllowed)
    }

    func testBehaviorTheNewestEarlierConversationWithTheSameTitleIsLastTimeWithItsOpenSteps() {
        let older = meeting("Weekly sync", daysAgo: 14, steps: [("Old", false)])
        let last = meeting("Weekly sync", daysAgo: 7, steps: [("Send the budget", false), ("Book the room", true), ("Hire", false)])
        let found = find("Weekly sync", in: [older, last])
        XCTAssertEqual(found?.meetingID, last.id)
        XCTAssertEqual(found?.date, last.date)
        XCTAssertEqual(found?.openSteps.map(\.text), ["Send the budget", "Hire"], "Done steps are left out")
    }

    func testBehaviorTheTimeDaybookAddsToATitleIsLeftOutOnBothSides() {
        let last = meeting("Weekly sync at 10:15 AM", daysAgo: 7)
        let other = meeting("Weekly sync at 9:00\u{202F}AM", daysAgo: 14)
        XCTAssertEqual(find("Weekly sync", in: [other, last])?.meetingID, last.id)
        XCTAssertEqual(find("weekly SYNC at 3:30 PM", in: [other, last])?.meetingID, last.id)
        XCTAssertEqual(LastTime.seriesKey("Weekly sync at 10:15"), "weekly sync")
        XCTAssertEqual(LastTime.seriesKey("Look at 10 things"), "look at 10 things", "Only a time at the end is dropped")
    }

    func testBehaviorATitleThatOnlySharesAPrefixIsAnotherMeeting() {
        let longer = meeting("Weekly sync review", daysAgo: 7)
        let shorter = meeting("Weekly", daysAgo: 8)
        XCTAssertNil(find("Weekly sync", in: [longer, shorter]))
    }

    func testBehaviorNothingMatchesWithoutAnEarlierConversationOrAThisOneOrAnUnfinishedOne() {
        let current = meeting("Weekly sync", daysAgo: 0)
        let later = meeting("Weekly sync", daysAgo: -1)
        let recording = meeting("Weekly sync", daysAgo: 2, status: .recording)
        XCTAssertNil(find("Weekly sync", in: [current, later, recording], excluding: current.id))
        XCTAssertNil(find("Weekly sync", in: []))
        XCTAssertNil(find("  ", in: [meeting("", daysAgo: 3)]), "An empty title is no meeting")
    }

    func testBehaviorAPersonalConversationTheLockHidesIsNeverShownNorSwappedForAnOlderOne() {
        let work = meeting("1:1", daysAgo: 14, placement: .work)
        let personal = meeting("1:1", daysAgo: 7, placement: .personal)
        XCTAssertEqual(find("1:1", in: [work, personal])?.meetingID, personal.id, "Unlocked, it's the newest")
        XCTAssertNil(find("1:1", in: [work, personal], isAllowed: { $0.effectivePlacement != .personal }))
    }

    func testBehaviorAWorkRecordingNeverShowsAPersonalConversationAndANewOneShowsEither() {
        let work = meeting("1:1", daysAgo: 14, placement: .work)
        let personal = meeting("1:1", daysAgo: 7, placement: .personal)
        XCTAssertEqual(find("1:1", in: [work, personal], placement: .work)?.meetingID, work.id)
        XCTAssertEqual(find("1:1", in: [work, personal], placement: .personal)?.meetingID, personal.id)
    }

    func testBehaviorAMergedConversationIsLastTimeUnderItsOwnTitleAndDate() {
        // A merge leaves one conversation (its sources go to the Trash), which reads like any other.
        let merged = meeting("Weekly sync", daysAgo: 3, steps: [("From both halves", false)])
        let found = find("Weekly sync", in: [merged])
        XCTAssertEqual(found?.meetingID, merged.id)
        XCTAssertEqual(found?.openSteps.count, 1)
    }

    func testBehaviorAConversationInTheTrashIsNotLastTime() async throws {
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookLastTime"), sync: nil)
        try await library.load()
        let earlier = library.newMeeting(title: "Weekly sync")
        library.update(earlier) { $0.date = Date(timeIntervalSinceNow: -14 * 86_400) }
        let trashed = library.newMeeting(title: "Weekly sync")
        library.update(trashed) { $0.date = Date(timeIntervalSinceNow: -7 * 86_400) }
        XCTAssertEqual(LastTime.find(title: "Weekly sync", startedAt: Date(), excluding: nil, placement: nil, in: library.meetings)?.meetingID, trashed)
        _ = try await library.moveToTrash(trashed)
        XCTAssertEqual(LastTime.find(title: "Weekly sync", startedAt: Date(), excluding: nil, placement: nil, in: library.meetings)?.meetingID, earlier)
    }
}
