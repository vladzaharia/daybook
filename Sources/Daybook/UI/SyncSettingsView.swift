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
            requestKey: { phone in try await state.requestLibraryKey(from: phone) },
            openSettings: Self.openAccountSettings,
            // iCloud's storage is managed from the Apple Account's iCloud settings.
            manageStorage: Self.openAccountSettings,
            startNewLibrary: { try await sync.startNewLibrary() },
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
            // Transcribe synced recordings on this Mac is Settings › Models' (whether this Mac takes other devices' work).
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
/// screenshots (`ICloudSyncDemo`, which the iPhone shows too). Its buttons still act on the real (unconnected)
/// controller. `--sync-sheet encrypt|recovery-key|enter-key|devices` opens a sheet over it.
@MainActor
enum SyncSettingsDemo {
    static let scenario = LaunchOptions.value(after: "--sync-demo")
    static var sheet: ICloudSyncSheet? { ICloudSyncDemo.sheet(LaunchOptions.value(after: "--sync-sheet")) }
    static var devices: [KnownSyncDevice] { ICloudSyncDemo.devices }
    static var shown: ICloudSyncShown? { scenario.flatMap(ICloudSyncDemo.shown) }
}
#endif
