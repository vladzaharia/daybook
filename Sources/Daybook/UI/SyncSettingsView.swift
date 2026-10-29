import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// Settings › Library › iCloud Sync (Direction A §5.14). Sync uses Daybook's own iCloud container, so
/// there's no folder to choose: the section says what iCloud is doing. Development builds without iCloud
/// can bring back a chosen folder with `LibrarySyncController.developmentFolderSyncKey`.
///
/// One row says where sync stands, with its one action ("Up to date · 11:42 AM", Sync Now); a problem follows it in
/// place, with its fix; then encryption and this Mac's preference. Turning sync off and erasing sit under the group,
/// as System Settings places such buttons.
struct SyncSettingsView: View {
    @ObservedObject var state: AppState
    /// Followed directly: the window doesn't redraw for every sync status change.
    @ObservedObject private var sync: LibrarySyncController
    /// For Get Key from <iPhone> while waiting for the library's key.
    @ObservedObject private var phoneLink: PhoneLink
    @State private var confirmingTurnOff = false
    @State private var confirmingAccount = false
    @State private var confirmingSkip = false
    @State private var confirmingErase = false
    /// Something the person asked for here that couldn't be done.
    @State private var problem: AppProblem?

    init(state: AppState) {
        self.state = state
        sync = state.sync
        phoneLink = state.phoneLink
    }

    private var shown: SyncShown {
        #if DEBUG
        if let demo = SyncSettingsDemo.shown { return demo }
        #endif
        return SyncShown(sync, peers: phoneLink.peers.values.map { SyncShown.KeyPeer(id: $0.deviceID, name: $0.name) })
    }

    var body: some View {
        let shown = shown
        Section {
            if shown.isFolderTransport {
                folderRows(shown)
            } else {
                iCloudRows(shown)
            }
            if let problem { ProblemLine(problem: problem) }
        } header: {
            Text("iCloud Sync")
        } footer: {
            footer(shown)
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
        .alert("Erase deleted conversations from iCloud?", isPresented: $confirmingErase) {
            Button("Erase", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can’t be undone.")
        }
    }

    // MARK: iCloud

    @ViewBuilder private func iCloudRows(_ shown: SyncShown) -> some View {
        LabeledContent("iCloud") {
            HStack(spacing: Space.s3) {
                if shown.isBusy { ProgressView().controlSize(.small) }
                Text(shown.headline).foregroundStyle(.secondary).monospacedDigit()
                headlineAction(shown)
            }
        }
        switch shown.iCloud {
        case .migrating(let progress) where progress.total > 0:
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                .progressViewStyle(.brand(width: nil))
                .accessibilityLabel("Moving your library to iCloud")
        case .connected:
            connectedRows(shown)
        case .waitingForKey:
            SyncEncryptionRows(state: state, shown: shown, problem: $problem)
        case .accountChanged:
            ProblemLine(text: "This library synced with a different iCloud account.") {
                Button("Sync with This Account…") { confirmingAccount = true }
            }
        case .previousFolderAccessLost(let location):
            ProblemLine(text: "Can’t open the folder this Mac synced through before.") {
                Button("Choose Folder Again…") { sync.choosePreviousFolderAgain(near: location) }
                Button("Sync Without It…") { confirmingSkip = true }
            }
        case .previousFolderMissing:
            ProblemLine(text: "Can’t find the folder this Mac synced through before.") {
                Button("Try Again") { sync.retryContainer() }
                Button("Sync Without It…") { confirmingSkip = true }
            }
        default:
            EmptyView()
        }
    }

    /// The status row's one action: what moves sync on from where it stands.
    @ViewBuilder private func headlineAction(_ shown: SyncShown) -> some View {
        switch shown.iCloud {
        case .connected, .waitingForKey:
            Button("Sync Now") { Task { await state.synchronizeLibrary() } }
                .disabled(shown.isSyncing)
        case .iCloudDriveOff, .signedOut:
            Button("Open System Settings…") { Self.openAccountSettings() }
        case .turnedOff:
            Button("Turn On") { sync.turnOnICloudSync() }
        case .containerUnavailable(let reason):
            if !reason.isEmpty { DetailsButton(details: reason) }
            Button("Try Again") { sync.retryContainer() }
        default:
            EmptyView()
        }
    }

    /// Connected: a paused or failed pass and the warnings, in place; encryption; and this Mac's preference.
    @ViewBuilder private func connectedRows(_ shown: SyncShown) -> some View {
        if let problem = shown.problem { ProblemLine(text: problem.text, details: problem.details) }
        if let remaining = shown.remainingMigration { Text(remaining).foregroundStyle(.secondary) }
        ForEach(Array(shown.warnings.enumerated()), id: \.offset) { _, warning in
            let words = SyncWarningWords.split(warning)
            ProblemLine(text: words.text, details: words.details)
        }
        SyncEncryptionRows(state: state, shown: shown, problem: $problem)
        Toggle("Transcribe synced recordings on this Mac", isOn: $state.processSyncedAudio)
            .controlSize(.regular)
    }

    /// Under the group: a fix for iCloud Drive, or, while syncing, erasing and turning sync off.
    @ViewBuilder private func footer(_ shown: SyncShown) -> some View {
        if let footer = shown.footer {
            SettingsFooter(footer)
        } else if shown.isConnected {
            HStack(spacing: Space.s2) {
                Spacer()
                if shown.encryption.isOn {
                    Button("Erase Deleted Conversations from iCloud…") { confirmingErase = true }
                        .disabled(shown.isSyncing)
                }
                Button("Turn Off Sync…") { confirmingTurnOff = true }
                    .disabled(shown.isSyncing)
            }
            .padding(.top, Space.s1)
        }
    }

    private func erase() {
        problem = nil
        Task {
            do { try await sync.rotateEncryptionKey() } catch {
                problem = AppProblem(title: "Couldn’t Erase", fallback: "Deleted conversations couldn’t be erased from iCloud. Try again once sync is up to date.", error: error)
            }
        }
    }

    private static func openAccountSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    // MARK: Development folder

    /// The folder transport, for development builds without iCloud (and libraries connected in tests).
    @ViewBuilder private func folderRows(_ shown: SyncShown) -> some View {
        if let folder = shown.folder {
            LabeledContent("Folder") {
                Text(SettingsPath.display(folder))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.path)
            }
            LabeledContent("Status") {
                HStack(spacing: Space.s3) {
                    if shown.isSyncing { ProgressView().controlSize(.small) }
                    Text(shown.connectedStatus).foregroundStyle(.secondary).monospacedDigit()
                    Button("Sync Now") { Task { await state.synchronizeLibrary() } }
                        .disabled(shown.isSyncing)
                }
            }
            connectedRows(shown)
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

// MARK: - Words

/// What the iCloud Sync section shows, as plain values: from the sync controller, or from a demo (`--sync-demo`). The
/// words it makes are tested (`SyncSettingsWordsTests`).
struct SyncShown {
    struct KeyPeer: Identifiable, Equatable {
        var id: UUID
        var name: String
    }

    var iCloud: ICloudSyncState
    /// The development folder transport instead of iCloud.
    var isFolderTransport = false
    var folder: URL?
    var isSyncing = false
    var pendingDownloads = 0
    var lastSync: Date?
    /// The controller's status line, which carries a paused or failed pass.
    var status = ""
    var warnings: [String] = []
    var migration: SyncMigrationRecord?
    var encryption: EncryptionShown = .unavailable
    var mayStartOverEncryption = false
    var hasRetiredFolderJournal = false
    /// Devices that can send the library's key.
    var keyPeers: [KeyPeer] = []

    init(iCloud: ICloudSyncState) { self.iCloud = iCloud }

    @MainActor init(_ sync: LibrarySyncController, peers: [KeyPeer]) {
        iCloud = sync.iCloud
        isFolderTransport = sync.transport == .folder || sync.allowsFolderSync
        folder = sync.folder
        isSyncing = sync.isSyncing
        pendingDownloads = sync.pendingDownloads
        lastSync = sync.lastSync
        status = sync.status
        warnings = sync.warnings
        migration = sync.migrationRecord
        encryption = EncryptionShown(sync.encryption)
        mayStartOverEncryption = sync.mayStartOverEncryption
        hasRetiredFolderJournal = sync.hasRetiredFolderJournal
        keyPeers = peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Syncing through iCloud or a folder: Turn Off Sync… applies.
    var isConnected: Bool { folder != nil && (isFolderTransport || iCloud == .connected) }

    /// The iCloud row's value: one phrase for where sync stands.
    var headline: String {
        switch iCloud {
        case .checking: return "Checking…"
        case .connected: return connectedStatus
        case .waitingForKey: return "Waiting for this library’s key"
        case .iCloudDriveOff: return "iCloud Drive is off"
        case .signedOut: return "Signed out"
        case .migrating(let progress):
            return progress.total > 0 ? "Moving to iCloud · \(progress.completed) of \(progress.total) files" : "Moving to iCloud…"
        case .accountChanged, .previousFolderMissing, .previousFolderAccessLost: return "Paused"
        case .containerUnavailable: return "Not available right now"
        case .turnedOff: return "Off"
        case .unavailableInThisBuild: return "Not available in this build"
        }
    }

    var isBusy: Bool {
        switch iCloud {
        case .checking, .migrating: return true
        case .connected: return isSyncing
        default: return false
        }
    }

    /// The copy deck's sync states: Up to date · 11:42 AM, Syncing…, Waiting for iCloud to download 3 items…. With a
    /// problem, the line under the row says what's wrong, so the row says only when sync last finished.
    var connectedStatus: String {
        if isSyncing { return "Syncing…" }
        if pendingDownloads > 0 {
            return "Waiting for iCloud to download \(pendingDownloads) \(pendingDownloads == 1 ? "item" : "items")…"
        }
        guard let date = lastSync else { return problem == nil ? "Waiting to sync" : "Not synced yet" }
        let time = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return problem == nil ? "Up to date · \(time)" : "Last synced \(time)"
    }

    /// A paused or failed pass, in place: what happened, with the reason behind Details.
    var problem: (text: String, details: String?)? {
        guard status.hasPrefix("Sync paused") || status.hasPrefix("Couldn") || status.hasPrefix("Reconnect")
                || status.hasPrefix("Apple Account") else { return nil }
        return SyncProblemWords.split(status)
    }

    var remainingMigration: String? {
        guard let record = migration, record.switchedAt != nil, record.completedAt == nil,
              !record.abandoned, record.remainingFiles > 0 else { return nil }
        return "Copying \(record.remainingFiles) more \(record.remainingFiles == 1 ? "file" : "files") from the previous sync folder"
    }

    /// The fix the status row's button can't give on its own: where iCloud Drive is turned on.
    var footer: String? {
        iCloud == .iCloudDriveOff ? "Turn it on in System Settings › Apple Account › iCloud." : nil
    }
}

/// Whether the library in iCloud is encrypted, as the section shows it.
enum EncryptionShown: Equatable {
    /// This build can't keep library keys: nothing to show.
    case unavailable
    case off
    case waitingForKey
    /// "On", or how much is left to encrypt; and whether a recovery key was saved.
    case on(status: String, hasRecoveryKey: Bool)

    init(_ state: LibraryEncryptionState) {
        switch state {
        case .unavailable: self = .unavailable
        case .off: self = .off
        case .waitingForKey: self = .waitingForKey
        case .on(let summary): self = .on(status: LibraryWords.encryptionStatus(summary), hasRecoveryKey: summary.hasRecoveryKey)
        }
    }

    var isOn: Bool { if case .on = self { return true } else { return false } }
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

// MARK: - Demos

#if DEBUG
/// Debug-only: `--sync-demo <state>` shows Settings › Library's iCloud Sync section in that state, without iCloud, for
/// screenshots. Its buttons still act on the real (unconnected) controller. States: checking, off, signed-out,
/// drive-off, unavailable, moving, on, syncing, downloading, paused, warning, account, folder-lost, folder-missing,
/// waiting, encrypted, no-recovery-key, encrypting, dev-folder.
@MainActor
enum SyncSettingsDemo {
    static let scenario = LaunchOptions.value(after: "--sync-demo")

    static var shown: SyncShown? {
        guard let scenario else { return nil }
        let folder = URL(fileURLWithPath: "/Users/demo/Library/Mobile Documents/iCloud~local~daybook/Documents/Daybook")
        func connected(_ change: (inout SyncShown) -> Void = { _ in }) -> SyncShown {
            var shown = SyncShown(iCloud: .connected)
            shown.folder = folder
            shown.lastSync = Calendar.current.date(bySettingHour: 11, minute: 42, second: 0, of: Date())
            shown.encryption = .off
            change(&shown)
            return shown
        }
        switch scenario {
        case "checking": return SyncShown(iCloud: .checking)
        case "off": return SyncShown(iCloud: .turnedOff)
        case "signed-out": return SyncShown(iCloud: .signedOut)
        case "drive-off": return SyncShown(iCloud: .iCloudDriveOff)
        case "unavailable": return SyncShown(iCloud: .containerUnavailable("The operation couldn’t be completed. (CKErrorDomain error 4.)"))
        case "moving":
            var progress = SyncMigrationProgress()
            progress.total = 412; progress.completed = 157
            return SyncShown(iCloud: .migrating(progress))
        case "on": return connected()
        case "syncing": return connected { $0.isSyncing = true }
        case "downloading": return connected { $0.pendingDownloads = 3 }
        case "paused": return connected { $0.status = "Sync paused: The operation couldn’t be completed. No space left on device." }
        case "warning": return connected { $0.warnings = [SyncWarningWords.unsavedChange + ": The file “events-0042.json” couldn’t be saved."] }
        case "account": return SyncShown(iCloud: .accountChanged)
        case "folder-lost": return SyncShown(iCloud: .previousFolderAccessLost(nil))
        case "folder-missing": return SyncShown(iCloud: .previousFolderMissing)
        case "waiting":
            var shown = SyncShown(iCloud: .waitingForKey)
            shown.folder = folder
            shown.encryption = .waitingForKey
            shown.mayStartOverEncryption = true
            shown.keyPeers = [.init(id: UUID(), name: "Alex’s iPhone")]
            return shown
        case "encrypted": return connected { $0.encryption = .on(status: "On", hasRecoveryKey: true) }
        case "no-recovery-key":
            return connected { $0.encryption = .on(status: "On", hasRecoveryKey: false); $0.hasRetiredFolderJournal = true }
        case "encrypting": return connected { $0.encryption = .on(status: "Encrypting · 128 left", hasRecoveryKey: true) }
        case "dev-folder":
            return connected { $0.isFolderTransport = true; $0.folder = URL(fileURLWithPath: NSHomeDirectory() + "/Daybook Sync") }
        default: return nil
        }
    }
}
#endif
