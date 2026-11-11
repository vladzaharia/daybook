import DaybookCaptions
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// The library: a place (All, Work, Personal, a folder, or the Trash) as a date-grouped list, or search results.
/// The same on one page and two (docs/iphone.md, "Scope"): places are the title's menu; More (New Note, Select
/// Conversations, New Folder…, Devices) beside Settings; and at the foot the status sheet stands, Record, Import, and
/// Search at the thumb (`StatusSheetHost` presents it in one column; on two pages this page draws it at its compact
/// size, `StatusSheetFoot`). Search opens from the sheet's Search, its field at the thumb while it's up, with tag and
/// speaker suggestions. Select turns on multi-select for what `ConversationActions.batch` offers. The rows, results,
/// empty places, and the Trash's rows are DaybookUI's, the Mac's too.
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
  @Environment(\.showStatus) private var showStatus
  /// The standing sheet's compact room, while it stands over this page (one column).
  @Environment(\.statusSheetInset) private var statusSheetInset
  @Environment(\.verticalSizeClass) private var heightClass
  @Environment(\.creaseEdge) private var creaseEdge
  @Environment(\.undoManager) private var undoManager
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// What the Personal lock hides and what a Focus leaves out (`PersonalLock`).
  @Environment(PersonalLock.self) private var personalLock: PersonalLock?
  @State private var showingSettings = false
  @State private var naming: FolderNaming?
  @State private var folderName = ""
  @State private var deletingFolder: LibraryFolder?
  @State private var captionHits: [LibraryCaptionSearch.Hit] = []

  private enum FolderNaming: Identifiable {
    case new([UUID])
    case rename(UUID)
    var id: String {
      switch self {
      case .new: return "new"
      case .rename(let id): return "rename:\(id)"
      }
    }
  }

  var body: some View {
    content
    // The list fades hard under the selection's bar and the mini player; under the sheet drawn at the foot, which is
    // its own glass, softly, so what scrolls past its rounded corners blurs away.
    .scrollEdgeEffectStyle(footSheet ? .soft : .hard, for: .bottom)
    .safeAreaBar(edge: .bottom, spacing: 0) { foot }
    .navigationTitle(title)
    .toolbarTitleDisplayMode(.inline)
    // The place's menu stands in for the title, leading in every place, the Trash too (`placesTitle`); selection
    // keeps the system's title, "2 Selected".
    .toolbar(removing: session.isSelecting ? nil : .title)
    // One way into search, at the thumb: the sheet's Search opens it, and its field is there only while it's up.
    .modifier(SearchWhilePresented(library: library))
    .toolbar { topBar }
    .environment(\.editMode, .constant(session.isSelecting ? .active : .inactive))
    .settingsSheet(isPresented: $showingSettings)
    .task { await openRequestedAtLaunch() }
    // A conversation opened from Settings (a recorder's Recent imports) shows once Settings steps aside.
    .onChange(of: session.openID) { _, id in
      if id != nil, showingSettings { showingSettings = false }
    }
    .alert(
      naming.map { if case .rename = $0 { return "Rename Folder" } else { return "New Folder" } }
        ?? "",
      isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
    ) {
      TextField("Name", text: $folderName)
      Button("Cancel", role: .cancel) { naming = nil }
      Button(
        naming.map { if case .rename = $0 { return "Rename" } else { return "Create" } } ?? "Create"
      ) { commitFolder() }
    }
    .alert(
      "Delete the folder “\(deletingFolder?.name ?? "")”?",
      isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })
    ) {
      Button("Delete Folder", role: .destructive) {
        if let folder = deletingFolder {
          library.removeFolder(folder.id, undoManager: undoManager)
          if session.place == .library(.folder(folder.id)) {
            session.place = .library(.section(.all))
          }
        }
        deletingFolder = nil
      }
      Button("Cancel", role: .cancel) { deletingFolder = nil }
    } message: {
      Text(
        LibraryWords.folderDeletion(
          conversations: library.meetings.filter { $0.folderID == deletingFolder?.id }.count))
    }
    .onChange(of: session.searchText) { _, text in
      if !text.isEmpty, session.isSelecting {
        session.isSelecting = false
        session.selection = []
      }
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
    } else if place.isTrash {
      TrashList(library: library, twoPage: twoPage)
    } else {
      list
    }
  }

  private var place: LibraryPlace { session.place.libraryPlace }
  private var meetings: [Meeting] {
    place.meetings(in: library.meetings, showingPersonal: personalLock?.focus.showsPersonal ?? true)
  }

  private var list: some View {
    let meetings = meetings
    let now = Date()
    return List(selection: selectionBinding) {
      ForEach(DateGroup.groups(for: meetings, now: now)) { group in
        Section {
          ForEach(group.meetings) { meeting in
            PhoneConversationRow(
              library: library, meeting: meeting,
              timeLabel: RowDate.format(meeting.date, group: group.title, now: now)
            )
            .tag(meeting.id)
            .pageRowInsets(twoPage: twoPage)
            .listRowBackground(
              PageRowBackground(
                shown: twoPage && !session.isSelecting && session.openID == meeting.id)
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
              swipes(meeting, edge: .trailing)
            }
            .swipeActions(edge: .leading) { swipes(meeting, edge: .leading) }
          }
        } header: {
          Text(group.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .textCase(nil)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
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
    .daybookMotion(
      library.isLoaded ? DaybookMotion.state : .linear(duration: 0), value: meetings.map(\.id))
  }

  /// A row's swipes, from its actions: Move to Trash and Move to Folder to the trailing edge, Work or Personal to
  /// the leading.
  @ViewBuilder private func swipes(_ meeting: Meeting, edge: HorizontalEdge) -> some View {
    // Only what can be done now, as the row's menu. A row the Personal lock hides has none: they'd name it.
    let groups = ConversationActionMenuItems.shown(
      PhoneActions.groups(for: [meeting.id], library: library), on: .iPhone)
    if personalLock?.hides(meeting) == true {
      EmptyView()
    } else if edge == .trailing {
      if let trash = ConversationActionMenuItems.action(.moveToTrash, in: groups) {
        Button(role: .destructive) {
          session.confirmingTrash = [meeting.id]
        } label: {
          Label(ConversationActionMenuItems.shortTitle(trash), systemImage: trash.symbol)
        }
      }
      if let move = ConversationActionMenuItems.action(.moveToFolder, in: groups) {
        Button {
          session.sheet = .move([meeting.id])
        } label: {
          Label(ConversationActionMenuItems.shortTitle(move), systemImage: move.symbol)
        }
        .tint(DaybookPalette.prominentFill)
      }
    } else if let filing = ConversationActionMenuItems.action(.moveTo(.work), in: groups)
      ?? ConversationActionMenuItems.action(.moveTo(.personal), in: groups),
      case .moveTo(let placement) = filing.id
    {
      Button {
        library.setPlacement([meeting.id], placement, undoManager: undoManager)
      } label: {
        Label(ConversationActionMenuItems.shortTitle(filing), systemImage: filing.symbol)
      }
      .tint(Color(uiColor: .systemGray))
    }
  }

  /// Select mode edits the set; otherwise the list reflects the open conversation (on two pages).
  private var selectionBinding: Binding<Set<UUID>> {
    Binding(
      get: {
        session.isSelecting ? session.selection : []
      },
      set: { ids in
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
    @Bindable var session = session
    let hits = LibrarySearch.hits(
      in: personalLock?.listed(library.meetings) ?? library.meetings, text: session.searchText,
      tokens: session.searchTokens,
      scope: session.searchScope)
    return List {
      // The scopes, on one page and on two, as on the Mac.
      // Its rows line up with the list's, clear of the crease on two pages.
      SearchScopePicker(scope: $session.searchScope, folder: viewedFolder)
        .listRowSeparator(.hidden)
        .pageRowInsets(twoPage: twoPage)
        .listRowBackground(DaybookPalette.paper)
      ForEach(hits) { hit in
        if let meeting = library.meetings.first(where: { $0.id == hit.meetingID }) {
          Button {
            session.open(hit)
          } label: {
            SearchResultRowView(meeting: meeting, hit: hit)
          }
          .buttonStyle(.plain)
          .pageRowInsets(twoPage: twoPage)
          .listRowBackground(DaybookPalette.paper)
        }
      }
      // Saved live captions of conversations the text search didn't find, labelled as such.
      ForEach(captionHits) { hit in
        Button {
          session.open(hit.meeting.id, mode: .transcript)
          session.showCaption(hit.segment.id)
        } label: {
          CaptionHitRowView(meeting: hit.meeting, segment: hit.segment, query: session.searchText)
        }
        .buttonStyle(.plain)
        .pageRowInsets(twoPage: twoPage)
        .listRowBackground(DaybookPalette.paper)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .paperBackground()
    .overlay {
      if hits.isEmpty && captionHits.isEmpty {
        ContentUnavailableView.search(text: session.searchText)
      }
    }
    .task(
      id: CaptionQuery(
        text: session.searchText, tokens: session.searchTokens, scope: session.searchScope,
        revision: library.revision)
    ) {
      let candidates = Self.captionCandidates(
        in: personalLock?.listed(library.meetings) ?? library.meetings, tokens: session.searchTokens,
        scope: session.searchScope)
      let found = await LibraryCaptionSearch.hits(
        in: candidates, query: session.searchText,
        excluding: Set(hits.map(\.meetingID)), libraryRoot: library.rootURL)
      guard !Task.isCancelled else { return }
      captionHits = found
    }
  }

  /// The conversations whose saved captions search reads: those the search could list (its scope and tokens). Which
  /// captions still show is the transcript page's own rule (`SavedCaptions.shown`), which the search reads too, so a
  /// caption result always opens at them.
  static func captionCandidates(in meetings: [Meeting], tokens: [SearchToken], scope: SearchScope)
    -> [Meeting]
  {
    let scoped = Set(
      LibrarySearch.hits(in: meetings, text: "", tokens: tokens, scope: scope).map(\.meetingID))
    return meetings.filter { scoped.contains($0.id) }
  }

  /// The folder being viewed, which the scopes offer too.
  private var viewedFolder: LibraryFolder? {
    guard case .folder(let id) = place else { return nil }
    return library.folders.first { $0.id == id }
  }

  /// A place with nothing in it, in the Mac's words; an empty library that's still arriving from iCloud says so.
  @ViewBuilder private var emptyPlace: some View {
    let sync = model.sync
    if LibraryWords.isGettingConversations(
      libraryIsEmpty: library.meetings.isEmpty,
      checking: sync.connection == .checking && sync.controller != nil,
      connected: sync.isConnected, lastSync: sync.controller?.lastSync,
      hasMoreWork: sync.hasMoreWork)
    {
      GettingConversationsView()
    } else if let words = LibraryWords.emptyPlace(
      place, libraryIsEmpty: library.meetings.isEmpty, platform: .iPhone)
    {
      LibraryEmptyPlaceView(words)
    }
  }

  // MARK: Chrome

  private var title: String {
    if session.isSelecting {
      return session.selection.isEmpty
        ? "Select Conversations" : "\(session.selection.count) Selected"
    }
    switch place {
    case .section(let section): return section.rawValue
    case .folder(let id): return library.folders.first { $0.id == id }?.name ?? "Folder"
    case .device: return "Device"
    case .trash: return LibraryWords.trash
    }
  }

  /// The top bar: the place's menu as the title, leading; More and Settings, trailing, each its own glass.
  @ToolbarContentBuilder private var topBar: some ToolbarContent {
    if !session.isSelecting {
      ToolbarItem(placement: .topBarLeading) {
        Menu {
          PlacesMenu(
            library: library,
            newFolder: newFolder,
            renameFolder: { id in
              naming = .rename(id)
              folderName = library.folders.first { $0.id == id }?.name ?? ""
            },
            deleteFolder: { id in deletingFolder = library.folders.first { $0.id == id } })
        } label: {
          PlacesTitle(title: title)
        }
        .accessibilityLabel(title)
        .accessibilityHint("Shows places, folders, and the Trash")
        .accessibilityAddTraits(.isHeader)
      }
      .sharedBackgroundVisibility(.hidden)
    }
    if session.isSelecting {
      ToolbarItem(placement: .topBarLeading) {
        let all = Set(meetings.map(\.id))
        Button(session.selection == all && !all.isEmpty ? "Deselect All" : "Select All") {
          session.selection = session.selection == all ? [] : all
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Done") {
          withAnimation(
            DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion)
          ) {
            session.isSelecting = false
            session.selection = []
          }
        }
        .fontWeight(.semibold)
      }
    } else {
      // Only what works here (`LibraryChrome.more`): no New Note in the Trash, no Select with nothing to select.
      // Glyphs in the title's ink, as the system's back chevron; teal is for what confirms.
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          ForEach(LibraryChrome.more(in: place, isEmpty: meetings.isEmpty), id: \.self) { item in
            Button {
              perform(item)
            } label: {
              Label(item.title, systemImage: item.symbol)
            }
          }
        } label: {
          Label("More", systemImage: "ellipsis")
        }
        .tint(DaybookPalette.Ink.title)
      }
      ToolbarSpacer(.fixed, placement: .topBarTrailing)
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showingSettings = true
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .tint(DaybookPalette.Ink.title)
      }
    }
  }

  /// The standing sheet is drawn at this page's foot (two pages, or one column on its side), not the system's over it.
  private var footSheet: Bool {
    StatusSheetModel.placement(
      twoPages: twoPage, compactHeight: heightClass == .compact, reading: false,
      searching: session.isSearchPresented, selecting: session.isSelecting, inTrash: place.isTrash) == .foot
  }

  /// At the foot: the selection's bar while selecting; else what's playing, then the standing sheet, drawn here at its
  /// compact size (`StatusSheetFoot`), or the room the system's leaves above itself, so the last rows scroll clear.
  @ViewBuilder private var foot: some View {
    if session.isSelecting {
      SelectionBar(library: library, ids: Array(session.selection))
        .padding(.leading, barInset(.leading))
        .padding(.trailing, barInset(.trailing))
        .padding(.bottom, DaybookSpacing.s2)
        .daybookTransition(.move(edge: .bottom).combined(with: .opacity))
    } else if !session.isSearchPresented {
      let playing = session.player.meetingID.flatMap { id in
        twoPage && session.openID == id ? nil : library.meeting(id)
      }
      let footSheet = footSheet
      if playing != nil || footSheet || statusSheetInset != nil {
        VStack(spacing: DaybookSpacing.s2) {
          if let playing {
            MiniPlayer(player: session.player, meeting: playing) {
              twoPage ? session.select(playing.id) : session.open(playing.id)
            }
          }
          if footSheet {
            StatusSheetFoot()
          } else if let statusSheetInset {
            Color.clear.frame(height: statusSheetInset).accessibilityHidden(true)
          }
        }
        .padding(.leading, barInset(.leading))
        .padding(.trailing, barInset(.trailing))
        .padding(.bottom, footSheet || statusSheetInset != nil ? 0 : DaybookSpacing.s2)
      }
    }
  }

  /// The bar's side padding: 16 pt, and on the side that meets the Duo's crease, clear of it.
  private func barInset(_ edge: Edge) -> CGFloat {
    creaseEdge == edge ? ReadingGeometry.creaseClearance : DaybookSpacing.s4
  }

  // MARK: Actions

  private func newNote() {
    session.newNote(in: library)
  }

  private func newFolder() {
    naming = .new([])
    folderName = ""
  }

  private func perform(_ item: LibraryChrome.MoreItem) {
    switch item {
    case .newNote: newNote()
    case .select:
      withAnimation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion)) {
        session.isSelecting = true
        session.selection = []
      }
    case .newFolder: newFolder()
    case .devices: showStatus(StatusRequest())
    }
  }

  /// `--open-settings` (debug): Settings at launch, for screenshots. (`--show-importer` is the sheet's Import's.)
  private func openRequestedAtLaunch() async {
    if model.options.openSettings != nil, !showingSettings {
      try? await Task.sleep(for: .milliseconds(400))
      showingSettings = true
    }
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

/// The search field, only while search is up: the status sheet's Search opens it, and the system keeps it at the thumb
/// above the keyboard, on one page and two. The scopes are the results' first row (`SearchScopePicker`), as on the
/// Mac. It's attached to the page's background, so opening and closing it never rebuilds the list or loses its place,
/// and there's no search button of its own to move when the iPhone turns.
private struct SearchWhilePresented: ViewModifier {
  let library: LibraryController
  @Environment(ReadingSession.self) private var session

  func body(content: Content) -> some View {
    @Bindable var session = session
    content.background {
      if session.isSearchPresented || session.isSearching {
        Color.clear
          .searchable(
            text: $session.searchText, tokens: $session.searchTokens,
            suggestedTokens: .constant(
              LibrarySearchSuggestions.tokens(
                for: session.searchText, tags: library.allTags,
                meetings: library.meetings, chosen: session.searchTokens)),
            isPresented: $session.isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: LibraryWords.searchPrompt
          ) { token in
            Label(token.text, systemImage: token.symbol)
          }
      }
    }
  }
}

/// What the library's chrome offers in a place, on one page and two alike (the open Duo's left page draws the same
/// bar as the 18 Pro, and the same standing sheet at its foot). Plain values, so tests read it.
enum LibraryChrome {
  /// The More menu's items, in order.
  enum MoreItem: Hashable, CaseIterable {
    case newNote, select, newFolder, devices

    var title: String {
      switch self {
      case .newNote: return "New Note"
      case .select: return "Select Conversations"
      case .newFolder: return "New Folder…"
      case .devices: return StatusSheetModel.title
      }
    }

    var symbol: String {
      switch self {
      case .newNote: return "square.and.pencil"
      case .select: return "checkmark.circle"
      case .newFolder: return "folder.badge.plus"
      case .devices: return "macbook.and.iphone"
      }
    }
  }

  /// The top bar, outside selection: the place's menu as the title, More, and Settings. Record, Import, and Search
  /// are the status sheet's, at the foot.
  enum TopItem: Hashable { case titleMenu, more, settings }

  static func topBar(selecting: Bool) -> [TopItem] {
    selecting ? [] : [.titleMenu, .more, .settings]
  }

  /// More: New Note (not in the Trash, which nothing is written into), Select Conversations when there's something to
  /// select (never in the Trash, whose rows restore one at a time), New Folder…, and Devices.
  static func more(in place: LibraryPlace, isEmpty: Bool) -> [MoreItem] {
    (place.isTrash ? [] : [.newNote]) + (place.isTrash || isEmpty ? [] : [.select]) + [.newFolder, .devices]
  }
}

/// The place's name as the bar's title, leading, with the menu's chevron: "All Conversations ⌄", in every place.
/// The system's own title (`.inline`) moves between leading and centred with what the bar holds, and its large inline
/// form neither shows the chevron nor fits a long name beside More and Settings.
private struct PlacesTitle: View {
  let title: String

  var body: some View {
    HStack(spacing: DaybookSpacing.s1 + 2) {
      Text(title)
        .font(.title3.weight(.bold))
        .foregroundStyle(DaybookPalette.Ink.title)
        .lineLimit(1)
      Image(systemName: "chevron.down.circle.fill")
        .font(.subheadline)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DaybookPalette.Ink.secondary)
        .accessibilityHidden(true)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// The title's menu: places, folders, and the Trash. Personal shows the lock while it's locked, and goes while a
/// Focus leaves it out (`PersonalLock`).
private struct PlacesMenu: View {
  let library: LibraryController
  let newFolder: () -> Void
  let renameFolder: (UUID) -> Void
  let deleteFolder: (UUID) -> Void
  @Environment(ReadingSession.self) private var session
  @Environment(PersonalLock.self) private var personalLock: PersonalLock?

  var body: some View {
    @Bindable var session = session
    Picker("Place", selection: $session.place) {
      ForEach(personalLock?.sections ?? LibrarySection.allCases) { section in
        Label(section.rawValue, systemImage: personalLock?.symbol(section) ?? section.systemImage).tag(
          ReadingPlace.library(.section(section)))
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
        Button {
          renameFolder(id)
        } label: {
          Label("Rename Folder…", systemImage: "pencil")
        }
        Button(role: .destructive) {
          deleteFolder(id)
        } label: {
          Label("Delete Folder…", systemImage: "folder.badge.minus")
        }
      }
    }
    Section {
      Picker(LibraryWords.trash, selection: $session.place) {
        Label(LibraryWords.trash, systemImage: "trash").tag(ReadingPlace.library(.trash))
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
  @Environment(\.audioProvider) private var provider
  @Environment(\.summaryPlacement) private var placement
  @Environment(\.undoManager) private var undoManager
  @Environment(PersonalLock.self) private var personalLock: PersonalLock?

  var body: some View {
    let meetings = library.meetings.filter { ids.contains($0.id) }
    if let only = meetings.first, meetings.count == 1, personalLock?.hides(only) == true {
      // Locked: nothing that shows or shares it until the person unlocks.
      Button {
        session.open(only.id)
      } label: {
        Label(PersonalLockWords.unlock, systemImage: PersonalLockWords.symbol)
      }
    } else if let only = meetings.first, meetings.count == 1 {
      Button {
        session.open(only.id)
      } label: {
        Label("Open", systemImage: "doc.text")
      }
      if !only.unifiedTranscript.isEmpty {
        Button {
          session.open(only.id, mode: .transcript)
        } label: {
          Label("Open Transcript", systemImage: "text.quote")
        }
      }
      Divider()
    }
    if !meetings.isEmpty {
      ConversationActionMenuItems(PhoneActions.groups(for: ids, library: library), platform: .iPhone) {
        PhoneActions.perform(
          $0, on: ids, library: library, session: session, provider: provider,
          placement: placement, undoManager: undoManager)
      }
    }
  }
}

/// What this iPhone does for each of `ConversationActions`, from a row's menu, the selection bar, and the
/// conversation's More alike: the library's actions through DaybookUI's `ConversationActionPerformer`, as the Mac
/// does them, and this iPhone's own here.
@MainActor
enum PhoneActions {
  /// The actions for one conversation, or a selection's.
  static func groups(for ids: [UUID], library: LibraryController) -> [ConversationActionGroup] {
    let selected = library.meetings.filter { ids.contains($0.id) }
    guard let only = selected.first, selected.count == 1 else {
      return ConversationActions.batch(ids, in: library.meetings, context: .init(platform: .iPhone))
    }
    return groups(for: only)
  }

  /// One conversation's actions on this iPhone: Take Photo where there's a camera, Reprocess unless it's waiting.
  static func groups(for meeting: Meeting) -> [ConversationActionGroup] {
    ConversationActions.actions(
      for: meeting,
      context: .init(
        platform: .iPhone, status: ProcessingStatus.phone(meeting),
        canTakePhoto: CameraPicker.isAvailable))
  }

  /// How this iPhone processes a conversation in a mode, from its menus, its status, and Info alike: a summary goes where
  /// its placement puts it; the rest is a request a Mac takes up.
  static func process(
    _ id: UUID, _ mode: ProcessingRequest.Mode, library: LibraryController, placement: PhoneSummaryPlacement?
  ) {
    if mode == .summaryOnly {
      library.summarize(id, placement: placement)
    } else {
      library.requestProcessing(id, mode: mode)
    }
  }

  /// Carries out `id` on the conversations `ids`.
  static func perform(
    _ id: ConversationAction.ID, on ids: [UUID], library: LibraryController,
    session: ReadingSession, provider: any AudioProviding,
    placement: PhoneSummaryPlacement?, undoManager: UndoManager?
  ) {
    let performer = ConversationActionPerformer(
      library: library, undoManager: undoManager,
      process: { process($0, $1, library: library, placement: placement) },
      show: { request in
        switch request {
        case .tags(let ids): session.sheet = .tags(ids)
        case .versionHistory(let id): session.sheet = .history(id)
        case .moveToFolder(let ids): session.sheet = .move(ids)
        case .moveToTrash(let ids): session.confirmingTrash = ids
        }
      },
      copy: { LocalPasteboard.copy($0) },
      confirm: { session.confirmation = $0 })
    performer.perform(id, on: ids) { meetings in
      guard let first = meetings.first else { return }
      switch id {
      case .shareMarkdown, .shareJSON, .shareAudio:
        ConversationShare.share(id, meeting: first, session: session, provider: provider)
      case .takePhoto: session.cameraFor = first.id
      case .addPhotos: session.sheet = .importPhotos(first.id)
      case .addRecordingFromFile: session.addRecording(to: first.id)
      case .share, .reprocess:
        break  // Menus.
      case .export, .exportMarkdown, .exportJSON, .addRecording, .showFloatingNotes, .rename, .showInFinder:
        break  // The Mac's.
      case .play, .adjustTiming, .showOriginalTranscript, .moveToNewConversation, .removeRecording:
        break  // A recording's, in Info.
      case .copySummary, .process, .versionHistory, .moveToFolder, .tags, .moveTo, .moveToTrash:
        break  // The library's (`ConversationActionPerformer`).
      }
    }
  }
}

/// What this iPhone does for what a conversation's status offers, from the page and Info's Now row alike: the library's
/// half through DaybookKit's `ConversationStatusActionHandler`, as the Mac does it, with its work processed as its menus
/// process it (`PhoneActions.process`), and this iPhone's own here: Details, its downloads, Settings, where its summaries
/// run, and upgrades. A Mac's queue isn't this iPhone's to pause, resume, or cancel.
@MainActor
struct PhoneStatusActions: ConversationStatusActionHandler {
  let library: LibraryController
  let undoManager: UndoManager?
  let session: ReadingSession
  /// Its downloads; nil where none is offered (Info's Now row offers where the summary runs, Stop, and the waits).
  var model: PhoneAppModel? = nil
  let placement: PhoneSummaryPlacement?
  var upgrades: PhoneUpgrades? = nil
  /// Opens a Settings screen over the page (Models, Cloud).
  var openSettings: (@MainActor (SettingsRoute) -> Void)? = nil

  func process(_ id: UUID, _ mode: ProcessingRequest.Mode) {
    PhoneActions.process(id, mode, library: library, placement: placement)
  }

  func performHere(_ action: ConversationStatusPresentation.Action, on id: UUID) {
    switch action {
    case .details(let words): session.sheet = .details(words)
    case .pause, .resume, .cancel: break  // A Mac's queue.
    case .cancelDownload: model?.models.cancelProcessingDownloads()
    case .downloadModels: model?.models.downloadProcessingSet()
    case .downloadSummaryModel:
      guard let models = model?.models, let summary = models.summaryModel else { return }
      models.downloadIfItFits(summary)
    case .chooseModels: openSettings?(.models)
    case .cloudSettings: openSettings?(.cloud)
    case .summarizeHere: placement?.placements.beginHere(id)
    case .useYourMac: library.requestProcessing(id, mode: .summaryOnly)
    case .placement(let choice): placement?.perform(choice, for: id)
    case .stopSummary: placement?.stop(id)
    case .upgrade(let offer): Task { await upgrades?.accept(offer, for: id) }
    case .dismissUpgrade(let offer): upgrades?.dismiss(offer, for: id)
    case .transcribe, .summarize, .tryAgain, .cancelRequest, .dontWait, .waitAgain, .dismiss:
      break  // The library's (`ConversationStatusActionHandler.perform`).
    }
  }
}

/// The selection's actions at the bottom, where the thumb is: what `ConversationActions.batch` offers, each a glyph
/// over a word on one baseline.
private struct SelectionBar: View {
  let library: LibraryController
  let ids: [UUID]
  @Environment(ReadingSession.self) private var session
  @Environment(\.audioProvider) private var provider
  @Environment(\.summaryPlacement) private var placement
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    let groups = ConversationActions.batch(
      ids, in: library.meetings, context: .init(platform: .iPhone))
    let actions = ConversationActionMenuItems.shown(groups, on: .iPhone).flatMap(\.actions)
    HStack(spacing: 0) {
      if actions.isEmpty {
        // Nothing selected yet: the same bar, waiting.
        ForEach(Self.placeholders, id: \.0) { title, symbol in item(title, symbol, role: nil) {} }
      } else {
        ForEach(actions) { action in
          item(
            ConversationActionMenuItems.shortTitle(action), action.symbol,
            role: action.role == .destructive ? .destructive : nil
          ) {
            PhoneActions.perform(
              action.id, on: ids, library: library, session: session, provider: provider,
              placement: placement, undoManager: undoManager)
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
  private static let placeholders = [
    ("Move", "folder"), ("Tags", "tag"), ("Personal", "house"), ("Trash", "trash"),
  ]

  private func item(
    _ title: String, _ symbol: String, role: ButtonRole?, action: @escaping () -> Void
  ) -> some View {
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
    .foregroundStyle(role == .destructive ? DaybookPalette.Ink.error : DaybookPalette.Ink.link)
  }
}

/// A list row's side insets on the open Duo's left page: 20 pt, and 16 pt on the side meeting the crease.
/// The library's rows, search's results, and the Trash's line up. On one page, the list's own.
enum PageRows {
  static func inset(_ edge: Edge, twoPage: Bool, creaseEdge: Edge?) -> CGFloat? {
    guard twoPage else { return nil }
    return creaseEdge == edge ? ReadingGeometry.readingCreaseClearance : pageInset
  }

  static let pageInset: CGFloat = 20
  /// How far the shown row's wash reaches past its words.
  static let washOutset: CGFloat = 10

  /// The wash can extend toward the outside of the page, but never inside the crease clearance.
  static func washInset(_ edge: Edge, creaseEdge: Edge?) -> CGFloat {
    let inset = inset(edge, twoPage: true, creaseEdge: creaseEdge) ?? pageInset
    return creaseEdge == edge ? inset : inset - washOutset
  }
}

extension View {
  /// The row's side insets on two pages (`PageRows`).
  func pageRowInsets(twoPage: Bool) -> some View {
    modifier(PageRowInsets(twoPage: twoPage))
  }
}

private struct PageRowInsets: ViewModifier {
  let twoPage: Bool
  @Environment(\.creaseEdge) private var creaseEdge

  func body(content: Content) -> some View {
    content
      .listRowInsets(.leading, PageRows.inset(.leading, twoPage: twoPage, creaseEdge: creaseEdge))
      .listRowInsets(.trailing, PageRows.inset(.trailing, twoPage: twoPage, creaseEdge: creaseEdge))
  }
}

/// A row's background on paper. The shown row's wash extends 10 pt past its words except at the crease.
struct PageRowBackground: View {
  let shown: Bool
  @Environment(\.creaseEdge) private var creaseEdge

  var body: some View {
    if shown {
      RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DaybookPalette.accent.opacity(0.14))
        .padding(
          .leading,
          PageRows.washInset(.leading, creaseEdge: creaseEdge)
        )
        .padding(
          .trailing,
          PageRows.washInset(.trailing, creaseEdge: creaseEdge))
    } else {
      DaybookPalette.paper
    }
  }
}
