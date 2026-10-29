@testable import DaybookCore
import DaybookKit
import XCTest
@testable import Daybook

/// Settings › Library › iCloud Sync: one row says where sync stands, without repeating the problem line under it.
final class SyncSettingsWordsTests: XCTestCase {
    private func connected(_ change: (inout SyncShown) -> Void = { _ in }) -> SyncShown {
        var shown = SyncShown(iCloud: .connected)
        shown.folder = URL(fileURLWithPath: "/tmp/sync")
        change(&shown)
        return shown
    }

    func testTheRowSaysWhereSyncStandsInEveryState() {
        XCTAssertEqual(SyncShown(iCloud: .checking).headline, "Checking…")
        XCTAssertEqual(SyncShown(iCloud: .turnedOff).headline, "Off")
        XCTAssertEqual(SyncShown(iCloud: .signedOut).headline, "Signed out")
        XCTAssertEqual(SyncShown(iCloud: .iCloudDriveOff).headline, "iCloud Drive is off")
        XCTAssertEqual(SyncShown(iCloud: .accountChanged).headline, "Paused")
        XCTAssertEqual(SyncShown(iCloud: .previousFolderMissing).headline, "Paused")
        XCTAssertEqual(SyncShown(iCloud: .containerUnavailable("CKErrorDomain 4")).headline, "Not available right now")
        XCTAssertEqual(SyncShown(iCloud: .unavailableInThisBuild).headline, "Not available in this build")
        XCTAssertEqual(SyncShown(iCloud: .waitingForKey).headline, "Waiting for this library’s key")
        var progress = SyncMigrationProgress()
        XCTAssertEqual(SyncShown(iCloud: .migrating(progress)).headline, "Moving to iCloud…")
        progress.total = 412; progress.completed = 157
        XCTAssertEqual(SyncShown(iCloud: .migrating(progress)).headline, "Moving to iCloud · 157 of 412 files")
    }

    func testConnectedSaysWhenItWasLastUpToDate() {
        XCTAssertEqual(connected().headline, "Waiting to sync")
        XCTAssertEqual(connected { $0.isSyncing = true }.headline, "Syncing…")
        XCTAssertEqual(connected { $0.pendingDownloads = 1 }.headline, "Waiting for iCloud to download 1 item…")
        XCTAssertEqual(connected { $0.pendingDownloads = 3 }.headline, "Waiting for iCloud to download 3 items…")
        let now = Date()
        let time = now.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(connected { $0.lastSync = now }.headline, "Up to date · \(time)")
    }

    func testAProblemIsSaidOnceUnderTheRowWhichKeepsOnlyTheLastSync() {
        let now = Date()
        let paused = connected { $0.lastSync = now; $0.status = "Sync paused: No space left on device." }
        XCTAssertEqual(paused.problem?.text, "Sync is paused.")
        XCTAssertEqual(paused.problem?.details, "No space left on device.")
        XCTAssertEqual(paused.headline, "Last synced \(now.formatted(date: .omitted, time: .shortened))")
        XCTAssertFalse(paused.headline.localizedCaseInsensitiveContains("sync is paused"))
        XCTAssertEqual(connected { $0.status = "Couldn’t open iCloud: not signed in" }.headline, "Not synced yet")
        XCTAssertNil(connected { $0.status = "Connected · preparing sync" }.problem)
    }

    func testOnlyICloudDriveOffNeedsAFooterAndOnlyASyncingLibraryCanBeTurnedOff() {
        XCTAssertEqual(SyncShown(iCloud: .iCloudDriveOff).footer, "Turn it on in System Settings › Apple Account › iCloud.")
        XCTAssertNil(SyncShown(iCloud: .signedOut).footer)
        XCTAssertNil(connected().footer)
        XCTAssertTrue(connected().isConnected)
        XCTAssertFalse(SyncShown(iCloud: .waitingForKey).isConnected)
        XCTAssertFalse(SyncShown(iCloud: .turnedOff).isConnected)
        var folder = SyncShown(iCloud: .unavailableInThisBuild)
        folder.isFolderTransport = true
        XCTAssertFalse(folder.isConnected)
        folder.folder = URL(fileURLWithPath: "/tmp/sync")
        XCTAssertTrue(folder.isConnected)
    }

    func testTheBusyIndicatorFollowsWorkInProgress() {
        XCTAssertTrue(SyncShown(iCloud: .checking).isBusy)
        XCTAssertTrue(SyncShown(iCloud: .migrating(SyncMigrationProgress())).isBusy)
        XCTAssertFalse(connected().isBusy)
        XCTAssertTrue(connected { $0.isSyncing = true }.isBusy)
        XCTAssertFalse(SyncShown(iCloud: .turnedOff).isBusy)
    }

    func testEncryptionIsShownFromTheControllersState() {
        XCTAssertEqual(EncryptionShown(.unavailable), .unavailable)
        XCTAssertEqual(EncryptionShown(.off), .off)
        XCTAssertEqual(EncryptionShown(.waitingForKey), .waitingForKey)
        let saved = SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: true, isMigrator: false, progress: nil)
        XCTAssertEqual(EncryptionShown(.on(saved)), .on(status: "On", hasRecoveryKey: true))
        var progress = SealerProgress()
        progress.remaining = 12
        let sealing = SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: false, isMigrator: true, progress: progress)
        XCTAssertEqual(EncryptionShown(.on(sealing)), .on(status: "Encrypting · 12 left", hasRecoveryKey: false))
        XCTAssertTrue(EncryptionShown(.on(saved)).isOn)
        XCTAssertFalse(EncryptionShown.off.isOn)
    }

    func testRemainingMigrationIsSaidOnlyWhileFilesAreStillComing() {
        var record = SyncMigrationRecord(sourcePath: "/tmp/old", container: "iCloud.local.daybook")
        XCTAssertNil(connected { $0.migration = record }.remainingMigration)
        record.switchedAt = Date(); record.remainingFiles = 1
        XCTAssertEqual(connected { $0.migration = record }.remainingMigration, "Copying 1 more file from the previous sync folder")
        record.remainingFiles = 4
        XCTAssertEqual(connected { $0.migration = record }.remainingMigration, "Copying 4 more files from the previous sync folder")
        record.abandoned = true
        XCTAssertNil(connected { $0.migration = record }.remainingMigration)
    }
}
