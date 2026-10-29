import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// Detail column for a device: its page, a selected recording, Listen Live, or the conversation for
/// a selected imported recording (which brings its own toolbar). What the page shows follows the
/// device's capabilities.
struct DevicePage: View {
    @ObservedObject var state: AppState
    var body: some View {
        if let session = state.selectedDevice {
            DevicePageContent(state: state, session: session, browser: session.browser).id(session.id)
        } else {
            Color.clear.background(DaybookStyle.paper)
        }
    }
}

private struct DevicePageContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @ObservedObject var browser: DeviceBrowser

    private enum Target: Equatable {
        case device, recordingNow, meeting(UUID), recording(DeviceRecording), several([DeviceRecording])
    }

    private var target: Target {
        let live = session.primary as? any LiveListeningConnection
        if browser.selection == [.recordingNow] {
            return session.split.inProgress != nil || live?.live.isListening == true ? .recordingNow : .device
        }
        let ids = browser.selectedRecordingIDs
        let links = session.links
        let recordings = session.primary?.recordings ?? []
        if ids.count == 1, let id = ids.first {
            if let meetingID = links.imported[id], state.meetings.contains(where: { $0.id == meetingID }) { return .meeting(meetingID) }
            let queued = ([session.queue.current].compactMap { $0 } + session.queue.waiting).first { $0.id == id }?.recording
            if let recording = recordings.first(where: { $0.id == id }) ?? queued { return .recording(recording) }
        }
        if ids.count > 1 {
            let chosen = recordings.filter { ids.contains($0.id) && links.imported[$0.id] == nil }
            if chosen.count > 1 { return .several(chosen) }
            if let only = chosen.first { return .recording(only) }
        }
        return .device
    }

    var body: some View {
        Group {
            switch target {
            case .meeting(let id):
                MeetingDetailView(state: state, meetingID: id).id(id)
            case .device:
                if session.kind.id == DaybookPhoneIntegration.id {
                    PhoneOverview(state: state, session: session).toolbar { more }
                } else {
                    DeviceOverview(state: state, session: session).toolbar { more }
                }
            case .recordingNow:
                if let live = session.primary as? SoundcoreConnection {
                    LivePage(state: state, session: session, connection: live, live: live.live).toolbar { more }
                }
            case .recording(let recording):
                RecordingPage(state: state, session: session, recordings: [recording]).toolbar { more }
            case .several(let recordings):
                RecordingPage(state: state, session: session, recordings: recordings).toolbar { more }
            }
        }
        .onAppear { syncConversation() }
        .onChange(of: target) { _, _ in syncConversation() }
        .onDisappear { state.deviceConversationID = nil }
        .alert(item: $browser.stopRequest) { request in
            Alert(title: Text("Stop importing “\(request.title)”?"),
                  message: Text("The \(request.minutesReceived) minutes received so far will be discarded. The recording stays on your \(session.kind.shortName)."),
                  primaryButton: .destructive(Text("Stop Importing")) {
                      if request.stopsAll { session.stopAll() } else { session.stopCurrent() }
                  },
                  secondaryButton: .cancel(Text("Keep Importing")))
        }
        .sheet(item: $browser.choosingConversation) { choice in
            ConversationChooser(state: state, session: session, recordings: choice.recordings)
        }
    }

    /// The window's toolbar shows the conversation controls only while a conversation is shown here.
    private func syncConversation() {
        let id: UUID? = if case .meeting(let id) = target { id } else { nil }
        if state.deviceConversationID != id { state.deviceConversationID = id }
    }

    @ToolbarContentBuilder private var more: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            DeviceMoreMenu(state: state, session: session, browser: browser)
        }
    }
}

// MARK: - The device page

private struct DeviceOverview: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let problem = session.problem
        DevicePageScroll {
            DevicePageTitle(title: session.device.name) {
                DeviceGlyph(symbol: session.kind.systemImage, size: 26, linked: session.isLinked)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                DeviceByline(session: session, text: byline(problem: problem, now: context.date))
            }
            .padding(.top, 6)

            if let problem {
                DeviceProblemBanner(problem: problem, perform: { DeviceActions.perform($0, session: session, state: state) },
                                    hidden: DeviceActions.inapplicable(for: session))
            }
            RecorderHandoffNotice(state: state, session: session)

            if session.queue.isActive {
                ImportProgress(session: session)
                    .padding(.top, Space.s5)
                    .transition(.deviceNotice(reduceMotion: reduceMotion))
            }
            if let live = session.primary as? SoundcoreConnection {
                LiveSavedNotice(state: state, session: session, live: live.live)
            }

            DeviceFigures(session: session)

            DevicePrimaryAction(state: state, session: session, problem: problem)

            DeviceHeading("Import")
            DeviceMethodRows(state: state, session: session)

            RecentImports(state: state, session: session)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: problem)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.queue.isActive)
        .onAppear { session.primary?.refreshIfStale() }
    }

    /// The device's state in a few words. The import's progress, the problem, and the figures each
    /// say the rest in their own place, so the line doesn't repeat them.
    private func byline(problem: DeviceProblem?, now: Date) -> String {
        guard let primary = session.primary else { return "Not set up" }
        func notConnected() -> String {
            if let last = primary.lastConnectedAt { return "Not connected · Last connected \(DeviceDateFormat.lastSeen(last, now: now))" }
            return "Not connected"
        }
        if let files = primary as? ImportFolderWatcher {
            if files.problem != nil {
                if let last = files.lastImportDate { return "Not watching · Last import \(DeviceDateFormat.lastSeen(last, now: now))" }
                return "Not watching"
            }
            if files.waitingForICloud > 0 { return files.summary }
            guard files.isWatching else { return "Not watching" }
            guard let last = files.lastImportDate else { return "Watching" }
            return "Watching · Last import \(DeviceDateFormat.relative(last, now: now))"
        }
        switch primary.state {
        case .searching: return "Looking for \(session.kind.name)…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        // The problem box below says why.
        case .unavailable: return problem == nil ? "Not available" : notConnected()
        case .notSetUp: return "Not set up"
        case .connected:
            if (primary as? any LiveListeningConnection)?.live.isListening == true { return "Connected · Recording · Listening" }
            if (primary as? any RecordControlConnection)?.recordCommandPending == true { return "Connected · Waiting for \(session.kind.shortName)…" }
            return session.status?.isRecording == true ? "Connected · Recording" : "Connected"
        case .notConnected:
            if let owner = session.managedElsewhere, primary.method == .direct {
                return "Managed by \(owner.ownerName)"
            }
            if let status = session.status, status.isRecording == true { return DeviceDateFormat.recordingAsOf(status.updatedAt) }
            return notConnected()
        }
    }

}

/// The page's one action for its state: Import N New, Connect, or Use on This Mac. Nothing when the
/// problem box already offers it, or while a handoff is under way.
private struct DevicePrimaryAction: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @ObservedObject var handoff: RecorderHandoff
    let problem: DeviceProblem?

    init(state: AppState, session: DeviceSession, problem: DeviceProblem?) {
        self.state = state
        self.session = session
        self.handoff = state.recorderHandoff
        self.problem = problem
    }

    var body: some View {
        let primary = session.primary
        let new = session.newRecordings
        let offered = problem.map { Set(DeviceProblemBanner.actions($0, excluding: DeviceActions.inapplicable(for: session))) } ?? []
        if !new.isEmpty, !session.queue.isActive, primary?.state.isConnected == true {
            let total = new.compactMap(\.length).reduce(0) { $0 + $1.seconds }
            let estimated = new.contains { $0.length?.isEstimate ?? true }
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Button {
                    session.importRecordings(new)
                } label: {
                    Label(new.count == 1 ? "Import 1 New Recording" : "Import \(new.count) New Recordings", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(DaybookStyle.prominentFill)
                .controlSize(.large)
                if total > 0 {
                    Text("\(estimated ? "About " : "")\(DurationLabel.format(total)) in all")
                        .font(TypeStyle.status).foregroundStyle(Ink.secondary).monospacedDigit()
                }
            }
            .padding(.top, Space.s5)
        } else if let direct = session.direct, direct.method == primary?.method, direct.state == .notConnected, direct.isSetUp,
                  session.device.isEnabled(.direct) {
            if session.managedElsewhere != nil {
                if !handoff.state(of: session).isPending {
                    Button { state.useRecorderOnThisMac(session) } label: { Label("Use on This Mac", systemImage: "laptopcomputer") }
                        .controlSize(.large)
                        .help("Your other device stops connecting to it.")
                        .padding(.top, Space.s5)
                }
            } else if offered.isDisjoint(with: [.connect, .reconnect]) {
                Button { session.connect() } label: { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }
                    .controlSize(.large)
                    .padding(.top, Space.s5)
            }
        }
    }
}

/// The status line under a device's title: its dot, its state, and Cancel while it's looking or
/// connecting.
struct DeviceByline: View {
    @ObservedObject var session: DeviceSession
    let text: String

    var body: some View {
        HStack(spacing: Space.s2) {
            DeviceStatusDot(state: session.state)
            Text(text)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let primary = session.primary, primary.state.isBusy, primary.method == .direct {
                Button("Cancel") { session.disconnect(primary.method) }
                    .buttonStyle(.daybookLink)
            }
        }
        .font(TypeStyle.byline())
    }
}

/// Recorder, Case, Storage: what the device reports, in tiles. Values the recorder hasn't confirmed
/// since it was last connected are drawn quieter, with their time once under the tiles.
private struct DeviceFigures: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        let capabilities = session.direct?.capabilities ?? []
        if let status = session.status, !capabilities.isDisjoint(with: [.battery, .caseBattery, .storage]) {
            let stale = !session.isLinked
            let lowStorage = status.storage.map(StorageFormat.isLow) ?? false
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(alignment: .top, spacing: Space.s3) {
                    if capabilities.contains(.battery) {
                        battery("Recorder", status.battery, stale: stale)
                    }
                    if capabilities.contains(.caseBattery) {
                        battery("Case", status.caseBattery, stale: stale)
                    }
                    if capabilities.contains(.storage), let storage = status.storage {
                        let hours = storage.hoursLeft < 1 ? "< 1 hr" : "\(StorageFormat.roundedHours(storage.hoursLeft)) hr\(lowStorage ? " left" : "")"
                        DeviceFigureTile(label: "Storage", symbol: lowStorage ? "externaldrive.trianglebadge.exclamationmark" : "externaldrive",
                                         value: hours, detail: lowStorage ? "Nearly full" : "of recording left",
                                         warning: lowStorage, stale: stale,
                                         accessibility: "Storage, " + StorageFormat.hoursLeft(storage))
                    }
                }
                if lowStorage {
                    Text("When it’s full, \(session.kind.shortName) records over its oldest recordings. Free up space in the \(session.kind.shortName) app.")
                        .font(TypeStyle.status).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if stale, !bylineDates(status.updatedAt) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("As of \(DeviceDateFormat.lastSeen(status.updatedAt, now: context.date))")
                            .font(TypeStyle.colophon).foregroundStyle(Ink.meta).monospacedDigit()
                    }
                }
            }
            .padding(.top, Space.s5)
        }
    }

    /// The line under the title says "Last connected" at the same minute, so the figures needn't.
    private func bylineDates(_ updated: Date) -> Bool {
        guard session.managedElsewhere == nil, session.status?.isRecording != true,
              session.state == .notConnected || session.state == .unavailable,
              let last = session.primary?.lastConnectedAt else { return false }
        return abs(last.timeIntervalSince(updated)) < 60
    }

    private func battery(_ label: String, _ battery: DeviceStatus.Battery?, stale: Bool) -> some View {
        let low = BatteryFormat.isLow(battery)
        let detail: String
        if battery?.level == nil { detail = "Not reported" }
        else if low { detail = "Charge soon" }
        else if battery?.charging == true, !stale { detail = "Charging" }
        else { detail = " " }
        return DeviceFigureTile(label: label, symbol: BatteryFormat.symbol(battery), value: BatteryFormat.value(battery),
                                detail: detail, warning: low, stale: stale,
                                accessibility: BatteryFormat.accessibilityLabel("\(label) battery", battery))
    }
}

/// "Importing 1 of 3 · about 6 min left", the bar, and Stop.
private struct ImportProgress: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        let queue = session.queue
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(TypeStyle.statusLead).monospacedDigit()
                    .foregroundStyle(Ink.body)
                    .contentTransition(.numericText())
                Spacer()
                Button("Stop") { session.requestStop(all: true) }
                    .buttonStyle(.daybookLink).font(TypeStyle.status)
            }
            if !queue.isSuspended {
                // While preparing, the bar waits empty; the title says "Preparing…".
                ProgressView(value: session.phase == .preparing && queue.imported + queue.failed == 0
                             ? 0 : queue.fraction(current: session.phase?.fraction))
                    .progressViewStyle(.brand(width: nil))
                    .accessibilityLabel("Import progress")
                if session.capabilities.contains(.wirelessTransfer) {
                    Text("Keep your \(session.kind.shortName) near this Mac.")
                        .font(TypeStyle.status).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Waiting, it says for what: the line above says it isn't connected.
    private var title: String {
        let queue = session.queue
        let name = session.kind.shortName
        if queue.isSuspended { return queue.total == 1 ? "1 recording waiting for \(name)" : "\(queue.total) recordings waiting for \(name)" }
        var text = "Importing \(queue.position) of \(queue.total)"
        if session.phase == .preparing { text += " · Preparing…" }
        else if let seconds = session.secondsLeft { text += " · " + TransferRateEstimator.label(secondsLeft: seconds) }
        return text
    }
}

/// How recordings arrive: each method in the kind's order of preference, with its state and one action.
struct DeviceMethodRows: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // What the problem box above already offers isn't offered again here.
        let covered = Set(session.problem.map { DeviceProblemBanner.actions($0, excluding: DeviceActions.inapplicable(for: session)) } ?? [])
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.kind.implementedMethods.enumerated()), id: \.element.id) { index, method in
                if index > 0 { Divider().padding(.leading, Self.glyphColumn + Space.s3) }
                if let connection = session.connection(method.kind) {
                    row(method, connection, preferred: index == 0, covered: covered)
                }
            }
        }
        .padding(.vertical, Space.s1)
        .padding(.horizontal, Space.s3)
        .background(DaybookStyle.quietFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Every row's symbol sits in one column, so the titles line up whatever the symbols' widths.
    static let glyphColumn: CGFloat = 24

    private func row(_ method: ConnectionMethod, _ connection: any DeviceConnection, preferred: Bool,
                     covered: Set<DeviceProblemAction>) -> some View {
        let enabled = session.device.isEnabled(method.kind)
        let linked = method.kind == .direct && connection.state.isConnected
        return HStack(alignment: .center, spacing: Space.s3) {
            Image(systemName: symbol(method, connection))
                .font(.system(size: 15))
                .foregroundStyle(linked ? DaybookStyle.accent : Ink.secondary)
                .symbolEffect(.variableColor.iterative, isActive: connection.state.isBusy && !reduceMotion)
                .frame(width: Self.glyphColumn, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s2) {
                    Text(method.title).font(TypeStyle.body()).foregroundStyle(Ink.body)
                    if preferred && session.kind.implementedMethods.count > 1 && !connection.isSetUp {
                        RecommendedBadge()
                    }
                }
                Text(summary(connection, enabled: enabled))
                    .font(TypeStyle.status).foregroundStyle(Ink.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s2)
            action(method, connection, enabled: enabled, covered: covered)
        }
        .padding(.vertical, Space.s2 + 2)
        .accessibilityElement(children: .combine)
    }

    /// The method's own state. A watched folder that is the device's only way in says just where it
    /// is: the line under the title says it's watching.
    private func summary(_ connection: any DeviceConnection, enabled: Bool) -> String {
        if connection.isSetUp && !enabled { return "Off" }
        if let files = connection as? ImportFolderWatcher, connection.method == session.primary?.method,
           files.problem == nil, files.isWatching, files.waitingForICloud == 0, let name = files.folderDisplayName {
            return name
        }
        return connection.summary
    }

    private func symbol(_ method: ConnectionMethod, _ connection: any DeviceConnection) -> String {
        guard method.kind == .direct else { return method.systemImage }
        switch connection.state {
        case .connected: return "antenna.radiowaves.left.and.right"
        case .searching, .connecting, .reconnecting: return "dot.radiowaves.left.and.right"
        default: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    /// One action per row, and only one that works now and isn't offered elsewhere on the page:
    /// connecting, and moving a recorder to this Mac, are the page's own action above.
    @ViewBuilder
    private func action(_ method: ConnectionMethod, _ connection: any DeviceConnection, enabled: Bool,
                        covered: Set<DeviceProblemAction>) -> some View {
        if session.kind.id == DaybookPhoneIntegration.id {
            // The phone connects to this Mac itself; only pairing and sync need the person, and the
            // page's box asks for them.
            EmptyView()
        } else if !connection.isSetUp {
            Button(method.kind == .files ? "Choose Folder…" : "Set Up…") {
                if method.kind == .files { state.chooseDeviceFolder(for: session) }
                else { state.requestAddDevice(kind: session.kind.id, method: method.kind) }
            }
            .controlSize(.small)
        } else if !enabled {
            Button("Settings…") { DeviceActions.openSettings(openSettings) }.controlSize(.small)
        } else if let files = connection as? ImportFolderWatcher {
            if files.problem != nil {
                if covered.isDisjoint(with: [.chooseFolder, .setUpFolder]) {
                    Button("Choose Folder…") { state.chooseDeviceFolder(for: session) }.controlSize(.small)
                }
            } else if let folder = files.folder {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }.controlSize(.small)
            }
        }
    }
}

/// "Recommended", for the method setup offers first: a label, in the secondary ink, since the
/// accent is for what you can act on.
struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(DaybookStyle.quietFill, in: Capsule())
    }
}

/// Recently imported: the library's latest from this device, and anything that didn't import.
struct RecentImports: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    /// "Recent imports", which holds what didn't import too.
    var heading = "Recent imports"

    private enum Entry: Identifiable {
        case imported(DeviceLibraryLinks.Entry)
        case failed(DeviceImportFailure)
        var id: String {
            switch self {
            case .imported(let entry): return entry.trackID.uuidString
            case .failed(let failure): return "failed:" + failure.id
            }
        }
        var date: Date {
            switch self {
            case .imported(let entry): return entry.importedAt
            case .failed(let failure): return failure.date
            }
        }
    }

    var body: some View {
        let entries = (session.links.recent.map(Entry.imported) + session.failures.map(Entry.failed))
            .sorted { $0.date > $1.date }.prefix(10)
        if !entries.isEmpty {
            DeviceHeading(heading)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s3, verticalSpacing: Space.s2) {
                ForEach(Array(entries)) { entry in row(entry) }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry {
        case .imported(let item):
            let meeting = state.meetings.first { $0.id == item.meetingID }
            GridRow {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.meta).frame(width: 20).accessibilityHidden(true)
                Text(label(item)).font(TypeStyle.body()).foregroundStyle(Ink.body).monospacedDigit().lineLimit(1).truncationMode(.middle)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let meeting {
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Ink.meta).accessibilityHidden(true)
                        Button(meeting.title) { state.showConversation(meeting.id) }
                            .buttonStyle(.daybookLink)
                            .font(TypeStyle.body())
                            .lineLimit(1)
                        if let processing = state.deviceProcessingLabel(meeting.id) {
                            Text("· \(processing)").font(TypeStyle.body()).foregroundStyle(Ink.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        case .failed(let failure):
            GridRow {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning).frame(width: 20).accessibilityHidden(true)
                Text(failure.recording.title).font(TypeStyle.body()).foregroundStyle(Ink.body).monospacedDigit().lineLimit(1).truncationMode(.middle)
                HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                    Text(failure.message).font(TypeStyle.status).foregroundStyle(Ink.secondary).lineLimit(1)
                    if failure.id != retriedAbove {
                        Button("Try Again") { session.retry(failure) }
                            .buttonStyle(.daybookLink).font(TypeStyle.status)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The failure the problem box's Try Again retries, which its row doesn't offer again.
    private var retriedAbove: String? {
        guard let problem = session.problem, problem.isTransferProblem, problem.actions.contains(.tryAgain) else { return nil }
        return session.failures.first?.id
    }

    /// "Mon 19 Oct, 4:00 PM" for a recorder's recording, the file name for an export.
    private func label(_ entry: DeviceLibraryLinks.Entry) -> String {
        // Daybook on iPhone's recordings are named by a UUID; their start says more.
        if session.kind.id == DaybookPhoneIntegration.id { return DeviceDateFormat.title(entry.importedAt) }
        let identity = DeviceRecordingIdentity(kind: session.kind.id, serial: session.recorderSerial, recordingID: entry.recordingID)
        if let date = DeviceRecordingStart.date(of: identity) {
            let title = DeviceDateFormat.title(date)
            return entry.recordingID.hasSuffix(DeviceLibraryLinks.partialSuffix) ? "\(title) (live)" : title
        }
        if entry.recordingID.hasPrefix("file:") {
            return String(entry.recordingID.dropFirst(5).split(separator: "|").first ?? Substring(entry.fileName))
        }
        return entry.fileName
    }
}

// MARK: - More menu

/// The device's More menu (`ellipsis`) in the detail toolbar, built from its capabilities.
struct DeviceMoreMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: DeviceSession
    @ObservedObject var browser: DeviceBrowser
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            let primary = session.primary
            let connected = primary?.state.isConnected == true
            let busy = session.queue.current != nil
            Button("Refresh Status") { primary?.refresh() }
                .disabled(!connected || busy || primary?.isRefreshing == true)
            if let control = session.direct as? any RecordControlConnection {
                Divider()
                if session.status?.isRecording == true {
                    Button("Pause Recording on \(session.kind.shortName)") { control.pauseRecording() }
                        .disabled(!session.isLinked || control.recordCommandPending || busy)
                } else {
                    Button("Start Recording on \(session.kind.shortName)") { control.startRecording() }
                        .disabled(!session.isLinked || control.recordCommandPending || busy)
                }
            }
            if let live = session.direct as? any LiveListeningConnection {
                Button(live.live.isListening ? "Stop Listening" : "Listen Live") {
                    if live.live.isListening { live.stopListening() } else { browser.selection = [.recordingNow]; live.startListening() }
                }
                .disabled(session.status?.isRecording != true || !session.isLinked || busy)
            }
            Divider()
            if session.direct is any DetailedConnection {
                Button("Device Details…") { browser.showingDetails = true }
                    .disabled(session.status == nil && !session.isLinked)
            }
            if let direct = session.direct, direct.isSetUp, session.kind.id != DaybookPhoneIntegration.id {
                if direct.state.isConnected || direct.state.isBusy {
                    Button("Disconnect") { session.disconnect(.direct) }
                } else if session.managedElsewhere == nil {
                    // Connect does nothing while another device manages it: Use on This Mac, below, does.
                    Button("Connect") { session.connect() }
                        .disabled(direct.state == .unavailable || !session.device.isEnabled(.direct))
                }
                RecorderHandoffMenuItems(state: state, session: session)
            }
            Divider()
            Button("Device Settings…") { DeviceActions.openSettings(openSettings) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
        .popover(isPresented: $browser.showingDetails, arrowEdge: .bottom) {
            DeviceDetailsView(session: session, browser: browser)
        }
    }
}
