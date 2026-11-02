import DaybookCaptions
import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI

// The status sheet (docs/iphone.md, "Status sheet"): the recorder, your Mac, this iPhone's own work,
// and sync at a glance, expanding to manage them, like Maps or Find My. It's the status overview both
// apps share (DaybookUI's `StatusOverview`), a depth per detent.
//
// - Pocket (closed, or an iPhone 18 Pro upright): a persistent system sheet on the library screens,
//   with a compact detent that hosts Record, Import, and Search at the thumb (`StatusSheetHost`).
// - Notebook (open, partly open in the library, or any iPhone on its side): a panel at the foot of
//   the right page that never crosses the crease or covers the reading spread (`StatusPanel`, placed
//   by `LibraryBrowser`).
// - Recording: hidden. `RecordingSurface` replaces the library and shows the recorder's essentials.

extension EnvironmentValues {
    /// Set while the status sheet hosts Record at the foot of the pocket library: the room to leave
    /// for it. `LibraryPage` then shows only the mini player there, just above the sheet.
    @Entry var statusSheetInset: CGFloat? = nil
}

extension PresentationDetent {
    /// The compact detent: the Record row and the lines (three, or four while this iPhone has work of its
    /// own), with room for a notice or an import's progress over Record when there's one.
    static func statusCompact(notice: Bool, workLine: Bool) -> PresentationDetent {
        switch (notice, workLine) {
        case (false, false): return .custom(StatusCompactDetent.self)
        case (true, false): return .custom(StatusCompactShaped<WithNotice>.self)
        case (false, true): return .custom(StatusCompactShaped<WithWorkLine>.self)
        case (true, true): return .custom(StatusCompactShaped<WithNoticeAndWorkLine>.self)
        }
    }
}

/// Tall enough for the Record row and the lines at the person's text size, measured from the fonts they
/// use, so nothing is cut off. At the accessibility sizes compact holds the Record row and one line, its
/// title and its words sharing four rows (`StatusSheetModel.compactLines`), so the list above stays
/// usable; the rest are a tap away. At most 55% of the screen; past that, the line scrolls.
struct StatusCompactDetent: CustomPresentationDetent {
    /// Room above Record, so the sheet's grabber sits clearly above it.
    static let recordTop: CGFloat = 26
    /// Room between Record and the lines.
    static let recordGap: CGFloat = PhoneStyle.Space.s4
    /// The largest text size the Record row takes: beyond it, Record's label would break mid-word
    /// beside the round buttons. The row is a control bar, with the large content viewer past it.
    static let recordLargestSize = DynamicTypeSize.accessibility1
    /// Lines when nothing on this iPhone is working: the recorder, your Mac, and iCloud.
    static let lineCount = 3

    static func height(in context: Context) -> CGFloat? {
        height(for: context.dynamicTypeSize, maximum: context.maxDetentValue)
    }

    static func lineHeight(_ style: UIFont.TextStyle, at size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return ceil(UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).lineHeight)
    }

    /// The lines' height at a text size: one row each, or at the accessibility sizes one line with its title
    /// and its words sharing four rows (`StatusLineView`, stacked); the room between them, and a progress
    /// line's under the last.
    static func linesHeight(for size: DynamicTypeSize, lines: Int = lineCount) -> CGFloat {
        let line = lineHeight(.subheadline, at: size)
        if size.isAccessibilitySize {
            return CGFloat(StatusMetrics.stackedRows) * line + 2 + 6
        }
        return CGFloat(lines) * line + CGFloat(max(0, lines - 1)) * PhoneStyle.Space.s2 + 6
    }

    static func height(for size: DynamicTypeSize, maximum: CGFloat, notice: Bool = false, lines: Int = lineCount) -> CGFloat {
        // Record is at least 60 pt, taller when its label grows; the glass button adds 4 pt each side.
        let record = max(60, lineHeight(.title3, at: min(size, recordLargestSize)) + 8) + 8
        // A notice over Record (`RecordingNotice`, or "Importing 2 recordings…"): two lines and the gap under them.
        let notice = notice ? 2 * lineHeight(.footnote, at: min(size, recordLargestSize)) + PhoneStyle.Space.s2 : 0
        let content = recordTop + notice + record + recordGap + linesHeight(for: size, lines: lines) + PhoneStyle.Space.s4
        return min(maximum * 0.55, content)
    }
}

/// What a compact detent makes room for besides the Record row and three lines.
protocol StatusCompactShape {
    static var notice: Bool { get }
    static var workLine: Bool { get }
}
enum WithNotice: StatusCompactShape { static let notice = true, workLine = false }
enum WithWorkLine: StatusCompactShape { static let notice = false, workLine = true }
enum WithNoticeAndWorkLine: StatusCompactShape { static let notice = true, workLine = true }

/// `StatusCompactDetent` with room for a notice over Record, or this iPhone's line, or both.
struct StatusCompactShaped<Shape: StatusCompactShape>: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        StatusCompactDetent.height(for: context.dynamicTypeSize, maximum: context.maxDetentValue, notice: Shape.notice,
                                   lines: StatusCompactDetent.lineCount + (Shape.workLine ? 1 : 0))
    }
}

// MARK: Pocket: the sheet

/// Presents the status sheet over the pocket library while it's the thing on screen: not over a
/// conversation, search, selection, or the Trash, and never in a compact height (an iPhone on its
/// side), where iOS would show it over the whole window; the library lays out as two pages there
/// (`DevicePosture.layout`). Other sheets and alerts (Settings, Move, Tags) open above it, as they do
/// over Maps' sheet.
struct StatusSheetHost: ViewModifier {
    let enabled: Bool
    @Environment(PhoneAppModel.self) private var model
    @Environment(ReadingSession.self) private var session
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var heightClass
    @State private var detent: PresentationDetent = .statusCompact(notice: false, workLine: false)
    @State private var appliedLaunchDetent = false

    /// Something shows over Record (`RecordStartButton`), so the compact detent makes room for it.
    private var hasNotice: Bool {
        model.notice != nil || model.importing > 0 || (model.recorderOnly != nil && !model.recorder.isActive)
            || (model.recorder.isCapturing && PhoneAppModel.recorderWarning(model.recorder.lastError) != nil)
    }

    /// What the compact detent makes room for: a notice over Record, and this iPhone's line while it has work.
    private var shape: CompactShape {
        CompactShape(notice: hasNotice, workLine: !StatusSheetInputs.phoneWork(model, library: model.library.controller).line.isEmpty)
    }

    struct CompactShape: Equatable {
        var notice: Bool
        var workLine: Bool
    }

    static func shows(enabled: Bool, reading: Bool, searching: Bool, selecting: Bool, inTrash: Bool,
                      heightClass: UserInterfaceSizeClass?) -> Bool {
        enabled && !reading && !searching && !selecting && !inTrash && heightClass != .compact
    }

    func body(content: Content) -> some View {
        let shows = Self.shows(enabled: enabled, reading: session.reading, searching: session.isSearchPresented, selecting: session.isSelecting,
                               inTrash: session.place == .trash, heightClass: heightClass)
        let shape = shape
        content
            .environment(\.statusSheetInset, shows
                         ? StatusCompactDetent.height(for: typeSize, maximum: 900, notice: shape.notice,
                                                      lines: StatusCompactDetent.lineCount + (shape.workLine ? 1 : 0)) - 34
                         : nil)
            .sheet(isPresented: Binding(get: { shows }, set: { _ in })) {
                StatusSheetView(detent: Binding(get: { Self.status(detent) }, set: { detent = Self.presentation($0, shape: shape) }),
                                hostsRecordButton: true)
                    .environment(model)
                    .environment(session)
                    .presentationDetents([Self.presentation(.compact, shape: shape), .medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationContentInteraction(.resizes)
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
                    .tint(PhoneStyle.accent)
            }
            .onChange(of: shows) { _, shows in
                // Back from a conversation or search: compact again, not wherever it was left.
                if !shows, detent == .large { detent = Self.presentation(.compact, shape: self.shape) }
            }
            .onChange(of: shape) { _, shape in
                if Self.status(detent) == .compact { detent = Self.presentation(.compact, shape: shape) }
            }
            .task {
                guard !appliedLaunchDetent, let launch = model.options.statusDetent else { return }
                appliedLaunchDetent = true
                try? await Task.sleep(for: .milliseconds(700))
                detent = Self.presentation(launch, shape: self.shape)
            }
    }

    static func status(_ detent: PresentationDetent) -> StatusDetent {
        detent == .large ? .large : detent == .medium ? .medium : .compact
    }

    static func presentation(_ detent: StatusDetent, shape: CompactShape) -> PresentationDetent {
        switch detent {
        case .compact: return .statusCompact(notice: shape.notice, workLine: shape.workLine)
        case .medium: return .medium
        case .large: return .large
        }
    }
}

// MARK: Notebook: the panel on the right page

/// The status at the foot of the right page of the open iPhone Duo (and of an iPhone on its side).
/// Compact, it's the lines, as tall as they are at the person's text size, within 55% of the page;
/// medium takes half the page; large takes the page (the conversation preview steps aside). It stays
/// on its page, clear of the crease, and hides while a conversation is open across both pages.
struct StatusPanel: View {
    @Binding var detent: StatusDetent
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.creaseEdge) private var creaseEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        let layout = StatusPanelLayout(lines: StatusCompactDetent.lineCount
                                           + (StatusSheetInputs.phoneWork(model, library: model.library.controller).line.isEmpty ? 0 : 1),
                                       typeSize: typeSize)
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    handle
                    StatusSheetView(detent: $detent, hostsRecordButton: false)
                        .frame(height: Self.contentHeight(detent, in: proxy.size.height, layout: layout))
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .padding(.leading, creaseEdge == .leading ? PhoneStyle.Page.creaseClearance : PhoneStyle.Space.s3)
                .padding(.trailing, PhoneStyle.Space.s3)
                .padding(.bottom, PhoneStyle.Space.s2)
                .offset(y: max(-40, min(40, drag)))
            }
        }
        .onChange(of: layout, initial: true) { _, layout in
            // The page keeps clear of what the panel holds (`footprint`).
            if StatusPanelLayout.current != layout { StatusPanelLayout.current = layout }
        }
        .animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: detent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
        .accessibilityActions {
            if detent != .large { Button("Expand") { step(up: true) } }
            if detent != .compact { Button("Collapse") { step(up: false) } }
        }
        // Full, it stands in for the page: the escape gesture puts it back, as it dismisses a sheet.
        .accessibilityAction(.escape) { if detent == .large { detent = .compact } }
    }

    /// The room the panel takes at the foot of a page this tall: its content, the handle, and the
    /// room under it. The preview keeps clear of it (`LibraryBrowser`); reading it follows what the
    /// panel holds (`StatusPanelLayout.current`), so the page moves when a line comes or goes.
    @MainActor
    static func footprint(_ detent: StatusDetent, in height: CGFloat) -> CGFloat {
        footprint(detent, in: height, layout: StatusPanelLayout.current)
    }

    static func footprint(_ detent: StatusDetent, in height: CGFloat, layout: StatusPanelLayout) -> CGFloat {
        contentHeight(detent, in: height, layout: layout) + chromeHeight
    }
    private static let handleHeight: CGFloat = 28
    /// The handle over the content and the room under the panel.
    private static let chromeHeight = handleHeight + PhoneStyle.Space.s2

    /// The panel's content on a page this tall. Compact is its lines at the person's text size, the
    /// panel at most 55% of the page as the sheet is of the screen (an iPhone on its side, at the
    /// accessibility sizes, where the line then scrolls). Each size is at least the one below it, so
    /// Expand never shrinks the panel.
    static func contentHeight(_ detent: StatusDetent, in height: CGFloat, layout: StatusPanelLayout) -> CGFloat {
        // The lines, with the room above and under them (`StatusSections`).
        let lines = StatusCompactDetent.linesHeight(for: layout.typeSize, lines: layout.lines) + PhoneStyle.Space.s1 + PhoneStyle.Space.s4
        let compact = max(0, min(lines, height * 0.55 - chromeHeight))
        let medium = max(compact, 220, height * 0.5)
        switch detent {
        case .compact: return compact
        case .medium: return medium
        case .large: return max(medium, height - 44 - PhoneStyle.Space.s2 - PhoneStyle.Space.s3)
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

/// What the notebook's panel holds at its compact size: how many lines, at what text size, for the
/// room the page keeps clear of it.
struct StatusPanelLayout: Equatable {
    var lines: Int
    var typeSize: DynamicTypeSize

    /// What the panel on screen holds; reading it from a view's body follows it.
    @MainActor static var current: StatusPanelLayout {
        get { Holder.shared.layout }
        set { Holder.shared.layout = newValue }
    }

    @MainActor @Observable
    fileprivate final class Holder {
        static let shared = Holder()
        var layout = StatusPanelLayout(lines: StatusCompactDetent.lineCount, typeSize: .large)
    }
}

// MARK: The content

/// The sheet's content for a detent, shared by the pocket sheet and the notebook panel. Its links
/// open the full screens inside it (a device's page, a Mac's, Settings › iCloud, Storage), never
/// copies of them.
struct StatusSheetView: View {
    @Binding var detent: StatusDetent
    let hostsRecordButton: Bool
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [SettingsRoute] = []
    @State private var showingPairing = false
    @State private var showingAddDevice = false

    var body: some View {
        NavigationStack(path: $path) {
            StatusSections(library: model.library.controller, detent: $detent, hostsRecordButton: hostsRecordButton,
                           open: open, showingPairing: $showingPairing, showingAddDevice: $showingAddDevice)
                .toolbar(.hidden, for: .navigationBar)
                // The sheet's (or panel's) Liquid Glass shows through; content is never glass itself.
                .containerBackground(.clear, for: .navigation)
                .navigationDestination(for: SettingsRoute.self) { route in SettingsDestination(route: route) }
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
        // A recorder's notification (imported, almost full) opens its page here, where recorders' pages are.
        .onChange(of: model.destination, initial: true) { _, request in
            guard let request, case .device(let id) = request.destination,
                  model.devices.sessions.contains(where: { $0.id == id }) else { return }
            open(.device(id))
            model.reached(request)
        }
    }

    /// `--status-open device|mac|storage|icloud|add-recorder` (debug): that screen inside the sheet (or
    /// Add Recorder over it), for screenshots.
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
        case "icloud": open(.icloud)
        case "add-recorder": showingAddDevice = true
        default: break
        }
    }

    /// A full screen opens with the sheet at full height.
    private func open(_ route: SettingsRoute) {
        detent = .large
        path = [route]
    }
}

/// The sections for the detent: Record pinned at the top, clear of the grabber and never scrolled
/// under it, then the overview both apps share (`StatusOverview`): the lines, and past compact the
/// groups, in a scroll view.
private struct StatusSections: View {
    let library: LibraryController
    @Binding var detent: StatusDetent
    let hostsRecordButton: Bool
    let open: (SettingsRoute) -> Void
    @Binding var showingPairing: Bool
    @Binding var showingAddDevice: Bool
    @Environment(PhoneAppModel.self) private var model
    @Environment(ReadingSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The group a tapped line's fix is in, until the sheet has scrolled to it.
    @State private var fix: StatusSection?

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
            ScrollViewReader { proxy in
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let lines = StatusSheetModel.lines(inputs, now: context.date)
                        StatusOverview(lines: detent == .compact
                                           ? StatusSheetModel.compactLines(lines, accessibilitySize: typeSize.isAccessibilitySize) : lines,
                                       density: detent.density,
                                       hint: { StatusSheetModel.hint(for: StatusSheetModel.route(for: $0, inputs)) },
                                       choose: { choose($0, inputs: inputs) }) {
                            ForEach(sections.filter { $0 != .quickActions && $0 != .lines }, id: \.self) { section in
                                view(for: section, inputs: inputs, now: context.date)
                                    .id(section)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, PhoneStyle.Space.s4)
                        .padding(.top, hostsRecordButton ? 0 : PhoneStyle.Space.s1)
                        .padding(.bottom, PhoneStyle.Space.s4)
                    }
                }
                // Compact holds its lines whole; at the accessibility sizes, where the 55% cap can leave a long
                // line less room than it takes, the line scrolls rather than running under the home indicator.
                .scrollDisabled(detent == .compact && !typeSize.isAccessibilitySize)
                .scrollBounceBehavior(.basedOnSize)
                // `--status-scroll-end`: the foot of the content, for screenshots.
                .defaultScrollAnchor(model.options.statusScrollEnd ? .bottom : nil)
                .onChange(of: fix.map(sections.contains) ?? false) { _, shown in
                    if shown { reveal(in: proxy) }
                }
            }
        }
        .animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: sections)
        .animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: detent)
        .task { await chooseRequestedLine() }
    }

    /// `--status-choose mac|sync|recorder` (debug): that compact line, tapped, for screenshots of where it leads.
    private func chooseRequestedLine() async {
        guard let id = model.options.statusChoose, detent == .compact else { return }
        try? await Task.sleep(for: .milliseconds(1_500))
        let inputs = StatusSheetInputs.make(model, library: library, hostsRecordButton: hostsRecordButton)
        guard let line = StatusSheetModel.lines(inputs).first(where: { $0.id == id || $0.id.hasPrefix(id + "-") }) else { return }
        choose(line, inputs: inputs)
    }

    /// A line leads to its fix when it needs the person, else to more of the sheet.
    private func choose(_ line: StatusLineItem, inputs: StatusInputs) {
        switch StatusSheetModel.route(for: line, inputs) {
        case .showMore: if detent == .compact { detent = .medium }
        case .showFix(let section):
            if detent == .compact { detent = .medium }
            fix = section
        case .open(let route): open(route)
        }
    }

    /// Scrolls the group with the fix to the top, once the sheet has stepped up and the group has laid out.
    private func reveal(in proxy: ScrollViewProxy) {
        guard let section = fix else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(reduceMotion ? nil : PhoneStyle.Motion.state) { proxy.scrollTo(section, anchor: .top) }
            fix = nil
        }
    }

    @ViewBuilder
    private func view(for section: StatusSection, inputs: StatusInputs, now: Date) -> some View {
        switch section {
        case .quickActions, .lines: EmptyView()
        case .captions: StatusCaptions()
        case .recorders: StatusRecorders(detent: detent, open: open, addRecorder: { showingAddDevice = true })
        case .macs:
            StatusMacs(inputs: inputs, now: now, open: open, pair: { showingPairing = true },
                       openConversation: openConversation, perform: perform)
        case .iphone:
            StatusThisIPhone(entries: inputs.phoneQueue, showsStorage: detent == .large, now: now, open: open,
                             openConversation: openConversation, perform: perform)
        }
    }

    /// A queued conversation opens on its page, and the sheet steps back to compact behind it.
    private func openConversation(_ id: UUID) {
        detent = .compact
        session.open(id)
    }

    /// What a queued conversation offers: where its summary runs, or Try Again, as its page does.
    private func perform(_ action: StatusQueueItem.Action, for id: UUID) {
        switch action {
        case .placement(let choice): model.placement.perform(choice, for: id)
        case .tryAgain(.summaryOnly): library.summarize(id, placement: model.placement)
        case .tryAgain(let mode): library.requestProcessing(id, mode: mode)
        }
    }
}

/// Gathers the sheet's facts from the app model.
@MainActor
enum StatusSheetInputs {
    static func make(_ model: PhoneAppModel, library: LibraryController, hostsRecordButton: Bool) -> StatusInputs {
        let devices = model.devices
        var inputs = StatusInputs()
        inputs.recorders = devices.sessions.map { lineRecorder($0, model: model) }
        inputs.mac = model.macPresence
        inputs.liveProgress = model.liveProgress.values.sorted { $0.receivedAt > $1.receivedAt }
        inputs.queue = StatusSheetModel.queue(meetings: library.meetings, liveProgress: model.liveProgress, thisDevice: library.thisDevice.id,
                                              planners: model.placement.planners, runs: model.placement.runs,
                                              cloudOffered: model.placement.cloudOffer != nil)
        let work = phoneWork(model, library: library)
        inputs.phone = work.line
        inputs.phoneQueue = work.entries
        sync(model.sync, into: &inputs)
        inputs.hostsRecordButton = hostsRecordButton
        inputs.hasLiveCaptions = devices.sessions.contains { $0.isListeningLive }
        inputs.pairedMacs = model.link.macs.map { mac in
            StatusInputs.Mac(id: mac.id, name: mac.name, line: macLine(mac, model: model), isConnected: mac.isConnected,
                             notProcessing: mac.isConnected && !mac.canProcess)
        }
        return inputs
    }

    /// iCloud's line: where sync stands in Settings' words, the reason in a few words when iCloud can't be
    /// used ("Signed out", narrowed to "Off"), and what needs the person in warning ink: a pass that failed,
    /// the library's key not here, iCloud full, or an older Daybook app syncing as this iPhone.
    static func sync(_ sync: PhoneSync, into inputs: inout StatusInputs) {
        inputs.syncLine = sync.statusLine
        switch sync.connection {
        case .checking: inputs.syncTone = .checking
        case .unavailable where sync.iCloud == .accountChanged:
            // Paused for the person, not off: Settings › iCloud offers Sync with This Account.
            inputs.syncTone = .attention
            inputs.syncLine = SyncStatus.accountChanged.shortText
        case .unavailable(let reason):
            inputs.syncTone = .attention
            inputs.syncOff = true
            inputs.syncLine = StatusSheetModel.unavailablePhrase(reason)
            inputs.syncShort = "Off"
        case .connected:
            let full = sync.isStorageFull
            let olderApp = sync.controller?.warning == .otherInstallation
            if full { inputs.syncLine = SyncStatus.storageFull.shortText }
            if olderApp, !full, sync.lastError == nil { inputs.syncLine = "Older Daybook app installed" }
            inputs.syncTone = sync.lastError != nil || full || olderApp || sync.encryption == .waitingForKey ? .attention
                : sync.isUpToDate ? .upToDate : .working
        }
    }

    /// A paired Mac's row: recording, or what its link is doing, from the link; away, when it was last seen,
    /// by the link or the library's sync, whichever is newer, as every device's absence is dated.
    static func macLine(_ mac: PhoneLink.Mac, model: PhoneAppModel, now: Date = Date()) -> String {
        let recordingBySync = model.isRecordingBySync(mac, now: now)
        guard !mac.isRecording, !recordingBySync else { return mac.rowLine(recordingBySync: recordingBySync) }
        switch mac.state {
        case .idle, .suspended:
            let synced = model.sync.devices.first { $0.id == (mac.syncDeviceID ?? mac.id.uuidString) }?.lastSeen
            let seen = [mac.lastConnectedAt, synced].compactMap { $0 }.max()
            return seen.map { RecorderStatusWords.lastSeen($0, now: now) } ?? "Not connected"
        default:
            return mac.rowLine(recordingBySync: false)
        }
    }

    /// This iPhone's own work: its processor's queue, and summaries counting down to it or running in the cloud.
    static func phoneWork(_ model: PhoneAppModel, library: LibraryController, now: Date = Date()) -> StatusSheetModel.PhoneWork {
        let processor = model.processor
        var work = StatusSheetModel.phoneWork(meetings: library.meetings, local: { processor.queue(for: $0, at: now) },
                                              pause: processor.pause.map(pauseReason), thisDevice: library.thisDevice.id,
                                              planners: model.placement.planners, runs: model.placement.runs, now: now)
        #if DEBUG
        StatusSheetDemo.adjust(&work, meetings: library.meetings)
        #endif
        return work
    }

    /// Why this iPhone's work waits, in the words both apps use for it.
    static func pauseReason(_ pause: PhoneProcessor.Pause) -> ProcessingWords.PauseReason {
        switch pause {
        case .recording: return .recording
        case .background: return .background
        case .heat: return .heat
        case .lowPowerMode: return .lowPowerMode
        case .lowBattery: return .lowBattery
        }
    }

    /// One recorder's facts for its line: `recorder(_:model:)`'s, and what its words need besides.
    static func lineRecorder(_ session: DeviceSession, model: PhoneAppModel) -> StatusInputs.Recorder {
        var recorder = recorder(session, model: model)
        let facts = RecorderFacts(session: session)
        recorder.symbol = facts.symbol
        recorder.recordCommandPending = facts.recordCommandPending
        recorder.recordingAsOf = facts.recordingAsOf
        recorder.folder = facts.folder
        return recorder
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
            problem: session.problem.map { RecorderStatusWords.problem($0, on: .iPhone).title },
            lastConnected: session.direct?.lastConnectedAt ?? session.primary?.lastConnectedAt,
            storageHours: session.status?.storage?.hoursLeft,
            storageIsLow: session.status?.storage.map(StorageFormat.isLow) ?? false,
            hasRecordControl: control != nil && session.direct?.capabilities.contains(.recordControl) == true,
            hasLiveListening: session.direct is any LiveListeningConnection,
            canConnect: RecorderFacts.canConnect(session),
            importRunning: session.queue.current != nil,
            notListed: session.managedElsewhere == nil && session.listingState == .notListed,
            otherAppWait: session.otherAppWait,
            fastTransfer: session.fastTransferStage)
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
/// sheet is up, so there's one bottom surface rather than two stacked). Their glass is one layer
/// (`GlassEffectContainer`), so the three read and blend as one bar. Past `recordLargestSize` the
/// row stops growing and each control shows the large content viewer.
private struct StatusQuickActions: View {
    @Environment(ReadingSession.self) private var session

    var body: some View {
        GlassEffectContainer(spacing: PhoneStyle.Space.s3) {
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
        }
        .dynamicTypeSize(...StatusCompactDetent.recordLargestSize)
    }
}

// MARK: Cards

/// The glyph column of a card's rows at the person's text size: a card tile's side (DaybookDesign's
/// `StatusRow` uses the same), so a device's glyph lines up with the rows under it.
private struct CardGlyphColumn: DynamicProperty {
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    var value: CGFloat { DaybookTileSize.card.side(scale: scale) }
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
    let open: (SettingsRoute) -> Void
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
    let session: DeviceSession
    let detent: StatusDetent
    let open: (SettingsRoute) -> Void
    @Environment(PhoneAppModel.self) private var model
    private let glyph = CardGlyphColumn()

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
                                    // On the accent wash, the ink that keeps 4.5:1 there.
                                    .foregroundStyle(PhoneStyle.Ink.onWash)
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

    /// "Connected · 80%" in the words both apps give a recorder (`RecorderStatusWords`), and at the large
    /// detent its room: "About 2,170 hours left" (orange when low), on the same line when it fits.
    @ViewBuilder
    private func status(storage hours: Double?, low: Bool) -> some View {
        let line = StatusSheetModel.recorderLine(StatusSheetInputs.lineRecorder(session, model: model)).text.keepingSeparators
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
    let session: DeviceSession
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
            // On the accent wash, the ink that keeps 4.5:1 there (link ink falls under it).
            .foregroundStyle(PhoneStyle.Ink.onWash)
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

/// Live listening captions, while a recorder streams: the shared strip (`.sheet`), drawn as the Mac's
/// Listen Live draws it. Tentative; never the transcript.
private struct StatusCaptions: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let locale = model.settings.captionLocale
        ForEach(model.devices.sessions.filter(\.isListeningLive)) { session in
            VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
                HStack(spacing: 6) {
                    Circle().fill(PhoneStyle.Ink.record).frame(width: 7, height: 7).accessibilityHidden(true)
                    StatusHeading(text: "Listening to \(session.device.name)")
                }
                let segments = session.liveCaptions, state = session.liveCaptionState
                if LiveCaptionStrip.shows(segments: segments, state: state, locale: locale) {
                    LiveCaptionStrip(segments: segments, state: state, locale: locale, style: .sheet)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PhoneStyle.Space.s3)
            .background(PhoneStyle.quietFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: Macs

/// Every paired Mac (and one the library syncs with that isn't paired here), the queue under the
/// Mac doing it, and Pair with Your Mac…. Work no Mac here is doing yet starts at the card's edge.
private struct StatusMacs: View {
    let inputs: StatusInputs
    let now: Date
    let open: (SettingsRoute) -> Void
    let pair: () -> Void
    let openConversation: (UUID) -> Void
    let perform: (StatusQueueItem.Action, UUID) -> Void

    var body: some View {
        let rows = StatusSheetModel.macRows(inputs, now: now)
        StatusGroup(title: "Macs") {
            StatusCard {
                // Work no Mac here is doing yet (no Mac has synced): at the top, under none.
                if !rows.contains(where: \.showsQueue) {
                    ForEach(inputs.queue) { entry in queueRow(entry, under: nil) }
                }
                ForEach(rows) { row in
                    macRow(row)
                    if row.showsQueue {
                        ForEach(inputs.queue) { entry in queueRow(entry, under: row.name) }
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

    private func queueRow(_ entry: StatusQueueEntry, under mac: String?) -> some View {
        StatusQueueRow(entry.item(under: mac, now: now), indented: mac != nil, open: { openConversation(entry.id) },
                       perform: { perform($0, entry.id) })
            .statusRowAtCardEdge(mac == nil)
    }

    @ViewBuilder
    private func macRow(_ row: StatusMacRow) -> some View {
        let label = StatusRow {
            DaybookTile(symbol: "desktopcomputer", tone: row.needsYou ? .attention : row.isConnected ? .active : .neutral, size: .card)
        } content: {
            HStack(spacing: PhoneStyle.Space.s2) {
                StatusRowTitle(title: row.name) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.text.keepingSeparators).foregroundStyle(row.needsYou ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
                        if let fix = row.fix { Text(fix) }
                    }
                }
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

// MARK: This iPhone

/// This iPhone's own work while it has some (docs/iphone.md, "Processing on this iPhone"): what runs
/// here, a summary counting down to it, what waits and what's paused, in the rows the Macs card uses;
/// and at full height the audio kept on it, opening Storage.
private struct StatusThisIPhone: View {
    let entries: [StatusQueueEntry]
    let showsStorage: Bool
    let now: Date
    let open: (SettingsRoute) -> Void
    let openConversation: (UUID) -> Void
    let perform: (StatusQueueItem.Action, UUID) -> Void
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        StatusGroup(title: "This iPhone") {
            StatusCard {
                ForEach(entries) { entry in
                    StatusQueueRow(entry.item(under: nil, now: now), indented: false, open: { openConversation(entry.id) },
                                   perform: { perform($0, entry.id) })
                        .statusRowAtCardEdge()
                }
                if showsStorage {
                    Button { open(.storage) } label: {
                        StatusRow {
                            DaybookTile(symbol: "iphone", size: .card)
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
}
