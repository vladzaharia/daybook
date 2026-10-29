import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// Settings › Library › iCloud Sync › Encryption (docs/icloud-sync.md, "Encryption"): whether the library in iCloud is
/// encrypted, turning it on, its recovery key, and waiting for its key. The section passes what the sync controller and
/// the phone link say (`SyncShown`); erasing deleted conversations sits under the section with Turn Off Sync….
struct SyncEncryptionRows: View {
    let state: AppState
    let shown: SyncShown
    /// The section's one problem line.
    @Binding var problem: AppProblem?
    @State private var enabling = false
    @State private var shownKey: ShownRecoveryKey?
    @State private var enteringKey = false
    @State private var confirmingFolder = false
    @State private var confirmingStartOver = false

    private var sync: LibrarySyncController { state.sync }

    var body: some View {
        Group {
            switch shown.encryption {
            case .unavailable:
                EmptyView()
            case .off:
                LabeledContent("Encryption") {
                    HStack(spacing: Space.s3) {
                        Text("Off").foregroundStyle(.secondary)
                        Button("Turn On…") { enabling = true }
                            .disabled(shown.isSyncing || shown.folder == nil)
                    }
                }
            case .waitingForKey:
                ProblemLine(text: "Turn on iCloud Keychain, or get the key from another device.", symbol: "lock.icloud.fill") {
                    ForEach(shown.keyPeers) { phone in
                        Button("Get Key from \(phone.name)") { Task { await state.requestLibraryKey(from: phone.id) } }
                    }
                    Button("Enter Recovery Key…") { enteringKey = true }
                    if shown.mayStartOverEncryption {
                        Button("Start Over…") { confirmingStartOver = true }
                    }
                }
            case .on(let status, let hasRecoveryKey):
                LabeledContent("Encryption") {
                    Text(status).foregroundStyle(.secondary).monospacedDigit()
                }
                LabeledContent("Recovery key") {
                    if hasRecoveryKey {
                        Text("Saved").foregroundStyle(.secondary)
                    } else {
                        Button("Create Recovery Key…") { createRecoveryKey() }
                    }
                }
                if shown.hasRetiredFolderJournal {
                    LabeledContent("Previous sync folder") {
                        Button("Delete Its Copy…") { confirmingFolder = true }
                    }
                }
            }
        }
        #if DEBUG
        // `--sync-sheet encrypt|recovery-key|enter-key` opens one of the sheets, with `--sync-demo`.
        .task {
            switch LaunchOptions.value(after: "--sync-sheet") {
            case "encrypt"?: enabling = true
            case "recovery-key"?: shownKey = ShownRecoveryKey(key: RecoveryKey.generate())
            case "enter-key"?: enteringKey = true
            default: break
            }
        }
        #endif
        .sheet(isPresented: $enabling) {
            EncryptLibrarySheet(state: state) { recovery in shownKey = ShownRecoveryKey(key: recovery) }
        }
        .sheet(item: $shownKey) { shown in RecoveryKeySheet(key: shown.key) }
        .sheet(isPresented: $enteringKey) { EnterRecoveryKeySheet(state: state) }
        .alert("Start over with a new key?", isPresented: $confirmingStartOver) {
            Button("Start Over", role: .destructive) { startOver() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(LibraryWords.startOverConsequence)
        }
        .alert("Delete the previous sync folder’s copy?", isPresented: $confirmingFolder) {
            Button("Delete", role: .destructive) {
                problem = nil
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
                problem = AppProblem(title: "Couldn’t Create a Recovery Key", fallback: "A recovery key couldn’t be created. Try again.", error: error)
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
        .padding(Space.s5)
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
        .padding(Space.s5)
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
        .padding(Space.s5)
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
