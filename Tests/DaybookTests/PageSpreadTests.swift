import DaybookCore
import DaybookKit
import DaybookTestSupport
import DaybookUI
import Foundation
import XCTest
@testable import Daybook

/// Where the detail column has room for two pages, a conversation with a transcript shows Summary and Transcript side by
/// side: the toolbar's Summary | Transcript becomes a pair of toggles, and what the page is asked to show (a passage,
/// Your notes, Find) comes into view beside the other page instead of turning it.
@MainActor
final class PageSpreadTests: XCTestCase {
    func testBehaviorTheTogglesKeepALitPageAloneAndPutTheOtherBackBesideIt() {
        let spread = PageSides(spread: true, mode: .summary)
        XCTAssertTrue(spread.shows(.summary) && spread.shows(.transcript), "both lit while both show")

        let transcriptOnly = spread.choosing(.transcript, pairs: true)
        XCTAssertEqual(transcriptOnly, PageSides(spread: false, mode: .transcript), "a lit one keeps its page alone")
        XCTAssertFalse(transcriptOnly.shows(.summary))
        XCTAssertEqual(spread.choosing(.summary, pairs: true), PageSides(spread: false, mode: .summary))

        XCTAssertEqual(transcriptOnly.choosing(.transcript, pairs: true), transcriptOnly, "one page always shows")
        XCTAssertEqual(transcriptOnly.choosing(.summary, pairs: true), PageSides(spread: true, mode: .summary),
                       "the other comes back beside it, and is the page a narrower window shows")
    }

    func testBehaviorWithRoomForOnePageItsASwitchThatKeepsTheSpreadForLater() {
        let collapsed = PageSides(spread: false, mode: .summary)
        XCTAssertEqual(collapsed.choosing(.transcript, pairs: false), PageSides(spread: false, mode: .transcript))
        let chosen = PageSides(spread: true, mode: .summary)
        XCTAssertEqual(chosen.choosing(.transcript, pairs: false), PageSides(spread: true, mode: .transcript),
                       "the window widening again brings both pages back")
    }

    func testBehaviorAPassageScrollsTheTranscriptBesideTheSummaryWithoutTurningThePage() async throws {
        let (state, root, id) = await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        let segment = try XCTUnwrap(meeting.unifiedTranscript.first)

        state.pageSpreadFits = true
        XCTAssertTrue(state.showsPageSpread(meeting))
        state.showPassage(segment.id)
        XCTAssertEqual(state.pageScrollTarget, segment.id, "the transcript beside it scrolls there and flashes it")
        XCTAssertEqual(state.pageMode, .summary, "the page doesn't turn")

        state.pageScrollTarget = nil
        state.pageSpreadFits = false
        state.showPassage(segment.id)
        XCTAssertEqual(state.pageMode, .transcript, "with room for one page, it turns to the transcript")
        XCTAssertEqual(state.pageScrollTarget, segment.id)
    }

    func testBehaviorShowInYourNotesStaysOnTheSpread() async throws {
        let (state, root, id) = await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        state.pageSpreadFits = true
        state.pageMode = .transcript
        let jump = SummaryJump.window
        _ = jump.take(for: id)

        TranscriptHost.mac(state: state, player: state.playback, meetingID: id, play: { _ in }).showNotes()

        XCTAssertEqual(state.pageMode, .transcript, "the summary is already beside the transcript")
        XCTAssertEqual(jump.take(for: id), SummaryJump.notes, "and it moves to your notes")

        state.pageSpreadChosen = false
        TranscriptHost.mac(state: state, player: state.playback, meetingID: id, play: { _ in }).showNotes()
        XCTAssertEqual(state.pageMode, .summary, "collapsed to the transcript, the page turns")
        _ = jump.take(for: id)
    }

    func testBehaviorChoosingAPageFollowsTheToggles() async throws {
        let (state, root, id) = await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        state.pageSpreadFits = true
        XCTAssertTrue(state.pairsPages(meeting))
        XCTAssertEqual(state.pageSides(meeting), PageSides(spread: true, mode: .summary))

        state.choosePage(.transcript, for: meeting)
        XCTAssertFalse(state.pageSpreadChosen, "a lit Transcript keeps the transcript alone")
        XCTAssertEqual(state.pageMode, .transcript)
        XCTAssertFalse(state.showsPageSpread(meeting))
        XCTAssertFalse(state.pageSides(meeting).shows(.summary))

        state.choosePage(.summary, for: meeting)
        XCTAssertTrue(state.pageSpreadChosen, "Summary puts the summary back beside it")
        XCTAssertEqual(state.pageMode, .summary)
        XCTAssertTrue(state.showsPageSpread(meeting))
    }

    func testBehaviorAConversationWithoutATranscriptShowsOnePageAndKeepsTheChoice() async throws {
        let (state, root, _) = await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let notesOnly = state.newMeeting(title: "Note at 10:15 AM")
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == notesOnly })
        state.pageSpreadFits = true

        XCTAssertFalse(state.showsPageSpread(meeting), "there's no transcript to put beside it")
        XCTAssertFalse(state.pairsPages(meeting), "the switch stays a switch")
        XCTAssertEqual(state.pageSides(meeting), PageSides(spread: false, mode: .summary))
        state.choosePage(.summary, for: meeting)
        XCTAssertTrue(state.pageSpreadChosen, "⌘1 here doesn't collapse the next conversation's spread")
    }

    private func makeState() async -> (AppState, URL, UUID) {
        let root = makeTemporaryFolder("DaybookPageSpread")
        let state = AppState(libraryURL: root, defaults: makeTestDefaults())
        await state.initialize()
        let id = state.newMeeting(title: "Weekly product sync")
        state.update(id) { meeting in
            meeting.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "We ship the beta on Friday.")]
        }
        return (state, root, id)
    }
}
