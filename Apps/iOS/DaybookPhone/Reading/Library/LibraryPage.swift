import DaybookKit
import DaybookUI
import SwiftUI

/// The library: a place (All, Work, Personal, a folder, or the Trash) as a date-grouped list, or search results.
/// Places are the title's menu; search opens from Search beside Record (or on the status sheet), at the thumb, with
/// tag and speaker suggestions; and Select turns on multi-select for what `ConversationActions.batch` offers. The
/// rows, results, empty places, and the Trash's rows are DaybookUI's, the Mac's too.
///
/// It reads the `LibraryController` directly, which is `@Observable`, as the player is: the list redraws for the
/// conversations, and a row for whether it's playing.
struct LibraryPage: View {
    let library: LibraryController
    let rootURL: URL
    /// Two pages: a tap shows the conversation on the right page instead of opening it; a second tap opens it.
    var twoPage = false
    @Environment(ReadingSession.self) private var session
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.liveCaptionStore) private var captionStore
    /// The status sheet holds Record, Import, and Search while it's up (pocket); leave it room.
    @Environment(\.statusSheetInset) private var statusSheetInset
    @Environment(\.creaseEdge) private var creaseEdge
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSettings = false
    @State private var naming: FolderNaming?
    @State private var folderName = ""
    @State private var deletingFolder: LibraryFolder?
    @State private var captionHits: [LibraryCaptionSearch.Hit] = []

    private enum FolderNaming: Identifiable {
        case new([UUID]), rename(UUID)
        var id: String { switch self { case .new: return "new"; case .rename(let id): return "rename:\(id)" } }
    }

    var body: some View {
        @Bindable var session = session
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // One way into search, at the thumb (Search beside Record, or on the status sheet): the field is there only
            // while search is up, at the thumb above the keyboard, never at rest above the list.
            .modifier(SearchWhilePresented(library: library))
            .toolbar { toolbar }
            // A bar, not an inset: the list's edge effect then runs under Record and the status sheet.
            .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
            .environment(\.editMode, .constant(session.isSelecting ? .active : .inactive))
            .settingsSheet(isPresented: $showingSettings)
            .alert(naming.map { if case .rename = $0 { return "Rename Folder" } else { return "New Folder" } } ?? "",
                   isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("Name", text: $folderName)
                Button("Cancel", role: .cancel) { naming = nil }
                Button(naming.map { if case .rename = $0 { return "Rename" } else { return "Create" } } ?? "Create") { commitFolder() }
            }
            .alert("Delete the folder “\(deletingFolder?.name ?? "")”?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
                Button("Delete Folder", role: .destructive) {
                    if let folder = deletingFolder {
                        library.removeFolder(folder.id, undoManager: undoManager)
                        if session.place == .library(.folder(folder.id)) { session.place = .library(.section(.all)) }
                    }
                    deletingFolder = nil
                }
                Button("Cancel", role: .cancel) { deletingFolder = nil }
            } message: {
                Text(LibraryWords.folderDeletion(conversations: library.meetings.filter { $0.folderID == deletingFolder?.id }.count))
            }
            .onChange(of: session.searchText) { _, text in
                if !text.isEmpty, session.isSelecting { session.isSelecting = false; session.selection = [] }
                // "#launch " typed whole becomes the tag's token, as on the Mac.
                if let token = LibrarySearchSuggestions.promotedTag(in: text, tags: library.allTags) {
                    session.searchTokens.append(token)
                    session.searchText = ""
                }
            }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if session.isSearching {
            results
        } else if session.place == .trash {
            TrashList(library: library)
        } else {
            list
        }
    }

    private var place: LibraryPlace { session.place.libraryPlace ?? .section(.all) }
    private var meetings: [Meeting] { place.meetings(in: library.meetings) }

    private var list: some View {
        let meetings = meetings
        let now = Date()
        return List(selection: selectionBinding) {
            ForEach(DateGroup.groups(for: meetings, now: now)) { group in
                Section {
                    ForEach(group.meetings) { meeting in
                        PhoneConversationRow(library: library, meeting: meeting,
                                             timeLabel: RowDate.format(meeting.date, group: group.title, now: now))
                            .tag(meeting.id)
                            .listRowInsets(.leading, rowInset(.leading))
                            .listRowInsets(.trailing, rowInset(.trailing))
                            .listRowBackground(rowBackground(meeting.id))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipes(meeting, edge: .trailing) }
                            .swipeActions(edge: .leading) { swipes(meeting, edge: .leading) }
                    }
                } header: {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneStyle.Ink.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Hard, so rows don't read through the glass at the thumb; the soft one leaves them legible.
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .paperBackground()
        .contextMenu(forSelectionType: UUID.self) { ids in
            RowMenu(library: library, ids: Array(ids))
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            // On two pages a tap shows it on the right page, and a tap on the one shown opens it.
            if twoPage && session.openID != id { session.select(id) } else { session.open(id) }
        }
        // Through PhoneSync, so a pull joins a pass already running instead of being dropped, and the status follows.
        .refreshable { await model.sync.synchronize(.manual) }
        .overlay { if meetings.isEmpty && library.isLoaded { emptyPlace } }
        .motion(library.isLoaded ? PhoneStyle.Motion.state : .linear(duration: 0), value: meetings.map(\.id))
    }

    /// A row's side inset on two pages: 20 pt, and on the side that meets the Duo's crease, clear of it. Nil, the
    /// list's own, on one page.
    private func rowInset(_ edge: Edge) -> CGFloat? {
        guard twoPage else { return nil }
        return creaseEdge == edge ? PhoneStyle.Page.creaseClearance : Self.pageRowInset
    }

    private static let pageRowInset: CGFloat = 20
    /// How far the shown row's wash reaches past its words.
    private static let washOutset: CGFloat = 10

    /// The one shown on the right page, on two pages: a wash 10 pt outside the row's words on both sides, so it
    /// keeps clear of the crease as they do.
    private func rowBackground(_ id: UUID) -> some View {
        Group {
            if twoPage && !session.isSelecting && session.openID == id {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PhoneStyle.accent.opacity(0.14))
                    .padding(.leading, (rowInset(.leading) ?? Self.pageRowInset) - Self.washOutset)
                    .padding(.trailing, (rowInset(.trailing) ?? Self.pageRowInset) - Self.washOutset)
            } else {
                PhoneStyle.paper
            }
        }
    }

    /// A row's swipes, from its actions: Move to Trash and Move to Folder to the trailing edge, Work or Personal to
    /// the leading.
    @ViewBuilder private func swipes(_ meeting: Meeting, edge: HorizontalEdge) -> some View {
        // Only what can be done now, as the row's menu.
        let groups = ConversationActionMenuItems.shown(PhoneActions.groups(for: [meeting.id], library: library), on: .iPhone)
        if edge == .trailing {
            if let trash = ConversationActionMenuItems.action(.moveToTrash, in: groups) {
                Button(role: .destructive) { session.confirmingTrash = [meeting.id] } label: {
                    Label(ConversationActionMenuItems.shortTitle(trash), systemImage: trash.symbol)
                }
            }
            if let move = ConversationActionMenuItems.action(.moveToFolder, in: groups) {
                Button { session.sheet = .move([meeting.id]) } label: {
                    Label(ConversationActionMenuItems.shortTitle(move), systemImage: move.symbol)
                }
                .tint(PhoneStyle.prominentFill)
            }
        } else if let filing = ConversationActionMenuItems.action(.moveTo(.work), in: groups)
                    ?? ConversationActionMenuItems.action(.moveTo(.personal), in: groups),
                  case .moveTo(let placement) = filing.id {
            Button { library.setPlacement([meeting.id], placement, undoManager: undoManager) } label: {
                Label(ConversationActionMenuItems.shortTitle(filing), systemImage: filing.symbol)
            }
            .tint(Color(uiColor: .systemGray))
        }
    }

    /// Select mode edits the set; otherwise the list reflects the open conversation (on two pages).
    private var selectionBinding: Binding<Set<UUID>> {
        Binding(get: {
            session.isSelecting ? session.selection : []
        }, set: { ids in
            if session.isSelecting { session.selection = ids }
        })
    }

    private struct CaptionQuery: Equatable {
        var text: String
        var tokens: [SearchToken]
        var scope: SearchScope
        var revision: Int
    }

    private var results: some View {
        let hits = LibrarySearch.hits(in: library.meetings, text: session.searchText, tokens: session.searchTokens, scope: session.searchScope)
        return List {
            ForEach(hits) { hit in
                if let meeting = library.meetings.first(where: { $0.id == hit.meetingID }) {
                    Button { session.open(hit) } label: { SearchResultRowView(meeting: meeting, hit: hit) }
                        .buttonStyle(.plain)
                        .listRowBackground(PhoneStyle.paper)
                }
            }
            // Saved live captions of conversations the text search didn't find, labelled as such.
            ForEach(captionHits) { hit in
                Button {
                    session.open(hit.meeting.id, mode: .transcript)
                    session.showCaption(hit.segment.id)
                } label: { CaptionHitRowView(meeting: hit.meeting, segment: hit.segment, query: session.searchText) }
                    .buttonStyle(.plain)
                    .listRowBackground(PhoneStyle.paper)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .paperBackground()
        .overlay { if hits.isEmpty && captionHits.isEmpty { ContentUnavailableView.search(text: session.searchText) } }
        .task(id: CaptionQuery(text: session.searchText, tokens: session.searchTokens, scope: session.searchScope, revision: library.revision)) {
            let scoped = Set(LibrarySearch.hits(in: library.meetings, text: "", tokens: session.searchTokens, scope: session.searchScope).map(\.meetingID))
            let found = await LibraryCaptionSearch.hits(in: library.meetings.filter { scoped.contains($0.id) }, query: session.searchText,
                                                        excluding: Set(hits.map(\.meetingID)), libraryRoot: library.rootURL)
            guard !Task.isCancelled else { return }
            captionHits = found
        }
    }

    /// A place with nothing in it, in the Mac's words; an empty library that's still arriving from iCloud says so.
    @ViewBuilder private var emptyPlace: some View {
        let sync = model.sync
        if LibraryWords.isGettingConversations(libraryIsEmpty: library.meetings.isEmpty, checking: sync.connection == .checking && sync.controller != nil,
                                               connected: sync.isConnected, lastSync: sync.controller?.lastSync, hasMoreWork: sync.hasMoreWork) {
            GettingConversationsView()
        } else if let words = LibraryWords.emptyPlace(place, libraryIsEmpty: library.meetings.isEmpty, platform: .iPhone) {
            LibraryEmptyPlaceView(words)
        }
    }

    // MARK: Chrome

    private var title: String {
        if session.isSelecting { return session.selection.isEmpty ? "Select Conversations" : "\(session.selection.count) Selected" }
        switch session.place {
        case .trash: return LibraryWords.trash
        case .library(.section(let section)): return section.rawValue
        case .library(.folder(let id)): return library.folders.first { $0.id == id }?.name ?? "Folder"
        case .library(.device): return "Device"
        case .library(.trash): return LibraryWords.trash
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !session.isSelecting {
            ToolbarTitleMenu {
                PlacesMenu(library: library, newFolder: { naming = .new([]); folderName = "" },
                           renameFolder: { id in naming = .rename(id); folderName = library.folders.first { $0.id == id }?.name ?? "" },
                           deleteFolder: { id in deletingFolder = library.folders.first { $0.id == id } })
            }
        }
        if session.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let all = Set(meetings.map(\.id))
                Button(session.selection == all && !all.isEmpty ? "Deselect All" : "Select All") {
                    session.selection = session.selection == all ? [] : all
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { withAnimation(PhoneStyle.Motion.resolved(PhoneStyle.Motion.state, reduceMotion: reduceMotion)) { session.isSelecting = false; session.selection = [] } }
                    .fontWeight(.semibold)
            }
        } else {
            // Only what works here: no New Note in the Trash, no Select with nothing to select. Glyphs in the title's
            // ink, as the system's back chevron; teal is for what confirms.
            if session.place != .trash {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: newNote) { Label("New Note", systemImage: "square.and.pencil") }
                        .tint(PhoneStyle.Ink.title)
                }
                if !meetings.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { withAnimation(PhoneStyle.Motion.resolved(PhoneStyle.Motion.state, reduceMotion: reduceMotion)) { session.isSelecting = true; session.selection = [] } } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .tint(PhoneStyle.Ink.title)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .tint(PhoneStyle.Ink.title)
            }
        }
    }

    /// Record at the thumb, a mini player while something plays, or the selection's actions. On the Duo's left
    /// page they keep clear of the crease.
    @ViewBuilder private var bottomBar: some View {
        if session.isSelecting {
            SelectionBar(library: library, ids: Array(session.selection))
                .padding(.leading, barInset(.leading))
                .padding(.trailing, barInset(.trailing))
                .padding(.bottom, PhoneStyle.Space.s2)
                .daybookTransition(.move(edge: .bottom).combined(with: .opacity))
        } else if !session.isSearchPresented {
            VStack(spacing: PhoneStyle.Space.s2) {
                if let id = session.player.meetingID, !(twoPage && session.openID == id), let meeting = library.meeting(id) {
                    MiniPlayer(player: session.player, meeting: meeting) { twoPage ? session.select(id) : session.open(id) }
                }
                if let statusSheetInset {
                    Color.clear.frame(height: statusSheetInset).accessibilityHidden(true)
                } else if session.place != .trash {
                    // One row at the thumb: Record, Import, and Search, the same size and spacing as on
                    // the status sheet's row.
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
            .padding(.leading, barInset(.leading))
            .padding(.trailing, barInset(.trailing))
            .padding(.bottom, PhoneStyle.Space.s2)
        }
    }

    /// The bar's side padding: 16 pt, and on the side that meets the Duo's crease, clear of it.
    private func barInset(_ edge: Edge) -> CGFloat {
        creaseEdge == edge ? PhoneStyle.Page.creaseClearance : PhoneStyle.Space.s4
    }

    // MARK: Actions

    private func newNote() {
        session.newNote(in: library)
    }

    private func commitFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { naming = nil }
        guard !name.isEmpty, let naming else { return }
        switch naming {
        case .new(let ids):
            let id = library.createFolder(named: name, moving: ids, undoManager: undoManager)
            session.place = .library(.folder(id))
        case .rename(let id):
            library.renameFolder(id, to: name, undoManager: undoManager)
        }
    }
}

/// The search field, only while search is up: Search beside Record, or on the status sheet, opens it, and the system
/// keeps it at the thumb above the keyboard with the scopes over the results. It's attached to the page's
/// background, so opening and closing it never rebuilds the list or loses its place.
private struct SearchWhilePresented: ViewModifier {
    let library: LibraryController
    @Environment(ReadingSession.self) private var session

    func body(content: Content) -> some View {
        @Bindable var session = session
        content.background {
            if session.isSearchPresented || session.isSearching {
                Color.clear
                    .searchable(text: $session.searchText, tokens: $session.searchTokens,
                                suggestedTokens: .constant(LibrarySearchSuggestions.tokens(for: session.searchText, tags: library.allTags,
                                                                                          meetings: library.meetings, chosen: session.searchTokens)),
                                isPresented: $session.isSearchPresented, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: LibraryWords.searchPrompt) { token in
                        Label(token.text, systemImage: token.symbol)
                    }
                    .searchScopes($session.searchScope, activation: .onSearchPresentation) {
                        Text("All").tag(SearchScope.all)
                        Text("Work").tag(SearchScope.work)
                        Text("Personal").tag(SearchScope.personal)
                        if case .library(.folder(let id)) = session.place, let folder = library.folders.first(where: { $0.id == id }) {
                            Text(folder.name).tag(SearchScope.folder(id))
                        }
                    }
            }
        }
    }
}

/// The title's menu: places, folders, and the Trash.
private struct PlacesMenu: View {
    let library: LibraryController
    let newFolder: () -> Void
    let renameFolder: (UUID) -> Void
    let deleteFolder: (UUID) -> Void
    @Environment(ReadingSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Picker("Place", selection: $session.place) {
            ForEach(LibrarySection.allCases) { section in
                Label(section.rawValue, systemImage: section.systemImage).tag(ReadingPlace.library(.section(section)))
            }
        }
        .pickerStyle(.inline)
        Section("Folders") {
            Picker("Folder", selection: $session.place) {
                ForEach(library.folders) { folder in
                    Label(folder.name, systemImage: "folder").tag(ReadingPlace.library(.folder(folder.id)))
                }
            }
            .pickerStyle(.inline)
            Button(action: newFolder) { Label("New Folder…", systemImage: "folder.badge.plus") }
            if case .library(.folder(let id)) = session.place {
                Button { renameFolder(id) } label: { Label("Rename Folder…", systemImage: "pencil") }
                Button(role: .destructive) { deleteFolder(id) } label: { Label("Delete Folder…", systemImage: "folder.badge.minus") }
            }
        }
        Section {
            Picker(LibraryWords.trash, selection: $session.place) {
                Label(LibraryWords.trash, systemImage: "trash").tag(ReadingPlace.trash)
            }
            .pickerStyle(.inline)
        }
    }
}

/// A row's menu, or the selection's: Open first, then what `ConversationActions` lists for this iPhone, without
/// what doesn't apply now.
struct RowMenu: View {
    let library: LibraryController
    let ids: [UUID]
    @Environment(ReadingSession.self) private var session
    @Environment(\.summaryPlacement) private var placement
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let meetings = library.meetings.filter { ids.contains($0.id) }
        if let only = meetings.first, meetings.count == 1 {
            Button { session.open(only.id) } label: { Label("Open", systemImage: "doc.text") }
            if !only.unifiedTranscript.isEmpty {
                Button { session.open(only.id, mode: .transcript) } label: { Label("Open Transcript", systemImage: "text.quote") }
            }
            Divider()
        }
        if !meetings.isEmpty {
            ConversationActionMenuItems(PhoneActions.groups(for: ids, library: library), platform: .iPhone,
                                        perform: { PhoneActions.perform($0, on: ids, library: library, session: session,
                                                                        placement: placement, undoManager: undoManager) },
                                        custom: { PhoneActions.custom($0, ids: ids, library: library) })
        }
    }
}

/// What this iPhone does for each of `ConversationActions`.
@MainActor
enum PhoneActions {
    /// The actions for one conversation, or a selection's.
    static func groups(for ids: [UUID], library: LibraryController) -> [ConversationActionGroup] {
        let selected = library.meetings.filter { ids.contains($0.id) }
        guard let only = selected.first, selected.count == 1 else {
            return ConversationActions.batch(ids, in: library.meetings, context: .init(platform: .iPhone))
        }
        return ConversationActions.actions(for: only, context: .init(platform: .iPhone, status: ProcessingStatus.phone(only),
                                                                      canTakePhoto: CameraPicker.isAvailable))
    }

    static func perform(_ id: ConversationAction.ID, on ids: [UUID], library: LibraryController, session: ReadingSession,
                        placement: PhoneSummaryPlacement?, undoManager: UndoManager?) {
        let meetings = library.meetings.filter { ids.contains($0.id) }
        guard let first = meetings.first else { return }
        switch id {
        case .copySummary: LocalPasteboard.copy(MeetingExport.summaryMarkdown(first))
        case .takePhoto: session.cameraFor = first.id
        case .addPhotos: session.sheet = .importPhotos(first.id)
        case .process(let mode):
            for meeting in meetings where mode != .summaryOnly || !meeting.unifiedTranscript.isEmpty {
                if mode == .summaryOnly { library.summarize(meeting.id, placement: placement) }
                else { library.requestProcessing(meeting.id, mode: mode) }
            }
        case .versionHistory: session.sheet = .history(first.id)
        case .moveToFolder: session.sheet = .move(meetings.map(\.id))
        case .tags: session.sheet = .tags(meetings.map(\.id))
        case .moveTo(let placement): library.setPlacement(meetings.map(\.id), placement, undoManager: undoManager)
        case .moveToTrash: session.confirmingTrash = meetings.map(\.id)
        case .export, .exportMarkdown, .exportJSON, .shareAudio, .reprocess, .addRecording, .addRecordingFromFile:
            break // Menus this iPhone draws itself (`custom`).
        case .showFloatingNotes, .rename, .showInFinder:
            break // The Mac's.
        case .play, .adjustTiming, .showOriginalTranscript, .moveToNewConversation, .removeRecording:
            break // A recording's, in Info.
        }
    }

    /// Share and Reprocess, through the share sheet and the requests this iPhone writes; Add Recording isn't offered
    /// from a row.
    static func custom(_ action: ConversationAction, ids: [UUID], library: LibraryController) -> AnyView? {
        guard ids.count == 1, let meeting = library.meeting(ids[0]) else { return nil }
        switch action.id {
        case .export: return AnyView(ExportMenu(meeting: meeting))
        case .reprocess: return AnyView(ReprocessMenu(library: library, meeting: meeting))
        case .addRecording: return AnyView(EmptyView())
        default: return nil
        }
    }
}

/// The selection's actions at the bottom, where the thumb is: what `ConversationActions.batch` offers, each a glyph
/// over a word on one baseline.
private struct SelectionBar: View {
    let library: LibraryController
    let ids: [UUID]
    @Environment(ReadingSession.self) private var session
    @Environment(\.summaryPlacement) private var placement
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let groups = ConversationActions.batch(ids, in: library.meetings, context: .init(platform: .iPhone))
        let actions = ConversationActionMenuItems.shown(groups, on: .iPhone).flatMap(\.actions)
        HStack(spacing: 0) {
            if actions.isEmpty {
                // Nothing selected yet: the same bar, waiting.
                ForEach(Self.placeholders, id: \.0) { title, symbol in item(title, symbol, role: nil) {} }
            } else {
                ForEach(actions) { action in
                    item(ConversationActionMenuItems.shortTitle(action), action.symbol, role: action.role == .destructive ? .destructive : nil) {
                        PhoneActions.perform(action.id, on: ids, library: library, session: session, placement: placement, undoManager: undoManager)
                        // Done the moment it's chosen (a sheet, or the Trash's question, ends Select itself).
                        if Self.endsSelection(action.id) {
                            session.isSelecting = false
                            session.selection = []
                        }
                    }
                }
            }
        }
        .disabled(ids.isEmpty)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
    }

    /// Whether an action is done the moment it's chosen.
    private static func endsSelection(_ id: ConversationAction.ID) -> Bool {
        switch id {
        case .process, .moveTo: return true
        default: return false
        }
    }

    /// What the bar shows before anything is selected.
    private static let placeholders = [("Move", "folder"), ("Tags", "tag"), ("Personal", "house"), ("Trash", "trash")]

    private func item(_ title: String, _ symbol: String, role: ButtonRole?, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                // Every glyph in the same box, so the words share a baseline whatever the symbol's height.
                Image(systemName: symbol).font(.body.weight(.medium)).frame(height: 24)
                Text(title).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? PhoneStyle.Ink.error : PhoneStyle.Ink.link)
    }
}

/// An empty place in a sheet ("No Changes Yet"): DaybookUI's empty state with the place's glyph.
struct EmptyPlace: View {
    let title: String
    let systemImage: String

    var body: some View {
        LibraryEmptyPlaceView(LibraryWords.EmptyPlace(title: title, symbol: systemImage))
    }
}
