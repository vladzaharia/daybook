import DaybookKit
import SwiftUI
import UIKit

/// Settings › iCloud › encryption (docs/icloud-sync.md, "Encryption"): turning it on, the recovery key, waiting for the
/// library's key, and erasing deleted conversations.
struct EncryptionRows: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var enabling = false
    @State private var shownKey: ShownRecoveryKey?
    @State private var enteringKey = false
    @State private var confirmingErase = false
    @State private var confirmingStartOver = false
    @State private var problem: ReadingAlert?

    var body: some View {
        Group {
            switch model.sync.encryption {
            case .unavailable:
                EmptyView()
            case .off:
                Button("Encrypt Library in iCloud…") { enabling = true }
                    .disabled(model.sync.isSyncing)
            case .waitingForKey:
                ForEach(model.link.connectedMacs) { mac in
                    Button("Get Key from \(mac.name)") { Task { await model.requestLibraryKey(from: mac.id) } }
                }
                Button("Enter Recovery Key…") { enteringKey = true }
                if model.sync.mayStartOver {
                    Button("Start Over…", role: .destructive) { confirmingStartOver = true }
                }
            case .on(let summary):
                LabeledContent("Encryption", value: LibraryWords.encryptionStatus(summary))
                if summary.hasRecoveryKey {
                    LabeledContent("Recovery Key", value: "Saved")
                } else {
                    Button("Create Recovery Key…") { createRecoveryKey() }
                }
                Button("Erase Deleted Conversations from iCloud…", role: .destructive) { confirmingErase = true }
                    .disabled(model.sync.isSyncing)
            }
            if let problem { ProblemText(problem: problem) }
        }
        .sheet(isPresented: $enabling) {
            EncryptLibraryScreen { recovery in shownKey = recovery.map(ShownRecoveryKey.init(key:)) }
        }
        .sheet(item: $shownKey) { shown in RecoveryKeyScreen(key: shown.key) }
        .sheet(isPresented: $enteringKey) { EnterRecoveryKeyScreen() }
        .confirmationDialog("Erase deleted conversations from iCloud?", isPresented: $confirmingErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { erase() }
        } message: {
            Text("This can’t be undone.")
        }
        .confirmationDialog("Start over with a new key?", isPresented: $confirmingStartOver, titleVisibility: .visible) {
            Button("Start Over", role: .destructive) { startOver() }
        } message: {
            Text(LibraryWords.startOverConsequence)
        }
    }

    private func createRecoveryKey() {
        problem = nil
        Task {
            guard let controller = model.sync.controller else { return }
            do { shownKey = ShownRecoveryKey(key: try await controller.createRecoveryKey()) } catch {
                problem = ReadingAlert(title: "Couldn’t Create a Recovery Key", error: error, fallback: "A recovery key couldn’t be created. Try again.")
            }
        }
    }

    private func startOver() {
        problem = nil
        Task {
            do { try await model.sync.controller?.startOverEncryption() } catch {
                problem = ReadingAlert(title: "Couldn’t Start Over", error: error, fallback: "The library couldn’t start over. Try again.")
            }
        }
    }

    private func erase() {
        problem = nil
        Task {
            do { try await model.sync.controller?.rotateEncryptionKey() } catch {
                problem = ReadingAlert(title: "Couldn’t Erase", error: error, fallback: "Deleted conversations couldn’t be erased from iCloud. Try again once sync is up to date.")
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
private struct EncryptLibraryScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onDone: (RecoveryKey?) -> Void
    @State private var notReady: [KnownSyncDevice]?
    @State private var createsRecoveryKey = true
    @State private var working = false
    @State private var problem: ReadingAlert?

    var body: some View {
        NavigationStack {
            Form {
                if let notReady, !notReady.isEmpty {
                    Section {
                        ForEach(notReady) { device in
                            Text(device.displayName ?? "A device that hasn’t checked in")
                        }
                    } header: {
                        Text("Stop Syncing Until Updated")
                    }
                }
                Section {
                    Toggle("Create a Recovery Key", isOn: $createsRecoveryKey)
                } footer: {
                    if let problem { ProblemText(problem: problem) }
                }
            }
            .navigationTitle("Encrypt Library in iCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Encrypt") { encrypt() }.disabled(working || notReady == nil)
                }
            }
            .task { notReady = await model.sync.controller?.devicesNotReadyForEncryption() ?? [] }
        }
    }

    private func encrypt() {
        guard let controller = model.sync.controller else { return }
        working = true; problem = nil
        let recovery = createsRecoveryKey ? RecoveryKey.generate() : nil
        Task {
            do {
                try await controller.enableEncryption(recoveryKey: recovery)
                dismiss()
                onDone(recovery)
            } catch {
                problem = ReadingAlert(title: "Couldn’t Encrypt", error: error, fallback: "The library couldn’t be encrypted. Try again.")
            }
            working = false
        }
    }
}

/// A recovery key, shown once: the person saves it.
private struct RecoveryKeyScreen: View {
    let key: RecoveryKey
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(key.text)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(key.text.map(String.init).joined(separator: " "))
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = key.text
                        copied = true
                    }
                }
            }
            .navigationTitle("Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .interactiveDismissDisabled()
    }
}

/// Typing a recovery key while waiting for the library's key.
private struct EnterRecoveryKeyScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: ReadingAlert?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recovery Key", text: $text)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    if let problem { ProblemText(problem: problem) }
                }
            }
            .navigationTitle("Enter Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { open() }.disabled(working || RecoveryKey(text) == nil)
                }
            }
        }
    }

    private func open() {
        guard let controller = model.sync.controller else { return }
        working = true; problem = nil
        Task {
            do {
                if try await controller.enterRecoveryKey(text) { dismiss() } else { problem = ReadingAlert(title: "Wrong Recovery Key", message: "That recovery key doesn’t match this library.") }
            } catch {
                problem = ReadingAlert(title: "Couldn’t Check the Key", error: error, fallback: "The recovery key couldn’t be checked. Try again.")
            }
            working = false
        }
    }
}

/// A problem shown in place: one plain sentence, and the system's own words behind Details, in the sheet every other
/// problem on this iPhone opens.
private struct ProblemText: View {
    let problem: ReadingAlert
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(problem.message)
                .font(.footnote)
                .foregroundStyle(PhoneStyle.Ink.warning)
            if let details = problem.details {
                Button("Details") { showingDetails = true }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .sheet(isPresented: $showingDetails) { DetailsSheet(title: "Details", text: details) }
            }
        }
    }
}
