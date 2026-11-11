import DaybookCaptions
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// The conversation as a page: the title, one byline, the processing status when there's
/// something to say, then what happened (the lede), the next steps, the template's sections, your
/// notes with their recording times, your bookmarks, and how the page was made.
///
/// The blocks are DaybookUI's, the same as the Mac's page (`ConversationHeader`, `StatusBlock`, `SummaryBody`,
/// `YourNotes`, `Colophon`); this iPhone gives them its notes editor, photos, player, and what it knows about its Macs.
/// A conversation that isn't transcribed yet is a complete page too: everything but the summary works.
struct SummaryPage: View {
    let library: LibraryController
    let meeting: Meeting
    /// The page shows its own title and byline (one column, and the notebook's left page).
    var showsHeader = true
    /// The scroll edge effect under what sits at the page's foot: hard under the notebook's status
    /// panel, so the page doesn't read through its glass; nil is the system's.
    var bottomEdgeEffect: ScrollEdgeEffectStyle? = nil
    @Environment(ReadingSession.self) private var session
    @Environment(PhoneAppModel.self) private var model: PhoneAppModel?
    @Environment(\.audioProvider) private var provider
    @Environment(\.macSighting) private var sightingOverride
    @Environment(\.summaryPlacement) private var placement
    @Environment(\.upgrades) private var upgrades
    @Environment(\.isTwoPage) private var twoPage
    @Environment(\.findQuery) private var query
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var consumedToken = 0
    @Environment(\.liveCaptionStore) private var captionStore
    @Environment(\.liveCaptionsSaved) private var captionsSaved
    /// Saved live captions take the transcript's page, which then doesn't say "Not transcribed yet".
    @State private var hasCaptions = false
    /// The summary present when the page opened. Any later one arrived while the page was on screen, so it's
    /// revealed block by block; opening a page never animates, nor does turning it to another conversation.
    @State private var arrival: SummaryArrival
    /// A Settings screen the status opened (Cloud Settings).
    @State private var settings: PageSettings?

    init(library: LibraryController, meeting: Meeting, showsHeader: Bool = true, bottomEdgeEffect: ScrollEdgeEffectStyle? = nil) {
        self.library = library
        self.meeting = meeting
        self.showsHeader = showsHeader
        self.bottomEdgeEffect = bottomEdgeEffect
        _arrival = State(initialValue: SummaryArrival(opening: meeting))
    }

    var body: some View {
        @Bindable var session = session
        let status = self.status(at: Date())
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if showsHeader {
                        PageHeader(library: library, meeting: meeting, play: play).id(SummaryBlockID.header)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        if let status, !(twoPage && isRecordedOnly && !hasCaptions) {
                            StatusBlock(status, perform: perform)
                                .padding(.top, DaybookSpacing.s4)
                                .daybookTransition(.opacity.combined(with: .move(edge: .top)))
                                .id("status")
                        } else if meeting.tracks.isEmpty && !twoPage {
                            // Only notes so far: the byline says so, and Record records into it. Two pages offer it
                            // on the transcript's page.
                            RecordIntoButton(meeting: meeting)
                                .padding(.top, DaybookSpacing.s4)
                                .id("status")
                        }
                    }
                    .daybookMotion(DaybookMotion.state, value: StatusBlockLayout.motionKey(status))
                    if let summary = meeting.summary {
                        SummaryBody(meeting: meeting, summary: summary, library: library, query: query,
                                    revealing: arrival.reveals(summary, in: meeting), passages: passages,
                                    blockID: Self.blockID) { section in
                            ForEach(meeting.photos(in: section)) { PhotoTile(meeting: meeting, photo: $0, large: true).padding(.top, DaybookSpacing.s2) }
                        }
                        // A new summary is a new block, so it reveals itself; the ID is a String, as the page's anchors are.
                        .id("summary:\(summary.createdAt.timeIntervalSinceReferenceDate)")
                        .opacity(isResummarizing ? 0.5 : 1)
                        .daybookTransition(.opacity)
                    }
                    PhoneNotes(library: library, meeting: meeting, play: play, passages: passages)
                        .padding(.top, meeting.summary == nil ? DaybookSpacing.s5 : 0)
                        .id(meeting.summary == nil ? SummaryBlockID.notes : "notes-body")
                    PhotoStrip(meeting: meeting)
                    if let summary = meeting.summary {
                        PageColophon(library: library, meeting: meeting, summary: summary).id(SummaryBlockID.colophon)
                    }
                }
                .scrollTargetLayout()
                .pageColumn()
                .padding(.top, DaybookSpacing.s3)
                .padding(.bottom, DaybookSpacing.s8)
            }
            .scrollPosition(id: $session.summaryAnchor, anchor: .top)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(bottomEdgeEffect, for: .bottom)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { session.pageMode = .summary }
            }
            .onAppear { handleRequest(proxy) }
            .onChange(of: session.summaryRequest) { _, _ in handleRequest(proxy) }
        }
        // Every page of the iPhone keeps its times in a lane inside the column (docs/interface.md, "Geometry").
        .environment(\.readingWidth, .narrow)
        .readingContext(readingContext)
        .paperBackground()
        .onChange(of: meeting.id) { arrival = SummaryArrival(opening: meeting) }
        .task(id: SavedCaptions.Reading(meeting, lastSave: captionsSaved)) {
            let read = await SavedCaptions.read(for: meeting, from: captionStore) != nil
            guard !Task.isCancelled else { return }
            hasCaptions = read
        }
        .sheet(item: $settings) { page in
            NavigationStack {
                SettingsDestination(route: page.route)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = nil } } }
            }
        }
        .daybookMotion(DaybookMotion.page, value: meeting.summary?.createdAt)
        .daybookMotion(DaybookMotion.dim, value: isResummarizing)
    }

    /// The page's blocks' scroll IDs, which the transcript and search jump to.
    private static func blockID(_ block: SummaryBlock) -> String? {
        switch block {
        case .lede: return SummaryBlockID.lede
        case .nextSteps: return SummaryBlockID.nextSteps
        case .section(let id): return SummaryBlockID.section(id)
        case .notesHeading: return SummaryBlockID.notes
        }
    }

    /// A passage, from a summary line or a bookmark: on two pages the transcript beside scrolls there; in one column
    /// the page turns to it.
    private var passages: PassageLinks {
        PassageLinks(onTap: twoPage) { [session, twoPage] in session.showInTranscript($0, switchPage: !twoPage) }
    }

    private var readingContext: ReadingContext {
        ReadingContext(thisDevice: PhoneSummaryPlacement.thisDeviceWords, macPlace: "Your Mac", audio: { _ in .local }, player: nil,
                       navigator: ReadingNavigator(open: { [session] in session.open($0) },
                                                   showInfo: { [session] in session.sheet = .info($0) },
                                                   search: { _ in },
                                                   showTranscript: { [session] _, _ in session.pageMode = .transcript }))
    }

    private func handleRequest(_ proxy: ScrollViewProxy) {
        guard let request = session.summaryRequest, request.token != consumedToken else { return }
        consumedToken = request.token
        let animation = DaybookMotion.scrollAnimation(reduceMotion: reduceMotion)
        Task { @MainActor in
            withAnimation(animation) { proxy.scrollTo(request.target, anchor: .top) }
        }
    }

    // MARK: Status

    /// The shared presentation of the conversation's processing, from what this iPhone knows
    /// (`ConversationStatusPresentation.phone`).
    private func status(at now: Date) -> ConversationStatusPresentation? {
        ConversationStatusPresentation.phone(meeting, library: library, model: model, placement: placement, upgrades: upgrades,
                                             sighting: sightingOverride, now: now)
    }

    /// What this iPhone does itself: its own recordings when processing here is on, with what the models still need,
    /// how the whole set asked for is coming (one figure over all of it, as every surface says it), and the summary model
    /// it could download where it has the memory for one and the room. Without the app's model (previews), nothing.
    static func local(_ model: PhoneAppModel?) -> ConversationStatusPresentation.LocalCapabilities {
        guard let model else { return .iPhone() }
        return local(model.models, processesHere: model.settings.processesOnThisIPhone, summarizes: model.processingCapabilities.summarizes)
    }

    static func local(_ models: PhoneModels, processesHere: Bool, summarizes: Bool) -> ConversationStatusPresentation.LocalCapabilities {
        let summaryBytes = models.summaryModelBytes
        // While the system's speech model stands in, transcribing waits for no download: nothing to offer one for.
        let standsIn = models.transcriptionStandIn != nil
        return .iPhone(processesHere: processesHere, summarizes: processesHere && summarizes,
                       missingModelBytes: standsIn ? 0 : models.processingMissingBytes, download: standsIn ? nil : models.transcribingDownload,
                       models: models.processingDownloadState,
                       summaryModelBytes: models.space.fits(summaryBytes) ? summaryBytes : 0, summaryModelAsked: models.summaryModelAsked)
    }

    /// Recorded and nothing asked yet: two pages say so on the transcript's page, with Transcribe.
    private var isRecordedOnly: Bool {
        if case .recorded = ProcessingStatus.phone(meeting) { return true }
        return false
    }

    /// Summarize Again: the old summary steps back while the new one is written.
    private var isResummarizing: Bool {
        // Counting down, or waiting for a Mac, this iPhone holds the Summarize request, but nothing is being written yet.
        if let placement, placement.planners[meeting.id] != nil, placement.runs[meeting.id] == nil { return false }
        if case .processing(let progress) = ProcessingStatus.phone(meeting), progress.stage == .summarizing { return true }
        return false
    }

    private func play(_ target: PlaybackTarget) {
        session.player.play(target, in: meeting, provider: provider)
    }

    private func perform(_ action: ConversationStatusPresentation.Action) {
        PhoneStatusActions(library: library, undoManager: undoManager, session: session, model: model, placement: placement,
                           upgrades: upgrades, openSettings: { settings = PageSettings(route: $0) })
            .perform(action, on: meeting.id)
    }
}

extension ConversationStatusPresentation {
    /// A conversation's status on this iPhone's page (`SummaryPage`): the shared presentation of its `ProcessingStatus`
    /// from what this iPhone knows (`Inputs.phone`). Nil when there's nothing to say.
    @MainActor static func phone(_ meeting: Meeting, library: LibraryController, model: PhoneAppModel?, placement: PhoneSummaryPlacement?,
                                 upgrades: PhoneUpgrades?, sighting: MacSighting? = nil, now: Date = Date()) -> ConversationStatusPresentation? {
        let status = ProcessingStatus.phone(meeting, now: now)
        return page(status, meeting: meeting, inputs: .phone(model: model, library: library, meeting: meeting, status: status,
                                                            placement: placement, upgrades: upgrades, sighting: sighting, now: now), now: now)
    }
}

extension ConversationStatusPresentation.Inputs {
    /// What this iPhone knows about a conversation, for its page's status: what it does itself (`SummaryPage.local`),
    /// whether a Mac is around and a Mac's live progress over the link, where its summaries run (`placement`), why its own
    /// work is paused, whether the recordings still to transcribe are its own, an upgrade, and its own recording a Mac
    /// waits for. `model` is nil only without the app's (previews); `sighting` stands in for the library's last sight of
    /// a Mac (`\.macSighting`).
    @MainActor static func phone(model: PhoneAppModel?, library: LibraryController, meeting: Meeting, status: ProcessingStatus,
                                 placement: PhoneSummaryPlacement?, upgrades: PhoneUpgrades?, sighting: MacSighting? = nil,
                                 now: Date = Date()) -> Self {
        var inputs = Self(words: .iPhone(id: library.thisDevice.id), local: SummaryPage.local(model))
        let ownsTrack = model?.library.ownsTrack ?? { _ in false }
        inputs.mac = ConversationStatusPresentation.MacStanding.phone(
            presence: model?.macPresence,
            sighting: sighting ?? MacSighting.latest(in: library.meetings, excluding: library.thisDevice.id, owns: ownsTrack),
            override: sighting != nil, connected: model?.link.connectedMacs ?? [], liveProgress: model?.liveProgress ?? [:],
            meetingID: meeting.id, now: now)
        inputs.link = model?.liveProgress[meeting.id].map(ConversationStatusPresentation.LinkWork.init(live:))
        inputs.placement = .init(planner: placement?.planners[meeting.id], run: placement?.runs[meeting.id],
                                 cloudOffered: placement?.cloudOffer != nil)
        inputs.pause = PhoneProcessor.current?.pause.map(ProcessingWords.PauseReason.init(phone:))
        inputs.cloudModel = placement?.cloud?.resolved?.model.name
        if let owns = model?.library.ownsTrack {
            inputs.ownsUntranscribed = meeting.transcribableTracks
                .filter { track in !meeting.transcripts.contains { $0.trackID == track.id } }
                .allSatisfy(owns)
        }
        // A clearly better model within reach, when there's nothing else to say.
        if status == .done { inputs.upgrade = upgrades?.offer(for: meeting, now: now) }
        // Its own recording a Mac waits for, not on its way yet: the line the Mac's page matches.
        inputs.unsent = model?.multipoints.unsent(meeting.id)
        return inputs
    }
}

/// A Settings screen opened from the page.
private struct PageSettings: Identifiable {
    let route: SettingsRoute
    var id: SettingsRoute { route }
}

// MARK: - Header

/// Title and one byline: the same on both pages and both apps, so switching feels like turning the page. DaybookUI's
/// `ConversationHeader`, with this iPhone's player in its play pill, and "Recording on Studio Mac" while a Mac records it.
struct PageHeader: View {
    let library: LibraryController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    @Environment(ReadingSession.self) private var session
    @Environment(PhoneAppModel.self) private var model: PhoneAppModel?

    var body: some View {
        ConversationHeader(meeting: meeting, library: library, recording: recording) {
            if let duration = meeting.duration {
                ConversationPlayPill(duration: duration, player: pillPlayer)
            }
        }
        .readingContext(ReadingContext(thisDevice: PhoneSummaryPlacement.thisDeviceWords, macPlace: "Your Mac", audio: { _ in .local },
                                       navigator: ReadingNavigator(open: { [session] in session.open($0) },
                                                                   showInfo: { [session] in session.sheet = .info($0) },
                                                                   search: { _ in }, showTranscript: { _, _ in })))
    }

    /// A Mac recording this conversation, over the link.
    private var recording: String? {
        model?.link.connectedMacs.first { $0.isRecording && $0.recording?.conversationID == meeting.id }.map { "Recording on \($0.name)" }
    }

    private var pillPlayer: ConversationPlayPill.Player {
        let player = session.player, id = meeting.id
        return ConversationPlayPill.Player(isHere: { player.meetingID == id && player.phase == .ready },
                                           isPlaying: { player.isPlaying },
                                           position: { player.position },
                                           toggle: { player.toggle() },
                                           start: { play(.timeline(0)) })
    }
}

// MARK: - Colophon

/// How the page was made, at its foot: DaybookUI's `Colophon`, with the template menu and Summarize Again.
private struct PageColophon: View {
    let library: LibraryController
    let meeting: Meeting
    let summary: MeetingSummary
    @Environment(PhoneAppModel.self) private var model: PhoneAppModel?
    @Environment(\.summaryPlacement) private var placement

    var body: some View {
        let deviceClass = summary.origin.deviceID.flatMap { id in model?.sync.devices.first { $0.id == id }?.deviceClass }
        Colophon(SummaryColophon(summary, thisDeviceID: library.thisDevice.id, words: .iPhone(id: library.thisDevice.id),
                                 deviceClass: deviceClass),
                 arrived: summary.createdAt, template: TemplateWords.title(for: meeting, resolved: library.resolvedTemplate(for: meeting)),
                 summarizeAgain: summarizeAgain) {
            TemplatePicker(library: library, meeting: meeting)
        }
    }

    /// Only while it can be asked for: a pending request already shows on the page.
    private var summarizeAgain: (() -> Void)? {
        guard !meeting.unifiedTranscript.isEmpty, !ProcessingStatus.phone(meeting).isPending else { return nil }
        return { [library, placement, id = meeting.id] in library.summarize(id, placement: placement) }
    }
}

/// The template menu's items: Automatic (with its guess), then the built-in and your own templates. Choosing another
/// one summarizes again; the old summary stays in Version History.
struct TemplatePicker: View {
    let library: LibraryController
    let meeting: Meeting
    @Environment(\.summaryPlacement) private var placement

    var body: some View {
        Picker("Template", selection: Binding(get: { library.templateSelection(for: meeting.id) }, set: choose)) {
            Text(TemplateWords.automatic(for: meeting)).tag("auto")
            Divider()
            ForEach(library.templates.filter(\.isBuiltIn)) { Text($0.name).tag($0.id) }
            let custom = library.templates.filter { !$0.isBuiltIn }
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { Text($0.name).tag($0.id) }
            }
        }
    }

    private func choose(_ id: String) {
        guard library.chooseTemplate(id, for: meeting.id), !meeting.unifiedTranscript.isEmpty else { return }
        library.summarize(meeting.id, templateID: id == "auto" ? nil : id, placement: placement)
    }
}
