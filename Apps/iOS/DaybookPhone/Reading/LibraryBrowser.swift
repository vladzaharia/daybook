import DaybookKit
import SwiftUI

/// The library and reading while nothing is being recorded, in one column (pocket) or two pages
/// (notebook). Owned by the library and reading work (docs/iphone.md, phase 2). It places
/// `RecordStartButton` and presents `SettingsScreen`, and hosts the status (Status/StatusSheet.swift):
/// a sheet over the pocket library (which then holds Record), a panel at the foot of the notebook's
/// right page.
///
/// - Pocket (closed, or a regular iPhone): the list, and a conversation pushed over it with a
///   Summary | Transcript switch.
/// - Notebook (open): the list on the left and the chosen conversation on the right; open a
///   conversation and it becomes the spread, its summary on the left and transcript on the right,
///   linked so a next step, a bullet, or a bookmark scrolls the right page to its evidence.
///
/// Everything it shows comes from the `ReadingSession` in the environment, which outlives the
/// layout, so folding and unfolding keeps the conversation, the scroll positions, and playback.
struct LibraryBrowser: View {
    let style: SurfaceStyle
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        ReadingLayout(style: style, library: model.library.controller, rootURL: model.library.rootURL,
                      openLatest: model.options.openLatest, statusDetent: model.options.statusDetent)
    }
}

private struct ReadingLayout: View {
    let style: SurfaceStyle
    @ObservedObject var library: LibraryController
    let rootURL: URL
    let openLatest: Bool
    let statusDetent: StatusDetent?
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The notebook's status panel.
    @State private var panelDetent: StatusDetent = .compact

    var body: some View {
        @Bindable var session = session
        Group {
            if style == .pocket { pocket } else { notebook }
        }
        .environment(\.findQuery, session.isSearching ? session.searchText : "")
        // reading: until the recording work exposes its store on the app model, read the same folder.
        .environment(\.liveCaptionStore, LiveCaptionStore(libraryRoot: rootURL))
        .sheet(item: $session.sheet) { sheet in
            ReadingSheetContent(sheet: sheet, library: library)
                .environment(session)
                .tint(PhoneStyle.accent)
        }
        .alert("Daybook", isPresented: Binding(get: { session.alert != nil }, set: { if !$0 { session.alert = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(session.alert ?? "") }
        .onChange(of: library.isLoaded, initial: true) { _, loaded in
            guard loaded else { return }
            session.launch.apply(to: session, library: library, provider: provider)
            if openLatest, session.openID == nil, let newest = LibraryPlace.section(.all).meetings(in: library.meetings).first {
                session.open(newest.id)
            }
            adapt(to: style)
        }
        .onChange(of: style) { _, style in adapt(to: style) }
        .onChange(of: library.meetings.map(\.id)) { _, ids in
            // A conversation trashed elsewhere (or by sync) leaves the page.
            if let open = session.openID, !ids.contains(open) { session.forget(open) }
            if style != .pocket { adapt(to: style) }
        }
    }

    // MARK: One column

    private var pocket: some View {
        PocketStack(library: library, rootURL: rootURL)
            .modifier(StatusSheetHost(enabled: true))
    }

    // MARK: Two pages

    private var notebook: some View {
        CreaseSplit {
            leftPage
        } trailing: {
            rightPage
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : PhoneStyle.Motion.page, value: session.reading)
    }

    @ViewBuilder private var leftPage: some View {
        if session.reading, let id = session.openID, let meeting = library.meeting(id) {
            NavigationStack {
                SummaryPage(library: library, meeting: meeting)
                    .environment(\.isTwoPage, true)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { session.closeConversation() } label: { Label("Library", systemImage: "chevron.backward") }
                                .labelStyle(.titleAndIcon)
                        }
                        ConversationToolbar(library: library, meeting: meeting)
                    }
            }
            .transition(pageTurn(from: .trailing))
        } else {
            NavigationStack {
                LibraryPage(library: library, rootURL: rootURL, twoPage: true)
            }
            .transition(pageTurn(from: .leading))
        }
    }

    @ViewBuilder private var rightPage: some View {
        if let id = session.openID, let meeting = library.meeting(id) {
            if session.reading {
                NavigationStack {
                    TranscriptPage(library: library, player: session.player, meeting: meeting, showsHeader: false)
                        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar(player: session.player, library: library, meeting: meeting) }
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { TranscriptToolbar(meeting: meeting) }
                }
                .environment(\.isTwoPage, true)
                .transition(pageTurn(from: .trailing))
            } else {
                withStatusPanel(NavigationStack {
                    SummaryPage(library: library, meeting: meeting)
                        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar(player: session.player, library: library, meeting: meeting) }
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { session.open(id) } label: {
                                    Label(meeting.unifiedTranscript.isEmpty ? "Open" : "Open with Transcript", systemImage: "book.pages")
                                }
                                .labelStyle(.titleAndIcon)
                            }
                            ConversationToolbar(library: library, meeting: meeting)
                        }
                }
                .id(id))
                .transition(.opacity)
            }
        } else {
            withStatusPanel(NotebookPlaceholder(isEmpty: library.isLoaded && library.meetings.isEmpty))
        }
    }

    /// The right page while browsing: the status panel at its foot, the preview scrolling clear of
    /// it. Expanded to the full page, the panel stands in for the preview until it's collapsed.
    private func withStatusPanel(_ page: some View) -> some View {
        ZStack(alignment: .bottom) {
            page
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: StatusPanel.compactFootprint) }
                .opacity(panelDetent == .large ? 0 : 1)
                .accessibilityHidden(panelDetent == .large)
            StatusPanel(detent: $panelDetent)
        }
        .task {
            if let statusDetent { try? await Task.sleep(for: .milliseconds(500)); panelDetent = statusDetent }
        }
    }

    private func pageTurn(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: edge).combined(with: .opacity), removal: .opacity)
    }

    /// Carries the reading position across a fold (see `ReadingSession`).
    private func adapt(to style: SurfaceStyle) {
        session.isNotebook = style != .pocket
        guard library.isLoaded else { return }
        if style == .pocket {
            // The conversation the person chose on the right page stays open in one column.
            if !session.reading, session.chosen, session.openID != nil, !session.isSelecting { session.reading = true }
        } else if session.openID == nil {
            let place = session.place.libraryPlace ?? .section(.all)
            if let newest = place.meetings(in: library.meetings).first ?? LibraryPlace.section(.all).meetings(in: library.meetings).first {
                session.openID = newest.id
                session.chosen = false
            }
        }
    }
}

/// The transcript page's own toolbar on two pages: where it's playing, and the speakers' Info.
private struct TranscriptToolbar: ToolbarContent {
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { session.sheet = .info(meeting.id) } label: { Label("People", systemImage: "person.2") }
                .disabled(meeting.speakers.isEmpty)
        }
    }
}

/// The right page before anything is chosen.
private struct NotebookPlaceholder: View {
    let isEmpty: Bool
    var body: some View {
        VStack(spacing: PhoneStyle.Space.s3) {
            Image(systemName: "book.pages")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(PhoneStyle.brandGradient)
                .accessibilityHidden(true)
            Text(isEmpty ? "Your conversations will open here" : "Choose a conversation")
                .font(PhoneStyle.Typeface.title(22)).foregroundStyle(PhoneStyle.Ink.title)
                .multilineTextAlignment(.center)
            if isEmpty {
                Text("Record one with the button on the left, or on your Mac.")
                    .font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(PhoneStyle.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperBackground()
    }
}

/// One column's navigation. The pushed conversation is the session's open one; the path is set a
/// moment after the stack appears (without animation), because a stack created already pushed
/// (after a fold) loses its page's toolbar title items.
private struct PocketStack: View {
    @ObservedObject var library: LibraryController
    let rootURL: URL
    @Environment(ReadingSession.self) private var session
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            LibraryPage(library: library, rootURL: rootURL)
                .navigationDestination(for: UUID.self) { id in
                    ConversationScreen(library: library, id: id)
                }
        }
        .onAppear {
            DispatchQueue.main.async { sync(animated: false) }
        }
        .onChange(of: wanted) { _, _ in sync(animated: true) }
        .onChange(of: path) { _, path in
            if let last = path.last {
                if session.openID != last || !session.reading { session.open(last) }
            } else if session.reading {
                session.closeConversation()
            }
        }
    }

    private var wanted: [UUID] { session.reading ? session.openID.map { [$0] } ?? [] : [] }

    private func sync(animated: Bool) {
        guard path != wanted else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = !animated
        withTransaction(transaction) { path = wanted }
    }
}
