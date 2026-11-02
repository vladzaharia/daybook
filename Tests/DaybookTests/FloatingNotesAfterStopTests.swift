import AVFoundation
import DaybookCore
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
}
