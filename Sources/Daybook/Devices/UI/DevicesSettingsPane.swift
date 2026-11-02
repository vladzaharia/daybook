import AppKit
import DaybookCore
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI

/// Settings › Devices: each recorder's ways in, and its options in the words its page and the iPhone use
/// (DaybookUI's `RecorderPreferencesSection`). Everything operational (connecting, importing, status) lives
/// on the device's page instead.
struct DevicesSettingsPane: View {
    let state: AppState
    let hub: DeviceHub

    init(state: AppState) {
        self.state = state
        self.hub = state.devices
    }

    var body: some View {
        Form {
            if hub.sessions.isEmpty {
                Section {
                    HStack(spacing: Space.s3) {
                        Image(systemName: "recordingtape")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No devices yet")
                            Text("Soundcore Work, Daybook on iPhone, or any recorder that saves audio files.")
                                .font(TypeStyle.status).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // The iPhone's pairing screen sends people here for this button.
                        AddDeviceButton(state: state, kind: DaybookPhoneIntegration.id, title: PairingWords.pairWithIPhone)
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
                        AddDeviceButton(state: state, kind: DaybookPhoneIntegration.id, title: PairingWords.pairWithIPhone)
                        AddDeviceButton(state: state)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .environment(\.recorderServices, state.recorderServices)
    }
}

private struct AddDeviceButton: View {
    let state: AppState
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
    let state: AppState
    let session: DeviceSession
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingForget = false
    @State private var confirmingRemove = false
    @State private var name = ""

    var body: some View {
        let kind = session.kind
        Section {
            if kind.id == DaybookPhoneIntegration.id {
                if kind.allowsMultiple {
                    TextField("Name", text: $name)
                        .onAppear { name = session.device.name }
                        .onSubmit { state.devices.rename(session.id, to: name) }
                }
                PhoneSettingsRows(state: state, session: session)
                // Also for a pairing that can't be read or is gone ("Not paired"): Unpair removes what's left of it.
                LabeledContent("Pairing") {
                    Button(PairingWords.unpair) { confirmingRemove = true }
                }
            } else {
                if let direct = session.direct, let method = kind.method(.direct) {
                    directRows(direct, method)
                }
                if let files = session.files, let method = kind.method(.files) {
                    FolderRows(state: state, session: session, files: files, method: method)
                }
                RecorderPreferencesSection(session: session, style: .form)
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
        .alert(PairingWords.unpairQuestion(session.device.name), isPresented: $confirmingRemove) {
            Button("Unpair", role: .destructive) {
                if let phone = UUID(uuidString: session.id), state.phoneLink.isPaired(phone) { state.unpairPhone(phone) }
                else { state.removeDevice(session.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PairingWords.unpairConsequence)
        }
    }

    @ViewBuilder
    private func directRows(_ direct: any DeviceConnection, _ method: ConnectionMethod) -> some View {
        let enabled = Binding(get: { session.device.isEnabled(.direct) },
                              set: { on in session.update { if on { $0.disabledMethods.remove(.direct) } else { $0.disabledMethods.insert(.direct) } } })
        Toggle("Connect \(method.title.prefix(1).lowercased() + method.title.dropFirst())", isOn: enabled)
            .controlSize(.regular)
            .disabled(!direct.isSetUp)
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
    let state: AppState
    let session: DeviceSession
    let files: ImportFolderWatcher
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

/// Settings › Devices for Daybook on iPhone: the link, Can start recording, and how its recordings arrive, in the
/// words of its page and of the iPhone's row for a Mac.
struct PhoneSettingsRows: View {
    let state: AppState
    let session: DeviceSession
    let link: PhoneLink
    let sync: LibrarySyncController

    init(state: AppState, session: DeviceSession) {
        self.state = state
        self.session = session
        self.link = state.phoneLink
        self.sync = state.sync
    }

    var body: some View {
        let direct = session.direct
        let phone = direct as? PhoneLinkConnection
        LabeledContent("Over Wi‑Fi") {
            HStack(spacing: Space.s2) {
                DeviceStatusDot(state: direct?.state ?? .notSetUp)
                Text(Self.overWiFi(isSetUp: direct?.isSetUp == true, isConnected: direct?.state.isConnected == true,
                                   recording: phone?.recordingPhase, lastSeen: direct?.lastConnectedAt))
                    .foregroundStyle(.secondary)
                if direct?.isSetUp == false {
                    Button(PairingWords.pairAgain) { state.requestAddDevice(kind: DaybookPhoneIntegration.id) }
                }
            }
        }
        // One way, as on the iPhone: whether the phone may start a recording here.
        Toggle(PairingWords.canStartRecording,
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

    /// The Over Wi‑Fi line, as the iPhone's row for a Mac reads: "Recording now", "Connected", "Not connected · Last
    /// seen today, 9:12 AM", or "Needs pairing again" (with Pair Again…) for a pairing that's gone or can't be read.
    static func overWiFi(isSetUp: Bool, isConnected: Bool, recording: LinkRecordingState.Phase?, lastSeen: Date?,
                         now: Date = Date()) -> String {
        guard isSetUp else { return PairingWords.needsPairingAgain }
        if isConnected {
            switch recording {
            case nil: return "Connected"
            case .paused?: return "Paused recording"
            default: return "Recording now"
            }
        }
        return lastSeen.map { "Not connected · \(RecorderStatusWords.lastSeen($0, now: now))" } ?? "Not connected"
    }
}
