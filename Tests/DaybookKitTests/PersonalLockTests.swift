import AppKit
import DaybookCore
import DaybookTestSupport
import XCTest
@testable import DaybookKit

/// The lock for Personal conversations (docs/architecture.md, "The Personal lock"), with a stand-in for Touch ID: off
/// by default; on, it hides Personal conversations' titles and shuts their pages until the person proves it's them,
/// once however many ask; it locks again with the screen, sleep, and idleness; it never touches the library's own work;
/// and a Focus filter's choice leaves Personal out of every place.
@MainActor
final class PersonalLockTests: XCTestCase {
    private func meeting(_ title: String, _ placement: LibraryPlacement?, kind: MeetingKind = .auto, minutesAgo: Double = 0) -> Meeting {
        var meeting = Meeting(title: title, date: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60), kind: kind)
        meeting.placement = placement
        return meeting
    }

    private func lock(_ authenticator: FakePersonalLockAuthenticator = FakePersonalLockAuthenticator(),
                      defaults: UserDefaults? = nil, platform: ConversationAction.Platform = .mac) -> PersonalLock {
        PersonalLock(defaults: defaults ?? makeTestDefaults("PersonalLockTests"), platform: platform, authenticator: authenticator)
    }

    // MARK: What it hides

    func testBehaviorItsOffByDefaultAndHidesNothing() {
        let lock = lock()
        let therapy = meeting("Session with Dr. Lee", .personal)
        XCTAssertFalse(lock.isRequired)
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.hides(therapy))
        XCTAssertEqual(lock.symbol(.personal), LibrarySection.personal.systemImage)
    }

    func testBehaviorTurnedOnItHidesPersonalConversationsOnlyAndKeepsTheSwitch() async {
        let defaults = makeTestDefaults("PersonalLockTests.switch")
        let authenticator = FakePersonalLockAuthenticator()
        let lock = lock(authenticator, defaults: defaults)
        var events: [PersonalLock.Event] = []
        lock.observe { events.append($0) }
        let personal = meeting("Session with Dr. Lee", .personal)
        let therapy = meeting("Tuesday", nil, kind: .therapy)
        let work = meeting("Weekly product sync", .work)
        let unknown = meeting("Hallway chat", nil)
        lock.lookup = { id in [personal, therapy, work, unknown].first { $0.id == id } }

        let answer1 = await lock.setRequired(true)
        XCTAssertTrue(answer1)
        XCTAssertEqual(authenticator.asked, 0, "turning it on asks nothing")
        XCTAssertTrue(lock.isLocked, "and hides Personal at once")
        XCTAssertEqual(events, [.locked])
        XCTAssertTrue(lock.hides(personal))
        XCTAssertTrue(lock.hides(therapy), "a Therapy template is Personal (`effectivePlacement`)")
        XCTAssertFalse(lock.hides(work))
        XCTAssertFalse(lock.hides(unknown), "a conversation whose kind isn't known yet isn't Personal")
        XCTAssertTrue(lock.hides(personal.id), "by its ID too, through the library")
        XCTAssertFalse(lock.hides(UUID()), "one the library doesn't have (the Trash's) is asked with itself")
        XCTAssertEqual(lock.firstShown(in: [personal, work, unknown])?.title, "Weekly product sync", "what a list selects by itself")
        XCTAssertEqual(lock.symbol(.personal), PersonalLockWords.symbol, "the Personal place shows the lock")
        XCTAssertEqual(lock.symbol(.work), LibrarySection.work.systemImage)

        let relaunched = PersonalLock(defaults: defaults, platform: .mac, authenticator: authenticator)
        XCTAssertTrue(relaunched.isLocked, "the switch is kept, and a launch starts locked")
    }

    func testBehaviorTurningItOffAsksFirst() async {
        let authenticator = FakePersonalLockAuthenticator(answers: false)
        let lock = lock(authenticator)
        await lock.setRequired(true)
        let answer2 = await lock.setRequired(false)
        XCTAssertFalse(answer2, "refused: the switch stays on")
        XCTAssertTrue(lock.isRequired)
        XCTAssertEqual(authenticator.asked, 1)
        authenticator.answers(true)
        let answer3 = await lock.setRequired(false)
        XCTAssertTrue(answer3)
        XCTAssertFalse(lock.isRequired)
        XCTAssertFalse(lock.isLocked)
    }

    // MARK: Unlocking

    func testBehaviorUnlockingAsksWithItsReasonAndOpensPersonalUntilItLocksAgain() async {
        let authenticator = FakePersonalLockAuthenticator(answers: false)
        let lock = lock(authenticator, platform: .mac)
        var events: [PersonalLock.Event] = []
        let personal = meeting("Session with Dr. Lee", .personal)
        await lock.setRequired(true)
        lock.observe { events.append($0) }

        let answer4 = await lock.unlock()
        XCTAssertFalse(answer4, "cancelled")
        XCTAssertTrue(lock.hides(personal))
        authenticator.answers(true)
        let answer5 = await lock.unlock()
        XCTAssertTrue(answer5)
        XCTAssertFalse(lock.hides(personal), "shown once the person proved it's them")
        XCTAssertEqual(authenticator.reasons, ["show Personal conversations", "show Personal conversations"],
                       "the Mac's prompt reads “Daybook is trying to show Personal conversations.”")
        let answer6 = await lock.unlock()
        XCTAssertTrue(answer6, "unlocked already: nothing is asked")
        XCTAssertEqual(authenticator.asked, 2)

        lock.lock()
        XCTAssertTrue(lock.hides(personal), "locked again")
        XCTAssertEqual(events, [.locked])
        lock.lock()
        XCTAssertEqual(events, [.locked], "locking what's locked says nothing")
    }

    func testBehaviorManyAskingAtOnceGetOnePrompt() async throws {
        let authenticator = FakePersonalLockAuthenticator()
        let lock = lock(authenticator, platform: .iPhone)
        await lock.setRequired(true)
        authenticator.hold()
        async let first = lock.unlock()
        async let second = lock.unlock()
        try await waitUntil("the prompt to be up") { authenticator.isWaiting }
        authenticator.release(true)
        let answers = await [first, second]
        XCTAssertEqual(answers, [true, true])
        XCTAssertEqual(authenticator.asked, 1, "one prompt for both")
        XCTAssertEqual(authenticator.reasons, ["Show Personal conversations"], "the iPhone's reason is a line of its own")
    }

    func testBehaviorAPromptAnsweredAfterTheLockCameBackDoesntUnlock() async throws {
        let authenticator = FakePersonalLockAuthenticator()
        let lock = lock(authenticator)
        await lock.setRequired(true)
        authenticator.hold()
        let unlocking = Task { await lock.unlock() }
        try await waitUntil("the prompt to be up") { authenticator.isWaiting }
        // The screen locks with Touch ID's prompt up.
        lock.lock()
        authenticator.release(true)
        let unlocked = await unlocking.value
        XCTAssertFalse(unlocked)
        XCTAssertTrue(lock.isLocked)
    }

    // MARK: Locking again

    func testBehaviorTheMacLocksAgainWithTheScreenSleepAnotherUserAndIdleness() async throws {
        let authenticator = FakePersonalLockAuthenticator()
        let lock = lock(authenticator)
        let distributed = NotificationCenter()
        let workspace = NotificationCenter()
        lock.watchSystem(distributed: distributed, workspace: workspace, idle: { 0 }, every: .seconds(3600))
        await lock.setRequired(true)

        for (center, name) in [(distributed, PersonalLock.screenLocked), (workspace, NSWorkspace.willSleepNotification),
                               (workspace, NSWorkspace.sessionDidResignActiveNotification)] {
            let answer7 = await lock.unlock()
            XCTAssertTrue(answer7)
            center.post(name: name, object: nil)
            try await waitUntil("\(name.rawValue) to lock it") { lock.isLocked }
        }
        XCTAssertEqual(PersonalLock.screenLocked.rawValue, "com.apple.screenIsLocked")

        let answer8 = await lock.unlock()
        XCTAssertTrue(answer8)
        lock.lockIfIdle(for: PersonalLock.idleLimit - 1)
        XCTAssertFalse(lock.isLocked, "under ten minutes without input")
        lock.lockIfIdle(for: PersonalLock.idleLimit)
        XCTAssertTrue(lock.isLocked, "ten minutes without input")
        XCTAssertEqual(PersonalLock.idleLimit, 600)
    }

    func testBehaviorTheIdleWatchLocksOnItsOwn() async throws {
        let lock = lock()
        await lock.setRequired(true)
        let answer9 = await lock.unlock()
        XCTAssertTrue(answer9)
        lock.watchSystem(distributed: NotificationCenter(), workspace: NotificationCenter(), idle: { PersonalLock.idleLimit },
                         every: .milliseconds(10))
        try await waitUntil("the idle watch to lock it") { lock.isLocked }
    }

    // MARK: What it never touches

    /// It's a lock on what's shown, not on the library: with Personal locked, the library still lists, files, edits,
    /// and plans a Personal conversation's summary, and syncs it, as it does unlocked.
    func testBehaviorTheLibrarysOwnWorkNeverAsksIt() async throws {
        let root = makeTemporaryFolder("PersonalLockTests.library")
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        let authenticator = FakePersonalLockAuthenticator(answers: false)
        let lock = lock(authenticator)
        lock.lookup = { library.meeting($0) }
        await lock.setRequired(true)

        let id = library.newMeeting(title: "Session with Dr. Lee", date: Date(), folderID: nil, placement: .personal)
        library.update(id) { $0.notes = "What we talked about." }
        XCTAssertTrue(lock.hides(id))
        XCTAssertEqual(library.meeting(id)?.notes, "What we talked about.", "edits land while it's locked")
        XCTAssertEqual(LibraryPlace.section(.personal).meetings(in: library.meetings).map(\.id), [id],
                       "the library's places list it; only the views hide its words")
        XCTAssertEqual(MeetingExport.summaryMarkdown(try XCTUnwrap(library.meeting(id))).isEmpty, false,
                       "and its words are there for the work that needs them")
        XCTAssertEqual(authenticator.asked, 0, "nothing in the library asked for Touch ID")
    }

    // MARK: Focus

    func testBehaviorAFocusThatHidesPersonalLeavesItOutOfEveryPlace() {
        let personal = meeting("Session with Dr. Lee", .personal, minutesAgo: 1)
        let therapy = meeting("Tuesday", nil, kind: .therapy, minutesAgo: 2)
        let work = meeting("Weekly product sync", .work, minutesAgo: 3)
        let unknown = meeting("Hallway chat", nil, minutesAgo: 4)
        var filed = meeting("Dentist", .personal, minutesAgo: 5)
        let folder = UUID()
        filed.folderID = folder
        let all = [personal, therapy, work, unknown, filed]

        XCTAssertEqual(LibraryPlace.section(.all).meetings(in: all).count, 5)
        XCTAssertEqual(LibraryPlace.section(.all).meetings(in: all, showingPersonal: false).map(\.title), ["Weekly product sync", "Hallway chat"])
        XCTAssertEqual(LibraryPlace.section(.personal).meetings(in: all, showingPersonal: false), [], "Personal itself lists nothing")
        XCTAssertEqual(LibraryPlace.folder(folder).meetings(in: all, showingPersonal: false), [], "nor a folder")
        XCTAssertEqual(LibraryPlace.section(.work).meetings(in: all, showingPersonal: false).map(\.title), ["Weekly product sync"])
        XCTAssertEqual(LibrarySection.shown(showingPersonal: false), [.all, .work])
        XCTAssertEqual(LibrarySection.shown(showingPersonal: true), [.all, .work, .personal])
    }

    func testBehaviorTheFocusFilterReachesTheLockAndIsKept() throws {
        let defaults = makeTestDefaults("PersonalLockTests.focus")
        let lock = lock(defaults: defaults)
        var events: [PersonalLock.Event] = []
        lock.observe { events.append($0) }
        XCTAssertEqual(lock.focus, PersonalFocus(), "outside a Focus: Personal shows, and Daybook asks")
        XCTAssertEqual(lock.sections, LibrarySection.allCases)

        let elsewhere = makeTestDefaults("PersonalLockTests.filter")
        PersonalFocus.set(PersonalFocus(showsPersonal: false, asksToRecord: false), in: elsewhere)
        XCTAssertEqual(PersonalFocus.load(from: elsewhere), PersonalFocus(showsPersonal: false, asksToRecord: false),
                       "the filter keeps it where a launch reads it")
        XCTAssertEqual(lock.focus.showsPersonal, false, "and a running lock follows it")
        XCTAssertEqual(PersonalFocus.load(from: defaults).showsPersonal, false, "keeping it in its own preferences")
        XCTAssertEqual(events, [.focusChanged])
        XCTAssertEqual(lock.sections, [.all, .work])
        let personal = meeting("Session with Dr. Lee", .personal)
        let work = meeting("Weekly product sync", .work)
        XCTAssertFalse(lock.lists(personal))
        XCTAssertEqual(lock.listed([personal, work]).map(\.title), ["Weekly product sync"])
        XCTAssertFalse(lock.hides(personal), "a Focus leaves it out; it doesn't lock it")

        lock.apply(PersonalFocus())
        XCTAssertTrue(lock.lists(personal), "the Focus ended: both back on")
        XCTAssertEqual(events, [.focusChanged, .focusChanged])
    }

    func testBehaviorTheDemoNeverAsksTheSystem() async {
        XCTAssertEqual(PersonalLockDemo.state(arguments: ["Daybook", "--lock-demo", "locked"]), .locked)
        XCTAssertNil(PersonalLockDemo.state(arguments: ["Daybook", "--lock-demo"]))
        let defaults = makeTestDefaults("PersonalLockTests.demo")
        let lock = PersonalLock(defaults: defaults, platform: .mac, authenticator: FakePersonalLockAuthenticator())
        PersonalLockDemo.apply(.locked, to: lock, platform: .mac)
        XCTAssertTrue(lock.isLocked)
        let answer10 = await lock.unlock()
        XCTAssertFalse(answer10, "Unlock is refused, so a snapshot stays as launched")
        XCTAssertEqual(lock.method, .touchID)
        XCTAssertFalse(defaults.bool(forKey: PersonalLock.requiredKey), "a demo keeps nothing")

        let focused = PersonalLock(defaults: defaults, platform: .iPhone, authenticator: FakePersonalLockAuthenticator())
        PersonalLockDemo.apply(.focus, to: focused, platform: .iPhone)
        XCTAssertFalse(focused.focus.showsPersonal)
        XCTAssertEqual(focused.method, .faceID)
        XCTAssertEqual(PersonalFocus.load(from: defaults), PersonalFocus(), "a demo's Focus isn't kept")
    }
}
