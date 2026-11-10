import DaybookKit
import XCTest
@testable import DaybookPhone

/// The iPhone's side of the Personal lock (docs/iphone.md, "Personal lock"), with a stand-in for Face ID: opening a
/// Personal conversation, a search hit in one, or the Personal place asks first; the app leaving the screen locks it
/// again and closes what was open of it; the two pages never show a hidden one by themselves; and a Focus filter's
/// choice leaves the Personal place and the meetings' reminders.
@MainActor
final class PersonalLockPhoneTests: XCTestCase {
    private struct Rig {
        let lock: PersonalLock
        let authenticator: FakePersonalLockAuthenticator
        let session: ReadingSession
        let personal: Meeting
        let work: Meeting
    }

    private func rig(answers: Bool = true) async -> Rig {
        var personal = Meeting(title: "Session with Dr. Lee", date: Date(timeIntervalSince1970: 1_800_000_600))
        personal.placement = .personal
        var work = Meeting(title: "Weekly product sync", date: Date(timeIntervalSince1970: 1_800_000_000))
        work.placement = .work
        let authenticator = FakePersonalLockAuthenticator(method: .faceID, answers: answers)
        let lock = PersonalLock(defaults: makeTestDefaults("PersonalLockPhoneTests"), platform: .iPhone, authenticator: authenticator)
        lock.lookup = { [personal, work] id in [personal, work].first { $0.id == id } }
        await lock.setRequired(true)
        return Rig(lock: lock, authenticator: authenticator, session: ReadingSession(personalLock: lock), personal: personal, work: work)
    }

    func testBehaviorOpeningAPersonalConversationAsksFirst() async throws {
        let rig = await rig(answers: false)
        let session = rig.session
        session.open(rig.personal.id)
        try await waitUntil("Face ID to be asked") { rig.authenticator.asked == 1 }
        await Task.yield()
        XCTAssertNil(session.openID, "cancelled: it doesn't open")
        XCTAssertFalse(session.reading)
        XCTAssertEqual(rig.authenticator.reasons, ["Show Personal conversations"])

        session.open(rig.work.id)
        XCTAssertEqual(session.openID, rig.work.id, "Work opens as ever")
        XCTAssertEqual(rig.authenticator.asked, 1)

        rig.authenticator.answers(true)
        session.open(rig.personal.id, mode: .transcript)
        try await waitUntil("it to open") { session.openID == rig.personal.id }
        XCTAssertTrue(session.reading)
        XCTAssertEqual(session.pageMode, .transcript)
    }

    func testBehaviorASearchHitInAPersonalConversationAsksBeforeItLands() async throws {
        let rig = await rig()
        let hit = try XCTUnwrap(LibrarySearch.hits(in: [rig.personal, rig.work], text: "Dr. Lee", tokens: [], scope: .all).first)
        rig.session.open(hit)
        XCTAssertNil(rig.session.openID, "not before Face ID")
        try await waitUntil("it to open") { rig.session.openID == rig.personal.id }
        XCTAssertEqual(rig.authenticator.asked, 1)
    }

    func testBehaviorLeavingTheScreenLocksItAgainAndClosesWhatWasOpen() async throws {
        let rig = await rig()
        let session = rig.session
        session.open(rig.personal.id)
        try await waitUntil("it to open") { session.openID == rig.personal.id }
        session.sheet = .history(rig.personal.id)

        // DaybookPhoneApp locks it as the scene goes to the background.
        rig.lock.lock()
        XCTAssertNil(session.openID, "the page closes")
        XCTAssertFalse(session.reading)
        XCTAssertNil(session.sheet, "and what was over it")

        session.open(rig.work.id)
        rig.lock.lock()
        XCTAssertEqual(session.openID, rig.work.id, "a Work page stays")
    }

    func testBehaviorThePersonalPlaceAsksAndTwoPagesNeverShowAHiddenOne() async throws {
        let rig = await rig(answers: false)
        let session = rig.session
        session.showNewest(of: [rig.personal, rig.work])
        XCTAssertEqual(session.openID, rig.work.id, "the newest is Personal and locked: the right page shows the next")
        XCTAssertFalse(session.chosen)

        session.place = .library(.section(.personal))
        try await waitUntil("Face ID to be asked") { rig.authenticator.asked == 1 }
    }

    func testBehaviorAFocusThatHidesPersonalLeavesItsPlace() async {
        let rig = await rig()
        rig.authenticator.answers(false)
        rig.session.place = .library(.section(.personal))
        rig.lock.apply(PersonalFocus(showsPersonal: false))
        XCTAssertEqual(rig.session.place, .library(.section(.all)))
        XCTAssertEqual(rig.lock.sections, [.all, .work], "the place menu leaves it out")
    }

    func testBehaviorAFocusThatTurnsAskingOffTakesTheMeetingsRemindersAway() throws {
        let start = Date().addingTimeInterval(20 * 60)
        let calendar = FakeMeetingCalendar(meetings: [MeetingEvent(id: "standup", title: "Standup", start: start,
                                                                   end: start.addingTimeInterval(900), attendees: 4)])
        var environment = try PhoneAppEnvironment.test(self)
        environment.calendar = calendar
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        let model = PhoneAppModel(recorder: RecorderRig().recorder, library: library, posture: DevicePosture(),
                                  options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  environment: environment)
        var reminded: [PhoneNotices.Notice]?
        model.notices = PhoneNotices(post: { _ in }, remove: { _ in }, askPermission: {}, remind: { reminded = $0 })
        model.settings.usesCalendar = true

        model.remindMeetings()
        XCTAssertEqual(reminded?.map(\.title), ["Standup"])
        PersonalFocus(asksToRecord: false).save(to: environment.defaults)
        model.remindMeetings()
        XCTAssertEqual(reminded?.count, 0, "in the Focus: none")
        PersonalFocus().save(to: environment.defaults)
        model.remindMeetings()
        XCTAssertEqual(reminded?.map(\.title), ["Standup"], "the Focus ended: back")
    }

    /// The filter's words are literals the system reads from the app; they're the ones both apps share.
    func testBehaviorTheFocusFilterSaysTheSharedWords() {
        XCTAssertEqual(String(localized: DaybookFocusFilter.title), PersonalLockWords.focusFilter)
        let filter = DaybookFocusFilter()
        XCTAssertEqual(filter.$showsPersonal.title.key, PersonalLockWords.showPersonal)
        XCTAssertEqual(filter.$asksToRecord.title.key, PersonalLockWords.askToRecord)
        XCTAssertEqual(PersonalLockWords.requirement(.faceID), "Require Face ID for Personal")
    }
}
