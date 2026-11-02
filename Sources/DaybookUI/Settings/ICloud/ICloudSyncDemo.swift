#if DEBUG
import DaybookKit
import Foundation

/// Debug-only: iCloud Sync in a state, without iCloud, for screenshots on both apps (`--sync-demo <state>`, with
/// `--sync-sheet encrypt|recovery-key|enter-key|devices` for a sheet over it). States: checking, off, signed-out,
/// drive-off, unavailable, moving, moving-paused, on, syncing, downloading, uploading, full, removed, other-app, paused,
/// warning, damaged, account, folder-lost, folder-missing, waiting, waiting-many (two devices with long names),
/// encrypted, no-recovery-key, encrypting, dev-folder.
public enum ICloudSyncDemo {
    /// The library's devices in the demos: this device, another Mac that's recording, and an iPhone.
    public static var devices: [KnownSyncDevice] {
        let now = Date()
        let recording = SyncDeviceActivity(recordingConversationID: UUID(), since: now.addingTimeInterval(-600), expiresAt: now.addingTimeInterval(600))
        #if os(macOS)
        let here = KnownSyncDevice(id: "this-mac", deviceClass: .mac, displayName: "Vlad’s MacBook Pro", canProcess: true, lastSeen: now,
                                   isCurrentDevice: true)
        let phone = KnownSyncDevice(id: "phone", deviceClass: .phone, displayName: "Alex’s iPhone", lastSeen: now.addingTimeInterval(-7_200))
        #else
        let here = KnownSyncDevice(id: "this-phone", deviceClass: .phone, displayName: "Vlad’s iPhone", lastSeen: now, isCurrentDevice: true)
        let phone = KnownSyncDevice(id: "laptop", deviceClass: .mac, displayName: "Vlad’s MacBook Pro", canProcess: true,
                                    lastSeen: now.addingTimeInterval(-7_200))
        #endif
        return [here,
                KnownSyncDevice(id: "studio", deviceClass: .mac, displayName: "Studio Mac", canProcess: true, lastSeen: now.addingTimeInterval(-300),
                                activity: recording),
                phone]
    }

    /// A sheet over it.
    public static func sheet(_ name: String?) -> ICloudSyncSheet? {
        switch name {
        case "encrypt"?: return .encrypt
        case "recovery-key"?: return .recoveryKey(RecoveryKey.generate())
        case "enter-key"?: return .enterRecoveryKey
        case "devices"?: return .devices
        default: return nil
        }
    }

    public static func shown(_ scenario: String) -> ICloudSyncShown? {
        let folder = URL(fileURLWithPath: "/Users/demo/Library/Mobile Documents/iCloud~local~daybook/Documents/Daybook")
        func connected(_ change: (inout ICloudSyncShown) -> Void = { _ in }) -> ICloudSyncShown {
            var shown = ICloudSyncShown(iCloud: .connected)
            shown.folder = folder
            shown.lastSync = Calendar.current.date(bySettingHour: 11, minute: 42, second: 0, of: Date())
            shown.encryption = .off
            shown.devices = devices
            change(&shown)
            return shown
        }
        let peers: [ICloudSyncShown.KeyPeer]
        #if os(macOS)
        peers = scenario == "waiting" ? [.init(id: UUID(), name: "Alex’s iPhone")]
            : [.init(id: UUID(), name: "Alex’s iPhone 15 Pro Max"), .init(id: UUID(), name: "Jordan’s Work iPhone")]
        #else
        peers = scenario == "waiting" ? [.init(id: UUID(), name: "Studio Mac")]
            : [.init(id: UUID(), name: "Vlad’s MacBook Pro (14-inch, 2026)"), .init(id: UUID(), name: "Studio Mac")]
        #endif
        switch scenario {
        case "checking": return ICloudSyncShown(iCloud: .checking)
        case "off": return ICloudSyncShown(iCloud: .turnedOff)
        case "signed-out": return ICloudSyncShown(iCloud: .signedOut)
        case "drive-off": return ICloudSyncShown(iCloud: .iCloudDriveOff)
        case "unavailable": return ICloudSyncShown(iCloud: .containerUnavailable("The operation couldn’t be completed. (CKErrorDomain error 4.)"))
        case "moving", "moving-paused":
            var progress = SyncMigrationProgress()
            progress.total = 412; progress.completed = 157
            var shown = ICloudSyncShown(iCloud: .migrating(progress))
            if scenario == "moving-paused" { shown.problem = .migrationPaused(details: "The operation couldn’t be completed. No space left on device.") }
            return shown
        case "on": return connected()
        case "syncing": return connected { $0.isSyncing = true }
        case "downloading": return connected { $0.pendingDownloads = 3 }
        case "uploading": return connected { $0.pendingUploads = 2 }
        case "full": return connected { $0.pendingUploads = 2; $0.problem = .storageFull }
        case "removed": return connected { $0.problem = .libraryRemoved; $0.encryption = .on(status: "On", hasRecoveryKey: true, encryptsHere: false) }
        case "other-app": return connected { $0.otherInstallation = true }
        case "paused": return connected { $0.problem = .failure(details: "The operation couldn’t be completed. No space left on device.") }
        case "warning": return connected { $0.warnings = [SyncWarningWords.unsavedChange + ": The file “events-0042.json” couldn’t be saved."] }
        case "damaged":
            return connected {
                $0.warnings = [
                    SyncWarningWords.compose(SyncWarningWords.damagedHistory, details: "A synced change couldn’t be read: 3fa2c09e4b71d85e.json."),
                    SyncWarningWords.compose(SyncWarningWords.keptBothRecordings,
                                             details: "The one that was here is kept at ~/Library/Application Support/Daybook/Meetings/…/SyncConflicts/9c1d…-microphone.m4a."),
                ]
            }
        case "account": return ICloudSyncShown(iCloud: .accountChanged)
        case "folder-lost": return ICloudSyncShown(iCloud: .previousFolderAccessLost(nil))
        case "folder-missing": return ICloudSyncShown(iCloud: .previousFolderMissing)
        case "waiting", "waiting-many":
            var shown = ICloudSyncShown(iCloud: .waitingForKey)
            shown.folder = folder
            shown.encryption = .waitingForKey
            shown.mayStartOverEncryption = true
            shown.devices = devices
            shown.keyPeers = peers
            return shown
        case "encrypted": return connected { $0.encryption = .on(status: "On", hasRecoveryKey: true, encryptsHere: false) }
        case "no-recovery-key":
            return connected { $0.encryption = .on(status: "On", hasRecoveryKey: false, encryptsHere: false); $0.hasRetiredFolderJournal = true }
        case "encrypting": return connected { $0.encryption = .on(status: "Encrypting · 128 left", hasRecoveryKey: true, encryptsHere: true) }
        case "dev-folder":
            return connected { $0.isFolderTransport = true; $0.folder = URL(fileURLWithPath: NSHomeDirectory() + "/Daybook Sync") }
        default: return nil
        }
    }
}
#endif
