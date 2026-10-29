import DaybookKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Settings › Recorders

struct RecordersSection: View {
    @Environment(PhoneAppModel.self) private var model
    @Binding var showingAddDevice: Bool

    var body: some View {
        Section {
            ForEach(model.devices.sessions) { session in
                NavigationLink(value: SettingsRoute.device(session.id)) { DeviceRow(session: session) }
            }
            Button { showingAddDevice = true } label: { Label("Add Recorder…", systemImage: "plus.circle") }
        } header: {
            Text("Recorders")
        } footer: {
            if model.devices.sessions.isEmpty {
                Text("Add Soundcore Work, or any recorder that saves audio files.")
            }
        }
    }
}

struct DeviceRow: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        HStack(spacing: 12) {
            DeviceGlyph(session: session, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.device.name)
                Text(PhoneDeviceCopy.line(for: session)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let progress = session.importProgress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small).tint(PhoneStyle.accent)
            } else if !session.newRecordings.isEmpty, session.managedElsewhere == nil {
                Text("\(session.newRecordings.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(PhoneStyle.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(PhoneStyle.Ink.link)
                    .accessibilityLabel("\(session.newRecordings.count) new recordings")
            }
        }
        .padding(.vertical, 2)
    }
}

/// The recorder's symbol: teal while it's linked, secondary otherwise.
struct DeviceGlyph: View {
    @ObservedObject var session: DeviceSession
    var size: CGFloat

    var body: some View {
        Image(systemName: session.kind.systemImage)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(session.isLinked ? PhoneStyle.accent : .secondary)
            .frame(width: size, height: size)
            .background((session.isLinked ? PhoneStyle.accent : Color.gray).opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Device page

/// One recorder: its status, what's new on it, what's been imported, and how recordings arrive.
struct DevicePage: View {
    @Environment(PhoneAppModel.self) private var model
    let sessionID: String

    var body: some View {
        if let session = model.devices.sessions.first(where: { $0.id == sessionID }) {
            DevicePageContent(session: session)
        } else {
            ContentUnavailableView("Recorder Removed", systemImage: "waveform.badge.microphone", description: Text("Recordings it brought in stay in your library."))
        }
    }
}

private struct DevicePageContent: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: DeviceSession
    @State private var confirmingRemove = false
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        let soundcore = session.direct as? SoundcoreConnection
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            // Who manages it, and moving it between this iPhone and a Mac (docs/devices.md, "Handing a recorder over").
            if session.direct is any ManagedConnection,
               session.managedElsewhere != nil || model.devices.handoffState(session) != .idle || !model.devices.handoffTargets(session).isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        if let owner = session.managedElsewhere {
                            Label("Managed by \(owner.ownerName)", systemImage: owner.ownerClass == .mac ? "desktopcomputer" : "iphone")
                                .font(.headline)
                                .foregroundStyle(PhoneStyle.Ink.title)
                        }
                        RecorderHandoffCard(session: session)
                    }
                    .padding(.vertical, 4)
                }
            }
            if session.managedElsewhere == nil, let problem = session.problem {
                Section { ProblemBox(session: session, problem: problem) }
            }
            if let status = session.status, session.managedElsewhere == nil {
                Section { StatusTiles(status: status, live: session.isLinked) }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            importSection
            if !session.links.recent.isEmpty {
                Section("Recently Imported") {
                    ForEach(session.links.recent.prefix(6)) { entry in
                        let meeting = model.library.controller.meeting(entry.meetingID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting?.title ?? entry.fileName)
                            Text(DeviceDateFormat.relative(entry.importedAt)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                ForEach(session.connections.filter(\.isSetUp), id: \.method) { connection in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(PhoneDeviceCopy.methodTitle(session.kind, connection.method)).font(.subheadline.weight(.semibold))
                        Text(PhoneDeviceCopy.summary(connection.summary)).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                if soundcore != nil {
                    Toggle("Import New Recordings Automatically", isOn: Binding(
                        get: { session.device.importsAutomatically },
                        set: { value in session.update { $0.importsAutomatically = value } }))
                    Toggle("Hand Back to My Mac When It’s Nearby", isOn: Binding(
                        get: { model.settings.handsRecorderBackToMac },
                        set: { value in
                            model.settings.handsRecorderBackToMac = value
                            model.devices.handoff.handsBackAutomatically = value
                        }))
                }
                if let soundcore, session.managedElsewhere == nil {
                    if session.isLinked {
                        Button("Disconnect") { session.disconnect(.direct) }
                    } else if soundcore.isSetUp {
                        Button("Connect") { session.connect() }
                            .disabled(session.state.isBusy)
                    }
                }
            } header: {
                Text("Import")
            }
            if session.direct is any DetailedConnection {
                Section {
                    NavigationLink("Details") { DeviceDetailsScreen(session: session) }
                }
            }
        }
        .navigationTitle(session.device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The page's own header names the recorder; the bar stays quiet.
            ToolbarItem(placement: .principal) { Text("") }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename…") { name = session.device.name; renaming = true }
                    if session.isLinked { Button("Refresh") { session.direct?.refresh() } }
                    Button("Remove from This iPhone…", role: .destructive) { confirmingRemove = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .refreshable { session.direct?.refresh() }
        .onAppear { session.direct?.refreshIfStale() }
        .alert("Rename Recorder", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.devices.hub.rename(session.id, to: name) }
        }
        .confirmationDialog("Remove \(session.device.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.devices.remove(session)
                dismiss()
            }
        } message: {
            Text("Recordings already imported stay in your library.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            DeviceGlyph(session: session, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.device.name).font(PhoneStyle.Typeface.title(.title)).foregroundStyle(PhoneStyle.Ink.title)
                HStack(spacing: 6) {
                    Circle().fill(session.isLinked ? PhoneStyle.accent : Color(uiColor: .tertiaryLabel)).frame(width: 7, height: 7)
                    Text(PhoneDeviceCopy.line(for: session)).font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var importSection: some View {
        let split = session.split
        let new = session.newRecordings
        if session.queue.isActive || !new.isEmpty || split.inProgress != nil {
            Section {
                if let current = session.queue.current {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Importing \(current.recording.title)").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(session.phase?.label ?? "Waiting…").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: session.phase?.fraction ?? 0).tint(PhoneStyle.accent)
                        if session.queue.total > 1 || session.secondsLeft != nil {
                            Text(queueLine).font(.footnote).foregroundStyle(.secondary)
                        }
                        if session.kind.method(.direct)?.transport == .bluetoothLE {
                            Text("Keep it near this iPhone until it finishes.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    Button("Stop Importing", role: .destructive) { session.stopAll() }
                } else if session.queue.isSuspended {
                    Text("Importing continues when \(session.kind.shortName) reconnects.").font(.subheadline).foregroundStyle(.secondary)
                }
                if let now = split.inProgress {
                    HStack {
                        Circle().fill(PhoneStyle.Ink.record).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recording now · started \(now.title)").font(.subheadline)
                            // Handed over mid-recording: the conversation it goes into once it's finished.
                            if let waiting = session.conversationWaiting(for: now.id),
                               let title = model.library.controller.meeting(waiting)?.title {
                                Text("For \(title)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(new) { recording in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.title)
                            Text(recording.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import") { session.importRecordings([recording]) }
                            .buttonStyle(.bordered)
                            .tint(PhoneStyle.accent)
                            .disabled(!session.isConnected || session.managedElsewhere != nil)
                    }
                }
                if new.count > 1, !session.queue.isActive {
                    Button("Import \(new.count) New") { session.importRecordings(new) }
                        .disabled(!session.isConnected || session.managedElsewhere != nil)
                }
            } header: {
                Text("New on \(session.kind.shortName)")
            }
        }
    }

    private var queueLine: String {
        var parts = ["\(session.queue.position) of \(session.queue.total)"]
        if let seconds = session.secondsLeft { parts.append("about \(DurationLabel.format(seconds)) left") }
        return parts.joined(separator: " · ")
    }
}

/// The recorder's status and technical facts, and every recording on it with why it is or isn't
/// new. Copy puts all of it on the clipboard, to send when something looks wrong.
struct DeviceDetailsScreen: View {
    @ObservedObject var session: DeviceSession
    @State private var copied = false

    var body: some View {
        let detailed = session.direct as? any DetailedConnection
        List {
            if let detailed {
                Section {
                    ForEach(detailed.details) { row($0) }
                }
                Section("Technical") {
                    ForEach(detailed.technicalDetails) { row($0) }
                    if let last = detailed.lastTechnicalProblem { row(DeviceDetail(label: "Last problem", value: last)) }
                }
            }
            Section("On \(session.kind.shortName)") {
                let standings = session.standings
                if standings.isEmpty {
                    Text("None listed").foregroundStyle(.secondary)
                }
                ForEach(standings) { standing in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(standing.recording.title)
                            Text(standing.recording.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(standing.reason.label).font(.footnote).foregroundStyle(standing.reason == .new ? PhoneStyle.Ink.link : .secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = Self.text(session)
                    copied = true
                }
            }
        }
        .refreshable { session.direct?.refresh() }
    }

    private func row(_ detail: DeviceDetail) -> some View {
        LabeledContent(detail.label, value: detail.value)
            .textSelection(.enabled)
    }

    /// The app's version first, then the session's own account.
    static func text(_ session: DeviceSession, bundle: Bundle = .main) -> String {
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Daybook \(version) (\(build)) on iPhone\n" + session.diagnostics
    }
}

/// Battery, case, and storage as figure tiles. Cached values say when they're from.
private struct StatusTiles: View {
    let status: DeviceStatus
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let battery = status.battery, battery.level != nil {
                    tile("Recorder", BatteryFormat.value(battery), symbol: BatteryFormat.symbol(battery), warn: BatteryFormat.isLow(battery))
                }
                if let battery = status.caseBattery, battery.level != nil {
                    tile("Case", BatteryFormat.value(battery), symbol: BatteryFormat.symbol(battery), warn: BatteryFormat.isLow(battery))
                }
                if let storage = status.storage {
                    tile("Hours of space", "\(StorageFormat.roundedHours(storage.hoursLeft))", symbol: "internaldrive", warn: StorageFormat.isLow(storage))
                        .accessibilityLabel(StorageFormat.hoursLeft(storage))
                }
            }
            if !live {
                Text(DeviceDateFormat.asOf(status.updatedAt)).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ label: String, _ value: String, symbol: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(warn ? PhoneStyle.Ink.warning : .secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(warn ? PhoneStyle.Ink.warning : PhoneStyle.Ink.title)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One problem at a time: what happened, what's safe, at most two actions.
private struct ProblemBox: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var session: DeviceSession
    let problem: DeviceProblem

    var body: some View {
        let copy = PhoneDeviceCopy.problem(problem)
        VStack(alignment: .leading, spacing: 8) {
            Label(copy.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(PhoneStyle.Ink.warning)
            Text(copy.message).font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
            HStack(spacing: 16) {
                ForEach(Array(problem.actions.filter(PhoneDeviceCopy.isAvailable).prefix(2).enumerated()), id: \.offset) { _, action in
                    Button(PhoneDeviceCopy.title(action)) { perform(action) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneStyle.Ink.link)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func perform(_ action: DeviceProblemAction) {
        switch action {
        case .openBluetoothSettings, .openPrivacySettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .tryAgain: session.tryAgain()
        case .reconnect, .connect: session.connect()
        case .dismiss: session.dismissProblem()
        case .refreshStatus: session.direct?.refresh()
        default: session.dismissProblem()
        }
    }
}

// MARK: Add Device

/// Add Recorder: choose a kind, then its method. Soundcore searches only when you tap Search,
/// which is when iOS asks to allow Bluetooth.
struct AddDeviceSheet: View {
    @Environment(PhoneAppModel.self) private var model
    var done: (String?) -> Void
    @State private var session: DeviceSession?

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    SetupScreen(session: session, done: finish)
                } else {
                    List {
                        Section {
                            // Daybook on iPhone is this app: a recorder the Mac adds, not one the iPhone adds.
                            ForEach(DeviceCatalog.kinds.filter { $0.id != DaybookPhoneIntegration.id }) { kind in
                                Button {
                                    session = model.devices.beginSetup(kind)
                                } label: {
                                    // Explicit inks: in a list, a button tints its label, and `.primary` and
                                    // `.secondary` would follow that tint, turning the whole row teal.
                                    HStack(spacing: 14) {
                                        Image(systemName: kind.systemImage)
                                            .font(.system(size: 20, weight: .medium))
                                            .foregroundStyle(PhoneStyle.Ink.secondary)
                                            .frame(width: 44, height: 44)
                                            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(kind.name).foregroundStyle(PhoneStyle.Ink.title)
                                            Text(PhoneDeviceCopy.kindSummary(kind)).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.forward")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(session?.kind.name ?? "Add Recorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.devices.cancelSetup()
                        done(nil)
                    }
                }
            }
        }
        .task {
            // `--open-settings add-device`: straight to Soundcore setup.
            if model.options.openSettings == "add-device", session == nil, let kind = DeviceCatalog.kind(SoundcoreWorkIntegration.id) {
                session = model.devices.beginSetup(kind)
            }
        }
    }

    private func finish(_ id: String?) {
        if id != nil { model.devices.commitSetup() } else { model.devices.cancelSetup() }
        done(id)
    }
}

private struct SetupScreen: View {
    @ObservedObject var session: DeviceSession
    var done: (String?) -> Void
    @State private var choosingFolder = false
    @State private var folderError: String?

    var body: some View {
        let soundcore = session.direct as? SoundcoreConnection
        List {
            if let soundcore {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Directly over Bluetooth").font(.headline)
                        Text("Straight from the recorder. New recordings import on their own when it’s near this iPhone.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("iOS asks to allow Bluetooth when you search.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    if soundcore.state == .searching || !soundcore.discovered.isEmpty || soundcore.connectingTo != nil {
                        ForEach(soundcore.discovered) { recorder in
                            Button { soundcore.connect(to: recorder) } label: {
                                HStack {
                                    Image(systemName: "waveform.badge.microphone").foregroundStyle(PhoneStyle.Ink.secondary)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading) {
                                        Text(recorder.name).foregroundStyle(PhoneStyle.Ink.title)
                                        Text(recorder.signal.word).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                                    }
                                    Spacer()
                                    if soundcore.connectingTo == recorder.id { ProgressView() }
                                }
                            }
                            .disabled(soundcore.connectingTo != nil)
                        }
                        if soundcore.discovered.isEmpty {
                            HStack(spacing: 10) { ProgressView(); Text("Looking for Soundcore Work…").foregroundStyle(.secondary) }
                        }
                    } else {
                        Button {
                            soundcore.search()
                        } label: {
                            Label("Search for Soundcore Work", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                } footer: {
                    if soundcore.searchFoundNothing {
                        Text("Nothing found yet.")
                    }
                }
                Section("If It Doesn’t Appear") {
                    ForEach(PhoneDeviceCopy.tips(session.kind), id: \.text) { tip in
                        // Tips aren't actions: secondary symbols, so the accent stays on Search.
                        Label {
                            Text(tip.text)
                        } icon: {
                            Image(systemName: tip.symbol).foregroundStyle(PhoneStyle.Ink.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                if let problem = session.problem {
                    Section {
                        Text(PhoneDeviceCopy.problem(problem).message).font(.subheadline).foregroundStyle(PhoneStyle.Ink.warning)
                    }
                }
            } else if let files = session.files {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("From a Folder").font(.headline)
                        Text("Save or export recordings to a folder in Files, such as one in iCloud Drive.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button { choosingFolder = true } label: { Label("Choose Folder…", systemImage: "folder") }
                    if let folderError { Text(folderError).font(.footnote).foregroundStyle(PhoneStyle.Ink.warning) }
                }
                .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                    guard case .success(let url) = result else { return }
                    do {
                        try files.watch(url)
                        done(session.id)
                    } catch {
                        folderError = "Daybook can’t read that folder. Choose another one."
                    }
                }
            }
        }
        .onChange(of: session.isLinked) { _, linked in
            // The recorder answered: it's set up, and this iPhone manages it.
            if linked { done(session.id) }
        }
    }
}

// MARK: Copy for iPhone

/// The device framework's words are written for the Mac ("bring it close to this Mac"); these are
/// the iPhone's, keyed by the same stable problem IDs.
@MainActor
enum PhoneDeviceCopy {
    static func line(for session: DeviceSession) -> String {
        if let owner = session.managedElsewhere { return "Managed by \(owner.ownerName)" }
        if let current = session.queue.current { return "Importing \(current.recording.title) · \(session.phase?.label ?? "…")" }
        switch session.state {
        case .connected:
            let state = session.status?.isRecording == true ? "Recording" : "Connected"
            if let battery = session.status?.battery, battery.level != nil { return "\(state) · \(BatteryFormat.label(battery))" }
            return state
        case .searching: return "Looking for it…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .unavailable: return session.problem.map { problem(for: $0.id)?.title ?? $0.title } ?? "Bluetooth isn’t available"
        case .notSetUp: return "Not set up"
        case .notConnected:
            if let status = session.status, status.isRecording == true { return DeviceDateFormat.recordingAsOf(status.updatedAt) }
            if let last = session.direct?.lastConnectedAt { return DeviceDateFormat.lastSeen(last) }
            return session.files != nil ? "Watching a folder" : "Not connected"
        }
    }

    static func summary(_ text: String) -> String {
        text.replacingOccurrences(of: "this Mac", with: "this iPhone")
    }

    static func kindSummary(_ kind: DeviceKind) -> String {
        kind.id == SoundcoreWorkIntegration.id ? "Over Bluetooth, even while Daybook is closed." : kind.summary
    }

    static func methodTitle(_ kind: DeviceKind, _ method: ConnectionMethodKind) -> String {
        kind.method(method)?.title ?? method.rawValue.capitalized
    }

    static func tips(_ kind: DeviceKind) -> [DeviceTip] {
        guard kind.id == SoundcoreWorkIntegration.id else { return kind.discoveryTips }
        return [
            DeviceTip(symbol: "moon.zzz", text: "Take it out of its case."),
            DeviceTip(symbol: "xmark.app", text: "Close the Soundcore app."),
            DeviceTip(symbol: "desktopcomputer", text: "If your Mac manages it, wait a few minutes."),
            DeviceTip(symbol: "wave.3.right", text: "Bring it close to this iPhone."),
        ]
    }

    static func problem(_ problem: DeviceProblem) -> (title: String, message: String) {
        if let copy = Self.problem(for: problem.id) { return copy }
        return (problem.title, summary(problem.message))
    }

    private static func problem(for id: String) -> (title: String, message: String)? {
        switch SoundcoreIssue(rawValue: id) {
        case .bluetoothDenied?: return ("Daybook can’t use Bluetooth", "Allow Bluetooth for Daybook in Settings › Daybook.")
        case .bluetoothUnsupported?: return ("This iPhone can’t connect to Soundcore", "Export recordings from the Soundcore app and import them with Import Audio.")
        case .notFound?: return ("No Soundcore found nearby", "Take it out of its case, close the Soundcore app, and bring it close to this iPhone.")
        case .connectTimeout?: return ("Soundcore didn’t finish connecting", "Take it out of its case to wake it, and close the Soundcore app.")
        case .rejected?: return ("This Soundcore didn’t accept the connection", "Export from the Soundcore app and import the file instead.")
        case .listFailed?: return ("Soundcore didn’t list its recordings", "Close the Soundcore app, then refresh.")
        default: return nil
        }
    }

    /// Folder actions belong to the Mac's setup; on iPhone, Import Audio does that job.
    static func isAvailable(_ action: DeviceProblemAction) -> Bool {
        action != .setUpFolder && action != .chooseFolder && action != .technicalDetails
    }

    static func title(_ action: DeviceProblemAction) -> String {
        switch action {
        case .openBluetoothSettings, .openPrivacySettings: return "Open Settings"
        default: return action.title
        }
    }
}
