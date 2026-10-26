import DaybookKit
import XCTest

/// Sentences the Mac and the iPhone share, so the same dialog reads the same on both.
final class LibraryWordsTests: XCTestCase {
    func testFolderDeletionSaysWhatHappensToWhatsInIt() {
        XCTAssertEqual(LibraryWords.folderDeletion(conversations: 0), "The folder is empty.")
        XCTAssertEqual(LibraryWords.folderDeletion(conversations: 1), "The conversation in it stays in your library.")
        XCTAssertEqual(LibraryWords.folderDeletion(conversations: 4), "The 4 conversations in it stay in your library.")
    }
}
