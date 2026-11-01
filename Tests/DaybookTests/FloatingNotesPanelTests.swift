import AppKit
import DaybookDesign
import DaybookUI
import SwiftUI
import XCTest
@testable import Daybook

/// Floating Notes sits over calls with your notes and live captions on it, so it stays out of
/// screen shares and screenshots.
@MainActor
final class FloatingNotesPanelTests: XCTestCase {
    func testThePanelFloatsOverCallsButIsLeftOutOfScreenCapture() {
        let panel = FloatingNotesWindow.floatingPanel()
        defer { panel.close() }
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    /// The title band is a little taller than the system's title bar, so the phase and the chips have
    /// room above and below them, and close stays on its centre line however the panel is resized.
    func testTheTitleBandHasRoomAndCloseStaysOnItsCentreLine() throws {
        let panel = FloatingNotesWindow.floatingPanel()
        defer { panel.close() }
        let chrome = PanelChrome()
        chrome.measure(panel)
        let titleBar = panel.frame.height - panel.contentLayoutRect.height
        XCTAssertGreaterThan(titleBar, 0)
        XCTAssertEqual(chrome.band, titleBar + FloatingLayout.bandRoom)
        XCTAssertEqual(chrome.buttonCenter, chrome.band / 2, "close on the band's centre line, as Compact is")

        let close = try XCTUnwrap(panel.standardWindowButton(.closeButton))
        func closeCenter() -> CGFloat { panel.frame.height - close.convert(close.bounds, to: nil).midY }
        for size in [NSSize(width: 340, height: FloatingLayout.compactHeight), NSSize(width: 480, height: 720)] {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
            panel.layoutIfNeeded()
            XCTAssertEqual(closeCenter(), chrome.band / 2, accuracy: 0.5, "after a resize to \(size)")
        }
    }

    /// The panel says once, at its root, that it's a panel: a shared view placed in it without its own
    /// metrics takes the panel's type and sizes, not the window's or the phone's.
    func testViewsUnderThePanelTakeThePanelDensity() {
        var seen: (density: DaybookDensity, metrics: PlatformMetrics)?
        let host = NSHostingView(rootView: DensityProbe { seen = ($0, $1) }.modifier(FloatingNotesSurface()))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(seen?.density, .panel)
        XCTAssertEqual(seen?.metrics, .for(.panel))
        XCTAssertEqual(seen?.metrics.meter, .panel, "The panel's meter, not the phone's bars")
        XCTAssertEqual(seen?.metrics.phase, .panel)
        XCTAssertEqual(DaybookFont.docTitle.size(.panel), 17, "Floating Notes' title")
    }
}

/// Reports the density and metrics a view under it reads.
private struct DensityProbe: View {
    let report: (DaybookDensity, PlatformMetrics) -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(\.platformMetrics) private var metrics

    var body: some View {
        report(density, metrics)
        return Color.clear
    }
}
