import DaybookCore
import DaybookKit
import DaybookTestSupport
import DaybookUI
import Foundation
import XCTest
@testable import Daybook

/// Show in Your Notes on the Mac's transcript turns to the summary and asks it to move to your notes, as the iPhone's
/// does, with the same token request (`LibraryWindowModel.summaryRequest`, `ReadingSession.summaryRequest`): once, and
/// only on that conversation's summary.
@MainActor
final class SummaryJumpTests: XCTestCase {
    func testBehaviorShowInYourNotesTurnsToTheSummaryAtYourNotes() async throws {
        let root = makeTemporaryFolder("DaybookSummaryJump")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(libraryURL: root, defaults: makeTestDefaults())
        await state.initialize()
        let id = state.newMeeting(title: "Weekly")
        state.window.pageMode = .transcript
        let token = state.window.summaryRequest?.token ?? 0

        TranscriptHost.mac(state: state, player: state.playback, meetingID: id, play: { _ in }).showNotes()

        XCTAssertEqual(state.window.pageMode, .summary)
        XCTAssertGreaterThan(state.window.summaryRequest?.token ?? 0, token, "the summary page sees the request arrive")
        XCTAssertEqual(state.window.takeSummaryRequest(for: id), SummaryBlockID.notes)
        XCTAssertNil(state.window.takeSummaryRequest(for: id), "it moves the page once")

        let again = state.window.summaryRequest?.token ?? 0
        TranscriptHost.mac(state: state, player: state.playback, meetingID: id, play: { _ in }).showNotes()
        XCTAssertGreaterThan(state.window.summaryRequest?.token ?? 0, again, "asking for the same block again moves it again")
        XCTAssertEqual(state.window.takeSummaryRequest(for: id), SummaryBlockID.notes)
    }

    func testBehaviorAJumpForAnotherConversationIsDropped() {
        let lock = PersonalLock(defaults: makeTestDefaults(), platform: .mac, authenticator: SystemPersonalLockAuthenticator())
        let window = LibraryWindowModel(personalLock: lock, defaults: makeTestDefaults())
        let asked = UUID(), shown = UUID()
        window.showOnSummary(SummaryBlockID.notes, in: asked)
        XCTAssertNil(window.takeSummaryRequest(for: shown), "another conversation's summary doesn't move")
        XCTAssertNil(window.takeSummaryRequest(for: asked), "and the person has moved on from the one it was asked for")
    }
}
