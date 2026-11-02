import DaybookCore
import DaybookKit
import DaybookTestSupport
import DaybookUI
import Foundation
import XCTest
@testable import Daybook

/// Show in Your Notes on the Mac's transcript turns to the summary and asks it to move to your notes, as the iPhone's
/// does: once, and only on that conversation's summary.
@MainActor
final class SummaryJumpTests: XCTestCase {
    func testBehaviorShowInYourNotesTurnsToTheSummaryAtYourNotes() async throws {
        let root = makeTemporaryFolder("DaybookSummaryJump")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(libraryURL: root, defaults: makeTestDefaults())
        await state.initialize()
        let id = state.newMeeting(title: "Weekly")
        state.pageMode = .transcript
        let jump = SummaryJump.window
        _ = jump.take(for: id)
        let token = jump.token

        TranscriptHost.mac(state: state, player: state.playback, meetingID: id, play: { _ in }).showNotes()

        XCTAssertEqual(state.pageMode, .summary)
        XCTAssertGreaterThan(jump.token, token, "the summary page sees the request arrive")
        XCTAssertEqual(jump.take(for: id), SummaryJump.notes)
        XCTAssertNil(jump.take(for: id), "it moves the page once")
    }

    func testBehaviorAJumpForAnotherConversationIsDropped() {
        let jump = SummaryJump()
        let asked = UUID(), shown = UUID()
        jump.show(SummaryJump.notes, in: asked)
        XCTAssertNil(jump.take(for: shown), "another conversation's summary doesn't move")
        XCTAssertNil(jump.take(for: asked), "and the person has moved on from the one it was asked for")
    }
}
