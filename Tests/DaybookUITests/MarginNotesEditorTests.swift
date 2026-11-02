import AppKit
import DaybookDesign
import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookUI

/// The notes editor both apps share: how the lane reads the notes' paragraphs, where the recording's marks go, and
/// what VoiceOver and the keyboard reach in it on the Mac.
@MainActor
final class MarginNotesEditorTests: XCTestCase {
    // MARK: Paragraphs

    func testBehaviorParagraphsSplitAsTheTimelineSplitsThem() {
        let text = "First\n\n  \nSecond line\r\nThird" as NSString
        let ranges = NoteParagraphs.ranges(in: text)
        XCTAssertEqual(ranges.map { text.substring(with: $0) }, ["First", "Second line", "Third"], "blank lines aren't paragraphs")
        XCTAssertEqual(NoteParagraphs.ranges(in: "" as NSString), [])
    }

    /// A bookmark or photo goes before the first paragraph written after it; after the last when nothing was.
    func testBehaviorMarksSitBeforeTheParagraphWrittenAfterThem() {
        let times: [TimeInterval?] = [2, nil, 10]
        let marks = [NoteMark(id: "late", kind: .bookmark, time: 12), NoteMark(id: "early", kind: .bookmark, time: 4),
                     NoteMark(id: "photo", kind: .photo, time: 6)]
        let placed = NoteParagraphs.placement(of: marks, times: times)
        XCTAssertEqual(placed.map(\.mark.id), ["early", "photo", "late"], "in time order")
        XCTAssertEqual(placed.map(\.before), [2, 2, 3], "before the 0:10 paragraph, and after the last")
        XCTAssertEqual(NoteMark(id: "b", kind: .bookmark, time: 250).spoken, "Bookmark at \(SpokenTime.format(250))")
    }

    func testBehaviorPlayFromHerePlaysTheParagraphAtTheCaretOrTheOneBeforeIt() {
        let text = "Intro\nUntimed\nLater" as NSString
        let ranges = NoteParagraphs.ranges(in: text)
        let times: [TimeInterval?] = [5, nil, 40]
        XCTAssertEqual(NoteParagraphs.playTime(at: 2, ranges: ranges, times: times), 5)
        XCTAssertEqual(NoteParagraphs.playTime(at: 8, ranges: ranges, times: times), 5, "an untimed paragraph plays from the one before it")
        XCTAssertEqual(NoteParagraphs.playTime(at: text.length, ranges: ranges, times: times), 40)
        XCTAssertNil(NoteParagraphs.playTime(at: 0, ranges: ranges, times: [nil, nil, nil]))
    }

    func testBehaviorTheSearchsMatchesAreFoundWhateverTheirCaseAndAccents() {
        let text = "Beta date, then the BETA list and the bêta." as NSString
        XCTAssertEqual(NoteParagraphs.matches(of: "beta", in: text).map { text.substring(with: $0) }, ["Beta", "BETA", "bêta"])
        XCTAssertEqual(NoteParagraphs.matches(of: "  ", in: text), [], "no query, no marks")
    }

    // MARK: The Mac's lane

    private func editor(_ text: String, times: [TimeInterval?], marks: [NoteMark] = [], plays: ((TimeInterval) -> Void)? = nil) -> MarginTextView {
        let view = MarginTextView()
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        view.textContainer?.lineFragmentPadding = 0
        view.margin = 52
        view.times = times
        view.marks = marks
        view.playTime = plays
        view.string = text
        view.applyTypingStyle()
        view.updateGutter()
        return view
    }

    /// Regression: the margin's times were drawn only, so VoiceOver never heard them and nothing but a click played
    /// from them. Each is now a button that says where it plays from, and each mark says itself.
    func testBehaviorVoiceOverHearsEachTimeAsAButtonThatPlaysAndEachMark() throws {
        var played: [TimeInterval] = []
        let view = editor("Launch is two weeks out\nAnnual plan leads the pricing page", times: [250, 316],
                          marks: [NoteMark(id: "b", kind: .bookmark, time: 260)], plays: { played.append($0) })
        let children = try XCTUnwrap(view.gutter.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.map { $0.accessibilityLabel() }, [
            "Play from \(SpokenTime.format(250))", "Bookmark at \(SpokenTime.format(260))", "Play from \(SpokenTime.format(316))"
        ], "in reading order")
        XCTAssertEqual(children[0].accessibilityRole(), .button)
        XCTAssertEqual(children[1].accessibilityRole(), .staticText)
        XCTAssertTrue(children[2].accessibilityPerformPress())
        XCTAssertEqual(played, [316])
        XCTAssertFalse(children[1].accessibilityPerformPress(), "a mark doesn't play")
    }

    func testBehaviorTimesThatCantPlaySayWhenTheNoteWasTaken() throws {
        let view = editor("Written while recording", times: [12])
        let children = try XCTUnwrap(view.gutter.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.map { $0.accessibilityLabel() }, ["Note at \(SpokenTime.format(12))"])
        XCTAssertEqual(children.first?.accessibilityRole(), .staticText)
        XCTAssertNil(view.accessibilityCustomActions()?.first { $0.name == MarginNotesEditor.playFromHere })
    }

    func testBehaviorPlayFromHereIsInTheMenuAndAVoiceOverAction() throws {
        var played: [TimeInterval] = []
        let view = editor("Intro\nThe pricing page", times: [5, 40], plays: { played.append($0) })
        view.setSelectedRange(NSRange(location: 8, length: 0))
        let action = try XCTUnwrap(view.accessibilityCustomActions()?.first { $0.name == MarginNotesEditor.playFromHere })
        XCTAssertTrue(action.handler?() ?? false)
        XCTAssertEqual(played, [40], "the paragraph at the insertion point")
        XCTAssertEqual(view.playableTime(at: 1), 5)
        XCTAssertTrue(view.usesFindBar, "⌘F finds in the notes")
        XCTAssertTrue(view.isIncrementalSearchingEnabled)
    }

    /// Bookmarks made while recording appear in the lane, beside the paragraph written after them, without moving
    /// the text or the times.
    func testBehaviorBookmarksAreTicksInTheLane() {
        let view = editor("First\nSecond", times: [2, 30], marks: [NoteMark(id: "b", kind: .bookmark, time: 10),
                                                                   NoteMark(id: "p", kind: .photo, time: 45)])
        XCTAssertEqual(view.gutter.labels.map(\.text), ["0:02", "0:30"])
        let ticks = view.gutter.ticks
        XCTAssertEqual(ticks.map(\.mark.id), ["b", "p"])
        XCTAssertLessThan(ticks[0].rect.maxX, view.margin, "in the lane, clear of the text")
        XCTAssertGreaterThan(ticks[0].rect.minX, view.gutter.rect(for: view.gutter.labels[1]).maxX, "between the time and the text")
        XCTAssertEqual(ticks[0].rect.minY, view.gutter.rect(for: view.gutter.labels[1]).minY, accuracy: 6, "beside the paragraph after it")
        XCTAssertGreaterThan(ticks[1].rect.minY, ticks[0].rect.maxY, "after the last paragraph, where the next goes")
    }
}
