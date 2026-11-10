import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookDesign

/// A status line counts down by itself, the same on both apps: its words move a second at a time, and only they do.
final class StatusLineTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testBehaviorACountdownLineTicksItsWordsAndShortWords() {
        typealias Words = SummaryPlacementWords
        let until = now.addingTimeInterval(12)
        let text = Words.countdown(seconds: 12) + " · 1 waiting"
        let line = StatusLineItem(id: "queue", symbol: "desktopcomputer", title: "This Mac", text: text, tone: .calm,
                                  shortText: Words.countdown(seconds: 12), countdownUntil: until)
        XCTAssertEqual(line.text(at: now.addingTimeInterval(3)), Words.countdown(seconds: 9) + " · 1 waiting")
        XCTAssertEqual(line.shortText(at: now.addingTimeInterval(3)), Words.countdown(seconds: 9))
        XCTAssertEqual(line.secondsLeft(at: now.addingTimeInterval(2.2)), 10, "rounded up")
        XCTAssertEqual(line.text(at: now.addingTimeInterval(30)), Words.countdown(seconds: 1) + " · 1 waiting", "never under a second")
        XCTAssertEqual(line.accessibilityLabel, "This Mac, " + text)
        // The line ticks as the shared words do, on the same second.
        for offset in [0, 2.2, 3, 11.9, 30] as [TimeInterval] {
            let at = now.addingTimeInterval(offset)
            XCTAssertEqual(line.text(at: at), Words.ticking(text, until: until, at: at))
            XCTAssertEqual(line.secondsLeft(at: at), Words.secondsLeft(until: until, at: at))
        }
    }

    func testBehaviorALineWithoutACountdownKeepsItsWords() {
        let line = StatusLineItem(id: "mac", symbol: "desktopcomputer", title: "Studio Mac", text: "Back in 5 s", tone: .linked)
        XCTAssertNil(line.secondsLeft(at: now))
        XCTAssertEqual(line.text(at: now), "Back in 5 s", "only a countdown's words move")
        XCTAssertNil(line.shortText(at: now))
    }

    /// ui-iphone-02: under touch a line's glyph column grows with the text but stops where a large glyph still fits,
    /// and the glyph stops growing before it; at the accessibility sizes the title and its words share four rows.
    func testBehaviorALinesGlyphColumnHasALimit() {
        XCTAssertEqual(StatusMetrics.glyphColumnLimit, 44)
        XCTAssertGreaterThan(StatusMetrics.glyphColumnLimit, StatusMetrics.phone.glyphColumn)
        XCTAssertEqual(StatusMetrics.largestGlyphSize, .accessibility2)
        XCTAssertEqual(StatusMetrics.stackedRows, 4)
        XCTAssertEqual(StatusMetrics.stackedTitleLimit, 2)
        XCTAssertEqual(StatusMetrics.stackedWordsLimit(titleLines: 1), 3, "a one-line title leaves its words three rows")
        XCTAssertEqual(StatusMetrics.stackedWordsLimit(titleLines: 2), 2)
        XCTAssertFalse(StatusMetrics.mac.usesTextStyles, "the Mac's lines keep their fixed column")
    }

    /// ui-iphone-02: at the accessibility sizes a short title ("iCloud") takes one row, and its words the three it leaves,
    /// so "Waiting for this library's key" isn't cut off with a row to spare; a title on two rows leaves its words two.
    /// Either way the line stays within the four rows the compact detent makes room for.
    @MainActor
    func testBehaviorAStackedLinesWordsTakeTheRowsItsTitleLeaves() {
        func height(_ title: String, _ text: String) -> CGFloat {
            let line = StatusLineItem(id: "sync", symbol: "icloud", title: title, text: text, tone: .attention)
            let view = StatusLineView(line, metrics: .phone).environment(\.dynamicTypeSize, .accessibility5)
            return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 150, height: 10_000)).height
        }
        let words = String(repeating: "Waiting for this library’s key ", count: 6)
        let one = height("iCloud", "Key"), shortTitle = height("iCloud", words), longTitle = height("Alex’s Studio MacBook Pro in the Office", words)
        let row = (one - 2) / 2
        XCTAssertGreaterThan(row, 0)
        XCTAssertEqual(shortTitle, 4 * row + 2, accuracy: row / 3, "a one-row title, then its words on three rows, cut after them")
        XCTAssertEqual(longTitle, 4 * row + 2, accuracy: row / 3, "a two-row title, then its words on two")
    }
}
