import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// An export's file name is the same on both apps and always one a volume, Files, and Mail take: no separators or
/// refused characters, no hidden file, and short enough for what an export adds to it.
final class MeetingExportFileNameTests: XCTestCase {
    func testBehaviorRefusedCharactersBecomeDashes() {
        XCTAssertEqual(MeetingExport.fileName(for: "Q3: plan / budget?"), "Q3- plan - budget-")
        XCTAssertEqual(MeetingExport.fileName(for: "a\\b*c|d\"e<f>g%h"), "a-b-c-d-e-f-g-h")
        XCTAssertEqual(MeetingExport.fileName(for: "Line one\nLine two\tthree"), "Line one-Line two-three", "never multi-line")
    }

    func testBehaviorANameIsNeverHiddenOrEmpty() {
        XCTAssertEqual(MeetingExport.fileName(for: ".hidden notes"), "hidden notes")
        XCTAssertEqual(MeetingExport.fileName(for: "  Retro...  "), "Retro")
        XCTAssertEqual(MeetingExport.fileName(for: ""), "Conversation")
        XCTAssertEqual(MeetingExport.fileName(for: " .. "), "Conversation")
        XCTAssertEqual(MeetingExport.fileName(for: Meeting(title: "Weekly product sync")), "Weekly product sync")
    }

    func testBehaviorALongTitleIsCutOnACharacterBoundaryWithRoomForSuffixes() throws {
        let long = String(repeating: "Quarterly planning with finance and design ", count: 10)
        let name = MeetingExport.fileName(for: long)
        XCTAssertLessThanOrEqual(name.utf8.count, MeetingExport.fileNameBytes)
        XCTAssertTrue(long.hasPrefix(name))
        XCTAssertFalse(name.hasSuffix(" "))
        XCTAssertLessThanOrEqual((name + " 12 Photos").utf8.count, 255)

        // Four-byte characters: 120 of them were under the old 120-character cap but over 255 bytes.
        let emoji = String(repeating: "🎙️", count: 120)
        let cut = MeetingExport.fileName(for: emoji)
        XCTAssertLessThanOrEqual(cut.utf8.count, MeetingExport.fileNameBytes)
        XCTAssertTrue(emoji.hasPrefix(cut), "whole characters only")
        XCTAssertFalse(cut.isEmpty)
        let accented = String(repeating: "é", count: 300)
        XCTAssertEqual(MeetingExport.fileName(for: accented, maxBytes: 9).unicodeScalars.count, 4)
        // A name that fits is untouched.
        XCTAssertEqual(MeetingExport.fileName(for: "Standup", maxBytes: 7), "Standup")
    }
}
