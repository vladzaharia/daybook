import DaybookKit
import SwiftUI

/// The library: a place (All, Work, Personal, a folder, or the Trash) as a date-grouped list, or
/// search results. Places are the title's menu, search is the system search field with tag and
/// speaker suggestions, and Select turns on multi-select for moving, tagging, and the Trash.
///
/// It observes the `LibraryController` directly. (Reading `PhoneLibrary.conversations` through the
/// `@Observable` app model doesn't: the controller is an `ObservableObject`, which Observation
/// doesn't track, so a list drawn before the library loaded stayed empty.)
struct LibraryPage: View {
    @ObservedObject var library: LibraryController
    let rootURL: URL
    /// Two pages: a tap shows the conversation on the right page instead of opening it.
    var twoPage = false
    @Environment(ReadingSession.self) private var session
    @Environment(\.liveCaptionStore) private var captionStore
    /// The status sheet holds Record, Import, and Search while it's up (pocket); leave it room.
    @Environment(\.statusSheetInset) private var statusSheetInset
    @State private var showingSettings = false
    @State private var naming: FolderNaming?
    @State private var folderName = ""
    @State private var confirmingTrash: [UUID] = []
    @State private var trashError: String?

    private enum FolderNaming: Identifiable {
        case new([UUID]), rename(UUID)
        var id: String { switch self { case .new: return "new"; case .rename(let id): return "rename:\(id)" } }
    }

    var body: some View {
        @Bindable var session = session
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // The field opens under the title; the button that opens it sits beside Record, at the thumb.
            .searchable(text: $session.searchText, tokens: $session.searchTokens, suggestedTokens: .constant(suggestedTokens),
                        isPresented: $session.isSearchPresented, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Titles, notes, transcripts") { token in
                switch token {
                case .tag(let tag): Label(tag, systemImage: "tag")
                case .speaker(let name): Label(name, systemImage: "person")
                }
            }
            .searchScopes($session.searchScope, activation: .onSearchPresentation) {
                Text("All").tag(SearchScope.all)
                Text("Work").tag(SearchScope.work)
                Text("Personal").tag(SearchScope.personal)
                if case .library(.folder(let id)) = session.place, let folder = library.folders.first(where: { $0.id == id }) {
                    Text(folder.name).tag(SearchScope.folder(id))
                }
            }
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .environment(\.editMode, .constant(session.isSelecting ? .active : .inactive))
            .sheet(isPresented: $showingSettings) { SettingsScreen() }
            .alert(naming.map { if case .rename = $0 { return "Rename Folder" } else { return "New Folder" } } ?? "",
                   isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("Name", text: $folderName)
                Button("Cancel", role: .cancel) { naming = nil }
                Button(naming.map { if case .rename = $0 { return "Rename" } else { return "Create" } } ?? "Create") { commitFolder() }
            }
            .confirmationDialog(confirmingTrash.count == 1 ? "Move this conversation to the Trash?" : "Move \(confirmingTrash.count) conversations to the Trash?",
                                isPresented: Binding(get: { !confirmingTrash.isEmpty }, set: { if !$0 { confirmingTrash = [] } }),
                                titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { trash(confirmingTrash); confirmingTrash = [] }
            } message: {
                Text(confirmingTrash.count == 1 ? "Its audio and notes go with it." : "Their audio and notes go with them.")
            }
            .alert("Couldn’t Move to Trash", isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: { Text(trashError ?? "") }
            .onChange(of: session.searchText) { _, text in
                if !text.isEmpty, session.isSelecting { session.isSelecting = false; session.selection = [] }
            }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if session.isSearching {
            results
        } else if session.place == .trash {
            TrashList(library: library, rootURL: rootURL)
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
                        ConversationRow(meeting: meeting,
                                        status: StatusPresentation.row(ProcessingStatus(meeting, now: now)),
                                        timeLabel: RowDate.format(meeting.date, group: group.title, now: now),
                                        isPlaying: session.player.meetingID == meeting.id && session.player.isPlaying)
                            .tag(meeting.id)
                            .listRowBackground(rowBackground(meeting.id))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { trash([meeting.id]) } label: { Label("Trash", systemImage: "trash") }
                                Button { session.sheet = .move([meeting.id]) } label: { Label("Move", systemImage: "folder") }
                                    .tint(PhoneStyle.prominentFill)
                            }
                            .swipeActions(edge: .leading) {
                                let personal = meeting.effectivePlacement == .personal
                                Button { library.setPlacement([meeting.id], personal ? .work : .personal) } label: {
                                    Label(personal ? "Work" : "Personal", systemImage: personal ? "briefcase" : "house")
                                }
                                .tint(Color(uiColor: .systemGray))
                            }
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
        .paperBackground()
        .contextMenu(forSelectionType: UUID.self) { ids in
            RowMenu(library: library, ids: Array(ids), trash: { confirmingTrash = $0 })
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            twoPage ? session.select(id) : session.open(id)
        }
        .refreshable { _ = await library.synchronize() }
        .overlay { if meetings.isEmpty && library.isLoaded { emptyPlace } }
        .motion(library.isLoaded ? PhoneStyle.Motion.state : .linear(duration: 0), value: meetings.map(\.id))
    }

    private func rowBackground(_ id: UUID) -> some View {
        Group {
            if twoPage && !session.isSelecting && session.openID == id {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PhoneStyle.accent.opacity(0.14)).padding(.horizontal, 6)
            } else {
                PhoneStyle.paper
            }
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

    private var results: some View {
        let hits = LibrarySearch.hits(in: library.meetings, text: session.searchText, tokens: session.searchTokens, scope: session.searchScope)
        // Saved live captions of conversations not transcribed yet, labelled as such.
        let found = Set(hits.map(\.meetingID))
        let scoped = LibrarySearch.hits(in: library.meetings, text: "", tokens: session.searchTokens, scope: session.searchScope).map(\.meetingID)
        let captionHits = SavedCaptions.hits(in: library.meetings.filter { scoped.contains($0.id) && !found.contains($0.id) },
                                             query: session.searchText, store: captionStore)
        return List {
            ForEach(hits) { hit in
                if let meeting = library.meetings.first(where: { $0.id == hit.meetingID }) {
                    Button { session.open(hit) } label: { SearchResultRow(meeting: meeting, hit: hit) }
                        .buttonStyle(.plain)
                        .listRowBackground(PhoneStyle.paper)
                }
            }
            ForEach(captionHits, id: \.meeting.id) { hit in
                Button {
                    session.open(hit.meeting.id, mode: .transcript)
                    session.showCaption(hit.segment.id)
                } label: { CaptionSearchRow(meeting: hit.meeting, segment: hit.segment, query: session.searchText) }
                    .buttonStyle(.plain)
                    .listRowBackground(PhoneStyle.paper)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .paperBackground()
        .overlay { if hits.isEmpty && captionHits.isEmpty { ContentUnavailableView.search(text: session.searchText) } }
    }

    @ViewBuilder private var emptyPlace: some View {
        switch place {
        case .section(.all):
            VStack(spacing: PhoneStyle.Space.s3) {
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(PhoneStyle.brandGradient)
                Text("No conversations yet").font(PhoneStyle.Typeface.title(22)).foregroundStyle(PhoneStyle.Ink.title)
                Text("Conversations you record or import appear here.")
                    .font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary).multilineTextAlignment(.center)
            }
            .padding(PhoneStyle.Space.s6)
            .accessibilityElement(children: .combine)
        case .section(.work):
            ContentUnavailableView("No Work Conversations", systemImage: "briefcase",
                                   description: Text("Conversations about work appear here automatically."))
        case .section(.personal):
            ContentUnavailableView("No Personal Conversations", systemImage: "house",
                                   description: Text("Personal conversations appear here automatically."))
        case .folder(let id):
            ContentUnavailableView("Nothing in \(library.folders.first { $0.id == id }?.name ?? "This Folder")", systemImage: "folder",
                                   description: Text("Swipe a conversation and choose Move."))
        case .device:
            Color.clear
        }
    }

    // MARK: Chrome

    private var title: String {
        if session.isSelecting { return session.selection.isEmpty ? "Select Conversations" : "\(session.selection.count) Selected" }
        switch session.place {
        case .trash: return "Trash"
        case .library(.section(let section)): return section.rawValue
        case .library(.folder(let id)): return library.folders.first { $0.id == id }?.name ?? "Folder"
        case .library(.device): return "Device"
        }
    }

    private var suggestedTokens: [SearchToken] {
        let tags = library.allTags.map(SearchToken.tag)
        let speakers = Set(library.meetings.flatMap { $0.speakers.map(\.name) }.filter { !$0.hasPrefix("Speaker ") && $0 != "Me" })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(SearchToken.speaker)
        return (tags + speakers).filter { !session.searchTokens.contains($0) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !session.isSelecting {
            ToolbarTitleMenu {
                PlacesMenu(library: library, newFolder: { naming = .new([]); folderName = "" },
                           renameFolder: { id in naming = .rename(id); folderName = library.folders.first { $0.id == id }?.name ?? "" })
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
                Button("Done") { withAnimation { session.isSelecting = false; session.selection = [] } }
                    .fontWeight(.semibold)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: newNote) { Label("New Note", systemImage: "square.and.pencil") }
                    .disabled(session.place == .trash)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation { session.isSelecting = true; session.selection = [] } } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .disabled(session.place == .trash || meetings.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
    }

    /// Record at the thumb, a mini player while something plays, or the selection's actions.
    @ViewBuilder private var bottomBar: some View {
        if session.isSelecting {
            SelectionBar(library: library, ids: Array(session.selection), trash: { confirmingTrash = $0 })
        } else if !session.isSearchPresented {
            VStack(spacing: PhoneStyle.Space.s2) {
                if let id = session.player.meetingID, !(twoPage && session.openID == id), let meeting = library.meeting(id) {
                    MiniPlayer(player: session.player, meeting: meeting) { twoPage ? session.select(id) : session.open(id) }
                }
                if let statusSheetInset {
                    Color.clear.frame(height: statusSheetInset).accessibilityHidden(true)
                } else if session.place != .trash {
                    // One row at the thumb: Record, and Search beside it.
                    HStack(alignment: .bottom, spacing: PhoneStyle.Space.s2) {
                        RecordStartButton()
                        Button { session.isSearchPresented = true } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.title3.weight(.medium))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .foregroundStyle(PhoneStyle.Ink.title)
                        .accessibilityLabel("Search")
                        .accessibilityHint("Searches titles, notes, transcripts, and summaries")
                    }
                }
            }
            .padding(.horizontal, PhoneStyle.Space.s4)
            .padding(.bottom, PhoneStyle.Space.s2)
        }
    }

    // MARK: Actions

    private func newNote() {
        session.newNote(in: library)
    }

    private func trash(_ ids: [UUID]) {
        Task {
            for id in ids {
                do {
                    if try await library.moveToTrash(id) { session.forget(id) }
                } catch {
                    trashError = error.localizedDescription
                }
            }
            if session.isSelecting { session.isSelecting = false; session.selection = [] }
        }
    }

    private func commitFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { naming = nil }
        guard !name.isEmpty, let naming else { return }
        switch naming {
        case .new(let ids):
            let id = library.createFolder(named: name, moving: ids)
            session.place = .library(.folder(id))
        case .rename(let id):
            library.saveFolder(LibraryFolder(id: id, name: name))
        }
    }
}

/// The title's menu: places, folders, and the Trash.
private struct PlacesMenu: View {
    @ObservedObject var library: LibraryController
    let newFolder: () -> Void
    let renameFolder: (UUID) -> Void
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
                Button(role: .destructive) {
                    library.removeFolder(id)
                    session.place = .library(.section(.all))
                } label: { Label("Delete Folder", systemImage: "folder.badge.minus") }
            }
        }
        Section {
            Picker("Trash", selection: $session.place) {
                Label("Trash", systemImage: "trash").tag(ReadingPlace.trash)
            }
            .pickerStyle(.inline)
        }
    }
}

/// A row's menu, or the selection's. Items that don't apply are hidden.
struct RowMenu: View {
    @ObservedObject var library: LibraryController
    let ids: [UUID]
    let trash: ([UUID]) -> Void
    @Environment(ReadingSession.self) private var session

    private var meetings: [Meeting] { library.meetings.filter { ids.contains($0.id) } }

    var body: some View {
        if let meeting = meetings.first {
            if meetings.count == 1 {
                Button { session.open(meeting.id) } label: { Label("Open", systemImage: "doc.text") }
                if !meeting.unifiedTranscript.isEmpty {
                    Button { session.open(meeting.id, mode: .transcript) } label: { Label("Open Transcript", systemImage: "text.quote") }
                }
            }
            Button { session.sheet = .move(ids) } label: { Label("Move to Folder…", systemImage: "folder") }
            Button { session.sheet = .tags(ids) } label: { Label("Tags…", systemImage: "tag") }
            let personal = meetings.allSatisfy { $0.effectivePlacement == .personal }
            Button { library.setPlacement(ids, personal ? .work : .personal) } label: {
                Label(personal ? "Move to Work" : "Move to Personal", systemImage: personal ? "briefcase" : "house")
            }
            if meetings.count == 1 {
                Divider()
                ReprocessMenu(library: library, meeting: meeting)
                ExportMenu(meeting: meeting)
            }
            Divider()
            Button(role: .destructive) { trash(ids) } label: {
                Label(meetings.count == 1 ? "Move to Trash" : "Move \(meetings.count) to Trash", systemImage: "trash")
            }
        }
    }
}

/// The selection's actions, at the bottom where the thumb is.
private struct SelectionBar: View {
    @ObservedObject var library: LibraryController
    let ids: [UUID]
    let trash: ([UUID]) -> Void
    @Environment(ReadingSession.self) private var session

    var body: some View {
        let personal = !ids.isEmpty && library.meetings.filter { ids.contains($0.id) }.allSatisfy { $0.effectivePlacement == .personal }
        HStack(spacing: 0) {
            item("Move", "folder") { session.sheet = .move(ids) }
            item("Tag", "tag") { session.sheet = .tags(ids) }
            item(personal ? "Work" : "Personal", personal ? "briefcase" : "house") {
                library.setPlacement(ids, personal ? .work : .personal)
            }
            item("Trash", "trash", role: .destructive) { trash(ids) }
        }
        .disabled(ids.isEmpty)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, PhoneStyle.Space.s4)
        .padding(.bottom, PhoneStyle.Space.s2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func item(_ title: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.body.weight(.medium))
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? PhoneStyle.Ink.error : PhoneStyle.Ink.link)
    }
}

