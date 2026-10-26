import DaybookKit
import XCTest

/// Times on a conversation's timeline, as both apps show and speak them. A note an iPhone took before the Mac started
/// recording has a time before the start: shown "−0:12", spoken "12 seconds before the start".
final class TimeWordsTests: XCTestCase {
    func testATimeBeforeTheStartIsSpokenAsBeforeIt() {
        XCTAssertEqual(SpokenTime.format(-12), "12 seconds before the start")
        XCTAssertEqual(SpokenTime.format(-75), "1 minute, 15 seconds before the start")
        XCTAssertEqual(TimeLabel.short(-12), "−0:12")
        XCTAssertEqual(TimeLabel.short(-75), "−1:15")
        // Never "0 seconds" for a time that isn't the start.
        XCTAssertNotEqual(SpokenTime.format(-3), SpokenTime.format(0))
    }

    func testWhatsSpokenMatchesWhatsShown() {
        // Whole seconds toward zero, either side of the start.
        XCTAssertEqual(TimeLabel.short(12.9), "0:12"); XCTAssertEqual(SpokenTime.format(12.9), SpokenTime.format(12))
        XCTAssertEqual(TimeLabel.short(-12.9), "−0:12"); XCTAssertEqual(SpokenTime.format(-12.9), "12 seconds before the start")
        XCTAssertEqual(SpokenTime.format(751), "12 minutes, 31 seconds")
        // Less than a second before the start is the start: no minus sign on "0:00".
        XCTAssertEqual(TimeLabel.short(-0.4), "0:00"); XCTAssertEqual(TimeLabel.format(-0.4), "00:00")
        XCTAssertEqual(SpokenTime.format(-0.4), SpokenTime.format(0))
        XCTAssertEqual(SpokenTime.format(.nan), SpokenTime.format(0))
        XCTAssertEqual(TimeLabel.format(-15), "−00:15")
    }
}
