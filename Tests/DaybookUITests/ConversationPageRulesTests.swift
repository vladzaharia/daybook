import DaybookDesign
import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// The conversation page's rules both apps draw by: a title and a bookmark label commit once and never leave a title
/// empty, the status animates on its words and never its figure, a box's actions move under its words when it's
/// narrow, and the reveal's timing.
final class ConversationPageRulesTests: XCTestCase {
    func testBehaviorATitleCommitsOnceTrimmedAndNeverEmpty() {
        XCTAssertEqual(TitleEdit.committed(draft: "  Roadmap review ", current: "Weekly sync"), "Roadmap review")
        XCTAssertNil(TitleEdit.committed(draft: "", current: "Weekly sync"), "an emptied title puts the old one back")
        XCTAssertNil(TitleEdit.committed(draft: "   \n", current: "Weekly sync"))
        XCTAssertNil(TitleEdit.committed(draft: "Weekly sync", current: "Weekly sync"), "nothing to save")
        XCTAssertEqual(TitleEdit.committed(draft: "Two\nlines", current: "x"), "Two lines")
        XCTAssertTrue(TitleEdit.endsEditing("Roadmap\n"), "Return ends the title")
        XCTAssertFalse(TitleEdit.endsEditing("Roadmap"))
    }

    func testBehaviorABookmarkLabelReadsAutomaticLabelsAsNone() {
        for automatic in BookmarkMarks.automaticLabels {
            XCTAssertEqual(BookmarkLabel.shown(automatic), "")
            XCTAssertNil(BookmarkLabel.committed(draft: "", stored: automatic), "leaving it empty changes nothing")
        }
        XCTAssertEqual(BookmarkLabel.committed(draft: " Gate on the fix ", stored: ""), "Gate on the fix")
        XCTAssertNil(BookmarkLabel.committed(draft: "Gate on the fix", stored: "Gate on the fix"))
        XCTAssertEqual(BookmarkLabel.committed(draft: "", stored: "Gate on the fix"), "", "clearing a label is a change")

        let track = RecordingTrack(source: .soundcore, relativePath: "s.mp3", fileName: "s.mp3")
        let meeting = Meeting(title: "Walk", tracks: [track])
        XCTAssertEqual(BookmarkLabel.placeholder(for: Highlight(trackID: track.id, time: 3, text: ""), in: meeting), "Bookmark from Soundcore")
        XCTAssertEqual(BookmarkLabel.placeholder(for: Highlight(time: 3, text: ""), in: meeting), "Bookmark")
    }

    func testBehaviorTheStatusAnimatesOnItsWordsNeverItsFigure() {
        let at40 = ConversationStatusPresentation(kind: .line, symbol: "desktopcomputer", title: "Transcribing on Studio Mac · 40%", progress: 0.4)
        var at41 = at40
        at41.title = "Transcribing on Studio Mac · 41%"
        at41.progress = 0.41
        XCTAssertEqual(StatusBlockLayout.motionKey(at40), StatusBlockLayout.motionKey(at41), "a new percent starts no animation")
        var summarizing = at41
        summarizing.title = "Summarizing on Studio Mac · 10%"
        XCTAssertNotEqual(StatusBlockLayout.motionKey(at40), StatusBlockLayout.motionKey(summarizing), "a new step does")
        XCTAssertNotEqual(StatusBlockLayout.motionKey(at40), StatusBlockLayout.motionKey(nil))

        let countdown = ConversationStatusPresentation(kind: .line, symbol: "clock", title: "Summarizing on this Mac in 12 s",
                                                       countdownUntil: Date(), actions: [.placement(.useCloud), .placement(.startNow)])
        var later = countdown
        later.title = "Summarizing on this Mac in 11 s"
        XCTAssertEqual(StatusBlockLayout.motionKey(countdown), StatusBlockLayout.motionKey(later), "a tick isn't a change of state")
    }

    func testBehaviorABoxStacksItsActionsWhenNarrowAndSpacesThemForAFinger() {
        XCTAssertFalse(StatusBlockLayout.stacksActions(width: 640, density: .window), "the Mac's page: beside the words")
        XCTAssertTrue(StatusBlockLayout.stacksActions(width: 402, density: .touch), "an iPhone: under them")
        XCTAssertFalse(StatusBlockLayout.stacksActions(width: 600, density: .touch), "the open Duo as one page: beside them")
        XCTAssertTrue(StatusBlockLayout.stacksActions(width: 640, density: .panel), "Floating Notes: always under")
        XCTAssertGreaterThanOrEqual(StatusBlockLayout.actionSpacing(.touch), 24, "Use the Cloud and Start Now never a mis-tap apart")
        XCTAssertEqual(StatusBlockLayout.attention(.problem), .problem)
        XCTAssertEqual(StatusBlockLayout.attention(.accent), .accent)
        XCTAssertEqual(StatusBlockLayout.attention(.info), .info)
    }

    func testBehaviorANewSummaryRevealsBlockByBlockUpToSix() {
        XCTAssertEqual(SummaryRevealTiming.delay(index: 0), 0)
        XCTAssertEqual(SummaryRevealTiming.delay(index: 1), 0.04, accuracy: 0.0001)
        XCTAssertEqual(SummaryRevealTiming.delay(index: 9), SummaryRevealTiming.delay(index: 5), "no block waits longer than the sixth")
    }

    func testBehaviorBulletsFollowTheDensity() {
        XCTAssertEqual(SummaryMarkdownMetrics.bullet(density: .window).dot, 5)
        XCTAssertEqual(SummaryMarkdownMetrics.bullet(density: .window, scale: 1.2).column, 16 * 1.2, accuracy: 0.001)
        XCTAssertEqual(SummaryMarkdownMetrics.bullet(density: .touch).dot, 6)
        XCTAssertEqual(SummaryMarkdownMetrics.bullet(density: .touch).column, 20)
    }
}
