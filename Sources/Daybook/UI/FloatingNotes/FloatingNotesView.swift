import AppKit
import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// What the panel shows, apart from what the app already knows: the conversation in focus, and
/// whether the panel watched it record (so after Stop it reports what became of it).
@MainActor
@Observable
final class FloatingNotesModel {
    let state: AppState
    let input = MicrophoneInputs()
    let levels = RecorderLevels()
    /// The conversation shown when nothing is recording; nil is the home.
    private(set) var focusID: UUID?
    /// The conversation this panel watched record.
    private(set) var recordedID: UUID?

    init(state: AppState) {
        self.state = state
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
    let model: FloatingNotesModel
    let state: AppState
    let chrome: PanelChrome

    var body: some View {
        FloatingNotesView(model: model, state: state, chrome: chrome, input: model.input)
            .environment(\.readingScale, CGFloat(state.readingScale))
            .modifier(FloatingNotesSurface())
            .modifier(DemoContrast())
    }
}

/// Floating Notes is a panel: every shared view under it takes the panel's type and sizes.
struct FloatingNotesSurface: ViewModifier {
    static let density = DaybookDensity.panel

    func body(content: Content) -> some View {
        content
            .environment(\.daybookDensity, Self.density)
            .environment(\.platformMetrics, .for(Self.density))
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
    let model: FloatingNotesModel
    let state: AppState
    let chrome: PanelChrome
    let input: MicrophoneInputs
    /// Live captions are running for the recording. Kept here, rather than reading the captions,
    /// so a revised word redraws only the caption strip.
    @State private var captionsShowing: UUID?
    /// Opens the library's window wherever it is: closed, minimized, or behind.
    @Environment(\.openWindow) private var openWindow

    enum Surface: Equatable { case recording, conversation, home }

    private var shownID: UUID? { state.recordingID ?? model.focusID }
    private var meeting: Meeting? { shownID.flatMap { id in state.meetings.first { $0.id == id } } }
    private var isRecording: Bool { meeting.map { state.recordingID == $0.id } ?? false }
    private var afterStop: Bool { !isRecording && meeting != nil && model.recordedID == meeting?.id }
    private var surface: Surface { isRecording ? .recording : afterStop ? .conversation : .home }

    var body: some View {
        // The panel redraws for what it reads; a summary's countdown redraws only its own chip or line.
        panel(FloatingStatusInputs.make(state, meeting: meeting, afterStop: afterStop, inputDevice: input.name))
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
            .onChange(of: state.captions.showing, initial: true) { _, showing in
                if showing != captionsShowing { captionsShowing = showing }
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: FloatingNotesDemo.openRequested)) { _ in context(compact: false, chips: []).open() }
            #endif
    }

    private func context(compact: Bool, chips: [RecorderChip]) -> PanelContext {
        let openWindow = self.openWindow
        return PanelContext(state: state, meeting: meeting, band: chrome.band, compact: compact, chips: chips,
                            showLibrary: { openWindow(id: WindowID.library) }, goHome: model.goHome)
    }

    private func panel(_ inputs: FloatingStatusInputs) -> some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < FloatingLayout.compactBelow
            let chips = FloatingStatus.chips(inputs, including: chipKinds(compact: compact))
            ZStack(alignment: .top) {
                content(inputs: inputs, context: context(compact: compact, chips: compact ? [] : chips))
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .transition(.opacity)
                    .id(surface)
                // Full, the band holds the phase and the chips get a row of their own under it;
                // compact, the band holds both.
                StatusBand(chrome: chrome, phase: FloatingStatus.phase(inputs), chips: compact ? chips : [],
                           context: context(compact: compact, chips: chips), compact: compact, input: input)
            }
            .daybookMotion(DaybookMotion.state, value: surface)
            .daybookMotion(DaybookMotion.state, value: compact)
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
    private func content(inputs: FloatingStatusInputs, context: PanelContext) -> some View {
        switch surface {
        case .recording:
            if let meeting {
                FloatingRecording(context: context, meeting: meeting, inputs: inputs, levels: model.levels,
                                  captionsShowing: captionsShowing == meeting.id)
            }
        case .conversation:
            if let meeting { FloatingAfterStop(context: context, meeting: meeting, inputs: inputs) }
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
            Button("Open in Daybook") { context(compact: false, chips: []).open() }.keyboardShortcut("o")
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
}

/// What every surface needs from the panel around it.
struct PanelContext {
    let state: AppState
    /// The conversation shown, for the chips' menus.
    let meeting: Meeting?
    /// The title band's height: content starts below it.
    let band: CGFloat
    let compact: Bool
    /// The status chips for a row under the band (full layouts); empty when the band holds them.
    let chips: [RecorderChip]
    /// Opens the library's window (the scene's `openWindow`), closed or not.
    let showLibrary: @MainActor () -> Void
    let goHome: () -> Void

    /// The shown conversation in the main window, or the main window itself from the home.
    @MainActor func open() { openConversation(meeting?.id) }

    /// Brings Daybook forward on a conversation (or as it was, for nil).
    @MainActor
    func openConversation(_ id: UUID?) {
        if let id {
            state.place = .section(.all)
            state.selectedID = id
        }
        Self.bringLibraryForward(showLibrary)
    }

    /// A device's page in the main window.
    @MainActor
    func showDevice(_ id: String) {
        state.showDevice(id)
        Self.bringLibraryForward(showLibrary)
    }

    /// The library's window, in front: opened if it was closed, restored if it was minimized. Floating Notes is
    /// often all that's open of Daybook during a call, and it can't become the main window itself.
    @MainActor
    static func bringLibraryForward(_ showLibrary: @MainActor () -> Void) {
        showLibrary()
        NSApp.activate()
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(WindowID.library) == true {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - The status bar

/// The title band: the close button (on hover), the phase and what it records from, and the
/// Compact button (on hover) mirroring close. Full, the phase is centred like a window title;
/// compact, the chips join it and shorten, then shrink to their glyphs, as the panel narrows.
private struct StatusBand: View {
    let chrome: PanelChrome
    let phase: RecorderPhase?
    let chips: [RecorderChip]
    let context: PanelContext
    let compact: Bool
    let input: MicrophoneInputs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if compact {
                ViewThatFits(in: .horizontal) {
                    bar(.full, yields: false)
                    ForEach(RecorderChipFit.allCases, id: \.self) { fit in bar(fit, yields: true) }
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

    private func bar(_ fit: RecorderChipFit, yields: Bool) -> some View {
        HStack(spacing: chips.contains(where: \.expands) ? 8 : 4) {
            if let phase { phaseLabel(phase, yields: yields) }
            // A chip at work takes the rest of the band itself; otherwise the chips sit at its trailing end.
            if (!yields || phase?.detail == nil) && !chips.contains(where: \.expands) { Spacer(minLength: 4) }
            ForEach(chips) { chip in RecorderChipControl(chip: chip, fit: fit) { ChipMenuItems(context: context, chip: $0) } }
        }
    }

    @ViewBuilder
    private func phaseLabel(_ phase: RecorderPhase, yields: Bool) -> some View {
        let label = RecordingPhaseLabel(phase.phase, title: phase.title, detail: phase.detail, detailIsWarning: phase.detailIsWarning,
                                        detailYields: yields, metrics: .panel)
        // Recording, the phase is the input menu: Automatic and each input.
        if phase.choosesInput {
            MicrophoneMenu(inputs: input, phase: phase) { label }
        } else {
            label.help(phase.detailIsWarning ? RecordingStatusWords.microphoneSilentHelp : phase.detail ?? "")
        }
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

/// What a chip's menu can do, for the panel's conversation.
struct ChipMenuItems: View {
    let context: PanelContext
    let chip: RecorderChip
    @Environment(\.openWindow) private var openSettingsWindow

    private var state: AppState { context.state }

    var body: some View {
        switch chip.target {
        case .recorder(let id):
            if let session = state.devices.session(id) {
                RecorderHandoffMenuItems(state: state, session: session)
                Button("Show \(session.device.name)") { context.showDevice(id) }
            }
        case .peer(let id):
            if let session = state.devices.session(id) {
                Button("Show \(session.device.name)") { context.showDevice(id) }
            }
        case .processing:
            if let meeting = context.meeting, state.awaitingModels.contains(meeting.id) {
                // Waiting for models: the download comes first.
                ModelDownloadMenuItems(state: state)
            }
            if let meeting = context.meeting {
                if let planner = state.placements[meeting.id], !planner.actions.isEmpty {
                    // Where its summary runs: Use the Cloud, Start Now.
                    ForEach(planner.actions, id: \.self) { action in
                        Button(action.title) { state.chooseSummaryPlacement(action, for: meeting.id) }
                    }
                } else if state.processingID == meeting.id {
                    Button("Pause Transcription") { state.pauseProcessing(meeting.id) }
                } else if state.pausedIDs.contains(meeting.id) || (meeting.status == .failed && !isNoSpeech(meeting)) {
                    Button(meeting.status == .failed ? "Try Again" : "Resume Transcription") {
                        state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting))
                    }
                }
                Button("Open in Daybook") { context.open() }
            }
            if let meeting = context.meeting, state.awaitingModels.contains(meeting.id) {
                Button("Choose Models…") { openSettingsPane(.models) }
            }
        case .queue:
            if state.processingID == nil, !state.awaitingModels.isEmpty || state.modelDownloadState != nil {
                ModelDownloadMenuItems(state: state)
            }
            if let id = state.processingID, let planner = state.placements[id], !planner.actions.isEmpty {
                ForEach(planner.actions, id: \.self) { action in
                    Button(action.title) { state.chooseSummaryPlacement(action, for: id) }
                }
                Button("Open in Daybook") { context.openConversation(id) }
            } else if let id = state.processingID {
                Button("Pause Transcription") { state.pauseProcessing(id) }
                Button("Open in Daybook") { context.openConversation(id) }
            }
            if !state.awaitingModels.isEmpty {
                Button("Choose Models…") { openSettingsPane(.models) }
            }
        case .sync:
            Button("Open Sync Settings…") { openSettingsPane(.library) }
        case .call, .storage:
            EmptyView()
        }
    }

    private func openSettingsPane(_ pane: SettingsPane) {
        LaunchOptions.defaults.set(pane.rawValue, forKey: SettingsPane.storageKey)
        openSettingsWindow.settings()
        NSApp.activate()
    }

    /// A recording with no speech: trying again can't help, so there's no Try Again (`ProcessingRequest.FailureKind.noSpeech`).
    private func isNoSpeech(_ meeting: Meeting) -> Bool {
        if case .failed(let failure) = state.processingStatus(for: meeting) { return failure.isNoSpeech }
        return false
    }
}

/// What a chip about models offers first (`AppState.modelDownloadState`): Cancel Download while they arrive, Try Again
/// after one stopped, and otherwise what downloading them takes ("Download · 0.9 GB"), over whatever network this is.
private struct ModelDownloadMenuItems: View {
    let state: AppState

    var body: some View {
        switch state.modelDownloadState {
        case .downloading?:
            Button("Cancel Download") { state.cancelDownload() }
        case .failed?:
            Button("Try Again") { state.downloadModels(state.missingSelectedModels) }
        case .waitingForWiFi(let bytes)?:
            Button(ProcessingWords.download(bytes)) { state.downloadModels(state.missingSelectedModels) }
        case nil:
            if let bytes = state.missingSelectedBytes {
                Button(ProcessingWords.download(bytes)) { state.downloadModels(state.missingSelectedModels) }
            }
        }
    }
}

extension AppState {
    /// Shows Floating Notes on a conversation, or on its home for nil (the recording, while there is one).
    func showFloatingNotes(focus id: UUID?) {
        FloatingNotesWindow.shared.show(state: self, focus: id)
    }
}
