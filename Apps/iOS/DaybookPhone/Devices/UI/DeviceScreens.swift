import DaybookCaptions
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI
import UniformTypeIdentifiers

// A recorder's screens on the iPhone are the ones the Mac shows (DaybookUI's `Devices`): its page, its recordings,
// Listen Live, its handoff, and adding one, in the same words. What's here is how the iPhone hosts them: Settings'
// Recorders section, the pushes from the page, Add Recorder's sheet and the open Duo's pages, and the services
// they reach the app through (`PhoneRecorderServices`).

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

/// A recorder in Settings: its tile (teal while it's connected), its name, and its status line as both apps word
/// it ("Connected · 80% · 2 new", "Importing 1 of 3", "Managed by Studio Mac").
struct DeviceRow: View {
    let session: DeviceSession
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let line = session.statusLine(model: model, now: context.date)
            SettingsRow(title: session.device.name, detail: line.text, systemImage: session.kind.systemImage,
                        tone: DeviceGlyph.tone(linked: session.isLinked), detailNeedsAttention: line.tone == .attention)
        }
    }
}

extension DeviceSession {
    /// The recorder's status line, as both apps word it (`RecorderStatusWords.line`): the status sheet's card and
    /// Settings' row. Over the recorder's Wi‑Fi it says to keep Daybook open.
    @MainActor
    func statusLine(model: PhoneAppModel, now: Date = Date()) -> StatusLineWords {
        RecorderStatusWords.line(PhoneRecorderServices.make(model: model).facts(self, now: now), here: "this iPhone", now: now)
    }
}

// MARK: The services the shared screens reach the iPhone through

@MainActor
enum PhoneRecorderServices {
    /// The services for a recorder's screens. `push` opens what the page leads to (Details, Listen Live, All
    /// Recordings); `left` runs once the recorder is removed; `open` opens a conversation.
    static func make(model: PhoneAppModel, open: ((UUID) -> Void)? = nil, push: ((DevicePageRoute) -> Void)? = nil,
                     left: (() -> Void)? = nil, openURL: OpenURLAction? = nil) -> RecorderServices {
        let devices = model.devices
        let link = model.link
        let library = model.library.controller
        let settings = model.settings
        return RecorderServices(
            place: .iPhone, handoff: devices.handoff, devices: devices.hub, library: library, thisDeviceSymbol: "iphone",
            processingLabel: { id in
                switch library.meeting(id)?.status {
                case .transcribing?: return "Transcribing"
                case .summarizing?: return "Summarizing"
                default: return nil
                }
            },
            showConversation: { id in open?(id) },
            linkState: { session in
                guard session.managedElsewhere != nil else { return nil }
                return link.recorderReport(kind: session.kind.id, serial: session.recorderSerial)?.state
            },
            openSystemSettings: { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL?(url) }
            },
            stopImporting: { session, all in if all { session.stopAll() } else { session.stopCurrent() } },
            showDetails: { _ in push?(.details) },
            remove: { session in
                devices.remove(session)
                left?()
            },
            captionStatus: PhoneRecorderServices.captionStatus,
            showListenLive: push.map { push in { _ in push(.listenLive) } },
            showRecordings: push.map { push in { _ in push(.recordings) } },
            handsBack: Binding(get: { settings.handsRecorderBackToMac }, set: { on in
                settings.handsRecorderBackToMac = on
                devices.handoff.handsBackAutomatically = on
            }))
    }

    /// What Listen Live's captioner is doing, before there are captions to read.
    static func captionStatus(_ state: LiveCaptionState) -> String? {
        switch state {
        case .preparing: return "Getting captions ready…"
        case .downloading: return "Downloading captions…"
        case .listening: return "Listening…"
        case .failed: return "Captions stopped"
        case .unavailable(let reason): return reason
        case .off, .finished: return nil
        }
    }
}

// MARK: Device page

/// What a recorder's page leads to.
enum DevicePageRoute: Hashable, Identifiable {
    case details, listenLive, recordings
    var id: Self { self }
}

/// One recorder: the page both apps show (`RecorderDevicePage`), with its menu in the bar, the screens it pushes
/// (Details, Listen Live, and All Recordings), and Choose Conversation…'s sheet.
struct DevicePage: View {
    @Environment(PhoneAppModel.self) private var model
    let sessionID: String

    var body: some View {
        if let session = model.devices.sessions.first(where: { $0.id == sessionID }) {
            DevicePageContent(session: session)
        } else {
            ContentUnavailableView("Recorder Removed", systemImage: "recordingtape", description: Text("Recordings it brought in stay in your library."))
        }
    }
}

private struct DevicePageContent: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(ReadingSession.self) private var reading: ReadingSession?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsPages) private var pages
    @Environment(\.openURL) private var openURL
    let session: DeviceSession
    @State private var route: DevicePageRoute?

    private var services: RecorderServices {
        PhoneRecorderServices.make(model: model, open: { id in reading?.open(id) }, push: { route = $0 },
                                   left: { if let pages { pages.leave() } else { dismiss() } }, openURL: openURL)
    }

    var body: some View {
        let services = services
        ScrollViewReader { proxy in
            RecorderDevicePage(session: session, showsRecordings: true)
                .task {
                    // `--scroll-end` (debug): the page scrolled to its foot, for screenshots.
                    guard model.options.scrollEnd else { return }
                    try? await Task.sleep(for: .milliseconds(1500))
                    proxy.scrollTo(RecorderDevicePage.endAnchor, anchor: .bottom)
                }
        }
        .environment(\.recorderServices, services)
        .navigationTitle(session.device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The page's own header names the recorder; the bar stays quiet.
            ToolbarItem(placement: .principal) { Text("") }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    RecorderMenuItems(session: session).environment(\.recorderServices, services)
                } label: {
                    // The bar's glyphs are in the title's ink: they're chrome, not a link.
                    Image(systemName: "ellipsis").foregroundStyle(DaybookPalette.Ink.title)
                }
                .accessibilityLabel("More")
            }
        }
        .navigationDestination(item: $route) { route in
            Group {
                switch route {
                case .details: DeviceDetailsScreen(session: session)
                case .listenLive:
                    ListenLiveView(session: session)
                        .navigationTitle("Listen Live")
                        .navigationBarTitleDisplayMode(.inline)
                case .recordings:
                    DeviceRecordingsView(session: session)
                        .navigationTitle("All Recordings")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .environment(\.recorderServices, services)
        }
        // A new recording's Choose Conversation… on the page, as the Mac's device page presents it.
        .sheet(item: Bindable(session.browser).choosingConversation) { choice in
            ConversationChooser(session: session, recordings: choice.recordings)
                .environment(\.recorderServices, services)
        }
        .refreshable { session.direct?.refresh() }
        .task {
            // `--open-settings device-details|device-live|device-recordings` (debug): what the page pushes, for
            // screenshots.
            let pushes: [String: DevicePageRoute] = ["device-details": .details, "device-live": .listenLive, "device-recordings": .recordings]
            guard let push = model.options.openSettings.flatMap({ pushes[$0] }) else { return }
            try? await Task.sleep(for: .milliseconds(500))
            route = push
        }
    }
}

/// The recorder's status and technical facts, and every recording on it with why it is or isn't
/// new. Copy puts all of it on the clipboard, to send when something looks wrong.
struct DeviceDetailsScreen: View {
    let session: DeviceSession
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
                    Text("None listed").foregroundStyle(DaybookPalette.Ink.secondary)
                }
                ForEach(standings) { standing in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(standing.recording.title).foregroundStyle(DaybookPalette.Ink.title)
                            Text(standing.recording.detail).font(.footnote).foregroundStyle(DaybookPalette.Ink.secondary)
                        }
                        Spacer()
                        // A fact, not an action: new stands out by weight, not the accent.
                        Text(standing.reason.label)
                            .font(.footnote.weight(standing.reason == .new ? .semibold : .regular))
                            .foregroundStyle(standing.reason == .new ? DaybookPalette.Ink.title : DaybookPalette.Ink.secondary)
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

// MARK: Add Recorder

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

/// Add Recorder: choose a kind, then set it up. A recorder Daybook talks to directly searches only when you tap
/// Search, which is when iOS asks to allow Bluetooth; one a Mac manages moves here with Use on This iPhone instead.
struct AddDeviceSheet: View {
    /// Shown over the whole open display, rather than as a sheet.
    var asPages = false
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.surfaceStyle) private var surface
    @Environment(\.openURL) private var openURL
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
        .environment(\.recorderServices, PhoneRecorderServices.make(model: model, openURL: openURL))
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
                Image(systemName: "recordingtape")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(DaybookPalette.Ink.secondary)
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
    @Environment(\.openURL) private var openURL
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
        .environment(\.recorderServices, PhoneRecorderServices.make(model: model, openURL: openURL))
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

/// The kinds of recorder this iPhone can add, in the rows the Mac's Add Device shows. Two pages mark the chosen
/// one, whose setup is on the right page rather than pushed (so no chevrons).
private struct RecorderKinds: View {
    var chosen: DeviceKind?
    var showsChevrons: Bool
    let choose: (DeviceKind) -> Void
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        List {
            Section {
                // Daybook on iPhone is this app: a recorder the Mac adds, not one the iPhone adds.
                ForEach(DeviceCatalog.kinds.filter { $0.id != DaybookPhoneIntegration.id }) { kind in
                    let isChosen = chosen == kind
                    Button { choose(kind) } label: {
                        RecorderKindRow(kind: kind, isSetUp: !kind.allowsMultiple && model.devices.hub.session(kind: kind.id) != nil,
                                        showsChevron: showsChevrons)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isChosen ? DaybookPalette.accent.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground))
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

/// Setting one kind up. A recorder Daybook talks to directly: Search (iOS asks to allow Bluetooth then), then what
/// it found, with the step's own action (Stop, Try Again, Look Again) beside its title. One already set up here
/// opens its page; one a Mac manages offers Use on This iPhone instead of a search. A folder recorder: Choose
/// Folder….
private struct SetupScreen: View {
    let session: DeviceSession
    var done: (String?) -> Void
    @Environment(PhoneAppModel.self) private var model
    @State private var choosingFolder = false
    @State private var folderError: String?
    @State private var searched = false
    private let tileColumn = SettingsTileWidth()

    var body: some View {
        List {
            if session.managedElsewhere != nil {
                // Set up here before, and a Mac manages it now: moving it here is the way, not a second search.
                Section {
                    RecorderHandoffView(session: session, style: .card)
                        .listRowInsets(EdgeInsets())
                }
            } else if case .discover = AddRecorderStep.after(choosing: session.kind, on: .iPhone),
                      let discovering = session.direct as? any DiscoveringConnection {
                // Its only way in here is direct (the shared step rule): finding it nearby.
                discovery(discovering)
            } else if let files = session.files, AddRecorderStep.methods(session.kind, on: .iPhone).contains(where: { $0.kind == .files }) {
                Section {
                    Button { choosingFolder = true } label: { SettingsActionLabel(title: "Choose Folder…", systemImage: "folder") }
                    if let folderError { Text(folderError).font(.footnote).foregroundStyle(DaybookPalette.Ink.warning) }
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
        .task {
            // Already set up here and managed here: its page is where it goes.
            if model.devices.hub.pendingSetup !== session, session.managedElsewhere == nil, session.direct?.isSetUp == true {
                done(session.id)
            }
        }
        .onChange(of: session.isLinked) { _, linked in
            // The recorder answered: it's set up, and this iPhone manages it.
            if linked { done(session.id) }
        }
    }

    @ViewBuilder
    private func discovery(_ connection: any DiscoveringConnection) -> some View {
        let searching = connection.state == .searching
        let connecting = connection.connectingTo != nil
        let found = !connection.discovered.isEmpty
        Section {
            if !searched && !searching && !found && !connecting && !connection.searchFoundNothing {
                Button {
                    searched = true
                    connection.search()
                } label: {
                    SettingsActionLabel(title: "Search for \(session.kind.name)", systemImage: "antenna.radiowaves.left.and.right")
                }
            } else {
                HStack(spacing: SettingsMetrics.gap) {
                    Group {
                        if searching || connecting { ProgressView() } else {
                            Image(systemName: found ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                                .foregroundStyle(DaybookPalette.Ink.secondary)
                        }
                    }
                    .frame(width: tileColumn.value)
                    .accessibilityHidden(true)
                    Text(RecorderStatusWords.discoveryTitle(session.kind, searching: searching, connecting: connecting, found: found))
                        .foregroundStyle(DaybookPalette.Ink.title)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let action = RecorderStatusWords.discoveryAction(searching: searching, connecting: connecting, found: found) {
                        Button(action) { if searching { connection.stopSearching() } else { connection.search() } }
                            .buttonStyle(.daybookLink)
                    }
                }
            }
        }
        Section {
            RecorderDiscoveryContent(session: session, connection: connection)
                .padding(.bottom, DaybookSpacing.s4)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
    }
}
