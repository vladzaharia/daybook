import AppKit
import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI

/// Settings › Library › iCloud Sync: DaybookUI's `ICloudSyncSection`, which the iPhone's Settings › iCloud shows too,
/// filled from this Mac's sync controller and phone link. Sync uses Daybook's own iCloud container, so there's no
/// folder to choose; development builds without iCloud can bring back a chosen folder with
/// `LibrarySyncController.developmentFolderSyncKey`. The library's devices and encryption's sheets are 420 pt sheets.
struct SyncSettingsView: View {
    @Bindable var state: AppState
    /// Followed directly: the window doesn't redraw for every sync status change.
    private let sync: LibrarySyncController
    /// For Get Key from <iPhone> while waiting for the library's key.
    private let phoneLink: PhoneLink
    @State private var sheet: ICloudSyncSheet?

    init(state: AppState) {
        self.state = state
        sync = state.sync
        phoneLink = state.phoneLink
    }

    private var shown: ICloudSyncShown {
        #if DEBUG
        if let demo = SyncSettingsDemo.shown { return demo }
        #endif
        return Self.shown(sync, peers: phoneLink.peers.values.map { ICloudSyncShown.KeyPeer(id: $0.deviceID, name: $0.name) },
                          devices: state.syncDevices)
    }

    /// What the section shows, from the controller.
    @MainActor static func shown(_ sync: LibrarySyncController, peers: [ICloudSyncShown.KeyPeer], devices: [KnownSyncDevice]) -> ICloudSyncShown {
        var shown = ICloudSyncShown(iCloud: sync.iCloud)
        shown.isFolderTransport = sync.transport == .folder || sync.allowsFolderSync
        shown.folder = sync.folder
        shown.isSyncing = sync.isSyncing
        shown.pendingUploads = sync.pendingUploads
        shown.pendingDownloads = sync.pendingDownloads
        shown.lastSync = sync.lastSync
        shown.problem = sync.status.problem
        shown.warnings = sync.warnings
        shown.otherInstallation = sync.warning == .otherInstallation
        shown.migration = sync.migrationRecord
        shown.encryption = LibraryEncryptionShown(sync.encryption)
        shown.mayStartOverEncryption = sync.mayStartOverEncryption
        shown.hasRetiredFolderJournal = sync.hasRetiredFolderJournal
        shown.keyPeers = peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        shown.devices = devices
        return shown
    }

    private var actions: ICloudSyncActions {
        let state = state, sync = sync
        return ICloudSyncActions(
            syncNow: { Task { await state.synchronizeLibrary() } },
            tryAgain: { sync.retryContainer() },
            useCurrentAccount: { sync.useCurrentICloudAccount() },
            requestKey: { phone in Task { await state.requestLibraryKey(from: phone) } },
            openSettings: Self.openAccountSettings,
            // iCloud's storage is managed from the Apple Account's iCloud settings.
            manageStorage: Self.openAccountSettings,
            turnOn: { sync.turnOnICloudSync() },
            turnOff: { sync.disconnect() },
            choosePreviousFolderAgain: { sync.choosePreviousFolderAgain(near: $0) },
            continueWithoutPreviousFolder: { sync.continueWithoutPreviousFolder() },
            deleteRetiredFolderJournal: { try sync.deleteRetiredFolderJournal() })
    }

    var body: some View {
        let shown = shown
        ICloudSyncSection(shown: shown, actions: actions, controller: sync, sheet: $sheet) {
            Button { sheet = .devices } label: {
                LibraryDevicesRowLabel(summary: shown.devicesSummary(), chevron: true)
            }
            .buttonStyle(.plain)
        } extras: {
            if shown.isAttached {
                Toggle("Transcribe synced recordings on this Mac", isOn: $state.processSyncedAudio)
                    .controlSize(.regular)
            }
            if shown.isFolderTransport, shown.folder == nil {
                LabeledContent {
                    Button("Choose Folder…") { sync.chooseFolder() }
                } label: {
                    Text("Sync through a folder")
                    Text("Development builds without iCloud only.")
                }
            }
        }
        .sheet(item: $sheet) { shownSheet in
            ICloudSyncSheetContent(shownSheet, controller: sync, devices: devicesForSheet, refreshDevices: { await state.refreshSyncDevices() },
                                   present: { sheet = $0 })
        }
        #if DEBUG
        // `--sync-sheet encrypt|recovery-key|enter-key|devices` opens one of the sheets, with `--sync-demo`.
        .task { sheet = SyncSettingsDemo.sheet }
        #endif
    }

    private var devicesForSheet: [KnownSyncDevice] {
        #if DEBUG
        if SyncSettingsDemo.shown != nil { return SyncSettingsDemo.devices }
        #endif
        return state.syncDevices
    }

    private static func openAccountSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

// MARK: - Demos

#if DEBUG
/// Debug-only: `--sync-demo <state>` shows Settings › Library's iCloud Sync section in that state, without iCloud, for
/// screenshots. Its buttons still act on the real (unconnected) controller. States: checking, off, signed-out,
/// drive-off, unavailable, moving, moving-paused, on, syncing, downloading, uploading, full, removed, other-app, paused,
/// warning, damaged, account, folder-lost, folder-missing, waiting, waiting-many (two iPhones with long names), encrypted,
/// no-recovery-key, encrypting, dev-folder. `--sync-sheet encrypt|recovery-key|enter-key|devices` opens a sheet over it.
@MainActor
enum SyncSettingsDemo {
    static let scenario = LaunchOptions.value(after: "--sync-demo")

    static var sheet: ICloudSyncSheet? {
        switch LaunchOptions.value(after: "--sync-sheet") {
        case "encrypt"?: return .encrypt
        case "recovery-key"?: return .recoveryKey(RecoveryKey.generate())
        case "enter-key"?: return .enterRecoveryKey
        case "devices"?: return .devices
        default: return nil
        }
    }

    /// The library's devices in the demos: this Mac, an iPhone, and another Mac that's recording.
    static var devices: [KnownSyncDevice] {
        let now = Date()
        let recording = SyncDeviceActivity(recordingConversationID: UUID(), since: now.addingTimeInterval(-600), expiresAt: now.addingTimeInterval(600))
        return [
            KnownSyncDevice(id: "this-mac", deviceClass: .mac, displayName: "Vlad’s MacBook Pro", canProcess: true, lastSeen: now, isCurrentDevice: true),
            KnownSyncDevice(id: "studio", deviceClass: .mac, displayName: "Studio Mac", canProcess: true, lastSeen: now.addingTimeInterval(-300),
                            activity: recording),
            KnownSyncDevice(id: "phone", deviceClass: .phone, displayName: "Alex’s iPhone", lastSeen: now.addingTimeInterval(-7_200)),
        ]
    }

    static var shown: ICloudSyncShown? {
        guard let scenario else { return nil }
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
        switch scenario {
        case "checking": return ICloudSyncShown(iCloud: .checking)
        case "off": return ICloudSyncShown(iCloud: .turnedOff)
        case "signed-out": return ICloudSyncShown(iCloud: .signedOut)
        case "drive-off": return ICloudSyncShown(iCloud: .iCloudDriveOff)
        case "unavailable": return ICloudSyncShown(iCloud: .containerUnavailable("The operation couldn’t be completed. (CKErrorDomain error 4.)"))
        case "moving":
            var progress = SyncMigrationProgress()
            progress.total = 412; progress.completed = 157
            return ICloudSyncShown(iCloud: .migrating(progress))
        case "moving-paused":
            var progress = SyncMigrationProgress()
            progress.total = 412; progress.completed = 157
            var shown = ICloudSyncShown(iCloud: .migrating(progress))
            shown.problem = .migrationPaused(details: "The operation couldn’t be completed. No space left on device.")
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
            shown.keyPeers = scenario == "waiting"
                ? [.init(id: UUID(), name: "Alex’s iPhone")]
                : [.init(id: UUID(), name: "Alex’s iPhone 15 Pro Max"), .init(id: UUID(), name: "Jordan’s Work iPhone")]
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
