import AppKit
import DaybookCaptions
import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// A photo open in the viewer.
struct PhotoViewerRequest: Identifiable, Equatable { let id: UUID }

/// A conversation: its page (Summary or Transcript, or both side by side where the column has room for two pages),
/// toolbar, and player.
struct MeetingDetailView: View {
    @Bindable var state: AppState
    let meetingID: UUID
    @State private var playbackRequest: Task<Void, Never>?
    @State private var viewingPhoto: PhotoViewerRequest?
    @Environment(\.readingScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var meeting: Meeting? { state.meetings.first { $0.id == meetingID } }

    var body: some View {
        if let meeting {
            // Saved live captions turn to the Transcript side until a transcript replaces them, as on the iPhone
            // (`AppState.hasTranscriptPage`, from the captions read off the main actor).
            let hasTranscript = state.hasTranscriptPage(meeting)
            let mode: PageMode = hasTranscript ? state.pageMode : .summary
            // Two pages where the column has room for them (`PageSpread`, from 1120 pt): the summary under the title,
            // and beside it, past a hairline, the transcript, scrolling and following the playhead on its own. The
            // person can collapse it to one page from the toolbar.
            let pairs = hasTranscript && state.pageSpreadChosen
            Group {
                if pairs {
                    PageSpread(twoPagesFit: state.pageSpreadFits) {
                        SummaryPage(state: state, player: state.playback, meeting: meeting, besideTranscript: true, play: play)
                            .pageOfSpread(PageMode.summary.title)
                    } trailing: {
                        TranscriptPage(state: state, player: state.playback, meeting: meeting, titled: false, play: play)
                            .pageOfSpread(PageMode.transcript.title)
                    } single: {
                        page(mode, meeting)
                    }
                } else {
                    page(mode, meeting)
                }
            }
            .animation(DaybookMotion.resolved(DaybookMotion.pageTurn, reduceMotion: reduceMotion), value: pairs)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DaybookStyle.paper)
            // The toolbar's switch and the View menu follow the room the column has (`PageSides`).
            .onGeometryChange(for: Bool.self) { PageSpreadLayout.split(width: $0.size.width, crease: nil) != nil } action: {
                if state.pageSpreadFits != $0 { state.pageSpreadFits = $0 }
            }
            .bottomBar {
                PlayerBar(player: state.playback, meeting: meeting, isRecording: state.isRecording) { trackID, seconds in
                    state.addPlaybackHighlight(meeting.id, trackID: trackID, seconds: seconds)
                }
            }
            .onDisappear {
                playbackRequest?.cancel()
                if state.playback.meetingID == meetingID { state.playback.unload() }
            }
            .environment(\.openPhoto) { viewingPhoto = PhotoViewerRequest(id: $0.id) }
            .sheet(item: $viewingPhoto) { request in PhotoViewer(state: state, meetingID: meetingID, photoID: request.id, play: play) }
            .modifier(PhotoDropTarget(state: state, meetingID: meetingID))
            // Photos synced from another device, or added before the models were here, are read when seen.
            .task(id: "\(meetingID):\(meeting.visiblePhotos.filter { $0.analysis == nil }.map(\.id)):\(state.photoModel?.description ?? "vision"):\(state.recordingID?.uuidString ?? "idle")") {
                state.readPhotosWhenIdle(meetingID)
                #if DEBUG
                if PhotoDemo.opensPhoto, viewingPhoto == nil, meeting.visiblePhotos.allSatisfy({ $0.analysis != nil }), let first = meeting.visiblePhotos.first {
                    try? await Task.sleep(for: .milliseconds(600))
                    viewingPhoto = PhotoViewerRequest(id: first.id)
                }
                #endif
            }
        }
    }

    /// One page: the side chosen, turning with a fade.
    private func page(_ mode: PageMode, _ meeting: Meeting) -> some View {
        Group {
            switch mode {
            case .summary: SummaryPage(state: state, player: state.playback, meeting: meeting, play: play)
            case .transcript: TranscriptPage(state: state, player: state.playback, meeting: meeting, play: play)
            }
        }
        .transition(.opacity)
        .animation(DaybookMotion.resolved(DaybookMotion.pageTurn, reduceMotion: reduceMotion), value: mode)
    }

    /// What a passage, a time, or a recording plays: resolved as on the iPhone (`PlaybackTarget`).
    private func play(_ target: PlaybackTarget) {
        guard let meeting, !state.isRecording, let resolved = target.resolve(in: meeting) else { return }
        requestPlayback(resolved.track, at: resolved.seconds)
    }

    private func requestPlayback(_ track: RecordingTrack, at seconds: Double) {
        playbackRequest?.cancel()
        let animation = DaybookMotion.resolved(Motion.state, reduceMotion: reduceMotion)
        playbackRequest = Task {
            guard let url = await state.audioURL(for: track, meetingID: meetingID), !Task.isCancelled,
                  state.selectedID == meetingID || state.place.isDevice else { return }
            withAnimation(animation) { state.playback.play(url: url, at: seconds, trackID: track.id, meetingID: meetingID) }
        }
    }
}

private extension View {
    /// A page of the spread: one container for VoiceOver, named for its side, and one region for keyboard focus, which
    /// Tab leaves for the other page in reading order.
    func pageOfSpread(_ name: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityLabel(name)
            .focusSection()
    }
}

/// The page reads the library itself. The window redrawing it for the same conversation (the app has one
/// state) adds nothing, so it isn't drawn again: each change of the library draws the page once.
extension MeetingDetailView: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.meetingID == rhs.meetingID }
}

// MARK: - Toolbar

/// The detail toolbar, declared once on the window's stable detail column: Record, then the view switch and More,
/// then the inspector toggle. The groups never come and go: what doesn't apply is dimmed, so Record stays under the
/// pointer from one conversation to the next and on a device's page, where More holds the device's items. The view
/// switch's slot keeps its width when Bookmark takes it during a recording, so nothing beside it moves.
///
/// It isn't customizable: as a customizable toolbar (`.toolbar(id:)`), a window too narrow for its items now and then
/// laid itself out without end at launch on macOS 27.2, and AppKit stopped the app.
struct DetailToolbar: ToolbarContent {
    @Bindable var state: AppState
    let meeting: Meeting?
    /// Whether the inspector can show for what's on the page (a conversation in the list, not a device's page).
    let inspectorAvailable: Bool
    /// The inspector shows now.
    let inspectorShown: Bool
    /// Shows or hides it (a narrow window widens for it).
    let toggleInspector: () -> Void
    /// What the window does for an action of More's that needs it: share (the sharing picker hangs from it) and Tags…
    /// (the inspector).
    let windowAction: (ConversationAction.ID, Meeting) -> Void

    /// The device whose page shows, when no conversation does: its items fill More.
    private var device: DeviceSession? {
        guard meeting == nil, state.place.isDevice, !state.isSearching else { return nil }
        return state.selectedDevice
    }

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            // Stop is a red pill with its own colours, not on the toolbar's shared glass.
            recordItem.sharedBackgroundVisibility(RecordControl.Phase(state) == .recording ? .hidden : .automatic)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        } else {
            recordItem
        }
        ToolbarItemGroup(placement: .primaryAction) {
            PageSwitch(state: state, meeting: meeting)
            MoreButton(state: state, meeting: meeting, device: device, windowAction: windowAction)
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItem(placement: .primaryAction) {
            Button(action: toggleInspector) { Label("Inspector", systemImage: "sidebar.trailing") }
                .disabled(!inspectorAvailable)
                .help(inspectorShown ? "Hide Inspector (⌃⌘I)" : "Show Inspector (⌃⌘I)")
        }
    }

    private var recordItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { RecordControl(state: state) }
    }
}

/// Summary | Transcript, or Bookmark while this conversation records, in a slot that keeps the switch's width. Where
/// the column has room for two pages it's a pair of toggles, both lit while both pages show: a lit one keeps its page
/// alone, the other puts its page back beside it (`PageSides`). Otherwise it's a switch between the two.
private struct PageSwitch: View {
    @Bindable var state: AppState
    let meeting: Meeting?

    var body: some View {
        let recording = meeting.map { state.recordingID == $0.id } ?? false
        // Saved live captions count, as the page reads them (`AppState.hasTranscriptPage`).
        let hasTranscript = meeting.map { state.hasTranscriptPage($0) } ?? false
        let pairs = meeting.map { state.pairsPages($0) } ?? false
        let help = help(hasTranscript: hasTranscript)
        // Laid out always, so the slot is the switch's width whatever shows in it: the toggles where the column has room
        // for two pages, and Bookmark while recording, cover it.
        Picker("View", selection: hasTranscript ? $state.pageMode : .constant(.summary)) {
            ForEach(PageMode.allCases) { mode in Text(mode.title).tag(mode) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!hasTranscript || recording || pairs)
        .opacity(recording || pairs ? 0 : 1)
        .accessibilityHidden(recording || pairs)
        .help(help)
        .overlay {
            if let meeting, pairs, !recording {
                PageToggles(sides: state.pageSides(meeting), help: help) { state.choosePage($0, for: meeting) }
            }
        }
        .overlay {
            if let meeting, recording {
                Button { state.addHighlight(meeting.id) } label: {
                    Label {
                        Text("Bookmark")
                    } icon: {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(DaybookStyle.bookmark)
                            .daybookBounce(value: meeting.highlights.count)
                    }
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Add Bookmark (⌘D)")
            }
        }
    }

    private func help(hasTranscript: Bool) -> String {
        guard let meeting else { return "Choose a conversation" }
        guard hasTranscript else { return "Not transcribed yet" }
        guard state.pairsPages(meeting) else { return "Show the summary (⌘1) or the transcript (⌘2)" }
        if state.showsPageSpread(meeting) { return "Show only the summary (⌘1) or only the transcript (⌘2)" }
        let other: PageMode = state.pageMode == .summary ? .transcript : .summary
        return "Show the \(other.title.lowercased()) beside the \(state.pageMode.title.lowercased()) (⌘\(other == .summary ? 1 : 2))"
    }
}

/// Summary | Transcript as a pair of toggles in the switch's own segmented control, so it stays the same capsule: an
/// `NSSegmentedControl` that selects any, lit as `PageSides` says. A click asks for its side; the segments then show
/// what the page shows, not what the click toggled.
private struct PageToggles: NSViewRepresentable {
    let sides: PageSides
    let help: String
    let choose: (PageMode) -> Void
    @Environment(\.controlSize) private var controlSize

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: PageMode.allCases.map(\.title), trackingMode: .selectAny,
                                         target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        control.setAccessibilityLabel("View")
        // The switch's slot, its segments as wide as their words, as the switch's are.
        control.segmentDistribution = .fillProportionally
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.choose = choose
        context.coordinator.sides = sides
        context.coordinator.light(control)
        control.toolTip = help
        control.controlSize = switch controlSize {
        case .mini: .mini
        case .small: .small
        case .large: .large
        default: .regular
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(sides: sides, choose: choose) }

    @MainActor
    final class Coordinator: NSObject {
        var sides: PageSides
        var choose: (PageMode) -> Void

        init(sides: PageSides, choose: @escaping (PageMode) -> Void) {
            self.sides = sides
            self.choose = choose
        }

        /// Each segment lit while its page shows.
        func light(_ control: NSSegmentedControl) {
            for (index, side) in PageMode.allCases.enumerated() where control.isSelected(forSegment: index) != sides.shows(side) {
                control.setSelected(sides.shows(side), forSegment: index)
            }
        }

        @objc func clicked(_ control: NSSegmentedControl) {
            // The segment the click toggled is the one that no longer matches what shows.
            let side = PageMode.allCases.enumerated().first { control.isSelected(forSegment: $0.offset) != sides.shows($0.element) }?.element
            light(control)
            if let side { choose(side) }
        }
    }
}

/// More: the conversation's actions, or on a device's page the device's.
private struct MoreButton: View {
    let state: AppState
    let meeting: Meeting?
    let device: DeviceSession?
    let windowAction: (ConversationAction.ID, Meeting) -> Void

    var body: some View {
        Menu {
            if let meeting {
                ConversationMoreMenu(state: state, meeting: meeting, windowAction: windowAction)
            } else if let device {
                DeviceMoreMenuContent(state: state, session: device)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .disabled(meeting == nil && device == nil)
        .help("More")
    }
}

/// The conversation's More menu: what DaybookKit's `ConversationActions` lists, in its order (share, add, reprocess,
/// history, filing, the Trash), as the iPhone's More menu lists it. What doesn't apply now is dimmed, its reason as help.
struct ConversationMoreMenu: View {
    let state: AppState
    let meeting: Meeting
    let windowAction: (ConversationAction.ID, Meeting) -> Void

    var body: some View {
        ConversationActionMenuItems(ConversationActions.actions(for: meeting, context: MoreMenuActions.context(state, meeting)), platform: .mac,
                                    perform: { id in
                                        if MoreMenuActions.needsWindow(id) { windowAction(id, meeting) }
                                        else { MoreMenuActions.perform(id, meeting: meeting, state: state) }
                                    },
                                    custom: { MoreMenuActions.custom($0, meeting: meeting, state: state) })
    }
}

/// Reprocess ▸, as the More menu has it, for the inspector and a row's menu.
struct ReprocessMenu: View {
    let state: AppState
    let meeting: Meeting
    var body: some View {
        let groups = ConversationActions.actions(for: meeting, context: MoreMenuActions.context(state, meeting)).filter { $0.id == .reprocess }
        ConversationActionMenuItems(groups, platform: .mac) { MoreMenuActions.perform($0, meeting: meeting, state: state) }
    }
}

/// What the Mac does for each of a conversation's actions (`ConversationActions`).
@MainActor
enum MoreMenuActions {
    /// What the Mac knows about a conversation for its actions: recording here, or being processed here.
    static func context(_ state: AppState, _ meeting: Meeting) -> ConversationActions.Context {
        let recording = state.recordingID == meeting.id && (state.isRecording || state.isStartingRecording || state.isStoppingRecording)
        return ConversationActions.Context(platform: .mac, isRecording: recording, isProcessingHere: state.processingID == meeting.id,
                                           status: state.processingStatus(for: meeting))
    }

    /// Actions the window answers itself: sharing hangs its picker from it, and Tags… opens its inspector.
    static func needsWindow(_ id: ConversationAction.ID) -> Bool {
        switch id {
        case .shareMarkdown, .shareAudio, .tags: return true
        default: return false
        }
    }

    static func perform(_ id: ConversationAction.ID, meeting: Meeting, state: AppState) {
        switch id {
        case .copySummary: state.copySummary(meeting.id)
        case .exportMarkdown: state.export(meeting.id)
        case .exportJSON: state.export(meeting.id, json: true)
        case .showFloatingNotes: state.showNotes(for: meeting.id)
        case .addPhotos: state.chooseAddPhoto(to: meeting.id)
        case .addRecordingFromFile: state.chooseImport(attachTo: meeting.id)
        case .process(let mode): state.enqueue(meeting.id, mode: mode)
        case .versionHistory:
            state.selectedID = meeting.id
            state.activeSheet = .versionHistory
        case .rename:
            state.selectedID = meeting.id
            state.focusTitle(meeting.id)
        case .moveTo(let placement): state.setPlacement([meeting.id], placement)
        case .showInFinder: state.showInFinder(meeting.id)
        case .moveToTrash: state.trashRequestIDs = [meeting.id]
        case .moveToFolder, .addRecording, .share, .export, .reprocess:
            break // Menus.
        case .shareMarkdown, .shareJSON, .shareAudio, .tags:
            break // The window's (`needsWindow`), or the iPhone's.
        case .takePhoto:
            break // The iPhone's.
        case .play, .adjustTiming, .showOriginalTranscript, .moveToNewConversation, .removeRecording:
            break // A recording's, in the inspector.
        }
    }

    /// The Mac's own submenus: Move to Folder lists the folders, and Add Recording each recorder beside a file.
    static func custom(_ action: ConversationAction, meeting: Meeting, state: AppState) -> AnyView? {
        switch action.id {
        case .moveToFolder:
            return AnyView(Menu { FolderMenuItems(state: state, meetingIDs: [meeting.id]) } label: {
                Label(action.title, systemImage: action.symbol)
            }
            .disabled(!action.isAvailable))
        case .addRecording:
            return AnyView(Menu {
                Button("From a File…") { state.chooseImport(attachTo: meeting.id) }
                AddRecordingFromDeviceItems(state: state)
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
            .disabled(!action.isAvailable)
            .help({ if case .unavailable(let why) = action.availability { return why } else { return "" } }()))
        default:
            return nil
        }
    }
}

// MARK: - Sharing

/// Share ▸ Markdown… and Audio… on the Mac: the files the iPhone's share sheet gets (DaybookKit's `ExportFiles`), made
/// off the main actor, then the system's sharing picker (Mail, Messages, AirDrop, Notes…) hanging from the top of the
/// page, under the toolbar's More. Each share's files go once it's done with them (`ShareCleanup`).
@MainActor
enum MacShare {
    static func share(_ id: ConversationAction.ID, meeting: Meeting, state: AppState, anchor: SharingAnchor.Holder) {
        Task {
            do {
                guard let url = try await file(id, meeting: meeting, state: state) else { return }
                anchor.show([url])
            } catch {
                state.report("Couldn’t Share", id == .shareAudio ? "The audio couldn’t be prepared. Try again." : "The conversation couldn’t be prepared. Try again.", error)
            }
        }
    }

    private static func file(_ id: ConversationAction.ID, meeting: Meeting, state: AppState) async throws -> URL? {
        let folder = state.library.rootURL.appendingPathComponent("Meetings/\(meeting.id.uuidString)", isDirectory: true)
        switch id {
        case .shareMarkdown:
            var originals: [UUID: URL] = [:]
            for photo in meeting.visiblePhotos { originals[photo.id] = folder.appendingPathComponent(photo.relativePath) }
            let files = originals
            return try await Task.detached(priority: .userInitiated) { try ExportFiles.markdownWithPhotos(meeting, originals: files) }.value
        case .shareAudio:
            guard let track = meeting.primaryRecording,
                  let source = await state.audioURL(for: track, meetingID: meeting.id) else { return nil }
            let name = ExportFiles.audioName(meeting, track: track, fileExtension: source.pathExtension)
            return try await Task.detached(priority: .userInitiated) { try ExportFiles.audio(source, named: name) }.value
        default:
            return nil
        }
    }
}

/// An invisible view the sharing picker hangs from: the top trailing corner of the page, under the toolbar's More. It
/// also tells the window it's in, for what only AppKit does (widening the window for the inspector).
struct SharingAnchor: NSViewRepresentable {
    /// Holds the anchor's view for whoever shows the picker, and each share under way until it's done with its files.
    @MainActor
    final class Holder {
        fileprivate weak var view: NSView?
        private var shares: [ShareCleanup] = []

        var window: NSWindow? { view?.window }

        /// The sharing picker for `files`, export files that go once the share is done with them.
        func show(_ files: [URL]) {
            let share = ShareCleanup(files: files) { [weak self] done in
                self?.shares.removeAll { $0 === done }
                let files = done.files
                Task.detached(priority: .utility) { ExportFiles.clear(files) }
            }
            guard let view, view.window != nil else { share.finish(); return }
            shares.append(share)
            let picker = NSSharingServicePicker(items: files)
            picker.delegate = share
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        holder.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { holder.view = view }
}

/// One share's files, kept while the sharing picker is open and while the service chosen in it (Mail, AirDrop…) shares
/// them, then let go once: the picker dismissed without a choice, or the service done or failed. A share that never says
/// leaves them for the next launch (`ExportFiles`).
@MainActor
final class ShareCleanup: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    let files: [URL]
    private var finished: ((ShareCleanup) -> Void)?

    init(files: [URL], finished: @escaping (ShareCleanup) -> Void) {
        self.files = files
        self.finished = finished
    }

    /// The share is done with its files; only the first call counts.
    func finish() {
        guard let finished else { return }
        self.finished = nil
        finished(self)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        self
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { finish() }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) { finish() }
}
