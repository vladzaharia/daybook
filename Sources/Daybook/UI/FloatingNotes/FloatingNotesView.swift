import AppKit
import DaybookCore
import DaybookDesign
import DaybookKit
import SwiftUI

/// What the panel shows, apart from what the app already knows: the conversation in focus, and
/// whether the panel watched it record (so after Stop it reports what became of it).
@MainActor
final class FloatingNotesModel: ObservableObject {
    let state: AppState
    let feed: FloatingStatusFeed
    let input = InputDeviceName()
    let levels = PanelLevels()
    /// The conversation shown when nothing is recording; nil is the home.
    @Published private(set) var focusID: UUID?
    /// The conversation this panel watched record.
    @Published private(set) var recordedID: UUID?

    init(state: AppState) {
        self.state = state
        feed = FloatingStatusFeed(state: state)
        focusID = state.recordingID
        recordedID = state.recordingID
    }

    func focus(_ id: UUID?, afterStop: Bool = false) {
        if id != focusID {
            focusID = id
            if recordedID != id { recordedID = nil }
        }
        // Shown for the recording (as recording starts), or as just stopped: it reports what becomes of it.
        if let id, afterStop || id == state.recordingID { recordedID = id }
    }

    /// A recording started (or ended) anywhere: the panel follows it, and keeps it once stopped.
    func recordingChanged(_ id: UUID?) {
        guard let id else { return }
        focusID = id
        recordedID = id
    }

    func goHome() {
        focusID = nil
        recordedID = nil
    }
}

/// Reads the reading scale from the app state, so ⌘+ and ⌘− resize the notes while the panel is open.
struct FloatingNotesRoot: View {
    @ObservedObject var model: FloatingNotesModel
    @ObservedObject var state: AppState
    let chrome: PanelChrome

    var body: some View {
        FloatingNotesView(model: model, state: state, chrome: chrome, feed: model.feed, input: model.input)
            .environment(\.readingScale, CGFloat(state.readingScale))
            .modifier(DemoContrast())
    }
}

/// `--notes-contrast`: the panel as Increase Contrast draws it, for snapshots. The shared tokens
/// draw their contrast values (`DaybookShade.simulatesIncreasedContrast`), and SwiftUI's contrast,
/// which follows the system setting, is set here.
private struct DemoContrast: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if FloatingNotesDemo.increasedContrast {
            content.environment(\._colorSchemeContrast, .increased)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// The three surfaces and the status bar over them. The surface follows the app: recording, a
/// conversation (after Stop, or opened for one), or the home. The size picks full or compact.
struct FloatingNotesView: View {
    @ObservedObject var model: FloatingNotesModel
    @ObservedObject var state: AppState
    @ObservedObject var chrome: PanelChrome
    @ObservedObject var feed: FloatingStatusFeed
    @ObservedObject var input: InputDeviceName
    /// Live captions are running for the recording. Kept here, rather than observing the captions,
    /// so a revised word redraws only the caption strip.
    @State private var captionsShowing: UUID?

    enum Surface: Equatable { case recording, conversation, home }

    private var shownID: UUID? { state.recordingID ?? model.focusID }
    private var meeting: Meeting? { shownID.flatMap { id in state.meetings.first { $0.id == id } } }
    private var isRecording: Bool { meeting.map { state.recordingID == $0.id } ?? false }
    private var afterStop: Bool { !isRecording && meeting != nil && model.recordedID == meeting?.id }
    private var surface: Surface { isRecording ? .recording : afterStop ? .conversation : .home }

    var body: some View {
        let _ = feed.revision
        let inputs = FloatingStatusInputs.make(state, meeting: meeting, afterStop: afterStop, inputDevice: input.name)
        GeometryReader { proxy in
            let compact = proxy.size.height < FloatingLayout.compactBelow
            let chips = FloatingStatus.chips(inputs, including: chipKinds(compact: compact))
            let menus = ChipMenus(state: state, meeting: meeting, openMeeting: openInDaybook)
            ZStack(alignment: .top) {
                content(inputs: inputs, chips: compact ? [] : chips, menus: menus, compact: compact)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .transition(.opacity)
                    .id(surface)
                // Full, the band holds the phase and the chips get a row of their own under it;
                // compact, the band holds both.
                StatusBand(chrome: chrome, phase: FloatingStatus.phase(inputs), chips: compact ? chips : [], menus: menus,
                           compact: compact)
            }
            .daybookMotion(DaybookMotion.state, value: surface)
            .daybookMotion(DaybookMotion.state, value: compact)
        }
        .background { shortcuts }
        // Inside the safe-area escape, so the minimum is measured against the whole window.
        .frame(minWidth: FloatingLayout.minimumSize.width, minHeight: FloatingLayout.minimumSize.height)
        .background(DaybookPalette.paper)
        .ignoresSafeArea()
        .onAppear {
            input.start()
            runLevels()
        }
        .onChange(of: state.recordingID) { _, id in
            model.recordingChanged(id)
            runLevels()
        }
        .onReceive(state.captions.$showing) { showing in
            if showing != captionsShowing { captionsShowing = showing }
        }
    }

    /// The status bar leaves out what the surface already says in full: the home's lines list the
    /// devices and the queue.
    private func chipKinds(compact: Bool) -> Set<FloatingStatus.ChipKind> {
        switch surface {
        case .recording: return [.call, .devices, .sync]
        // A conversation that couldn't finish says so in its box, with Try Again.
        case .conversation: return meeting?.status == .failed ? [.devices, .sync] : [.devices, .work, .sync]
        case .home:
            if compact { return [.devices, .work, .queue, .sync] }
            return meeting == nil ? [] : [.work]
        }
    }

    @ViewBuilder
    private func content(inputs: FloatingStatusInputs, chips: [FloatingChip], menus: ChipMenus, compact: Bool) -> some View {
        let context = PanelContext(state: state, band: chrome.band, compact: compact, chips: chips, menus: menus,
                                   open: openInDaybook, goHome: model.goHome)
        switch surface {
        case .recording:
            if let meeting {
                RecordingSurface(context: context, meeting: meeting, inputs: inputs, levels: model.levels,
                                 captionsShowing: captionsShowing == meeting.id)
            }
        case .conversation:
            if let meeting { AfterStopSurface(context: context, meeting: meeting, inputs: inputs) }
        case .home:
            HomeSurface(context: context, focused: meeting, inputs: inputs)
        }
    }

    private func runLevels() {
        var synthetic = false
        #if DEBUG
        synthetic = FloatingNotesDemo.syntheticLevels && !state.recorder.isRecording
        #endif
        model.levels.run(state.recordingID != nil, readers: .live(state), synthetic: synthetic)
    }

    // MARK: Keyboard

    /// ⌘O opens the conversation, ⌘+ ⌘− ⌘0 size the text, ⌘W hides the panel (recording continues).
    /// ⌘D and ⇧⌘R belong to the visible Bookmark, Stop, and Record. There's deliberately no Esc: a
    /// stray Escape during a call should do nothing.
    private var shortcuts: some View {
        Group {
            Button("Open in Daybook", action: openInDaybook).keyboardShortcut("o")
            Button("Make Text Bigger") { state.readingScale = ReadingScale.bigger(state.readingScale) }.keyboardShortcut("+")
            Button("Make Text Smaller") { state.readingScale = ReadingScale.smaller(state.readingScale) }.keyboardShortcut("-")
            Button("Actual Size") { state.readingScale = 1 }.keyboardShortcut("0")
            Button("Hide Floating Notes") { FloatingNotesWindow.shared.close() }.keyboardShortcut("w")
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The shown conversation in the main window, or the main window itself from the home.
    private func openInDaybook() { open(meeting?.id) }

    fileprivate func open(_ id: UUID?) {
        PanelContext.openInDaybook(state: state, id: id)
    }
}

/// What every surface needs from the panel around it.
struct PanelContext {
    let state: AppState
    /// The title band's height: content starts below it.
    let band: CGFloat
    let compact: Bool
    /// The status chips for a row under the band (full layouts); empty when the band holds them.
    let chips: [FloatingChip]
    let menus: ChipMenus
    let open: () -> Void
    let goHome: () -> Void

    /// Brings Daybook forward on a conversation (or as it was, for nil).
    @MainActor
    static func openInDaybook(state: AppState, id: UUID?) {
        if let id {
            state.place = .section(.all)
            state.selectedID = id
        }
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
    }

    /// A device's page in the main window.
    @MainActor
    static func showDevice(state: AppState, id: String) {
        state.showDevice(id)
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - The status bar

/// The title band: the close button (on hover), the phase and what it records from, and the
/// Compact button (on hover) mirroring close. Full, the phase is centred like a window title;
/// compact, the chips join it and shorten, then shrink to their glyphs, as the panel narrows.
private struct StatusBand: View {
    @ObservedObject var chrome: PanelChrome
    let phase: FloatingPhase?
    let chips: [FloatingChip]
    let menus: ChipMenus
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if compact {
                ViewThatFits(in: .horizontal) {
                    bar(.full, yields: false)
                    ForEach(ChipRow.Fit.allCases, id: \.self) { fit in bar(fit, yields: true) }
                }
            } else {
                Spacer(minLength: 0)
                if let phase { phaseLabel(phase, yields: false) }
                Spacer(minLength: 0)
            }
            compactButton
        }
        .padding(.leading, chrome.buttonInset + chrome.buttonWidth + 6)
        .padding(.trailing, chrome.buttonInset)
        .frame(height: max(chrome.band, chrome.buttonCenter * 2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }

    private func bar(_ fit: ChipRow.Fit, yields: Bool) -> some View {
        HStack(spacing: 4) {
            if let phase { phaseLabel(phase, yields: yields) }
            if !yields || phase?.detail == nil { Spacer(minLength: 4) }
            ForEach(chips) { chip in ChipControl(chip: chip, fit: fit, menus: menus) }
        }
    }

    private func phaseLabel(_ phase: FloatingPhase, yields: Bool) -> some View {
        RecordingPhaseLabel(phase.phase, title: phase.title, detail: phase.detail, detailIsWarning: phase.detailIsWarning,
                            detailYields: yields, metrics: .panel)
            .help(phase.detailIsWarning ? FloatingStatus.microphoneSilentHelp : phase.detail ?? "")
    }

    /// Compact snaps the panel short (the status bar, one caption line, the controls); Expand returns.
    private var compactButton: some View {
        Button {
            chrome.setCompact(!compact, animate: !reduceMotion)
        } label: {
            Image(systemName: compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .frame(width: chrome.buttonWidth, height: chrome.buttonWidth)
                .background(Circle().fill(DaybookPalette.quietFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(chrome.isHovering ? 1 : 0)
        .daybookMotion(DaybookMotion.hover, value: chrome.isHovering)
        .help(compact ? "Expand" : "Compact")
        .accessibilityLabel(compact ? "Expand" : "Compact")
    }
}

/// The status chips in a row of their own under the band: whole labels when they fit, then short
/// ones, then glyphs.
struct ChipRow: View {
    /// How much each chip says, widest first. A chip whose short label says as much shortens first;
    /// then prominent chips (processing, anything that needs the person) keep their words while the
    /// others give theirs up.
    enum Fit: CaseIterable {
        case full, shortFirst, shortOthers, glyphOthers, short, glyph

        func label(_ chip: FloatingChip) -> String? {
            switch self {
            case .full: return chip.label
            case .shortFirst: return chip.shortensFirst ? chip.shortLabel : chip.label
            case .shortOthers: return chip.isProminent ? Fit.shortFirst.label(chip) : chip.shortLabel
            case .glyphOthers: return chip.isProminent ? Fit.shortFirst.label(chip) : nil
            case .short: return chip.isProminent ? chip.shortLabel : nil
            case .glyph: return nil
            }
        }
    }

    let chips: [FloatingChip]
    let menus: ChipMenus

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Fit.allCases, id: \.self) { fit in row(fit) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }

    private func row(_ fit: Fit) -> some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in ChipControl(chip: chip, fit: fit, menus: menus) }
        }
    }
}

/// What a chip's menu can do, and for which conversation.
struct ChipMenus {
    let state: AppState
    let meeting: Meeting?
    let openMeeting: () -> Void
}

/// One chip: a menu with its whole status and what you can do about it. The call chip only says.
private struct ChipControl: View {
    let chip: FloatingChip
    let fit: ChipRow.Fit
    let menus: ChipMenus

    var body: some View {
        let face = StatusChip(symbol: chip.symbol, text: label, tone: chip.tone, showsDot: chip.showsDot, progress: chip.progress,
                              filled: true, metrics: .mac)
        Group {
            if chip.target == .call {
                face
            } else {
                Menu {
                    Text(chip.detail)
                    Divider()
                    ChipMenuItems(state: menus.state, chip: chip, meeting: menus.meeting, openMeeting: menus.openMeeting)
                } label: {
                    face
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
        .fixedSize()
        .help(chip.detail)
        .accessibilityLabel(chip.detail)
    }

    private var label: String? { fit.label(chip) }
}

private struct ChipMenuItems: View {
    @ObservedObject var state: AppState
    let chip: FloatingChip
    let meeting: Meeting?
    let openMeeting: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        switch chip.target {
        case .recorder(let id):
            if let session = state.devices.session(id) {
                RecorderHandoffMenuItems(state: state, session: session)
                Button("Show \(session.device.name)") { PanelContext.showDevice(state: state, id: id) }
            }
        case .phone(let id):
            if let session = state.devices.session(id) {
                Button("Show \(session.device.name)") { PanelContext.showDevice(state: state, id: id) }
            }
        case .processing:
            if let meeting {
                if let planner = state.placements[meeting.id], !planner.actions.isEmpty {
                    // Where its summary runs: Use the Cloud, Start Now.
                    ForEach(planner.actions, id: \.self) { action in
                        Button(action.title) { state.chooseSummaryPlacement(action, for: meeting.id) }
                    }
                } else if state.processingID == meeting.id {
                    Button("Pause Transcription") { state.pauseProcessing(meeting.id) }
                } else if state.pausedIDs.contains(meeting.id) || (meeting.status == .failed && !FriendlyError.isNoSpeech(meeting.errorMessage ?? "")) {
                    Button(meeting.status == .failed ? "Try Again" : "Resume Transcription") {
                        state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting))
                    }
                }
                Button("Open in Daybook", action: openMeeting)
            }
            if let meeting, state.awaitingModels.contains(meeting.id) {
                Button("Open Settings…") { openSettingsPane(.models) }
            }
        case .queue:
            if let id = state.processingID, let planner = state.placements[id], !planner.actions.isEmpty {
                ForEach(planner.actions, id: \.self) { action in
                    Button(action.title) { state.chooseSummaryPlacement(action, for: id) }
                }
                Button("Open in Daybook") { PanelContext.openInDaybook(state: state, id: id) }
            } else if let id = state.processingID {
                Button("Pause Transcription") { state.pauseProcessing(id) }
                Button("Open in Daybook") { PanelContext.openInDaybook(state: state, id: id) }
            }
            if !state.awaitingModels.isEmpty {
                Button("Open Settings…") { openSettingsPane(.models) }
            }
        case .sync:
            Button("Open Sync Settings…") { openSettingsPane(.library) }
        case .call:
            EmptyView()
        }
    }

    private func openSettingsPane(_ pane: SettingsPane) {
        LaunchOptions.defaults.set(pane.rawValue, forKey: "settingsPane")
        openSettings()
        NSApp.activate()
    }
}

extension AppState {
    /// Shows Floating Notes on a conversation, or on its home for nil (the recording, while there is one).
    func showFloatingNotes(focus id: UUID?) {
        FloatingNotesWindow.shared.show(state: self, focus: id)
    }
}
