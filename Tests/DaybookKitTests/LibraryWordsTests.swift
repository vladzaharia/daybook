@testable import DaybookCore
import DaybookKit
import XCTest

/// Sentences the Mac and the iPhone share, so the same dialog reads the same on both.
final class LibraryWordsTests: XCTestCase {
    func testFolderDeletionSaysWhatHappensToWhatsInIt() {
        XCTAssertEqual(LibraryWords.folderDeletion(conversations: 0), "The folder is empty.")
        XCTAssertEqual(LibraryWords.folderDeletion(conversations: 1), "The conversation in it stays in your library.")
        XCTAssertEqual(LibraryWords.folderDeletion(conversations: 4), "The 4 conversations in it stay in your library.")
    }

    func testTheEncryptionStatusSaysHowMuchIsLeftAndWhatItWaitsFor() {
        var progress = SealerProgress()
        let summary = SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: false, isMigrator: true, progress: progress)
        XCTAssertEqual(LibraryWords.encryptionStatus(summary), "On")
        progress.remaining = 12
        XCTAssertEqual(LibraryWords.encryptionStatus(SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: false, isMigrator: true,
                                                                    progress: progress)), "Encrypting · 12 left")
        progress.waitsForWiFi = true
        XCTAssertEqual(LibraryWords.encryptionStatus(SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: false, isMigrator: true,
                                                                    progress: progress)), "Encrypting · 12 left · Waiting for Wi‑Fi")
        // Only the device sealing the history says how far it's got, and offers cellular (Use Cellular Data).
        XCTAssertEqual(LibraryWords.encryptionStatus(SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: false, isMigrator: false,
                                                                    progress: progress)), "On")
        XCTAssertTrue(LibraryWords.encryptsHere(SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: false, isMigrator: true, progress: progress)))
        XCTAssertFalse(LibraryWords.encryptsHere(SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: false, isMigrator: false, progress: progress)))
        XCTAssertFalse(LibraryWords.encryptsHere(summary), "nothing left to encrypt")
    }

    func testANetworkSuitsLargeDownloadsOnlyOnWiFiOutsideLowDataMode() {
        XCTAssertEqual(SyncNetworkCondition(satisfied: true, expensive: false, constrained: false), .unrestricted)
        XCTAssertEqual(SyncNetworkCondition(satisfied: true, expensive: true, constrained: false), .restricted, "cellular, or a hotspot")
        XCTAssertEqual(SyncNetworkCondition(satisfied: true, expensive: false, constrained: true), .restricted, "Low Data Mode")
        XCTAssertEqual(SyncNetworkCondition(satisfied: false, expensive: false, constrained: false), .restricted, "offline")
        XCTAssertEqual(SyncReplicaConfiguration().network(), .unrestricted, "a Mac never waits")
        XCTAssertEqual(SyncNetworkCondition.restricted.allowing(cellular: true), .unrestricted, "cellular allowed, as for model downloads")
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
