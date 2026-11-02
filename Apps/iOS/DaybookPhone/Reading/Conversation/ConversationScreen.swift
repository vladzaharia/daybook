import DaybookCaptions
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// One column: the conversation with a Summary | Transcript switch, the player at the thumb.
struct ConversationScreen: View {
    let library: LibraryController
    let id: UUID
    @Environment(ReadingSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveCaptionStore) private var captionStore
    @Environment(\.liveCaptionsSaved) private var captionsSaved
    @State private var hasCaptions = false

    var body: some View {
        @Bindable var session = session
        if let meeting = library.meeting(id) {
            // Saved live captions open the Transcript side until a transcript replaces them, as on the Mac.
            let hasTranscript = !meeting.unifiedTranscript.isEmpty || hasCaptions
            let mode: PageMode = hasTranscript ? session.pageMode : .summary
            // While the player shows, the page's foot fades hard under it, as the list's does under Record, so lines
            // don't read sharp beneath its glass.
            let edge: ScrollEdgeEffectStyle? = session.player.isActive(for: meeting.id) ? .hard : nil
            Group {
                switch mode {
                case .summary: SummaryPage(library: library, meeting: meeting, bottomEdgeEffect: edge)
                case .transcript: PhoneTranscriptPage(library: library, player: session.player, meeting: meeting)
                        .scrollEdgeEffectStyle(edge, for: .bottom)
                }
            }
            .transition(.opacity)
            .animation(DaybookMotion.resolved(.easeOut(duration: 0.15), reduceMotion: reduceMotion), value: mode)
            // A bar, so the page under the player gets the scroll edge effect rather than running sharp beneath it.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                ConversationPlayer(library: library, meeting: meeting)
            }
            .daybookMotion(DaybookMotion.state, value: session.player.isActive(for: meeting.id))
            .confirmationBeat($session.confirmation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The switch only when there's a second page to turn to; the page itself says why not.
                if hasTranscript {
                    ToolbarItem(placement: .principal) {
                        Picker("Page", selection: $session.pageMode) {
                            ForEach(PageMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                ConversationToolbar(library: library, meeting: meeting)
            }
            .task(id: SavedCaptions.Reading(meeting, lastSave: captionsSaved)) {
                let read = await SavedCaptions.read(for: meeting, from: captionStore) != nil
                guard !Task.isCancelled else { return }
                hasCaptions = read
            }
        } else {
            ContentUnavailableView("Conversation Not Found", systemImage: "doc.questionmark")
                .paperBackground()
        }
    }
}

/// Info and More, the same in every layout. Glyphs alone, in title ink like the system's back chevron: teal is for
/// what's selected and for text you can act on.
struct ConversationToolbar: ToolbarContent {
    let library: LibraryController
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { session.sheet = .info(meeting.id) } label: { Label("Info", systemImage: "info.circle") }
                .tint(PhoneStyle.Ink.title)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ConversationMoreMenu(library: library, meeting: meeting)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .tint(PhoneStyle.Ink.title)
        }
    }
}

/// The conversation's More menu: what DaybookKit's `ConversationActions` lists, in its order (share, add, reprocess,
/// history, filing, the Trash), as the Mac's More menu lists it. What doesn't apply now is left out.
struct ConversationMoreMenu: View {
    let library: LibraryController
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider
    @Environment(\.summaryPlacement) private var placement

    var body: some View {
        ConversationActionMenuItems(ConversationMoreActions.groups(meeting), platform: .iPhone) { id in
            ConversationMoreActions.perform(id, meeting: meeting, library: library, session: session, provider: provider,
                                            placement: placement)
        }
    }
}

/// What this iPhone does for each of a conversation's actions (`ConversationActions`).
@MainActor
enum ConversationMoreActions {
    /// The conversation's actions on this iPhone: Take Photo where there's a camera, Reprocess unless it's waiting.
    static func groups(_ meeting: Meeting) -> [ConversationActionGroup] {
        ConversationActions.actions(for: meeting, context: .init(platform: .iPhone, status: ProcessingStatus.phone(meeting),
                                                                 canTakePhoto: CameraPicker.isAvailable))
    }

    static func perform(_ id: ConversationAction.ID, meeting: Meeting, library: LibraryController, session: ReadingSession,
                        provider: any AudioProviding, placement: PhoneSummaryPlacement?) {
        switch id {
        case .copySummary:
            LocalPasteboard.copy(MeetingExport.summaryMarkdown(meeting))
            session.confirmation = .copied
        case .shareMarkdown, .shareJSON, .shareAudio:
            ConversationShare.share(id, meeting: meeting, session: session, provider: provider)
        case .takePhoto: session.cameraFor = meeting.id
        case .addPhotos: session.sheet = .importPhotos(meeting.id)
        case .addRecordingFromFile: session.addRecording(to: meeting.id)
        case .process(let mode):
            if mode == .summaryOnly { library.summarize(meeting.id, placement: placement) }
            else { library.requestProcessing(meeting.id, mode: mode) }
        case .versionHistory: session.sheet = .history(meeting.id)
        case .moveToFolder: session.sheet = .move([meeting.id])
        case .tags: session.sheet = .tags([meeting.id])
        case .moveTo(let placement): library.setPlacement([meeting.id], placement)
        case .moveToTrash: session.confirmingTrash = [meeting.id]
        case .share, .export, .exportMarkdown, .exportJSON, .addRecording, .reprocess:
            break // Menus, or the Mac's own.
        case .showFloatingNotes, .rename, .showInFinder:
            break // The Mac's.
        case .play, .adjustTiming, .showOriginalTranscript, .moveToNewConversation, .removeRecording:
            break // A recording's, in Info › Audio.
        }
    }
}

/// Reprocess ▸, as the More menu has it, for Info and a row's menu: what can be asked for now, nothing while a request
/// waits. Each item writes a request; the page then says it's waiting.
struct ReprocessMenu: View {
    let library: LibraryController
    let meeting: Meeting
    @Environment(\.summaryPlacement) private var placement
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider

    var body: some View {
        let groups = ConversationMoreActions.groups(meeting).filter { $0.id == .reprocess }
        ConversationActionMenuItems(groups, platform: .iPhone) { id in
            ConversationMoreActions.perform(id, meeting: meeting, library: library, session: session, provider: provider, placement: placement)
        }
    }
}

/// Share ▸, as the More menu has it, for a row's menu: the conversation as Markdown, its full data, or its audio,
/// through the share sheet.
struct ExportMenu: View {
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider

    var body: some View {
        let share = ConversationActionMenuItems.action(.share, in: ConversationMoreActions.groups(meeting)).map {
            ConversationActionGroup(id: .share, actions: [$0])
        }
        ConversationActionMenuItems(share.map { [$0] } ?? [], platform: .iPhone) { id in
            ConversationShare.share(id, meeting: meeting, session: session, provider: provider)
        }
    }
}

/// Getting a conversation's files ready for the share sheet (DaybookKit's `ExportFiles`), off the main actor.
@MainActor
enum ConversationShare {
    static func share(_ id: ConversationAction.ID, meeting: Meeting, session: ReadingSession, provider: any AudioProviding) {
        switch id {
        case .shareMarkdown: markdown(meeting, session: session, provider: provider)
        case .shareJSON: json(meeting, session: session)
        case .shareAudio: audio(meeting, session: session, provider: provider)
        default: break
        }
    }

    private static func markdown(_ meeting: Meeting, session: ReadingSession, provider: any AudioProviding) {
        Task {
            do {
                var originals: [UUID: URL] = [:]
                for photo in meeting.visiblePhotos { originals[photo.id] = try await provider.localPhoto(for: photo, in: meeting.id) }
                let files = originals
                let url = try await Task.detached { try ExportFiles.markdownWithPhotos(meeting, originals: files) }.value
                session.sheet = .share([url])
            } catch { session.alert = ReadingAlert(title: "Couldn’t Share", error: error, fallback: "The Markdown couldn’t be prepared. Try again.") }
        }
    }

    private static func json(_ meeting: Meeting, session: ReadingSession) {
        Task {
            do {
                let url = try await Task.detached { try ExportFiles.json(meeting) }.value
                session.sheet = .share([url])
            } catch { session.alert = ReadingAlert(title: "Couldn’t Share", error: error, fallback: "The conversation couldn’t be prepared. Try again.") }
        }
    }

    private static func audio(_ meeting: Meeting, session: ReadingSession, provider: any AudioProviding) {
        guard let track = meeting.transcribableTracks.first ?? meeting.tracks.first else { return }
        Task {
            do {
                let source = try await provider.localAudio(for: track, in: meeting.id) { _ in }
                let name = ExportFiles.audioName(meeting, track: track, fileExtension: source.pathExtension)
                let url = try await Task.detached { try ExportFiles.audio(source, named: name) }.value
                session.sheet = .share([url])
            } catch {
                session.alert = ReadingAlert(title: "Couldn’t Share", error: error, fallback: "The audio couldn’t be prepared. Try again.")
            }
        }
    }
}
