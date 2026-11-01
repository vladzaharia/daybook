import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// What an empty place and Move to Trash's question say, the same on both apps.
final class LibraryPlaceWordsTests: XCTestCase {
    func testBehaviorAnEmptyPlaceSaysNoConversationsAndAFolderHowToFillIt() {
        XCTAssertEqual(LibraryWords.emptyPlace(.section(.work), libraryIsEmpty: false, platform: .mac),
                       LibraryWords.EmptyPlace(title: "No Conversations", symbol: "briefcase"))
        XCTAssertEqual(LibraryWords.emptyPlace(.section(.personal), libraryIsEmpty: false, platform: .iPhone),
                       LibraryWords.EmptyPlace(title: "No Conversations", symbol: "house"))
        XCTAssertEqual(LibraryWords.emptyPlace(.folder(UUID()), libraryIsEmpty: false, platform: .mac)?.description,
                       "Drag conversations here, or choose Move to Folder.")
        XCTAssertEqual(LibraryWords.emptyPlace(.folder(UUID()), libraryIsEmpty: false, platform: .iPhone)?.description,
                       "Choose Move to Folder… on a conversation.", "an iPhone has no drag")
        XCTAssertEqual(LibraryWords.emptyPlace(.folder(UUID()), libraryIsEmpty: true, platform: .iPhone)?.title, "No Conversations")
        XCTAssertNil(LibraryWords.emptyPlace(.device("sc"), libraryIsEmpty: false, platform: .mac), "a recorder's page lists recordings")
    }

    func testBehaviorAnEmptyLibrarySaysSoOnce() {
        XCTAssertNil(LibraryWords.emptyPlace(.section(.all), libraryIsEmpty: true, platform: .mac), "the Mac's page says it")
        XCTAssertEqual(LibraryWords.emptyPlace(.section(.all), libraryIsEmpty: true, platform: .iPhone),
                       LibraryWords.EmptyPlace(title: "No Conversations Yet", symbol: "waveform", showsMark: true))
        XCTAssertEqual(LibraryWords.emptyPlace(.section(.all), libraryIsEmpty: false, platform: .iPhone)?.title, "No Conversations")
    }

    func testBehaviorMoveToTrashAsksAboutWhatItMoves() {
        XCTAssertEqual(LibraryWords.trashTitle([Meeting(title: "Weekly sync")]), "Move “Weekly sync” to the Trash?")
        XCTAssertEqual(LibraryWords.trashTitle([Meeting(title: "A"), Meeting(title: "B"), Meeting(title: "C")]),
                       "Move 3 conversations to the Trash?")
        XCTAssertEqual(LibraryWords.trashTitle([Meeting(title: "  ")]), "Move this conversation to the Trash?", "never empty quotes")
        XCTAssertEqual(LibraryWords.trashTitle([]), "Move this conversation to the Trash?")
    }
}
