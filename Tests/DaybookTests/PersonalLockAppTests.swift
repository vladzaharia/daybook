import DaybookCore
import DaybookKit
import DaybookTestSupport
import XCTest
@testable import Daybook

/// The Mac's side of the Personal lock (docs/architecture.md, "The Personal lock"): the selection is the one gate the
/// page, the inspector, Version History, Share, and Floating Notes go through, so a Personal conversation is selected
/// only once Touch ID (a stand-in here) says so; locking again lets it go; what the app selects by itself never asks; a
/// Focus that leaves Personal out leaves it out of the places, search, and the call prompt's asking; and processing
/// never asks.
@MainActor
final class PersonalLockAppTests: XCTestCase {
    private struct Rig {
        let state: AppState
        let authenticator: FakePersonalLockAuthenticator
        let personal: UUID
        let work: UUID
    }

    private func rig(locked: Bool = true, answers: Bool = true) async throws -> Rig {
        let defaults = makeTestDefaults("PersonalLockAppTests")
        defaults.set(false, forKey: "showsFloatingNotesWhileRecording")
        let state = AppState(libraryURL: makeTemporaryFolder("PersonalLockAppTests"), defaults: defaults)
        await state.initialize()
        let authenticator = FakePersonalLockAuthenticator(answers: answers)
        state.personalLock.authenticator = authenticator
        let work = state.library.newMeeting(title: "Weekly product sync", date: Date(timeIntervalSince1970: 1_800_000_000), placement: .work)
        let personal = state.library.newMeeting(title: "Session with Dr. Lee", date: Date(timeIntervalSince1970: 1_800_000_600), placement: .personal)
        if locked { await state.personalLock.setRequired(true) }
        return Rig(state: state, authenticator: authenticator, personal: personal, work: work)
    }

    // MARK: The selection

    func testBehaviorAPersonalConversationIsSelectedOnlyOnceThePersonUnlocksIt() async throws {
        let rig = try await rig(answers: false)
        let state = rig.state
        state.selectedID = rig.work
        XCTAssertEqual(state.selectedID, rig.work)

        state.selectedID = rig.personal
        try await waitUntil("Touch ID to be asked") { rig.authenticator.asked == 1 }
        await Task.yield()
        XCTAssertEqual(state.selectedID, rig.work, "cancelled: the selection stays where it was")
        XCTAssertNotEqual(state.selectedMeeting?.id, rig.personal, "so nothing shows it")

        rig.authenticator.answers(true)
        state.selectedID = rig.personal
        try await waitUntil("it to be selected") { state.selectedID == rig.personal }
        XCTAssertFalse(state.personalLock.isLocked)
        XCTAssertEqual(rig.authenticator.asked, 2)
    }

    func testBehaviorLockingAgainLetsAPersonalPageGo() async throws {
        let rig = try await rig()
        let state = rig.state
        state.selectedID = rig.personal
        try await waitUntil("it to be selected") { state.selectedID == rig.personal }

        state.multiSelection = [rig.personal, rig.work]
        state.personalLock.lock()
        XCTAssertEqual(state.selectedID, rig.work, "the place's first that isn't hidden takes its place")
        XCTAssertEqual(state.multiSelection, [], "a selection of several holding it lets go")
    }

    func testBehaviorWhatTheAppSelectsByItselfNeverAsks() async throws {
        let rig = try await rig()
        let state = rig.state
        state.selectQuietly(rig.personal)
        XCTAssertEqual(state.selectedID, rig.work, "the newest is Personal and locked: the first that isn't")
        XCTAssertEqual(rig.authenticator.asked, 0)
        state.place = .section(.personal)
        state.selectQuietly(state.visibleMeetings.first?.id)
        XCTAssertNil(state.selectedID, "everything here is hidden")
        XCTAssertEqual(rig.authenticator.asked, 0)

        await state.unlockPersonal()
        XCTAssertEqual(state.selectedID, rig.personal, "choosing Personal, or Unlock on its page, opens its newest")
        XCTAssertEqual(rig.authenticator.asked, 1)
    }

    func testBehaviorWithTheLockOffNothingAsks() async throws {
        let rig = try await rig(locked: false)
        rig.state.selectedID = rig.personal
        XCTAssertEqual(rig.state.selectedID, rig.personal)
        XCTAssertEqual(rig.authenticator.asked, 0)
    }

    // MARK: Work goes on

    func testBehaviorProcessingAPersonalConversationNeverAsks() async throws {
        let rig = try await rig(answers: false)
        let state = rig.state
        state.update(rig.personal) { $0.notes = "Written while it was locked." }
        state.enqueue(rig.personal, mode: .summaryOnly)
        XCTAssertTrue(state.queue.isQueued(rig.personal) || state.queue.awaitingModels.contains(rig.personal)
                        || state.queue.awaitingSummaryModel.contains(rig.personal),
                      "the queue takes it as it would unlocked (a Summarize waits for the summary model when it isn't here)")
        XCTAssertEqual(state.meetings.first { $0.id == rig.personal }?.notes, "Written while it was locked.")
        XCTAssertEqual(rig.authenticator.asked, 0)
        XCTAssertTrue(state.personalLock.isLocked)
    }

    // MARK: Focus

    func testBehaviorAFocusThatHidesPersonalLeavesItOutOfThePlacesAndSearch() async throws {
        let rig = try await rig(locked: false)
        let state = rig.state
        state.place = .section(.personal)
        XCTAssertEqual(state.visibleMeetings.map(\.id), [rig.personal])

        state.personalLock.apply(PersonalFocus(showsPersonal: false))
        XCTAssertEqual(state.place, .section(.all), "the Personal place gives way")
        XCTAssertEqual(state.visibleMeetings.map(\.id), [rig.work], "All leaves Personal out")
        XCTAssertEqual(state.personalLock.sections, [.all, .work], "and so does the sidebar")
        state.search = "Session"
        try await waitUntil("search to settle") { state.searchHits.isEmpty }

        state.personalLock.apply(PersonalFocus())
        XCTAssertEqual(state.visibleMeetings.map(\.id), [rig.personal, rig.work], "the Focus ended")
        try await waitUntil("search to find it again") { state.searchHits.map(\.meetingID) == [rig.personal] }
    }

    func testBehaviorAFocusThatTurnsAskingOffLeavesACallAlone() {
        XCTAssertEqual(CallPolicy.decision(for: "us.zoom.xos", policy: .ask, choices: [:], busy: false, asks: false), .ignore,
                       "Ask to Record Meetings off: not asked")
        XCTAssertEqual(CallPolicy.decision(for: "us.zoom.xos", policy: .record, choices: ["us.zoom.xos": .ask], busy: false, asks: false),
                       .ignore, "an app's own Ask is asking too")
        XCTAssertEqual(CallPolicy.decision(for: "us.zoom.xos", policy: .record, choices: [:], busy: false, asks: false), .record,
                       "Record Automatically isn't asking")
        XCTAssertEqual(CallPolicy.decision(for: "us.zoom.xos", policy: .ask, choices: [:], busy: false), .ask, "outside a Focus")
    }

    func testBehaviorAFocusThatTurnsAskingOffLetsAMeetingStartUnasked() async throws {
        let rig = try await rig(locked: false)
        let state = rig.state
        state.personalLock.apply(PersonalFocus(asksToRecord: false))
        let meeting = MeetingEvent(id: "standup", title: "Standup", start: Date(), end: Date().addingTimeInterval(900), attendees: 4)
        state.askToRecord(meeting)
        XCTAssertNil(CallPromptWindow.shared.question, "no prompt")
        XCTAssertTrue(state.askedMeetings.contains("standup"), "and it isn't asked about later in the Focus either")
    }

    // MARK: Words

    /// The filter's words are literals the system reads from the app; they're the ones both apps share.
    func testBehaviorTheFocusFilterSaysTheSharedWords() {
        XCTAssertEqual(String(localized: DaybookFocusFilter.title), PersonalLockWords.focusFilter)
        let filter = DaybookFocusFilter()
        XCTAssertEqual(filter.$showsPersonal.title.key, PersonalLockWords.showPersonal)
        XCTAssertEqual(filter.$asksToRecord.title.key, PersonalLockWords.askToRecord)
    }
}
