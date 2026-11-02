import AppKit
import DaybookCaptions
import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI
import UniformTypeIdentifiers

/// The list column: conversations in the selected place, the Trash, or search results.
struct ConversationList: View {
    @Bindable var state: AppState
    @State private var isDropTargeted = false
    @State private var tagging: ConversationIDs?
    /// Matches in saved live captions, which the results list and the subtitle's count share.
    @State private var captionHits: [LibraryCaptionSearch.Hit] = []
    @Environment(\.undoManager) private var undoManager

    private var selection: Binding<Set<UUID>> {
        Binding(get: {
            !state.multiSelection.isEmpty ? state.multiSelection : Set(state.selectedID.map { [$0] } ?? [])
        }, set: { ids in
            if ids.count > 1 { state.multiSelection = ids }
            else { state.multiSelection = []; state.selectedID = ids.first }
        })
    }

    var body: some View {
        Group {
            if state.isSearching { SearchResults(state: state, captionHits: $captionHits) }
            else if state.place.isTrash { MacTrashList(state: state) }
            else { browsing }
        }
        .navigationTitle(title)
        // The subtitle follows a download's percent without redrawing the list.
        .modifier(ListSubtitle(placements: state.placements) { subtitle(at: $0) })
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                SyncAttention(state: state)
                LibraryNotice(state: state)
            }
        }
        .overlay { if isDropTargeted { DropOutline(label: "Import Audio") } }
        .dropDestination(for: URL.self) { urls, _ in importAudio(urls) } isTargeted: { isDropTargeted = $0 }
        .onDeleteCommand { if !state.place.isTrash { state.trashRequestIDs = Array(selection.wrappedValue) } }
        .sheet(item: $tagging) { request in
            ConversationTagsChooser(library: state.library, ids: request.ids) { tagging = nil }
        }
    }

    // MARK: Browsing

    private var browsing: some View {
        let meetings = state.visibleMeetings
        let selected = selection.wrappedValue
        return List(selection: selection) {
            ForEach(DateGroup.groups(for: meetings)) { group in
                Section(group.title) {
                    ForEach(group.meetings) { meeting in
                        // Each row draws in a view of its own, and only the row being processed reads the job's progress
                        // (`processingStatus(for:)`): a progress report, or a summary's countdown, redraws that row alone.
                        ActivityReader {
                            ConversationRowView(meeting: meeting, status: MacRowStatus.make(state, meeting),
                                                timeLabel: RowDate.format(meeting.date, group: group.title),
                                                isSelected: selected.contains(meeting.id))
                        }
                        .tag(meeting.id)
                        .modifier(RowDrag(meeting: meeting))
                        .listRowSeparator(.hidden)
                    }
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .softTopScrollEdge()
        // ⌘C copies the selection: inside Daybook the conversations, elsewhere their Markdown or their words.
        .copyable(state.meetings.filter { selection.wrappedValue.contains($0.id) }.map(ConversationTransfer.init))
        .motion(state.isReady ? Motion.state : .linear(duration: 0), value: meetings.map(\.id))
        .contextMenu(forSelectionType: UUID.self) { ids in
            RowMenu(state: state, ids: Array(ids), undoManager: undoManager) { tagging = ConversationIDs(ids: $0) }
        } primaryAction: { ids in
            if let id = ids.first { state.selectedID = id; state.focusTitle(id) }
        }
        .overlay {
            if meetings.isEmpty && state.isReady,
               let words = LibraryWords.emptyPlace(state.place, libraryIsEmpty: state.meetings.isEmpty, platform: .mac) {
                LibraryEmptyPlaceView(words)
            }
        }
    }

    // MARK: Title and status

    private var title: String {
        switch state.place {
        case .section(let section): return section.rawValue
        case .folder(let id): return state.folders.first { $0.id == id }?.name ?? "Folder"
        case .device(let id): return state.devices.session(id)?.device.name ?? "Device"
        case .trash: return LibraryWords.trash
        }
    }

    /// Says something only while work is happening (a selection's count is on the page). While the running job's
    /// summary counts down, or runs in the cloud, it says that: "Summarizing in 12 s".
    private func subtitle(at now: Date) -> String {
        if state.isSearching {
            let count = state.searchHits.count + captionHits.count
            return count == 1 ? "1 result" : "\(count) results"
        }
        if state.isStoppingRecording { return "Saving recording…" }
        if state.isRecording { return "Recording" }
        if let id = state.processingID {
            if let placing = state.placements[id]?.shortLine(at: now) { return placing }
            let total = state.queuedIDs.count + 1
            return total > 1 ? "Transcribing 1 of \(total)" : "Transcribing"
        }
        if state.downloadingID != nil { return "Downloading models · \(Int(state.downloadProgress.fraction * 100))%" }
        return ""
    }

    private func importAudio(_ urls: [URL]) -> Bool {
        let audio = AppState.droppedRecordings(urls)
        guard !audio.isEmpty else { return false }
        Task { do { try await state.importFiles(audio, source: .imported, attachTo: nil) } catch { state.report("Couldn’t Import Audio", "Choose an audio or video file and try again.", error) } }
        return true
    }
}

/// Conversations an action is about, for a sheet.
struct ConversationIDs: Identifiable {
    let ids: [UUID]
    var id: [UUID] { ids }
}

/// What a row says on this Mac (`ConversationStatusPresentation.row`): its own recording, where its summary runs,
/// this Mac's queue, and what the library says; and the mint waveform while it plays.
@MainActor
enum MacRowStatus {
    static func make(_ state: AppState, _ meeting: Meeting, now: Date = Date()) -> ConversationRowStatus? {
        let inputs = ConversationStatusPresentation.Inputs(
            words: .mac(id: state.library.thisDevice.id), local: .mac(),
            isRecording: state.recordingID == meeting.id,
            placement: .init(planner: state.placements[meeting.id]),
            queuedMode: state.processingQueue.first { $0.meetingID == meeting.id }?.mode,
            isPlaying: state.playback.meetingID == meeting.id && state.playback.isPlaying)
        return ConversationStatusPresentation.row(state.processingStatus(for: meeting), meeting: meeting, inputs: inputs, now: now)
    }
}

/// The list's subtitle, redrawn by a download's progress and a summary's countdown on their own (what `text` reads
/// redraws only it): a countdown's seconds once a second.
private struct ListSubtitle: ViewModifier {
    let placements: SummaryPlacements
    let text: (Date) -> String

    func body(content: Content) -> some View {
        let counting = placements.planners.values.contains { $0.deadline != nil }
        TimelineView(.periodic(from: .now, by: counting ? 1 : 3_600)) { context in
            content.navigationSubtitle(text(context.date))
        }
    }
}

// MARK: - Dragging

/// A row travels as its conversation (`ConversationTransfer`): onto a place in the sidebar, or out of Daybook as
/// its Markdown. Each row is a drag source of its own, the path List rows have always taken; a place the row is
/// dropped on files the whole selection when the row is part of it (`ConversationDrop`).
private struct RowDrag: ViewModifier {
    let meeting: Meeting

    func body(content: Content) -> some View {
        content.draggable(ConversationTransfer(meeting))
    }
}

/// What a drop on a sidebar place files.
enum ConversationDrop {
    /// The conversations dropped; and when one of them is part of a selection of several, the whole selection, as
    /// Finder takes every selected file along. In the library's order.
    static func filed(_ dropped: [UUID], selection: Set<UUID>, in meetings: [Meeting]) -> [UUID] {
        let carried = selection.count > 1 && dropped.contains(where: selection.contains) ? selection.union(dropped) : Set(dropped)
        return meetings.map(\.id).filter(carried.contains)
    }
}

// MARK: - Search

/// Search results: the library's matches, then matches in saved live captions the text search didn't find.
private struct SearchResults: View {
    @Bindable var state: AppState
    @Binding var captionHits: [LibraryCaptionSearch.Hit]

    private struct CaptionQuery: Equatable {
        var text: String
        var tokens: [SearchToken]
        var scope: SearchScope
        var revision: Int
    }

    var body: some View {
        let hits = state.searchHits
        let byID = Dictionary(state.meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        List(selection: Binding(get: { state.selectedID }, set: { id in open(id, in: hits) })) {
            Picker("Search in", selection: $state.searchScope) {
                Text("All").tag(SearchScope.all)
                Text("Work").tag(SearchScope.work)
                Text("Personal").tag(SearchScope.personal)
                if case .folder(let id) = state.place, let folder = state.folders.first(where: { $0.id == id }) {
                    Text(folder.name).tag(SearchScope.folder(id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Space.s3)
            .selectionDisabled()
            .listRowSeparator(.hidden)
            // The control's edges line up with the result rows' highlight.
            .listRowInsets(EdgeInsets())
            .padding(.horizontal, -6.5)
            ForEach(hits) { hit in
                if let meeting = byID[hit.meetingID] {
                    SearchResultRowView(meeting: meeting, hit: hit).tag(hit.meetingID).listRowSeparator(.hidden)
                }
            }
            ForEach(captionHits) { hit in
                CaptionHitRowView(meeting: hit.meeting, segment: hit.segment, query: state.search)
                    .tag(hit.meeting.id)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .softTopScrollEdge()
        .overlay { if hits.isEmpty && captionHits.isEmpty { ContentUnavailableView.search(text: state.search) } }
        .task(id: CaptionQuery(text: state.search, tokens: state.searchTokens, scope: state.searchScope, revision: state.libraryRevision)) {
            // The conversations the search could list (its scope and tokens), less those the text search found.
            let scoped = Set(LibrarySearch.hits(in: state.meetings, text: "", tokens: state.searchTokens, scope: state.searchScope).map(\.meetingID))
            let found = await LibraryCaptionSearch.hits(in: state.meetings.filter { scoped.contains($0.id) }, query: state.search,
                                                        excluding: Set(hits.map(\.meetingID)), libraryRoot: state.library.rootURL)
            guard !Task.isCancelled else { return }
            captionHits = found
        }
    }

    /// Opens a result at what it found: a transcript passage, the notes, or the page.
    private func open(_ id: UUID?, in hits: [SearchHit]) {
        state.multiSelection = []
        state.selectedID = id
        if let caption = captionHits.first(where: { $0.meeting.id == id }) {
            // Saved captions read on the transcript's page.
            state.pageMode = .transcript
            state.pageScrollTarget = caption.segment.id
            return
        }
        guard let hit = hits.first(where: { $0.meetingID == id }) else { return }
        if hit.field == .transcript, let segment = hit.segmentID {
            state.pageMode = .transcript
            state.pageScrollTarget = segment
        } else {
            state.pageMode = .summary
            if hit.field == .notes { state.pageScrollTarget = PageAnchor.notes }
        }
    }
}

// MARK: - The Trash

/// The Trash: what was moved there, newest first, each with Restore; the page beside it shows the one selected,
/// read only (`TrashDetail`).
private struct MacTrashList: View {
    @Bindable var state: AppState
    @State private var trashed: [Meeting] = []
    @State private var loaded = false

    var body: some View {
        List(selection: $state.selectedID) {
            ForEach(trashed) { meeting in
                TrashRowView(meeting: meeting) { MacTrash.restore([meeting.id], state: state) }
                    .tag(meeting.id)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .softTopScrollEdge()
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button { MacTrash.restore(Array(ids), state: state) } label: {
                Label(TrashWords.restore, systemImage: TrashWords.restoreSymbol)
            }
        }
        // ⌘⌫ puts the selected one back, as Put Back does in Finder's Trash.
        .onKeyPress(.delete, phases: .down) { press in
            guard press.modifiers.contains(.command), let id = state.selectedID, trashed.contains(where: { $0.id == id }) else { return .ignored }
            MacTrash.restore([id], state: state)
            return .handled
        }
        .overlay {
            if loaded && trashed.isEmpty, let words = LibraryWords.emptyPlace(.trash, libraryIsEmpty: state.meetings.isEmpty, platform: .mac) {
                LibraryEmptyPlaceView(words)
            }
        }
        // Moving to the Trash and restoring change the library's conversations, so its revision.
        .task(id: state.libraryRevision) {
            trashed = await state.library.trashedMeetings()
            loaded = true
            if !trashed.contains(where: { $0.id == state.selectedID }) { state.selectedID = trashed.first?.id }
        }
    }
}

/// The page beside the Trash: the selected conversation, read only, with Restore.
struct TrashDetail: View {
    let state: AppState
    @State private var meeting: Meeting?

    var body: some View {
        ZStack {
            if let meeting {
                TrashedConversationPage(meeting: meeting) { MacTrash.restore([meeting.id], state: state) }
            } else {
                DaybookStyle.paper
            }
        }
        .task(id: [state.selectedID, state.libraryRevision] as [AnyHashable?]) {
            guard let id = state.selectedID else { meeting = nil; return }
            meeting = await state.library.trashedMeeting(id)
        }
    }
}

@MainActor
enum MacTrash {
    /// Puts conversations back from the Trash, each saying so with Show, which opens it.
    static func restore(_ ids: [UUID], state: AppState) {
        Task {
            for id in ids {
                do {
                    let meeting = try await state.library.restoreFromTrash(id)
                    state.post(LibraryWords.restored(meeting), action: LibraryNoticeAction(title: "Show") {
                        state.place = .section(.all)
                        state.multiSelection = []
                        state.selectedID = meeting.id
                    })
                } catch {
                    state.report("Couldn’t Restore", "Try again.", error)
                }
            }
        }
    }
}

// MARK: - Actions

/// Actions for one or more selected rows, from `ConversationActions`, in its one order: Share first, then what it
/// lists; what doesn't apply now is dimmed. Filing can be undone.
private struct RowMenu: View {
    let state: AppState
    let ids: [UUID]
    let undoManager: UndoManager?
    let tag: ([UUID]) -> Void

    var body: some View {
        let meetings = state.meetings.filter { ids.contains($0.id) }
        if let only = meetings.first, meetings.count == 1 {
            ShareLink(item: ConversationShareItem(only), preview: SharePreview(ConversationRowView.title(only))) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            ConversationActionMenuItems(ConversationActions.actions(for: only, context: MacActions.context(state, only)), platform: .mac,
                                        perform: { MacActions.perform($0, on: [only.id], state: state, undoManager: undoManager, tag: tag) },
                                        custom: { MacActions.custom($0, ids: [only.id], state: state, undoManager: undoManager) })
        } else if !meetings.isEmpty {
            ConversationActionMenuItems(ConversationActions.batch(ids, in: state.meetings, context: .init(platform: .mac)), platform: .mac,
                                        perform: { MacActions.perform($0, on: ids, state: state, undoManager: undoManager, tag: tag) },
                                        custom: { MacActions.custom($0, ids: ids, state: state, undoManager: undoManager) })
        }
    }
}

/// Several conversations selected, on the page: what can be done to all of them, from `ConversationActions.batch`
/// (Summarize Again, Move to Folder, Tags…, Work or Personal, the Trash), as buttons.
struct BatchActionButtons: View {
    let state: AppState
    let ids: [UUID]
    @State private var tagging: ConversationIDs?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let groups = ConversationActions.batch(ids, in: state.meetings, context: .init(platform: .mac))
        let actions = groups.flatMap(\.actions)
        VStack(spacing: Space.s3) {
            HStack {
                ForEach(actions.filter { $0.role != .destructive }) { action in
                    if let custom = MacActions.custom(action, ids: ids, state: state, undoManager: undoManager) {
                        custom.fixedSize()
                    } else {
                        Button(action.title) { perform(action.id) }.disabled(!action.isAvailable)
                    }
                }
            }
            // Words alone, as the buttons beside it.
            .labelStyle(.titleOnly)
            // Red is reserved for recording; destructive text takes the error ink.
            ForEach(actions.filter { $0.role == .destructive }) { action in
                Button(action.title, role: .destructive) { perform(action.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.error)
                    .disabled(!action.isAvailable)
            }
        }
        .sheet(item: $tagging) { request in
            ConversationTagsChooser(library: state.library, ids: request.ids) { tagging = nil }
        }
    }

    private func perform(_ id: ConversationAction.ID) {
        MacActions.perform(id, on: ids, state: state, undoManager: undoManager) { tagging = ConversationIDs(ids: $0) }
    }
}

/// What the Mac does for each of `ConversationActions`.
@MainActor
enum MacActions {
    /// What the Mac knows about a conversation for its actions: recording here, or being processed here.
    static func context(_ state: AppState, _ meeting: Meeting) -> ConversationActions.Context {
        let recording = state.recordingID == meeting.id && (state.isRecording || state.isStartingRecording || state.isStoppingRecording)
        return ConversationActions.Context(platform: .mac, isRecording: recording, isProcessingHere: state.processingID == meeting.id,
                                           status: state.processingStatus(for: meeting))
    }

    static func perform(_ id: ConversationAction.ID, on ids: [UUID], state: AppState, undoManager: UndoManager?, tag: ([UUID]) -> Void) {
        let meetings = state.meetings.filter { ids.contains($0.id) }
        guard let first = meetings.first else { return }
        switch id {
        case .copySummary: state.copySummary(first.id)
        case .exportMarkdown: state.export(first.id)
        case .exportJSON: state.export(first.id, json: true)
        case .showFloatingNotes: state.showNotes(for: first.id)
        case .addPhotos: state.chooseAddPhoto(to: first.id)
        case .addRecordingFromFile: state.chooseImport(attachTo: first.id)
        case .process(let mode):
            for meeting in meetings where mode != .summaryOnly || !meeting.unifiedTranscript.isEmpty { state.enqueue(meeting.id, mode: mode) }
        case .versionHistory:
            state.selectedID = first.id
            state.activeSheet = .versionHistory
        case .rename:
            state.selectedID = first.id
            state.focusTitle(first.id)
        case .tags: tag(meetings.map(\.id))
        case .moveTo(let placement): state.library.setPlacement(meetings.map(\.id), placement, undoManager: undoManager)
        case .moveToFolder: break // A menu of the folders (`custom`).
        case .showInFinder: state.showInFinder(first.id)
        case .moveToTrash: state.trashRequestIDs = meetings.map(\.id)
        case .export, .shareAudio, .addRecording, .reprocess, .takePhoto:
            break // Menus, or the iPhone's.
        case .play, .adjustTiming, .showOriginalTranscript, .moveToNewConversation, .removeRecording:
            break // A recording's, in the inspector.
        }
    }

    /// The actions the Mac draws its own way: Move to Folder lists the folders, and Add Recording each recorder too.
    static func custom(_ action: ConversationAction, ids: [UUID], state: AppState, undoManager: UndoManager?) -> AnyView? {
        switch action.id {
        case .moveToFolder:
            return AnyView(Menu {
                Button("None") { state.library.moveToFolder(ids, nil, undoManager: undoManager) }
                if !state.folders.isEmpty { Divider() }
                ForEach(state.folders) { folder in
                    Button(folder.name) { state.library.moveToFolder(ids, folder.id, undoManager: undoManager) }
                }
                Divider()
                Button("New Folder") { state.requestNewFolder(moving: ids) }
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
            .disabled(!action.isAvailable))
        case .addRecording:
            guard let id = ids.first else { return nil }
            return AnyView(Menu {
                Button("From a File…") { state.chooseImport(attachTo: id) }
                AddRecordingFromDeviceItems(state: state)
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
            .disabled(!action.isAvailable))
        default:
            return nil
        }
    }
}

// MARK: - Grouping and dates

// `DateGroup`, `RowDate`, and `RowPreview` live in DaybookKit, shared with the iPhone.

// MARK: - Sync, notices, and drop targets

/// One quiet line while sync needs the person, in the sentence Settings › Library says it with, and Open Sync
/// Settings….
private struct SyncAttention: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings

    private var text: String? {
        #if DEBUG
        // `--sync-demo <state>`: the list says what Settings › Library shows for it.
        if let demo = SyncAttentionDemo.status { return LibraryWords.syncAttention(demo, hasSynced: true) }
        #endif
        return LibraryWords.syncAttention(state.sync.status, hasSynced: state.sync.lastSync != nil)
    }

    var body: some View {
        if let text {
            LibrarySyncLine(text) {
                LaunchOptions.defaults.set(SettingsPane.library.rawValue, forKey: "settingsPane")
                openSettings()
                NSApp.activate()
            }
            .padding(10)
            .quietBox()
            .padding(.horizontal, 10).padding(.top, 6)
            .daybookTransition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

#if DEBUG
/// Debug only: `--sync-demo paused|account|signed-out|drive-off|waiting|folder-missing|folder-lost` puts the sync
/// state Settings › Library shows for it into the list's line too, for snapshots, without iCloud.
enum SyncAttentionDemo {
    static let status: SyncStatus? = {
        switch LaunchOptions.value(after: "--sync-demo") {
        case "paused"?: return .failure(details: "The operation couldn’t be completed. No space left on device.")
        case "account"?: return .accountChanged
        case "signed-out"?: return .signedOut
        case "drive-off"?: return .iCloudDriveOff
        case "waiting"?, "waiting-many"?: return .waitingForKey
        case "folder-missing"?: return .previousFolderMissing
        case "folder-lost"?: return .previousFolderAccessLost
        default: return nil
        }
    }()
}
#endif

/// One library-wide notice at the top of the list column, a line for each thing it says, newest last. The line its
/// one action came with ends with it as a text link (Undo, Show, Show in Finder: `AppState.post(_:action:)`).
private struct LibraryNotice: View {
    let state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if state.notice != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Information, not an action: the glyph stays quiet rather than taking the accent.
                Image(systemName: "info.circle.fill").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(state.noticeLines.enumerated()), id: \.offset) { _, line in
                        LibraryNoticeLine(text: line, action: state.noticeAction(on: line)) {
                            withAnimation(Motion.resolved(Motion.fade, reduceMotion: reduceMotion)) { state.performNoticeAction() }
                        }
                    }
                }
                Button { withAnimation(Motion.resolved(Motion.fade, reduceMotion: reduceMotion)) { state.notice = nil } } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
            .padding(10)
            .quietBox()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .daybookTransition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// One of the library notice's lines, ending with its action when it came with one.
private struct LibraryNoticeLine: View {
    let text: String
    let action: LibraryNoticeAction?
    let perform: () -> Void
    var body: some View {
        if let action {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                words
                Button(action.title, action: perform)
                    .buttonStyle(.daybookLink)
                    .font(TypeStyle.status)
                    .fixedSize()
            }
            // Heard as one: the line, then what it offers.
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: action.title, perform)
        } else {
            words
        }
    }

    /// The words take the room the link leaves, which keeps its own at the trailing edge. They wrap in that width;
    /// a fixed vertical size made the window's split view taller than the window once a line wrapped.
    private var words: some View {
        Text(text).font(TypeStyle.status).textSelection(.enabled).lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DropOutline: View {
    let label: String
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DaybookStyle.accent.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DaybookStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                .padding(6)
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 20)).foregroundStyle(DaybookStyle.accent)
                Text(label).font(.headline)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .scaleEffect(shown || reduceMotion ? 1 : 0.98)
        .opacity(shown ? 1 : 0)
        .onAppear { shown = true }
        .motion(.easeOut(duration: 0.15), value: shown)
        .allowsHitTesting(false)
    }
}

private extension View {
    /// A pinned section header blends into the toolbar's soft edge instead of drawing a second rule.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }
}
