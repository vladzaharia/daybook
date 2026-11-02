import DaybookDesign
import DaybookKit
import SwiftUI

// Everything on a recorder (docs/devices.md, "Interface"): the recording it's making, the import queue, what's new
// on it, and what's already in Daybook. The Mac shows it in the list column beside the device page, where a
// selection opens a recording's page; the iPhone pushes it as All Recordings from the page. A recording's
// actions are one list (`DeviceRecordingActions`), in a context menu on both and as swipes on the iPhone.

/// Something to do with recordings on a recorder.
public enum DeviceRecordingAction: Hashable {
    /// Import the chosen recordings, each as a new conversation.
    case importRecordings(Int)
    /// Import into the conversation recorded at the same time.
    case addTo(Meeting.ID, title: String)
    case chooseConversation
    case removeFromQueue
    case stopImporting
    case showConversation(Meeting.ID)
    case showInFinder(Meeting.ID)
    case listenLive
    case stopListening

    public var title: String {
        switch self {
        case .importRecordings(let count): return count > 1 ? "Import \(count) Recordings" : "Import"
        case .addTo(_, let title): return "Add to “\(title)”"
        case .chooseConversation: return "Choose Conversation…"
        case .removeFromQueue: return "Remove from Queue"
        case .stopImporting: return "Stop Importing"
        case .showConversation: return "Show Conversation"
        case .showInFinder: return "Show Audio File in Finder"
        case .listenLive: return "Listen Live"
        case .stopListening: return "Stop Listening"
        }
    }
}

public enum DeviceRecordingActions {
    /// What can be done with the chosen rows now, in order; never one that can't run. `revealsAudio`: this device
    /// can show an imported recording's audio file (the Mac's Finder).
    @MainActor
    public static func available(_ rows: Set<DeviceBrowser.Row>, in session: DeviceSession, revealsAudio: Bool) -> [DeviceRecordingAction] {
        if rows.contains(.recordingNow) {
            guard let live = session.direct as? any LiveListeningConnection else { return [] }
            if live.live.isListening { return [.stopListening] }
            return session.queue.current == nil && session.isLinked ? [.listenLive] : []
        }
        let ids = rows.compactMap(\.recordingID)
        guard !ids.isEmpty else { return [] }
        let links = session.links
        if let current = session.queue.current, ids == [current.id] { return [.stopImporting] }
        if ids.allSatisfy({ session.queue.isWaiting($0) }) { return [.removeFromQueue] }
        let recordings = recordings(ids, in: session)
        let imported = recordings.filter { links.imported[$0.id] != nil }
        let fresh = recordings.filter { links.imported[$0.id] == nil && !session.queue.contains($0.id) }
        if !fresh.isEmpty, imported.isEmpty, session.importsHere {
            var actions: [DeviceRecordingAction] = [.importRecordings(fresh.count)]
            if fresh.count == 1 {
                actions += session.overlaps(fresh[0]).map { .addTo($0.meetingID, title: $0.title) }
            }
            actions.append(.chooseConversation)
            return actions
        }
        // A recording in Daybook is in one conversation, which an import of it again would join rather than copy
        // (docs/devices.md, "Library identity"): it opens there, and imports again once that conversation is gone.
        if imported.count == 1, recordings.count == 1, let recording = imported.first, let meetingID = links.imported[recording.id] {
            var actions: [DeviceRecordingAction] = [.showConversation(meetingID)]
            if revealsAudio { actions.append(.showInFinder(meetingID)) }
            return actions
        }
        return []
    }

    /// The recordings rows name: what the recorder lists, and what's queued from it.
    @MainActor
    static func recordings(_ ids: [String], in session: DeviceSession) -> [DeviceRecording] {
        let listed = session.primary?.recordings ?? []
        let queued = ([session.queue.current].compactMap { $0 } + session.queue.waiting).map(\.recording)
        return ids.compactMap { id in listed.first { $0.id == id } ?? queued.first { $0.id == id } }
    }

    /// Does what an action says, for the chosen recordings.
    @MainActor
    public static func perform(_ action: DeviceRecordingAction, recordings: [DeviceRecording], session: DeviceSession,
                               services: RecorderServices?, choose: ([DeviceRecording]) -> Void) {
        switch action {
        case .importRecordings: session.importRecordings(recordings.filter { session.links.imported[$0.id] == nil })
        case .addTo(let meetingID, _): session.importRecordings(recordings, attachTo: meetingID)
        case .chooseConversation: choose(recordings)
        case .removeFromQueue: recordings.forEach { session.removeFromQueue($0.id) }
        case .stopImporting: services?.stopImporting(session, false) ?? session.stopCurrent()
        case .showConversation(let id): services?.showConversation(id)
        case .showInFinder(let id): if let recording = recordings.first { services?.revealAudio?(id, recording.id) }
        case .listenLive:
            session.browser.selection = [.recordingNow]
            (session.direct as? any LiveListeningConnection)?.startListening()
            services?.showListenLive?(session)
        case .stopListening: (session.direct as? any LiveListeningConnection)?.stopListening()
        }
    }
}

/// A recording's actions as menu items: a row's context menu, a recording's page.
public struct DeviceRecordingMenuItems: View {
    private let session: DeviceSession
    private let rows: Set<DeviceBrowser.Row>
    private let choose: ([DeviceRecording]) -> Void
    @Environment(\.recorderServices) private var services

    public init(session: DeviceSession, rows: Set<DeviceBrowser.Row>, choose: @escaping ([DeviceRecording]) -> Void) {
        self.session = session
        self.rows = rows
        self.choose = choose
    }

    /// For recordings, choosing a conversation in the recorder's browser.
    public init(session: DeviceSession, recordings: [DeviceRecording]) {
        self.init(session: session, rows: Set(recordings.map { .recording($0.id) })) { chosen in
            session.browser.choosingConversation = .init(recordings: chosen)
        }
    }

    public var body: some View {
        let actions = DeviceRecordingActions.available(rows, in: session, revealsAudio: services?.revealAudio != nil)
        let recordings = DeviceRecordingActions.recordings(rows.compactMap(\.recordingID), in: session)
        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
            // Moving it elsewhere starts a group of its own.
            if index > 0, action == .chooseConversation { Divider() }
            Button(action.title) {
                DeviceRecordingActions.perform(action, recordings: recordings, session: session, services: services, choose: choose)
            }
        }
    }
}

// MARK: - The list

/// Everything on a recorder, by section: Recording Now, the import queue, New on <kind> (Import All), and Already in
/// Daybook (collapsed on the Mac until opened).
public struct DeviceRecordingsView: View {
    private let session: DeviceSession
    @Bindable private var browser: DeviceBrowser
    @Environment(\.recorderServices) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choosing: [DeviceRecording]?

    public init(session: DeviceSession) {
        self.session = session
        self.browser = session.browser
    }

    /// Daybook on iPhone: its recordings arrive through sync, so there's nothing to import.
    private var isPhone: Bool { session.kind.id == DaybookPhoneIntegration.id }

    public var body: some View {
        let split = session.split
        list(split)
            .overlay { if let empty = emptyState(split) { empty } }
            .daybookMotion(DaybookMotion.fade, value: session.queue.ids)
            .onAppear { session.primary?.refreshIfStale() }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .refreshable { session.primary?.refresh() }
            .sheet(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } })) {
                if let choosing { ConversationChooser(session: session, recordings: choosing) }
            }
            #endif
    }

    // MARK: Empty

    private func emptyState(_ split: DeviceRecordingSplit) -> AnyView? {
        let hasRows = !split.new.isEmpty || !split.imported.isEmpty || session.queue.isActive || split.inProgress != nil
        guard !hasRows, let primary = session.primary else { return nil }
        let kind = session.kind
        func unavailable(_ title: String, _ symbol: String, _ text: String?, animated: Bool = false,
                         action: (title: String, run: () -> Void)? = nil) -> AnyView {
            AnyView(ContentUnavailableView {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: animated && !reduceMotion)
                }
            } description: {
                if let text { Text(text) }
            } actions: {
                if let action { Button(action.title, action: action.run) }
            })
        }
        switch primary.state {
        case .notSetUp:
            if let setUp = services?.setUpMethod, let method = kind.preferredMethod {
                return unavailable("Not Set Up", kind.systemImage, nil, action: ("Set Up…", { setUp(session, method.kind) }))
            }
            return unavailable("Not Set Up", kind.systemImage, nil)
        case .searching:
            return unavailable("Looking for \(kind.name)…", "dot.radiowaves.left.and.right", nil, animated: true)
        case .connecting, .reconnecting:
            return unavailable(primary.state == .reconnecting ? "Reconnecting…" : "Connecting…", "dot.radiowaves.left.and.right", nil, animated: true)
        case .unavailable:
            // The page's box says why; the list only says why it's empty.
            if isPhone { return unavailable("Sync Is Off", "icloud.slash", nil) }
            return primary.method == .files
                ? unavailable("Not Watching", "folder.badge.questionmark", nil)
                : unavailable("Not Connected", "antenna.radiowaves.left.and.right.slash", nil)
        case .notConnected:
            if primary.method == .files {
                return unavailable("Not Watching", "folder", nil, action: ("Watch Folder", { primary.connect() }))
            }
            if let owner = session.managedElsewhere {
                return unavailable("Managed by \(owner.ownerName)", "antenna.radiowaves.left.and.right.slash", nil)
            }
            return unavailable("Not Connected", "antenna.radiowaves.left.and.right.slash",
                               "Take your \(kind.shortName) out of its case to wake it.", action: ("Connect", { session.connect() }))
        case .connected:
            if primary.isRefreshing || primary.inventoryUpdatedAt == nil {
                return AnyView(ContentUnavailableView {
                    Label { Text("Checking for Recordings…") } icon: { ProgressView().controlSize(.small) }
                })
            }
            if primary.method == .files, !isPhone {
                return unavailable("Watching for Audio", "folder.badge.gearshape", (primary as? ImportFolderWatcher)?.folderDisplayName)
            }
            return unavailable("No Recordings on Your \(kind.shortName)", kind.systemImage, kind.emptyHint)
        }
    }

    // MARK: Sections

    private func list(_ split: DeviceRecordingSplit) -> some View {
        let queue = session.queue
        let new = split.new.filter { !queue.contains($0.id) }
        let selectedNew = new.filter { browser.selection.contains(.recording($0.id)) }
        let canImport = session.importsHere && (session.primary?.state.isConnected == true || session.primary?.isSetUp == true)
        let fromFolder = session.primary?.method == .files
        #if os(macOS)
        let selection: Binding<Set<DeviceBrowser.Row>>? = $browser.selection
        #else
        let selection: Binding<Set<DeviceBrowser.Row>>? = nil
        #endif
        return List(selection: selection) {
            if let recording = split.inProgress {
                Section {
                    row(.recordingNow) {
                        RecordingNowRow(recording: recording, listening: session.isListeningLive)
                    }
                }
            }
            if queue.isActive {
                Section {
                    if let current = queue.current {
                        row(.recording(current.id)) {
                            ImportingRow(recording: current.recording, phase: session.phase ?? .preparing)
                        }
                    }
                    ForEach(queue.waiting) { item in
                        row(.recording(item.id)) {
                            WaitingRow(recording: item.recording, suspended: queue.isSuspended, deviceName: session.kind.shortName)
                        }
                    }
                } header: {
                    HStack {
                        Text(queue.isSuspended ? "Waiting to Reconnect" : "Importing")
                        Spacer()
                        Button("Stop") { services?.stopImporting(session, true) ?? session.stopAll() }
                            .buttonStyle(.daybookLink)
                    }
                }
            }
            if !new.isEmpty {
                Section {
                    ForEach(new) { recording in
                        row(.recording(recording.id)) {
                            NewRecordingRow(recording: recording, overlap: session.overlaps(recording).first,
                                            stale: session.primary?.state.isConnected != true,
                                            failure: session.failures.first { $0.id == recording.id }?.message,
                                            importAction: importButton(recording, canImport: canImport))
                        }
                    }
                } header: {
                    HStack {
                        Text(fromFolder ? "Not in Daybook" : "New on \(session.kind.shortName)")
                        Spacer()
                        if canImport {
                            Button(selectedNew.count > 1 ? "Import Selected (\(selectedNew.count))" : "Import All") {
                                session.importRecordings(selectedNew.count > 1 ? selectedNew : new)
                            }
                            .buttonStyle(.daybookLink)
                        } else if let updated = session.primary?.inventoryUpdatedAt {
                            Text(RecorderStatusWords.asOf(updated)).lineLimit(1)
                        }
                    }
                }
            } else if session.primary?.state.isConnected == true, !queue.isActive, session.primary?.inventoryUpdatedAt != nil,
                      !split.imported.isEmpty, !isPhone {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                        Text("You’re All Caught Up").daybookFont(.rowTitle)
                    }
                    .padding(.vertical, 6)
                    .selectionDisabled()
                }
            }
            if !split.imported.isEmpty {
                Section {
                    if isPhone || browser.showsImported || !Self.collapsesImported {
                        ForEach(split.imported) { item in
                            row(.recording(item.id)) {
                                ImportedRow(recording: item.recording, meeting: services?.library.meeting(item.meetingID),
                                            processing: services?.processingLabel(item.meetingID))
                            }
                        }
                    }
                } header: {
                    if isPhone {
                        // Everything from the phone is in the library already: its recordings are the list.
                        Text("Recordings")
                    } else if Self.collapsesImported {
                        Button {
                            withAnimation(DaybookMotion.resolved(DaybookMotion.fade, reduceMotion: reduceMotion)) { browser.showsImported.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(browser.showsImported ? 90 : 0))
                                Text("Already in Daybook")
                                Text("\(split.imported.count)").foregroundStyle(.secondary).monospacedDigit()
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Already in Daybook, \(split.imported.count) recordings")
                        .accessibilityHint(browser.showsImported ? "Collapses the list" : "Expands the list")
                    } else {
                        Text("Already in Daybook")
                    }
                }
            }
        }
        #if os(macOS)
        .contextMenu(forSelectionType: DeviceBrowser.Row.self) { rows in
            DeviceRecordingMenuItems(session: session, rows: rows) { chosen in browser.choosingConversation = .init(recordings: chosen) }
        } primaryAction: { rows in
            guard rows.count == 1, let id = rows.first?.recordingID, let meetingID = session.links.imported[id] else { return }
            services?.showConversation(meetingID)
        }
        .onExitCommand { browser.selection = [] }
        #endif
    }

    /// The Mac collapses Already in Daybook under its header; the iPhone lists it.
    private static var collapsesImported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// A row: its tag (the Mac's selection); on the iPhone, a tap that opens what it is, its context menu, and swipes.
    @ViewBuilder
    private func row<Content: View>(_ tag: DeviceBrowser.Row, @ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        content().tag(tag)
        #else
        let actions = DeviceRecordingActions.available([tag], in: session, revealsAudio: false)
        let recordings = DeviceRecordingActions.recordings(tag.recordingID.map { [$0] } ?? [], in: session)
        // Recording Now opens Listen Live; a recording in Daybook opens its conversation.
        let opens: (() -> Void)? = {
            if tag == .recordingNow, let show = services?.showListenLive { return { show(session) } }
            if let id = tag.recordingID, let meetingID = session.links.imported[id] { return { services?.showConversation(meetingID) } }
            return nil
        }()
        Group {
            if let opens {
                Button(action: opens) { content().contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            } else {
                content()
            }
        }
        .contextMenu {
            ForEach(actions, id: \.self) { action in Button(action.title) { perform(action, recordings) } }
        }
        .swipeActions(edge: .trailing) {
            ForEach(Array(actions.filter(\.swipes).prefix(2)), id: \.self) { action in
                Button(action.swipeTitle) { perform(action, recordings) }.tint(DaybookPalette.prominentFill)
            }
        }
        #endif
    }

    private func perform(_ action: DeviceRecordingAction, _ recordings: [DeviceRecording]) {
        DeviceRecordingActions.perform(action, recordings: recordings, session: session, services: services) { choosing = $0 }
    }

    /// Import, beside a new recording on the iPhone, where a row has room for it.
    private func importButton(_ recording: DeviceRecording, canImport: Bool) -> AnyView? {
        #if os(iOS)
        guard canImport, session.isConnected else { return nil }
        return AnyView(Button("Import") { session.importRecordings([recording]) }
            .buttonStyle(.daybookTinted)
            .accessibilityLabel("Import \(recording.title)"))
        #else
        return nil
        #endif
    }
}

extension DeviceRecordingAction {
    /// Offered as a swipe on the iPhone: importing, and adding it to a conversation.
    var swipes: Bool {
        switch self {
        case .importRecordings, .addTo, .removeFromQueue: return true
        default: return false
        }
    }

    /// A swipe's shorter words.
    var swipeTitle: String {
        switch self {
        case .addTo(_, let title): return "Add to “\(title)”"
        case .removeFromQueue: return "Remove"
        default: return title
        }
    }
}

// MARK: - Rows

private struct RowLayout<Glyph: View, Content: View, Trailing: View>: View {
    @ViewBuilder var glyph: Glyph
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
            glyph.frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 6)
    }
}

extension RowLayout where Trailing == EmptyView {
    init(@ViewBuilder glyph: () -> Glyph, @ViewBuilder content: () -> Content) {
        self.init(glyph: glyph, content: content, trailing: { EmptyView() })
    }
}

private struct NewRecordingRow: View {
    let recording: DeviceRecording
    let overlap: DeviceOverlap?
    let stale: Bool
    let failure: String?
    let importAction: AnyView?

    var body: some View {
        RowLayout {
            Image(systemName: failure == nil ? "arrow.down.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(DaybookPalette.Ink.warning))
        } content: {
            Text(recording.title).daybookFont(.rowTitle).monospacedDigit().lineLimit(1).truncationMode(.middle)
            Text(failure ?? recording.detail).daybookFont(.rowDetail).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
            if let overlap {
                Label { Text("Overlaps “\(overlap.title)”").lineLimit(1) } icon: { Image(systemName: "link") }
                    .daybookFont(.rowDetail).foregroundStyle(.secondary)
                    .labelStyle(InlineGlyphLabelStyle())
            }
        } trailing: {
            if let importAction { importAction }
        }
        .opacity(stale ? 0.65 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recording.title), \(recording.length?.inlineLabel ?? recording.detail), not in Daybook yet"
                            + (overlap.map { ", overlaps \($0.title)" } ?? "") + (failure.map { ", \($0)" } ?? ""))
    }
}

private struct ImportingRow: View {
    let recording: DeviceRecording
    let phase: TransferPhase

    var body: some View {
        RowLayout {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(DaybookPalette.accent)
                .symbolEffect(.pulse, isActive: phase == .preparing)
        } content: {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title).daybookFont(.rowTitle).monospacedDigit().lineLimit(1)
                Spacer()
                Text(phase.label).daybookFont(.rowDetail).foregroundStyle(.secondary).monospacedDigit()
            }
            // The brand gradient bar, as for all progress; it waits empty until the transfer reports a fraction.
            ProgressView(value: phase.fraction ?? 0)
                .progressViewStyle(.brand(width: nil))
                .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recording.title), importing, \(phase.label)")
        .accessibilityValue(phase.fraction.map { "\(Int($0 * 100)) percent" } ?? "")
    }
}

private struct WaitingRow: View {
    let recording: DeviceRecording
    let suspended: Bool
    let deviceName: String

    var body: some View {
        RowLayout {
            Image(systemName: "arrow.down.circle.dotted").foregroundStyle(.secondary)
        } content: {
            Text(recording.title).daybookFont(.rowTitle).monospacedDigit().lineLimit(1)
            Text(suspended ? "Waiting for \(deviceName)" : "Waiting").daybookFont(.rowDetail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ImportedRow: View {
    let recording: DeviceRecording
    let meeting: Meeting?
    let processing: String?

    var body: some View {
        RowLayout {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        } content: {
            Text(meeting?.title ?? recording.title).daybookFont(.rowTitle).lineLimit(1)
            Text(([recording.title, recording.length?.label].compactMap { $0 } + (processing.map { [$0] } ?? [])).joined(separator: " · "))
                .daybookFont(.rowDetail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingNowRow: View {
    let recording: DeviceRecording
    let listening: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RowLayout {
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.hierarchical).foregroundStyle(DaybookPalette.Ink.record)
                .symbolEffect(.breathe, isActive: !reduceMotion)
        } content: {
            Text("Recording Now").daybookFont(.rowTitle)
            HStack(spacing: 4) {
                if let start = recording.startedAt { Text("Started \(start.formatted(date: .omitted, time: .shortened))") }
                if listening {
                    Text("·")
                    Image(systemName: "waveform").foregroundStyle(DaybookPalette.liveGlyph)
                        .symbolEffect(.variableColor.iterative, isActive: !reduceMotion && scheme == .dark)
                    Text("Listening")
                }
            }
            .daybookFont(.rowDetail).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A glyph tucked against its words, for a row's details.
struct InlineGlyphLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
    }
}

// MARK: - Choose Conversation…

/// Adds a recorder's recordings to a conversation from the same day, give or take one, found by its title: a sheet
/// on both devices.
public struct ConversationChooser: View {
    private let session: DeviceSession
    private let recordings: [DeviceRecording]
    @State private var search = ""
    @State private var selection: Meeting.ID?
    @Environment(\.recorderServices) private var services
    @Environment(\.dismiss) private var dismiss

    public init(session: DeviceSession, recordings: [DeviceRecording]) {
        self.session = session
        self.recordings = recordings
    }

    /// Conversations near the recordings' days whose titles match `search`, newest first.
    public static func candidates(_ meetings: [Meeting], near recordings: [DeviceRecording], search: String,
                                  calendar: Calendar = .current) -> [Meeting] {
        let days = recordings.compactMap(\.sortDate).map { calendar.startOfDay(for: $0) }
        let query = search.trimmingCharacters(in: .whitespaces)
        return meetings.filter { meeting in
            let day = calendar.startOfDay(for: meeting.date)
            let near = days.isEmpty || days.contains { abs(calendar.dateComponents([.day], from: $0, to: day).day ?? 99) <= 1 }
            return near && (query.isEmpty || meeting.title.localizedCaseInsensitiveContains(query))
        }
        .sorted { $0.date > $1.date }
    }

    private var candidates: [Meeting] {
        Self.candidates(services?.library.meetings ?? [], near: recordings, search: search)
    }

    private func add(_ id: Meeting.ID) {
        session.importRecordings(recordings, attachTo: id)
        dismiss()
    }

    public var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            Text("Add to a Conversation").font(.title3.weight(.semibold))
            TextField("Search Conversations", text: $search).textFieldStyle(.roundedBorder)
            List(candidates, selection: $selection) { meeting in
                row(meeting).tag(meeting.id)
            }
            .frame(height: 220)
            .overlay {
                if candidates.isEmpty { Text("No conversations from around that day.").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import and Add") { if let selection { add(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(DaybookSpacing.s5)
        .frame(width: 440)
        #else
        NavigationStack {
            List(candidates) { meeting in
                Button { add(meeting.id) } label: { row(meeting) }
                    .buttonStyle(.plain)
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("No Conversations", systemImage: "magnifyingglass",
                                           description: Text("No conversations from around that day."))
                }
            }
            .searchable(text: $search, prompt: "Search Conversations")
            .navigationTitle("Add to a Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        #endif
    }

    private func row(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).daybookFont(.rowTitle).foregroundStyle(DaybookPalette.Ink.title)
            Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).daybookFont(.rowDetail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
