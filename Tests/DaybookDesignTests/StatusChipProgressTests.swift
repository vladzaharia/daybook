import AppKit
import SwiftUI
import XCTest
@testable import DaybookDesign

/// A chip at work fills its own capsule with the brand gradient: VoiceOver hears how far it's gone, and the words
/// over the fill keep 4.5:1 wherever the gradient reaches, in every appearance.
final class StatusChipProgressTests: XCTestCase {
    func testBehaviorVoiceOverHearsTheWorkAsAPercent() {
        XCTAssertEqual(StatusChip.accessibilityValue(progress: 0.4), "40 percent")
        XCTAssertEqual(StatusChip.accessibilityValue(progress: 0.999), "99 percent", "whole percents, rounded down, as the words are")
        XCTAssertEqual(StatusChip.accessibilityValue(progress: 1), "100 percent")
        XCTAssertEqual(StatusChip.accessibilityValue(progress: -0.2), "0 percent")
        XCTAssertEqual(StatusChip.accessibilityValue(progress: 3), "100 percent")
        XCTAssertEqual(StatusChip.accessibilityValue(progress: .nan), "0 percent")
        XCTAssertNil(StatusChip.accessibilityValue(progress: nil), "no work, no value")
    }

    /// Every stop of the gradient, laid at the fill's opacity over the chip's quiet fill on paper, under the words'
    /// body ink: light, dark, and both with Increase Contrast.
    func testBehaviorTheWordsKeepTheirContrastOverTheWorksFill() {
        typealias Shade = DaybookPalette.Shade
        for (dark, more) in [(false, false), (true, false), (false, true), (true, true)] {
            let paper = Shade.paper.hex(dark: dark, increasedContrast: more)
            let quiet = DaybookContrast.flattened(.quiet, over: paper, dark: dark, increasedContrast: more)
            let ink = StatusChip.progressInk.hex(dark: dark, increasedContrast: more)
            for stop in [Shade.neonMint, Shade.neonCyan, Shade.neonViolet] {
                let fill = DaybookContrast.composite(stop.hex(dark: dark, increasedContrast: more),
                                                     opacity: StatusChip.progressFillOpacity(dark: dark), over: quiet)
                XCTAssertGreaterThanOrEqual(DaybookContrast.ratio(ink, fill), 4.5, "dark \(dark), more contrast \(more), \(String(stop.light, radix: 16))")
            }
            XCTAssertGreaterThanOrEqual(DaybookContrast.ratio(ink, quiet), 4.5, "past the fill, on the quiet capsule")
        }
    }

    /// Offered a row, a chip at work spans it; a chip without work keeps its own size.
    @MainActor
    func testBehaviorAChipAtWorkSpansItsRow() {
        final class Box { var width: CGFloat = 0 }
        func laidOut(_ chip: StatusChip) -> CGFloat {
            let box = Box()
            let row = HStack(spacing: 0) {
                chip.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { box.width = $0 }
                Spacer(minLength: 0)
            }
            let host = NSHostingView(rootView: row.frame(width: 300, height: 30).environment(\.daybookDensity, .panel))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
            host.layoutSubtreeIfNeeded()
            return box.width
        }
        let working = StatusChip(symbol: "quote.bubble", text: "Transcribing · 40%", tone: .working, progress: 0.4, expands: true)
        let plain = StatusChip(symbol: "waveform", text: "Call", tone: .linked)
        XCTAssertEqual(laidOut(working), 300, accuracy: 0.5, "the whole row")
        XCTAssertLessThan(laidOut(plain), 100, "its own size")
        XCTAssertGreaterThan(laidOut(plain), 0)
    }
}
