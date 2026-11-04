import AppKit
import DaybookCore
import DaybookDesign
import DaybookIntelligence
import DaybookKit
import DaybookUI
import IOKit
import SwiftUI

// MARK: - Page geometry

struct PageIsNarrowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True when the detail column is too narrow for the time margin; times then render inline.
    var pageIsNarrow: Bool {
        get { self[PageIsNarrowKey.self] }
        set { self[PageIsNarrowKey.self] = newValue }
    }
}

/// A scrolling, centred page: DaybookUI's `ReadingPage` (a 56 pt time margin hanging left of a 640 pt text measure,
/// `readingWidth` for the shared rows), which also says when it's narrow for the Mac's own rows (`pageIsNarrow`).
struct PageScroll<Content: View>: View {
    var lazy = false
    var bottomInset: CGFloat = 0
    @ViewBuilder var content: Content
    @State private var width: CGFloat = 1000

    var body: some View {
        ReadingPage(lazy: lazy, bottomInset: bottomInset) { content }
            .environment(\.pageIsNarrow, ReadingWidth(width: width) == .narrow)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// One block of the page: an optional margin item (a time, a glyph) and content in the measure.
struct MarginRow<Margin: View, Content: View>: View {
    var alignment: VerticalAlignment = .firstTextBaseline
    /// A 4 pt dot drawn in the 8 pt gutter between the margin and the text, never moving the time.
    var gutterDot: Color? = nil
    @ViewBuilder var margin: Margin
    @ViewBuilder var content: Content
    @Environment(\.pageIsNarrow) private var narrow

    var body: some View {
        if narrow {
            HStack(alignment: alignment, spacing: 6) {
                margin.fixedSize()
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: alignment, spacing: 0) {
                HStack(spacing: 4) { margin }
                    .frame(width: DaybookStyle.margin - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                    .overlay(alignment: .trailing) {
                        if let gutterDot { Circle().fill(gutterDot).frame(width: 4, height: 4).offset(x: -2) }
                    }
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension MarginRow where Margin == EmptyView {
    init(alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: () -> Content) {
        self.init(alignment: alignment, gutterDot: nil, margin: { EmptyView() }, content: content)
    }
}

/// A clickable time in the margin: meta ink, link ink on hover, plays from there.
struct MarginTime: View {
    let time: TimeInterval
    var alwaysVisible = true
    let play: () -> Void
    @Environment(\.readingScale) private var scale
    @State private var hovering = false
    var body: some View {
        Button(action: play) {
            Text(TimeLabel.short(time))
                .font(TypeStyle.margin(scale))
                .foregroundStyle(hovering ? Ink.link : Ink.meta)
        }
        .buttonStyle(.plain)
        .opacity(alwaysVisible || hovering ? 1 : 0)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .help("Play from here")
        .accessibilityLabel("Play from \(SpokenTime.format(time))")
    }
}

// MARK: - Reading context

extension AppState {
    /// How this Mac calls itself in a conversation's status and colophon: "this Mac", with its glyph by what it is (a
    /// MacBook's laptop, whatever it's named), else by its name, the rule the iPhone uses for this Mac too
    /// (`SettingsWords.deviceSymbol`).
    var statusWords: DeviceWords {
        DeviceWords.mac(id: library.thisDevice.id, symbol: SettingsWords.thisDeviceSymbol(model: Self.hardwareModel, name: library.thisDevice.name))
    }

    /// What this Mac is, read once: Apple silicon's product name ("MacBook Pro (14-inch, M5 Pro)"), since its model
    /// identifiers no longer name the family ("Mac17,9"); else the identifier ("MacBookPro16,1"); "Mac" when neither
    /// can be read.
    nonisolated static let hardwareModel: String = productName() ?? modelIdentifier() ?? "Mac"

    private nonisolated static func productName() -> String? {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard product != 0 else { return nil }
        defer { IOObjectRelease(product) }
        guard let data = IORegistryEntryCreateCFProperty(product, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private nonisolated static func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        let model = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return model.isEmpty ? nil : model
    }

    /// Shows a passage in the transcript: the page turns to it and scrolls there.
    func showPassage(_ segmentID: UUID) {
        pageScrollTarget = segmentID
        pageMode = .transcript
    }
}

/// Where the page's shared views go on this Mac: the inspector for Info, the transcript for a passage.
private struct MacReadingContext: ViewModifier {
    let state: AppState

    func body(content: Content) -> some View {
        content.readingContext(ReadingContext(
            thisDevice: AppState.thisDeviceWords, macPlace: "This Mac", audio: { _ in .local }, player: nil,
            // The window widens for the inspector where it has no room, as for any other ask of it.
            navigator: ReadingNavigator(open: { state.selectedID = $0 },
                                        showInfo: { _ in state.showInspector() },
                                        search: { state.search = $0 },
                                        showTranscript: { _, _ in state.pageMode = .transcript })))
    }
}

extension View {
    /// The page's shared views reach this Mac's inspector and transcript.
    func macReadingContext(_ state: AppState) -> some View { modifier(MacReadingContext(state: state)) }
}

// MARK: - Header

/// Title and one byline: the same on Summary and Transcript, so switching feels like turning the page. DaybookUI's
/// `ConversationHeader`, with this Mac's player in its play pill.
struct PageHeader: View {
    let state: AppState
    let player: AudioPlaybackController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void

    var body: some View {
        MarginRow {
            ConversationHeader(meeting: meeting, library: state.library,
                               recording: state.recordingID == meeting.id ? "Recording" : nil,
                               focusTitle: state.titleFocusRequest == meeting.id,
                               titleFocused: { state.titleFocusRequest = nil }) {
                if let duration = meeting.duration {
                    ConversationPlayPill(duration: duration, player: pillPlayer, unavailable: state.isRecording ? "Playback is off while recording" : nil)
                }
            }
        }
        .macReadingContext(state)
    }

    private var pillPlayer: ConversationPlayPill.Player {
        let id = meeting.id
        return ConversationPlayPill.Player(isHere: { player.meetingID == id && player.duration > 0 },
                                           isPlaying: { player.isPlaying },
                                           position: { player.position },
                                           toggle: { state.playback.toggle() },
                                           start: { play(.timeline(0)) })
    }
}

// MARK: - Status line

/// The one line that speaks when something is working or needs the person, and is absent otherwise: DaybookUI's
/// `StatusBlock` drawing DaybookKit's `ConversationStatusPresentation`, as the iPhone does, from this Mac's queue.
struct ConversationStatus: View {
    let state: AppState
    let meeting: Meeting
    /// What the recorders recording along are doing ("Soundcore Work is recording too").
    private let sources: MultiSourceCoordinator
    /// A summary's countdown, and the cloud at work.
    private let placements: SummaryPlacements
    @AppStorage(SettingsPane.storageKey) private var settingsPane = "general"
    @Environment(\.openWindow) private var openSettingsWindow
    @Environment(\.undoManager) private var undoManager

    init(state: AppState, meeting: Meeting) {
        self.state = state
        self.meeting = meeting
        sources = state.sources
        placements = state.placements
    }

    var body: some View {
        // Progress redraws only this line, at its own pace.
        ActivityReader { content }
            // Settings › Cloud, when the cloud could upgrade this summary.
            .task(id: meeting.id) { await state.prepareUpgradeOffer(for: meeting) }
    }

    @ViewBuilder private var content: some View {
        let shown = presentation(at: Date())
        VStack(alignment: .leading, spacing: 0) {
            if let shown {
                // A countdown's seconds tick in the block's own words; nothing else here redraws for them.
                MarginRow { StatusBlock(shown, perform: perform) }
                .padding(.top, Space.s5)
                .daybookTransition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .daybookMotion(Motion.state, value: StatusBlockLayout.motionKey(shown))
    }

    /// Recording is this Mac's own state; everything else is the shared presentation of `ProcessingStatus`.
    private func presentation(at now: Date) -> ConversationStatusPresentation? {
        if state.recordingID == meeting.id {
            return state.sources.recorders.status.map {
                ConversationStatusPresentation(kind: .line, symbol: "dot.radiowaves.left.and.right", title: $0)
            }
        }
        let status = state.processingStatus(for: meeting)
        var presentation = ConversationStatusPresentation.page(status, meeting: meeting, inputs: inputs(for: status), now: now)
        // Adding a recording to a transcript: which one, under the step.
        if case .processing(let progress) = status, progress.device == nil, presentation?.detail == nil,
           let adding = state.sourceActivity(meeting.id) {
            presentation?.detail = adding
        }
        return presentation
    }

    private func inputs(for status: ProcessingStatus) -> ConversationStatusPresentation.Inputs {
        let download = state.downloadingID.map {
            ConversationStatusPresentation.LocalCapabilities.Download(name: state.modelCatalog.name(for: $0),
                                                                      fraction: state.downloadProgress.fraction)
        }
        let missing = state.missingSelectedModels.compactMap { state.modelCatalog.model($0)?.approximateBytes }.reduce(0, +)
        var inputs = ConversationStatusPresentation.Inputs(words: state.statusWords, local: .mac(missingModelBytes: missing, download: download))
        // The cloud at work on its job: "Summarizing with Claude Sonnet 5.5 · 35%", with Stop.
        inputs.placement = .queue(placements[meeting.id], running: state.processingID == meeting.id)
        inputs.runningTitle = state.processingID.flatMap { id in state.meetings.first { $0.id == id }?.title }
        inputs.queueWaitsForDownload = state.downloadingID != nil && state.processingID == nil
        inputs.queuedMode = state.processingQueue.first { $0.meetingID == meeting.id }?.mode
        if status == .done { inputs.upgrade = state.upgradeOffer(for: meeting) }
        if case .failed(let failure) = status, case .cloud = failure.kind, state.hasCloudSetup {
            inputs.cloudModel = state.cloud.resolved?.model.name
        }
        return inputs
    }

    private func perform(_ action: ConversationStatusPresentation.Action) {
        let id = meeting.id
        switch action {
        case .transcribe: state.enqueue(id, mode: .newAudio)
        case .summarize, .useYourMac: state.enqueue(id, mode: .summaryOnly)
        case .tryAgain(let mode): state.enqueue(id, mode: mode)
        case .details: break
        case .pause, .stopSummary: state.pauseProcessing(id)
        case .resume: state.enqueue(id, mode: state.defaultProcessingMode(for: meeting))
        case .cancel: state.cancelQueued(id)
        case .cancelRequest(let request):
            let device = state.library.thisDevice
            state.library.update(id) { $0.withdrawProcessingRequest(request, by: device, at: Date()) }
        case .dontWait: state.library.stopWaitingForRecordings(in: id, undoManager: undoManager)
        case .cancelDownload: state.cancelDownload()
        case .downloadModels:
            state.enqueue(id)
            state.downloadModels(state.missingSelectedModels)
        case .chooseModels: openSettingsPane("models")
        case .cloudSettings: openSettingsPane("cloud")
        case .summarizeHere: state.summarizeHere(id)
        case .placement(let choice): state.chooseSummaryPlacement(choice, for: id)
        case .upgrade(let offer): state.acceptUpgrade(offer, for: id)
        case .dismissUpgrade(let offer): state.dismissUpgrade(offer, for: id)
        case .dismiss: state.update(id) { $0.errorMessage = nil }
        }
    }

    private func openSettingsPane(_ pane: String) {
        settingsPane = pane
        openSettingsWindow.settings()
    }
}

/// What a status box is about: something went wrong, something to do, or something to know.
enum StatusBoxKind { case problem, accent, info }

/// A state that needs the person, on a device's page and in the transcript's notices: the same box as a
/// conversation's status (`StatusBlock`), with one radius and padding from the tokens, its glyph on the title's
/// first baseline, and its actions beside the words, or under them in a narrow measure.
struct StatusBox<Actions: View>: View {
    let kind: StatusBoxKind
    let symbol: String
    let title: String
    let message: String?
    let actions: Actions
    @State private var width: CGFloat = DaybookStyle.measure
    @Environment(\.colorSchemeContrast) private var contrast

    private var attention: AttentionKind {
        switch kind {
        case .problem: return .problem
        case .accent: return .accent
        case .info: return .info
        }
    }
    private var stacked: Bool { StatusBlockLayout.stacksActions(width: width, density: .window) }
    private var tint: Color {
        switch kind {
        case .problem: return Ink.warning
        case .accent: return DaybookStyle.accent
        case .info: return Ink.secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .symbolRenderingMode(kind == .problem ? .monochrome : .hierarchical)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(TypeStyle.statusLead).foregroundStyle(AttentionBoxLayout.title(for: attention).ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        Text(message).font(TypeStyle.status).foregroundStyle(AttentionBoxLayout.message(for: attention).ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if stacked { actionRow }
            }
            .layoutPriority(1)
            if !stacked {
                Spacer(minLength: Space.s3)
                actionRow
            }
        }
        .padding(Space.s3)
        // Stacked or not, the box spans the measure, so boxes and lines share both edges.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AttentionBoxLayout.wash(for: attention).color, in: DaybookRadius.shape(DaybookRadius.box))
        .overlay {
            if contrast == .increased {
                DaybookRadius.shape(DaybookRadius.box).strokeBorder(kind == .problem ? Ink.warning : Ink.meta, lineWidth: 1)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var actionRow: some View {
        HStack(spacing: Space.s3) { actions }
            .controlSize(.small)
            .fixedSize()
    }
}


/// Plain-language reasons for processing failures, for Floating Notes' box, which has only the conversation's message.
/// The page words a failure from its stored kind (`FailureWords`). The technical message stays one click away.
enum FriendlyError {
    /// The recording worked but holds no speech; trying again can't help.
    static func isNoSpeech(_ error: String) -> Bool { error.lowercased().contains("no speech") }

    static func message(for error: String) -> String {
        let lower = error.lowercased()
        if lower.contains("no speech") { return "No speech was found. \(FailureWords.saved)" }
        if lower.contains("download") || lower.contains("not installed") { return "Its models aren’t downloaded yet. \(FailureWords.saved)" }
        if lower.contains("memory") || lower.contains("language model") { return "The summary model couldn’t start. Choose Quick in Settings › Models, or close other apps and try again." }
        return "Something went wrong. \(FailureWords.saved)"
    }
}
