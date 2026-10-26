import DaybookCore
import DaybookKit
import XCTest

/// Sentences the Mac and the iPhone share, so the same dialog reads the same on both.
final class LibraryWordsTests: XCTestCase {
    func testFolderDeletionSaysWhatHappensToWhatsInIt() {
        XCTAssertEqual(LibraryWords.folderDeletion(conversations: 0), "The folder is empty.")
        XCTAssertEqual(LibraryWords.folderDeletion(conversations: 1), "The conversation in it stays in your library.")
        XCTAssertEqual(LibraryWords.folderDeletion(conversations: 4), "The 4 conversations in it stay in your library.")
    }

    func testAPhotoIsReadWithItsTimeAndCaptionNotItsFileName() {
        var meeting = Meeting(title: "Design review")
        let untimed = MeetingPhoto(relativePath: "Originals/Photos/a.heic", fileName: "Photo.heic", sha256: "", capturedAt: Date())
        meeting.photos = [untimed]
        XCTAssertEqual(meeting.photoAccessibilityLabel(untimed), "Photo", "never the file name")
        let captioned = MeetingPhoto(relativePath: "Originals/Photos/b.jpg", fileName: "IMG_0412.jpg", sha256: "", capturedAt: Date(),
                                     caption: "Whiteboard")
        XCTAssertEqual(meeting.photoAccessibilityLabel(captioned), "Photo: Whiteboard")
    }
}
