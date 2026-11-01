import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// What `AppState` offers the views around it: the library notice's one action, why a recording stopped on its own,
/// and waiting for the library to open.
@MainActor
final class AppStateHooksTests: XCTestCase {
    private func state() async -> AppState {
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookHooks"), defaults: makeTestDefaults("local.daybook.tests.hooks"))
        await state.initialize()
        return state
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
        state.performNoticeAction()
        XCTAssertEqual(undone, 1)
        XCTAssertNil(state.notice, "Acting on it closes the notice")
        XCTAssertNil(state.shownNoticeAction)
        state.performNoticeAction()
        XCTAssertEqual(undone, 1, "Once")

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

    func testBehaviorARecordingThatStopsOnItsOwnKeepsWhyForItsConversation() async throws {
        let state = await state()
        let id = state.newMeeting(title: "Interview")
        state.recordingID = id
        let directory = makeTemporaryFolder("DaybookHooksCapture").appendingPathComponent(id.uuidString, isDirectory: true)
        let result = CaptureResult(id: UUID(), startedAt: Date(timeIntervalSinceNow: -60), endedAt: Date(), tracks: [], warnings: [],
                                   directory: directory)
        state.recorder.onUnexpectedStop?(result)
        XCTAssertEqual(state.unexpectedStops[id], RecordingController.unexpectedStopSentence,
                       "The recorder's one sentence; its own words when the cause is one of Daybook's")
        try await waitUntil("the capture to finish") { state.recordingID == nil }
        XCTAssertEqual(state.unexpectedStops[id], RecordingController.unexpectedStopSentence, "Kept once the recording is filed")
        state.dismissUnexpectedStop(id)
        XCTAssertNil(state.unexpectedStops[id])
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
