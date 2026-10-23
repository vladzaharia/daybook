import AppKit
import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("iCloud library sync", systemImage: "icloud").font(.title3.weight(.semibold))
            Text("Keep original recordings, transcripts, summaries, notes, highlights, speakers, folders, tags, templates, vocabulary, and revision history together across Macs.")
                .font(.callout).foregroundStyle(.secondary)
            if let folder = state.sync.folder {
                if !state.sync.isICloudLocation { Text("This folder is not identified as iCloud Drive. Choose a folder in iCloud Drive for automatic delivery between Macs.").font(.caption).foregroundStyle(DaybookStyle.gold) }
                Text(folder.path).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Sync now") { Task { await state.synchronizeLibrary() } }
                    Button("Show in Finder") { NSWorkspace.shared.open(folder) }
                    Button("Disconnect") { state.sync.disconnect() }
                }.disabled(state.sync.isSyncing)
                if state.sync.isSyncing { ProgressView().controlSize(.small) }
            } else {
                Button("Connect an iCloud Drive folder…") { state.sync.chooseFolder() }
                if let identifier = Bundle.main.object(forInfoDictionaryKey: "DaybookICloudContainerIdentifier") as? String {
                    Button("Use app iCloud container") { Task { await state.sync.connectNativeContainer(identifier: identifier) } }
                }
            }
            Toggle("Process new synced recordings on this Mac", isOn: $state.processSyncedAudio)
            Text("When the selected models are installed, newly received audio without a transcript joins this Mac’s processing queue.").font(.caption).foregroundStyle(.secondary)
            Text(state.sync.status).font(.callout).foregroundStyle(DaybookStyle.accent)
            if let date = state.sync.lastSync { Text("Last exchange: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            if !state.sync.warnings.isEmpty {
                ForEach(Array(state.sync.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(DaybookStyle.gold)
                }
            }
            Text("Choose the same private folder on each Mac. iCloud must be enabled in macOS. Files may take time to upload or download; Daybook retries automatically while open. Recordings finish locally before syncing. Each Mac downloads its own models and runs all inference locally.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Connecting uploads the library to your iCloud Drive. Daybook retains local originals and recoverable sync history; disconnecting does not delete either copy.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
