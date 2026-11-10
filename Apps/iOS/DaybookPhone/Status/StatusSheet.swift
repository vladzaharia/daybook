import DaybookCaptions
import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI

// The status (docs/iphone.md, "Status sheet"): the recorders, the Macs, this iPhone's own work, and iCloud. At rest
// it speaks only when there's something to say: one line, the status strip, above the library's toolbar
// (`StatusStrip`). Tapping it, or Devices in the library's More menu, shows the sheet: the overview both apps draw
// (DaybookUI's `StatusOverview`), a group and a card for each kind of device.
//
// - Pocket (closed, or an iPhone 18 Pro upright): an ordinary sheet over the library, at medium, then large.
// - Notebook (open, partly open in the library, or any iPhone on its side): a card on the right page, clear of the
//   crease, leaving the left page in reach, as every reading sheet on two pages is (`PageCard`).
// - Recording: no strip. `RecordingSurface` replaces the library and shows the recorder's essentials.

/// A request to show the status sheet: at a size, at a screen inside it (a recorder's page, Settings › iCloud), or
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

  /// What tapping a line asks for: the screen that fixes it, the group that says how, or the sheet.
  init(_ route: StatusLineRoute) {
    switch route {
    case .showMore: self.init()
    case .showFix(let section): self.init(fix: section)
    case .open(let screen): self.init(route: screen)
    }
  }
}

/// Shows the status sheet: the library's strip and its More menu's Devices ask for it (`\.showStatus`).
struct ShowStatusAction {
  let show: @MainActor (StatusRequest) -> Void

  @MainActor func callAsFunction(_ request: StatusRequest) { show(request) }
}

extension EnvironmentValues {
  @Entry var showStatus = ShowStatusAction { _ in }
}

// MARK: Presenting it

extension View {
  /// The status sheet over the library, when asked for (`\.showStatus`), a recorder's notification, or a debug launch:
  /// in the hand an ordinary sheet, at medium then large; open, a card on the right page (`PageCard`), the left page
  /// in reach. A fold shows it again the other way.
  func statusSheet(onPage: Bool) -> some View {
    modifier(StatusSheetPresenter(onPage: onPage))
  }
}

private struct StatusSheetPresenter: ViewModifier {
  let onPage: Bool
  @Environment(PhoneAppModel.self) private var model
  @Environment(ReadingSession.self) private var session
  @State private var request: StatusRequest?
  @State private var shownOnPage: Bool?
  @State private var detent: PresentationDetent = .medium
  @State private var appliedLaunch = false

  func body(content: Content) -> some View {
    let onPage = shownOnPage ?? self.onPage
    content
      .environment(\.showStatus, ShowStatusAction { show($0) })
      .sheet(item: Binding(get: { onPage ? nil : request }, set: { request = $0 })) { request in
        StatusSheetView(
          request: request,
          detent: Binding(get: { detent == .large ? .large : .medium }, set: { detent = $0 == .large ? .large : .medium })
        )
        .environment(model)
        .environment(session)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .tint(PhoneStyle.accent)
      }
      .overlay {
        if onPage, let shown = request {
          // A page is tall enough for the cards with what can be done.
          CreaseSplit {
            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
          } trailing: {
            PageCard(close: { request = nil }) {
              StatusSheetView(request: shown, detent: .constant(.large))
                .environment(\.closePageSheet) { request = nil }
            }
            .id(shown.id)
          }
          .daybookTransition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .daybookMotion(PhoneStyle.Motion.state, value: onPage ? request?.id : nil)
      .onChange(of: request?.id) { _, id in shownOnPage = id == nil ? nil : self.onPage }
      // Folded or opened while it shows: the same request, shown the other way.
      .onChange(of: self.onPage) { _, now in if request != nil { shownOnPage = now } }
      // A recorder's notification (imported, almost full) opens its page here, where recorders' pages are.
      .onChange(of: model.destination, initial: true) { _, destination in
        guard let destination, case .device(let id) = destination.destination,
          model.devices.sessions.contains(where: { $0.id == id })
        else { return }
        show(StatusRequest(route: .device(id)))
        model.reached(destination)
      }
      .task { await showRequestedAtLaunch() }
  }

  private func show(_ next: StatusRequest) {
    detent = next.detent == .large ? .large : .medium
    request = next
  }

  /// `--status-detent`, `--status-open`, and `--status-choose` (debug): the sheet at a size, at a screen, or as a
  /// line's tap would show it, for screenshots.
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
      case .device: if let session = model.devices.sessions.first { show(StatusRequest(route: .device(session.id))) }
      case .mac: if let mac = model.link.macs.first { show(StatusRequest(route: .mac(mac.id))) }
      case .storage: show(StatusRequest(route: .storage))
      case .icloud: show(StatusRequest(route: .icloud))
      case .addRecorder: show(StatusRequest(route: .addRecorder))
      }
    } else if let detent = options.statusDetent {
      try? await Task.sleep(for: .milliseconds(700))
      show(StatusRequest(detent: detent))
    } else if let id = options.statusChoose {
      try? await Task.sleep(for: .milliseconds(1_500))
      let inputs = StatusSheetInputs.make(model, library: model.library.controller)
      guard let line = StatusOverviewModel.lines(inputs).first(where: { $0.id == id || $0.id.hasPrefix(id + "-") }) else { return }
      show(StatusRequest(StatusSheetModel.route(for: line, inputs)))
    }
  }
}

// MARK: The strip

/// The library's status strip, above its toolbar: the one line with something to say (`StatusOverviewModel.strip`), in
/// its own words, ink, and progress line; `LibraryPage` shows it only while there is one (`shown`). Tapping it leads
/// where the line's fix is, else to the sheet.
struct StatusStrip: View {
  let line: StatusLineItem
  let route: StatusLineRoute
  @Environment(\.showStatus) private var showStatus
  @Environment(\.dynamicTypeSize) private var typeSize

  /// The line the strip says now, and where it leads; nil when there's nothing to say.
  static func shown(_ model: PhoneAppModel, now: Date = Date()) -> StatusStrip? {
    let inputs = StatusSheetInputs.make(model, library: model.library.controller)
    guard let line = StatusOverviewModel.strip(StatusOverviewModel.lines(inputs, now: now)) else { return nil }
    return StatusStrip(line: StatusLineItem(line), route: StatusSheetModel.route(for: line, inputs))
  }

  var body: some View {
    Button {
      showStatus(StatusRequest(route))
    } label: {
      HStack(spacing: PhoneStyle.Space.s2) {
        StatusLineView(line)
        // At the accessibility sizes the words take the chevron's room: the strip is a button either way.
        if !typeSize.isAccessibilitySize { StatusChevron() }
      }
      .padding(.horizontal, typeSize.isAccessibilitySize ? PhoneStyle.Space.s3 : PhoneStyle.Space.s4)
      .padding(.vertical, PhoneStyle.Space.s3)
      .contentShape(DaybookRadius.shape(DaybookRadius.panel))
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: DaybookRadius.shape(DaybookRadius.panel))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(line.accessibilityLabel)
    .accessibilityHint(StatusSheetModel.hint(for: route))
    .accessibilityAddTraits(.isButton)
  }
}

// MARK: The sheet

/// The status sheet: the groups for its size in a navigation stack of the sheet's own, so its links open the full
/// screens inside it (a device's page, a Mac's, Settings › iCloud, Storage), never copies of them.
struct StatusSheetView: View {
  let request: StatusRequest
  @Binding var detent: StatusDetent
  @Environment(PhoneAppModel.self) private var model
  @State private var path: [SettingsRoute]
  @State private var showingPairing = false
  private let dismiss = SheetDismiss()

  init(request: StatusRequest, detent: Binding<StatusDetent>) {
    self.request = request
    _detent = detent
    _path = State(initialValue: request.route.map { [$0] } ?? [])
  }

  var body: some View {
    NavigationStack(path: $path) {
      StatusSections(
        library: model.library.controller, detent: detent, fix: request.fix, open: open,
        close: { dismiss() }, pair: { showingPairing = true }
      )
      .navigationTitle(StatusSheetModel.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.tint(PhoneStyle.Ink.title) }
      }
      .navigationDestination(for: SettingsRoute.self) { route in SettingsDestination(route: route) }
    }
    .pairingSheet(isPresented: $showingPairing)
  }

  /// A full screen opens with the sheet at full height.
  private func open(_ route: SettingsRoute) {
    detent = .large
    path.append(route)
  }
}

/// The groups, in a scroll view: iCloud's line while it's a problem, then a group per kind of device, each a heading
/// and one card (`StatusOverviewModel.sections`). It doesn't repeat the lines the cards say.
private struct StatusSections: View {
  let library: LibraryController
  let detent: StatusDetent
  let fix: StatusSection?
  let open: (SettingsRoute) -> Void
  let close: () -> Void
  let pair: () -> Void
  @Environment(PhoneAppModel.self) private var model
  @Environment(ReadingSession.self) private var session
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let inputs = StatusSheetInputs.make(model, library: library)
    ScrollViewReader { proxy in
      ScrollView {
        TimelineView(.periodic(from: .now, by: 30)) { context in
          let sections = StatusOverviewModel.sections(inputs, now: context.date)
          StatusOverview(lines: [], density: detent.density) {
            ForEach(sections, id: \.self) { section in
              view(for: section, inputs: inputs, now: context.date)
                .id(section)
                .transition(.opacity)
            }
          }
          .padding(.horizontal, PhoneStyle.Space.s4)
          .padding(.top, PhoneStyle.Space.s2)
          .padding(.bottom, PhoneStyle.Space.s4)
          .animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: sections)
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      // `--status-scroll-end`: the foot of the content, for screenshots.
      .defaultScrollAnchor(model.options.statusScrollEnd ? .bottom : nil)
      .task { await reveal(in: proxy) }
    }
    .animation(reduceMotion ? nil : PhoneStyle.Motion.state, value: detent)
  }

  /// The group with a line's fix, scrolled to the top once the sheet has laid out.
  private func reveal(in proxy: ScrollViewProxy) async {
    guard let fix else { return }
    try? await Task.sleep(for: .milliseconds(350))
    withAnimation(reduceMotion ? nil : PhoneStyle.Motion.state) { proxy.scrollTo(fix, anchor: .top) }
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

  /// A queued conversation opens on its page, and the sheet goes.
  private func openConversation(_ id: UUID) {
    close()
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
      .foregroundStyle(PhoneStyle.Ink.link)
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
        .foregroundStyle(PhoneStyle.Ink.title)
        .fixedSize(horizontal: false, vertical: true)
      subtitle
        .font(.footnote)
        .foregroundStyle(PhoneStyle.Ink.secondary)
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
      VStack(spacing: PhoneStyle.Space.s3) {
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
          HStack(spacing: PhoneStyle.Space.s2) {
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
          HStack(spacing: PhoneStyle.Space.s2) {
            VStack(alignment: .leading, spacing: 2) {
              Text(recording.title).font(.subheadline).foregroundStyle(PhoneStyle.Ink.body)
              Text(recording.detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
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
                  .foregroundStyle(PhoneStyle.Ink.onWash)
                  .padding(.horizontal, PhoneStyle.Space.s3)
                  .padding(.vertical, 5)
                  .background(PhoneStyle.accent.opacity(0.12), in: Capsule())
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
                PhoneStyle.Ink.link)
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
        .foregroundStyle(low ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
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
      ? AnyLayout(VStackLayout(spacing: PhoneStyle.Space.s2))
      : AnyLayout(HStackLayout(spacing: PhoneStyle.Space.s2))
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
          HStack(spacing: PhoneStyle.Space.s3) {
            symbol
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, PhoneStyle.Space.s3)
        } else {
          VStack(spacing: PhoneStyle.Space.s1) {
            symbol
            ViewThatFits(in: .horizontal) {
              Text(title).lineLimit(1)
              if let shortTitle { Text(shortTitle).lineLimit(1) }
              Text(shortTitle ?? title).multilineTextAlignment(.center).fixedSize(
                horizontal: false, vertical: true)
            }
          }
          .padding(.horizontal, PhoneStyle.Space.s1)
        }
      }
      .font(.footnote.weight(.semibold))
      // On the accent wash, the ink that keeps 4.5:1 there (link ink falls under it).
      .foregroundStyle(PhoneStyle.Ink.onWash)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.vertical, PhoneStyle.Space.s2 + 2)
      .background(
        PhoneStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
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
      VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
        HStack(spacing: 6) {
          Circle().fill(PhoneStyle.Ink.record).frame(width: 7, height: 7).accessibilityHidden(true)
          StatusHeading(text: "Listening to \(session.device.name)")
        }
        let segments = session.liveCaptions
        let state = session.liveCaptionState
        if LiveCaptionStrip.shows(segments: segments, state: state, locale: locale) {
          LiveCaptionStrip(segments: segments, state: state, locale: locale, style: .sheet)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(PhoneStyle.Space.s3)
      .background(PhoneStyle.quietFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                PhoneStyle.Ink.link)
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
      HStack(spacing: PhoneStyle.Space.s2) {
        StatusRowTitle(title: row.name) {
          VStack(alignment: .leading, spacing: 2) {
            Text(row.text.keepingSeparators).foregroundStyle(
              row.needsYou ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
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
            HStack(spacing: PhoneStyle.Space.s2) {
              Text(StatusSheetModel.audioOnThisIPhone(bytes: model.audio.usage.bytes))
                .font(.subheadline)
                .foregroundStyle(PhoneStyle.Ink.title)
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
