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
}
