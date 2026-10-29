import DaybookKit
import SwiftUI
import UIKit

/// Settings' iCloud row: what sync is doing, in a line, opening Settings › iCloud.
struct ICloudRow: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let sync = model.sync
        let needsYou = SyncSymbol.needsAttention(sync)
        SettingsRow(title: "iCloud", detail: sync.statusLine, systemImage: SyncSymbol.name(sync),
                    tone: needsYou ? .attention : .neutral, detailNeedsAttention: needsYou)
    }
}

/// The sync status's symbol, and whether it needs the person (orange).
@MainActor
enum SyncSymbol {
    static func name(_ sync: PhoneSync) -> String {
        if case .unavailable = sync.connection { return "icloud.slash" }
        if needsAttention(sync) { return "exclamationmark.icloud" }
        return "icloud"
    }

    /// iCloud can't be used, a pass failed, or the library's key is missing.
    static func needsAttention(_ sync: PhoneSync) -> Bool {
        if case .unavailable = sync.connection { return true }
        return sync.isConnected && (sync.lastError != nil || sync.encryption == .waitingForKey)
    }
}

/// Settings › iCloud: what sync is doing right now, in one honest line; Sync Now; the library's
/// devices; and encryption.
struct ICloudScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showingDetails = false

    var body: some View {
        let sync = model.sync
        let needsYou = SyncSymbol.needsAttention(sync)
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: SettingsMetrics.gap) {
                        SettingsTile(systemImage: SyncSymbol.name(sync), tone: needsYou ? .attention : .neutral)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sync.statusLine)
                                .foregroundStyle(needsYou ? PhoneStyle.Ink.warning : PhoneStyle.Ink.title)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = sync.detailLine(now: context.date) {
                                Text(detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                    .accessibilityElement(children: .combine)
                }
                if sync.isConnected {
                    if sync.lastError != nil {
                        Button { showingDetails = true } label: { SettingsActionLabel(title: "Details", systemImage: "info.circle") }
                    }
                    // A pass already running takes this as another to run after it.
                    Button {
                        Task { await model.sync.synchronize(.manual) }
                    } label: {
                        SettingsActionLabel(title: "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                } else if case .unavailable = sync.connection {
                    if model.cloud.settingsCanFix, let url = URL(string: UIApplication.openSettingsURLString) {
                        Button { openURL(url) } label: { SettingsActionLabel(title: "Open Settings", systemImage: "gear") }
                    }
                    Button {
                        Task { await model.refreshCloud() }
                    } label: {
                        SettingsActionLabel(title: "Check Again", systemImage: "arrow.clockwise")
                    }
                }
            }
            if sync.isConnected {
                Section {
                    NavigationLink(value: SettingsRoute.libraryDevices) {
                        LabeledContent("Devices in This Library", value: devicesSummary)
                    }
                }
                if sync.encryption != .unavailable {
                    Section { EncryptionRows() }
                }
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("iCloud")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingDetails) { DetailsSheet(title: "Details", text: model.sync.lastError ?? "") }
    }

    private var devicesSummary: String {
        let others = model.sync.devices.filter { !$0.isCurrentDevice }
        return others.isEmpty ? "Only this iPhone" : others.count == 1 ? "1 other" : "\(others.count) others"
    }
}

/// Every device that syncs this library, with when it was last seen.
struct LibraryDevicesScreen: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let devices = model.sync.devices
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                Section {
                    ForEach(devices) { device in
                        SettingsRow(title: name(device), detail: Self.detail(device, now: context.date), systemImage: symbol(device))
                    }
                }
            }
            .refreshable { await model.sync.refreshDevices() }
        }
        .settingsScrollEnd()
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.sync.refreshDevices() }
    }

    private func symbol(_ device: KnownSyncDevice) -> String {
        switch device.deviceClass {
        case .mac?: return "desktopcomputer"
        case .phone?: return "iphone"
        default: return "questionmark.app.dashed"
        }
    }

    private func name(_ device: KnownSyncDevice) -> String {
        // A device known only from the journal hasn't written a presence record: an earlier Daybook, or
        // one that hasn't finished its first sync. It can't be told which, or what kind of device it is.
        device.displayName ?? (device.deviceClass == nil ? "A device that hasn’t checked in" : "Unnamed device")
    }

    /// "This iPhone · Synced just now", "Recording now · Transcribes and summarizes · Last seen 2 h ago";
    /// nil when there's nothing to say.
    static func detail(_ device: KnownSyncDevice, now: Date) -> String? {
        var parts: [String] = device.isCurrentDevice ? ["This iPhone"] : []
        if device.deviceClass == .mac, device.isRecording(at: now) { parts.append("Recording now") }
        if device.canProcess == true { parts.append("Transcribes and summarizes") }
        if let seen = device.lastSeen {
            parts.append(device.isCurrentDevice ? "Synced \(MacPresence.age(now.timeIntervalSince(seen)))" : "Last seen \(MacPresence.age(now.timeIntervalSince(seen)))")
        } else if device.isCurrentDevice {
            parts.append("Not synced yet")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Settings › Storage: the audio kept on this iPhone against its budget, Clear Downloaded Audio
/// (only while there's some to clear), and backups.
struct StorageScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var clearing = false

    var body: some View {
        @Bindable var settings = model.settings
        let usage = model.audio.usage
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bytes(usage.bytes)).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(PhoneStyle.Ink.title)
                        Text("of \(bytes(settings.audioCacheBudget))").foregroundStyle(PhoneStyle.Ink.secondary)
                    }
                    // A meter, not an action or work in progress: neutral ink.
                    ProgressView(value: min(1, Double(usage.bytes) / Double(max(1, settings.audioCacheBudget))))
                        .tint(PhoneStyle.Ink.secondary)
                    if let breakdown = Self.breakdown(bytes: usage.bytes, downloaded: usage.downloadedBytes) {
                        Text(breakdown).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                Picker("Keep Up To", selection: $settings.audioCacheBudget) {
                    ForEach(PhoneSettings.budgetChoices, id: \.self) { Text(bytes($0)).tag($0) }
                }
            } header: {
                Text("Audio on This iPhone")
            }
            // Downloads go back to iCloud, so they can be cleared only while it's there to get them again.
            if (usage.downloadedBytes > 0 && model.sync.isConnected) || clearing {
                Section {
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
                } footer: {
                    Text("Only downloaded audio is removed.")
                }
            }
            Section {
                // An encrypted library's choice is its own (`BackupExclusion`).
                Toggle("Include in iPhone Backups", isOn: model.libraryIsEncrypted
                       ? $settings.includesEncryptedLibraryInBackups : $settings.includesLibraryInBackups)
            }
        }
        .settingsScrollEnd()
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.audio.refreshUsage() }
        .onChange(of: settings.audioCacheBudget) { _, budget in Task { await model.audio.setBudget(budget) } }
        .onChange(of: settings.includesLibraryInBackups) { model.applyBackupExclusion() }
        .onChange(of: settings.includesEncryptedLibraryInBackups) { model.applyBackupExclusion() }
    }

    private func bytes(_ value: UInt64) -> String { Self.bytes(value) }

    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }

    /// What the audio is, under its total: both kinds with their sizes, one kind without repeating the
    /// total, or nil when there's none.
    static func breakdown(bytes total: UInt64, downloaded: UInt64) -> String? {
        let downloaded = min(total, downloaded), here = total - downloaded
        switch (downloaded > 0, here > 0) {
        case (true, true): return "\(bytes(downloaded)) downloaded · \(bytes(here)) recorded on this iPhone"
        case (true, false): return "Downloaded for playback"
        case (false, true): return "Recorded on this iPhone"
        case (false, false): return nil
        }
    }
}
