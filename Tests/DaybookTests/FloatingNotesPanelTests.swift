import AppKit
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
}
