import DaybookCore
import Foundation
import XCTest

/// Bytes as hex one way everywhere, and back.
final class HexTests: XCTestCase {
    func testBehaviorBytesSpellTwoLowercaseDigitsEach() {
        XCTAssertEqual([UInt8]([0x00, 0x0f, 0xa5, 0xff]).lowercaseHex, "000fa5ff")
        XCTAssertEqual(Data().lowercaseHex, "")
        XCTAssertEqual(Data("Daybook".utf8).lowercaseHex, Data("Daybook".utf8).map { String(format: "%02x", $0) }.joined(),
                       "the same text the modules wrote before")
    }

    func testBehaviorHexReadsBackInEitherCase() {
        XCTAssertEqual(Data(hex: "000fA5Ff"), Data([0x00, 0x0f, 0xa5, 0xff]))
        XCTAssertEqual(Data(hex: ""), Data())
        let random = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        XCTAssertEqual(Data(hex: random.lowercaseHex), random)
    }

    func testBehaviorAnythingButPairsOfDigitsIsRefused() {
        XCTAssertNil(Data(hex: "abc"), "an odd count")
        XCTAssertNil(Data(hex: "0x00"))
        XCTAssertNil(Data(hex: "zz"))
        XCTAssertNil(Data(hex: "00 ff"))
    }
}
