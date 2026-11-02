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

    func testBehaviorTheListSaysSyncHasStoppedInSettingsWordsOnlyWhenItNeedsThePerson() {
        XCTAssertEqual(LibraryWords.syncAttention(.storageFull, hasSynced: true), "iCloud storage is full.")
        XCTAssertEqual(LibraryWords.syncAttention(.failure(details: "The network went away"), hasSynced: true), "Sync is paused.")
        XCTAssertEqual(LibraryWords.syncAttention(.waitingForKey, hasSynced: false), "Waiting for this library’s key.")
        XCTAssertEqual(LibraryWords.syncAttention(.signedOut, hasSynced: true), "Signed out of iCloud.")
        XCTAssertNil(LibraryWords.syncAttention(.signedOut, hasSynced: false), "a Mac that never synced isn't told in its list")
        for working in [SyncStatus.off, .unavailableInThisBuild, .syncing, .upToDate(at: Date()), .keyStoreUnreadable, .connecting] {
            XCTAssertNil(LibraryWords.syncAttention(working, hasSynced: true), "\(working)")
        }
        XCTAssertEqual(LibraryWords.notSyncing, "Not syncing")
    }

    func testBehaviorAnEmptyLibrarySaysItsConversationsAreComingUntilThisInstallsFirstPassEnds() {
        func getting(empty: Bool = true, checking: Bool = false, connected: Bool = true, lastSync: Date? = nil, more: Bool = false) -> Bool {
            LibraryWords.isGettingConversations(libraryIsEmpty: empty, checking: checking, connected: connected, lastSync: lastSync, hasMoreWork: more)
        }
        XCTAssertTrue(getting(), "connected, no pass finished yet")
        XCTAssertFalse(getting(connected: false), "sync off or unavailable: the library is just empty")
        XCTAssertTrue(getting(checking: true, connected: false), "still looking for the library")
        XCTAssertTrue(getting(lastSync: Date(), more: true), "the first pass stopped with more to bring")
        XCTAssertFalse(getting(lastSync: Date()), "a pass finished and brought nothing: it's empty")
        XCTAssertFalse(getting(empty: false), "conversations are here")
        XCTAssertEqual(LibraryWords.gettingConversations, "Getting your conversations…")
    }

    func testBehaviorRestoreSaysWhatCameBack() {
        XCTAssertEqual(LibraryWords.restored(Meeting(title: "Old standup")), "Restored “Old standup”.")
        XCTAssertEqual(LibraryWords.restored(Meeting(title: " ")), "Restored a conversation.")
        XCTAssertEqual(LibraryWords.trash, "Trash")
        XCTAssertEqual(LibraryWords.searchPrompt, "Titles, notes, transcripts")
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
