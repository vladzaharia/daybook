import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// Settings › Devices: each recorder's set-and-forget preferences and its methods. Everything
/// operational (connecting, importing, status) lives on the device's page instead.
struct DevicesSettingsPane: View {
    @ObservedObject var state: AppState
    @ObservedObject var hub: DeviceHub

    init(state: AppState) {
        self.state = state
        self.hub = state.devices
    }

    var body: some View {
        Form {
            if hub.sessions.isEmpty {
                Section {
                    HStack(spacing: Space.s3) {
                        Image(systemName: "waveform.badge.microphone")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No recorders yet")
                            Text("Soundcore Work, Daybook on iPhone, or any recorder that saves audio files.")
                                .font(TypeStyle.status).foregroundStyle(.secondary)
                        }
                        Spacer()
                        AddDeviceButton(state: state)
                    }
                    .padding(.vertical, Space.s1)
                }
            } else {
                ForEach(hub.sessions) { session in
                    DeviceSettingsSection(state: state, session: session)
                }
                // Add Device… sits under the groups, trailing, as System Settings places its Add buttons,
                // instead of alone in an otherwise empty group.
                Section {
                } footer: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                        Spacer()
                        AddDeviceButton(state: state, kind: DaybookPhoneIntegration.id, title: "Add iPhone…")
                        AddDeviceButton(state: state)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AddDeviceButton: View {
    @ObservedObject var state: AppState
    var kind: String?
    var title = "Add Device…"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: WindowID.library)
            state.requestAddDevice(kind: kind)
        }
    }
}

private struct DeviceSettingsSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingForget = false
    @State private var confirmingRemove = false
    @State private var name = ""

    var body: some View {
        let kind = session.kind
        Section {
            if kind.allowsMultiple {
                TextField("Name", text: $name)
                    .onAppear { name = session.device.name }
                    .onSubmit { state.devices.rename(session.id, to: name) }
            }
            if kind.id == DaybookPhoneIntegration.id {
                PhoneSettingsRows(state: state, session: session)
                LabeledContent("Pairing") {
                    Button("Unpair…") { confirmingRemove = true }
                }
            } else {
                if let direct = session.direct, let method = kind.method(.direct) {
                    directRows(direct, method)
                }
                if let files = session.files, let method = kind.method(.files) {
                    FolderRows(state: state, session: session, files: files, method: method)
                }
                LabeledContent("Remove from Daybook") {
                    Button("Remove…") { confirmingRemove = true }
                }
            }
        } header: {
            HStack(spacing: Space.s2) {
                // One glyph column, so every recorder's name starts at the same x.
                Image(systemName: kind.systemImage)
                    .foregroundStyle(session.isLinked ? AnyShapeStyle(DaybookStyle.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(session.device.name)
            }
        }
        .alert("Forget this \(kind.name)?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { state.forgetDeviceMethod(.direct, of: session.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Daybook stops connecting to it. Recordings you already imported stay.")
        }
        .alert(kind.id == DaybookPhoneIntegration.id ? "Unpair \(session.device.name)?" : "Remove \(session.device.name) from Daybook?",
               isPresented: $confirmingRemove) {
            if kind.id == DaybookPhoneIntegration.id {
                Button("Unpair", role: .destructive) {
                    if let phone = UUID(uuidString: session.id), state.phoneLink.isPaired(phone) { state.unpairPhone(phone) }
                    else { state.removeDevice(session.id) }
                }
            } else {
                Button("Remove", role: .destructive) { state.removeDevice(session.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(kind.id == DaybookPhoneIntegration.id
                 ? "This Mac and the iPhone stop recording together. Its recordings stay in your library."
                 : "Daybook stops importing from it. Recordings you already imported stay in your library.")
        }
    }

    @ViewBuilder
    private func directRows(_ direct: any DeviceConnection, _ method: ConnectionMethod) -> some View {
        let enabled = Binding(get: { session.device.isEnabled(.direct) },
                              set: { on in session.update { if on { $0.disabledMethods.remove(.direct) } else { $0.disabledMethods.insert(.direct) } } })
        let automatic = Binding(get: { session.device.importsAutomatically },
                                set: { on in session.update { $0.importsAutomatically = on } })
        Toggle("Connect \(method.title.prefix(1).lowercased() + method.title.dropFirst())", isOn: enabled)
            .controlSize(.regular)
            .disabled(!direct.isSetUp)
        Toggle("Import new recordings automatically", isOn: automatic)
            .controlSize(.regular)
            .padding(.leading, Space.s5)
            .disabled(!direct.isSetUp || !session.device.isEnabled(.direct))
        if direct.capabilities.contains(.recordControl) {
            Toggle("Record along with this Mac",
                   isOn: Binding(get: { session.device.recordsAlongsideMac }, set: { on in session.update { $0.alsoRecordsWithMac = on } }))
                .controlSize(.regular)
                .padding(.leading, Space.s5)
                .disabled(!direct.isSetUp || !session.device.isEnabled(.direct))
        }
        RecorderOwnershipRow(state: state, session: session)
        LabeledContent("Recorder") {
            if let snapshot = (direct as? SoundcoreConnection)?.remembered {
                HStack(spacing: Space.s2) {
                    Text(snapshot.displayName).foregroundStyle(.secondary).monospacedDigit()
                    Button("Forget…") { confirmingForget = true }
                }
            } else {
                HStack(spacing: Space.s2) {
                    Text("None").foregroundStyle(.secondary)
                    Button("Set Up…") {
                        openWindow(id: WindowID.library)
                        state.requestAddDevice(kind: session.kind.id, method: .direct)
                    }
                }
            }
        }
        .padding(.leading, Space.s5)
    }
}

private struct FolderRows: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @ObservedObject var files: ImportFolderWatcher
    let method: ConnectionMethod

    var body: some View {
        if let name = files.folderDisplayName {
            LabeledContent(session.kind.implementedMethods.count > 1 ? method.title : "Import folder") {
                HStack(spacing: Space.s2) {
                    Text(name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        .help(files.folder?.path ?? "")
                    Button("Choose…") { state.chooseDeviceFolder(for: session) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let problem = files.problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning).accessibilityHidden(true)
                    Text(problem.message).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose Folder…") { state.chooseDeviceFolder(for: session) }
                } else {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                        .foregroundStyle(files.isWatching && files.waitingForICloud == 0 ? AnyShapeStyle(DaybookStyle.accent) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    Text(status).foregroundStyle(.secondary)
                    Spacer()
                    if session.kind.implementedMethods.count > 1 {
                        Button("Turn Off") { state.forgetDeviceMethod(.files, of: session.id) }
                    }
                }
            }
            .font(TypeStyle.status)
            .padding(.leading, Space.s5)
        } else {
            LabeledContent(session.kind.implementedMethods.count > 1 ? method.title : "Import folder") {
                Button("Choose Folder…") { state.chooseDeviceFolder(for: session) }
            }
            if let problem = files.problem {
                Label { Text(problem.message) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning)
                }
                .font(TypeStyle.status)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        if files.waitingForICloud > 0 { return files.summary }
        guard files.isWatching else { return "Not watching" }
        guard let last = files.lastImportDate else { return "Watching for new audio" }
        return "Watching · Last import \(DeviceDateFormat.relative(last))"
    }
}

/// Settings › Devices for Daybook on iPhone: the link, recording along with this Mac, and how its
/// recordings arrive.
private struct PhoneSettingsRows: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @ObservedObject var link: PhoneLink
    @ObservedObject var sync: LibrarySyncController

    init(state: AppState, session: DeviceSession) {
        self.state = state
        self.session = session
        self.link = state.phoneLink
        self.sync = state.sync
    }

    var body: some View {
        let direct = session.direct
        LabeledContent("Over Wi‑Fi") {
            HStack(spacing: Space.s2) {
                DeviceStatusDot(state: direct?.state ?? .notSetUp)
                Text(linkStatus(direct)).foregroundStyle(.secondary)
                if direct?.isSetUp == false {
                    Button("Pair Again…") { state.requestAddDevice(kind: DaybookPhoneIntegration.id) }
                }
            }
        }
        Toggle("Record along with this Mac",
               isOn: Binding(get: { session.device.recordsAlongsideMac }, set: { on in session.update { $0.alsoRecordsWithMac = on } }))
            .controlSize(.regular)
            .padding(.leading, Space.s5)
            .disabled(direct?.isSetUp != true)
        if sync.folder == nil {
            LabeledContent("Recordings") {
                HStack(spacing: Space.s2) {
                    Text("Sync is off").foregroundStyle(.secondary)
                    Button("Library Settings…") { LaunchOptions.defaults.set(SettingsPane.library.rawValue, forKey: "settingsPane") }
                }
            }
        }
    }

    private func linkStatus(_ direct: (any DeviceConnection)?) -> String {
        guard let direct, direct.isSetUp else { return "Not paired" }
        if direct.state.isConnected { return direct.status?.isRecording == true ? "Connected · Recording" : "Connected" }
        if let last = direct.lastConnectedAt { return "Not connected · Last connected \(DeviceDateFormat.lastSeen(last))" }
        return "Not connected"
    }
}
