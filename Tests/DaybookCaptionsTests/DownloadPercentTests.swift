import XCTest
@testable import DaybookCaptions

/// A captions download is told as it moves, once per whole percent, however often its progress reports.
final class DownloadPercentTests: XCTestCase {
    func testBehaviorProgressIsToldOncePerWholePercent() {
        let told = DownloadPercent()
        XCTAssertTrue(told.changed(to: 0))
        XCTAssertFalse(told.changed(to: 0.004), "still 0%")
        XCTAssertTrue(told.changed(to: 0.011))
        XCTAssertFalse(told.changed(to: 0.019), "still 1%")
        XCTAssertTrue(told.changed(to: 0.5))
        XCTAssertTrue(told.changed(to: 1.2), "past the end reads as 100%")
        XCTAssertFalse(told.changed(to: 1))
    }
}
