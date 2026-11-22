import DaybookDesign
@testable import DaybookUI
import XCTest

final class RecorderTileColumnsTests: XCTestCase {
    func testActionTilesFallToTheFiguresColumnsAtTheSameWidths() {
        let spacing = DaybookSpacing.s2
        let minimum = RecorderFigures.minimumTile
        func columns(_ width: CGFloat) -> Int { RecorderTileColumns.columns(width: width, spacing: spacing, minimumTile: minimum) }
        XCTAssertEqual(columns(525), 3, "A window's measure: one tile is one figure wide")
        XCTAssertEqual(columns(3 * minimum + 2 * spacing), 3)
        XCTAssertEqual(columns(3 * minimum + 2 * spacing - 1), 2)
        XCTAssertEqual(columns(2 * minimum + spacing), 2)
        XCTAssertEqual(columns(2 * minimum + spacing - 1), 1)
        XCTAssertEqual(columns(100), 1)
    }
}
