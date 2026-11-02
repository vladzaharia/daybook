import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// A notification center that keeps what it was asked to do.
@MainActor
final class FakeNotificationCenter: RecordingNotificationPosting {
    private(set) var authorizationRequests = 0
    private(set) var posted: [RecordingNotification] = []
    private(set) var removed: [String] = []

    /// What's on screen now: posted and not taken back.
    var showing: [RecordingNotification] {
        posted.filter { notification in !removed.contains(notification.identifier) }
    }

    func requestAuthorization() { authorizationRequests += 1 }
    func post(_ notification: RecordingNotification) {
        removed.removeAll { $0 == notification.identifier }
        posted.append(notification)
    }
    func remove(_ identifiers: [String]) { removed.append(contentsOf: identifiers) }
}

/// A Spotlight index that keeps what it was sent.
final class FakeConversationIndex: ConversationIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: ConversationEntity] = [:]
    private var passes: [String] = []

    var indexed: [UUID: ConversationEntity] { lock.withLock { entries } }
    var history: [String] { lock.withLock { passes } }

    func replaceAll(with entities: [ConversationEntity]) async {
        lock.withLock {
            entries = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
            passes.append("all \(entities.count)")
        }
    }

    func update(_ entities: [ConversationEntity], removing removed: [UUID]) async {
        lock.withLock {
            for id in removed { entries[id] = nil }
            for entity in entities { entries[entity.id] = entity }
            passes.append("update \(entities.count) remove \(removed.count)")
        }
    }
}

/// What reaches Daybook from outside its windows: the recording's notifications, App Intents, and Spotlight. Synthetic
/// audio from fake capture sources; nothing records the room, posts a real notification, or touches Spotlight.
@MainActor
final class SystemEntryPointsTests: XCTestCase {
    override func tearDown() async throws {
        IntentState.reset()
    }

    private func state(capture: CaptureEnvironment = .live) async -> AppState {
        let defaults = makeTestDefaults("local.daybook.tests.entry")
        // No panel opens in a test.
        defaults.set(false, forKey: "showsFloatingNotesWhileRecording")
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookEntryPoints"), defaults: defaults, capture: capture)
        state.includeComputerAudio = false
        await state.initialize()
        return state
    }

    private static func fakeCapture(_ microphone: FakeCaptureSource) -> CaptureEnvironment {
        CaptureEnvironment(microphoneAuthorization: { true }, makeMicrophone: { microphone }, systemAudio: FakeSystemAudio(),
                           currentRoute: { AudioOutputRoute(kind: .speakers, deviceName: "Speakers", transport: nil) },
                           observeRoutes: { _ in nil }, hostTime: { 100 })
    }

    private func notifications(_ state: AppState, center: FakeNotificationCenter, inFront: Bool = false,
                               floatingNotes: Bool = false) -> RecordingNotifications {
        RecordingNotifications(state: state, center: center, isInForeground: { inFront }, isFloatingNotesShowing: { floatingNotes })
    }

    // MARK: Notifications

    /// The microphone goes ten minutes into a call while Daybook is behind Zoom: "Recording stopped", the conversation,
    /// why, and Record Again. Seen in the app, it goes.
    func testBehaviorARecordingThatStopsOnItsOwnIsSaidOutsideDaybook() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(capture: Self.fakeCapture(microphone))
        let center = FakeNotificationCenter()
        let notifier = notifications(state, center: center)
        notifier.start()
        let id = state.newMeeting(title: "Design review")
        state.recordingID = id
        let directory = makeTemporaryFolder("DaybookEntryCapture").appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await state.recorder.start(in: directory, includeSystemAudio: false)
        try await waitUntil("permission to be asked") { center.authorizationRequests == 1 }

        microphone.send(.failed(FakeError(message: "kAudioHardwareNotRunningError")))
        try await waitUntil("the stop to be said") { !center.showing.isEmpty }
        let stop = try XCTUnwrap(center.showing.first)
        XCTAssertEqual(stop.kind, .stopped)
        XCTAssertEqual(stop.title, "Recording stopped")
        XCTAssertEqual(stop.subtitle, "Design review")
        XCTAssertEqual(stop.body, RecordingController.unexpectedStopSentence)
        XCTAssertEqual(stop.conversationID, id)
        try await waitUntil("the capture to finish") { state.recordingID == nil }
        XCTAssertEqual(center.posted.count, 1, "Said once")
        XCTAssertEqual(center.authorizationRequests, 1, "Asked once")

        state.dismissUnexpectedStop(id)
        try await waitUntil("the stop to be taken back") { center.showing.isEmpty }
        notifier.stop()
        await state.flush()
    }

    /// A Personal conversation is never named outside the app; nothing is posted while Daybook is in front.
    func testBehaviorAPersonalConversationIsUnnamedAndNothingIsSaidInFront() async throws {
        let state = await state()
        let center = FakeNotificationCenter()
        let notifier = notifications(state, center: center)
        let id = state.newMeeting(title: "Therapy")
        state.setPlacement([id], .personal)
        notifier.update(to: .init(stops: [id: "Recording stopped because the Mac went to sleep. Everything up to then is saved."]))
        XCTAssertEqual(center.showing.count, 1)
        XCTAssertNil(center.showing.first?.subtitle, "Personal: unnamed")
        XCTAssertEqual(center.showing.first?.body, "Recording stopped because the Mac went to sleep. Everything up to then is saved.")

        let inFront = FakeNotificationCenter()
        let front = notifications(state, center: inFront, inFront: true)
        front.update(to: .init(stops: [id: "Recording stopped unexpectedly. What was recorded is saved."]))
        XCTAssertTrue(inFront.posted.isEmpty, "In front, the page says it")
        await state.flush()
    }

    /// A call that starts recording on its own is said, naming the call, unless Floating Notes shows it; the
    /// notification goes when the recording ends. The next recording takes back an earlier stop and its Record Again.
    func testBehaviorAnAutomaticStartIsSaidWhileFloatingNotesIsHidden() async throws {
        let state = await state()
        let center = FakeNotificationCenter()
        let notifier = notifications(state, center: center)
        let earlier = UUID(), call = UUID()
        notifier.update(to: .init(stops: [earlier: RecordingController.unexpectedStopSentence]))
        XCTAssertEqual(center.showing.map(\.kind), [.stopped])

        notifier.update(to: .init(recordingID: call, automatic: true, callName: "Zoom call", automaticRecording: true,
                                  stops: [earlier: RecordingController.unexpectedStopSentence]))
        XCTAssertEqual(center.showing.map(\.kind), [.recording], "The stop is out of date once a new recording starts")
        XCTAssertEqual(center.showing.first?.title, "Recording")
        XCTAssertEqual(center.showing.first?.body, "Zoom call")
        XCTAssertEqual(RecordingNotifications.callLine("call in Chrome"), "Call in Chrome")
        XCTAssertEqual(RecordingNotifications.callLine(nil), "Call")

        notifier.update(to: .init(automaticRecording: true, stops: [earlier: RecordingController.unexpectedStopSentence]))
        XCTAssertTrue(center.showing.isEmpty, "Gone once the recording ends")

        // Floating Notes showing says it already; a recording started by hand isn't announced.
        let shown = FakeNotificationCenter()
        let withPanel = notifications(state, center: shown, floatingNotes: true)
        withPanel.update(to: .init(recordingID: UUID(), automatic: true, callName: "Zoom call", automaticRecording: true))
        withPanel.update(to: .init(automaticRecording: true))
        withPanel.update(to: .init(recordingID: UUID(), automatic: false))
        XCTAssertTrue(shown.posted.isEmpty)
        await state.flush()
    }

    /// Permission is asked the first time someone records or turns on Record calls automatically, and only then.
    func testBehaviorPermissionIsAskedAtTheFirstRecordingOrAutomaticRecording() async throws {
        let state = await state()
        let center = FakeNotificationCenter()
        let notifier = notifications(state, center: center)
        notifier.update(to: .init())
        XCTAssertEqual(center.authorizationRequests, 0, "Not at launch")
        notifier.update(to: .init(automaticRecording: true))
        XCTAssertEqual(center.authorizationRequests, 1)
        notifier.update(to: .init(recordingID: UUID(), automaticRecording: true))
        XCTAssertEqual(center.authorizationRequests, 1)
        await state.flush()
    }

    /// The stop's notification opens its conversation; Record Again records a new one.
    func testBehaviorAClickOpensTheConversationAndRecordAgainRecords() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(capture: Self.fakeCapture(microphone))
        let center = FakeNotificationCenter()
        let notifier = notifications(state, center: center)
        var opened = 0
        notifier.openLibrary = { opened += 1 }
        let id = state.newMeeting(title: "Design review")
        state.selectedID = nil
        notifier.respond(.open(.stopped, id))
        XCTAssertEqual(state.selectedID, id)
        XCTAssertEqual(opened, 1)

        notifier.respond(.recordAgain)
        try await waitUntil("a new recording") { state.recordingID != nil }
        XCTAssertNotEqual(state.recordingID, id)
        XCTAssertTrue(microphone.started)
        await state.stopRecording()
        await state.flush()
    }

    // MARK: Intents

    /// Shortcuts can launch Daybook: an intent waits for the app's state and its library, then acts.
    func testBehaviorAnIntentWaitsForTheAppAndItsLibrary() async throws {
        IntentState.reset()
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookEntryPoints"), defaults: makeTestDefaults("local.daybook.tests.entry"))
        let waiting = Task { try await IntentState.ready(within: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(50))
        IntentState.register(state) {}
        await state.initialize()
        let ready = try await waiting.value
        XCTAssertTrue(ready === state)
        await state.flush()
    }

    func testBehaviorAnIntentWithoutTheAppSaysToOpenDaybook() async throws {
        IntentState.reset()
        do {
            _ = try await IntentState.ready(within: .milliseconds(50))
            XCTFail("expected Daybook to be unavailable")
        } catch {
            XCTAssertEqual(error as? DaybookIntentError, .appUnavailable)
        }
    }

    /// Start Recording, Add Bookmark, and Stop Recording on the app's state, with a fake microphone.
    func testBehaviorTheRecordingIntentsRecordBookmarkAndStop() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(capture: Self.fakeCapture(microphone))
        XCTAssertThrowsError(try IntentActions.addBookmark(state)) { XCTAssertEqual($0 as? DaybookIntentError, .notRecording) }
        do {
            try await IntentActions.stopRecording(state)
            XCTFail("expected not recording")
        } catch {
            XCTAssertEqual(error as? DaybookIntentError, .notRecording)
        }
        try await IntentActions.startRecording(state)
        let id = try XCTUnwrap(state.recordingID)
        // Asked again while recording: nothing changes.
        try await IntentActions.startRecording(state)
        XCTAssertEqual(state.recordingID, id)
        try IntentActions.addBookmark(state)
        XCTAssertEqual(state.meetings.first { $0.id == id }?.highlights.count, 1)
        try await IntentActions.stopRecording(state)
        XCTAssertNil(state.recordingID)
        await state.flush()
    }

    /// New Note and Open Conversation open the library on the conversation; one that's gone says so.
    func testBehaviorNewNoteAndOpenConversationShowTheConversation() async throws {
        let state = await state()
        var opened = 0
        IntentState.register(state) { opened += 1 }
        let note = IntentActions.newNote(state)
        XCTAssertEqual(state.selectedID, note)
        XCTAssertTrue(state.meetings.first { $0.id == note }?.title.hasPrefix("Note at") == true)
        let other = state.newMeeting(title: "Roadmap")
        state.selectedID = note
        try IntentActions.open(other, in: state)
        XCTAssertEqual(state.selectedID, other)
        XCTAssertEqual(opened, 2)
        XCTAssertThrowsError(try IntentActions.open(UUID(), in: state)) { XCTAssertEqual($0 as? DaybookIntentError, .conversationGone) }
        await state.flush()
    }

    // MARK: Spotlight and Shortcuts' suggestions

    /// Spotlight gets every conversation but Personal ones, follows renames, and loses one moved to Personal or to the
    /// Trash; Shortcuts suggests the same ones and still opens a Personal one by ID.
    func testBehaviorPersonalConversationsStayOutOfSpotlightAndSuggestions() async throws {
        let state = await state()
        let work = state.newMeeting(title: "Roadmap")
        let personal = state.newMeeting(title: "Therapy")
        let unsorted = state.newMeeting(title: "Conversation at 9:00 AM")
        state.setPlacement([work], .work)
        state.setPlacement([personal], .personal)
        let index = FakeConversationIndex()
        let spotlight = ConversationSpotlight(state: state, index: index, delay: .milliseconds(10))
        spotlight.start()
        await spotlight.settled()
        XCTAssertEqual(Set(index.indexed.keys), [work, unsorted])
        XCTAssertEqual(index.history.first, "all 2", "The first pass replaces whatever was indexed before")

        state.update(work) { $0.title = "Roadmap review" }
        try await waitUntil("the rename to reach Spotlight") { index.indexed[work]?.title == "Roadmap review" }
        state.setPlacement([unsorted], .personal)
        try await waitUntil("a conversation moved to Personal to leave Spotlight") { index.indexed[unsorted] == nil }
        XCTAssertNil(index.indexed[personal])

        IntentState.register(state) {}
        let suggested = try await ConversationQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), [work])
        let found = try await ConversationQuery().entities(matching: "therapy")
        XCTAssertTrue(found.isEmpty, "Personal titles aren't searched from outside")
        let byID = try await ConversationQuery().entities(for: [personal])
        XCTAssertEqual(byID.map(\.id), [personal], "A shortcut made with it still opens it")

        _ = try await state.library.moveToTrash(work)
        try await waitUntil("a conversation in the Trash to leave Spotlight") { index.indexed[work] == nil }
        spotlight.stop()
        await spotlight.settled()
        await state.flush()
    }
}
