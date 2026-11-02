import DaybookKit
import DaybookUI
import SwiftUI
import UIKit

/// Settings' iCloud row: where sync stands, in a line, opening Settings › iCloud.
struct ICloudRow: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let shown = model.sync.shown()
        SettingsRow(title: "iCloud", detail: shown.line, systemImage: shown.symbol,
                    tone: shown.needsAttention ? .attention : .neutral, detailNeedsAttention: shown.needsAttention)
    }
}

/// Settings › iCloud: DaybookUI's `ICloudSyncSection`, which the Mac's Settings › Library shows too, filled from this
/// iPhone's sync and the Macs on the link. Its sheets are page sheets; the library's devices push.
struct ICloudScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var sheet: ICloudSyncSheet?

    var body: some View {
        @Bindable var settings = model.settings
        let sync = model.sync
        let shown = sync.shown(keyPeers: model.link.connectedMacs.map { ICloudSyncShown.KeyPeer(id: $0.id, name: $0.name) })
        Form {
            ICloudSyncSection(shown: shown, actions: actions, controller: sync.controller, sheet: $sheet,
                              cellular: $settings.encryptsOverCellular) {
                NavigationLink(value: SettingsRoute.libraryDevices) {
                    LibraryDevicesRowLabel(summary: shown.devicesSummary())
                }
            } extras: {
                EmptyView()
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("iCloud")
        .navigationBarTitleDisplayMode(.inline)
        .pageSheet(item: $sheet) { shownSheet in
            ICloudSyncSheetContent(shownSheet, controller: sync.controller, present: { sheet = $0 })
        }
        .onChange(of: settings.encryptsOverCellular) { _, allowed in
            // Allowed now: the recordings waiting for Wi‑Fi start downloading.
            if allowed { Task { await model.sync.synchronize(.manual) } }
        }
        .task { await model.sync.refreshDevices() }
    }

    private var actions: ICloudSyncActions {
        let model = model, openURL = openURL
        let settings = URL(string: UIApplication.openSettingsURLString)
        return ICloudSyncActions(
            // A pass already running takes this as another to run after it.
            syncNow: { Task { await model.sync.synchronize(.manual) } },
            tryAgain: { Task { await model.refreshCloud() } },
            useCurrentAccount: { Task { await model.sync.useCurrentAccount() } },
            requestKey: { mac in Task { await model.requestLibraryKey(from: mac) } },
            // Settings can fix it (signing in, or iCloud Drive); a build without iCloud can't.
            openSettings: model.cloud.settingsCanFix ? settings.map { url in { openURL(url) } } : nil)
    }
}

/// Every device that syncs this library, with when it was last seen (DaybookUI's `LibraryDevicesSection`, which the
/// Mac shows in a sheet).
struct LibraryDevicesScreen: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        List {
            LibraryDevicesSection(devices: model.sync.devices)
            SettingsScrollEndMarker()
        }
        .refreshable { await model.sync.refreshDevices() }
        .settingsScrollEnd()
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.sync.refreshDevices() }
    }
}

/// Settings › Storage: DaybookUI's `LibraryStorageSection` (the figures the Mac's Storage shows: this iPhone's audio,
/// its conversations, and downloaded models), then this iPhone's own: how much downloaded audio it keeps while it
/// syncs, Clear Downloaded Audio (only while there's some), and backups.
struct StorageScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var clearing = false

    var body: some View {
        @Bindable var settings = model.settings
        let usage = model.audio.usage
        let syncs = model.sync.isConnected
        Form {
            LibraryStorageSection(report: model.audio.report?.with(models: model.models.bytesOnDisk))
            // Downloads go back to iCloud and come down again when played: a budget applies only while sync runs.
            if syncs {
                Section {
                    StorageBudgetMeter(bytes: Int64(clamping: usage.bytes), budget: Int64(clamping: settings.audioCacheBudget))
                    Picker("Keep Up To", selection: $settings.audioCacheBudget) {
                        ForEach(PhoneSettings.budgetChoices, id: \.self) { Text(Self.bytes($0)).tag($0) }
                    }
                    if usage.downloadedBytes > 0 || clearing {
                        Button(role: .destructive) {
                            clearing = true
                            Task {
                                _ = await model.audio.clearDownloaded()
                                clearing = false
                            }
                        } label: {
                            HStack {
                                Text("Clear Downloaded Audio")
                                if clearing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(clearing)
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    if usage.downloadedBytes > 0 { Text("Only downloaded audio is removed.") }
                }
            }
            Section {
                // An encrypted library's choice is its own (`BackupExclusion`).
                Toggle("Include in iPhone Backups", isOn: model.libraryIsEncrypted
                       ? $settings.includesEncryptedLibraryInBackups : $settings.includesLibraryInBackups)
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.audio.refreshUsage() }
        .onChange(of: settings.audioCacheBudget) { _, budget in Task { await model.audio.setBudget(budget) } }
        .onChange(of: settings.includesLibraryInBackups) { model.applyBackupExclusion() }
        .onChange(of: settings.includesEncryptedLibraryInBackups) { model.applyBackupExclusion() }
    }

    /// A size, as Settings says it everywhere ("632 MB").
    static func bytes(_ value: UInt64) -> String { ByteSize.format(Int64(clamping: value)) }

    /// What the audio is, under its figure (`StorageWords.audioBreakdown`): both kinds with their sizes, one kind
    /// without repeating the figure, or nil when there's none.
    static func breakdown(bytes total: UInt64, downloaded: UInt64) -> String? {
        StorageWords.audioBreakdown(LibraryStorageReport(audio: Int64(clamping: total), downloadedAudio: Int64(clamping: downloaded)),
                                    here: "this iPhone")
    }
}
