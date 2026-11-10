import AVFoundation
import DaybookCore
import DaybookKit
import DaybookTestSupport
import DaybookUI
import Foundation
import XCTest
@testable import Daybook

/// Floating Notes after a recording ends: a recording that stopped on its own says so, rather than a calm Saved,
/// and Record Again records into the same conversation, so a call cut short isn't split in two. Fake capture and
/// a synthetic tone only: nothing is recorded.
@MainActor
final class FloatingNotesAfterStopTests: XCTestCase {
    /// The capture's host clock, moved by the test.
    private final class HostClock: @unchecked Sendable { var now: TimeInterval = 100 }
    private let clock = HostClock()

    /// A second of synthetic tone from the fake microphone, so the capture has audio to add.
    private func speak(_ microphone: FakeCaptureSource) {
        for _ in 0..<10 {
            clock.now += 0.1
            microphone.emit(CallSignals.tone(), at: clock.now)
        }
    }

    private func state(_ microphone: FakeCaptureSource) async -> AppState {
        let defaults = makeTestDefaults("local.daybook.tests.floating-after-stop")
        // The panel itself isn't opened in tests.
        defaults.set(false, forKey: "showsFloatingNotesWhileRecording")
        defaults.set(false, forKey: "includeComputerAudio")
        let clock = self.clock
        let capture = CaptureEnvironment(microphoneAuthorization: { true }, makeMicrophone: { microphone }, systemAudio: FakeSystemAudio(),
                                         currentRoute: { AudioOutputRoute(kind: .speakers, deviceName: "Speakers", transport: nil) },
                                         observeRoutes: { _ in nil }, hostTime: { clock.now })
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookFloatingAfterStop"), defaults: defaults, capture: capture)
        await state.initialize()
        state.includeComputerAudio = false
        return state
    }

    func testBehaviorARecordingThatStopsOnItsOwnSaysStoppedWithWhyAndRecordsAgainIntoTheSameConversation() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(microphone)
        await state.startRecording()
        let id = try XCTUnwrap(state.recordingID)
        speak(microphone)
        microphone.send(.failed(FakeError(message: "kAudioHardwareNotRunningError")))
        try await waitUntil("the capture to finish") { state.recordingID == nil && state.unexpectedStops[id] != nil }

        let meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        let inputs = FloatingStatusInputs.make(state, meeting: meeting, afterStop: true, inputDevice: nil)
        XCTAssertEqual(inputs.phase, .stopped, "not a calm Saved")
        XCTAssertEqual(FloatingStatus.phase(inputs)?.phase, .stopped)
        XCTAssertTrue(FloatingStatusInputs.stoppedShort(meeting, state: state))
        XCTAssertEqual(state.unexpectedStops[id], RecordingController.unexpectedStopSentence, "the reason, in the recorder's words")
        XCTAssertEqual(FloatingStatus.stoppedMessage(state.unexpectedStops[id]), "What was recorded is saved.",
                       "under \"Recording stopped\", the box doesn't say it stopped again")

        // Pressed at once, while the first part is still being added.
        await state.recordAgain(into: id)
        XCTAssertEqual(state.recordingID, id, "Record Again records into the conversation that was cut short")
        XCTAssertNil(state.unexpectedStops[id], "and the stop is said")
        XCTAssertEqual(state.meetings.filter { $0.title == meeting.title }.count, 1, "no second conversation")
        speak(microphone)
        await state.stopRecording()
        try await waitUntil("the second capture to finish") { state.recordingID == nil }
        await state.flush()
    }

    /// Regression: the stop was cleared only by Record Again, so a conversation recorded into again another way (the
    /// inspector's Record on This Mac) and stopped normally still said Stopped, with Record Again.
    func testBehaviorALaterRecordingIntoTheSameConversationIsSavedNotStopped() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(microphone)
        await state.startRecording()
        let id = try XCTUnwrap(state.recordingID)
        speak(microphone)
        microphone.send(.failed(FakeError(message: "kAudioHardwareNotRunningError")))
        try await waitUntil("the first part to be added") {
            state.recordingID == nil && state.meetings.first { $0.id == id }?.tracks.isEmpty == false
        }
        XCTAssertNotNil(state.unexpectedStops[id])

        // As the inspector's Record on This Mac does, once the conversation's processing lets go of it.
        if state.processingID == id { state.pauseProcessing(id) } else if state.queuedIDs.contains(id) { state.cancelQueued(id) }
        let staging = state.storageURL.appendingPathComponent("Staging").appendingPathComponent(id.uuidString)
        try await waitUntil("the conversation to be free") {
            state.canRecordInto(id) && !["capture-session.json", "microphone.caf"].contains {
                FileManager.default.fileExists(atPath: staging.appendingPathComponent($0).path)
            }
        }
        await state.startRecording(into: id)
        XCTAssertEqual(state.recordingID, id, String(describing: state.problem))
        XCTAssertNil(state.unexpectedStops[id], "recording into it again clears the stop")
        speak(microphone)
        await state.stopRecording()
        try await waitUntil("the second capture to finish") { state.recordingID == nil }

        let meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        XCTAssertFalse(FloatingStatusInputs.stoppedShort(meeting, state: state))
        XCTAssertEqual(FloatingStatusInputs.make(state, meeting: meeting, afterStop: true, inputDevice: nil).phase, .saved)
        await state.flush()
    }

    func testBehaviorAStopMessageSaysWhyOnlyWhenItKnows() {
        XCTAssertEqual(FloatingStatus.stoppedMessage(RecordingController.unexpectedStopSentence), "What was recorded is saved.")
        XCTAssertEqual(FloatingStatus.stoppedMessage("The microphone was disconnected."), "The microphone was disconnected.",
                       "a reason of the recorder's own stays")
        XCTAssertEqual(FloatingStatus.stoppedMessage(nil), "Everything up to then is saved.")
    }

    func testBehaviorANormalStopIsSaved() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(microphone)
        await state.startRecording()
        let id = try XCTUnwrap(state.recordingID)
        speak(microphone)
        await state.stopRecording()
        try await waitUntil("the capture to finish") { state.recordingID == nil }
        var meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        XCTAssertFalse(FloatingStatusInputs.stoppedShort(meeting, state: state))
        meeting.tracks = meeting.tracks.map { track in
            var track = track
            track.duration = 18 * 60
            return track
        }
        let inputs = FloatingStatusInputs.make(state, meeting: meeting, afterStop: true, inputDevice: nil)
        XCTAssertEqual(inputs.phase, .saved)
        XCTAssertEqual(FloatingStatus.phase(inputs)?.detail, "18 min")
        await state.flush()
    }

    // MARK: Recording more (`RecordMore`)

    /// One rule on both apps: after a Stop, Keep Recording records into the same conversation, after what was saved,
    /// for two minutes; then Record starts a new one, for the next call.
    func testBehaviorAfterAStopKeepRecordingRecordsIntoTheSameConversationThenRecordStartsANewOne() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(microphone)
        await state.startRecording()
        let id = try XCTUnwrap(state.recordingID)
        speak(microphone)
        await state.stopRecording()
        try await waitUntil("the capture to finish") { state.recordingID == nil }

        XCTAssertEqual(state.recordMore(after: id), .keepRecording)
        XCTAssertEqual(state.recordMore(after: id, now: Date().addingTimeInterval(RecordMore.window + 1)), .record, "two minutes on")
        XCTAssertEqual(state.recordMore(after: UUID()), .record, "only the conversation that was just stopped")

        await state.record(.keepRecording, after: id)
        XCTAssertEqual(state.recordingID, id, "Keep Recording records into the same conversation, its processing set aside")
        XCTAssertEqual(state.meetings.count, 1, "no second conversation")
        XCTAssertNil(state.afterStop.stoppedAt(id), "recording again ends the moment")
        speak(microphone)
        await state.stopRecording()
        try await waitUntil("the second capture to finish") { state.recordingID == nil }
        XCTAssertEqual(state.recordMore(after: id), .keepRecording, "every Stop has its own two minutes")

        // Past the moment, Record makes a new conversation for the next call.
        let selected = state.window.openID
        await state.record(.record, after: id)
        let next = try XCTUnwrap(state.recordingID)
        XCTAssertNotEqual(next, id)
        XCTAssertEqual(state.window.openID, selected, "started from the panel, the window is left as it was")
        XCTAssertEqual(state.meetings.count, 2)
        speak(microphone)
        await state.stopRecording()
        try await waitUntil("the third capture to finish") { state.recordingID == nil }
        await state.flush()
    }

    /// Keep Recording ends early when the meeting it would join is over: the call's meeting ended, the next call or
    /// calendar meeting started; and a stop the call's end made is final from the start.
    func testBehaviorTheMeetingEndingOrTheNextStartingEndsKeepRecording() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(microphone)
        let zoom = MeetingCandidate(bundleID: "us.zoom.xos", appName: "Zoom", windowTitle: "Zoom Meeting", hasInputActivity: true,
                                    hasOutputActivity: true, hasMeetingWindow: true, isBrowser: false)
        let id = state.newMeeting(title: "Design review")

        state.afterStop.began(id)
        XCTAssertEqual(state.recordMore(after: id), .keepRecording)
        _ = state.monitor.onMeetingEnded?(zoom)
        XCTAssertEqual(state.recordMore(after: id), .record, "the call's meeting ended")

        state.afterStop.began(id)
        state.callAppChoices = ["us.zoom.xos": .never]
        _ = state.monitor.onMeetingStarted?(zoom)
        XCTAssertEqual(state.recordMore(after: id), .record, "the next call started")

        let stoppedAt = Date()
        state.afterStop.began(id, at: stoppedAt)
        let next = MeetingEvent(id: "Next", title: "Planning", start: stoppedAt.addingTimeInterval(60), end: stoppedAt.addingTimeInterval(1860),
                                attendees: 3)
        let earlier = MeetingEvent(id: "Earlier", title: "Design review", start: stoppedAt.addingTimeInterval(-60),
                                   end: stoppedAt.addingTimeInterval(1740), attendees: 3)
        state.meetingCalendar = FakeMeetingCalendar(meetings: [earlier, next])
        state.usesCalendar = true
        state.askedMeetings = ["Next", "Earlier"]
        state.checkCalendar(at: stoppedAt.addingTimeInterval(10))
        XCTAssertEqual(state.recordMore(after: id), .keepRecording, "the meeting it stopped in isn't the next one")
        state.checkCalendar(at: stoppedAt.addingTimeInterval(45))
        XCTAssertEqual(state.recordMore(after: id), .record, "the next meeting is starting")

        // A recording the call's end stopped (or turning calls off) can't be gone on with, nor one the person stopped
        // when the prompt asked as the call or the meeting ended.
        await state.startRecording()
        let automatic = try XCTUnwrap(state.recordingID)
        speak(microphone)
        await state.stopRecording(manual: false)
        try await waitUntil("the capture to finish") { state.recordingID == nil }
        XCTAssertEqual(state.recordMore(after: automatic), .record)
        await state.startRecording()
        let asked = try XCTUnwrap(state.recordingID)
        speak(microphone)
        await state.stopRecording(manual: true, meetingOver: true)
        try await waitUntil("the second capture to finish") { state.recordingID == nil }
        XCTAssertEqual(state.recordMore(after: asked), .record)
        await state.flush()
    }

    /// A recording that starts anywhere but the library window's own Record (a call, the prompt, the menu bar, Floating
    /// Notes, a notification, a recorder) lands in All Conversations, unfiled, and leaves the window on what it showed.
    func testBehaviorARecordingStartedElsewhereLandsInAllAndLeavesTheWindowAlone() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(microphone)
        state.window.place = .section(.personal)
        let reading = state.newMeeting(title: "Prep notes")
        XCTAssertEqual(state.window.openID, reading)

        await state.startRecording(title: "Zoom Meeting", automatic: true, from: .elsewhere)
        let call = try XCTUnwrap(state.recordingID)
        let recorded = try XCTUnwrap(state.meetings.first { $0.id == call })
        XCTAssertNil(recorded.placement, "not filed into Personal because the window happened to show it")
        XCTAssertNil(recorded.folderID)
        XCTAssertTrue(LibrarySection.all.contains(recorded))
        XCTAssertEqual(state.window.openID, reading, "the page the person was reading stays")
        XCTAssertEqual(state.window.place, .section(.personal))
        speak(microphone)
        await state.stopRecording()
        try await waitUntil("the capture to finish") { state.recordingID == nil }

        // The window's own Record files into the place it shows and opens the recording, as before.
        state.createFolder(named: "Hiring", moving: [])
        let folder = try XCTUnwrap(state.folders.first { $0.name == "Hiring" })
        state.window.place = .folder(folder.id)
        await state.startRecording()
        let own = try XCTUnwrap(state.recordingID)
        XCTAssertEqual(state.meetings.first { $0.id == own }?.folderID, folder.id)
        XCTAssertEqual(state.window.openID, own)
        speak(microphone)
        await state.stopRecording()
        try await waitUntil("the second capture to finish") { state.recordingID == nil }
        await state.flush()
    }
}
