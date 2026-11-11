import DaybookCaptions
import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI

// The status sheet (docs/iphone.md, "Status sheet"): the recorders, the Macs, this iPhone's own work, and iCloud, standing
// at the foot of the library like Maps' sheet. At rest it's minimized, and small: Record, Import, and Search at the
// thumb, under the grabber, and under them the one line with something to say, if any. Dragged up it expands to the
// overview both apps share (DaybookUI's `StatusOverview`): the lines and a group and a card for each kind of device,
// then what can be done with them. Where it stands is `StatusSheetModel.placement`:
//
// - In one column (closed, or an iPhone 18 Pro upright): the system's sheet over the library, minimized, medium, and
//   large, dragged between them (`StatusSheetHost`).
// - On two pages (open, partly open in the library, or an iPhone on its side), and in one column turned on its side:
//   the same sheet minimized, drawn at the foot of the library's page (`StatusSheetFoot`); dragged up, the rest opens as
//   a card on the right page (`PageCard`), clear of the crease, the left page in reach.
// - Over a conversation, search, selection, or the Trash: none. Asked for there (More › Devices, a recorder's
//   notification), it's an ordinary sheet in one column and the card on two pages.
// - Recording: none. `RecordingSurface` replaces the library and shows the recorder's essentials.

/// A request to show more of the status: at a size, at a screen inside it (a recorder's page, Settings › iCloud), or
/// scrolled to the group that says how to fix a line.
struct StatusRequest: Identifiable, Equatable {
  var id = UUID()
  var detent: StatusDetent = .medium
  var route: SettingsRoute?
  var fix: StatusSection?

  init(detent: StatusDetent = .medium, route: SettingsRoute? = nil, fix: StatusSection? = nil) {
    self.detent = route == nil ? detent : .large
    self.route = route
    self.fix = fix
  }

  /// What tapping a line asks for: the screen that fixes it, the group that says how, or more of the sheet.
  init(_ route: StatusLineRoute) {
    switch route {
    case .showMore: self.init()
    case .showFix(let section): self.init(fix: section)
    case .open(let screen): self.init(route: screen)
    }
  }
}

/// Shows more of the status: the foot's lines and grabber, and the library's More › Devices, ask for it
/// (`\.showStatus`).
struct ShowStatusAction {
  let show: @MainActor (StatusRequest) -> Void

  @MainActor func callAsFunction(_ request: StatusRequest) { show(request) }
}

extension EnvironmentValues {
  @Entry var showStatus = ShowStatusAction { _ in }
  /// Set while the standing sheet stands over the library in one column: the room it takes minimized above the
  /// home indicator, which the list leaves free so its last rows scroll clear of it.
  @Entry var statusSheetInset: CGFloat? = nil
}

// MARK: Minimized

/// The minimized size (`StatusDetent.compact`): small, the grabber's room, a notice over Record when there's one, the
/// Record, Import, and Search row at a toolbar's size, and under it the one line with something to say while there's
/// one, measured from the fonts the person uses so nothing is cut off. With nothing to say, it's the row alone; never a
/// share of the screen.
enum StatusCompactDetent {
  /// Room above Record, so the sheet's grabber sits clear of it.
  static let recordTop: CGFloat = 18
  /// Room between Record and the lines, once it's dragged up.
  static let recordGap: CGFloat = DaybookSpacing.s4
  /// Room under the row (or the line), above the sheet's own bottom margin.
  static let bottomRoom: CGFloat = DaybookSpacing.s3
  /// The shortest the system's sheet is drawn as a sheet: below about 100 pt, iOS 26 floats it as a capsule inset from
  /// the edges and the home indicator, a tight band the row overflows (98 pt was a capsule and 106 pt a sheet on the
  /// 18 Pro, iOS 27.1; the Duo's cover draws 110 pt as a sheet too). The row alone is shorter, so minimized it takes
  /// this.
  static let sheetMinimum: CGFloat = 110
  /// Each control's height: a toolbar button's touch target.
  static let control: CGFloat = 44
  /// The largest text size the row takes: beyond it, Record's label would break mid-word beside the round buttons.
  /// The row is a control bar, with the large content viewer past it.
  static let recordLargestSize = DynamicTypeSize.accessibility1

  static func lineHeight(_ style: UIFont.TextStyle, at size: DynamicTypeSize) -> CGFloat {
    let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
    return ceil(UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).lineHeight)
  }

  /// The row: each control is 44 pt, taller when Record's label grows; the glass adds 4 pt each side.
  static func rowHeight(at size: DynamicTypeSize) -> CGFloat {
    max(control, lineHeight(.body, at: min(size, recordLargestSize)) + 8) + 8
  }

  /// A notice over Record (`RecordStartNotices`: "Importing 2 recordings…"): two lines and the gap under them.
  static func noticeHeight(at size: DynamicTypeSize) -> CGFloat {
    2 * lineHeight(.footnote, at: min(size, recordLargestSize)) + DaybookSpacing.s2
  }

  /// The line under the row (`StatusLineView`): one row of subheadline, or at the accessibility sizes its title and
  /// words sharing `StatusMetrics.stackedRows`, and room for the progress line under it while work runs.
  static func lineHeight(at size: DynamicTypeSize) -> CGFloat {
    let row = lineHeight(.subheadline, at: size)
    let text = size.isAccessibilitySize ? CGFloat(StatusMetrics.stackedRows) * row + 2 : row
    return text + 6
  }

  static func height(for size: DynamicTypeSize, maximum: CGFloat, notice: Bool = false, line: Bool = false) -> CGFloat {
    let notice = notice ? noticeHeight(at: size) : 0
    let line = line ? recordGap + lineHeight(at: size) : 0
    return min(maximum * 0.55, max(sheetMinimum, recordTop + notice + rowHeight(at: size) + line + bottomRoom))
  }
}

// MARK: Standing

extension View {
  /// The status sheet: standing over the library in one column, at the foot of the library's page on two pages
  /// (`LibraryPage` draws `StatusSheetFoot` there), and shown when asked for (`\.showStatus`): in the standing sheet
  /// while it stands, else an ordinary sheet in one column and a card on the right page on two (`PageCard`). A fold
  /// shows a request again the other way.
  func statusSheet(onPage: Bool) -> some View {
    modifier(StatusSheetHost(onPage: onPage))
  }
}

/// Presents the standing sheet over the one-column library while it's the thing on screen (`StatusSheetModel.placement`),
/// minimized, then medium and large as it's dragged up: the list stays usable up through medium, and it can't be swiped
/// away. Other sheets and alerts (Settings, Move, Tags) open above it, as they do over Maps' sheet. Back from a
/// conversation or search it's minimized again.
struct StatusSheetHost: ViewModifier {
  let onPage: Bool
  @Environment(PhoneAppModel.self) private var model
  @Environment(ReadingSession.self) private var session
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.verticalSizeClass) private var heightClass
  /// Its size, what it was last asked to show, and a request shown on its own.
  @State private var state = StatusSheetState()
  @State private var shownOnPage: Bool?
  @State private var requestDetent: PresentationDetent = .medium
  /// The window's height, which compact's cap is a share of.
  @State private var windowHeight: CGFloat = 874
  @State private var appliedLaunch = false
  /// A debug launch's request (`showRequestedAtLaunch`), shown once it's set.
  @State private var launchRequest: StatusRequest?

  private var placement: StatusSheetModel.Placement {
    StatusSheetModel.placement(
      twoPages: onPage, compactHeight: heightClass == .compact, reading: session.reading,
      searching: session.isSearchPresented, selecting: session.isSelecting, inTrash: session.place.isTrash)
  }

  /// The standing sheet stands: in one column, and nothing else of the status's is showing.
  private var stands: Bool { placement == .sheet && state.request == nil }

  /// What the minimized sheet makes room for: the row, a notice over Record while there's one, and the line with
  /// something to say while there's one.
  private var compactHeight: CGFloat {
    StatusCompactDetent.height(
      for: typeSize, maximum: windowHeight, notice: RecordStartNotices.isShowing(model),
      line: StatusCompactLine.shown(model) != nil)
  }

  func body(content: Content) -> some View {
    let onPage = shownOnPage ?? self.onPage
    let stands = stands
    let compact = PresentationDetent.height(compactHeight)
    content
      .environment(\.showStatus, ShowStatusAction { show($0) })
      // The list leaves the minimized sheet's room free above the home indicator (34 pt, which the list's own inset
      // has).
      .environment(\.statusSheetInset, stands ? max(0, compactHeight - 34) : nil)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
      .sheet(isPresented: Binding(get: { stands }, set: { _ in })) {
        StatusSheetView(request: state.asked, detent: $state.size, standing: true)
          .environment(model)
          .environment(session)
          .presentationDetents(
            [compact, .medium, .large],
            selection: Binding(
              get: { state.size == .large ? .large : state.size == .medium ? .medium : compact },
              set: { state.size = $0 == .large ? .large : $0 == .medium ? .medium : .compact })
          )
          .presentationBackgroundInteraction(.enabled(upThrough: .medium))
          .presentationContentInteraction(.resizes)
          .presentationDragIndicator(.visible)
          .interactiveDismissDisabled()
          .tint(DaybookPalette.accent)
          .background(StandingSheetEdge().frame(width: 0, height: 0).accessibilityHidden(true))
      }
      // Turned on its side, the sheet gives way to the foot without sliding away (it fades with the turn,
      // `StandingSheetEdge`); back upright it's there at once, minimized.
      .transaction(value: heightClass) { $0.disablesAnimations = true }
      // Asked for while the sheet doesn't stand: in one column an ordinary sheet.
      .sheet(item: Binding(get: { onPage ? nil : state.request }, set: { state.request = $0 })) { request in
        StatusSheetView(
          request: request,
          detent: Binding(
            get: { requestDetent == .large ? .large : .medium },
            set: { requestDetent = $0 == .large ? .large : .medium })
        )
        .environment(model)
        .environment(session)
        .presentationDetents([.medium, .large], selection: $requestDetent)
        .presentationDragIndicator(.visible)
        .tint(DaybookPalette.accent)
      }
      .overlay {
        if onPage, let shown = state.request {
          // A page is tall enough for the cards with what can be done.
          CreaseSplit {
            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
          } trailing: {
            PageCard(close: { state.request = nil }) {
              StatusSheetView(request: shown, detent: .constant(.large))
                .environment(\.closePageSheet) { state.request = nil }
            }
            .id(shown.id)
          }
          .daybookTransition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .daybookMotion(DaybookMotion.state, value: onPage ? state.request?.id : nil)
      .onChange(of: state.request?.id) { _, id in shownOnPage = id == nil ? nil : self.onPage }
      // Folded or opened while it shows: the same request, shown the other way.
      .onChange(of: self.onPage) { _, now in if state.request != nil { shownOnPage = now } }
      // Back from a conversation or search: minimized again, not wherever it was left.
      .onChange(of: stands) { _, stands in
        if !stands { state.stepAside() }
      }
      // A recorder's notification (imported, almost full) opens its page here, where recorders' pages are.
      .onChange(of: model.destination, initial: true) { _, destination in
        guard let destination, case .device(let id) = destination.destination,
          model.devices.sessions.contains(where: { $0.id == id })
        else { return }
        show(StatusRequest(route: .device(id)))
        model.reached(destination)
      }
      .task { await showRequestedAtLaunch() }
      .onChange(of: launchRequest) { _, next in
        guard let next else { return }
        launchRequest = nil
        show(next)
      }
  }

  /// In the standing sheet while it stands, at the request's size; else on its own.
  private func show(_ next: StatusRequest) {
    if !stands { requestDetent = next.detent == .large ? .large : .medium }
    state.show(next, standing: stands)
  }

  /// `--status-detent`, `--status-open`, and `--status-choose` (debug): the sheet at a size, at a screen, or as a
  /// line's tap would show it, for screenshots. Handed to `launchRequest`, which shows it from the view as it is then:
  /// this task's copy of the modifier is as it was when it began (upright, say, before `--interface-orientation`).
  private func showRequestedAtLaunch() async {
    guard !appliedLaunch else { return }
    appliedLaunch = true
    let options = model.options
    if let screen = options.statusPage {
      // A recorder the device autopilot is still adding: wait for it to connect and import.
      for _ in 0..<150 where screen == .device && model.devices.sessions.first?.links.recent.isEmpty != false {
        try? await Task.sleep(for: .milliseconds(100))
      }
      try? await Task.sleep(for: .milliseconds(800))
      switch screen {
      case .device:
        if let session = model.devices.sessions.first { launchRequest = StatusRequest(route: .device(session.id)) }
      case .mac: if let mac = model.link.macs.first { launchRequest = StatusRequest(route: .mac(mac.id)) }
      case .storage: launchRequest = StatusRequest(route: .storage)
      case .icloud: launchRequest = StatusRequest(route: .icloud)
      case .addRecorder: launchRequest = StatusRequest(route: .addRecorder)
      }
    } else if let detent = options.statusDetent, detent != .compact {
      // With `--interface-orientation`, once the library has turned, where it shows.
      let turns = LaunchOptions.value(after: "--interface-orientation", in: CommandLine.arguments) != nil
      try? await Task.sleep(for: .milliseconds(turns ? 4_500 : 700))
      launchRequest = StatusRequest(detent: detent)
    } else if let id = options.statusChoose {
      try? await Task.sleep(for: .milliseconds(1_500))
      let inputs = StatusSheetInputs.make(model, library: model.library.controller)
      guard let line = StatusOverviewModel.lines(inputs).first(where: { $0.id == id || $0.id.hasPrefix(id + "-") }) else { return }
      launchRequest = StatusRequest(StatusSheetModel.route(for: line, inputs))
    }
  }
}

/// Hands the standing sheet over to the foot as the iPhone turns on its side. iOS keeps a presented sheet through
/// the turn and lays it out across the whole width, and SwiftUI dismisses it only once the turn is done, so for a
/// moment the row stood across both pages before jumping to the left page's foot. The sheet fades out with the turn
/// instead, as the turn's crossfade brings the foot in, and keeps its detent (attached to the bottom edge) rather
/// than growing to the whole window. Back upright a new sheet stands at once, minimized.
private struct StandingSheetEdge: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> Controller { Controller() }
  func updateUIViewController(_ controller: Controller, context: Context) {}

  final class Controller: UIViewController {
    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      sheetPresentationController?.prefersEdgeAttachedInCompactHeight = true
      sheetPresentationController?.containerView?.alpha = 1
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
      super.viewWillTransition(to: size, with: coordinator)
      coordinator.animate(alongsideTransition: { [weak self] _ in
        guard let self, let window = self.view.window, let container = self.sheetPresentationController?.containerView
        else { return }
        // The window's size once turned: on its side the foot stands instead (`StatusSheetModel.placement`).
        container.alpha = window.bounds.width > window.bounds.height ? 0 : 1
      })
    }
  }
}

// MARK: The foot

/// The standing sheet minimized, drawn at the foot of the library's page where the system's sheet can't stand
/// (`StatusSheetModel.placement`): on two pages, clear of the crease, and in one column on its side. The same grabber,
/// row, and line as the minimized sheet, as small; its grabber or a drag up expands it (on two pages into a card on the
/// right page). It nests no navigation stack of its own, so the page keeps its bar.
struct StatusSheetFoot: View {
  @Environment(PhoneAppModel.self) private var model
  @Environment(\.showStatus) private var showStatus
  @Environment(\.verticalSizeClass) private var heightClass
  @GestureState private var drag: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      grabber
      StatusQuickActions()
      if let shown = StatusCompactLine.shown(model) {
        StatusLines(
          [StatusLineItem(shown.line)], hint: { _ in StatusSheetModel.hint(for: shown.route) },
          choose: { _ in showStatus(StatusRequest(shown.route)) }
        )
        .padding(.top, StatusCompactDetent.recordGap)
        .padding(.bottom, DaybookSpacing.s2)
        // On its side there's little height: at the accessibility sizes the line would stack on four rows and reach
        // the bar, so there it stays one row, cut short at the end; the card it opens says it whole.
        .dynamicTypeSize(heightClass == .compact ? ...DynamicTypeSize.xxxLarge : ...DynamicTypeSize.accessibility5)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, DaybookSpacing.s4)
    .padding(.bottom, StatusCompactDetent.bottomRoom)
    // As a sheet at a small size: glass reaching down past the home indicator to just short of the display's edge,
    // its corners concentric with the display's where they meet it.
    .background {
      Color.clear
        .glassEffect(.regular, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(DaybookRadius.panel)), isUniform: false))
        .padding(.bottom, DaybookSpacing.s2)
        .ignoresSafeArea(.container, edges: .bottom)
    }
    .offset(y: drag < 0 ? max(-24, drag / 3) : 0)
    .gesture(
      DragGesture(minimumDistance: 8)
        .updating($drag) { value, state, _ in state = value.translation.height }
        .onEnded { value in
          if value.translation.height < -30 || value.predictedEndTranslation.height < -90 { showStatus(StatusRequest()) }
        }
    )
    .daybookMotion(DaybookMotion.state, value: drag == 0)
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Show More") { showStatus(StatusRequest()) }
  }

  /// The sheet's grabber, where a sheet's is: a tap or a drag up shows more.
  private var grabber: some View {
    Button {
      showStatus(StatusRequest())
    } label: {
      Capsule()
        .fill(Color(uiColor: .tertiaryLabel))
        .frame(width: 36, height: 5)
        .frame(maxWidth: .infinity, minHeight: StatusCompactDetent.recordTop)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(StatusSheetModel.title)
    .accessibilityHint("Shows more")
  }
}

/// The line the minimized sheet says under the row, and where tapping it leads: the one with something to say
/// (`StatusSheetModel.lines(for: .compact, …)`), or nil, and the sheet is the row alone.
@MainActor
enum StatusCompactLine {
  static func shown(_ model: PhoneAppModel, now: Date = Date()) -> (line: StatusLineWords, route: StatusLineRoute)? {
    let inputs = StatusSheetInputs.make(model, library: model.library.controller)
    guard let line = StatusSheetModel.lines(for: .compact, StatusOverviewModel.lines(inputs, now: now)).first else {
      return nil
    }
    return (line, StatusSheetModel.route(for: line, inputs))
  }
}

// MARK: The row

/// Record, Import, and Search, at the thumb, the standing sheet's first row at every size, at a toolbar's size: Record
/// wide, Import and Search round beside it, one layer of glass (`GlassEffectContainer`), so the three read as one bar.
/// Above them, while there's one, what Record has to say (`RecordStartNotices`). Past `recordLargestSize` the row stops
/// growing and each control shows the large content viewer.
struct StatusQuickActions: View {
  @Environment(PhoneAppModel.self) private var model
  @Environment(ReadingSession.self) private var session
  @State private var importing = false

  /// One gap for Record–Import and Import–Search.
  static let spacing = DaybookSpacing.s2

  var body: some View {
    VStack(spacing: DaybookSpacing.s2) {
      if RecordStartNotices.isShowing(model) {
        RecordStartNotices().transition(.opacity)
      }
      GlassEffectContainer(spacing: DaybookSpacing.s3) {
        HStack(alignment: .bottom, spacing: Self.spacing) {
          RecordStartButton()
          Button {
            importing = true
          } label: {
            Image(systemName: "square.and.arrow.down")
              .font(.body.weight(.medium))
              .foregroundStyle(DaybookPalette.Ink.title)
              .frame(width: StatusCompactDetent.control, height: StatusCompactDetent.control)
              .contentShape(Circle())
          }
          .daybookControl(.standard, shape: .circle)
          .accessibilityLabel("Import Audio")
          .accessibilityHint("Adds a recording from Files, such as a voice memo")
          .accessibilityShowsLargeContentViewer()
          Button {
            session.isSearchPresented = true
          } label: {
            Image(systemName: "magnifyingglass")
              .font(.body.weight(.medium))
              .foregroundStyle(DaybookPalette.Ink.title)
              .frame(width: StatusCompactDetent.control, height: StatusCompactDetent.control)
              .contentShape(Circle())
          }
          .daybookControl(.standard, shape: .circle)
          .accessibilityLabel("Search")
          .accessibilityHint("Searches titles, notes, transcripts, and summaries")
          .accessibilityShowsLargeContentViewer()
        }
      }
    }
    .dynamicTypeSize(...StatusCompactDetent.recordLargestSize)
    .daybookMotion(DaybookMotion.state, value: RecordStartNotices.isShowing(model))
    .fileImporter(isPresented: $importing, allowedContentTypes: RecordStartButton.audioTypes, allowsMultipleSelection: true) {
      result in
      guard case .success(let urls) = result else { return }
      Task { await model.importFiles(urls) }
    }
    .task {
      // `--show-importer` (debug): Import Audio's picker at launch, for screenshots.
      guard model.options.showImporter else { return }
      try? await Task.sleep(for: .milliseconds(600))
      importing = true
    }
  }
}

// MARK: The sheet's content

/// The status sheet's content for a size: the standing sheet's (Record, Import, and Search at the top; minimized,
/// the line with something to say, if any; expanded, the lines and the groups), or, shown on its own, the lines and the groups under the title
/// Devices with the system's close button. Its links open the full screens inside it, in its own navigation stack (a
/// device's page, a Mac's, Settings › iCloud, Storage), never copies of them.
struct StatusSheetView: View {
  let request: StatusRequest?
  @Binding var detent: StatusDetent
  /// The standing sheet's: no title, the row and the lines at every size.
  var standing = false
  @Environment(PhoneAppModel.self) private var model
  @State private var path: [SettingsRoute]
  @State private var fix: StatusSection?
  @State private var showingPairing = false
  private let dismiss = SheetDismiss()

  init(request: StatusRequest?, detent: Binding<StatusDetent>, standing: Bool = false) {
    self.request = request
    _detent = detent
    self.standing = standing
    _path = State(initialValue: request?.route.map { [$0] } ?? [])
    _fix = State(initialValue: request?.fix)
  }

  var body: some View {
    NavigationStack(path: $path) {
      StatusSections(
        library: model.library.controller, detent: $detent, standing: standing, fix: $fix, open: open,
        close: { dismiss() }, pair: { showingPairing = true }
      )
      .modifier(StatusSheetTitle(standing: standing, close: { dismiss() }))
      .navigationDestination(for: SettingsRoute.self) { route in SettingsDestination(route: route) }
    }
    .pairingSheet(isPresented: $showingPairing)
    .onChange(of: detent) { _, detent in
      // Collapsing the standing sheet goes back to the overview.
      if standing, detent != .large, !path.isEmpty { path = [] }
    }
    // The standing sheet asked again: at that screen, or that group.
    .onChange(of: request?.id) { _, _ in
      guard let request else { return }
      path = request.route.map { [$0] } ?? []
      fix = request.fix
    }
  }

  /// A full screen opens with the sheet at full height.
  private func open(_ route: SettingsRoute) {
    detent = .large
    path = [route]
  }
}

/// The standing sheet has no bar: its row sits under the grabber, and the sheet's glass shows through. Shown on its
/// own, the sheet is titled Devices, with the system's close button.
private struct StatusSheetTitle: ViewModifier {
  let standing: Bool
  let close: () -> Void

  func body(content: Content) -> some View {
    if standing {
      content
        .toolbar(.hidden, for: .navigationBar)
        .containerBackground(.clear, for: .navigation)
    } else {
      content
        .navigationTitle(StatusSheetModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) { Button(role: .close, action: close).tint(DaybookPalette.Ink.title) }
        }
    }
  }
}

/// The sections for the size. Standing: Record, Import, and Search pinned at the top, clear of the grabber and never
/// scrolled under it; minimized, the line with something to say, if any; dragged up, every line and the groups
/// (`StatusSheetModel.lines`, `StatusSheetModel.groups`). Shown on its own (the card on the right page, a sheet over a conversation): the lines and
/// the groups, without the row.
private struct StatusSections: View {
  let library: LibraryController
  @Binding var detent: StatusDetent
  let standing: Bool
  @Binding var fix: StatusSection?
  let open: (SettingsRoute) -> Void
  let close: () -> Void
  let pair: () -> Void
  @Environment(PhoneAppModel.self) private var model
  @Environment(ReadingSession.self) private var session
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let inputs = StatusSheetInputs.make(model, library: library)
    VStack(spacing: 0) {
      if standing {
        StatusQuickActions()
          .padding(.horizontal, DaybookSpacing.s4)
          .padding(.top, StatusCompactDetent.recordTop)
      }
      ScrollViewReader { proxy in
        ScrollView {
          TimelineView(.periodic(from: .now, by: 30)) { context in
            let all = StatusOverviewModel.lines(inputs, now: context.date)
            // Shown on its own (the card on the right page, a sheet over a conversation) it's never minimized.
            let lines = StatusSheetModel.lines(for: detent, all)
            let groups = StatusSheetModel.groups(for: detent, inputs, now: context.date)
            StatusOverview(
              lines: lines.map { StatusLineItem($0) },
              density: detent.density,
              hint: { item in
                lines.first { $0.id == item.id }.map { StatusSheetModel.hint(for: StatusSheetModel.route(for: $0, inputs)) }
              },
              choose: { item in
                if let line = lines.first(where: { $0.id == item.id }) { choose(line, inputs: inputs) }
              }
            ) {
              ForEach(groups, id: \.self) { section in
                view(for: section, inputs: inputs, now: context.date)
                  .id(section)
                  .transition(.opacity)
              }
            }
            .padding(.horizontal, DaybookSpacing.s4)
            .padding(.top, standing ? (lines.isEmpty && groups.isEmpty ? 0 : StatusCompactDetent.recordGap) : DaybookSpacing.s2)
            .padding(.bottom, DaybookSpacing.s4)
            .animation(reduceMotion ? nil : DaybookMotion.state, value: groups)
          }
        }
        // Minimized holds its line whole; at the accessibility sizes, where the cap can leave a long line less room
        // than it takes, it scrolls rather than running under the home indicator.
        .scrollDisabled(standing && detent == .compact && !typeSize.isAccessibilitySize)
        .scrollBounceBehavior(.basedOnSize)
        // `--status-scroll-end`: the foot of the content, for screenshots.
        .defaultScrollAnchor(model.options.statusScrollEnd ? .bottom : nil)
        .onChange(of: fix, initial: true) { _, fix in
          if fix != nil { reveal(in: proxy) }
        }
      }
    }
    .animation(reduceMotion ? nil : DaybookMotion.state, value: detent)
  }

  /// A line leads to its fix when it needs the person, else to more of the sheet.
  private func choose(_ line: StatusLineWords, inputs: StatusOverviewInputs) {
    switch StatusSheetModel.route(for: line, inputs) {
    case .showMore: if detent == .compact { detent = .medium }
    case .showFix(let section):
      if detent == .compact { detent = .medium }
      fix = section
    case .open(let route): open(route)
    }
  }

  /// The group with a line's fix, scrolled to the top once the sheet has stepped up and the group has laid out.
  private func reveal(in proxy: ScrollViewProxy) {
    guard let section = fix else { return }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(350))
      withAnimation(reduceMotion ? nil : DaybookMotion.state) { proxy.scrollTo(section, anchor: .top) }
      fix = nil
    }
  }

  @ViewBuilder
  private func view(for section: StatusSection, inputs: StatusOverviewInputs, now: Date) -> some View {
    switch section {
    case .lines:
      if let line = StatusOverviewModel.syncLine(inputs) {
        StatusLines(
          [StatusLineItem(line)],
          hint: { _ in StatusSheetModel.hint(for: StatusSheetModel.route(for: line, inputs)) },
          choose: { _ in open(.icloud) })
      }
    case .captions: StatusCaptions()
    case .recorders: StatusRecorders(detent: detent, open: open)
    case .macs:
      StatusMacs(
        inputs: inputs, now: now, open: open, pair: pair, openConversation: openConversation,
        perform: perform)
    case .iphone:
      StatusThisIPhone(
        entries: inputs.localQueue, now: now, open: open, openConversation: openConversation,
        perform: perform)
    }
  }

  /// A queued conversation opens on its page: the standing sheet minimizes behind it, and one shown on its
  /// own goes.
  private func openConversation(_ id: UUID) {
    if standing { detent = .compact } else { close() }
    session.open(id)
  }

  /// What a queued conversation offers: where its summary runs, or Try Again, as its page does.
  private func perform(_ action: StatusQueueItem.Action, for id: UUID) {
    switch action {
    case .placement(let choice): model.placement.perform(choice, for: id)
    case .tryAgain(.summaryOnly): library.summarize(id, placement: model.placement)
    case .tryAgain(let mode): library.requestProcessing(id, mode: mode)
    }
  }
}

/// The iPhone's gatherer: the overview's facts (DaybookKit's `StatusOverviewInputs`, the Mac's gathered by
/// `StatusOverviewInputs.make`), from the app model. What each says is `StatusOverviewModel`'s.
@MainActor
enum StatusSheetInputs {
  static func make(_ model: PhoneAppModel, library: LibraryController) -> StatusOverviewInputs {
    let devices = model.devices
    let words = DeviceWords.iPhone(id: library.thisDevice.id)
    var inputs = StatusOverviewInputs(words: words)
    inputs.recording.recorders = devices.sessions.map { lineRecorder($0, model: model) }
    inputs.mac = model.macPresence
    inputs.liveProgress = model.liveProgress.values.sorted { $0.receivedAt > $1.receivedAt }
    inputs.queue = StatusOverviewModel.queue(
      meetings: library.meetings, liveProgress: model.liveProgress, words: words,
      planners: model.placement.planners, runs: model.placement.runs,
      cloudOffered: model.placement.cloudOffer != nil)
    let work = localWork(model, library: library)
    inputs.local = work.line
    inputs.localQueue = work.entries
    sync(model.sync, into: &inputs)
    inputs.hasLiveCaptions = devices.sessions.contains { $0.isListeningLive }
    inputs.pairedMacs = model.link.macs.map { mac in
      StatusOverviewInputs.Mac(
        id: mac.id, name: mac.name, line: macLine(mac, model: model), isConnected: mac.isConnected,
        notProcessing: mac.isConnected && !mac.canProcess,
        isRecording: mac.isRecording || model.isRecordingBySync(mac), problem: mac.problem != nil)
    }
    return inputs
  }

  /// iCloud's line: where sync stands in Settings' words, the reason in a few words when iCloud can't be
  /// used ("Signed out", narrowed to "Off"), and what needs the person in warning ink: a pass that failed,
  /// the library's key not here, iCloud full, or an older Daybook app syncing as this iPhone.
  static func sync(_ sync: PhoneSync, into inputs: inout StatusOverviewInputs) {
    inputs.syncLine = sync.statusLine
    switch sync.connection {
    case .checking: inputs.syncTone = .checking
    case .unavailable where sync.iCloud == .accountChanged:
      // Paused for the person, not off: Settings › iCloud offers Sync with This Account.
      inputs.syncTone = .attention
      inputs.syncLine = SyncStatus.accountChanged.shortText
    case .unavailable(let reason):
      inputs.syncTone = .attention
      inputs.syncOff = true
      inputs.syncLine = StatusSheetModel.unavailablePhrase(reason)
      inputs.syncShort = "Off"
    case .connected:
      let full = sync.isStorageFull
      let olderApp = sync.controller?.warning == .otherInstallation
      if full { inputs.syncLine = SyncStatus.storageFull.shortText }
      if olderApp, !full, sync.lastError == nil { inputs.syncLine = "Older Daybook app installed" }
      inputs.syncTone =
        sync.lastError != nil || full || olderApp || sync.encryption == .waitingForKey
        ? .attention
        : sync.isUpToDate ? .upToDate : .working
    }
  }

  /// A paired Mac's row: recording, or what its link is doing, from the link; away, when it was last seen,
  /// by the link or the library's sync, whichever is newer, as every device's absence is dated.
  static func macLine(_ mac: PhoneLink.Mac, model: PhoneAppModel, now: Date = Date()) -> String {
    let recordingBySync = model.isRecordingBySync(mac, now: now)
    guard !mac.isRecording, !recordingBySync else {
      return mac.rowLine(recordingBySync: recordingBySync)
    }
    switch mac.state {
    case .idle, .suspended:
      let synced = model.sync.devices.first { $0.id == (mac.syncDeviceID ?? mac.id.uuidString) }?
        .lastSeen
      let seen = [mac.lastConnectedAt, synced].compactMap { $0 }.max()
      return seen.map { RecorderStatusWords.lastSeen($0, now: now) } ?? "Not connected"
    default:
      return mac.rowLine(recordingBySync: false)
    }
  }

  /// This iPhone's own work: its processor's queue, and summaries counting down to it or running in the cloud.
  static func localWork(_ model: PhoneAppModel, library: LibraryController, now: Date = Date())
    -> StatusOverviewModel.LocalWork
  {
    let processor = model.processor
    var work = StatusOverviewModel.localWork(
      meetings: library.meetings, local: { processor.queue(for: $0, at: now) },
      pause: processor.pause.map(pauseReason), words: .iPhone(id: library.thisDevice.id),
      planners: model.placement.planners, runs: model.placement.runs, now: now)
    #if DEBUG
      StatusSheetDemo.adjust(&work, meetings: library.meetings)
    #endif
    return work
  }

  /// Why this iPhone's work waits, in the words both apps use for it.
  static func pauseReason(_ pause: PhoneProcessor.Pause) -> ProcessingWords.PauseReason {
    switch pause {
    case .recording: return .recording
    case .background, .locked: return .background
    case .heat: return .heat
    case .lowPowerMode: return .lowPowerMode
    case .lowBattery: return .lowBattery
    }
  }

  /// One recorder's facts for its line: `recorder(_:model:)`'s, and what its words need besides.
  static func lineRecorder(_ session: DeviceSession, model: PhoneAppModel) -> RecorderFacts {
    var recorder = recorder(session, model: model)
    let facts = RecorderFacts(session: session)
    recorder.recordCommandPending = facts.recordCommandPending
    recorder.recordingAsOf = facts.recordingAsOf
    recorder.folder = facts.folder
    return recorder
  }

  /// One recorder's facts, for its card: what its page offers (`RecorderActions`) and its room.
  static func recorder(_ session: DeviceSession, model: PhoneAppModel) -> RecorderFacts {
    let control = session.direct as? any RecordControlConnection
    var recorder = RecorderFacts(
      id: session.id, name: session.device.name, shortName: session.kind.shortName,
      symbol: session.kind.systemImage, isDirect: session.direct != nil, state: session.state,
      isLinked: session.isLinked)
    recorder.batteryLevel = session.status?.battery?.level
    recorder.batteryCharging = session.status?.battery?.charging == true
    recorder.newCount = session.managedElsewhere == nil ? session.newRecordings.count : 0
    if session.queue.isActive {
      recorder.importing = .init(
        position: session.queue.position, total: session.queue.total,
        fraction: session.importProgress, suspended: session.queue.isSuspended,
        running: session.queue.current != nil)
    }
    recorder.managedBy = session.managedElsewhere?.ownerName
    recorder.lastKnown = StatusSheetInputs.lastKnown(session, link: model.link)
    recorder.handoff = model.devices.handoffState(session)
    recorder.isRecording = session.isLinked && session.status?.isRecording == true
    recorder.isListeningLive = session.isListeningLive
    recorder.problem = session.problem.map { RecorderStatusWords.problem($0, on: .iPhone).title }
    recorder.lastConnected = session.direct?.lastConnectedAt ?? session.primary?.lastConnectedAt
    recorder.storageHours = session.status?.storage?.hoursLeft
    recorder.storageIsLow = session.status?.storage.map(StorageFormat.isLow) ?? false
    recorder.hasRecordControl =
      control != nil && session.direct?.capabilities.contains(.recordControl) == true
    recorder.hasLiveListening = session.direct is any LiveListeningConnection
    recorder.canConnect = RecorderFacts.canConnect(session)
    recorder.notListed = session.managedElsewhere == nil && session.listingState == .notListed
    recorder.otherAppWait = session.otherAppWait
    recorder.fastTransfer = session.fastTransferStage
    return recorder
  }

  /// A recorder that isn't live here: what the Mac managing it last said, or its last state here.
  static func lastKnown(_ session: DeviceSession, link: PhoneLink, now: Date = Date()) -> String? {
    guard !session.isLinked else { return nil }
    if session.managedElsewhere != nil {
      return link.recorderReport(kind: session.kind.id, serial: session.recorderSerial, now: now)?
        .state.summary(now: now)
    }
    return LinkRecorderState(session: session)?.summary(now: now)
  }
}

// MARK: Cards

/// The glyph column of a card's rows at the person's text size: a card tile's side (DaybookDesign's
/// `StatusRow` uses the same), so a device's glyph lines up with the rows under it.
private struct CardGlyphColumn: DynamicProperty {
  @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
  var value: CGFloat { DaybookTileSize.card.side(scale: scale) }
}

/// An action row's symbol, in the link's ink and the tile's size so its text lines up.
struct StatusLinkGlyph: View {
  let systemImage: String
  var body: some View {
    Image(systemName: systemImage)
      .font(.body.weight(.medium))
      .foregroundStyle(DaybookPalette.Ink.link)
      .accessibilityHidden(true)
  }
}

/// A device's name and its status, the top of a row.
struct StatusRowTitle<Subtitle: View>: View {
  let title: String
  @ViewBuilder var subtitle: Subtitle

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.wrappingAsName)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(DaybookPalette.Ink.title)
        .fixedSize(horizontal: false, vertical: true)
      subtitle
        .font(.footnote)
        .foregroundStyle(DaybookPalette.Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Where a row leads.
struct StatusChevron: View {
  var body: some View {
    Image(systemName: "chevron.forward")
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.tertiary)
      .accessibilityHidden(true)
  }
}

/// A whole row as a button: it dims while pressed, as a list row does.
struct StatusRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Color.primary.opacity(0.06) : .clear)
  }
}

// MARK: Recorders

/// A card per recorder added (the group shows only while there's one; Add Recorder… is in Settings).
private struct StatusRecorders: View {
  let detent: StatusDetent
  let open: (SettingsRoute) -> Void
  @Environment(PhoneAppModel.self) private var model

  var body: some View {
    StatusGroup(title: "Recorders") {
      VStack(spacing: DaybookSpacing.s3) {
        ForEach(model.devices.sessions) { session in
          StatusRecorderCard(session: session, detent: detent, open: open)
        }
      }
    }
  }
}

/// One recorder: its name and status (opening its page), its handoff, and at the large detent its
/// storage, its actions, and the recordings waiting on it.
private struct StatusRecorderCard: View {
  let session: DeviceSession
  let detent: StatusDetent
  let open: (SettingsRoute) -> Void
  @Environment(PhoneAppModel.self) private var model
  private let glyph = CardGlyphColumn()

  var body: some View {
    let recorder = StatusSheetInputs.recorder(session, model: model)
    let manages = StatusSheetModel.showsManagement(detent)
    let actions = manages ? StatusOverviewModel.actions(for: recorder) : []
    let waiting =
      manages && session.managedElsewhere == nil ? Array(session.newRecordings.prefix(4)) : []
    StatusCard {
      Button {
        open(.device(session.id))
      } label: {
        StatusRow {
          DeviceGlyph(session: session).frame(width: glyph.value)
        } content: {
          HStack(spacing: DaybookSpacing.s2) {
            StatusRowTitle(title: session.device.name) {
              status(storage: manages ? recorder.storageHours : nil, low: recorder.storageIsLow)
            }
            Spacer(minLength: 0)
            StatusChevron()
          }
        }
      }
      .buttonStyle(StatusRowButtonStyle())
      .accessibilityHint("Shows \(session.device.name)")

      if RecorderHandoffCard.shows(session, devices: model.devices) {
        RecorderHandoffCard(session: session)
      }
      if !actions.isEmpty {
        StatusRecorderActions(session: session, actions: actions)
      }
      ForEach(waiting) { recording in
        StatusRow {
          HStack(spacing: DaybookSpacing.s2) {
            VStack(alignment: .leading, spacing: 2) {
              Text(recording.title).font(.subheadline).foregroundStyle(DaybookPalette.Ink.body)
              Text(recording.detail).font(.footnote).foregroundStyle(DaybookPalette.Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if session.isConnected {
              Button {
                session.importRecordings([recording])
              } label: {
                Text("Import")
                  .font(.footnote.weight(.semibold))
                  // On the accent wash, the ink that keeps 4.5:1 there.
                  .foregroundStyle(DaybookPalette.Ink.onWash)
                  .padding(.horizontal, DaybookSpacing.s3)
                  .padding(.vertical, 5)
                  .background(DaybookPalette.accent.opacity(0.12), in: Capsule())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Import \(recording.title)")
            }
          }
        }
      }
      if !waiting.isEmpty {
        Button {
          open(.device(session.id))
        } label: {
          StatusRow {
            HStack {
              Text("All Recordings").font(.subheadline.weight(.medium)).foregroundStyle(
                DaybookPalette.Ink.link)
              Spacer(minLength: 0)
              StatusChevron()
            }
          }
        }
        .buttonStyle(StatusRowButtonStyle())
      }
    }
  }

  /// "Connected · 80%" in the words both apps give a recorder (`RecorderStatusWords`), and at the large
  /// detent its room: "About 2,170 hours left" (orange when low), on the same line when it fits.
  @ViewBuilder
  private func status(storage hours: Double?, low: Bool) -> some View {
    let line = StatusOverviewModel.recorderLine(
      StatusSheetInputs.lineRecorder(session, model: model), here: PhoneSummaryPlacement.thisDeviceWords
    )
    .text.keepingSeparators
    if let hours {
      let storage = Text(StatusOverviewModel.storageLeft(hours: hours))
        .foregroundStyle(low ? DaybookPalette.Ink.warning : DaybookPalette.Ink.secondary)
      ViewThatFits(in: .horizontal) {
        Text("\(line) · \(storage)").lineLimit(1)
        VStack(alignment: .leading, spacing: 2) {
          Text(line)
          storage
        }
      }
    } else {
      Text(line)
    }
  }
}

/// The recorder's actions as one row of equal-width buttons (stacked at the accessibility sizes).
struct StatusRecorderActions: View {
  let session: DeviceSession
  let actions: [StatusRecorderAction]
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let stacked = typeSize.isAccessibilitySize
    let layout =
      stacked
      ? AnyLayout(VStackLayout(spacing: DaybookSpacing.s2))
      : AnyLayout(HStackLayout(spacing: DaybookSpacing.s2))
    layout {
      ForEach(actions, id: \.self) { action in
        button(action, stacked: stacked)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(StatusCardMetrics.padding)
  }

  @ViewBuilder
  private func button(_ action: StatusRecorderAction, stacked: Bool) -> some View {
    let control = session.direct as? any RecordControlConnection
    let live = session.direct as? any LiveListeningConnection
    let short = session.kind.shortName
    switch action {
    case .connect:
      ActionTile(
        title: "Connect", systemImage: "antenna.radiowaves.left.and.right", stacked: stacked
      ) { session.connect() }
    case .record:
      ActionTile(
        title: "Record on \(short)", shortTitle: "Record", systemImage: "record.circle",
        stacked: stacked,
        pending: control?.recordCommandPending == true
      ) { control?.startRecording() }
    case .pause:
      ActionTile(
        title: "Pause on \(short)", shortTitle: "Pause", systemImage: "pause.circle",
        stacked: stacked,
        pending: control?.recordCommandPending == true, spoken: "Pause Recording on \(short)"
      ) { control?.pauseRecording() }
    case .importNew(let count):
      ActionTile(
        title: "Import \(count) New", systemImage: "arrow.down.circle", stacked: stacked,
        spoken: count == 1 ? "Import 1 New Recording" : "Import \(count) New Recordings"
      ) {
        session.importRecordings(session.newRecordings)
      }
    case .checkForNew:
      ActionTile(
        title: "Check for New Recordings", shortTitle: "Check for New",
        systemImage: "arrow.clockwise",
        stacked: stacked
      ) {
        session.direct?.refresh()
      }
    case .listenLive:
      ActionTile(title: "Listen Live", systemImage: "ear", stacked: stacked) {
        live?.startListening()
      }
    case .stopListening:
      ActionTile(title: "Stop Listening", systemImage: "stop.circle", stacked: stacked) {
        live?.stopListening()
      }
    }
  }
}

/// One of a recorder's actions: its symbol over its name, in an equal share of the row.
private struct ActionTile: View {
  let title: String
  var shortTitle: String?
  let systemImage: String
  let stacked: Bool
  var pending = false
  /// What VoiceOver says, when it's more than the title.
  var spoken: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Group {
        if stacked {
          HStack(spacing: DaybookSpacing.s3) {
            symbol
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, DaybookSpacing.s3)
        } else {
          VStack(spacing: DaybookSpacing.s1) {
            symbol
            ViewThatFits(in: .horizontal) {
              Text(title).lineLimit(1)
              if let shortTitle { Text(shortTitle).lineLimit(1) }
              Text(shortTitle ?? title).multilineTextAlignment(.center).fixedSize(
                horizontal: false, vertical: true)
            }
          }
          .padding(.horizontal, DaybookSpacing.s1)
        }
      }
      .font(.footnote.weight(.semibold))
      // On the accent wash, the ink that keeps 4.5:1 there (link ink falls under it).
      .foregroundStyle(DaybookPalette.Ink.onWash)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.vertical, DaybookSpacing.s2 + 2)
      .background(
        DaybookPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(ActionTileStyle())
    .disabled(pending)
    .accessibilityLabel(spoken ?? title)
  }

  @ViewBuilder private var symbol: some View {
    if pending {
      ProgressView().controlSize(.small).frame(height: 22)
    } else {
      Image(systemName: systemImage).font(.title3.weight(.medium)).frame(height: 22)
        .accessibilityHidden(true)
    }
  }
}

private struct ActionTileStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
  }
}

/// Live listening captions, while a recorder streams: the shared strip (`.sheet`), drawn as the Mac's
/// Listen Live draws it. Tentative; never the transcript.
private struct StatusCaptions: View {
  @Environment(PhoneAppModel.self) private var model

  var body: some View {
    let locale = model.settings.captionLocale
    ForEach(model.devices.sessions.filter(\.isListeningLive)) { session in
      VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
        HStack(spacing: 6) {
          Circle().fill(DaybookPalette.Ink.record).frame(width: 7, height: 7).accessibilityHidden(true)
          StatusHeading(text: "Listening to \(session.device.name)")
        }
        let segments = session.liveCaptions
        let state = session.liveCaptionState
        if LiveCaptionStrip.shows(segments: segments, state: state, locale: locale) {
          LiveCaptionStrip(segments: segments, state: state, locale: locale, style: .sheet)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(DaybookSpacing.s3)
      .background(DaybookPalette.quietFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }
}

// MARK: Macs

/// Every paired Mac (and one the library synced with lately that isn't paired here), the queue under the
/// Mac doing it, and Pair with Your Mac… while none is paired. Work no Mac here is doing yet starts at the
/// card's edge.
private struct StatusMacs: View {
  let inputs: StatusOverviewInputs
  let now: Date
  let open: (SettingsRoute) -> Void
  let pair: () -> Void
  let openConversation: (UUID) -> Void
  let perform: (StatusQueueItem.Action, UUID) -> Void

  var body: some View {
    let rows = StatusOverviewModel.macRows(inputs, now: now)
    StatusGroup(title: "Macs") {
      StatusCard {
        // Work no Mac here is doing yet (no Mac has synced): at the top, under none.
        if !rows.contains(where: \.showsQueue) {
          ForEach(inputs.queue) { entry in queueRow(entry, under: nil) }
        }
        ForEach(rows) { row in
          macRow(row)
          if row.showsQueue {
            ForEach(inputs.queue) { entry in queueRow(entry, under: row.name) }
          }
        }
        if inputs.pairedMacs.isEmpty {
          Button(action: pair) {
            StatusRow {
              StatusLinkGlyph(systemImage: "plus")
            } content: {
              Text("Pair with Your Mac…").font(.subheadline.weight(.medium)).foregroundStyle(
                DaybookPalette.Ink.link)
            }
          }
          .buttonStyle(StatusRowButtonStyle())
        }
      }
    }
  }

  private func queueRow(_ entry: StatusQueueEntry, under mac: String?) -> some View {
    StatusQueueRow(
      entry.item(under: mac, now: now), indented: mac != nil, open: { openConversation(entry.id) },
      perform: { perform($0, entry.id) }
    )
    .statusRowAtCardEdge(mac == nil)
  }

  @ViewBuilder
  private func macRow(_ row: StatusMacRow) -> some View {
    let label = StatusRow {
      DaybookTile(
        symbol: "desktopcomputer",
        tone: row.needsYou ? .attention : row.isConnected ? .active : .neutral, size: .card)
    } content: {
      HStack(spacing: DaybookSpacing.s2) {
        StatusRowTitle(title: row.name) {
          VStack(alignment: .leading, spacing: 2) {
            Text(row.text.keepingSeparators).foregroundStyle(
              row.needsYou ? DaybookPalette.Ink.warning : DaybookPalette.Ink.secondary)
            if let fix = row.fix { Text(fix) }
          }
        }
        Spacer(minLength: 0)
        if case .paired = row.id { StatusChevron() }
      }
    }
    switch row.id {
    case .paired(let id):
      Button {
        open(.mac(id))
      } label: {
        label
      }
      .buttonStyle(StatusRowButtonStyle())
      .accessibilityHint("Shows \(row.name)")
    case .synced:
      label.accessibilityElement(children: .combine)
    }
  }
}

// MARK: This iPhone

/// This iPhone: its own work while it has some (docs/iphone.md, "Processing on this iPhone"), what runs
/// here, a summary counting down to it, what waits and what's paused, in the rows the Macs card uses;
/// and the audio kept on it, opening Storage.
private struct StatusThisIPhone: View {
  let entries: [StatusQueueEntry]
  let now: Date
  let open: (SettingsRoute) -> Void
  let openConversation: (UUID) -> Void
  let perform: (StatusQueueItem.Action, UUID) -> Void
  @Environment(PhoneAppModel.self) private var model

  var body: some View {
    StatusGroup(title: "This iPhone") {
      StatusCard {
        ForEach(entries) { entry in
          StatusQueueRow(
            entry.item(under: nil, now: now), indented: false, open: { openConversation(entry.id) },
            perform: { perform($0, entry.id) }
          )
          .statusRowAtCardEdge()
        }
        Button {
          open(.storage)
        } label: {
          StatusRow {
            DaybookTile(symbol: "iphone", size: .card)
          } content: {
            HStack(spacing: DaybookSpacing.s2) {
              Text(StatusSheetModel.audioOnThisIPhone(bytes: model.audio.usage.bytes))
                .font(.subheadline)
                .foregroundStyle(DaybookPalette.Ink.title)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
              StatusChevron()
            }
          }
        }
        .buttonStyle(StatusRowButtonStyle())
        .accessibilityHint("Shows storage")
      }
    }
  }
}
