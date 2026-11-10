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

        state.window.pageSpreadFits = true
        XCTAssertTrue(state.window.showsPageSpread(hasTranscript: state.hasTranscriptPage(meeting)))
        state.window.showPassage(segment.id)
        XCTAssertEqual(state.window.pageScrollTarget, segment.id, "the transcript beside it scrolls there and flashes it")
        XCTAssertEqual(state.window.pageMode, .summary, "the page doesn't turn")

        state.window.pageScrollTarget = nil
        state.window.pageSpreadFits = false
        state.window.showPassage(segment.id)
        XCTAssertEqual(state.window.pageMode, .transcript, "with room for one page, it turns to the transcript")
        XCTAssertEqual(state.window.pageScrollTarget, segment.id)
    }

    func testBehaviorShowInYourNotesStaysOnTheSpread() async throws {
        let (state, root, id) = await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        state.window.pageSpreadFits = true
        state.window.pageMode = .transcript

        TranscriptHost.mac(state: state, player: state.playback, meetingID: id, play: { _ in }).showNotes()

        XCTAssertEqual(state.window.pageMode, .transcript, "the summary is already beside the transcript")
        XCTAssertEqual(state.window.takeSummaryRequest(for: id), SummaryBlockID.notes, "and it moves to your notes")

        state.window.pageSpreadChosen = false
        TranscriptHost.mac(state: state, player: state.playback, meetingID: id, play: { _ in }).showNotes()
        XCTAssertEqual(state.window.pageMode, .summary, "collapsed to the transcript, the page turns")
    }

    func testBehaviorChoosingAPageFollowsTheToggles() async throws {
        let (state, root, id) = await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        state.window.pageSpreadFits = true
        XCTAssertTrue(state.window.pairsPages(hasTranscript: state.hasTranscriptPage(meeting)))
        XCTAssertEqual(state.window.pageSides(hasTranscript: state.hasTranscriptPage(meeting)), PageSides(spread: true, mode: .summary))

        state.window.choosePage(.transcript, hasTranscript: state.hasTranscriptPage(meeting))
        XCTAssertFalse(state.window.pageSpreadChosen, "a lit Transcript keeps the transcript alone")
        XCTAssertEqual(state.window.pageMode, .transcript)
        XCTAssertFalse(state.window.showsPageSpread(hasTranscript: state.hasTranscriptPage(meeting)))
        XCTAssertFalse(state.window.pageSides(hasTranscript: state.hasTranscriptPage(meeting)).shows(.summary))

        state.window.choosePage(.summary, hasTranscript: state.hasTranscriptPage(meeting))
        XCTAssertTrue(state.window.pageSpreadChosen, "Summary puts the summary back beside it")
        XCTAssertEqual(state.window.pageMode, .summary)
        XCTAssertTrue(state.window.showsPageSpread(hasTranscript: state.hasTranscriptPage(meeting)))
    }

    func testBehaviorAConversationWithoutATranscriptShowsOnePageAndKeepsTheChoice() async throws {
        let (state, root, _) = await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let notesOnly = state.newMeeting(title: "Note at 10:15 AM")
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == notesOnly })
        state.window.pageSpreadFits = true

        XCTAssertFalse(state.window.showsPageSpread(hasTranscript: state.hasTranscriptPage(meeting)), "there's no transcript to put beside it")
        XCTAssertFalse(state.window.pairsPages(hasTranscript: state.hasTranscriptPage(meeting)), "the switch stays a switch")
        XCTAssertEqual(state.window.pageSides(hasTranscript: state.hasTranscriptPage(meeting)), PageSides(spread: false, mode: .summary))
        state.window.choosePage(.summary, hasTranscript: state.hasTranscriptPage(meeting))
        XCTAssertTrue(state.window.pageSpreadChosen, "⌘1 here doesn't collapse the next conversation's spread")
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
