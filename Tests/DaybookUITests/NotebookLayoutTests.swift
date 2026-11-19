import XCTest

@testable import DaybookUI

final class NotebookLayoutTests: XCTestCase {
    private let page = CGSize(width: 420, height: 595)

    func testBehaviorOpenDuoSpreadSplitsAtCrease() throws {
        // The open Duo: a 951 x 669 window, 84 pt of status bar on the right and 34 at the foot; the crease at 475.5.
        let size = CGSize(width: 867, height: 635)
        let layout = NotebookLayout.resolve(size: size, crease: 475.5, page: page)
        guard case .spread(let scale) = layout else { return XCTFail("two pages fit: \(layout)") }
        XCTAssertEqual(scale, 0.865, accuracy: 0.002)
        let frames = layout.frames(in: size, crease: 475.5, page: page)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].width, 363.3, accuracy: 0.5)
        XCTAssertEqual(frames[0].height, 514.7, accuracy: 0.5)
        XCTAssertLessThanOrEqual(frames[0].maxX, 475.5 - NotebookLayout.creaseClearance + 0.01, "the left page stops clear of the crease")
        XCTAssertGreaterThanOrEqual(frames[1].minX, 475.5 + NotebookLayout.creaseClearance - 0.01, "the right page starts clear of it")
        XCTAssertLessThanOrEqual(frames[1].maxX, size.width - NotebookLayout.margin + 0.01)
        XCTAssertGreaterThanOrEqual(frames[0].minY, NotebookLayout.band, "under the band, where the pill is")
    }

    func testBehaviorDuoCoverIsSinglePage() {
        let layout = NotebookLayout.resolve(size: CGSize(width: 382, height: 644), crease: nil, page: page)
        guard case .single(let scale) = layout else { return XCTFail("one page: \(layout)") }
        XCTAssertEqual(scale, 0.807, accuracy: 0.01, "the foot is kept for the tools")
        XCTAssertEqual(layout.frames(in: CGSize(width: 382, height: 644), crease: nil, page: page).count, 1)
    }

    func testBehaviorWideDisplayWithoutCreaseIsSpread() {
        let size = CGSize(width: 1180, height: 800)
        let layout = NotebookLayout.resolve(size: size, crease: nil, page: page)
        XCTAssertTrue(layout.isSpread)
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
}
