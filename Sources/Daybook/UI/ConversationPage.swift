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

/// A scrolling, centred page: DaybookUI's `ReadingPage` (a 56 pt time margin hanging left of a 560 pt text measure,
/// `readingWidth` for the shared rows), which also says when it's narrow for the Mac's own rows (`pageIsNarrow`).
struct PageScroll<Content: View>: View {
    var lazy = false
    var bottomInset: CGFloat = 0
    @ViewBuilder var content: Content
    @State private var width: CGFloat = 1000
    @Environment(\.spreadPage) private var spreadPage

    var body: some View {
        ReadingPage(lazy: lazy, bottomInset: bottomInset) { content }
            .environment(\.pageIsNarrow, ReadingWidth(width: width, spreadPage: spreadPage) == .narrow)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
}

/// Where the page's shared views go on this Mac: the inspector for Info, the transcript for a passage.
private struct MacReadingContext: ViewModifier {
    let state: AppState

    func body(content: Content) -> some View {
        content.readingContext(ReadingContext(
            thisDevice: AppState.thisDeviceWords, macPlace: "This Mac", audio: { _ in .local }, player: nil,
            // The window widens for the inspector where it has no room, as for any other ask of it.
            navigator: ReadingNavigator(open: { state.window.openID = $0 },
                                        showInfo: { _ in state.showInspector() },
                                        search: { state.window.searchText = $0 },
                                        showTranscript: { _, _ in state.window.turnPage(to: .transcript) })))
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
                               focusTitle: state.window.titleFocusRequest == meeting.id,
                               titleFocused: { state.window.titleFocusRequest = nil }) {
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
/// `StatusBlock` drawing DaybookKit's `ConversationStatusPresentation`, as the iPhone does, from what this Mac knows
/// (`ConversationStatusPresentation.mac`), and carried out by `MacStatusActions`.
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
        let shown = ConversationStatusPresentation.mac(state: state, meeting: meeting, now: Date())
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

    private func perform(_ action: ConversationStatusPresentation.Action) {
        MacStatusActions(state: state, undoManager: undoManager) { pane in
            settingsPane = pane.rawValue
            openSettingsWindow.settings()
        }
        .perform(action, on: meeting.id)
    }
}

extension ConversationStatusPresentation {
    /// A conversation's status on this Mac's page (`ConversationStatus`): while this Mac records it, what its recorders
    /// are doing; otherwise the shared presentation of its `ProcessingStatus` from what this Mac knows (`Inputs.mac`), with
    /// the recording being added to a transcript under the step. Nil when there's nothing to say.
    @MainActor static func mac(state: AppState, meeting: Meeting, now: Date = Date()) -> ConversationStatusPresentation? {
        if state.recordingID == meeting.id {
            return state.sources.recorders.status.map {
                ConversationStatusPresentation(kind: .line, symbol: "dot.radiowaves.left.and.right", title: $0)
            }
        }
        let status = state.processingStatus(for: meeting)
        var presentation = page(status, meeting: meeting, inputs: .mac(state: state, meeting: meeting, status: status), now: now)
        // Adding a recording to a transcript: which one, under the step.
        if case .processing(let progress) = status, progress.device == nil, presentation?.detail == nil,
           let adding = state.sourceActivity(meeting.id) {
            presentation?.detail = adding
        }
        return presentation
    }
}

extension ConversationStatusPresentation.Inputs {
    /// What this Mac knows about a conversation, for its page's status: how it calls itself, its queue (what runs, what's
    /// ahead, a download it waits for), where the summary runs, a summary waiting for its summary model, an upgrade,
    /// where an iPhone recording it waits for is, and the cloud model a cloud failure names. `status` is the
    /// conversation's, when the caller has it.
    @MainActor static func mac(state: AppState, meeting: Meeting, status: ProcessingStatus? = nil) -> Self {
        let status = status ?? state.processingStatus(for: meeting)
        // What the choices still need to download, and how this Mac's downloads stand ("Downloading models · 40%").
        var inputs = Self(words: state.statusWords, local: state.localCapabilities)
        // The cloud at work on its job: "Summarizing with Claude Sonnet 5.5 · 35%", with Stop.
        inputs.placement = .queue(state.placements[meeting.id], running: state.processingID == meeting.id)
        inputs.runningTitle = state.processingID.flatMap { id in state.meetings.first { $0.id == id }?.title }
        inputs.queueWaitsForDownload = state.downloadingID != nil && state.processingID == nil
        inputs.queuedMode = state.processingQueue.first { $0.meetingID == meeting.id }?.mode
        // Transcript first: "Waiting to summarize after the download · 38%", with Use the Cloud when it's on offer.
        var summaryMayWait = status == .transcribed
        if case .requested(.device) = status { summaryMayWait = true }
        if summaryMayWait, state.summaryWaitsForModel(meeting) {
            inputs.summaryWaitsForModel = true
            inputs.placement.cloudOffered = state.cloudOnOffer
        }
        if status == .done { inputs.upgrade = state.upgradeOffer(for: meeting) }
        // Where an iPhone recording it waits for is: " · Sending 40%", " · Last online 10:02".
        if case .awaitingRecordings = status { inputs.arrivals = state.arrivals(for: meeting) }
        if case .failed(let failure) = status, case .cloud = failure.kind, state.hasCloudSetup {
            inputs.cloudModel = state.cloud.resolved?.model.name
        }
        return inputs
    }
}
