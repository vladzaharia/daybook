import AppKit
import DaybookCore
import DaybookDesign
import DaybookIntelligence
import DaybookKit
import DaybookUI
import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    /// The conversation the library window's page shows (`LibraryView`): the selected one, or on a device's page the
    /// conversation of the imported recording it shows. Nil with none, or with several selected. For menus and other
    /// windows that act on what the person is looking at.
    @Entry var shownConversation: UUID?
    /// Whether the library window's toolbar shows, for View › Show/Hide Toolbar.
    @Entry var libraryToolbarShown: Binding<Bool>?
}

/// The main window: places, the conversation list, and the page, with an optional inspector.
struct LibraryView: View {
    @Bindable var state: AppState
    @AppStorage("isInspectorPresented") private var inspectorPresented = false
    @State private var columns = NavigationSplitViewVisibility.all
    /// The most columns the window has room for now (`ColumnFit`); the person's own choice is `storedColumns`.
    @State private var columnCap = ColumnFit.all
    /// What `adaptColumns` set last, so the change it makes isn't taken for the person's.
    @State private var adaptedColumns: NavigationSplitViewVisibility?
    @State private var windowWidth: CGFloat = 1280
    /// The visible width of the window's screen, once it's on one: a screen narrower than the inspector needs shows it
    /// in a window as wide as the screen (`ColumnFit.inspectorFits`).
    @State private var screenWidth: CGFloat?
    @State private var problemDetails: AppProblem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shareAnchor = SharingAnchor.Holder()
    @FocusState private var searchFocused: Bool
    /// The window's: Edit › Undo takes a Move to Trash back.
    @Environment(\.undoManager) private var undoManager
    // Where the person was, for the window to reopen there (`LibraryRestoration`): the place, the conversation, its
    // page, and which columns they chose to show.
    @SceneStorage("library.place") private var storedPlace = ""
    @SceneStorage("library.selection") private var storedSelection = ""
    @SceneStorage("library.page") private var storedPage = ""
    @SceneStorage("library.columns") private var storedColumns = ColumnFit.all.rawValue
    @SceneStorage("library.toolbar") private var toolbarShown = true
    @State private var restored = false

    /// The conversation whose controls the toolbar shows; on the device page, an imported recording's conversation.
    private var toolbarMeeting: Meeting? {
        guard state.multiSelection.count < 2 else { return nil }
        if state.place.isDevice && !state.isSearching {
            return state.deviceConversationID.flatMap { id in state.meetings.first { $0.id == id } }
        }
        return state.selectedMeeting
    }

    private var showsConversation: Bool { !state.place.isDevice && state.multiSelection.count < 2 && state.selectedMeeting != nil }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            Group {
                if state.place.isDevice && !state.isSearching { DeviceRecordingsList(state: state) }
                else { ConversationList(state: state) }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            // The inspector puts the page and itself in a split view of their own, and gives each a
            // new split item when its view's identity changes. Swapping the page's item takes the
            // inspector's out and back in, and an inspector animation still running then finishes
            // on the detached item and throws. So both sides are one view whatever they show.
            // Teal is content's: the page's checkboxes, links, and fills. The toolbar, the inspector, the list, and the
            // sidebar follow the accent the person chose in System Settings (the AccentColor asset under Multicolor).
            ZStack { detail.tint(DaybookStyle.accent) }
                .confirmationBeat($state.confirmation)
                .overlay(alignment: .topTrailing) {
                    SharingAnchor(holder: shareAnchor).frame(width: 1, height: 1).padding(.trailing, 72).accessibilityHidden(true)
                }
                .toolbar {
                    DetailToolbar(state: state, meeting: toolbarMeeting, inspectorAvailable: showsConversation,
                                  inspectorShown: inspectorShown, toggleInspector: toggleInspector, windowAction: windowAction)
                }
                .inspector(isPresented: inspector) {
                    ZStack {
                        if let id = state.selectedID { MeetingInspector(state: state, meetingID: id).equatable() }
                    }
                    .inspectorColumnWidth(min: 260, ideal: 280, max: 340)
                }
        }
        .searchable(text: $state.search, tokens: $state.searchTokens, placement: .toolbar, prompt: LibraryWords.searchPrompt) { token in
            Label(token.text, systemImage: token.symbol)
        }
        .searchSuggestions { suggestions }
        .searchFocused($searchFocused)
        .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: state.search) { _, text in promoteHashTag(text) }
        .onChange(of: state.place) { _, _ in reconcileSelection() }
        .onChange(of: state.visibleMeetings.map(\.id)) { _, _ in reconcileSelection() }
        .environment(\.readingScale, CGFloat(state.readingScale))
        .focusedSceneValue(\.shownConversation, toolbarMeeting?.id)
        .toolbarVisibility(toolbarShown ? .automatic : .hidden, for: .windowToolbar)
        .focusedSceneValue(\.libraryToolbarShown, $toolbarShown)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0; noteScreen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { note in
            if (note.object as? NSWindow) === shareAnchor.window { noteScreen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in noteScreen() }
        // Tags… and the byline's people ask for the inspector here, so they widen a narrow window as ⌃⌘I does.
        .onChange(of: state.inspectorRequest) { _, _ in withAnimation { inspector.wrappedValue = true } }
        .onChange(of: inspectorPresented) { _, _ in adaptColumns() }
        .onChange(of: showsConversation) { _, _ in adaptColumns() }
        .onChange(of: columns) { old, shown in columnsChanged(from: old, to: shown) }
        .onChange(of: state.isReady, initial: true) { _, ready in if ready { restore() } }
        .onChange(of: state.place) { _, place in if restored { storedPlace = LibraryRestoration.encode(place) } }
        .onChange(of: state.selectedID) { _, id in if restored { storedSelection = id?.uuidString ?? "" } }
        .onChange(of: state.pageMode) { _, mode in if restored { storedPage = mode.rawValue } }
        .sheet(item: $state.activeSheet) { sheet in ConversationSheet(state: state, sheet: sheet) }
        .sheet(item: $state.addDeviceRequest) { request in AddDeviceSheet(state: state, request: request) }
        .sheet(item: $state.libraryMoveOffer) { offer in LibraryMoveSheet(state: state, offer: offer) }
        .alert(trashTitle, isPresented: Binding(get: { !state.trashRequestIDs.isEmpty }, set: { if !$0 { state.trashRequestIDs = [] } })) {
            Button("Move to Trash", role: .destructive) {
                state.trashMeetings(state.trashRequestIDs, undoManager: undoManager)
                state.multiSelection = []
                state.trashRequestIDs = []
            }
            Button("Cancel", role: .cancel) { state.trashRequestIDs = [] }
        } message: {
            Text(state.trashRequestIDs.count > 1 ? "Their audio, notes, and summaries go with them."
                 : "Its audio, notes, and summary go with it.")
        }
        .alert(state.shownProblem?.title ?? "", isPresented: Binding(get: { state.shownProblem != nil }, set: { if !$0 { state.dismissProblem() } }),
               presenting: state.shownProblem) { problem in
            Button("OK") { state.dismissProblem() }
            if let pane = problem.privacyPane {
                Button("Open System Settings") { PrivacySettings.open(pane); state.dismissProblem() }
            }
            if problem.details != nil {
                Button("Details…") { problemDetails = problem; state.dismissProblem() }
            }
        } message: { problem in Text(problem.message) }
        .sheet(item: $problemDetails) { ProblemDetailsSheet(problem: $0) }
    }

    @ViewBuilder private var detail: some View {
        if let problem = state.libraryProblem {
            LibraryProblemPage(state: state, problem: problem)
        } else if state.place.isDevice && !state.isSearching {
            DevicePage(state: state)
        } else if state.place.isTrash && !state.isSearching {
            TrashDetail(state: state)
        } else if state.multiSelection.count > 1 {
            BatchSelectionView(state: state, ids: Array(state.multiSelection))
        } else if let meeting = state.selectedMeeting {
            MeetingDetailView(state: state, meetingID: meeting.id)
                .equatable()
                .id(meeting.id)
                .modifier(AddRecordingDrop(state: state, meeting: meeting))
        } else if state.isReady && state.meetings.isEmpty {
            EmptyLibraryView(state: state)
        } else if !state.isSearching && state.visibleMeetings.isEmpty {
            // An empty place says so in its list; the page stays blank rather than asking for a choice.
            DaybookStyle.paper
        } else {
            Text("No Conversation Selected")
                .font(TypeStyle.heading())
                .foregroundStyle(Ink.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DaybookStyle.paper)
        }
    }

    private var trashTitle: String {
        LibraryWords.trashTitle(state.meetings.filter { state.trashRequestIDs.contains($0.id) })
    }

    /// The tags and people that start with what's typed, the iPhone's too (`LibrarySearchSuggestions`); only once
    /// something is typed, so the field's menu doesn't open by itself.
    @ViewBuilder private var suggestions: some View {
        if !state.search.trimmingCharacters(in: .whitespaces).isEmpty {
            ForEach(LibrarySearchSuggestions.tokens(for: state.search, tags: state.allTags, meetings: state.meetings, chosen: state.searchTokens)) { token in
                Label(token.text, systemImage: token.symbol).searchCompletion(token)
            }
        }
    }

    /// The page always shows something in the list: when the selection leaves the place
    /// (moved to another folder, or the place changed), the first visible conversation is selected. The Trash
    /// selects what it lists itself.
    private func reconcileSelection() {
        guard state.isReady, !state.isSearching, !state.place.isDevice, !state.place.isTrash else { return }
        let visible = state.visibleMeetings
        if let selected = state.selectedID, visible.contains(where: { $0.id == selected }) { return }
        state.multiSelection = []
        state.selectedID = visible.first?.id
    }

    /// Typing "#tag " turns the tag into a token.
    private func promoteHashTag(_ text: String) {
        guard let token = LibrarySearchSuggestions.promotedTag(in: text, tags: state.allTags) else { return }
        state.searchTokens.append(token)
        state.search = ""
    }

    /// The sidebar steps aside in narrow windows, and when the inspector would leave the page under 560 pt, and comes
    /// back once there's room again (`ColumnFit`), never past what the person chose to show. (The window itself stays
    /// wide enough for the page beside the list and the inspector: `ColumnFit.narrowestWithInspector`.)
    private func adaptColumns() {
        columnCap = ColumnFit.cap(window: windowWidth, inspector: inspectorShown, previous: columnCap)
        let target = min(ColumnFit(storedColumns), columnCap).visibility
        guard ColumnFit(columns) != ColumnFit(target) else { return }
        adaptedColumns = target
        withAnimation { columns = target }
    }

    /// The inspector shows only where it leaves the page its 560 pt beside the list (the sidebar stepping aside), or in a
    /// window as wide as a narrower screen allows; in a narrower window it waits, still asked for, until there's room.
    private var inspectorShown: Bool {
        inspectorPresented && showsConversation && ColumnFit.inspectorFits(window: windowWidth, screen: screenWidth)
    }

    /// Every way of asking for the inspector or putting it away (the toolbar, ⌃⌘I, Tags…, the byline's people, closing
    /// it): asked for in a window that holds it back, the window widens, whether or not it was asked for already (the
    /// stored choice outlives a window that has since narrowed, or a relaunch).
    private var inspector: Binding<Bool> {
        Binding(get: { inspectorShown }, set: { wanted in
            let widens = ColumnFit.widensForInspector(asked: wanted, available: showsConversation, window: windowWidth, screen: screenWidth)
            inspectorPresented = wanted
            // On the next turn: this may be called inside an update, and a window resized during a layout pass lays
            // itself out again without end.
            if widens { DispatchQueue.main.async { makeRoomForInspector(animated: true) } }
        })
    }

    /// The toolbar's Inspector: hides it when it shows; otherwise asks for it, widening the window to make room.
    private func toggleInspector() {
        let show = !inspectorShown
        withAnimation { inspector.wrappedValue = show }
    }

    /// The width of the screen the window is on now, as the inspector's room depends on it.
    private func noteScreen() {
        screenWidth = shareAnchor.window?.screen?.visibleFrame.width
        adaptColumns()
    }

    /// Widens a window too narrow for the page beside the list and the inspector to `ColumnFit.narrowestWithInspector`,
    /// as far as its screen allows. Only for something the person did (a click, a key), never inside a layout pass: a
    /// window resized during one lays itself out again without end.
    private func makeRoomForInspector(animated: Bool) {
        guard let window = shareAnchor.window, !window.styleMask.contains(.fullScreen), let screen = window.screen?.visibleFrame,
              let frame = ColumnFit.widened(window.frame, to: min(ColumnFit.narrowestWithInspector, screen.width), on: screen) else { return }
        window.setFrame(frame, display: true, animate: animated && !reduceMotion)
    }

    /// A change the window didn't make is the person's (the sidebar button, ⌃⌘S): it's kept, and showing more lifts
    /// what the window holds back. Fewer columns while the window is short of room may be AppKit's own squeeze, so that
    /// isn't taken for a choice.
    private func columnsChanged(from old: NavigationSplitViewVisibility, to shown: NavigationSplitViewVisibility) {
        if let adapted = adaptedColumns, ColumnFit(adapted) == ColumnFit(shown) {
            adaptedColumns = nil
            return
        }
        guard let choice = ColumnFit.choice(from: ColumnFit(old), to: ColumnFit(shown), cap: columnCap) else { return }
        storedColumns = choice.rawValue
        columnCap = max(columnCap, choice)
    }

    /// Puts the window back as the person left it, once the library is ready: the place (if it's still there), the
    /// conversation (if it still is, else the place's first), its page, and the columns they chose. A launch that asks
    /// for a place, a conversation, or a demo (debug builds) keeps what it asked for.
    private func restore() {
        guard !restored else { return }
        defer {
            restored = true
            storedPlace = LibraryRestoration.encode(state.place)
            storedSelection = state.selectedID?.uuidString ?? ""
            storedPage = state.pageMode.rawValue
        }
        // The columns the person chose, as far as the window has room for them: one change, straight there.
        adaptColumns()
        guard !LibraryRestoration.launchChoosesPlace else { return }
        if let place = LibraryRestoration.decode(storedPlace, folders: state.folders.map(\.id), devices: state.devices.sessions.map(\.id)) {
            state.place = place
        }
        if let id = LibraryRestoration.selection(storedSelection, in: state.place.isDevice ? [] : state.visibleMeetings) {
            state.multiSelection = []
            state.selectedID = id
        }
        if let page = PageMode(rawValue: storedPage) { state.pageMode = page }
    }

    /// Share and Tags… from More: what needs the window.
    private func windowAction(_ id: ConversationAction.ID, _ meeting: Meeting) {
        switch id {
        case .tags:
            state.showInspector()
        default:
            MacShare.share(id, meeting: meeting, state: state, anchor: shareAnchor)
        }
    }
}

/// How many of the window's columns show, fewest to most. The person chooses with the sidebar button and ⌃⌘S; the
/// window holds some back while there isn't room for the page.
enum ColumnFit: String, Comparable, CaseIterable {
    case detailOnly, doubleColumn, all

    /// The page's least width while the inspector shows (docs/interface.md, "Window structure").
    static let page: CGFloat = 560
    // The columns' usual widths.
    static let sidebar: CGFloat = 200
    static let list: CGFloat = 300
    static let inspector: CGFloat = 280
    /// The narrowest the window goes while the inspector shows: the page's 560 pt beside the list and the inspector,
    /// the sidebar stepping aside. Opening the inspector in a narrower window widens it to this, as far as the screen
    /// allows. (macOS's split view won't fold its list column away, so the window makes the room instead.)
    static let narrowestWithInspector: CGFloat = list + inspector + page

    /// How far short of its screen's visible width a window still fills it (a tiled window keeps a margin).
    static let screenMargin: CGFloat = 24

    /// Whether a window `window` wide has room for the inspector beside the page and the list, the sidebar aside: the
    /// page's 560 pt, or on a screen narrower than that needs (`screen`, its visible width), a window as wide as the
    /// screen allows, the page narrower, so the inspector is never out of reach.
    static func inspectorFits(window: CGFloat, screen: CGFloat? = nil) -> Bool {
        window >= min(narrowestWithInspector, (screen ?? .infinity) - screenMargin)
    }

    /// Whether asking for the inspector (`asked`) widens the window first: there's a conversation for it (`available`)
    /// and the window holds it back for want of room, whether or not it was asked for before.
    static func widensForInspector(asked: Bool, available: Bool, window: CGFloat, screen: CGFloat?) -> Bool {
        asked && available && !inspectorFits(window: window, screen: screen)
    }

    init(_ visibility: NavigationSplitViewVisibility) {
        switch visibility {
        case .detailOnly: self = .detailOnly
        case .doubleColumn: self = .doubleColumn
        default: self = .all
        }
    }

    /// A stored choice; anything unreadable is every column.
    init(_ stored: String) { self = ColumnFit(rawValue: stored) ?? .all }

    var visibility: NavigationSplitViewVisibility {
        switch self {
        case .detailOnly: return .detailOnly
        case .doubleColumn: return .doubleColumn
        case .all: return .all
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: ColumnFit, rhs: ColumnFit) -> Bool { lhs.rank < rhs.rank }

    /// The most columns a window `window` wide has room for: the sidebar steps aside below 1000 pt, or when the
    /// inspector would leave the page under 560. Once aside, it comes back only with room to spare (1100 pt with the
    /// inspector), or once the inspector closes, so a window at the edge doesn't flicker (`previous` is what the window
    /// held back last).
    static func cap(window: CGFloat, inspector: Bool, previous: ColumnFit) -> ColumnFit {
        let inspectorWidth = inspector ? Self.inspector : 0
        let sidebarCrowds = window < 1000 || window - sidebar - list - inspectorWidth < page
        let sidebarFits = !sidebarCrowds && (window >= 1100 || !inspector)
        if sidebarCrowds || (previous < .all && !sidebarFits) { return .doubleColumn }
        return .all
    }

    /// `frame` at least `width` wide, kept on `screen` (growing leftward where its right edge would leave it); nil when
    /// it's already that wide.
    static func widened(_ frame: CGRect, to width: CGFloat, on screen: CGRect) -> CGRect? {
        guard frame.width < width else { return nil }
        var wider = frame
        wider.size.width = width
        if wider.maxX > screen.maxX { wider.origin.x = max(screen.minX, screen.maxX - width) }
        return wider
    }

    /// What a change of columns the window didn't make says the person chose: showing more always; showing fewer only
    /// while the window has room for more (narrower than that, AppKit folds the sidebar itself). Nil when it says
    /// nothing.
    static func choice(from old: ColumnFit, to new: ColumnFit, cap: ColumnFit) -> ColumnFit? {
        if new > old { return new }
        if new < old, cap == .all { return new }
        return nil
    }
}

/// Where the window was, as scene storage keeps it: a place as words ("section:work", "folder:<id>", "device:<id>"), and
/// a conversation by its ID, each used only while it's still in the library.
enum LibraryRestoration {
    static func encode(_ place: LibraryPlace) -> String {
        if case .section(let section) = place { return "section:" + section.rawValue }
        if case .folder(let id) = place { return "folder:" + id.uuidString }
        if case .device(let id) = place { return "device:" + id }
        return ""
    }

    /// The place `text` names, while its folder or device is still here.
    static func decode(_ text: String, folders: [UUID], devices: [String]) -> LibraryPlace? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "section": return LibrarySection(rawValue: parts[1]).map { .section($0) }
        case "folder": return UUID(uuidString: parts[1]).flatMap { folders.contains($0) ? .folder($0) : nil }
        case "device": return devices.contains(parts[1]) ? .device(parts[1]) : nil
        default: return nil
        }
    }

    /// The stored conversation, while it's among `visible`; nil leaves the place's first selected.
    static func selection(_ text: String, in visible: [Meeting]) -> UUID? {
        guard let id = UUID(uuidString: text), visible.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// A launch that opens a surface (debug builds' `--place`, `--select`, `--page`, `--search`, the demos) keeps it.
    static var launchChoosesPlace: Bool {
        let flags = ["--place", "--select", "--page", "--search", "--library-demo", "--demo-library", "--device-demo",
                     "--simulate-recording", "--multi-select", "--notes-demo"]
        return flags.contains { CommandLine.arguments.contains($0) }
    }
}

// MARK: - Record

/// Record, then the red elapsed-time pill, then Saving…, then for a moment Saved; each blurs into the next.
struct RecordControl: View {
    @Bindable var state: AppState
    /// The conversation being recorded, to see how its recording ended.
    @State private var recorded: UUID?
    /// The recording was saved: Record says so for `DaybookMotion.hold`.
    @State private var saved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: Equatable {
        case idle, recording, saving

        @MainActor init(_ state: AppState) {
            if state.isStoppingRecording { self = .saving }
            else { self = state.isRecording && state.recordingStartedAt != nil ? .recording : .idle }
        }
    }

    var body: some View {
        let phase = Phase(state)
        Group {
            switch phase {
            case .saving:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Saving…") }
                    .foregroundStyle(.secondary)
            case .recording:
                RecordingPill(state: state, start: state.recordingStartedAt ?? Date())
            case .idle:
                Button { Task { await state.startRecording() } } label: {
                    Label {
                        Text(saved ? "Saved" : "Record")
                            .contentTransition(reduceMotion ? .opacity : .interpolate)
                    } icon: {
                        if saved {
                            DoneMark()
                        } else {
                            Image(systemName: "record.circle").symbolRenderingMode(.palette).foregroundStyle(Ink.record, .secondary)
                        }
                    }
                }
                .disabled(!state.isReady || state.isStartingRecording)
                .help("Start Recording (⇧⌘R)")
                .accessibilityLabel("Record")
            }
        }
        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        .motion(Motion.state, value: phase)
        .motion(Motion.fade, value: saved)
        .onChange(of: state.recordingID) { _, id in if let id { recorded = id } }
        .onChange(of: phase) { old, new in
            guard old != .idle, new == .idle, let id = recorded else { return }
            recorded = nil
            saved = Self.savedWell(id, state: state)
        }
        .task(id: saved) {
            guard saved else { return }
            try? await Task.sleep(for: DaybookMotion.hold)
            saved = false
        }
    }

    /// The recording ended with its conversation saved: not failed, and not stopped by something else.
    static func savedWell(_ id: UUID, state: AppState) -> Bool {
        guard let meeting = state.meetings.first(where: { $0.id == id }) else { return false }
        return meeting.status != .failed && state.unexpectedStops[id] == nil
    }
}

/// Stop: the elapsed time in a red pill with its own colours, so it stays red while the window isn't key, which is how
/// it is during a call (as Floating Notes' Stop).
private struct RecordingPill: View {
    @Bindable var state: AppState
    let start: Date
    @State private var appeared = false

    var body: some View {
        Button { Task { await state.stopRecording() } } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .daybookBounce(value: appeared)
                ElapsedTime(start: start)
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(DaybookControlStyle(role: .stop, shape: .capsule))
        .help("Stop Recording (⇧⌘R)")
        .accessibilityLabel("Stop recording")
        .onAppear { appeared = true }
    }
}

// MARK: - Empty library and multiple selection

private struct EmptyLibraryView: View {
    @Bindable var state: AppState
    @State private var isDropTargeted = false
    var body: some View {
        VStack(spacing: Space.s4) {
            DaybookMark(size: 64)
                .padding(.bottom, Space.s2)
            Text("No Conversations Yet").font(TypeStyle.docTitleSmall).foregroundStyle(Ink.title)
            Text("Record a conversation, or drop audio files here.").foregroundStyle(Ink.secondary)
            HStack(spacing: Space.s3) {
                // The red dot, as on the toolbar's Record and Floating Notes': the one red control.
                Button { Task { await state.startRecording() } } label: {
                    RecordControlLabel(size: 13).padding(.horizontal, 14).padding(.vertical, 6)
                }
                .buttonStyle(DaybookControlStyle(role: .standard, shape: .capsule))
                .disabled(!state.isReady || state.isStartingRecording)
                Button("Import Audio…") { state.chooseImport() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, Space.s2)
            if let id = state.downloadingID {
                ActivityReader {
                    Text("Downloading \(state.modelCatalog.name(for: id)) · \(Int(state.downloadProgress.fraction * 100))%")
                        .font(TypeStyle.status)
                        .foregroundStyle(Ink.secondary)
                        .padding(.top, Space.s6)
                }
            }
        }
        .offset(y: -24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DaybookStyle.paper)
        .overlay { if isDropTargeted { DropOutline(label: "Import Audio") } }
        .dropDestination(for: URL.self) { urls, _ in
            Task { do { try await state.importFiles(urls, source: .imported, attachTo: nil) } catch { state.report("Couldn’t Import Audio", "Choose an audio or video file and try again.", error) } }
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }
}

private struct BatchSelectionView: View {
    @Bindable var state: AppState
    let ids: [UUID]
    private var meetings: [Meeting] { state.meetings.filter { ids.contains($0.id) }.sorted { $0.date > $1.date } }
    var body: some View {
        VStack(spacing: Space.s3) {
            Text("\(meetings.count) Conversations").font(TypeStyle.docTitleSmall).foregroundStyle(Ink.title)
            // Up to four names; "and 1 more" would take the place of the one name it hides.
            Text(meetings.count > 4 ? meetings.prefix(3).map(\.title).joined(separator: ", ") + ", and \(meetings.count - 3) more"
                 : meetings.map(\.title).formatted(.list(type: .and)))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            // What the selection's menu offers (`ConversationActions.batch`), as buttons.
            BatchActionButtons(state: state, ids: ids)
                .padding(.top, Space.s2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DaybookStyle.paper)
    }
}

/// Audio dropped on an open conversation joins it as another recording.
private struct AddRecordingDrop: ViewModifier {
    @Bindable var state: AppState
    let meeting: Meeting
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .overlay { if targeted { DropOutline(label: "Add to “\(meeting.title)”") } }
            .dropDestination(for: URL.self) { urls, _ in
                let audio = AppState.droppedRecordings(urls)
                guard !audio.isEmpty, state.recordingID != meeting.id else { return false }
                Task { do { try await state.importFiles(audio, source: .imported, attachTo: meeting.id) } catch { state.report("Couldn’t Import Audio", "Choose an audio or video file and try again.", error) } }
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// Elapsed recording time that rolls only the digits that change, and under Reduce Motion fades, as `ElapsedClock`
/// does. It takes the ink around it: white on Stop's red.
struct ElapsedTime: View {
    let start: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            Text(DaybookTime.short(elapsed))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: false))
                .animation(DaybookMotion.resolved(DaybookMotion.tick, reduceMotion: reduceMotion), value: Int(elapsed))
        }
    }
}
