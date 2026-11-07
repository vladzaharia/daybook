import AppKit
import DaybookDesign
import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookUI

/// One page geometry for every width both apps draw at: the Mac's detail column, the iPhone 18 Pro, the
/// Duo's cover and each of its open pages, and Floating Notes.
final class ReadingGeometryTests: XCTestCase {
    func testAWidePageHangsItsMarginLeftOfACentredMeasure() {
        let frame = ReadingGeometry.frame(width: 1000, density: .window)
        XCTAssertTrue(frame.hangsMargin)
        XCTAssertEqual(frame.measure, 640)
        XCTAssertEqual(frame.margin, 56)
        XCTAssertEqual(frame.leading, 124, "The measure centred, the margin hanging into the space on its left")
        XCTAssertEqual(frame.textLeading + frame.measure / 2, 500, "The text's middle is the column's")
        XCTAssertEqual(ReadingWidth(width: 1000), .regular)
    }

    func testAMacPageJustOverSixHundredKeepsItsMarginAndNarrowsTheMeasure() {
        let frame = ReadingGeometry.frame(width: 620, density: .window)
        XCTAssertTrue(frame.hangsMargin)
        XCTAssertEqual(frame.leading, 24)
        XCTAssertEqual(frame.measure, 508, "620 less the 24 and 32 pt gutters and the margin")
        XCTAssertEqual(frame.trailing, 32)
    }

    func testUnderSixHundredTheMarginFoldsIntoTheColumn() {
        let mac = ReadingGeometry.frame(width: 580, density: .window)
        XCTAssertFalse(mac.hangsMargin)
        XCTAssertEqual(mac.measure, 532)
        XCTAssertEqual(ReadingWidth(width: 599.5), .narrow)

        // iPhone 18 Pro, in the hand.
        let phone = ReadingGeometry.frame(width: 402, density: .touch)
        XCTAssertEqual(phone, ReadingGeometry.Frame(leading: 20, margin: 0, measure: 362, trailing: 20))
        // The Duo's cover.
        XCTAssertEqual(ReadingGeometry.frame(width: 466, density: .touch).measure, 426)
    }

    func testEachPageOfTheOpenDuoUsesTheSpecifiedCreaseClearance() {
        // The left page meets the crease on its trailing side, the right page on its leading side.
        let left = ReadingGeometry.frame(width: 475.5, density: .touch, creaseEdge: .trailing)
        XCTAssertEqual(left.leading, 20)
        XCTAssertEqual(left.trailing, 16)
        XCTAssertEqual(left.measure, 439.5)
        let right = ReadingGeometry.frame(width: 391.5, density: .touch, creaseEdge: .leading)
        XCTAssertEqual(right.leading, 16)
        XCTAssertEqual(right.measure, 355.5)
        XCTAssertFalse(left.hangsMargin || right.hangsMargin, "Each page is a phone-sized column")
        XCTAssertEqual(ReadingGeometry.readingCreaseClearance, 16)
        XCTAssertEqual(ReadingGeometry.creaseClearance, 24, "Controls keep their own clearance")
        let controls = ReadingGeometry.frame(width: 391.5, density: .touch, creaseEdge: .leading,
                                             creaseClearance: ReadingGeometry.creaseClearance)
        XCTAssertEqual(controls.leading, 24)
    }

    func testTheOpenDuoAsOnePageHangsItsMarginAsTheMacDoes() {
        let frame = ReadingGeometry.frame(width: 867, density: .touch)
        XCTAssertTrue(frame.hangsMargin)
        XCTAssertEqual(frame.measure, 640)
    }

    func testAPageNeverHasANegativeMeasure() {
        XCTAssertEqual(ReadingGeometry.frame(width: 10, density: .touch).measure, 0)
        XCTAssertEqual(ReadingGeometry.frame(width: 0, density: .window).measure, 0)
    }

    func testASpreadSplitsAtTheCreaseOrInTheMiddleOfTwoPages() {
        XCTAssertEqual(PageSpreadLayout.split(width: 867, crease: 475.5), 475.5, "The Duo splits at its crease")
        XCTAssertEqual(PageSpreadLayout.split(width: 1200, crease: nil), 600, "A full-screen Mac column")
        XCTAssertNil(PageSpreadLayout.split(width: 1119, crease: nil), "Too narrow for two 560 pt pages")
        XCTAssertNil(PageSpreadLayout.split(width: 400, crease: 500), "A crease outside the container")
        XCTAssertEqual(PageSpreadLayout.minimumWidth, 1120)
    }

    func testFloatingNotesTakesItsLayoutFromItsSize() {
        XCTAssertEqual(SurfaceLayout.floatingNotes(size: CGSize(width: 360, height: 560)), .column)
        XCTAssertEqual(SurfaceLayout.floatingNotes(size: CGSize(width: 340, height: 228)), .compact)
        XCTAssertEqual(SurfaceLayout.floatingNotes(size: CGSize(width: 1200, height: 700)), .spread(crease: nil))
        XCTAssertTrue(SurfaceLayout.spread(crease: 475.5).isSpread)
        XCTAssertEqual(SurfaceLayout.spread(crease: 475.5).crease, 475.5)
        XCTAssertNil(SurfaceLayout.column.crease)
    }

    func testPlatformMetricsFollowTheDensity() {
        let touch = PlatformMetrics.for(.touch)
        XCTAssertEqual(touch.status, .phone)
        XCTAssertEqual(touch.chip, .phone)
        XCTAssertEqual(touch.captions, .strip)
        let panel = PlatformMetrics.for(.panel)
        XCTAssertEqual(panel.status, .mac)
        XCTAssertEqual(panel.phase, .panel)
        XCTAssertEqual(panel.meter, .panel)
        XCTAssertEqual(panel.captions, .panel)
    }

    func testNamesWrapWithoutAnOrphanAndSeparatorsStayOnTheirLine() {
        XCTAssertEqual("Vlad’s MacBook Pro (755)".wrappingAsName, "Vlad’s MacBook Pro\u{00A0}(755)")
        XCTAssertEqual("Studio Mac".wrappingAsName, "Studio Mac", "Two words wrap as they like")
        XCTAssertEqual("Connected · 80% · 2 new".keepingSeparators, "Connected\u{00A0}· 80%\u{00A0}· 2 new")
    }

    @MainActor
    func testASettingsTileDrawsTheSizeItIsGiven() {
        func side(_ tile: SettingsTile) -> CGSize {
            let host = NSHostingView(rootView: tile.environment(\.daybookDensity, .window))
            return host.fittingSize
        }
        XCTAssertEqual(side(SettingsTile(systemImage: "mic")), CGSize(width: 30, height: 30), "The row column's")
        XCTAssertEqual(side(SettingsTile(systemImage: "mic", size: .header)), CGSize(width: 56, height: 56), "A device page's header")
        XCTAssertEqual(side(SettingsTile(systemImage: "mic", size: .card)), CGSize(width: 32, height: 32))
    }

    @MainActor
    func testTheNavigatorReachesItsApp() {
        var opened: [Meeting.ID] = [], tags: [String] = [], transcripts: [(Meeting.ID, TimeInterval?)] = []
        let id = UUID()
        let navigator = ReadingNavigator(open: { opened.append($0) }, showInfo: { opened.append($0) }, search: { tags.append($0) },
                                         showTranscript: { transcripts.append(($0, $1)) })
        navigator.open(id)
        navigator.search(tag: "launch")
        navigator.showTranscript(id, at: 12)
        XCTAssertEqual(opened, [id])
        XCTAssertEqual(tags, ["launch"])
        XCTAssertEqual(transcripts.first?.0, id)
        XCTAssertEqual(transcripts.first?.1, 12)
        XCTAssertEqual(ReadingContext.platform.thisDevice, "this Mac")
        XCTAssertEqual(ReadingContext.platform.macPlace, "This Mac")
    }

    @MainActor
    func testCopyingStaysOnThisMacAndOutOfClipboardHistory() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.daybook.tests.copy.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        LocalCopy.copy("Fix the two permissions issues", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Fix the two permissions issues")
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(LocalCopy.concealedType), "Clipboard managers don't show it")
        XCTAssertTrue(types.contains(LocalCopy.transientType), "Clipboard managers don't keep it")

        LocalCopy.copy("Expires", expiresIn: .milliseconds(50), to: pasteboard)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(pasteboard.string(forType: .string), "Gone once it expires")

        LocalCopy.copy("Expires", expiresIn: .milliseconds(50), to: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Copied since", forType: .string)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied since", "An expiry never clears what came after it")
    }

    @MainActor
    func testScreenServicesCopyThroughTheirClosure() {
        var copied: [(String, Duration?)] = []
        let services = ScreenServices(presentDetails: { _, _ in }, copyLocally: { copied.append(($0, $1)) })
        services.copyLocally("Notes", expiresIn: .seconds(60))
        XCTAssertEqual(copied.first?.0, "Notes")
        XCTAssertEqual(copied.first?.1, .seconds(60))
    }
}
