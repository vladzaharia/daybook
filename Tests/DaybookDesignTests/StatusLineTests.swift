import SwiftUI
import XCTest
@testable import DaybookDesign

/// A status line counts down by itself, the same on both apps: its words move a second at a time, and only they do.
final class StatusLineTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testBehaviorACountdownLineTicksItsWordsAndShortWords() {
        let line = StatusLineItem(id: "queue", symbol: "desktopcomputer", title: "This Mac", text: "Summarizing in 12 s · 1 waiting", tone: .calm,
                                  shortText: "Summarizing in 12 s", countdownUntil: now.addingTimeInterval(12))
        XCTAssertEqual(line.text(at: now.addingTimeInterval(3)), "Summarizing in 9 s · 1 waiting")
        XCTAssertEqual(line.shortText(at: now.addingTimeInterval(3)), "Summarizing in 9 s")
        XCTAssertEqual(line.secondsLeft(at: now.addingTimeInterval(2.2)), 10, "rounded up")
        XCTAssertEqual(line.text(at: now.addingTimeInterval(30)), "Summarizing in 1 s · 1 waiting", "never under a second")
        XCTAssertEqual(line.accessibilityLabel, "This Mac, Summarizing in 12 s · 1 waiting")
    }

    func testBehaviorALineWithoutACountdownKeepsItsWords() {
        let line = StatusLineItem(id: "mac", symbol: "desktopcomputer", title: "Studio Mac", text: "Back in 5 s", tone: .linked)
        XCTAssertNil(line.secondsLeft(at: now))
        XCTAssertEqual(line.text(at: now), "Back in 5 s", "only a countdown's words move")
        XCTAssertNil(line.shortText(at: now))
    }

    /// ui-iphone-02: under touch a line's glyph column grows with the text but stops where a large glyph still fits,
    /// and the glyph stops growing before it; the words go under the title on two lines at the accessibility sizes.
    func testBehaviorALinesGlyphColumnHasALimit() {
        XCTAssertEqual(StatusMetrics.glyphColumnLimit, 44)
        XCTAssertGreaterThan(StatusMetrics.glyphColumnLimit, StatusMetrics.phone.glyphColumn)
        XCTAssertEqual(StatusMetrics.largestGlyphSize, .accessibility2)
        XCTAssertEqual(StatusMetrics.stackedLineLimit, 2)
        XCTAssertFalse(StatusMetrics.mac.usesTextStyles, "the Mac's lines keep their fixed column")
    }
}
