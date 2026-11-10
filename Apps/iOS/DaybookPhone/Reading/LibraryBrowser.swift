import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// The library and reading while nothing is being recorded, in one column (pocket) or two pages
/// (notebook). Owned by the library and reading work (docs/iphone.md, phase 2). Its library page places
/// `RecordStartButton` and the status strip and presents `SettingsScreen`; it presents the status sheet.
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
    ReadingLayout(
      style: style, library: model.library.controller, rootURL: model.library.rootURL,
      openLatest: model.options.openLatest
    )
    .environment(\.liveCaptionsSaved, model.captions.lastSave)
    // The player stands aside for a recording however it starts, before anything plays here.
    .onAppear { [model] in session.player.follow { model.isRecordingActive } }
    // Add Recording…: the conversation is the session's until the picker answers, so the picker closing
    // first doesn't lose the files.
    .fileImporter(
      isPresented: Bindable(session).showsRecordingPicker,
      allowedContentTypes: RecordStartButton.audioTypes, allowsMultipleSelection: true
    ) { result in
      guard let picked = session.pickedRecordings(result) else { return }
      Task { await model.importFiles(picked.urls, attachTo: picked.conversation) }
    } onCancellation: {
      _ = session.pickedRecordings(.success([]))
    }
  }
}

private struct ReadingLayout: View {
  let style: SurfaceStyle
  let library: LibraryController
  let rootURL: URL
  let openLatest: Bool
  @Environment(ReadingSession.self) private var session
  @Environment(\.audioProvider) private var provider
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    // One column presents a sheet; two pages show it as a card on the right page instead (`PageCard`), so nothing
    // sits across the crease and the left page stays in reach. The share sheet is always the system's.
    .sheet(item: Binding(get: { sheetOnPage ? nil : session.sheet }, set: { session.sheet = $0 })) {
      sheet in
      ReadingSheetContent(sheet: sheet, library: library)
        .environment(session)
        .tint(PhoneStyle.accent)
    }
    // Today's status, in the hand a sheet, open on the right page; the library's strip and More ask for it.
    .statusSheet(onPage: style != .pocket)
    .fullScreenCover(
      isPresented: Binding(
        get: { session.cameraFor != nil }, set: { if !$0 { session.cameraFor = nil } })
    ) {
      if let id = session.cameraFor {
        CameraPicker(
          capture: { photo in addPhoto(photo, to: id) }, finish: { session.cameraFor = nil },
          failed: {
            session.alert = ReadingAlert(title: "Couldn’t Save Photo", message: "Take it again.")
          }
        )
        .ignoresSafeArea()
      }
    }
    .alert(
      session.alert?.title ?? "",
      isPresented: Binding(get: { session.alert != nil }, set: { if !$0 { session.alert = nil } }),
      presenting: session.alert
    ) { alert in
      if let details = alert.details {
        Button("Details") { session.sheet = .errorDetails(details) }
      }
      Button("OK", role: .cancel) {}
    } message: { alert in
      Text(alert.message)
    }
    .alert(
      trashTitle,
      isPresented: Binding(
        get: { !session.confirmingTrash.isEmpty }, set: { if !$0 { session.confirmingTrash = [] } })
    ) {
      Button("Move to Trash", role: .destructive) { trash(session.confirmingTrash) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        session.confirmingTrash.count > 1
          ? "Their audio, notes, and summaries go with them."
          : "Its audio, notes, and summary go with it.")
    }
    .onChange(of: library.isLoaded, initial: true) { _, loaded in
      guard loaded else { return }
      #if DEBUG
        DemoLibrary.seed(library, rootURL: rootURL)
      #endif
      session.launch.apply(to: session, library: library, provider: provider)
      if openLatest, session.openID == nil,
        let newest = LibraryPlace.section(.all).meetings(in: library.meetings).first
      {
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
      if session.isSelecting {
        session.isSelecting = false
        session.selection = []
      }
      if !failures.isEmpty {
        session.alert = ReadingAlert(
          title: "Couldn’t Move to Trash",
          message: failures.count == 1
            ? "Try again." : "\(failures.count) conversations weren’t moved. Try again.",
          details: failures.joined(separator: "\n"))
      }
    }
  }

  private func addPhoto(_ photo: CameraPhoto, to id: UUID) {
    Task {
      do { try await library.addCameraPhoto(photo, to: id) } catch {
        session.alert = ReadingAlert(
          title: "Couldn’t Save Photo", error: error, fallback: "Take it again.")
      }
    }
  }

  // MARK: One column

  private var pocket: some View {
    PocketStack(library: library, rootURL: rootURL)
  }

  // MARK: Two pages

  private var notebook: some View {
    CreaseSplit(spineRail: spineRail) {
      leftPage
    } trailing: {
      rightPage
        .accessibilityHidden(sheetOnPage)
        // On the right page, clear of the crease, as its sheets are.
        .confirmationBeat(Bindable(session).confirmation)
        .overlay {
          if sheetOnPage, let sheet = session.sheet {
            PageCard(close: { session.sheet = nil }) {
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

  /// The spine belongs to the conversation spread only, never to its library preview or a sheet.
  /// Observe the loaded track here, but let the spine alone follow the player's changing position.
  private var spineRail: ConversationSpineRail? {
    guard let id = session.spineMeetingID, let meeting = library.meeting(id) else { return nil }
    let player = session.player
    let active: ConversationSpineRailData.Player?
    if player.phase == .ready, let meetingID = player.meetingID, let trackID = player.trackID {
      active = .init(meetingID: meetingID, trackID: trackID, duration: player.duration)
    } else {
      active = nil
    }
    guard let data = ConversationSpineRailData(meeting: meeting, player: active) else { return nil }
    return ConversationSpineRail(data: data, player: active?.meetingID == id ? player : nil)
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
              Button {
                session.closeConversation()
              } label: {
                Label("Library", systemImage: "chevron.backward")
              }
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
      NavigationStack {
        TrashedPage(library: library, id: session.trashedID)
          .navigationBarTitleDisplayMode(.inline)
      }
      .transition(.opacity)
    } else if let id = session.openID, let meeting = library.meeting(id) {
      if session.reading {
        NavigationStack {
          PhoneTranscriptPage(
            library: library, player: session.player, meeting: meeting, showsHeader: false
          )
          // A bar, so the transcript under the player fades hard rather than reading sharp beneath it.
          .scrollEdgeEffectStyle(
            session.player.isActive(for: meeting.id) ? .hard : nil, for: .bottom
          )
          .safeAreaBar(edge: .bottom, spacing: 0) {
            ConversationPlayer(library: library, meeting: meeting)
          }
          .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.isTwoPage, true)
        .transition(pageTurn(from: .trailing))
      } else {
        NavigationStack {
          SummaryPage(library: library, meeting: meeting)
            .safeAreaBar(edge: .bottom, spacing: 0) {
              ConversationPlayer(library: library, meeting: meeting)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              // The way across both pages (a second tap on the row is the other), in the trailing group with Info and
              // More, no louder than they are: its word beside the open book where the bar has room; on the Duo, whose
              // bar items stand in the status bar's column, the glyph, with "Open" for VoiceOver.
              ToolbarItem(placement: .topBarTrailing) {
                Button {
                  session.open(id)
                } label: {
                  Label("Open", systemImage: "book.pages").labelStyle(.titleAndIcon)
                }
                .tint(PhoneStyle.Ink.title)
                .accessibilityHint("Opens it across both pages")
              }
              ConversationToolbar(library: library, meeting: meeting)
            }
        }
        .id(id)
        .transition(.opacity)
      }
    } else {
      NotebookPlaceholder(isEmpty: library.isLoaded && library.meetings.isEmpty)
    }
  }

  /// The left page lists the Trash (the conversations' spread isn't open, nor search), so the right page shows
  /// what's in it.
  private var showsTrash: Bool {
    let spread = session.reading && session.openID.flatMap { library.meeting($0) } != nil
    return !spread && session.place.isTrash && !session.isSearching
  }

  private func pageTurn(from edge: Edge) -> AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(insertion: .move(edge: edge).combined(with: .opacity), removal: .opacity)
  }

  /// Carries the reading position across a fold (see `ReadingSession`).
  private func adapt(to style: SurfaceStyle) {
    session.isNotebook = style != .pocket
    guard library.isLoaded else { return }
    if style == .pocket {
      // The conversation the person chose on the right page stays open in one column.
      if !session.reading, session.chosen, session.openID != nil, !session.isSelecting {
        session.reading = true
      }
    } else {
      session.showNewest(of: library.meetings)
    }
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
