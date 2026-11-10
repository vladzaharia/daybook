import DaybookDesign
import DaybookKit
import SwiftUI

// A recorder's page, the same on both devices and in one order (docs/devices.md, "Interface"): its name and
// state, a problem, the handoff, what can be done now, its figures, the import under way, what's new on it
// (where no list beside the page shows it), what it imported, how recordings arrive, its options, and Details.
// It sits on paper in a conversation page's column, so a title lines up with a conversation's; the kind's
// glyph hangs in the margin where the column has one, and sits on a tile beside the name where it doesn't.

/// One recorder's page.
public struct RecorderDevicePage: View {
    private let session: DeviceSession
    private let showsRecordings: Bool
    @Environment(\.recorderServices) private var services

    /// - Parameter showsRecordings: Lists what's new on the recorder on the page; the Mac's list column beside it
    ///   shows them instead.
    public init(session: DeviceSession, showsRecordings: Bool) {
        self.session = session
        self.showsRecordings = showsRecordings
    }

    /// The page's foot, for a `ScrollViewReader` (a debug launch scrolls to it for screenshots).
    public static let endAnchor = "recorder-page-end"

    public var body: some View {
        let problem = RecorderProblemBox.shownProblem(session)
        let boxActions = problem.map { RecorderProblemBox.actions($0, on: services?.place ?? .current,
                                                                   excluding: session.inapplicableProblemActions) } ?? []
        RecorderPageColumn {
            RecorderHeader(session: session)
            if let problem {
                RecorderProblemBox(session: session, problem: problem)
                    .padding(.top, DaybookSpacing.s4)
            }
            RecorderHandoffView(session: session, style: .page)
            RecorderActionTiles(session: session, hiding: boxActions.contains(.connect) || boxActions.contains(.reconnect) ? [.connect] : [])
            RecorderFigures(session: session)
            RecorderImportProgress(session: session)
            LiveSavedNotice(session: session)
            if showsRecordings { RecorderNewRecordings(session: session) }
            RecentImportsSection(session: session)
            RecorderMethods(session: session, covered: Set(boxActions))
            RecorderPreferencesSection(session: session, style: .page)
            RecorderPageFooter(session: session)
        }
        .daybookMotion(DaybookMotion.fade, value: problem?.id)
        .daybookMotion(DaybookMotion.fade, value: session.queue.isActive)
        .onAppear { session.primary?.refreshIfStale() }
    }
}

// MARK: - The column

/// A recorder's page on paper: the measure a conversation page uses, past the margin where one hangs. On the Mac a
/// scrolling page; on the iPhone a plain list on paper, so a row can be swiped.
public struct RecorderPageColumn<Content: View>: View {
    private let content: Content
    @Environment(\.daybookDensity) private var density
    @Environment(\.creaseEdge) private var creaseEdge
    @State private var width: CGFloat = 400

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        #if os(iOS)
        let frame = ReadingGeometry.frame(width: width, density: density, creaseEdge: creaseEdge,
                                          creaseClearance: ReadingGeometry.creaseClearance)
        List {
            Group { content }
                .listRowInsets(EdgeInsets(top: 0, leading: frame.textLeading, bottom: 0, trailing: frame.trailing))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Color.clear.frame(height: DaybookSpacing.s7)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityHidden(true)
                .id(RecorderDevicePage.endAnchor)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .environment(\.readingWidth, ReadingWidth(width: width))
        .background(DaybookPalette.paper)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        #else
        ReadingPage { RecorderMeasure { content } }
            .background(DaybookPalette.paper)
        #endif
    }
}

/// The text measure inside a scrolling page: past the margin, which a recorder's page leaves to its glyph.
private struct RecorderMeasure<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.readingWidth) private var readingWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.leading, readingWidth == .regular ? ReadingGeometry.margin : 0)
    }
}

/// A heading on a recorder's page: "Recent imports".
struct RecorderPageHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .daybookFont(.heading)
            .foregroundStyle(DaybookPalette.Ink.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DaybookSpacing.s6)
            .padding(.bottom, DaybookSpacing.s2)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Header

/// The recorder's name in New York and its state in a few words, which the problem, the import, and the figures
/// don't repeat ("Connected", "Not connected · Last seen today, 3:25 AM"), with Cancel while it connects. Where the
/// column has a margin its glyph hangs there; where it doesn't, it sits on a tile beside the name. Teal while
/// the recorder is linked.
public struct RecorderHeader: View {
    private let session: DeviceSession
    @Environment(\.recorderServices) private var services
    @Environment(\.readingWidth) private var readingWidth
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(session: DeviceSession) { self.session = session }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let byline = services.map { RecorderStatusWords.byline($0.facts(session, now: context.date), now: context.date) }
                ?? RecorderStatusWords.byline(RecorderFacts(session: session, now: context.date), now: context.date)
            content(byline: byline)
        }
        .modifier(DetailsPopover(session: session, browser: session.browser))
    }

    @ViewBuilder
    private func content(byline: String) -> some View {
        if readingWidth == .regular {
            VStack(alignment: .leading, spacing: 6) {
                title
                    .overlay(alignment: .topLeading) {
                        Image(systemName: session.kind.systemImage)
                            .font(.system(size: density == .touch ? 24 : 26))
                            .foregroundStyle(session.isLinked ? DaybookPalette.accent : DaybookPalette.Ink.secondary)
                            .frame(width: ReadingGeometry.margin - ReadingGeometry.marginGap, height: 36, alignment: .trailing)
                            .offset(x: -ReadingGeometry.margin)
                            .accessibilityHidden(true)
                    }
                bylineRow(byline)
            }
            .accessibilityElement(children: .contain)
        } else {
            // At the accessibility sizes the tile sits above the name, which then has the page's width.
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: DaybookSpacing.s3))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            layout {
                DeviceGlyph(session: session, size: .header)
                VStack(alignment: .leading, spacing: 4) {
                    title
                    bylineRow(byline)
                }
            }
            .padding(.top, density == .touch ? DaybookSpacing.s2 : 0)
        }
    }

    private var title: some View {
        // On one line when it fits; else a size smaller, wrapping at spaces (a page of the open Duo, a narrow window).
        ViewThatFits(in: .horizontal) {
            Text(session.device.name).daybookFont(.docTitle).lineLimit(1)
            Text(session.device.name.wrappingAsName)
                .daybookFont(.sheetTitle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DaybookPalette.Ink.title)
        .accessibilityAddTraits(.isHeader)
    }

    private func bylineRow(_ byline: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
            Text(byline.keepingSeparators)
                .daybookFont(.byline)
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let direct = session.direct, direct.state.isBusy, session.primary?.method == .direct {
                Button("Cancel") { session.disconnect(.direct) }
                    .buttonStyle(.daybookLink)
                    .daybookFont(.byline)
            }
        }
    }
}

/// Device Details opened from a menu (More › Device Details…, a problem's Technical Details), beside the header,
/// where the app shows them as a popover.
private struct DetailsPopover: ViewModifier {
    let session: DeviceSession
    @Bindable var browser: DeviceBrowser
    @Environment(\.recorderServices) private var services

    func body(content: Content) -> some View {
        if let popover = services?.detailsPopover {
            content.popover(isPresented: $browser.showingDetails, arrowEdge: .bottom) { popover(session) }
        } else {
            content
        }
    }
}

// MARK: - Problem

/// The recorder's problem, under its name: what happened and what's safe, with at most two actions (the first
/// leading) and Dismiss when there's room. A recorder another device manages shows none: that device reaches it.
public struct RecorderProblemBox: View {
    private let session: DeviceSession
    private let problem: DeviceProblem
    @Environment(\.recorderServices) private var services

    public init(session: DeviceSession, problem: DeviceProblem) {
        self.session = session
        self.problem = problem
    }

    /// The problem the page shows, if any.
    @MainActor
    public static func shownProblem(_ session: DeviceSession) -> DeviceProblem? {
        session.managedElsewhere == nil ? session.problem : nil
    }

    /// The problem's first two actions this device can take, with Dismiss when there's room for it.
    public static func actions(_ problem: DeviceProblem, on place: RecorderStatusWords.Place,
                               excluding hidden: Set<DeviceProblemAction> = []) -> [DeviceProblemAction] {
        let actions = Array(RecorderStatusWords.problemActions(problem, on: place, excluding: hidden).prefix(2))
        return actions.count < 2 && !actions.contains(.dismiss) ? actions + [.dismiss] : actions
    }

    public var body: some View {
        let place = services?.place ?? .current
        let words = RecorderStatusWords.problem(problem, on: place)
        let actions = Self.actions(problem, on: place, excluding: session.inapplicableProblemActions)
        AttentionBox(kind: .problem, title: words.title, message: words.message) {
            ForEach(Array(actions.dropFirst().reversed()), id: \.self) { action in
                Button(RecorderStatusWords.actionTitle(action, on: place)) { perform(action) }
                    .buttonStyle(.daybookLink)
            }
            if let first = actions.first {
                if first == .dismiss {
                    Button(RecorderStatusWords.actionTitle(first, on: place)) { perform(first) }.buttonStyle(.daybookLink)
                } else {
                    Button(RecorderStatusWords.actionTitle(first, on: place)) { perform(first) }.buttonStyle(.daybookProminent)
                }
            }
        }
        .daybookTransition(.opacity)
    }

    private func perform(_ action: DeviceProblemAction) {
        RecorderProblemBox.perform(action, session: session, services: services)
    }

    /// Does what a problem's action says, here.
    @MainActor
    static func perform(_ action: DeviceProblemAction, session: DeviceSession, services: RecorderServices?) {
        switch action {
        case .openBluetoothSettings, .openPrivacySettings: services?.openSystemSettings(action)
        case .setUpFolder, .chooseFolder:
            if services?.chooseFolder?(session) == true { session.dismissProblem() }
        case .tryAgain: session.tryAgain()
        case .technicalDetails:
            session.browser.showsTechnicalDetails = true
            services?.showDetails(session)
        case .reconnect, .connect: session.connect()
        case .dismiss: session.dismissProblem()
        case .refreshStatus:
            session.dismissProblem()
            session.primary?.refresh()
        }
    }
}

// MARK: - What can be done now

/// What can be done with the recorder now, as tiles of equal width straight on the page: Connect, Record or Pause
/// on it, Import N New, Check for New, Listen Live or Stop Listening (`RecorderActions`). Never a disabled one.
public struct RecorderActionTiles: View {
    private let session: DeviceSession
    private let hiding: Set<RecorderAction>
    @Environment(\.recorderServices) private var services
    @Environment(\.dynamicTypeSize) private var typeSize

    /// - Parameter hiding: What another part of the page offers already (Connect, in the problem box).
    public init(session: DeviceSession, hiding: Set<RecorderAction> = []) {
        self.session = session
        self.hiding = hiding
    }

    public var body: some View {
        let facts = services?.facts(session) ?? RecorderFacts(session: session)
        let actions = RecorderActions.available(facts).filter { !hiding.contains($0) }
        if !actions.isEmpty {
            let stacked = typeSize.isAccessibilitySize
            let layout = stacked ? AnyLayout(VStackLayout(spacing: DaybookSpacing.s2)) : AnyLayout(HStackLayout(spacing: DaybookSpacing.s2))
            layout {
                ForEach(actions, id: \.self) { action in
                    RecorderActionTile(label: action.label(shortName: session.kind.shortName), stacked: stacked,
                                       pending: (action == .record || action == .pause) && facts.recordCommandPending) {
                        perform(action)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DaybookSpacing.s4)
        }
    }

    private func perform(_ action: RecorderAction) {
        let control = session.direct as? any RecordControlConnection
        let live = session.direct as? any LiveListeningConnection
        switch action {
        case .connect: session.connect()
        case .record: control?.startRecording()
        case .pause: control?.pauseRecording()
        case .importNew: session.importRecordings(session.newRecordings)
        case .checkForNew: session.direct?.refresh()
        case .listenLive:
            live?.startListening()
            services?.showListenLive?(session)
        case .stopListening: live?.stopListening()
        }
    }
}

/// One of a recorder's actions: its glyph over its name on a quiet accent wash, in an equal share of the row
/// (beside its name, at the accessibility sizes).
struct RecorderActionTile: View {
    let label: RecorderAction.Label
    let stacked: Bool
    var pending = false
    let action: () -> Void
    @Environment(\.daybookDensity) private var density

    var body: some View {
        let touch = density == .touch
        Button(action: action) {
            let layout = stacked ? AnyLayout(HStackLayout(spacing: DaybookSpacing.s3)) : AnyLayout(VStackLayout(spacing: touch ? 5 : 4))
            layout {
                Group {
                    if pending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: label.symbol)
                    }
                }
                .font(touch ? .title3 : .system(size: 17))
                .frame(height: touch ? 26 : 20)
                ViewThatFits(in: .horizontal) {
                    Text(label.title).lineLimit(1)
                    if let short = label.shortTitle { Text(short).lineLimit(1) }
                }
                .font(touch ? .footnote.weight(.semibold) : .system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: stacked ? .leading : .center)
            .padding(.horizontal, DaybookSpacing.s3)
            .padding(.vertical, touch ? 12 : 10)
            .frame(minHeight: touch ? 64 : 54)
            .foregroundStyle(DaybookPalette.Ink.onWash)
            .background(DaybookPalette.accentWash, in: DaybookRadius.shape(DaybookRadius.box))
            .contentShape(DaybookRadius.shape(DaybookRadius.box))
        }
        .buttonStyle(RecorderTileButtonStyle())
        .disabled(pending)
        .accessibilityLabel(label.spoken)
    }
}

/// A tile dims while pressed and lifts a little under the pointer, as the button family does.
private struct RecorderTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RecorderTileFace(configuration: configuration)
    }
}

private struct RecorderTileFace: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.45)
            .brightness(hovering && isEnabled ? 0.03 : 0)
            #if os(macOS)
            .onHover { hovering = $0 }
            .daybookMotion(DaybookMotion.hover, value: hovering)
            #endif
    }
}

// MARK: - Figures

/// Recorder, Case, and Storage as figures: three across where they fit, else two, else one under another (and one
/// under another at the accessibility sizes). Values the recorder hasn't confirmed since it was last connected
/// are quieter, with their time once under the tiles, also while another device manages it.
public struct RecorderFigures: View {
    private let session: DeviceSession
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(session: DeviceSession) { self.session = session }

    public var body: some View {
        let capabilities = session.direct?.capabilities ?? []
        if let status = session.status, !capabilities.isDisjoint(with: [.battery, .caseBattery, .storage]) {
            let stale = !session.isLinked
            let low = status.storage.map(StorageFormat.isLow) ?? false
            let tiles = Self.tiles(status, capabilities: capabilities, stale: stale)
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: DaybookSpacing.s2) { tileViews(tiles) }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: DaybookSpacing.s2) {
                            ForEach(tiles) { tile in tileView(tile).frame(minWidth: Self.minimumTile) }
                        }
                        // Two across; a third on its own spans the row, so the grid keeps both edges.
                        Grid(horizontalSpacing: DaybookSpacing.s2, verticalSpacing: DaybookSpacing.s2) {
                            ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { index in
                                GridRow {
                                    if index + 1 < tiles.count {
                                        tileView(tiles[index])
                                        tileView(tiles[index + 1])
                                    } else {
                                        tileView(tiles[index]).gridCellColumns(2)
                                    }
                                }
                            }
                        }
                        .frame(minWidth: Self.minimumTile * 2 + DaybookSpacing.s2)
                        VStack(spacing: DaybookSpacing.s2) { tileViews(tiles) }
                    }
                }
                if low, let storage = status.storage, capabilities.contains(.storage), storage.hoursLeft >= 0 {
                    Text("When it’s full, \(session.kind.shortName) records over its oldest recordings. Free up space in the \(session.kind.shortName) app.")
                        .daybookFont(.status)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if stale, Self.showsAsOf(session) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(RecorderStatusWords.asOf(status.updatedAt, now: context.date))
                            .daybookFont(.colophon)
                            .foregroundStyle(DaybookPalette.Ink.meta)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.top, DaybookSpacing.s5)
        }
    }

    /// The narrowest a figure gets beside others.
    static let minimumTile: CGFloat = 140

    public struct Tile: Identifiable {
        public let id: String
        public let label: String
        public let symbol: String
        public let value: String
        public let detail: String?
        public let warning: Bool
        public let stale: Bool
        public let accessibility: String
    }

    /// The figures the recorder reports, in order.
    public static func tiles(_ status: DeviceStatus, capabilities: DeviceCapabilities, stale: Bool) -> [Tile] {
        var tiles: [Tile] = []
        func battery(_ id: String, _ label: String, _ battery: DeviceStatus.Battery?) {
            tiles.append(Tile(id: id, label: label, symbol: BatteryFormat.symbol(battery), value: BatteryFormat.value(battery),
                              detail: RecorderStatusWords.batteryDetail(battery, stale: stale), warning: BatteryFormat.isLow(battery),
                              stale: stale, accessibility: BatteryFormat.accessibilityLabel("\(label) battery", battery)))
        }
        if capabilities.contains(.battery) { battery("recorder", "Recorder", status.battery) }
        if capabilities.contains(.caseBattery) { battery("case", "Case", status.caseBattery) }
        if capabilities.contains(.storage), let storage = status.storage {
            let low = StorageFormat.isLow(storage)
            tiles.append(Tile(id: "storage", label: "Storage", symbol: low ? "externaldrive.trianglebadge.exclamationmark" : "externaldrive",
                              value: RecorderStatusWords.storageFigure(hours: storage.hoursLeft, low: low),
                              detail: low ? "Nearly full" : "of recording left", warning: low, stale: stale,
                              accessibility: "Storage, " + StorageFormat.hoursLeft(storage)))
        }
        return tiles
    }

    /// Whether the figures say when they're from. Not when the byline above already dates the last connection at
    /// the same minute ("Not connected · Last seen today, 3:25 AM"); always while another device manages it.
    @MainActor
    public static func showsAsOf(_ session: DeviceSession) -> Bool {
        guard let updated = session.status?.updatedAt, !session.isLinked else { return false }
        guard session.managedElsewhere == nil, session.status?.isRecording != true,
              session.state == .notConnected || session.state == .unavailable,
              let last = session.primary?.lastConnectedAt else { return true }
        return abs(last.timeIntervalSince(updated)) >= 60
    }

    @ViewBuilder
    private func tileViews(_ tiles: [Tile]) -> some View {
        ForEach(tiles) { tile in tileView(tile) }
    }

    private func tileView(_ tile: Tile) -> some View {
        FigureTile(label: tile.label, symbol: tile.symbol, value: tile.value, detail: tile.detail, warning: tile.warning,
                   stale: tile.stale, accessibility: tile.accessibility)
    }
}

// MARK: - The import under way

/// "Importing 1 of 3 · about 6 min left", its bar, and Stop; while it waits, what for. Over the recorder's Wi‑Fi
/// it says to keep Daybook open; over Bluetooth, to keep the recorder near.
public struct RecorderImportProgress: View {
    private let session: DeviceSession
    @Environment(\.recorderServices) private var services

    public init(session: DeviceSession) { self.session = session }

    public var body: some View {
        let facts = services?.facts(session) ?? RecorderFacts(session: session)
        if let title = RecorderStatusWords.importTitle(facts), let importing = facts.importing {
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .daybookFont(.statusLead)
                        .foregroundStyle(DaybookPalette.Ink.body)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DaybookSpacing.s3)
                    Button("Stop") { services?.stopImporting(session, true) ?? session.stopAll() }
                        .buttonStyle(.daybookLink)
                        .daybookFont(.status)
                }
                if !importing.suspended {
                    // While preparing, the bar waits empty; the title says "Preparing…".
                    ProgressView(value: importing.preparing ? 0 : importing.fraction ?? 0)
                        .progressViewStyle(.brand(width: nil))
                        .accessibilityLabel("Import progress")
                }
                if let note = RecorderStatusWords.importNote(facts, wireless: session.capabilities.contains(.wirelessTransfer)
                                                                || session.kind.method(.direct)?.transport == .bluetoothLE && session.primary?.method == .direct,
                                                             on: services?.place ?? .current) {
                    Text(note)
                        .daybookFont(.status)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, DaybookSpacing.s5)
            .daybookTransition(.opacity)
        }
    }
}

// MARK: - New on the recorder

/// What's on the recorder that isn't in Daybook, on a page with no list beside it: Recording now (opening Listen
/// Live), then each new recording with Import, and All Recordings. A recorder another device manages has none
/// here: that device imports them.
public struct RecorderNewRecordings: View {
    private let session: DeviceSession
    @Environment(\.recorderServices) private var services
    @Environment(\.dynamicTypeSize) private var typeSize

    /// How many new recordings the page lists before All Recordings.
    static let shown = 5

    public init(session: DeviceSession) { self.session = session }

    public var body: some View {
        let split = session.split
        let new = session.newRecordings
        if session.importsHere, !new.isEmpty || split.inProgress != nil || !split.imported.isEmpty {
            Group {
                RecorderPageHeading("New on \(session.kind.shortName)")
                if let now = split.inProgress { recordingNow(now) }
                ForEach(new.prefix(Self.shown)) { recording in row(recording) }
                if new.isEmpty, split.inProgress == nil {
                    Text("You’re all caught up.")
                        .daybookFont(.status)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .padding(.vertical, DaybookSpacing.s1)
                }
                if let show = services?.showRecordings {
                    Button { show(session) } label: {
                        HStack {
                            Text("All Recordings")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.daybookLink)
                    .daybookFont(.body)
                    .padding(.vertical, DaybookSpacing.s2)
                }
            }
        }
    }

    private func recordingNow(_ recording: DeviceRecording) -> some View {
        Button { services?.showListenLive?(session) } label: {
            HStack(spacing: DaybookSpacing.s2) {
                Circle().fill(DaybookPalette.Ink.record).frame(width: 8, height: 8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.startedAt.map { "Recording now · started \($0.formatted(date: .omitted, time: .shortened))" } ?? "Recording now")
                        .daybookFont(.body)
                        .foregroundStyle(DaybookPalette.Ink.title)
                    // Handed over mid-recording: the conversation it goes into once it's finished.
                    if let waiting = session.conversationWaiting(for: recording.id), let title = services?.library.meeting(waiting)?.title {
                        Text("For \(title)").daybookFont(.status).foregroundStyle(DaybookPalette.Ink.secondary)
                    }
                }
                Spacer(minLength: 0)
                if services?.showListenLive != nil, session.direct is any LiveListeningConnection {
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(DaybookPalette.Ink.meta)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, DaybookSpacing.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func row(_ recording: DeviceRecording) -> some View {
        let canImport = session.importsHere && session.isConnected
        // At the accessibility sizes, Import goes under the recording rather than squeezing it.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DaybookSpacing.s2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DaybookSpacing.s3))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).daybookFont(.body).foregroundStyle(DaybookPalette.Ink.title).monospacedDigit()
                Text(session.failures.first { $0.id == recording.id }?.message ?? recording.detail)
                    .daybookFont(.status).foregroundStyle(DaybookPalette.Ink.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if canImport {
                Button("Import") { session.importRecordings([recording]) }
                    .buttonStyle(.daybookTinted)
                    .accessibilityLabel("Import \(recording.title)")
            }
        }
        .padding(.vertical, DaybookSpacing.s2)
        .contextMenu { DeviceRecordingMenuItems(session: session, recordings: [recording]) }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            if canImport {
                Button("Import") { session.importRecordings([recording]) }.tint(DaybookPalette.prominentFill)
            }
        }
        #endif
    }
}

// MARK: - How recordings arrive

/// "Import": each of the recorder's ways in, in its order of preference, each saying only what the name above
/// doesn't (a connected link is just its name, a watched folder just where it is), with one action that works now
/// and isn't offered elsewhere on the page.
public struct RecorderMethods: View {
    private let session: DeviceSession
    private let covered: Set<DeviceProblemAction>
    @Environment(\.recorderServices) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter covered: What the problem box above already offers.
    public init(session: DeviceSession, covered: Set<DeviceProblemAction> = []) {
        self.session = session
        self.covered = covered
    }

    /// The methods shown: those set up, and those this device can set up from a page.
    private var methods: [(ConnectionMethod, any DeviceConnection)] {
        session.kind.implementedMethods.compactMap { method in
            guard let connection = session.connection(method.kind) else { return nil }
            guard connection.isSetUp || canSetUp(method.kind) else { return nil }
            return (method, connection)
        }
    }

    private func canSetUp(_ kind: ConnectionMethodKind) -> Bool {
        kind == .files ? services?.chooseFolder != nil : services?.setUpMethod != nil
    }

    public var body: some View {
        let methods = self.methods
        if !methods.isEmpty, session.kind.id != DaybookPhoneIntegration.id {
            Group {
                RecorderPageHeading("Import")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(methods.enumerated()), id: \.element.0.id) { index, item in
                        if index > 0 { Divider().padding(.leading, Self.glyphColumn + DaybookSpacing.s3) }
                        row(item.0, item.1, preferred: index == 0 && methods.count > 1)
                    }
                }
                .padding(.vertical, DaybookSpacing.s1)
                .padding(.horizontal, DaybookSpacing.s3)
                .background(DaybookPalette.quietFill, in: DaybookRadius.shape(DaybookRadius.box))
            }
        }
    }

    /// Every row's symbol sits in one column, so the titles line up whatever the symbols' widths.
    static let glyphColumn: CGFloat = 24

    private func row(_ method: ConnectionMethod, _ connection: any DeviceConnection, preferred: Bool) -> some View {
        let enabled = session.device.isEnabled(method.kind)
        let linked = method.kind == .direct && connection.state.isConnected
        return HStack(alignment: .center, spacing: DaybookSpacing.s3) {
            Image(systemName: Self.symbol(method, connection))
                .font(.system(size: 15))
                .foregroundStyle(linked ? DaybookPalette.accent : DaybookPalette.Ink.secondary)
                .symbolEffect(.variableColor.iterative, isActive: connection.state.isBusy && !reduceMotion)
                .frame(width: Self.glyphColumn, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DaybookSpacing.s2) {
                    Text(method.title).daybookFont(.body).foregroundStyle(DaybookPalette.Ink.body)
                    if preferred && !connection.isSetUp { RecommendedLabel() }
                }
                if let summary = summary(connection, enabled: enabled) {
                    Text(summary)
                        .daybookFont(.status)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DaybookSpacing.s2)
            action(method, connection, enabled: enabled)
        }
        .padding(.vertical, DaybookSpacing.s2 + 2)
        .accessibilityElement(children: .combine)
    }

    /// The method's own state, unless the line under the name says it already.
    private func summary(_ connection: any DeviceConnection, enabled: Bool) -> String? {
        if connection.isSetUp && !enabled { return "Off" }
        guard connection.method == session.primary?.method else { return connection.summary }
        if let files = connection as? ImportFolderWatcher, files.problem == nil, files.isWatching, files.waitingForICloud == 0,
           let name = files.folderDisplayName {
            return name
        }
        if connection.method == .direct, Self.bylineSays(connection.state, managedElsewhere: session.managedElsewhere != nil) { return nil }
        return connection.summary
    }

    /// The direct link's states the page's byline already names.
    public static func bylineSays(_ state: ConnectionState, managedElsewhere: Bool) -> Bool {
        switch state {
        case .connected, .searching, .connecting, .reconnecting, .notSetUp: return true
        case .notConnected: return managedElsewhere
        case .unavailable: return false
        }
    }

    static func symbol(_ method: ConnectionMethod, _ connection: any DeviceConnection) -> String {
        guard method.kind == .direct else { return method.systemImage }
        switch connection.state {
        case .connected: return "antenna.radiowaves.left.and.right"
        case .searching, .connecting, .reconnecting: return "dot.radiowaves.left.and.right"
        default: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    @ViewBuilder
    private func action(_ method: ConnectionMethod, _ connection: any DeviceConnection, enabled: Bool) -> some View {
        if !connection.isSetUp {
            if method.kind == .files, let choose = services?.chooseFolder {
                Button("Choose Folder…") { _ = choose(session) }.buttonStyle(.daybookTinted)
            } else if method.kind != .files, let setUp = services?.setUpMethod {
                Button("Set Up…") { setUp(session, method.kind) }.buttonStyle(.daybookTinted)
            }
        } else if !enabled {
            Button("Turn On") { session.update { $0.disabledMethods.remove(method.kind) } }.buttonStyle(.daybookTinted)
        } else if let files = connection as? ImportFolderWatcher {
            if files.problem != nil {
                if covered.isDisjoint(with: [.chooseFolder, .setUpFolder]), let choose = services?.chooseFolder {
                    Button("Choose Folder…") { _ = choose(session) }.buttonStyle(.daybookTinted)
                }
            } else if let folder = files.folder, let reveal = services?.revealFolder {
                Button("Show in Finder") { reveal(folder) }.buttonStyle(.daybookTinted)
            }
        }
    }
}

/// "Recommended", for the way setup offers first: a label in secondary ink, since the accent is for what you can
/// act on.
public struct RecommendedLabel: View {
    public init() {}
    public var body: some View {
        Text("Recommended")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(DaybookPalette.quietFill, in: DaybookRadius.chip)
    }
}

// MARK: - Footer

/// Details and Disconnect, at the page's foot.
struct RecorderPageFooter: View {
    let session: DeviceSession
    @Environment(\.recorderServices) private var services
    @State private var showingDetails = false

    var body: some View {
        let details = session.direct is any DetailedConnection && (session.status != nil || session.isLinked)
        let disconnect = session.isLinked && session.managedElsewhere == nil && session.direct?.method == .direct
            && session.kind.id != DaybookPhoneIntegration.id
        if details || disconnect {
            HStack(spacing: DaybookSpacing.s5) {
                if details, let services {
                    if let popover = services.detailsPopover {
                        Button(RecorderPageFooter.detailsTitle) { showingDetails = true }
                            .popover(isPresented: $showingDetails, arrowEdge: .bottom) { popover(session) }
                    } else {
                        Button(RecorderPageFooter.detailsTitle) { services.showDetails(session) }
                    }
                }
                if disconnect {
                    Button("Disconnect") { session.disconnect(.direct) }
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.daybookLink)
            .daybookFont(.status)
            .padding(.top, DaybookSpacing.s6)
        }
    }

    /// "Details…" on the Mac, where it opens a popover of facts; "Details" on the iPhone, which shows a screen.
    static var detailsTitle: String {
        #if os(macOS)
        "Details…"
        #else
        "Details"
        #endif
    }
}
