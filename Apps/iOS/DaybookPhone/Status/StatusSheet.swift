import DaybookCaptions
import DaybookKit
import DaybookLink
import SwiftUI

// The status sheet (docs/iphone.md, "Status sheet"): the recorder, your Mac, and sync at a glance,
// expanding to manage them, like Maps or Find My.
//
// - Pocket (closed, or an iPhone 18 Pro): a persistent system sheet on the library screens, with a
//   compact detent that hosts Record, Import, and Search at the thumb (`StatusSheetHost`).
// - Notebook (open, or partly open in the library): a panel at the foot of the right page that never
//   crosses the crease or covers the reading spread (`StatusPanel`, placed by `LibraryBrowser`).
// - Recording: hidden. `RecordingSurface` replaces the library and shows the recorder's essentials.

extension EnvironmentValues {
    /// Set while the status sheet hosts Record at the foot of the pocket library: the room to leave
    /// for it. `LibraryPage` then shows only the mini player there, just above the sheet.
    @Entry var statusSheetInset: CGFloat? = nil
}

extension PresentationDetent {
    /// The compact detent: three lines and the Record row.
    static let statusCompact = Self.custom(StatusCompactDetent.self)
}

/// Tall enough for the Record row and three lines at the person's text size, never more than half
/// the screen.
struct StatusCompactDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        height(for: context.dynamicTypeSize, maximum: context.maxDetentValue)
    }

    static func height(for size: DynamicTypeSize, maximum: CGFloat) -> CGFloat {
        let extra: CGFloat
        switch size {
        case ...DynamicTypeSize.large: extra = 0
        case .xLarge: extra = 14
        case .xxLarge: extra = 28
        case .xxxLarge: extra = 42
        default: extra = 120
        }
        return min(maximum * 0.55, 196 + extra)
    }
}

// MARK: Pocket: the sheet

/// Presents the status sheet over the pocket library while it's the thing on screen: not over a
/// conversation, search, selection, or the Trash. Other sheets and alerts (Settings, Move, Tags)
/// open above it, as they do over Maps' sheet.
struct StatusSheetHost: ViewModifier {
    let enabled: Bool
    @Environment(PhoneAppModel.self) private var model
    @Environment(ReadingSession.self) private var session
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detent: PresentationDetent = .statusCompact
    @State private var appliedLaunchDetent = false

    func body(content: Content) -> some View {
        let shows = enabled && !session.reading && !session.isSearchPresented && !session.isSelecting && session.place != .trash
        content
            .environment(\.statusSheetInset, shows ? StatusCompactDetent.height(for: typeSize, maximum: 900) - 34 : nil)
            .sheet(isPresented: Binding(get: { shows }, set: { _ in })) {
                StatusSheetView(detent: Binding(get: { Self.status(detent) }, set: { detent = Self.presentation($0) }),
                                hostsRecordButton: true)
                    .environment(model)
                    .environment(session)
                    .presentationDetents([.statusCompact, .medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationContentInteraction(.resizes)
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
                    .tint(PhoneStyle.accent)
            }
            .onChange(of: shows) { _, shows in
                // Back from a conversation or search: compact again, not wherever it was left.
                if !shows, detent == .large { detent = .statusCompact }
            }
            .task {
                guard !appliedLaunchDetent, let launch = model.options.statusDetent else { return }
                appliedLaunchDetent = true
                try? await Task.sleep(for: .milliseconds(700))
                detent = Self.presentation(launch)
            }
    }

    static func status(_ detent: PresentationDetent) -> StatusDetent {
        detent == .large ? .large : detent == .medium ? .medium : .compact
    }

    static func presentation(_ detent: StatusDetent) -> PresentationDetent {
        switch detent {
        case .compact: return .statusCompact
        case .medium: return .medium
        case .large: return .large
        }
    }
}

// MARK: Notebook: the panel on the right page

/// The status at the foot of the right page of the open iPhone Duo. Compact, it's the three lines;
/// medium takes half the page; large takes the page (the conversation preview steps aside). It
/// stays on its page, clear of the crease, and hides while a conversation is open across both pages.
struct StatusPanel: View {
    @Binding var detent: StatusDetent
    @Environment(\.creaseEdge) private var creaseEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    handle
                    StatusSheetView(detent: $detent, hostsRecordButton: false)
                        .frame(height: contentHeight(in: proxy.size.height))
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .padding(.leading, creaseEdge == .leading ? PhoneStyle.Page.creaseClearance : PhoneStyle.Space.s3)
                .padding(.trailing, PhoneStyle.Space.s3)
                .padding(.bottom, PhoneStyle.Space.s2)
                .offset(y: max(-40, min(40, drag)))
            }
        }
        .animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: detent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
        .accessibilityActions {
            if detent != .large { Button("Expand") { step(up: true) } }
            if detent != .compact { Button("Collapse") { step(up: false) } }
        }
    }

    /// The room the compact panel takes at the foot of the page (the preview scrolls clear of it).
    static let compactFootprint: CGFloat = compactContent + 28 + PhoneStyle.Space.s2
    /// Three lines, at the default text size (they scroll at larger ones).
    private static let compactContent: CGFloat = 112

    private func contentHeight(in height: CGFloat) -> CGFloat {
        switch detent {
        case .compact: return Self.compactContent
        case .medium: return max(220, height * 0.5)
        case .large: return max(220, height - 44 - PhoneStyle.Space.s2 - PhoneStyle.Space.s3)
        }
    }

    /// The grabber: tap to step up (and back down from large), or drag.
    private var handle: some View {
        Button { step(up: detent != .large) } label: {
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Status")
        .accessibilityValue(detent == .compact ? "Compact" : detent == .medium ? "Half" : "Full")
        .accessibilityHint(detent == .large ? "Collapses the status" : "Shows more")
        .gesture(DragGesture(minimumDistance: 8)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                if value.translation.height < -30 { step(up: true) } else if value.translation.height > 30 { step(up: false) }
            })
    }

    private func step(up: Bool) {
        let all = StatusDetent.allCases
        guard let index = all.firstIndex(of: detent) else { return }
        let next = up ? min(all.count - 1, index + 1) : max(0, index - 1)
        detent = all[next]
    }
}

// MARK: The content

/// Where the sheet's links lead: the full screens, not copies of them.
enum StatusRoute: Hashable {
    case device(String)
    case mac(UUID)
    case storage
}

/// The sheet's content for a detent, shared by the pocket sheet and the notebook panel.
struct StatusSheetView: View {
    @Binding var detent: StatusDetent
    let hostsRecordButton: Bool
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [StatusRoute] = []
    @State private var showingPairing = false
    @State private var showingAddDevice = false

    var body: some View {
        NavigationStack(path: $path) {
            StatusSections(library: model.library.controller, detent: $detent, hostsRecordButton: hostsRecordButton,
                           open: open, showingPairing: $showingPairing, showingAddDevice: $showingAddDevice)
                .toolbar(.hidden, for: .navigationBar)
                // The sheet's (or panel's) Liquid Glass shows through; content is never glass itself.
                .containerBackground(.clear, for: .navigation)
                .navigationDestination(for: StatusRoute.self) { route in
                    switch route {
                    case .device(let id): DevicePage(sessionID: id)
                    case .mac(let id): MacDetailScreen(macID: id)
                    case .storage: StorageScreen()
                    }
                }
        }
        .sheet(isPresented: $showingPairing) { PairingSheet() }
        .sheet(isPresented: $showingAddDevice) {
            AddDeviceSheet { id in
                showingAddDevice = false
                if let id { open(.device(id)) }
            }
        }
        .onChange(of: detent) { _, detent in
            // Collapsing goes back to the overview.
            if detent != .large, !path.isEmpty { path = [] }
        }
    }

    /// A full screen opens with the sheet at full height.
    private func open(_ route: StatusRoute) {
        detent = .large
        path = [route]
    }
}

/// The sections for the detent, in a scroll view.
private struct StatusSections: View {
    @ObservedObject var library: LibraryController
    @Binding var detent: StatusDetent
    let hostsRecordButton: Bool
    let open: (StatusRoute) -> Void
    @Binding var showingPairing: Bool
    @Binding var showingAddDevice: Bool
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let inputs = StatusSheetInputs.make(model, library: library, hostsRecordButton: hostsRecordButton)
        let sections = StatusSheetModel.sections(for: detent, inputs)
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: PhoneStyle.Space.s4) {
                    ForEach(sections, id: \.self) { section in
                        view(for: section, inputs: inputs, now: context.date)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, PhoneStyle.Space.s4)
                .padding(.top, hostsRecordButton ? PhoneStyle.Space.s4 : PhoneStyle.Space.s1)
                .padding(.bottom, PhoneStyle.Space.s4)
            }
        }
        .scrollDisabled(detent == .compact)
        .scrollBounceBehavior(.basedOnSize)
        .animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: sections)
    }

    @ViewBuilder
    private func view(for section: StatusSection, inputs: StatusInputs, now: Date) -> some View {
        switch section {
        case .quickActions: StatusQuickActions()
        case .lines: StatusLines(lines: StatusSheetModel.lines(inputs, now: now), expand: { if detent == .compact { detent = .medium } })
        case .recorders: StatusRecorders(open: open, addRecorder: { showingAddDevice = true })
        case .captions: StatusCaptions()
        case .mac: StatusMac(inputs: inputs, now: now, open: open)
        case .controls: StatusControls()
        case .waiting: StatusWaiting(open: open)
        case .storage: StatusStorage(open: open)
        case .pairing: StatusPairing(open: open, pair: { showingPairing = true })
        }
    }
}

/// Gathers the sheet's facts from the app model.
@MainActor
enum StatusSheetInputs {
    static func make(_ model: PhoneAppModel, library: LibraryController, hostsRecordButton: Bool) -> StatusInputs {
        let devices = model.devices
        var inputs = StatusInputs()
        inputs.recorders = devices.sessions.map { session in
            StatusInputs.Recorder(
                id: session.id, name: session.device.name, shortName: session.kind.shortName,
                isDirect: session.direct != nil, state: session.state, isLinked: session.isLinked,
                batteryLevel: session.status?.battery?.level, batteryCharging: session.status?.battery?.charging == true,
                newCount: session.managedElsewhere == nil ? session.newRecordings.count : 0,
                importing: session.queue.isActive
                    ? .init(position: session.queue.position, total: session.queue.total, fraction: session.importProgress,
                            suspended: session.queue.isSuspended)
                    : nil,
                managedBy: session.managedElsewhere?.ownerName,
                lastKnown: StatusSheetInputs.lastKnown(session, link: model.link),
                handoff: devices.handoffState(session),
                isRecording: session.isLinked && session.status?.isRecording == true,
                isListeningLive: session.isListeningLive,
                problem: session.problem.map { PhoneDeviceCopy.problem($0).title },
                lastConnected: session.direct?.lastConnectedAt ?? session.primary?.lastConnectedAt,
                storageHours: session.status?.storage?.hoursLeft,
                storageIsLow: session.status?.storage.map(StorageFormat.isLow) ?? false)
        }
        inputs.mac = model.macPresence
        inputs.liveProgress = model.liveProgress.values.sorted { $0.receivedAt > $1.receivedAt }
        inputs.queue = StatusSheetModel.queue(meetings: library.meetings, liveProgress: model.liveProgress, thisDevice: library.thisDevice.id)
        inputs.syncLine = model.sync.statusLine
        switch model.sync.connection {
        case .checking: inputs.syncTone = .checking
        case .unavailable:
            inputs.syncTone = .attention
            // The full reason is in Settings; the line fits one row.
            inputs.syncLine = "Off"
        case .connected:
            inputs.syncTone = model.sync.lastError != nil ? .attention : model.sync.isUpToDate ? .upToDate : .working
        }
        inputs.hostsRecordButton = hostsRecordButton
        inputs.hasLiveCaptions = devices.sessions.contains { $0.isListeningLive }
        inputs.pairedMacs = model.link.macs.count
        return inputs
    }

    /// A recorder that isn't live here: what the Mac managing it last said, or its last state here.
    static func lastKnown(_ session: DeviceSession, link: PhoneLink, now: Date = Date()) -> String? {
        guard !session.isLinked else { return nil }
        if session.managedElsewhere != nil {
            return link.recorderReport(kind: session.kind.id, serial: session.recorderSerial, now: now)?.state.summary(now: now)
        }
        return LinkRecorderState(session: session)?.summary(now: now)
    }
}

// MARK: Compact

/// Record, Import, and Search, at the thumb (they move here from the library's foot while the
/// sheet is up, so there's one bottom surface rather than two stacked).
private struct StatusQuickActions: View {
    @Environment(ReadingSession.self) private var session

    var body: some View {
        HStack(alignment: .bottom, spacing: PhoneStyle.Space.s2) {
            RecordStartButton()
            Button { session.isSearchPresented = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.title3.weight(.medium))
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .foregroundStyle(PhoneStyle.Ink.title)
            .accessibilityLabel("Search")
            .accessibilityHint("Searches titles, notes, transcripts, and summaries")
        }
    }
}

/// The three lines: recorder, Mac, sync.
private struct StatusLines: View {
    let lines: [StatusLine]
    let expand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            ForEach(lines) { line in
                Button(action: expand) { StatusLineRow(line: line) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line.accessibilityLabel)
                    .accessibilityHint("Shows more")
            }
        }
    }
}

struct StatusLineRow: View {
    let line: StatusLine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: PhoneStyle.Space.s2) {
                glyph.frame(width: 22)
                Text(line.title)
                    .font(PhoneStyle.Typeface.statusLead)
                    .foregroundStyle(PhoneStyle.Ink.title)
                    .lineLimit(1)
                    .layoutPriority(1)
                ViewThatFits(in: .horizontal) {
                    lineText(line.text)
                    if let short = line.shortText { lineText(short) }
                }
                Spacer(minLength: 0)
            }
            if line.tone == .working, let progress = line.progress {
                StatusProgressLine(fraction: progress).padding(.leading, 30)
            }
        }
        .contentShape(Rectangle())
    }

    private func lineText(_ text: String) -> some View {
        Text(text)
            .font(PhoneStyle.Typeface.status)
            .foregroundStyle(ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.numericText())
    }

    @ViewBuilder private var glyph: some View {
        switch line.tone {
        case .recording:
            Circle().fill(PhoneStyle.Ink.record).frame(width: 9, height: 9).accessibilityHidden(true)
        default:
            Image(systemName: line.symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(glyphInk)
                .symbolEffect(.variableColor.iterative, isActive: line.tone == .working && line.progress == nil && !reduceMotion)
                .accessibilityHidden(true)
        }
    }

    private var ink: Color {
        switch line.tone {
        case .attention: return PhoneStyle.Ink.warning
        default: return PhoneStyle.Ink.secondary
        }
    }

    private var glyphInk: Color {
        switch line.tone {
        case .linked: return PhoneStyle.accent
        case .attention: return PhoneStyle.Ink.warning
        case .working: return PhoneStyle.Ink.link
        default: return PhoneStyle.Ink.meta
        }
    }
}

/// Work in progress: the 2 pt brand-gradient line, as in a list row that's transcribing.
struct StatusProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(PhoneStyle.quietFill)
                Capsule().fill(PhoneStyle.brandGradient).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 2)
        .animation(.linear(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

// MARK: Medium

private struct StatusHeading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PhoneStyle.Ink.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Every recorder, with handoff.
private struct StatusRecorders: View {
    let open: (StatusRoute) -> Void
    let addRecorder: () -> Void
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            StatusHeading(text: "Recorders")
            if model.devices.sessions.isEmpty {
                Button("Add Recorder…", action: addRecorder)
                    .font(PhoneStyle.Typeface.statusLead).foregroundStyle(PhoneStyle.Ink.link)
            }
            ForEach(model.devices.sessions) { session in
                RecorderHandoffCard(session: session, open: { open(.device(session.id)) })
            }
        }
    }
}

/// Live listening captions, while a recorder streams. Tentative; never the transcript.
private struct StatusCaptions: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        ForEach(model.devices.sessions.filter(\.isListeningLive)) { session in
            VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
                HStack(spacing: 6) {
                    Circle().fill(PhoneStyle.Ink.record).frame(width: 7, height: 7).accessibilityHidden(true)
                    StatusHeading(text: "Listening to \(session.device.name)")
                }
                let segments = Array(session.liveCaptions.suffix(3))
                if segments.isEmpty {
                    Text("Waiting for speech…").font(PhoneStyle.Typeface.status).foregroundStyle(PhoneStyle.Ink.meta)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(segments) { segment in
                            Text(segment.text)
                                .font(.callout)
                                .foregroundStyle(segment.isTentative ? PhoneStyle.Ink.secondary : PhoneStyle.Ink.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Live captions")
                }
                Text("Live captions · tentative")
                    .font(PhoneStyle.Typeface.colophon).foregroundStyle(PhoneStyle.Ink.meta)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PhoneStyle.Space.s3)
            .background(PhoneStyle.quietFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// The Mac and its queue.
private struct StatusMac: View {
    let inputs: StatusInputs
    let now: Date
    let open: (StatusRoute) -> Void
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            HStack {
                StatusHeading(text: inputs.mac.macName ?? "Your Mac")
                Spacer()
                if let mac = macToOpen {
                    Button("Details") { open(.mac(mac)) }
                        .font(.footnote.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.link)
                }
            }
            // A connected Mac is named in the heading and the line above; nothing to add.
            if case .connected = inputs.mac {} else {
                Text(inputs.mac.summary(now: now))
                    .font(PhoneStyle.Typeface.status).foregroundStyle(PhoneStyle.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if inputs.queue.isEmpty {
                Text("Nothing waiting to be transcribed.").font(PhoneStyle.Typeface.status).foregroundStyle(PhoneStyle.Ink.meta)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(inputs.queue) { entry in
                        QueueRow(entry: entry)
                        if entry.id != inputs.queue.last?.id { Divider().padding(.leading, PhoneStyle.Space.s3) }
                    }
                }
                .background(PhoneStyle.quietFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var macToOpen: UUID? {
        if let connected = model.link.connectedMacs.first { return connected.id }
        return model.link.macs.first?.id
    }
}

private struct QueueRow: View {
    let entry: StatusQueueEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).font(.subheadline).foregroundStyle(PhoneStyle.Ink.body).lineLimit(1)
            Text("\(Text(entry.line).foregroundStyle(entry.failed ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary))\(Text(entry.requestedHere ? " · Requested from this iPhone" : "").foregroundStyle(PhoneStyle.Ink.meta))")
                .font(.footnote)
                .lineLimit(2)
            if entry.isRunning, let progress = entry.progress {
                StatusProgressLine(fraction: progress)
            }
        }
        .padding(.horizontal, PhoneStyle.Space.s3)
        .padding(.vertical, PhoneStyle.Space.s2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Large

/// Import now, record on the recorder, Listen Live.
private struct StatusControls: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        ForEach(model.devices.sessions.filter { $0.direct != nil && $0.managedElsewhere == nil }) { session in
            RecorderControlsCard(session: session)
        }
    }
}

private struct RecorderControlsCard: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        let new = session.newRecordings
        let control = session.direct as? any RecordControlConnection
        let live = session.direct as? any LiveListeningConnection
        let recording = session.status?.isRecording == true
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            StatusHeading(text: "\(session.device.name) controls")
            if !session.isLinked {
                Button {
                    session.connect()
                } label: { Label(session.state.isBusy ? "Connecting…" : "Connect", systemImage: "antenna.radiowaves.left.and.right") }
                .disabled(session.state.isBusy || session.direct?.isSetUp != true)
            }
            Button {
                session.importRecordings(new)
            } label: {
                Label(new.isEmpty ? "Nothing New to Import" : new.count == 1 ? "Import 1 New Recording" : "Import \(new.count) New Recordings",
                      systemImage: "arrow.down.circle")
            }
            .disabled(new.isEmpty || session.queue.isActive)
            if let control {
                Button {
                    if recording { control.pauseRecording() } else { control.startRecording() }
                } label: {
                    Label(recording ? "Pause Recording on \(session.kind.shortName)" : "Record on \(session.kind.shortName)",
                          systemImage: recording ? "pause.circle" : "record.circle")
                }
                .disabled(!session.isLinked || control.recordCommandPending || session.queue.current != nil)
            }
            if let live {
                Button {
                    if live.live.isListening { live.stopListening() } else { live.startListening() }
                } label: {
                    Label(live.live.isListening ? "Stop Listening" : "Listen Live", systemImage: "ear")
                }
                .disabled(!live.live.isListening && (!recording || !session.isLinked || session.queue.current != nil))
            }
            if !recording, session.isLinked, live != nil {
                Text("Listen Live works while \(session.kind.shortName) is recording.")
                    .font(PhoneStyle.Typeface.colophon).foregroundStyle(PhoneStyle.Ink.meta)
            }
        }
        .buttonStyle(.bordered)
        .tint(PhoneStyle.accent)
        .font(.subheadline.weight(.medium))
    }
}

/// Recordings waiting on a recorder, with the full list a tap away.
private struct StatusWaiting: View {
    let open: (StatusRoute) -> Void
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        ForEach(model.devices.sessions.filter { $0.managedElsewhere == nil && !$0.newRecordings.isEmpty }) { session in
            VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
                HStack {
                    StatusHeading(text: "Waiting on \(session.kind.shortName)")
                    Spacer()
                    Button("All Recordings") { open(.device(session.id)) }
                        .font(.footnote.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.link)
                }
                VStack(alignment: .leading, spacing: 0) {
                    let new = session.newRecordings
                    ForEach(new.prefix(4)) { recording in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recording.title).font(.subheadline)
                                Text(recording.detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                            }
                            Spacer()
                            Button("Import") { session.importRecordings([recording]) }
                                .buttonStyle(.bordered).tint(PhoneStyle.accent).controlSize(.small)
                                .disabled(!session.isConnected)
                        }
                        .padding(.horizontal, PhoneStyle.Space.s3)
                        .padding(.vertical, PhoneStyle.Space.s2)
                        if recording.id != new.prefix(4).last?.id { Divider().padding(.leading, PhoneStyle.Space.s3) }
                    }
                }
                .background(PhoneStyle.quietFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

/// The recorder's space and this iPhone's downloaded audio.
private struct StatusStorage: View {
    let open: (StatusRoute) -> Void
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            HStack {
                StatusHeading(text: "Storage")
                Spacer()
                Button("Manage") { open(.storage) }.font(.footnote.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.link)
            }
            ForEach(model.devices.sessions.filter { $0.status?.storage != nil }) { session in
                if let storage = session.status?.storage {
                    Label("\(session.device.name): \(StorageFormat.hoursLeft(storage))", systemImage: "internaldrive")
                        .foregroundStyle(StorageFormat.isLow(storage) ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
                }
            }
            let used = model.audio.usage.bytes
            Label(used == 0 ? "No audio downloaded on this iPhone" : "\(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)) of audio downloaded on this iPhone",
                  systemImage: "iphone")
                .foregroundStyle(PhoneStyle.Ink.secondary)
        }
        .font(PhoneStyle.Typeface.status)
    }
}

/// Macs paired over Wi‑Fi, and pairing another.
private struct StatusPairing: View {
    let open: (StatusRoute) -> Void
    let pair: () -> Void
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            StatusHeading(text: "Macs")
            if !model.link.macs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.link.macs) { mac in
                        Button { open(.mac(mac.id)) } label: {
                            HStack {
                                MacRow(mac: mac)
                                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, PhoneStyle.Space.s3)
                            .padding(.vertical, PhoneStyle.Space.s2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if mac.id != model.link.macs.last?.id { Divider().padding(.leading, PhoneStyle.Space.s3) }
                    }
                }
                .background(PhoneStyle.quietFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Button("Pair a Mac…", action: pair)
                .font(PhoneStyle.Typeface.statusLead).foregroundStyle(PhoneStyle.Ink.link)
        }
    }
}
