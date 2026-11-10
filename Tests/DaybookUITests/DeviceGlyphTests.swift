import DaybookDesign
import XCTest
@testable import DaybookUI

/// A recorder's glyph, one tile on both apps (`DeviceGlyph`): teal only while the recorder is linked.
final class DeviceGlyphTests: XCTestCase {
    func testBehaviorTheTileIsTealOnlyWhileTheRecorderIsLinked() {
        XCTAssertEqual(DeviceGlyph.tone(linked: true), .active)
        XCTAssertEqual(DeviceGlyph.tone(linked: false), .neutral)
    }
}
