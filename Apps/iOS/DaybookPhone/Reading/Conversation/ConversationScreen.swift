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
            .animation(DaybookMotion.resolved(DaybookMotion.pageTurn, reduceMotion: reduceMotion), value: mode)
            // A bar, so the page under the player gets the scroll edge effect rather than running sharp beneath it.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                ConversationPlayer(library: library, meeting: meeting)
            }
            .daybookMotion(DaybookMotion.state, value: session.player.isActive(for: meeting.id))
            .confirmationBeat($session.confirmation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The system's switch, only once there's a transcript to turn to: until then there's one page, and a switch
                // with a side that does nothing isn't shown.
                if hasTranscript {
                    ToolbarItem(placement: .principal) {
                        Picker("Page", selection: $session.pageMode) {
                            ForEach(PageMode.allCases) { mode in Text(mode.title).tag(mode) }
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

/// More, the same in every layout: a glyph alone, in title ink like the system's back chevron (teal is for what's
/// selected and for text you can act on). Info is its first item, above what DaybookKit's `ConversationActions` lists.
struct ConversationToolbar: ToolbarContent {
    let library: LibraryController
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { session.sheet = .info(meeting.id) } label: { Label("Info", systemImage: "info.circle") }
                Divider()
                ConversationMoreMenu(library: library, meeting: meeting)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .tint(DaybookPalette.Ink.title)
        }
    }
}

/// The conversation's More menu: what DaybookKit's `ConversationActions` lists, in its order (share, add, reprocess,
/// history, filing, the Trash), as the Mac's More menu lists it, each carried out as from a row (`PhoneActions`).
/// What doesn't apply now is left out.
struct ConversationMoreMenu: View {
    let library: LibraryController
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider
    @Environment(\.summaryPlacement) private var placement
    @Environment(PersonalLock.self) private var personalLock: PersonalLock?
    @Environment(PhoneAppModel.self) private var model: PhoneAppModel?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let lock = personalLock
        let merge = PhoneActions.MergeScope(
            library: library, recordingOnMac: model.map(PhoneActions.recordingOnMac) ?? [],
            hidden: { lock?.hides($0) == true || lock?.lists($0) == false })
        ConversationActionMenuItems(PhoneActions.groups(for: meeting, placement: placement, merge: merge), platform: .iPhone) { id in
            PhoneActions.perform(id, on: [meeting.id], library: library, session: session, provider: provider,
                                 placement: placement, undoManager: undoManager)
        } custom: { action in
            // Notebook, and Write by Hand (on a conversation being read, never on the open Duo's preview of one), under Take Photo.
            guard action.id == .addPhotos else { return nil }
            return AnyView(Group {
                Button { session.notebookFor = meeting.id } label: { Label("Notebook", systemImage: "book.pages") }
                if session.reading {
                    Button { session.writeByHand(meeting.id) } label: { Label(InkWords.writeByHand, systemImage: InkWords.writeByHandSymbol) }
                }
                Button {
                    PhoneActions.perform(action.id, on: [meeting.id], library: library, session: session, provider: provider,
                                         placement: placement, undoManager: undoManager)
                } label: { Label(action.title, systemImage: action.symbol) }
            })
        }
    }
}

/// Getting a conversation's files ready for the share sheet (DaybookKit's `ExportFiles`), off the main actor.
@MainActor
enum ConversationShare {
    static func share(_ id: ConversationAction.ID, meeting: Meeting, session: ReadingSession, provider: any AudioProviding) {
        switch id {
        case .shareMarkdown: markdown(meeting, session: session, provider: provider)
        case .shareJSON: json(meeting, session: session, provider: provider)
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

    private static func json(_ meeting: Meeting, session: ReadingSession, provider: any AudioProviding) {
        Task {
            do {
                // The page drawings this iPhone has or can fetch travel in the file with the rest of the conversation's data.
                var drawings: [String: URL] = [:]
                for drawing in (meeting.pages ?? []).compactMap(\.drawing) {
                    if let url = try? await provider.localPageDrawing(for: drawing, in: meeting.id) { drawings[drawing.relativePath] = url }
                }
                let files = drawings
                let url = try await Task.detached { try ExportFiles.json(meeting, pageDrawings: files) }.value
                session.sheet = .share([url])
            } catch { session.alert = ReadingAlert(title: "Couldn’t Share", error: error, fallback: "The conversation couldn’t be prepared. Try again.") }
        }
    }

    private static func audio(_ meeting: Meeting, session: ReadingSession, provider: any AudioProviding) {
        guard let track = meeting.primaryRecording else { return }
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
