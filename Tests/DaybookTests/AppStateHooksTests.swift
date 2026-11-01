import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// What `AppState` offers the views around it: the library notice's one action, why a recording stopped on its own,
/// and waiting for the library to open.
@MainActor
final class AppStateHooksTests: XCTestCase {
    private func state(capture: CaptureEnvironment = .live) async -> AppState {
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookHooks"), defaults: makeTestDefaults("local.daybook.tests.hooks"),
                             capture: capture)
        await state.initialize()
        return state
    }

    /// Records into a conversation's own staging folder, as `startRecording` does, with the state's fake capture.
    private func recording(_ state: AppState, prepare: (URL) throws -> Void = { _ in }) async throws -> UUID {
        let id = state.newMeeting(title: "Interview")
        state.recordingID = id
        let directory = makeTemporaryFolder("DaybookHooksCapture").appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try prepare(directory)
        try await state.recorder.start(in: directory, includeSystemAudio: false)
        XCTAssertEqual(state.recorder.state, .recording)
        return id
    }

    private static func fakeCapture(_ microphone: FakeCaptureSource) -> CaptureEnvironment {
        CaptureEnvironment(microphoneAuthorization: { true }, makeMicrophone: { microphone }, systemAudio: FakeSystemAudio(),
                           currentRoute: { AudioOutputRoute(kind: .speakers, deviceName: "Speakers", transport: nil) },
                           observeRoutes: { _ in nil }, hostTime: { 100 })
    }

    func testBehaviorANoticesActionShowsWhileItsWordsDoAndRunsOnce() async throws {
        let state = await state()
        var undone = 0
        state.post("Moved “Standup” to the Trash.", action: LibraryNoticeAction(title: "Undo") { undone += 1 })
        XCTAssertEqual(state.shownNoticeAction?.title, "Undo")
        // Another line joins the notice: the action stays with its own words.
        state.post(["Exported Standup.md"])
        XCTAssertEqual(state.notice, "Moved “Standup” to the Trash.\nExported Standup.md")
        XCTAssertEqual(state.shownNoticeAction?.title, "Undo")
        XCTAssertEqual(state.noticeAction(on: "Moved “Standup” to the Trash.")?.title, "Undo")
        XCTAssertNil(state.noticeAction(on: "Exported Standup.md"))
        state.performNoticeAction()
        XCTAssertEqual(undone, 1)
        XCTAssertEqual(state.notice, "Exported Standup.md", "Acting on it takes its own line away, and only that")
        XCTAssertNil(state.shownNoticeAction)
        state.performNoticeAction()
        XCTAssertEqual(undone, 1, "Once")
        state.notice = nil

        // Alone in the notice, acting on it closes the notice.
        state.post("Moved “Standup” to the Trash.", action: LibraryNoticeAction(title: "Undo") { undone += 1 })
        state.performNoticeAction()
        XCTAssertEqual(undone, 2)
        XCTAssertNil(state.notice)

        // Dismissed, the action goes with it, even if the same words come back later without one.
        state.post("Moved “Standup” to the Trash.", action: LibraryNoticeAction(title: "Undo") { undone += 1 })
        state.notice = nil
        state.post(["Moved “Standup” to the Trash."])
        XCTAssertNil(state.shownNoticeAction)
        // Words that replace the notice take its action away too.
        state.post("Exported Standup.md", action: LibraryNoticeAction(title: "Show in Finder") {})
        state.notice = "Something else happened."
        XCTAssertNil(state.shownNoticeAction)
        await state.flush()
    }

    func testBehaviorANoticesActionPostedAfterAnotherLineEndsItsOwnLine() async throws {
        let state = await state()
        var restored: [String] = []
        state.post(["Exported Standup.md"])
        state.post("Moved “Roadmap” to the Trash.", action: LibraryNoticeAction(title: "Undo") { restored.append("Roadmap") })
        XCTAssertEqual(state.noticeLines, ["Exported Standup.md", "Moved “Roadmap” to the Trash."])
        XCTAssertNil(state.noticeAction(on: "Exported Standup.md"), "The first line has nothing to undo")
        XCTAssertEqual(state.noticeAction(on: "Moved “Roadmap” to the Trash.")?.title, "Undo")
        state.performNoticeAction()
        XCTAssertEqual(restored, ["Roadmap"])
        XCTAssertEqual(state.notice, "Exported Standup.md", "The export line stays")
        XCTAssertNil(state.noticeAction(on: "Exported Standup.md"))
        await state.flush()
    }

    func testBehaviorARecordingThatStopsOnItsOwnKeepsWhyForItsConversation() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(capture: Self.fakeCapture(microphone))
        let id = try await recording(state)
        // The system's words aren't the person's: the recorder says it in its own sentence.
        microphone.send(.failed(FakeError(message: "kAudioHardwareNotRunningError")))
        try await waitUntil("the stop to be kept") { state.unexpectedStops[id] != nil }
        XCTAssertEqual(state.unexpectedStops[id], RecordingController.unexpectedStopSentence)
        try await waitUntil("the capture to finish") { state.recordingID == nil }
        XCTAssertEqual(state.unexpectedStops[id], RecordingController.unexpectedStopSentence, "Kept once the recording is filed")
        state.dismissUnexpectedStop(id)
        XCTAssertNil(state.unexpectedStops[id])
        await state.flush()
    }

    /// A full disk stops the track and then fails the recording's details too: why it stopped is still what's kept.
    func testBehaviorWhyARecordingStoppedOutlastsItsDetailsNotBeingSaved() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let state = await state(capture: Self.fakeCapture(microphone))
        let id = try await recording(state) { directory in
            // A folder where capture-result.json goes: saving the details fails, as on a full disk.
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("capture-result.json/kept", isDirectory: true),
                                                    withIntermediateDirectories: true)
            XCTAssertThrowsError(try CaptureJSON.persist(["probe": 1], at: directory.appendingPathComponent("capture-result.json")))
        }
        let why = PCMTrackWriterError.diskBacklog.localizedDescription
        microphone.send(.failed(PCMTrackWriterError.diskBacklog))
        try await waitUntil("the stop to be kept") { state.unexpectedStops[id] != nil }
        XCTAssertEqual(state.unexpectedStops[id], why)
        XCTAssertEqual(state.recorder.lastError, why, "The details not being saved doesn't replace why it stopped")
        try await waitUntil("the capture to finish") { state.recordingID == nil }
        XCTAssertEqual(state.unexpectedStops[id], why)
        await state.flush()
    }

    func testBehaviorWhenReadyReturnsOnceTheLibraryIsOpen() async throws {
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookHooks"), defaults: makeTestDefaults("local.daybook.tests.hooks"))
        XCTAssertFalse(state.isReady)
        let waiting = Task { await state.whenReady(); return state.isReady }
        await state.initialize()
        let ready = await waiting.value
        XCTAssertTrue(ready)
        // Ready already: at once.
        await state.whenReady()
        await state.flush()
    }
}
