import DaybookKit
import SwiftUI
import UIKit

/// Settings › iCloud: what sync is doing right now, in one honest line, and the library's devices.
struct SyncSection: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let sync = model.sync
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 12) {
                    SyncGlyph()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sync.statusLine)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = sync.detailLine(now: context.date) {
                            Text(detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
            if sync.isConnected {
                Button {
                    Task { await model.sync.synchronize(.manual) }
                } label: {
                    Text(sync.isSyncing ? "Syncing…" : "Sync Now")
                }
                .disabled(sync.isSyncing)
                NavigationLink(value: SettingsRoute.libraryDevices) {
                    LabeledContent("Devices in This Library", value: devicesSummary)
                }
            } else if case .unavailable = sync.connection {
                if model.cloud.settingsCanFix, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }
                }
                Button("Check Again") { Task { await model.refreshCloud() } }
            }
        } header: {
            Text("iCloud")
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private var devicesSummary: String {
        let others = model.sync.devices.filter { !$0.isCurrentDevice }
        return others.isEmpty ? "Only this iPhone" : others.count == 1 ? "1 other" : "\(others.count) others"
    }

    /// Where your Mac stands: "Studio Mac synced just now."
    private var footer: String? {
        if case .unavailable = model.sync.connection { return nil }
        return model.macPresence.summary()
    }
}

/// The status glyph: a check when up to date, arrows while syncing, a slash when sync can't run.
private struct SyncGlyph: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let sync = model.sync
        let (symbol, tint): (String, Color) = {
            if !sync.isConnected { return ("icloud.slash", PhoneStyle.Ink.warning) }
            if sync.lastError != nil { return ("exclamationmark.icloud", PhoneStyle.Ink.warning) }
            if sync.isSyncing || sync.pendingUploads > 0 || sync.hasMoreWork { return ("arrow.triangle.2.circlepath.icloud", PhoneStyle.accent) }
            return ("checkmark.icloud", PhoneStyle.accent)
        }()
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(tint)
            .symbolEffect(.rotate, isActive: sync.isSyncing)
            .frame(width: 30)
            .accessibilityHidden(true)
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
                        HStack(spacing: 12) {
                            Image(systemName: symbol(device))
                                .font(.system(size: 18))
                                .foregroundStyle(device.isCurrentDevice ? PhoneStyle.accent : .secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name(device) + (device.isCurrentDevice ? " (this iPhone)" : ""))
                                Text(detail(device, now: context.date)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .refreshable { await model.sync.refreshDevices() }
        }
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

    private func detail(_ device: KnownSyncDevice, now: Date) -> String {
        var parts: [String] = []
        if device.deviceClass == .mac, device.isRecording(at: now) { parts.append("Recording now") }
        if device.canProcess == true { parts.append("Transcribes and summarizes") }
        if let seen = device.lastSeen {
            parts.append(device.isCurrentDevice ? "Synced \(MacPresence.age(now.timeIntervalSince(seen)))" : "Last seen \(MacPresence.age(now.timeIntervalSince(seen)))")
        } else {
            parts.append(device.isCurrentDevice ? "Not synced yet" : "Last seen: not reported")
        }
        return parts.joined(separator: " · ")
    }
}

/// Settings › Storage: the audio cache budget, what's used, and Clear Downloaded Audio.
struct StorageScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var cleared: UInt64?
    @State private var clearing = false

    var body: some View {
        @Bindable var settings = model.settings
        let usage = model.audio.usage
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bytes(usage.bytes)).font(.title2.weight(.semibold).monospacedDigit())
                        Text("of \(bytes(settings.audioCacheBudget))").foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(1, Double(usage.bytes) / Double(max(1, settings.audioCacheBudget))))
                        .tint(PhoneStyle.accent)
                    Text(usage.items == 0 ? "No audio is kept on this iPhone yet." : breakdown(usage))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Audio on This iPhone")
            }
            Section {
                Picker("Keep Up To", selection: $settings.audioCacheBudget) {
                    ForEach(PhoneSettings.budgetChoices, id: \.self) { Text(bytes($0)).tag($0) }
                }
            }
            Section {
                Button(role: .destructive) {
                    clearing = true
                    Task {
                        cleared = await model.audio.clearDownloaded()
                        clearing = false
                    }
                } label: {
                    HStack {
                        Text("Clear Downloaded Audio")
                        if clearing { Spacer(); ProgressView() }
                    }
                }
                .disabled(usage.downloadedBytes == 0 || clearing || !model.sync.isConnected)
            } footer: {
                if let cleared {
                    Text(cleared == 0 ? "Nothing to clear." : "Freed \(bytes(cleared)).")
                } else {
                    Text("Only downloaded audio is removed.")
                }
            }
            Section {
                Toggle("Include in iPhone Backups", isOn: $settings.includesLibraryInBackups)
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.audio.refreshUsage() }
        .onChange(of: settings.audioCacheBudget) { _, budget in Task { await model.audio.setBudget(budget) } }
        .onChange(of: settings.includesLibraryInBackups) { _, included in
            BackupExclusion.apply(libraryRoot: model.library.rootURL, inbox: model.library.inboxURL, includesLibrary: included)
        }
    }

    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }

    private func breakdown(_ usage: SyncAudioProvider.CacheUsage) -> String {
        let downloaded = usage.downloadedBytes, here = usage.bytes - min(usage.bytes, usage.downloadedBytes)
        var parts: [String] = []
        if downloaded > 0 { parts.append("\(bytes(downloaded)) downloaded for playback") }
        if here > 0 { parts.append("\(bytes(here)) recorded on this iPhone") }
        return parts.joined(separator: " · ")
    }
}
