@testable import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// Settings' iCloud Sync, the same on the Mac and the iPhone: one row says where sync stands without repeating the
/// problem line under it, each problem comes with its fix, and the library's devices and encryption read the same.
@MainActor
final class ICloudSyncShownTests: XCTestCase {
    private func connected(_ change: (inout ICloudSyncShown) -> Void = { _ in }) -> ICloudSyncShown {
        var shown = ICloudSyncShown(iCloud: .connected)
        shown.folder = URL(fileURLWithPath: "/tmp/sync")
        change(&shown)
        return shown
    }

    func testBehaviorTheRowSaysWhereSyncStandsInEveryState() {
        XCTAssertEqual(ICloudSyncShown(iCloud: .checking).line, "Checking…")
        XCTAssertEqual(ICloudSyncShown(iCloud: .turnedOff).line, "Off")
        XCTAssertEqual(ICloudSyncShown(iCloud: .signedOut).line, "Signed out")
        XCTAssertEqual(ICloudSyncShown(iCloud: .iCloudDriveOff).line, "iCloud Drive is off")
        XCTAssertEqual(ICloudSyncShown(iCloud: .accountChanged).line, "Sync paused")
        XCTAssertEqual(ICloudSyncShown(iCloud: .previousFolderMissing).line, "Sync paused")
        XCTAssertEqual(ICloudSyncShown(iCloud: .containerUnavailable("CKErrorDomain 4")).line, "Not available right now")
        XCTAssertEqual(ICloudSyncShown(iCloud: .unavailableInThisBuild).line, "Not available in this build")
        XCTAssertEqual(ICloudSyncShown(iCloud: .waitingForKey).line, "Waiting for this library’s key")
        var progress = SyncMigrationProgress()
        XCTAssertEqual(ICloudSyncShown(iCloud: .migrating(progress)).line, "Moving to iCloud…")
        progress.total = 412; progress.completed = 157
        XCTAssertEqual(ICloudSyncShown(iCloud: .migrating(progress)).headline(), "Moving to iCloud · 157 of 412 files")
    }

    func testBehaviorConnectedSaysWhatMovesWhatWaitsOrWhenItWasUpToDate() {
        XCTAssertEqual(connected().headline(), "Waiting to sync")
        XCTAssertEqual(connected { $0.isSyncing = true }.headline(), "Syncing…")
        XCTAssertEqual(connected { $0.isSyncing = true; $0.changesInFlight = 3 }.line, "Syncing 3 changes")
        XCTAssertEqual(connected { $0.pendingDownloads = 1 }.headline(), "Waiting for iCloud to download 1 item…")
        XCTAssertEqual(connected { $0.pendingDownloads = 3 }.headline(), "Waiting for iCloud to download 3 items…")
        XCTAssertEqual(connected { $0.pendingUploads = 2; $0.lastSync = Date() }.line, "Uploading 2 items to iCloud",
                       "Up to date needs nothing waiting to upload")
        XCTAssertEqual(connected { $0.localChanges = 1; $0.lastSync = Date() }.line, "1 change waiting to sync")
        XCTAssertEqual(connected { $0.localChanges = 2; $0.lastSync = Date() }.line, "2 changes waiting to sync")
        XCTAssertEqual(connected { $0.courierWaiting = 3; $0.lastSync = Date() }.line, "Waiting to send 3 items to your Mac")
        XCTAssertEqual(connected { $0.hasMoreWork = true; $0.lastSync = Date() }.line, "Syncing… more to come")
        let now = Date()
        let time = now.formatted(date: .omitted, time: .shortened)
        let upToDate = connected { $0.lastSync = now }
        XCTAssertEqual(upToDate.line, "Up to date", "The Settings row and the status sheet say it without the time")
        XCTAssertEqual(upToDate.headline(now: now), "Up to date · \(time)")
        XCTAssertTrue(upToDate.isUpToDate)
        XCTAssertFalse(connected { $0.lastSync = now; $0.pendingUploads = 1 }.isUpToDate)
        XCTAssertEqual(connected { $0.lastSync = now; $0.encryption = .waitingForKey }.headline(now: now), "Waiting for this library’s key")
    }

    func testBehaviorAProblemIsSaidOnceUnderTheRowWhichKeepsOnlyTheLastSync() {
        let now = Date()
        let paused = connected { $0.lastSync = now; $0.problem = SyncStatus.failure(details: "No space left on device.").problem }
        XCTAssertEqual(paused.problem?.text, "Sync is paused.")
        XCTAssertEqual(paused.problem?.details, "No space left on device.")
        XCTAssertEqual(paused.line, "Sync paused")
        XCTAssertEqual(paused.headline(now: now), "Last synced \(now.formatted(date: .omitted, time: .shortened))")
        XCTAssertFalse(paused.headline(now: now).localizedCaseInsensitiveContains("sync is paused"))
        XCTAssertEqual(connected { $0.problem = .iCloudUnavailable(details: "not signed in") }.headline(), "Not synced yet")
        XCTAssertTrue(paused.needsAttention)
        XCTAssertEqual(paused.symbol, "exclamationmark.icloud")
        // iCloud being full is said as such, before what waits to upload, which can't go until there's room.
        let full = connected { $0.lastSync = now; $0.pendingUploads = 2; $0.problem = .storageFull }
        XCTAssertEqual(full.line, "iCloud storage is full")
        XCTAssertEqual(full.problem?.text, "iCloud storage is full.")
        XCTAssertFalse(full.isUpToDate)
    }

    func testBehaviorAChangedAccountPausesWithItsOneFixOnBothApps() {
        let changed = ICloudSyncShown(iCloud: .accountChanged)
        XCTAssertEqual(changed.line, "Sync paused")
        XCTAssertTrue(changed.needsAttention)
        XCTAssertEqual(changed.symbol, "exclamationmark.icloud")
        XCTAssertFalse(changed.isAttached, "Nothing to encrypt or list until the person chooses")
        XCTAssertEqual(SyncProblem.accountChanged.text, "This library synced with a different iCloud account.")
        XCTAssertEqual(ICloudSyncConfirmation.useAccount.action, "Sync with This Account")
        XCTAssertEqual(ICloudSyncConfirmation.useAccount.title, "Sync with this iCloud account?")
        XCTAssertEqual(ICloudSyncConfirmation.useAccount.message, "Its conversations are added to the iCloud account you’re signed in to.")
        XCTAssertEqual(ICloudSyncConfirmation.useAccount.confirm, "Sync")
        XCTAssertFalse(ICloudSyncConfirmation.useAccount.isDestructive)
    }

    func testBehaviorARemovedLibraryOffersANewOneOnlyWhereTheAppCanStartIt() {
        let removed = connected { $0.problem = .libraryRemoved; $0.encryption = .on(status: "On", hasRecoveryKey: true, encryptsHere: false) }
        XCTAssertTrue(removed.isLibraryRemoved, "nothing to encrypt or erase there")
        XCTAssertFalse(removed.offersNewLibrary(canStart: false), "nothing offered without the action")
        XCTAssertTrue(removed.offersNewLibrary(canStart: true))
        XCTAssertEqual(ICloudSyncShown.startNewLibraryTitle, "Start a New Library in iCloud")
        let paused = connected { $0.problem = .failure(details: "x") }
        XCTAssertFalse(paused.offersNewLibrary(canStart: true), "only for a library that was removed")
    }

    func testBehaviorTheOlderAppSyncingBesideThisOneIsSaidWithWhatToDo() {
        let warned = connected { $0.lastSync = Date(); $0.otherInstallation = true }
        XCTAssertTrue(warned.needsAttention)
        XCTAssertEqual(warned.line, "Up to date", "Sync carries on")
        XCTAssertEqual(ICloudSyncShown.otherInstallationLine, "Daybook is also installed as an older app on this Mac. Delete the older app.")
        XCTAssertFalse(connected { $0.lastSync = Date() }.needsAttention)
    }

    func testBehaviorAMoveToICloudThatStoppedSaysSoInsteadOfSpinning() {
        var progress = SyncMigrationProgress()
        var paused = ICloudSyncShown(iCloud: .migrating(progress))
        paused.problem = SyncStatus.migrationPaused(details: "No space left on device.").problem
        XCTAssertEqual(paused.problem?.text, "Moving to iCloud is paused.")
        XCTAssertFalse(paused.isBusy, "A paused move doesn't spin")
        XCTAssertTrue(paused.needsAttention)
        XCTAssertTrue(ICloudSyncShown(iCloud: .migrating(progress)).isBusy)
        progress.total = 412; progress.completed = 157
        paused.iCloud = .migrating(progress)
        XCTAssertEqual(paused.headline(), "Moving to iCloud · 157 of 412 files")
    }

    func testBehaviorFootersGiveOnlyTheFixTheActionCantAndOnlyASyncingLibraryCanBeTurnedOff() {
        XCTAssertEqual(ICloudSyncShown(iCloud: .iCloudDriveOff).footer, "Turn it on in System Settings › Apple Account › iCloud.")
        XCTAssertNil(ICloudSyncShown(iCloud: .signedOut).footer, "Open System Settings… goes there")
        XCTAssertNil(connected().footer)
        XCTAssertNil(connected { $0.problem = .storageFull }.footer, "the problem line has the fix")
        XCTAssertEqual(ICloudSyncShown.problemText(.storageFull, managesStorage: true), "iCloud storage is full.", "Manage Storage… is its fix")
        XCTAssertEqual(ICloudSyncShown.problemText(.storageFull, managesStorage: false),
                       "iCloud storage is full. Free up space in System Settings › Apple Account › iCloud.",
                       "where nothing opens iCloud's storage, the fix in words")
        XCTAssertEqual(ICloudSyncShown.problemText(.accountChanged, managesStorage: false), SyncProblem.accountChanged.text)
        XCTAssertTrue(connected().isConnected)
        XCTAssertFalse(ICloudSyncShown(iCloud: .waitingForKey).isConnected)
        XCTAssertFalse(ICloudSyncShown(iCloud: .turnedOff).isConnected)
        var waiting = ICloudSyncShown(iCloud: .waitingForKey)
        waiting.folder = URL(fileURLWithPath: "/tmp/sync")
        XCTAssertTrue(waiting.isAttached, "The devices and the key's fixes show while waiting")
        XCTAssertFalse(waiting.isConnected)
        var folder = ICloudSyncShown(iCloud: .unavailableInThisBuild)
        folder.isFolderTransport = true
        XCTAssertFalse(folder.isConnected)
        folder.folder = URL(fileURLWithPath: "/tmp/sync")
        XCTAssertTrue(folder.isConnected)
        XCTAssertEqual(ICloudSyncShown(iCloud: .signedOut).symbol, "icloud.slash")
        XCTAssertEqual(ICloudSyncShown(iCloud: .unavailableInThisBuild).symbol, "icloud.slash")
        XCTAssertFalse(ICloudSyncShown(iCloud: .unavailableInThisBuild).needsAttention, "a build without iCloud needs nothing")
    }

    func testBehaviorTheBusyIndicatorFollowsWorkInProgress() {
        XCTAssertTrue(ICloudSyncShown(iCloud: .checking).isBusy)
        var counted = SyncMigrationProgress()
        counted.total = 10
        XCTAssertFalse(ICloudSyncShown(iCloud: .migrating(counted)).isBusy, "The move's own bar shows its progress")
        XCTAssertFalse(connected().isBusy)
        XCTAssertTrue(connected { $0.isSyncing = true }.isBusy)
        XCTAssertFalse(ICloudSyncShown(iCloud: .turnedOff).isBusy)
    }

    func testBehaviorEncryptionIsShownFromTheControllersState() {
        XCTAssertEqual(LibraryEncryptionShown(.unavailable), .unavailable)
        XCTAssertEqual(LibraryEncryptionShown(.off), .off)
        XCTAssertEqual(LibraryEncryptionShown(.waitingForKey), .waitingForKey)
        let saved = SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: true, isMigrator: false, progress: nil)
        XCTAssertEqual(LibraryEncryptionShown(.on(saved)), .on(status: "On", hasRecoveryKey: true, encryptsHere: false))
        var progress = SealerProgress()
        progress.remaining = 12
        let sealing = SealingSummary(currentKey: "k", hasKey: true, hasRecoveryKey: false, isMigrator: true, progress: progress)
        XCTAssertEqual(LibraryEncryptionShown(.on(sealing)), .on(status: "Encrypting · 12 left", hasRecoveryKey: false, encryptsHere: true))
        XCTAssertTrue(LibraryEncryptionShown(.on(saved)).isOn)
        XCTAssertFalse(LibraryEncryptionShown.off.isOn)
        XCTAssertEqual(ICloudSyncShown.waitingForKeyLine, "Turn on iCloud Keychain, or get the key from another device.")
    }

    func testBehaviorRemainingMigrationIsSaidOnlyWhileFilesAreStillComing() {
        var record = SyncMigrationRecord(sourcePath: "/tmp/old", container: "iCloud.local.daybook")
        XCTAssertNil(connected { $0.migration = record }.remainingMigration)
        record.switchedAt = Date(); record.remainingFiles = 1
        XCTAssertEqual(connected { $0.migration = record }.remainingMigration, "Copying 1 more file from the previous sync folder")
        record.remainingFiles = 4
        XCTAssertEqual(connected { $0.migration = record }.remainingMigration, "Copying 4 more files from the previous sync folder")
        record.abandoned = true
        XCTAssertNil(connected { $0.migration = record }.remainingMigration)
    }

    func testBehaviorTheLibrarysDevicesAreNamedAndCountedTheSameOnBothApps() {
        let now = Date()
        let activity = SyncDeviceActivity(recordingConversationID: UUID(), since: now.addingTimeInterval(-300), expiresAt: now.addingTimeInterval(60))
        let me = KnownSyncDevice(id: "me", deviceClass: .mac, displayName: "Vlad’s MacBook Pro", canProcess: true, lastSeen: now, isCurrentDevice: true)
        let studio = KnownSyncDevice(id: "studio", deviceClass: .mac, displayName: "Studio Mac", canProcess: true, lastSeen: now, activity: activity)
        let phone = KnownSyncDevice(id: "phone", deviceClass: .phone, displayName: "Alex’s iPhone", lastSeen: now.addingTimeInterval(-3_600))
        let journalOnly = KnownSyncDevice(id: "old")
        XCTAssertEqual(connected { $0.devices = [me] }.devicesSummary(now: now), "Only this Mac")
        XCTAssertEqual(connected { $0.devices = [me, phone] }.devicesSummary(now: now), "1 other")
        XCTAssertEqual(connected { $0.devices = [me, phone, studio] }.devicesSummary(now: now), "2 others")
        XCTAssertEqual(LibraryDeviceWords.name(journalOnly), "A device that hasn’t checked in")
        XCTAssertEqual(LibraryDeviceWords.name(KnownSyncDevice(id: "x", deviceClass: .phone)), "Unnamed device")
        XCTAssertEqual(LibraryDeviceWords.detail(me, now: now), "This Mac · Transcribes and summarizes · Synced \(DeviceDateFormat.lastSeen(now, now: now))")
        XCTAssertEqual(LibraryDeviceWords.detail(studio, now: now),
                       "Recording now · Transcribes and summarizes · \(RecorderStatusWords.lastSeen(now, now: now))")
        XCTAssertNil(LibraryDeviceWords.detail(journalOnly, now: now))
        XCTAssertEqual(me.systemImage, "laptopcomputer", "a MacBook is a laptop, in the list and the encryption sheet")
        XCTAssertEqual(studio.systemImage, "desktopcomputer")
        XCTAssertEqual(phone.systemImage, "iphone")
    }

    func testBehaviorAFailedActionIsOnePlainSentenceWithTheSystemsWordsBehindDetails() {
        struct Opaque: LocalizedError { var errorDescription: String? { "The operation couldn’t be completed. (NSCocoaErrorDomain 4.)" } }
        let problem = SyncSettingsProblem(error: Opaque(), fallback: "The library couldn’t be encrypted. Try again.")
        XCTAssertEqual(problem.message, "The library couldn’t be encrypted. Try again.")
        XCTAssertEqual(problem.details, "The operation couldn’t be completed. (NSCocoaErrorDomain 4.)")
        XCTAssertNil(SyncSettingsProblem(message: "Same", details: "Same").details, "never the sentence twice")
        XCTAssertEqual(ICloudSyncConfirmation.erase.action, "Erase Deleted Conversations from iCloud")
        XCTAssertTrue(ICloudSyncConfirmation.erase.isDestructive)
        XCTAssertEqual(ICloudSyncConfirmation.turnOff.title, "Stop syncing this Mac?")
        XCTAssertEqual(ICloudSyncConfirmation.startOver.message, LibraryWords.startOverConsequence)
        // Get Key from a device that can't be reached, the same on both apps.
        XCTAssertEqual(ICloudSyncShown.couldntReach("Alex’s iPhone"),
                       "Couldn’t reach Alex’s iPhone. Make sure both are on the same Wi‑Fi, then try again.")
    }
}
