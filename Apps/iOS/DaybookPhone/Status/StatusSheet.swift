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
    /// The compact detent with a notice or an import's progress over Record.
    static let statusCompactNotice = Self.custom(StatusCompactNoticeDetent.self)
}

/// Tall enough for the Record row and three lines at the person's text size, measured from the
/// fonts they use: at most about half the screen, or 70% at the accessibility sizes, so nothing is
/// cut off.
struct StatusCompactDetent: CustomPresentationDetent {
    /// Room above Record, so the sheet's grabber sits clearly above it.
    static let recordTop: CGFloat = 26
    /// Room between Record and the lines.
    static let recordGap: CGFloat = PhoneStyle.Space.s4
    /// The largest text size the Record row takes: beyond it, Record's label would break mid-word
    /// beside the round buttons. The row is a control bar, with the large content viewer past it.
    static let recordLargestSize = DynamicTypeSize.accessibility1

    static func height(in context: Context) -> CGFloat? {
        height(for: context.dynamicTypeSize, maximum: context.maxDetentValue)
    }

    static func height(for size: DynamicTypeSize, maximum: CGFloat, notice: Bool = false) -> CGFloat {
        func lineHeight(_ style: UIFont.TextStyle, at size: DynamicTypeSize) -> CGFloat {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
            return ceil(UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).lineHeight)
        }
        // Record is at least 60 pt, taller when its label grows; the glass button adds 4 pt each side.
        let record = max(60, lineHeight(.title3, at: min(size, recordLargestSize)) + 8) + 8
        // Three lines, the room between them, and the Mac's progress line under its line.
        let lines = 3 * lineHeight(.subheadline, at: size) + 2 * PhoneStyle.Space.s2 + 6
        // A notice over Record (`RecordingNotice`, or "Importing 2 recordings…"): two lines and the gap under them.
        let notice = notice ? 2 * lineHeight(.footnote, at: size) + PhoneStyle.Space.s2 : 0
        let content = recordTop + notice + record + recordGap + lines + PhoneStyle.Space.s4
        return min(maximum * (size.isAccessibilitySize ? 0.7 : 0.55), content)
    }
}

/// `StatusCompactDetent` with room for a notice over Record, so the lines under it aren't cut off.
struct StatusCompactNoticeDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        StatusCompactDetent.height(for: context.dynamicTypeSize, maximum: context.maxDetentValue, notice: true)
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

    /// Something shows over Record (`RecordStartButton`), so the compact detent makes room for it.
    private var hasNotice: Bool {
        model.notice != nil || model.importing > 0 || (model.recorderOnly != nil && !model.recorder.isActive)
            || (model.recorder.isCapturing && PhoneAppModel.recorderWarning(model.recorder.lastError) != nil)
    }

    func body(content: Content) -> some View {
        let shows = enabled && !session.reading && !session.isSearchPresented && !session.isSelecting && session.place != .trash
        let notice = hasNotice
        content
            .environment(\.statusSheetInset, shows ? StatusCompactDetent.height(for: typeSize, maximum: 900, notice: notice) - 34 : nil)
            .sheet(isPresented: Binding(get: { shows }, set: { _ in })) {
                StatusSheetView(detent: Binding(get: { Self.status(detent) }, set: { detent = Self.presentation($0, notice: notice) }),
                                hostsRecordButton: true)
                    .environment(model)
                    .environment(session)
                    .presentationDetents([notice ? .statusCompactNotice : .statusCompact, .medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationContentInteraction(.resizes)
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
                    .tint(PhoneStyle.accent)
            }
            .onChange(of: shows) { _, shows in
                // Back from a conversation or search: compact again, not wherever it was left.
                if !shows, detent == .large { detent = Self.presentation(.compact, notice: hasNotice) }
            }
            .onChange(of: notice) { _, notice in
                if Self.status(detent) == .compact { detent = Self.presentation(.compact, notice: notice) }
            }
            .task {
                guard !appliedLaunchDetent, let launch = model.options.statusDetent else { return }
                appliedLaunchDetent = true
                try? await Task.sleep(for: .milliseconds(700))
                detent = Self.presentation(launch, notice: hasNotice)
            }
    }

    static func status(_ detent: PresentationDetent) -> StatusDetent {
        detent == .large ? .large : detent == .medium ? .medium : .compact
    }

    static func presentation(_ detent: StatusDetent, notice: Bool) -> PresentationDetent {
        switch detent {
        case .compact: return notice ? .statusCompactNotice : .statusCompact
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
                        .frame(height: Self.contentHeight(detent, in: proxy.size.height))
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

    /// The room the panel takes at the foot of a page this tall: its content, the handle, and the
    /// room under it. The preview keeps clear of it (`LibraryBrowser`).
    static func footprint(_ detent: StatusDetent, in height: CGFloat) -> CGFloat {
        contentHeight(detent, in: height) + handleHeight + PhoneStyle.Space.s2
    }
    /// Three lines, at the default text size (they scroll at larger ones).
    private static let compactContent: CGFloat = 112
    private static let handleHeight: CGFloat = 28

    private static func contentHeight(_ detent: StatusDetent, in height: CGFloat) -> CGFloat {
        switch detent {
        case .compact: return compactContent
        case .medium: return max(220, height * 0.5)
        case .large: return max(220, height - 44 - PhoneStyle.Space.s2 - PhoneStyle.Space.s3)
        }
    }

    /// The grabber: tap to step up (and back down from large), or drag.
    private var handle: some View {
        Button { step(up: detent != .large) } label: {
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: Self.handleHeight)
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
        .pairingSheet(isPresented: $showingPairing)
        .addRecorderSheet(isPresented: $showingAddDevice) { id in
            if let id { open(.device(id)) }
        }
        .onChange(of: detent) { _, detent in
            // Collapsing goes back to the overview.
            if detent != .large, !path.isEmpty { path = [] }
        }
        .task { await openRequestedScreen() }
    }

    /// `--status-open device|mac|storage|add-recorder` (debug): that screen inside the sheet (or Add
    /// Recorder over it), for screenshots.
    private func openRequestedScreen() async {
        guard let screen = model.options.statusOpen else { return }
        // A recorder the device autopilot is still adding: wait for it to connect and import.
        for _ in 0..<150 where screen == "device" && model.devices.sessions.first?.links.recent.isEmpty != false {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(800))
        switch screen {
        case "device": if let session = model.devices.sessions.first { open(.device(session.id)) }
        case "mac": if let mac = model.link.macs.first { open(.mac(mac.id)) }
        case "storage": open(.storage)
        case "add-recorder": showingAddDevice = true
        default: break
        }
    }

    /// A full screen opens with the sheet at full height.
    private func open(_ route: StatusRoute) {
        detent = .large
        path = [route]
    }
}

/// The sections for the detent: Record pinned at the top, clear of the grabber and never scrolled
/// under it, then the lines and groups in a scroll view.
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
        VStack(spacing: 0) {
            if sections.contains(.quickActions) {
                StatusQuickActions()
                    .padding(.horizontal, PhoneStyle.Space.s4)
                    .padding(.top, StatusCompactDetent.recordTop)
                    .padding(.bottom, StatusCompactDetent.recordGap)
            }
            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: PhoneStyle.Space.s5) {
                        ForEach(sections.filter { $0 != .quickActions }, id: \.self) { section in
                            view(for: section, inputs: inputs, now: context.date)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, PhoneStyle.Space.s4)
                    .padding(.top, hostsRecordButton ? 0 : PhoneStyle.Space.s1)
                    .padding(.bottom, PhoneStyle.Space.s4)
                }
            }
            .scrollDisabled(detent == .compact)
            .scrollBounceBehavior(.basedOnSize)
            // `--status-scroll-end`: the foot of the content, for screenshots.
            .defaultScrollAnchor(model.options.statusScrollEnd ? .bottom : nil)
        }
        .animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: sections)
        .animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: detent)
    }

    @ViewBuilder
    private func view(for section: StatusSection, inputs: StatusInputs, now: Date) -> some View {
        switch section {
        case .quickActions: EmptyView()
        case .lines: StatusLines(lines: StatusSheetModel.lines(inputs, now: now), expand: { if detent == .compact { detent = .medium } })
        case .captions: StatusCaptions()
        case .recorders: StatusRecorders(detent: detent, open: open, addRecorder: { showingAddDevice = true })
        case .macs: StatusMacs(inputs: inputs, now: now, open: open, pair: { showingPairing = true })
        case .iphone: StatusThisIPhone(open: open)
        }
    }
}

/// Gathers the sheet's facts from the app model.
@MainActor
enum StatusSheetInputs {
    static func make(_ model: PhoneAppModel, library: LibraryController, hostsRecordButton: Bool) -> StatusInputs {
        let devices = model.devices
        var inputs = StatusInputs()
        inputs.recorders = devices.sessions.map { recorder($0, model: model) }
        inputs.mac = model.macPresence
        inputs.liveProgress = model.liveProgress.values.sorted { $0.receivedAt > $1.receivedAt }
        inputs.queue = StatusSheetModel.queue(meetings: library.meetings, liveProgress: model.liveProgress, thisDevice: library.thisDevice.id,
                                              planners: model.placement.planners, runs: model.placement.runs,
                                              cloudOffered: model.placement.cloudOffer != nil)
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
        inputs.pairedMacs = model.link.macs.map { mac in
            StatusInputs.Mac(id: mac.id, name: mac.name, line: mac.rowLine(recordingBySync: model.isRecordingBySync(mac)),
                             isConnected: mac.isConnected)
        }
        return inputs
    }

    /// One recorder's facts.
    static func recorder(_ session: DeviceSession, model: PhoneAppModel) -> StatusInputs.Recorder {
        let control = session.direct as? any RecordControlConnection
        return StatusInputs.Recorder(
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
            handoff: model.devices.handoffState(session),
            isRecording: session.isLinked && session.status?.isRecording == true,
            isListeningLive: session.isListeningLive,
            problem: session.problem.map { PhoneDeviceCopy.problem($0).title },
            lastConnected: session.direct?.lastConnectedAt ?? session.primary?.lastConnectedAt,
            storageHours: session.status?.storage?.hoursLeft,
            storageIsLow: session.status?.storage.map(StorageFormat.isLow) ?? false,
            hasRecordControl: control != nil,
            hasLiveListening: session.direct is any LiveListeningConnection,
            canConnect: !session.isLinked && !session.state.isBusy && session.direct?.isSetUp == true,
            importRunning: session.queue.current != nil,
            notListed: session.managedElsewhere == nil && session.listingState == .notListed,
            otherAppWait: session.otherAppWait)
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
            .accessibilityShowsLargeContentViewer()
        }
        .dynamicTypeSize(...StatusCompactDetent.recordLargestSize)
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
                if line.countdownUntil != nil {
                    // A summary's countdown, a second at a time.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        lineText(line.text(at: context.date)).monospacedDigit()
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        lineText(line.text)
                        if let short = line.shortText { lineText(short) }
                    }
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

// MARK: Groups and cards

/// A group's heading: a generic label ("Recorders", "Macs"), never a device's name.
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

/// A group below the lines: its heading, then its card (or a card per recorder).
private struct StatusGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            StatusHeading(text: title).padding(.horizontal, StatusCardMetrics.padding)
            content
        }
    }
}

/// The measurements every status card shares, so rows in every card line up.
enum StatusCardMetrics {
    static let radius: CGFloat = 16
    /// Inside a card, on every side of every row.
    static let padding: CGFloat = PhoneStyle.Space.s3
    static let rowVertical: CGFloat = 10
    /// Between the glyph column and the text.
    static let gap: CGFloat = PhoneStyle.Space.s3
    /// The glyph column at the default text size; it grows with Dynamic Type up to `glyphLimit`.
    static let glyph: CGFloat = 32
    static let glyphLimit: CGFloat = 44
}

/// The glyph column's width at the person's text size.
private struct StatusGlyphWidth: DynamicProperty {
    @ScaledMetric(relativeTo: .subheadline) private var scaled = StatusCardMetrics.glyph
    var value: CGFloat { min(scaled, StatusCardMetrics.glyphLimit) }
}

/// One full-width card: the quiet fill, radius 16, an inset divider between rows.
struct StatusCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id { StatusDivider() }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhoneStyle.quietFill, in: RoundedRectangle(cornerRadius: StatusCardMetrics.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: StatusCardMetrics.radius, style: .continuous))
    }
}

/// The divider between a card's rows, from where the text starts.
struct StatusDivider: View {
    private let glyph = StatusGlyphWidth()
    var body: some View {
        Divider().padding(.leading, StatusCardMetrics.padding + glyph.value + StatusCardMetrics.gap)
    }
}

/// A row in a card: a fixed-width glyph column (empty for a row under another), then the content,
/// so text in sibling rows lines up whatever the symbols' widths.
struct StatusRow<Glyph: View, Content: View>: View {
    var alignment: VerticalAlignment = .center
    @ViewBuilder var glyph: Glyph
    @ViewBuilder var content: Content
    private let width = StatusGlyphWidth()

    var body: some View {
        HStack(alignment: alignment, spacing: StatusCardMetrics.gap) {
            glyph.frame(width: width.value)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, StatusCardMetrics.padding)
        .padding(.vertical, StatusCardMetrics.rowVertical)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension StatusRow where Glyph == Color {
    /// A row under another (a recording on its recorder, a conversation under its Mac): indented to the text.
    init(alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.init(alignment: alignment, glyph: { Color.clear }, content: content)
    }
}

/// A device's symbol on a tile: teal while it's connected, secondary otherwise (as `DeviceGlyph`).
struct StatusTile: View {
    let systemImage: String
    var isActive = false
    private let width = StatusGlyphWidth()

    var body: some View {
        let size = width.value
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(isActive ? PhoneStyle.accent : PhoneStyle.Ink.secondary)
            .frame(width: size, height: size)
            .background((isActive ? PhoneStyle.accent : Color.gray).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An action row's symbol, in the link's ink and the tile's size so its text lines up.
struct StatusLinkGlyph: View {
    let systemImage: String
    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.medium))
            .foregroundStyle(PhoneStyle.Ink.link)
            .accessibilityHidden(true)
    }
}

/// A device's name and its status, the top of a row.
struct StatusRowTitle<Subtitle: View>: View {
    let title: String
    @ViewBuilder var subtitle: Subtitle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.wrappingAsName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PhoneStyle.Ink.title)
                .fixedSize(horizontal: false, vertical: true)
            subtitle
                .font(.footnote)
                .foregroundStyle(PhoneStyle.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where a row leads.
struct StatusChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A whole row as a button: it dims while pressed, as a list row does.
struct StatusRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.06) : .clear)
    }
}

extension String {
    /// "Connected · 80%" with the dot kept on the end of a line when it wraps, never starting one.
    var keepingSeparators: String { replacingOccurrences(of: " · ", with: "\u{00A0}· ") }

    /// A device's name, wrapping without leaving a short last word alone on a line: "Vlad’s MacBook /
    /// Pro (755)", not "Vlad’s MacBook Pro / (755)". Names wrap only at spaces.
    var wrappingAsName: String {
        let words = split(separator: " ", omittingEmptySubsequences: false)
        guard words.count >= 3, let last = words.last, last.count <= 5 else { return self }
        return words.dropLast().joined(separator: " ") + "\u{00A0}" + last
    }
}

/// "Use on Vlad’s MacBook Pro (755)": on one line when it fits, else the name starts the next line,
/// so it's never split across the phrase; a name too long for a line wraps at a space, never mid-word.
struct NamePhrase: View {
    let prefix: String
    let name: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text("\(prefix) \(name)")
            VStack(alignment: .leading, spacing: 0) {
                Text(prefix)
                Text(name.wrappingAsName).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(prefix) \(name)")
    }
}

// MARK: Recorders

/// A card per recorder; Add Recorder… when there's none.
private struct StatusRecorders: View {
    let detent: StatusDetent
    let open: (StatusRoute) -> Void
    let addRecorder: () -> Void
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        StatusGroup(title: "Recorders") {
            if model.devices.sessions.isEmpty {
                StatusCard {
                    Button(action: addRecorder) {
                        StatusRow {
                            StatusLinkGlyph(systemImage: "plus")
                        } content: {
                            Text("Add Recorder…").font(.subheadline.weight(.medium)).foregroundStyle(PhoneStyle.Ink.link)
                        }
                    }
                    .buttonStyle(StatusRowButtonStyle())
                }
            }
            VStack(spacing: PhoneStyle.Space.s3) {
                ForEach(model.devices.sessions) { session in
                    StatusRecorderCard(session: session, detent: detent, open: open)
                }
            }
        }
    }
}

/// One recorder: its name and status (opening its page), its handoff, and at the large detent its
/// storage, its actions, and the recordings waiting on it.
private struct StatusRecorderCard: View {
    @ObservedObject var session: DeviceSession
    let detent: StatusDetent
    let open: (StatusRoute) -> Void
    @Environment(PhoneAppModel.self) private var model
    private let glyph = StatusGlyphWidth()

    var body: some View {
        let recorder = StatusSheetInputs.recorder(session, model: model)
        let manages = StatusSheetModel.showsManagement(detent)
        let actions = manages ? StatusSheetModel.actions(for: recorder) : []
        let waiting = manages && session.managedElsewhere == nil ? Array(session.newRecordings.prefix(4)) : []
        StatusCard {
            Button { open(.device(session.id)) } label: {
                StatusRow {
                    DeviceGlyph(session: session, size: glyph.value)
                } content: {
                    HStack(spacing: PhoneStyle.Space.s2) {
                        StatusRowTitle(title: session.device.name) {
                            status(storage: manages ? recorder.storageHours : nil, low: recorder.storageIsLow)
                        }
                        Spacer(minLength: 0)
                        StatusChevron()
                    }
                }
            }
            .buttonStyle(StatusRowButtonStyle())
            .accessibilityHint("Shows \(session.device.name)")

            if RecorderHandoffCard.shows(session, devices: model.devices) {
                RecorderHandoffCard(session: session)
            }
            if !actions.isEmpty {
                StatusRecorderActions(session: session, actions: actions)
            }
            ForEach(waiting) { recording in
                StatusRow {
                    HStack(spacing: PhoneStyle.Space.s2) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.title).font(.subheadline).foregroundStyle(PhoneStyle.Ink.body)
                            Text(recording.detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                        if session.isConnected {
                            Button { session.importRecordings([recording]) } label: {
                                Text("Import")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(PhoneStyle.Ink.link)
                                    .padding(.horizontal, PhoneStyle.Space.s3)
                                    .padding(.vertical, 5)
                                    .background(PhoneStyle.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Import \(recording.title)")
                        }
                    }
                }
            }
            if !waiting.isEmpty {
                Button { open(.device(session.id)) } label: {
                    StatusRow {
                        HStack {
                            Text("All Recordings").font(.subheadline.weight(.medium)).foregroundStyle(PhoneStyle.Ink.link)
                            Spacer(minLength: 0)
                            StatusChevron()
                        }
                    }
                }
                .buttonStyle(StatusRowButtonStyle())
            }
        }
    }

    /// "Connected · 80%", and at the large detent its room: "About 2,170 hours left" (orange when low),
    /// on the same line when it fits.
    @ViewBuilder
    private func status(storage hours: Double?, low: Bool) -> some View {
        let line = PhoneDeviceCopy.line(for: session).keepingSeparators
        if let hours {
            let storage = Text(StatusSheetModel.storageLeft(hours: hours))
                .foregroundStyle(low ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
            ViewThatFits(in: .horizontal) {
                Text("\(line) · \(storage)").lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line)
                    storage
                }
            }
        } else {
            Text(line)
        }
    }
}

/// The recorder's actions as one row of equal-width buttons (stacked at the accessibility sizes).
struct StatusRecorderActions: View {
    @ObservedObject var session: DeviceSession
    let actions: [StatusRecorderAction]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: PhoneStyle.Space.s2)) : AnyLayout(HStackLayout(spacing: PhoneStyle.Space.s2))
        layout {
            ForEach(actions, id: \.self) { action in
                button(action, stacked: stacked)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(StatusCardMetrics.padding)
    }

    @ViewBuilder
    private func button(_ action: StatusRecorderAction, stacked: Bool) -> some View {
        let control = session.direct as? any RecordControlConnection
        let live = session.direct as? any LiveListeningConnection
        let short = session.kind.shortName
        switch action {
        case .connect:
            ActionTile(title: "Connect", systemImage: "antenna.radiowaves.left.and.right", stacked: stacked) { session.connect() }
        case .record:
            ActionTile(title: "Record on \(short)", shortTitle: "Record", systemImage: "record.circle", stacked: stacked,
                       pending: control?.recordCommandPending == true) { control?.startRecording() }
        case .pause:
            ActionTile(title: "Pause on \(short)", shortTitle: "Pause", systemImage: "pause.circle", stacked: stacked,
                       pending: control?.recordCommandPending == true, spoken: "Pause Recording on \(short)") { control?.pauseRecording() }
        case .importNew(let count):
            ActionTile(title: "Import \(count) New", systemImage: "arrow.down.circle", stacked: stacked,
                       spoken: count == 1 ? "Import 1 New Recording" : "Import \(count) New Recordings") {
                session.importRecordings(session.newRecordings)
            }
        case .checkForNew:
            ActionTile(title: "Check for New Recordings", shortTitle: "Check for New", systemImage: "arrow.clockwise", stacked: stacked) {
                session.direct?.refresh()
            }
        case .listenLive:
            ActionTile(title: "Listen Live", systemImage: "ear", stacked: stacked) { live?.startListening() }
        case .stopListening:
            ActionTile(title: "Stop Listening", systemImage: "stop.circle", stacked: stacked) { live?.stopListening() }
        }
    }
}

/// One of a recorder's actions: its symbol over its name, in an equal share of the row.
private struct ActionTile: View {
    let title: String
    var shortTitle: String?
    let systemImage: String
    let stacked: Bool
    var pending = false
    /// What VoiceOver says, when it's more than the title.
    var spoken: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if stacked {
                    HStack(spacing: PhoneStyle.Space.s3) {
                        symbol
                        Text(title).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PhoneStyle.Space.s3)
                } else {
                    VStack(spacing: PhoneStyle.Space.s1) {
                        symbol
                        ViewThatFits(in: .horizontal) {
                            Text(title).lineLimit(1)
                            if let shortTitle { Text(shortTitle).lineLimit(1) }
                            Text(shortTitle ?? title).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, PhoneStyle.Space.s1)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PhoneStyle.Ink.link)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, PhoneStyle.Space.s2 + 2)
            .background(PhoneStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ActionTileStyle())
        .disabled(pending)
        .accessibilityLabel(spoken ?? title)
    }

    @ViewBuilder private var symbol: some View {
        if pending {
            ProgressView().controlSize(.small).frame(height: 22)
        } else {
            Image(systemName: systemImage).font(.title3.weight(.medium)).frame(height: 22).accessibilityHidden(true)
        }
    }
}

private struct ActionTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
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
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                // The person live speakers recognized, as the recording screen names them.
                                if let name = segment.speaker?.name {
                                    Text(name).font(.callout.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.meta).lineLimit(1).fixedSize()
                                }
                                Text(segment.text)
                                    .font(.callout)
                                    .foregroundStyle(segment.isTentative ? PhoneStyle.Ink.secondary : PhoneStyle.Ink.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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

// MARK: Macs

/// Every paired Mac (and one the library syncs with that isn't paired here), the queue under the
/// Mac doing it, and Pair with Your Mac….
private struct StatusMacs: View {
    let inputs: StatusInputs
    let now: Date
    let open: (StatusRoute) -> Void
    let pair: () -> Void

    var body: some View {
        let rows = StatusSheetModel.macRows(inputs, now: now)
        StatusGroup(title: "Macs") {
            StatusCard {
                // Work no Mac here is doing yet (no Mac has synced): at the top, under none.
                if !rows.contains(where: \.showsQueue) {
                    ForEach(inputs.queue) { entry in QueueRow(entry: entry, macName: nil) }
                }
                ForEach(rows) { row in
                    macRow(row)
                    if row.showsQueue {
                        ForEach(inputs.queue) { entry in QueueRow(entry: entry, macName: row.name) }
                    }
                }
                Button(action: pair) {
                    StatusRow {
                        StatusLinkGlyph(systemImage: "plus")
                    } content: {
                        Text("Pair with Your Mac…").font(.subheadline.weight(.medium)).foregroundStyle(PhoneStyle.Ink.link)
                    }
                }
                .buttonStyle(StatusRowButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func macRow(_ row: StatusMacRow) -> some View {
        let label = StatusRow {
            StatusTile(systemImage: "desktopcomputer", isActive: row.isConnected)
        } content: {
            HStack(spacing: PhoneStyle.Space.s2) {
                StatusRowTitle(title: row.name) { Text(row.text.keepingSeparators) }
                Spacer(minLength: 0)
                if case .paired = row.id { StatusChevron() }
            }
        }
        switch row.id {
        case .paired(let id):
            Button { open(.mac(id)) } label: { label }
                .buttonStyle(StatusRowButtonStyle())
                .accessibilityHint("Shows \(row.name)")
        case .synced:
            label.accessibilityElement(children: .combine)
        }
    }
}

/// A conversation in the queue, under the Mac doing it (which it then doesn't name again).
private struct QueueRow: View {
    let entry: StatusQueueEntry
    let macName: String?
    @State private var showingDetails = false
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        StatusRow {
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.subheadline).foregroundStyle(PhoneStyle.Ink.body).lineLimit(2)
                    if entry.countdownUntil != nil {
                        // A summary's countdown, a second at a time.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(entry.line(under: macName, at: context.date).keepingSeparators)
                                .foregroundStyle(PhoneStyle.Ink.secondary).monospacedDigit()
                        }
                        .font(.footnote)
                    } else {
                    Text("\(Text(entry.line(under: macName).keepingSeparators).foregroundStyle(entry.failed ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary))\(Text(entry.requestedHere ? " · Requested from this iPhone" : "").foregroundStyle(PhoneStyle.Ink.meta))")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail = entry.detail {
                        Text(detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if entry.isRunning, let progress = entry.progress {
                        StatusProgressLine(fraction: progress).padding(.top, 2)
                    }
                }
                .accessibilityElement(children: .combine)
                if entry.details != nil {
                    Button("Details") { showingDetails = true }
                        .buttonStyle(.daybookLink)
                        .font(.footnote.weight(.semibold))
                }
                // Where its summary runs: Use the Cloud, Start Now, Wait for a Mac.
                if !entry.actions.isEmpty {
                    HStack(spacing: PhoneStyle.Space.s4) {
                        ForEach(entry.actions, id: \.self) { action in
                            Button(action.title) { model.placement.perform(action, for: entry.id) }
                                .buttonStyle(.daybookLink)
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingDetails) { DetailsSheet(text: entry.details ?? "") }
    }
}

// MARK: This iPhone

/// The audio kept on this iPhone, opening Storage.
private struct StatusThisIPhone: View {
    let open: (StatusRoute) -> Void
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        StatusGroup(title: "This iPhone") {
            StatusCard {
                Button { open(.storage) } label: {
                    StatusRow {
                        StatusTile(systemImage: "iphone")
                    } content: {
                        HStack(spacing: PhoneStyle.Space.s2) {
                            Text(StatusSheetModel.audioOnThisIPhone(bytes: model.audio.usage.bytes))
                                .font(.subheadline)
                                .foregroundStyle(PhoneStyle.Ink.title)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            StatusChevron()
                        }
                    }
                }
                .buttonStyle(StatusRowButtonStyle())
                .accessibilityHint("Shows storage")
            }
        }
    }
}
