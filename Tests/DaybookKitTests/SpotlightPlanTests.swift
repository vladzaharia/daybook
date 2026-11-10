import DaybookCore
import XCTest
@testable import DaybookKit

/// What Spotlight lists of the library on both apps (`SpotlightPlan`): every conversation but Personal ones, by title
/// and date, newest first; a run's first pass starts over, and each later one sends only what changed.
final class SpotlightPlanTests: XCTestCase {
    private func meeting(_ title: String, at seconds: TimeInterval, _ placement: LibraryPlacement? = nil) -> Meeting {
        var meeting = Meeting(title: title, date: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
        meeting.placement = placement
        return meeting
    }

    func testBehaviorEveryConversationButPersonalOnesIsListedNewestFirst() {
        let work = meeting("Pricing review", at: 0, .work)
        let personal = meeting("Therapy", at: 100, .personal)
        let unsorted = meeting("Conversation at 10:15 AM", at: 200)
        XCTAssertTrue(SpotlightPlan.isShown(work))
        XCTAssertFalse(SpotlightPlan.isShown(personal), "never named outside the app")
        XCTAssertTrue(SpotlightPlan.isShown(unsorted))
        XCTAssertEqual(SpotlightPlan.entries([work, personal, unsorted]).map(\.title), ["Conversation at 10:15 AM", "Pricing review"])
        XCTAssertEqual(SpotlightPlan.Entry(work), SpotlightPlan.Entry(id: work.id, title: "Pricing review", date: work.date),
                       "its title and date, never what was said")
    }

    func testBehaviorTheFirstPassStartsOverAndLaterOnesSendOnlyWhatChanged() throws {
        var plan = SpotlightPlan()
        XCTAssertNil(plan.listed)
        let work = meeting("Pricing review", at: 0, .work)
        let unsorted = meeting("Conversation at 10:15 AM", at: 200)

        let first = try XCTUnwrap(plan.pass(to: SpotlightPlan.entries([work, unsorted])))
        XCTAssertTrue(first.startsOver, "what an earlier run listed goes first: it may have been trashed or made Personal since")
        XCTAssertEqual(first.listed.map(\.title), ["Conversation at 10:15 AM", "Pricing review"])
        XCTAssertEqual(first.removed, [])
        XCTAssertEqual(plan.listed?.count, 2)

        // Renamed, and the other moved to Personal: one listed again, one taken out.
        var renamed = unsorted
        renamed.title = "Hiring sync"
        var nowPersonal = work
        nowPersonal.placement = .personal
        let second = try XCTUnwrap(plan.pass(to: SpotlightPlan.entries([nowPersonal, renamed])))
        XCTAssertFalse(second.startsOver, "once a run")
        XCTAssertEqual(second.listed.map(\.title), ["Hiring sync"])
        XCTAssertEqual(second.removed, [work.id])

        XCTAssertNil(plan.pass(to: SpotlightPlan.entries([nowPersonal, renamed])), "nothing changed, nothing sent")

        // A new summary or notes aren't a change for Spotlight; an empty library starts nothing over.
        var summarized = renamed
        summarized.notes = "Agenda"
        XCTAssertNil(plan.pass(to: SpotlightPlan.entries([summarized])))
        var empty = SpotlightPlan()
        XCTAssertEqual(empty.pass(to: []), SpotlightPlan.Pass(startsOver: true, removed: [], listed: []))
    }
}
