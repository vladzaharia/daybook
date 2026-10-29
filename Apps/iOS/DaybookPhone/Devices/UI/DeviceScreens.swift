import DaybookKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Settings › Recorders

struct RecordersSection: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.settingsPages) private var pages
    @Binding var showingAddDevice: Bool

    var body: some View {
        Section {
            ForEach(model.devices.sessions) { session in
                SettingsLink(route: .device(session.id)) { DeviceRow(session: session) }
            }
            // Open, Add Recorder is the right page's; in the hand, a sheet.
            if pages != nil {
                SettingsLink(route: .addRecorder) { SettingsActionLabel(title: "Add Recorder…", systemImage: "plus") }
            } else {
                Button { showingAddDevice = true } label: { SettingsActionLabel(title: "Add Recorder…", systemImage: "plus") }
            }
        } header: {
            Text("Recorders")
        }
    }
}

/// A recorder in Settings: its tile (teal while it's connected), its name, and the status sheet's line
/// for it ("Connected · 80% · 2 new", "Importing 1 of 3", "Managed by Studio Mac").
struct DeviceRow: View {
    @ObservedObject var session: DeviceSession
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let line = StatusSheetModel.recorderLine(StatusSheetInputs.recorder(session, model: model), now: context.date)
            SettingsRow(title: session.device.name, detail: line.text, systemImage: session.kind.systemImage,
                        tone: session.isLinked ? .active : .neutral, detailNeedsAttention: line.tone == .attention)
        }
    }
}

/// The recorder's symbol: teal while it's linked, secondary otherwise.
struct DeviceGlyph: View {
    @ObservedObject var session: DeviceSession
    var size: CGFloat

    var body: some View {
        Image(systemName: session.kind.systemImage)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(session.isLinked ? PhoneStyle.accent : PhoneStyle.Ink.secondary)
            .frame(width: size, height: size)
            .background((session.isLinked ? PhoneStyle.accent : Color.gray).opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Device page

/// One recorder: its status, what can be done with it now, what's new on it, what's been imported,
/// and how recordings arrive.
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
    @Environment(\.settingsPages) private var pages
    @ObservedObject var session: DeviceSession
    @State private var confirmingRemove = false
    @State private var renaming = false
    @State private var name = ""
    @State private var showingDetails = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let soundcore = session.direct as? SoundcoreConnection
        let problem = session.managedElsewhere == nil ? session.problem : nil
        let actions = pageActions(problem: problem)
        List {
            Section {
                DevicePageHeader(systemImage: session.kind.systemImage, isActive: session.isLinked, title: session.device.name,
                                 status: PhoneDeviceCopy.line(for: session),
                                 statusNeedsAttention: !session.isLinked && session.state == .unavailable)
                    .devicePageHeaderRow()
            }
            if let problem {
                Section { ProblemBox(session: session, problem: problem) }
            }
            // Who manages it, and moving it between this iPhone and a Mac (docs/devices.md, "Handing a recorder over"):
            // the status sheet's rows, which say "Managed by" only in the header above.
            if RecorderHandoffCard.shows(session, devices: model.devices) {
                Section { RecorderHandoffCard(session: session) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
            // What can be done now, as the status sheet offers it: never a disabled button.
            if !actions.isEmpty {
                Section { StatusRecorderActions(session: session, actions: actions) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            if let status = session.status, session.managedElsewhere == nil {
                Section { StatusTiles(status: status, live: session.isLinked) }
            }
            importSection(offersImportAll: !actions.contains { if case .importNew = $0 { return true }; return false })
            if !session.links.recent.isEmpty {
                Section("Recently Imported") {
                    ForEach(session.links.recent.prefix(6)) { entry in
                        let meeting = model.library.controller.meeting(entry.meetingID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting?.title ?? entry.fileName).foregroundStyle(PhoneStyle.Ink.title)
                            Text(PhoneDeviceCopy.sentenceCase(DeviceDateFormat.relative(entry.importedAt)))
                                .font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            optionsSection(soundcore: soundcore)
            Section {
                if session.direct is any DetailedConnection {
                    Button { showingDetails = true } label: {
                        HStack {
                            Text("Details").foregroundStyle(PhoneStyle.Ink.title)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                                .accessibilityHidden(true)
                        }
                    }
                }
                if soundcore != nil, session.managedElsewhere == nil, session.isLinked {
                    Button("Disconnect") { session.disconnect(.direct) }
                }
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle(session.device.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingDetails) { DeviceDetailsScreen(session: session) }
        .toolbar {
            // The page's own header names the recorder; the bar stays quiet.
            ToolbarItem(placement: .principal) { Text("") }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename…") { name = session.device.name; renaming = true }
                    if session.isLinked { Button("Refresh") { session.direct?.refresh() } }
                    Button("Remove from This iPhone…", role: .destructive) { confirmingRemove = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
            }
        }
        .refreshable { session.direct?.refresh() }
        .onAppear { session.direct?.refreshIfStale() }
        .task {
            // `--open-settings device-details` (debug), for screenshots.
            if model.options.openSettings == "device-details", session.direct is any DetailedConnection {
                try? await Task.sleep(for: .milliseconds(500))
                showingDetails = true
            }
        }
        .alert("Rename Recorder", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.devices.hub.rename(session.id, to: name) }
        }
        .confirmationDialog("Remove \(session.device.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.devices.remove(session)
                // On the open Duo's right page there's nothing to go back to.
                if let pages { pages.leave() } else { dismiss() }
            }
        } message: {
            Text("Recordings already imported stay in your library.")
        }
    }

    /// The status sheet's actions for this recorder, less Connect when the problem above already offers it.
    private func pageActions(problem: DeviceProblem?) -> [StatusRecorderAction] {
        let actions = StatusSheetModel.actions(for: StatusSheetInputs.recorder(session, model: model))
        guard let problem, ProblemBox.actions(problem).contains(where: { $0 == .connect || $0 == .reconnect }) else { return actions }
        return actions.filter { $0 != .connect }
    }

    /// What's coming off the recorder now, and what's new on it. A recorder another device manages has
    /// none here: that device imports them.
    @ViewBuilder
    private func importSection(offersImportAll: Bool) -> some View {
        let split = session.split
        let new = session.newRecordings
        let canImport = session.isConnected && session.managedElsewhere == nil
        if session.managedElsewhere == nil, session.queue.isActive || !new.isEmpty || split.inProgress != nil {
            Section {
                if let current = session.queue.current {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Importing \(current.recording.title)")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.title)
                            Spacer()
                            Text(session.isWaitingForOtherApp ? "Waiting…" : session.phase?.label ?? "Waiting…")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(PhoneStyle.Ink.secondary)
                        }
                        // Work in progress: the brand gradient.
                        ProgressView(value: session.phase?.fraction ?? 0).progressViewStyle(.brand(width: nil))
                        if session.queue.total > 1 || session.secondsLeft != nil {
                            Text(queueLine).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                        }
                        if session.kind.method(.direct)?.transport == .bluetoothLE {
                            Text("Keep it near this iPhone until it finishes.").font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    Button("Stop Importing", role: .destructive) { session.stopAll() }
                } else if session.queue.isSuspended {
                    Text("Importing continues when \(session.kind.shortName) reconnects.")
                        .font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
                }
                if let now = split.inProgress {
                    HStack(spacing: PhoneStyle.Space.s2) {
                        Circle().fill(PhoneStyle.Ink.record).frame(width: 8, height: 8).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recording now · started \(now.title)").font(.subheadline).foregroundStyle(PhoneStyle.Ink.title)
                            // Handed over mid-recording: the conversation it goes into once it's finished.
                            if let waiting = session.conversationWaiting(for: now.id),
                               let title = model.library.controller.meeting(waiting)?.title {
                                Text("For \(title)").font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(new) { recording in
                    // At the accessibility sizes, Import goes under the recording rather than squeezing it.
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: PhoneStyle.Space.s2))
                        : AnyLayout(HStackLayout())
                    layout {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.title).foregroundStyle(PhoneStyle.Ink.title)
                            Text(recording.detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        if !typeSize.isAccessibilitySize { Spacer() }
                        if canImport {
                            Button("Import") { session.importRecordings([recording]) }
                                .buttonStyle(.bordered)
                                .tint(PhoneStyle.accent)
                                .accessibilityLabel("Import \(recording.title)")
                        }
                    }
                }
                if offersImportAll, canImport, new.count > 1, !session.queue.isActive {
                    Button("Import \(new.count) New") { session.importRecordings(new) }
                }
            } header: {
                Text("New on \(session.kind.shortName)")
            }
        }
    }

    /// How recordings arrive: a folder's place and state, and Soundcore's two choices. Bluetooth's own
    /// state is the header's line, so it isn't repeated here.
    @ViewBuilder
    private func optionsSection(soundcore: SoundcoreConnection?) -> some View {
        let methods = session.connections.filter { $0.isSetUp && !($0 is SoundcoreConnection) }
        if !methods.isEmpty || soundcore != nil {
            Section {
                ForEach(methods, id: \.method) { connection in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(PhoneDeviceCopy.methodTitle(session.kind, connection.method))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.title)
                        Text(PhoneDeviceCopy.summary(connection.summary)).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
                if soundcore != nil {
                    Toggle("Import Automatically", isOn: Binding(
                        get: { session.device.importsAutomatically },
                        set: { value in session.update { $0.importsAutomatically = value } }))
                    if session.direct?.capabilities.contains(.recordControl) == true {
                        // Off: this iPhone doesn't start it, its button doesn't start this iPhone, and its
                        // link isn't held in the background for that.
                        Toggle("Record Along", isOn: Binding(
                            get: { session.device.recordsAlongsideMac },
                            set: { value in session.update { $0.alsoRecordsWithMac = value } }))
                    }
                    Toggle("Hand Back to My Mac", isOn: Binding(
                        get: { model.settings.handsRecorderBackToMac },
                        set: { value in
                            model.settings.handsRecorderBackToMac = value
                            model.devices.handoff.handsBackAutomatically = value
                        }))
                }
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
                    Text("None listed").foregroundStyle(PhoneStyle.Ink.secondary)
                }
                ForEach(standings) { standing in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(standing.recording.title).foregroundStyle(PhoneStyle.Ink.title)
                            Text(standing.recording.detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                        }
                        Spacer()
                        // A fact, not an action: new stands out by weight, not the accent.
                        Text(standing.reason.label)
                            .font(.footnote.weight(standing.reason == .new ? .semibold : .regular))
                            .foregroundStyle(standing.reason == .new ? PhoneStyle.Ink.title : PhoneStyle.Ink.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
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

/// Battery, case, and storage as figures in one card, as the Mac's page shows them. Cached values
/// say when they're from.
private struct StatusTiles: View {
    let status: DeviceStatus
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
            HStack(alignment: .top, spacing: PhoneStyle.Space.s3) {
                if let battery = status.battery, battery.level != nil {
                    figure("Recorder", BatteryFormat.value(battery), symbol: BatteryFormat.symbol(battery), warn: BatteryFormat.isLow(battery))
                }
                if let battery = status.caseBattery, battery.level != nil {
                    figure("Case", BatteryFormat.value(battery), symbol: BatteryFormat.symbol(battery), warn: BatteryFormat.isLow(battery))
                }
                if let storage = status.storage {
                    let low = StorageFormat.isLow(storage)
                    figure("Storage", PhoneDeviceCopy.storageFigure(hours: storage.hoursLeft),
                           symbol: low ? "externaldrive.trianglebadge.exclamationmark" : "externaldrive", warn: low)
                        .accessibilityLabel("Storage, \(StorageFormat.hoursLeft(storage))")
                }
            }
            if !live {
                Text(PhoneDeviceCopy.asOf(status.updatedAt)).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func figure(_ label: String, _ value: String, symbol: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(warn ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
                .frame(height: 22, alignment: .leading)
                .accessibilityHidden(true)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(warn ? PhoneStyle.Ink.warning : PhoneStyle.Ink.title)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One problem at a time: what happened, what's safe, at most two actions.
struct ProblemBox: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var session: DeviceSession
    let problem: DeviceProblem

    var body: some View {
        let copy = PhoneDeviceCopy.problem(problem)
        VStack(alignment: .leading, spacing: 8) {
            Label(copy.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(PhoneStyle.Ink.warning)
                .fixedSize(horizontal: false, vertical: true)
            Text(copy.message).font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                ForEach(Array(Self.actions(problem).enumerated()), id: \.offset) { _, action in
                    Button(PhoneDeviceCopy.title(action)) { perform(action) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneStyle.Ink.link)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The problem's actions this iPhone can take, at most two.
    static func actions(_ problem: DeviceProblem) -> [DeviceProblemAction] {
        Array(problem.actions.filter(PhoneDeviceCopy.isAvailable).prefix(2))
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

extension View {
    /// Add Recorder: a sheet in the hand; open, the display as two pages (`pagesPresentation`). Closes
    /// itself, then says which recorder was added (nil when cancelled).
    func addRecorderSheet(isPresented: Binding<Bool>, done: @escaping (String?) -> Void) -> some View {
        pagesPresentation(isPresented: isPresented) { asPages in
            AddDeviceSheet(asPages: asPages) { id in
                isPresented.wrappedValue = false
                done(id)
            }
        }
    }
}

/// Add Recorder: choose a kind, then its method. Soundcore searches only when you tap Search,
/// which is when iOS asks to allow Bluetooth.
struct AddDeviceSheet: View {
    /// Shown over the whole open display, rather than as a sheet.
    var asPages = false
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.surfaceStyle) private var surface
    var done: (String?) -> Void
    @State private var session: DeviceSession?

    var body: some View {
        // Open, two pages: the kinds on the left, the chosen one's setup on the right.
        Group {
            if surface == .pocket {
                column
            } else if asPages {
                DisplayPages { kindsPage } trailing: { setupPage }
            } else {
                SheetCreaseSplit { kindsPage } trailing: { setupPage } single: { column }
            }
        }
        .presentationSizing(SheetPagesSizing(asPages: surface != .pocket))
        .task {
            // `--open-settings add-device`: straight to Soundcore setup.
            if model.options.openSettings == "add-device", session == nil, let kind = DeviceCatalog.kind(SoundcoreWorkIntegration.id) {
                session = model.devices.beginSetup(kind)
            }
        }
    }

    private var kindsPage: some View {
        NavigationStack { kinds(asPages: true).modifier(AddRecorderBar(title: "Add Recorder", cancel: cancel)) }
    }

    private var setupPage: some View {
        NavigationStack {
            if let session {
                SetupScreen(session: session, done: finish)
                    .navigationTitle(session.kind.name)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                // Until a kind is chosen the left page says what to do; this one shows only the mark.
                Image(systemName: "waveform.badge.microphone")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(PhoneStyle.Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .accessibilityHidden(true)
            }
        }
        .id(session?.id)
    }

    /// In the hand: the kinds, then the chosen one's setup in their place.
    private var column: some View {
        NavigationStack {
            Group {
                if let session {
                    SetupScreen(session: session, done: finish)
                } else {
                    kinds(asPages: false)
                }
            }
            .modifier(AddRecorderBar(title: session?.kind.name ?? "Add Recorder", cancel: cancel))
        }
    }

    private func kinds(asPages: Bool) -> some View {
        RecorderKinds(chosen: asPages ? session?.kind : nil, showsChevrons: !asPages) { session = model.devices.beginSetup($0) }
    }

    private func cancel() {
        model.devices.cancelSetup()
        done(nil)
    }

    private func finish(_ id: String?) {
        if id != nil { model.devices.commitSetup() } else { model.devices.cancelSetup() }
        done(id)
    }
}

/// Add Recorder on the open Duo's right page: the kinds, then the chosen one's setup in their place.
/// Cancel goes back to the kinds; choosing another page before it's set up cancels it.
struct AddRecorderPage: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.settingsPages) private var pages
    @Environment(\.dismiss) private var dismiss
    @State private var session: DeviceSession?
    @State private var finished = false

    var body: some View {
        Group {
            if let session {
                SetupScreen(session: session, done: finish)
            } else {
                RecorderKinds(chosen: nil, showsChevrons: true) { session = model.devices.beginSetup($0) }
            }
        }
        .navigationTitle(session?.kind.name ?? "Add Recorder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.devices.cancelSetup()
                        session = nil
                    }
                }
            }
        }
        .onDisappear { if !finished, session != nil { model.devices.cancelSetup() } }
        .task {
            // `--open-settings add-device`: straight to Soundcore setup.
            if model.options.openSettings == "add-device", session == nil, let kind = DeviceCatalog.kind(SoundcoreWorkIntegration.id) {
                session = model.devices.beginSetup(kind)
            }
        }
    }

    private func finish(_ id: String?) {
        finished = true
        if let id {
            model.devices.commitSetup()
            if let pages { pages.open(.device(id)) } else { dismiss() }
        } else {
            model.devices.cancelSetup()
            if let pages { pages.leave() } else { dismiss() }
        }
    }
}

/// The kinds of recorder this iPhone can add. Two pages mark the chosen one, whose setup is on the
/// right page rather than pushed (so no chevrons).
private struct RecorderKinds: View {
    var chosen: DeviceKind?
    var showsChevrons: Bool
    let choose: (DeviceKind) -> Void

    var body: some View {
        List {
            Section {
                // Daybook on iPhone is this app: a recorder the Mac adds, not one the iPhone adds.
                ForEach(DeviceCatalog.kinds.filter { $0.id != DaybookPhoneIntegration.id }) { kind in
                    let isChosen = chosen == kind
                    Button { choose(kind) } label: {
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
                            if showsChevrons {
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(isChosen ? PhoneStyle.accent.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground))
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                }
            }
        }
    }
}

/// Add Recorder's bar: its title, and Cancel.
private struct AddRecorderBar: ViewModifier {
    let title: String
    let cancel: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
    }
}

private struct SetupScreen: View {
    @ObservedObject var session: DeviceSession
    var done: (String?) -> Void
    @State private var choosingFolder = false
    @State private var folderError: String?
    private let tileColumn = SettingsTileWidth()

    var body: some View {
        let soundcore = session.direct as? SoundcoreConnection
        List {
            if let soundcore {
                Section {
                    if soundcore.state == .searching || !soundcore.discovered.isEmpty || soundcore.connectingTo != nil {
                        ForEach(soundcore.discovered) { recorder in
                            Button { soundcore.connect(to: recorder) } label: {
                                HStack {
                                    SettingsRow(title: recorder.name, detail: recorder.signal.word, systemImage: "waveform.badge.microphone")
                                    Spacer(minLength: 0)
                                    if soundcore.connectingTo == recorder.id { ProgressView() }
                                }
                            }
                            .disabled(soundcore.connectingTo != nil)
                        }
                        if soundcore.discovered.isEmpty {
                            HStack(spacing: SettingsMetrics.gap) {
                                ProgressView().frame(width: tileColumn.value)
                                Text("Looking for Soundcore Work…").foregroundStyle(PhoneStyle.Ink.secondary)
                            }
                        }
                    } else {
                        Button {
                            soundcore.search()
                        } label: {
                            SettingsActionLabel(title: "Search for Soundcore Work", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                } footer: {
                    if soundcore.searchFoundNothing {
                        Text("Nothing found yet.")
                    }
                }
                // The not-found problem says what the tips say.
                if let problem = session.problem, problem.id != SoundcoreIssue.notFound.rawValue {
                    Section {
                        Text(PhoneDeviceCopy.problem(problem).message).font(.subheadline).foregroundStyle(PhoneStyle.Ink.warning)
                    }
                }
                // Until it's found: what to try.
                if soundcore.discovered.isEmpty {
                    Section("If It Doesn’t Appear") {
                        ForEach(PhoneDeviceCopy.tips(session.kind), id: \.text) { tip in
                            // Tips aren't actions: secondary symbols, so the accent stays on Search.
                            HStack(spacing: SettingsMetrics.gap) {
                                Image(systemName: tip.symbol)
                                    .foregroundStyle(PhoneStyle.Ink.secondary)
                                    .frame(width: tileColumn.value)
                                    .accessibilityHidden(true)
                                Text(tip.text).foregroundStyle(PhoneStyle.Ink.title)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            } else if let files = session.files {
                Section {
                    Button { choosingFolder = true } label: { SettingsActionLabel(title: "Choose Folder…", systemImage: "folder") }
                    if let folderError { Text(folderError).font(.footnote).foregroundStyle(PhoneStyle.Ink.warning) }
                } footer: {
                    Text("Save or export recordings to a folder in Files, such as one in iCloud Drive.")
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
        if let wait = session.otherAppWait { return wait }
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
            if let last = session.direct?.lastConnectedAt { return lastSeen(last) }
            return session.files != nil ? "Watching a folder" : "Not connected"
        }
    }

    /// "Last seen today, 2:14 PM", as the status sheet's line says it.
    static func lastSeen(_ date: Date, now: Date = Date()) -> String {
        "Last seen \(DeviceDateFormat.lastSeen(date, now: now))"
    }

    /// Under figures that are from earlier: "As of 2:14 PM" today, "As of 20 Oct" before.
    static func asOf(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let when = DeviceDateFormat.asOf(date, now: now, calendar: calendar)
        for word in ["at ", "on "] where when.hasPrefix(word) { return "As of " + when.dropFirst(word.count) }
        return "As of " + when
    }

    /// A recorder's room as a figure: "210 hr", "6 hr", "< 1 hr".
    static func storageFigure(hours: Double) -> String {
        hours < 1 ? "< 1 hr" : "\(StorageFormat.roundedHours(hours)) hr"
    }

    /// "Just now", "2 hours ago": a relative time starting a line.
    static func sentenceCase(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

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
