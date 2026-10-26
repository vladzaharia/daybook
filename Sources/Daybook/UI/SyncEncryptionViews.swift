import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// Settings › Library › iCloud Sync › Encryption (docs/icloud-sync.md, "Encryption"): whether the library in iCloud is
/// encrypted, turning it on, its recovery key, waiting for its key, and erasing deleted conversations. It observes the
/// sync controller and the phone link itself, so it follows them whether or not the app state passes their changes on.
struct SyncEncryptionRows: View {
    let state: AppState
    @ObservedObject var sync: LibrarySyncController
    @ObservedObject var phoneLink: PhoneLink
    @State private var enabling = false
    @State private var shownKey: ShownRecoveryKey?
    @State private var enteringKey = false
    @State private var confirmingErase = false
    @State private var confirmingFolder = false
    @State private var confirmingStartOver = false
    @State private var problem: AppProblem?

    init(state: AppState) {
        self.state = state
        sync = state.sync
        phoneLink = state.phoneLink
    }

    var body: some View {
        Group {
            switch sync.encryption {
            case .unavailable:
                EmptyView()
            case .off:
                LabeledContent("Encryption") {
                    HStack(spacing: Space.s3) {
                        Text("Off").foregroundStyle(.secondary)
                        Button("Encrypt Library in iCloud…") { enabling = true }
                            .disabled(sync.isSyncing || sync.folder == nil)
                    }
                }
            case .waitingForKey:
                EncryptionWarning(text: LibrarySyncError.keyUnavailable("").localizedDescription) {
                    HStack {
                        ForEach(phoneLink.peers.values.sorted { $0.name < $1.name }) { phone in
                            Button("Get Key from \(phone.name)") { Task { await state.requestLibraryKey(from: phone.deviceID) } }
                        }
                        Button("Enter Recovery Key…") { enteringKey = true }
                        if sync.mayStartOverEncryption {
                            Button("Start Over…") { confirmingStartOver = true }
                        }
                    }
                }
            case .on(let summary):
                LabeledContent("Encryption") {
                    Text(LibraryWords.encryptionStatus(summary)).foregroundStyle(.secondary).monospacedDigit()
                }
                LabeledContent("Recovery Key") {
                    if summary.hasRecoveryKey {
                        Text("Saved").foregroundStyle(.secondary)
                    } else {
                        Button("Create Recovery Key…") { createRecoveryKey() }
                    }
                }
                if sync.hasRetiredFolderJournal {
                    LabeledContent("Previous Sync Folder") {
                        Button("Delete Its Copy…") { confirmingFolder = true }
                    }
                }
                HStack {
                    Spacer()
                    Button("Erase Deleted Conversations from iCloud…") { confirmingErase = true }
                        .disabled(sync.isSyncing)
                }
            }
            if let problem { ProblemLine(problem: problem) }
        }
        .sheet(isPresented: $enabling) {
            EncryptLibrarySheet(state: state) { recovery in shownKey = ShownRecoveryKey(key: recovery) }
        }
        .sheet(item: $shownKey) { shown in RecoveryKeySheet(key: shown.key) }
        .sheet(isPresented: $enteringKey) { EnterRecoveryKeySheet(state: state) }
        .alert("Erase deleted conversations from iCloud?", isPresented: $confirmingErase) {
            Button("Erase", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can’t be undone.")
        }
        .alert("Start over with a new key?", isPresented: $confirmingStartOver) {
            Button("Start Over", role: .destructive) { startOver() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(LibraryWords.startOverConsequence)
        }
        .alert("Delete the previous sync folder’s copy?", isPresented: $confirmingFolder) {
            Button("Delete", role: .destructive) {
                do { try sync.deleteRetiredFolderJournal() } catch {
                    problem = AppProblem(title: "Couldn’t Delete the Copy", fallback: "The previous sync folder’s copy couldn’t be deleted. Try again.", error: error)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private func createRecoveryKey() {
        problem = nil
        Task {
            do { shownKey = ShownRecoveryKey(key: try await sync.createRecoveryKey()) } catch {
                problem = AppProblem(title: "Couldn’t Make a Recovery Key", fallback: "A recovery key couldn’t be made. Try again.", error: error)
            }
        }
    }

    private func startOver() {
        problem = nil
        Task {
            do { try await sync.startOverEncryption() } catch {
                problem = AppProblem(title: "Couldn’t Start Over", fallback: "The library couldn’t start over. Try again.", error: error)
            }
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
}

/// A recovery key to show, once.
private struct ShownRecoveryKey: Identifiable {
    let key: RecoveryKey
    var id: String { key.text }
}

/// Turning encryption on: the devices that would stop syncing, a recovery key, and Encrypt.
private struct EncryptLibrarySheet: View {
    @ObservedObject var state: AppState
    let onRecoveryKey: (RecoveryKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notReady: [KnownSyncDevice]?
    @State private var createsRecoveryKey = true
    @State private var working = false
    @State private var problem: AppProblem?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Encrypt Library in iCloud").font(.headline)
            if let notReady, !notReady.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Stop syncing until they’re updated:").foregroundStyle(.secondary)
                    ForEach(notReady) { device in
                        Label(device.displayName ?? "A device that hasn’t checked in", systemImage: Self.symbol(device))
                    }
                }
            } else if notReady == nil {
                ProgressView().controlSize(.small)
            }
            Toggle("Create a recovery key", isOn: $createsRecoveryKey)
            if let problem { ProblemLine(problem: problem) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Encrypt") { encrypt() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || notReady == nil)
            }
        }
        .padding(Space.s6)
        .frame(width: 420)
        .task { notReady = await state.sync.devicesNotReadyForEncryption() }
    }

    private func encrypt() {
        working = true; problem = nil
        let recovery = createsRecoveryKey ? RecoveryKey.generate() : nil
        Task {
            do {
                try await state.sync.enableEncryption(recoveryKey: recovery)
                dismiss()
                if let recovery { onRecoveryKey(recovery) }
            } catch {
                problem = AppProblem(title: "Couldn’t Encrypt", fallback: "The library couldn’t be encrypted. Try again.", error: error)
            }
            working = false
        }
    }

    static func symbol(_ device: KnownSyncDevice) -> String {
        switch device.deviceClass {
        case .mac?: return "desktopcomputer"
        case .phone?: return "iphone"
        default: return "questionmark.app.dashed"
        }
    }
}

/// A recovery key, shown once: the person saves it.
private struct RecoveryKeySheet: View {
    let key: RecoveryKey
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Recovery Key").font(.headline)
            Text(key.text)
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel(key.text.map(String.init).joined(separator: " "))
            HStack {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key.text, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s6)
        .frame(width: 420)
    }
}

/// Typing a recovery key while waiting for the library's key.
private struct EnterRecoveryKeySheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: AppProblem?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Enter Recovery Key").font(.headline)
            TextField("Recovery key", text: $text)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            if let problem { ProblemLine(problem: problem) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || RecoveryKey(text) == nil)
            }
        }
        .padding(Space.s6)
        .frame(width: 420)
    }

    private func open() {
        working = true; problem = nil
        Task {
            do {
                if try await state.sync.enterRecoveryKey(text) { dismiss() } else { problem = AppProblem(title: "Wrong Recovery Key", message: "That recovery key doesn’t match this library.") }
            } catch {
                problem = AppProblem(title: "Couldn’t Check the Key", fallback: "The recovery key couldn’t be checked. Try again.", error: error)
            }
            working = false
        }
    }
}

/// A warning line with its actions, as the sync section shows them.
private struct EncryptionWarning<Action: View>: View {
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: "lock.icloud")
                .foregroundStyle(Ink.warning)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s3)
            action
        }
    }
}

/// A problem shown in place: one plain sentence, and the system's own words behind Details.
private struct ProblemLine: View {
    let problem: AppProblem
    @State private var showingDetails = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Ink.warning)
                .accessibilityHidden(true)
            Text(problem.message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s3)
            if let details = problem.details {
                Button("Details…") { showingDetails = true }
                    .popover(isPresented: $showingDetails) {
                        Text(details)
                            .textSelection(.enabled)
                            .padding(Space.s4)
                            .frame(maxWidth: 360, alignment: .leading)
                    }
            }
        }
    }
}
