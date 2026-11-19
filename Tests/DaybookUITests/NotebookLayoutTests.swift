import XCTest

@testable import DaybookUI

final class NotebookLayoutTests: XCTestCase {
    private let page = CGSize(width: 420, height: 595)

    func testBehaviorOpenDuoSpreadSplitsAtCrease() throws {
        // The open Duo: a 951 x 669 window, 84 pt of status bar on the right and 34 at the foot; the crease at 475.5.
        let size = CGSize(width: 867, height: 635)
        let layout = NotebookLayout.resolve(size: size, crease: 475.5, page: page)
        guard case .spread(let scale) = layout else { return XCTFail("two pages fit: \(layout)") }
        XCTAssertEqual(scale, 0.875, accuracy: 0.002, "the right page, 367.5 pt of room, sets the scale")
        let frames = layout.frames(in: size, crease: 475.5, page: page)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].width, 367.5, accuracy: 0.5)
        XCTAssertEqual(frames[0].height, 520.6, accuracy: 0.5)
        XCTAssertLessThanOrEqual(frames[0].maxX, 475.5 - NotebookLayout.creaseClearance + 0.01, "the left page stops clear of the crease")
        XCTAssertGreaterThanOrEqual(frames[1].minX, 475.5 + NotebookLayout.creaseClearance - 0.01, "the right page starts clear of it")
        XCTAssertLessThanOrEqual(frames[1].maxX, size.width - NotebookLayout.margin + 0.01, "and clear of the status area at the far right")
        XCTAssertEqual(frames[0].midY, size.height / 2, accuracy: 0.01, "centred, with nothing reserved above or below")
        XCTAssertTrue(layout.hasStrip(under: frames[0], in: size), "57 pt under the page for its number and the caption")
    }

    func testBehaviorDuoCoverIsSinglePage() {
        let size = CGSize(width: 382, height: 644)
        let layout = NotebookLayout.resolve(size: size, crease: nil, page: page)
        guard case .single(let scale) = layout else { return XCTFail("one page: \(layout)") }
        XCTAssertEqual(scale, 0.871, accuracy: 0.002, "the width sets it")
        let frames = layout.frames(in: size, crease: nil, page: page)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].midX, size.width / 2, accuracy: 0.01)
        XCTAssertTrue(layout.hasStrip(under: frames[0], in: size))
    }

    func testBehaviorWideDisplayWithoutCreaseIsSpread() {
        let size = CGSize(width: 1180, height: 800)
        let layout = NotebookLayout.resolve(size: size, crease: nil, page: page)
        XCTAssertTrue(layout.isSpread)
        XCTAssertGreaterThan(layout.scale, 1, "a page may be drawn larger than it's made: strokes are vectors")
        let frames = layout.frames(in: size, crease: nil, page: page)
        XCTAssertEqual(frames[1].minX - frames[0].maxX, NotebookLayout.gutter, accuracy: 0.01)
        XCTAssertEqual(frames[0].minX, size.width - frames[1].maxX, accuracy: 0.01, "the pair is centred")
    }

    func testBehaviorTooNarrowForSpreadIsSingle() {
        // A crease with a right page that would have to scale under 0.7.
        XCTAssertFalse(NotebookLayout.resolve(size: CGSize(width: 700, height: 800), crease: 300, page: page).isSpread)
        XCTAssertFalse(NotebookLayout.resolve(size: CGSize(width: 500, height: 800), crease: nil, page: page).isSpread)
    }

    func testBehaviorBothPagesShareScale() {
        let size = CGSize(width: 867, height: 635)
        let frames = NotebookLayout.resolve(size: size, crease: 475.5, page: page).frames(in: size, crease: 475.5, page: page)
        XCTAssertEqual(frames[0].size, frames[1].size)
    }

    func testBehaviorNoStripWhereThePageFillsTheHeight() {
        let size = CGSize(width: 1000, height: 420)
        let layout = NotebookLayout.resolve(size: size, crease: nil, page: page)
        let frame = layout.frames(in: size, crease: nil, page: page)[0]
        XCTAssertFalse(layout.hasStrip(under: frame, in: size), "the number goes in the pill and the caption floats")
    }

    func testBehaviorPillDropsMeterThenWrapsPageControls() {
        // Room for the whole row, then without the meter (the open Duo's right page and the cover), then two rows.
        XCTAssertEqual(NotebookPillFit.resolve(available: 400), .oneRow(meter: true))
        XCTAssertEqual(NotebookPillFit.resolve(available: 351), .oneRow(meter: false))
        XCTAssertEqual(NotebookPillFit.resolve(available: 300), .twoRows)
        XCTAssertEqual(NotebookPillFit.resolve(available: 351, textScale: 1.3), .twoRows, "larger text needs the second row")
    }

    func testBehaviorControlsStepAsideForAPenNearThem() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 50)
        XCTAssertTrue(PenProximity.isNear(CGPoint(x: 150, y: 120), frame), "on it")
        XCTAssertTrue(PenProximity.isNear(CGPoint(x: 150, y: 185), frame), "within 40 pt")
        XCTAssertFalse(PenProximity.isNear(CGPoint(x: 150, y: 200), frame), "further")
        XCTAssertFalse(PenProximity.isNear(nil, frame), "a lifted pen is near nothing, and the control comes back")
    }
}
