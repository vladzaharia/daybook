import AppKit
import DaybookKit
import SwiftUI

/// Settings › Library › iCloud Sync (Direction A §5.14). Sync uses Daybook's own iCloud container, so
/// there's no folder to choose: the section says what iCloud is doing. Development builds without iCloud
/// can bring back a chosen folder with `LibrarySyncController.developmentFolderSyncKey`.
struct SyncSettingsView: View {
    @ObservedObject var state: AppState
    /// Followed directly: the window doesn't redraw for every sync status change.
    @ObservedObject private var sync: LibrarySyncController
    @State private var confirmingTurnOff = false
    @State private var confirmingAccount = false
    @State private var confirmingSkip = false

    init(state: AppState) {
        self.state = state
        sync = state.sync
    }

    var body: some View {
        Section {
            if sync.transport == .folder || sync.allowsFolderSync {
                folderRows
            } else {
                iCloudRows
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            if let footer { SettingsFooter(footer) }
        }
        .alert("Stop syncing this Mac?", isPresented: $confirmingTurnOff) {
            Button("Turn Off", role: .destructive) { sync.disconnect() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your library stays on this Mac and in iCloud. Nothing is deleted.")
        }
        .alert("Sync with this iCloud account?", isPresented: $confirmingAccount) {
            Button("Sync") { sync.useCurrentICloudAccount() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its conversations are added to the iCloud account you’re signed in to.")
        }
        .alert("Sync without the previous folder?", isPresented: $confirmingSkip) {
            Button("Sync Without It") { sync.continueWithoutPreviousFolder() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everything in this Mac’s library still syncs. History and deleted conversations kept only in that folder stay there.")
        }
    }

    // MARK: iCloud

    @ViewBuilder private var iCloudRows: some View {
        LabeledContent("iCloud") {
            HStack(spacing: Space.s3) {
                if isBusy { ProgressView().controlSize(.small) }
                Text(headline).foregroundStyle(.secondary).monospacedDigit()
                headlineAction
            }
        }
        switch sync.iCloud {
        case .migrating(let progress) where progress.total > 0:
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                .accessibilityLabel("Moving your library to iCloud")
        case .connected:
            LabeledContent("Status") {
                Text(connectedStatus).foregroundStyle(.secondary).monospacedDigit()
            }
            if let problem { SyncWarning(text: problem.text, details: problem.details) }
            if let remaining = remainingMigration { SyncNote(text: remaining) }
            ForEach(Array(sync.warnings.enumerated()), id: \.offset) { _, warning in
                SyncWarning(text: warning)
            }
            Toggle("Transcribe synced recordings on this Mac", isOn: $state.processSyncedAudio)
                .controlSize(.regular)
            HStack {
                Spacer()
                Button("Turn Off Sync…") { confirmingTurnOff = true }
                    .disabled(sync.isSyncing)
            }
        case .accountChanged:
            SyncWarning(text: "This library synced with a different iCloud account, so sync is paused.") {
                Button("Sync with This Account…") { confirmingAccount = true }
            }
        case .previousFolderAccessLost(let location):
            SyncWarning(text: "Daybook can’t open the folder this Mac synced through before.") {
                HStack {
                    Button("Choose Folder Again…") { sync.choosePreviousFolderAgain(near: location) }
                    Button("Sync Without It…") { confirmingSkip = true }
                }
            }
        case .previousFolderMissing:
            SyncWarning(text: "Can’t find the folder this Mac synced through before.") {
                HStack {
                    Button("Try Again") { sync.retryContainer() }
                    Button("Sync Without It…") { confirmingSkip = true }
                }
            }
        case .containerUnavailable(let reason):
            SyncWarning(text: "iCloud isn’t available right now.", details: reason) { Button("Try Again") { sync.retryContainer() } }
        default:
            EmptyView()
        }
    }

    /// One phrase for where iCloud sync stands.
    private var headline: String {
        switch sync.iCloud {
        case .checking: return "Checking iCloud…"
        case .connected: return "On"
        case .iCloudDriveOff: return "iCloud is off in System Settings"
        case .signedOut: return "Signed out"
        case .migrating(let progress):
            return progress.total > 0 ? "Migrating \(progress.completed) of \(progress.total) files…" : "Preparing to move to iCloud…"
        case .accountChanged: return "Paused"
        case .previousFolderMissing, .previousFolderAccessLost: return "Paused"
        case .containerUnavailable: return "Not available"
        case .turnedOff: return "Off"
        case .unavailableInThisBuild: return "Not available in this build"
        }
    }

    @ViewBuilder private var headlineAction: some View {
        switch sync.iCloud {
        case .connected:
            Button("Sync Now") { Task { await state.synchronizeLibrary() } }
                .disabled(sync.isSyncing)
        case .iCloudDriveOff, .signedOut:
            Button("Open System Settings…") { Self.openAccountSettings() }
        case .turnedOff:
            Button("Turn On") { sync.turnOnICloudSync() }
        default:
            EmptyView()
        }
    }

    private var isBusy: Bool {
        switch sync.iCloud {
        case .checking, .migrating: return true
        case .connected: return sync.isSyncing
        default: return false
        }
    }

    private var footer: String? {
        switch sync.iCloud {
        case .iCloudDriveOff:
            return "Turn on iCloud Drive in System Settings › Apple Account › iCloud."
        case .signedOut:
            return "Sign in to iCloud to sync your library."
        default:
            return nil
        }
    }

    /// The copy deck's sync states: Up to date · 11:42 AM, Syncing…, Waiting for iCloud to download 3 items…
    private var connectedStatus: String {
        if sync.isSyncing { return "Syncing…" }
        if sync.pendingDownloads > 0 {
            return "Waiting for iCloud to download \(sync.pendingDownloads) \(sync.pendingDownloads == 1 ? "item" : "items")…"
        }
        if problem != nil { return "Not syncing" }
        guard let date = sync.lastSync else { return "Waiting to sync" }
        let time = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return "Up to date · \(time)"
    }

    /// A paused or failed sync, in place: what happened, with the reason behind Details.
    private var problem: (text: String, details: String?)? {
        let text = sync.status
        guard text.hasPrefix("Sync paused") || text.hasPrefix("Couldn") || text.hasPrefix("Reconnect")
                || text.hasPrefix("Apple Account") else { return nil }
        return SyncProblemWords.split(text)
    }

    private var remainingMigration: String? {
        guard let record = sync.migrationRecord, record.switchedAt != nil, record.completedAt == nil,
              !record.abandoned, record.remainingFiles > 0 else { return nil }
        return "Copying \(record.remainingFiles) more \(record.remainingFiles == 1 ? "file" : "files") from the previous sync folder"
    }

    private static func openAccountSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    // MARK: Development folder

    /// The folder transport, for development builds without iCloud (and libraries connected in tests).
    @ViewBuilder private var folderRows: some View {
        if let folder = sync.folder {
            LabeledContent("Folder") {
                Text(SettingsPath.display(folder))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.path)
                    .frame(maxWidth: 400, alignment: .trailing)
            }
            LabeledContent("Status") {
                HStack(spacing: Space.s3) {
                    if sync.isSyncing { ProgressView().controlSize(.small) }
                    Text(connectedStatus).foregroundStyle(.secondary).monospacedDigit()
                    Button("Sync Now") { Task { await state.synchronizeLibrary() } }
                        .disabled(sync.isSyncing)
                }
            }
            if let problem { SyncWarning(text: problem.text, details: problem.details) }
            ForEach(Array(sync.warnings.enumerated()), id: \.offset) { _, warning in
                SyncWarning(text: warning)
            }
            Toggle("Transcribe synced recordings on this Mac", isOn: $state.processSyncedAudio)
                .controlSize(.regular)
            HStack {
                Spacer()
                Button("Turn Off Sync…") { confirmingTurnOff = true }
                    .disabled(sync.isSyncing)
            }
        } else {
            LabeledContent {
                Button("Choose Folder…") { sync.chooseFolder() }
            } label: {
                Text("Sync through a folder")
                Text("Development builds without iCloud only.")
            }
        }
    }
}

/// An inline sync warning: a warning glyph, one sentence, and at most one action.
private struct SyncWarning<Action: View>: View {
    let text: String
    /// The system's own words, behind Details….
    var details: String?
    @ViewBuilder var action: Action
    @State private var showingDetails = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Ink.warning)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s3)
            if let details {
                Button("Details…") { showingDetails = true }
                    .popover(isPresented: $showingDetails) {
                        Text(details).font(.callout).textSelection(.enabled).padding(14).frame(width: 320, alignment: .leading)
                    }
            }
            action
        }
    }
}

extension SyncWarning where Action == EmptyView {
    init(text: String, details: String? = nil) { self.init(text: text, details: details) { EmptyView() } }
}

/// "Sync paused: <the system's words>" as a sentence, with the words for Details.
enum SyncProblemWords {
    static func split(_ status: String) -> (text: String, details: String?) {
        guard let range = status.range(of: ": ") else { return (status, nil) }
        let head = String(status[..<range.lowerBound]), reason = String(status[range.upperBound...])
        let text = head == "Sync paused" ? "Sync is paused." : head + "."
        return (text, reason.isEmpty ? nil : reason)
    }
}

/// A neutral line of sync information.
private struct SyncNote: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
