import DaybookDesign
import DaybookKit
import DaybookUI
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
    @Environment(ReadingSession.self) private var session

    var body: some View {
        ReadingLayout(style: style, library: model.library.controller, rootURL: model.library.rootURL,
                      openLatest: model.options.openLatest, statusDetent: model.options.statusDetent)
            .environment(\.liveCaptionsSaved, model.captions.lastSave)
            // The player stands aside for a recording however it starts, before anything plays here.
            .onAppear { [model] in session.player.follow { model.isRecordingActive } }
            .fileImporter(isPresented: Binding(get: { session.addingRecordingTo != nil }, set: { if !$0 { session.addingRecordingTo = nil } }),
                          allowedContentTypes: RecordStartButton.audioTypes, allowsMultipleSelection: true) { result in
                guard let id = session.addingRecordingTo, case .success(let urls) = result else { return }
                session.addingRecordingTo = nil
                Task { await model.addRecordings(urls, to: id) }
            }
    }
}

extension PhoneAppModel {
    /// Add Recording…: files from Files join a conversation as more of its recordings, each asking to be transcribed
    /// as an import does. A file already in the library isn't copied again.
    func addRecordings(_ urls: [URL], to id: UUID) async {
        var failures: [(name: String, reason: String)] = []
        for url in urls {
            do {
                let filed = try await library.importFile(url, requestTranscription: settings.requestsTranscription, attachTo: id)
                if let request = filed.request { link.nudge(request) }
            } catch {
                failures.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        if !failures.isEmpty {
            say(failures.count == 1 ? "Couldn’t add “\(failures[0].name)”." : "Couldn’t add \(failures.count) recordings.",
                details: failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
        }
        sync.synchronizeFinishing(.filed)
        processor.pickUp()
        publish()
    }
}

private struct ReadingLayout: View {
    let style: SurfaceStyle
    let library: LibraryController
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
        // The photo views' originals, viewer, and actions on every page (DaybookUI's photos).
        .modifier(PhonePhotoServices(library: library))
        // One column presents a sheet; two pages show it on the right page instead (`PageSheet`),
        // so nothing sits across the crease. The share sheet is always the system's.
        .sheet(item: Binding(get: { sheetOnPage ? nil : session.sheet }, set: { session.sheet = $0 })) { sheet in
            ReadingSheetContent(sheet: sheet, library: library)
                .environment(session)
                .tint(PhoneStyle.accent)
        }
        .fullScreenCover(isPresented: Binding(get: { session.cameraFor != nil }, set: { if !$0 { session.cameraFor = nil } })) {
            if let id = session.cameraFor {
                CameraPicker(capture: { photo in addPhoto(photo, to: id) }, finish: { session.cameraFor = nil },
                             failed: { session.alert = ReadingAlert(title: "Couldn’t Save Photo", message: "Take it again.") })
                    .ignoresSafeArea()
            }
        }
        .alert(session.alert?.title ?? "", isPresented: Binding(get: { session.alert != nil }, set: { if !$0 { session.alert = nil } }),
               presenting: session.alert) { alert in
            if let details = alert.details {
                Button("Details") { session.sheet = .errorDetails(details) }
            }
            Button("OK", role: .cancel) { }
        } message: { alert in Text(alert.message) }
        .alert(trashTitle, isPresented: Binding(get: { !session.confirmingTrash.isEmpty }, set: { if !$0 { session.confirmingTrash = [] } })) {
            Button("Move to Trash", role: .destructive) { trash(session.confirmingTrash) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(session.confirmingTrash.count > 1 ? "Their audio, notes, and summaries go with them." : "Its audio, notes, and summary go with it.")
        }
        .onChange(of: library.isLoaded, initial: true) { _, loaded in
            guard loaded else { return }
            #if DEBUG
            DemoLibrary.seed(library, rootURL: rootURL)
            #endif
            session.launch.apply(to: session, library: library, provider: provider)
            if openLatest, session.openID == nil, let newest = LibraryPlace.section(.all).meetings(in: library.meetings).first {
                session.open(newest.id)
            }
            adapt(to: style)
        }
        .onChange(of: style) { _, style in adapt(to: style) }
        // Leaving the Trash with nothing open shows the place's newest beside it.
        .onChange(of: session.place) { _, _ in if style != .pocket { adapt(to: style) } }
        .onChange(of: library.meetings.map(\.id)) { _, ids in
            // A conversation trashed elsewhere (or by sync) leaves the page.
            if let open = session.openID, !ids.contains(open) { session.forget(open) }
            if style != .pocket { adapt(to: style) }
        }
    }

    /// "Move “Weekly sync” to the Trash?", as on the Mac.
    private var trashTitle: String {
        LibraryWords.trashTitle(library.meetings.filter { session.confirmingTrash.contains($0.id) })
    }

    private func trash(_ ids: [UUID]) {
        Task {
            var failures: [String] = []
            for id in ids {
                do {
                    if try await library.moveToTrash(id) { session.forget(id) }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if session.isSelecting { session.isSelecting = false; session.selection = [] }
            if !failures.isEmpty {
                session.alert = ReadingAlert(title: "Couldn’t Move to Trash",
                                             message: failures.count == 1 ? "Try again." : "\(failures.count) conversations weren’t moved. Try again.",
                                             details: failures.joined(separator: "\n"))
            }
        }
    }

    private func addPhoto(_ photo: CameraPhoto, to id: UUID) {
        Task {
            do { try await library.addCameraPhoto(photo, to: id) }
            catch { session.alert = ReadingAlert(title: "Couldn’t Save Photo", error: error, fallback: "Take it again.") }
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
                .accessibilityHidden(sheetOnPage)
                // On the right page, clear of the crease, as its sheets are.
                .confirmationBeat(Bindable(session).confirmation)
                .overlay {
                    if sheetOnPage, let sheet = session.sheet {
                        PageSheet(close: { session.sheet = nil }) {
                            ReadingSheetContent(sheet: sheet, library: library)
                                .environment(\.closePageSheet) { session.sheet = nil }
                        }
                        .id(sheet.id)
                        .daybookTransition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .daybookMotion(PhoneStyle.Motion.state, value: session.sheet?.id)
        }
        .daybookMotion(PhoneStyle.Motion.page, value: session.reading)
    }

    /// The sheet shows on the right page: two pages, and anything but the system's share sheet.
    private var sheetOnPage: Bool {
        guard style != .pocket, let sheet = session.sheet else { return false }
        if case .share = sheet { return false }
        return true
    }

    @ViewBuilder private var leftPage: some View {
        if session.reading, let id = session.openID, let meeting = library.meeting(id) {
            NavigationStack {
                // A page of its own for each conversation, as the preview's: turning to another never animates it in.
                SummaryPage(library: library, meeting: meeting)
                    .id(id)
                    .environment(\.isTwoPage, true)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // The system's back button, as one column shows it: the chevron alone, in title ink.
                        ToolbarItem(placement: .topBarLeading) {
                            Button { session.closeConversation() } label: { Label("Library", systemImage: "chevron.backward") }
                                .labelStyle(.iconOnly)
                                .tint(PhoneStyle.Ink.title)
                                .accessibilityLabel("Library")
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
        if showsTrash {
            // Beside the Trash, the one shown there, read only, as the Mac's page beside its Trash.
            withStatusPanel { footprint in
                NavigationStack {
                    TrashedPage(library: library, id: session.trashedID)
                        .scrollEdgeEffectStyle(.hard, for: .bottom)
                        .safeAreaBar(edge: .bottom, spacing: 0) {
                            Rectangle().fill(Color.primary.opacity(0.001)).frame(height: footprint).accessibilityHidden(true)
                        }
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .transition(.opacity)
        } else if let id = session.openID, let meeting = library.meeting(id) {
            if session.reading {
                NavigationStack {
                    PhoneTranscriptPage(library: library, player: session.player, meeting: meeting, showsHeader: false)
                        // A bar, so the transcript under the player fades hard rather than reading sharp beneath it.
                        .scrollEdgeEffectStyle(session.player.isActive(for: meeting.id) ? .hard : nil, for: .bottom)
                        .safeAreaBar(edge: .bottom, spacing: 0) { ConversationPlayer(library: library, meeting: meeting) }
                        .navigationBarTitleDisplayMode(.inline)
                }
                .environment(\.isTwoPage, true)
                .transition(pageTurn(from: .trailing))
            } else {
                withStatusPanel { footprint in
                    NavigationStack {
                        // A bar the panel's height, not an inset: the preview's edge effect runs under the
                        // panel, hard, so the page doesn't read through its glass (as the list's under Record).
                        // The effect runs only under something drawn, so the bar's room is drawn, unseen.
                        SummaryPage(library: library, meeting: meeting, bottomEdgeEffect: .hard)
                            .safeAreaBar(edge: .bottom, spacing: 0) { ConversationPlayer(library: library, meeting: meeting) }
                            .safeAreaBar(edge: .bottom, spacing: 0) {
                                Rectangle().fill(Color.primary.opacity(0.001)).frame(height: footprint).accessibilityHidden(true)
                            }
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                // Words, not a glyph the toolbar would show alone: it's the way across both pages
                                // (a second tap on the row is the other).
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Open") { session.open(id) }
                                        .buttonStyle(.glassProminent)
                                        .tint(PhoneStyle.prominentFill)
                                }
                                ConversationToolbar(library: library, meeting: meeting)
                            }
                    }
                    .id(id)
                }
                .transition(.opacity)
            }
        } else {
            withStatusPanel { footprint in
                NotebookPlaceholder(isEmpty: library.isLoaded && library.meetings.isEmpty)
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: footprint) }
            }
        }
    }

    /// The left page lists the Trash (the conversations' spread isn't open, nor search), so the right page shows
    /// what's in it.
    private var showsTrash: Bool {
        let spread = session.reading && session.openID.flatMap { library.meeting($0) } != nil
        return !spread && session.place.isTrash && !session.isSearching
    }

    /// The right page while browsing: the status panel at its foot, the page keeping clear of the
    /// room it takes (`footprint`, compact or medium). Expanded to the full page, the panel stands in
    /// for the preview until it's collapsed.
    private func withStatusPanel(@ViewBuilder _ page: @escaping (_ footprint: CGFloat) -> some View) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                page(StatusPanel.footprint(panelDetent == .medium ? .medium : .compact, in: proxy.size.height))
                    .opacity(panelDetent == .large ? 0 : 1)
                    .accessibilityHidden(panelDetent == .large)
                StatusPanel(detent: $panelDetent)
            }
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
        } else {
            session.showNewest(of: library.meetings)
        }
    }
}

/// A reading sheet on the notebook's right page: a card on that page, clear of the crease, where one
/// column would present a sheet. Its Done or Cancel closes it (`SheetDismiss`), and so do what closes
/// a sheet: a swipe down from its grabber, and VoiceOver's escape (two fingers scrubbing). It isn't
/// modal: the left page stays as it was, and stays in reach.
private struct PageSheet<Content: View>: View {
    let close: () -> Void
    @ViewBuilder var content: Content
    @State private var drag: CGFloat = 0
    @Environment(\.creaseEdge) private var creaseEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .top) { grabber }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 4)
            .offset(y: drag)
            .accessibilityAction(.escape) { close() }
            .padding(.leading, creaseEdge == .leading ? PhoneStyle.Page.creaseClearance : PhoneStyle.Space.s3)
            .padding(.trailing, PhoneStyle.Space.s3)
            .padding(.vertical, PhoneStyle.Space.s2)
            // The page under it steps back, as under a sheet; the other page doesn't.
            .background {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.12))
                    .opacity(PageSheetDrag.dimming(drag))
                    .ignoresSafeArea(edges: [.top, .bottom, .trailing])
                    .accessibilityHidden(true)
            }
    }

    /// A sheet's grabber, over the middle of the card's top edge, clear of its Done and Cancel: the card follows a
    /// finger down and closes past a point, or springs back.
    private var grabber: some View {
        Capsule()
            .fill(Color(uiColor: .tertiaryLabel))
            .frame(width: 36, height: 5)
            .padding(.top, 5)
            .frame(width: 120, height: 24, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in drag = max(0, value.translation.height) }
                .onEnded { value in
                    if PageSheetDrag.closes(translation: value.translation.height, predicted: value.predictedEndTranslation.height) {
                        close()
                    } else {
                        withAnimation(DaybookMotion.resolved(DaybookMotion.land, reduceMotion: reduceMotion)) { drag = 0 }
                    }
                })
            .accessibilityHidden(true)
    }
}

/// When a swipe down on a page sheet's grabber closes it, and how much the page behind stays dimmed meanwhile.
enum PageSheetDrag {
    /// Past this far down, or flicked to land past twice it, the sheet closes.
    static let closingDistance: CGFloat = 120

    static func closes(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation >= closingDistance || predicted >= closingDistance * 2
    }

    /// The dimming fades as the card is pulled down, gone by twice the closing distance.
    static func dimming(_ drag: CGFloat) -> Double {
        max(0, 1 - Double(drag) / Double(closingDistance * 2))
    }
}

/// The right page before anything is chosen. In an empty library the left page already says what
/// to do, so this page shows only the mark.
private struct NotebookPlaceholder: View {
    let isEmpty: Bool
    var body: some View {
        VStack(spacing: PhoneStyle.Space.s3) {
            Image(systemName: "book.pages")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(PhoneStyle.brandGradient)
                .accessibilityHidden(true)
            if !isEmpty {
                Text("Choose a Conversation")
                    .font(PhoneStyle.Typeface.title(.title2)).foregroundStyle(PhoneStyle.Ink.title)
                    .multilineTextAlignment(.center)
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
    let library: LibraryController
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
