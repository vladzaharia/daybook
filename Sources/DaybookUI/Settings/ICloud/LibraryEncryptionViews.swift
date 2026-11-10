import DaybookDesign
import DaybookKit
import SwiftUI

// Encrypting the library in iCloud (docs/icloud-sync.md, "Encryption"), the same on both apps: turning it on, its
// recovery key, and typing one in while waiting for the library's key. Each is a `SettingsFormSheet`.

/// A sheet iCloud Sync opens. The Mac presents each as a 420 pt sheet; the iPhone as a page sheet, and it pushes the
/// library's devices instead.
public enum ICloudSyncSheet: Identifiable, Equatable {
    case encrypt
    /// A recovery key, shown once.
    case recoveryKey(RecoveryKey)
    case enterRecoveryKey
    /// Every device that syncs the library (the Mac's; the iPhone pushes them).
    case devices

    public var id: String {
        switch self {
        case .encrypt: return "encrypt"
        case .recoveryKey(let key): return "recovery-\(key.text)"
        case .enterRecoveryKey: return "enter-key"
        case .devices: return "devices"
        }
    }
}

/// What a sheet of iCloud Sync's shows, ready for either app's presentation.
public struct ICloudSyncSheetContent: View {
    private let sheet: ICloudSyncSheet
    private let controller: LibrarySyncController?
    private let devices: [KnownSyncDevice]
    private let refreshDevices: @MainActor () async -> Void
    private let present: @MainActor (ICloudSyncSheet?) -> Void

    /// - Parameters:
    ///   - controller: The sync controller the sheets act on.
    ///   - devices: The library's devices, for `.devices`.
    ///   - present: Shows another sheet (a recovery key once encryption is on), or none.
    public init(_ sheet: ICloudSyncSheet, controller: LibrarySyncController?, devices: [KnownSyncDevice] = [],
                refreshDevices: @escaping @MainActor () async -> Void = {}, present: @escaping @MainActor (ICloudSyncSheet?) -> Void) {
        self.sheet = sheet
        self.controller = controller
        self.devices = devices
        self.refreshDevices = refreshDevices
        self.present = present
    }

    public var body: some View {
        switch sheet {
        case .encrypt:
            EncryptLibraryForm(controller: controller, done: { recovery in present(recovery.map(ICloudSyncSheet.recoveryKey)) },
                               cancel: { present(nil) })
        case .recoveryKey(let key):
            RecoveryKeyView(key: key) { present(nil) }
        case .enterRecoveryKey:
            EnterRecoveryKeyForm(controller: controller) { present(nil) }
        case .devices:
            SettingsFormSheet(title: "Devices", cancel: nil, confirm: .init("Done") { present(nil) }) {
                LibraryDevicesSection(devices: devices)
            }
            .task { await refreshDevices() }
        }
    }
}

/// Turning encryption on: the devices that would stop syncing until they're updated, a recovery key, and Encrypt.
public struct EncryptLibraryForm: View {
    private let controller: LibrarySyncController?
    private let done: @MainActor (RecoveryKey?) -> Void
    private let cancel: @MainActor () -> Void
    @State private var notReady: [KnownSyncDevice]?
    @State private var createsRecoveryKey = true
    @State private var working = false
    @State private var problem: SyncSettingsProblem?
    @Environment(\.daybookDensity) private var density

    /// - Parameter done: Encryption is on, with the recovery key made for it, if one was asked for.
    public init(controller: LibrarySyncController?, done: @escaping @MainActor (RecoveryKey?) -> Void, cancel: @escaping @MainActor () -> Void) {
        self.controller = controller
        self.done = done
        self.cancel = cancel
    }

    public var body: some View {
        SettingsFormSheet(title: "Encrypt Library", cancel: .init("Cancel", perform: cancel),
                          confirm: .init("Encrypt", isEnabled: !working && notReady != nil && controller != nil, perform: encrypt)) {
            if let notReady, !notReady.isEmpty {
                Section {
                    ForEach(notReady) { device in
                        Label(LibraryDeviceWords.name(device), systemImage: device.systemImage)
                    }
                } header: {
                    Text(SyncSettingsCase.label("Stop syncing until they’re updated", density))
                }
            } else if notReady == nil {
                Section { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            }
            Section {
                Toggle(SyncSettingsCase.label("Create a recovery key", density), isOn: $createsRecoveryKey)
                if let problem { ProblemLine(text: problem.message, details: problem.details) }
            }
        }
        .task { notReady = await controller?.devicesNotReadyForEncryption() ?? [] }
    }

    private func encrypt() {
        guard let controller, !working else { return }
        working = true; problem = nil
        let recovery = createsRecoveryKey ? RecoveryKey.generate() : nil
        Task {
            do {
                try await controller.enableEncryption(recoveryKey: recovery)
                done(recovery)
            } catch {
                problem = SyncSettingsProblem(error: error, fallback: "The library couldn’t be encrypted. Try again.")
            }
            working = false
        }
    }
}

/// A recovery key, shown once: the person saves it. Copy keeps it on this device only, out of clipboard history,
/// and clears it after a while (`copyLifetime`): it opens the whole library.
public struct RecoveryKeyView: View {
    private let key: RecoveryKey
    private let done: @MainActor () -> Void
    @State private var copied = false
    @Environment(\.screenServices) private var services

    /// How long a copied recovery key stays on the pasteboard: long enough to paste it into a password manager.
    public static let copyLifetime: Duration = .seconds(120)

    public init(key: RecoveryKey, done: @escaping @MainActor () -> Void) {
        self.key = key
        self.done = done
    }

    /// Copies the key for this device only, with an expiry: through the app's `ScreenServices` when it fills them,
    /// else `LocalCopy`.
    @MainActor
    public static func copy(_ key: RecoveryKey, services: ScreenServices?) {
        if let services {
            services.copyLocally(key.text, expiresIn: copyLifetime)
        } else {
            LocalCopy.copy(key.text, expiresIn: copyLifetime)
        }
    }

    public var body: some View {
        SettingsFormSheet(title: "Recovery Key", cancel: nil, confirm: .init("Done", perform: done)) {
            Section {
                // Not selectable: the system's Copy would put it on every nearby device and in clipboard history.
                Text(key.text)
                    .font(.system(.title3, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(key.text.map(String.init).joined(separator: " "))
                Button(copied ? "Copied" : "Copy") {
                    Self.copy(key, services: services)
                    copied = true
                }
            }
        }
        #if os(iOS)
        // Saved or not, it goes only with Done.
        .interactiveDismissDisabled()
        #endif
    }
}

/// Typing a recovery key while waiting for the library's key.
public struct EnterRecoveryKeyForm: View {
    private let controller: LibrarySyncController?
    private let done: @MainActor () -> Void
    @State private var text = ""
    @State private var problem: SyncSettingsProblem?
    @State private var working = false
    @Environment(\.daybookDensity) private var density

    public init(controller: LibrarySyncController?, done: @escaping @MainActor () -> Void) {
        self.controller = controller
        self.done = done
    }

    public var body: some View {
        SettingsFormSheet(title: "Enter Recovery Key", cancel: .init("Cancel", perform: done),
                          confirm: .init("Open", isEnabled: !working && controller != nil && RecoveryKey(text) != nil, perform: open)) {
            Section {
                TextField(SyncSettingsCase.label("Recovery key", density), text: $text)
                    .font(.system(.body, design: .monospaced))
                    .touchKeyboard(capitalization: .characters)
                    .autocorrectionDisabled()
                    .onSubmit(open)
                if let problem { ProblemLine(text: problem.message, details: problem.details) }
            }
        }
    }

    private func open() {
        guard let controller, !working, RecoveryKey(text) != nil else { return }
        working = true; problem = nil
        Task {
            do {
                if try await controller.enterRecoveryKey(text) { done() } else {
                    problem = SyncSettingsProblem(message: "That recovery key doesn’t match this library.")
                }
            } catch {
                problem = SyncSettingsProblem(error: error, fallback: "The recovery key couldn’t be checked. Try again.")
            }
            working = false
        }
    }
}

/// Every device that syncs this library, with what it does and when it was last seen. Each physical device once: an
/// earlier identity of a reinstalled one, and one not seen for months, aren't listed (`inUse(at:)`).
public struct LibraryDevicesSection: View {
    private let devices: [KnownSyncDevice]

    public init(devices: [KnownSyncDevice]) { self.devices = devices }

    public var body: some View {
        Section {
            ForEach(devices.inUse()) { device in
                // Each row keeps its "Last seen" current.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    SettingsRow(title: LibraryDeviceWords.name(device), detail: LibraryDeviceWords.detail(device, now: context.date),
                                systemImage: device.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The Devices row in iCloud Sync: what it opens says who syncs the library ("Only this Mac", "2 others"). The iPhone
/// wraps it in a link that pushes the list; the Mac in a button that opens it in a sheet, with a chevron as System
/// Settings draws one.
public struct LibraryDevicesRowLabel: View {
    private let summary: String
    private let chevron: Bool

    public init(summary: String, chevron: Bool = false) {
        self.summary = summary
        self.chevron = chevron
    }

    public var body: some View {
        LabeledContent {
            HStack(spacing: DaybookSpacing.s2) {
                Text(summary)
                if chevron {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
        } label: {
            Text("Devices").foregroundStyle(DaybookPalette.Ink.title)
        }
        .contentShape(Rectangle())
    }
}

/// Settings' labels, in sentence case on the Mac and title case on the iPhone (`SettingsWords.titleCased`), where each
/// platform's guidelines put them.
enum SyncSettingsCase {
    static func label(_ sentence: String, _ density: DaybookDensity) -> String {
        density == .touch ? SettingsWords.titleCased(sentence) : sentence
    }
}
