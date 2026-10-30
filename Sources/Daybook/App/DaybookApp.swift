import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

@main
enum DaybookEntry {
    @MainActor static func main() async {
        // A sandboxed build can't reach paths outside its container: stop now and say where it can write.
        let unreachable = LaunchPaths.problems(arguments: CommandLine.arguments)
        if !unreachable.isEmpty {
            FileHandle.standardError.write(Data((unreachable.joined(separator: "\n") + "\n").utf8))
            Darwin.exit(2)
        }
        if CommandLine.arguments.contains("--smoke-test") {
            let code = await SmokeTest.run(arguments: CommandLine.arguments)
            Darwin.exit(code)
        }
        if CommandLine.arguments.contains("--evaluate") {
            let code = await SpeechEvaluation.run(arguments: CommandLine.arguments)
            Darwin.exit(code)
        }
        #if DEBUG
        // Speaker profiles reconciled over a copy of a library as a dry run, in numbers (docs/validation.md).
        if CommandLine.arguments.contains("--speaker-report") {
            Darwin.exit(SpeakerReport.run(arguments: CommandLine.arguments))
        }
        // Whether process taps work in the App Sandbox (docs/sandbox.md): the tap alone, nothing recorded.
        if CommandLine.arguments.contains("--capture-probe") {
            let code = await CaptureProbe.run(arguments: CommandLine.arguments)
            Darwin.exit(code)
        }
        if let name = LaunchOptions.deviceName { ProcessingRequest.Device.currentName = name }
        #endif
        // Before anything opens the library, syncs, or listens: one copy at a time.
        SingleInstance.ensureOnlyCopy()
        DaybookApp.main()
    }
}

/// `--library <path>` opens a separate library with its own preferences, for demos and UI checks
/// that must not touch the everyday library. With it, a debug build's `--device-name <name>` is this
/// Mac's name everywhere Daybook shows or sends it (Add iPhone, photos, sync), for screenshots.
enum LaunchOptions {
    #if DEBUG
    static let deviceName: String? = libraryURL == nil ? nil : value(after: "--device-name")
    #endif
    static let libraryURL: URL? = value(after: "--library").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    /// One suite per library, so runs on different libraries side by side don't share settings or panels.
    static let defaults: UserDefaults = libraryURL.flatMap { url in
        UserDefaults(suiteName: "local.daybook.app.alternate-library." + AudioDigest.sha256(data: Data(url.standardizedFileURL.path.utf8)).prefix(12))
    } ?? .standard
    static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

enum WindowID {
    static let library = "library"
    static let vocabulary = "vocabulary"
    static let templates = "templates"
    static let speakerProfiles = "speaker-profiles"
    static let welcome = "welcome"
}

struct DaybookApp: App {
    @NSApplicationDelegateAdaptor(DaybookDelegate.self) private var delegate
    /// The app's state, held and not observed: every view, the menus, and the menu bar item observe what
    /// they show. Observed here, each change of the library rebuilt every scene and drew the library window twice.
    @StateObject private var holder = AppStateHolder()
    private var state: AppState { holder.state }
    @AppStorage("showsMenuBarExtra", store: LaunchOptions.defaults) private var showsMenuBarExtra = true
    @AppStorage("onboardingCompleted", store: LaunchOptions.defaults) private var onboardingCompleted = false

    var body: some Scene {
        Window("Daybook", id: WindowID.library) {
            LibraryView(state: state)
                .defaultAppStorage(LaunchOptions.defaults)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    delegate.state = state
                    await state.initialize()
                }
                .debugLaunchActions(state: state)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { DaybookCommands(state: state) }

        Window("Welcome to Daybook", id: WindowID.welcome) { WelcomeWindow(state: state).defaultAppStorage(LaunchOptions.defaults) }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)
            // Help › Show Welcome opens it; the Window menu doesn't list it as well.
            .commandsRemoved()
            // A library to move first (docs/sandbox.md) is asked about in the library window, which opens instead.
            .defaultLaunchBehavior(onboardingCompleted || LaunchOptions.libraryURL != nil || state.libraryMoveOffer?.holdsLibrary == true
                                   ? .suppressed : .presented)

        Window("Vocabulary", id: WindowID.vocabulary) { GlossaryView(state: state).defaultAppStorage(LaunchOptions.defaults) }
            .defaultSize(width: 640, height: 440)
            .windowResizability(.contentMinSize)
        Window("Summary Templates", id: WindowID.templates) { TemplatesView(state: state).defaultAppStorage(LaunchOptions.defaults) }
            .defaultSize(width: 780, height: 560)
            .windowResizability(.contentMinSize)
        Window("Speaker Profiles", id: WindowID.speakerProfiles) { SpeakerProfilesView(state: state).defaultAppStorage(LaunchOptions.defaults) }
            .defaultSize(width: 720, height: 480)
            .windowResizability(.contentMinSize)

        Settings { SettingsView(state: state).defaultAppStorage(LaunchOptions.defaults) }
            .windowResizability(.contentSize)

        MenuBarExtra(isInserted: menuBarExtraInserted) {
            MenuBarView(state: state).defaultAppStorage(LaunchOptions.defaults)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.menu)
    }

    /// SwiftUI writes the menu bar item's visibility back whenever the app's state changes. An unchanged
    /// value isn't stored: storing it announces a change of settings, which redraws every view that keeps one
    /// (the library window among them).
    private var menuBarExtraInserted: Binding<Bool> {
        Binding(get: { showsMenuBarExtra }, set: { if $0 != showsMenuBarExtra { showsMenuBarExtra = $0 } })
    }
}

/// Makes the app's state when the app first draws its scenes. It never announces a change itself, so the
/// state's changes don't rebuild the scenes.
@MainActor
private final class AppStateHolder: ObservableObject {
    let state = AppState(libraryURL: LaunchOptions.libraryURL ?? AppState.libraryURL, defaults: LaunchOptions.defaults)
}

/// The menu bar item: a symbol only, since a ticking text label makes the status item re-layout every
/// second. The menu's first line shows the elapsed time.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    var body: some View {
        Image(systemName: state.isRecording ? "record.circle.fill" : "waveform")
            .symbolRenderingMode(.palette)
            .foregroundStyle(state.isRecording ? Color.red : Color.primary)
            .accessibilityLabel(state.isRecording ? "Daybook, recording" : "Daybook")
    }
}

/// The menu bar. Every toolbar and context-menu action has a home here; items that don't apply
/// are disabled, never hidden.
struct DaybookCommands: Commands {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var meeting: Meeting? { state.place.isDevice ? nil : state.selectedMeeting }
    private var locked: Bool {
        guard let meeting else { return true }
        return state.recordingID == meeting.id || state.processingID == meeting.id || state.isStartingRecording || state.isStoppingRecording
    }

    var body: some Commands {
        // The standard About panel, crediting the models (their licenses and required attributions).
        CommandGroup(replacing: .appInfo) {
            Button("About Daybook") { AboutPanel.show(catalog: state.modelCatalog) }
        }
        CommandGroup(replacing: .newItem) {
            // A conversation that's only your notes so far, as on the iPhone; Record records into it.
            Button("New Note") { state.place = state.place.isDevice ? .section(.all) : state.place; state.newNote(); openWindow(id: WindowID.library) }
                .keyboardShortcut("n")
            Button("New Folder") { state.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(state.isRecording ? "Stop Recording" : "Start Recording") {
                Task { if state.isRecording { await state.stopRecording() } else { await state.startRecording() } }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!state.isReady || state.isStartingRecording || state.isStoppingRecording)
            Button("Import Audio…") { state.chooseImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            DeviceFileMenuItems(state: state)
            Button("Add Recording to Conversation…") { if let id = meeting?.id { state.chooseImport(attachTo: id) } }
                .disabled(locked)
            Button("Add Photos…") { if let id = meeting?.id { state.chooseAddPhoto(to: id) } }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(meeting == nil)
        }
        // Continuity Camera: Take Photo, Scan Documents, and Add Sketch from an iPhone or iPad
        // (the page receives them through `importsItemProviders`).
        ImportFromDevicesCommands()
        CommandGroup(after: .saveItem) {
            Menu("Export") {
                Button("Markdown…") { if let id = meeting?.id { state.export(id) } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Full Data (JSON)…") { if let id = meeting?.id { state.export(id, json: true) } }
            }
            .disabled(meeting == nil)
            Button("Show in Finder") { if let id = meeting?.id { state.showInFinder(id) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(meeting == nil)
            Divider()
            Button("Move to Trash…") { state.trashRequestID = meeting?.id }
                .disabled(locked)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Summary") { if let meeting { state.copySummary(meeting.id) } }
                .disabled(meeting?.summary == nil)
            Button("Paste Photo") { if let meeting { state.pastePhoto(into: meeting.id) } }
                .disabled(meeting == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Conversations") { state.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
        SidebarCommands()
        InspectorCommands()
        ToolbarCommands()
        CommandGroup(before: .sidebar) {
            Button("Summary") { state.pageMode = .summary }
                .keyboardShortcut("1")
                .disabled(meeting == nil)
            Button("Transcript") { state.pageMode = .transcript }
                .keyboardShortcut("2")
                .disabled(meeting?.unifiedTranscript.isEmpty != false)
            Divider()
            Button("Make Text Bigger") { state.readingScale = ReadingScale.bigger(state.readingScale) }
                .keyboardShortcut("+")
            Button("Make Text Smaller") { state.readingScale = ReadingScale.smaller(state.readingScale) }
                .keyboardShortcut("-")
            Button("Actual Size") { state.readingScale = 1 }
                .keyboardShortcut("0")
            Divider()
        }
        CommandGroup(before: .windowList) {
            // The panel isn't in the window list (it floats over calls), so it has its own item: the
            // recording, else the selected conversation, else its home.
            Button("Floating Notes") { state.showFloatingNotes(focus: state.recordingID ?? meeting?.id) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Conversation") {
            if let meeting, state.processingID == meeting.id {
                Button("Pause Transcription") { state.pauseProcessing(meeting.id) }
            } else if let meeting, state.pausedIDs.contains(meeting.id) {
                Button("Resume Transcription") { state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting)) }
            } else {
                Button("Transcribe") { if let meeting { state.enqueue(meeting.id, mode: state.defaultProcessingMode(for: meeting)) } }
                    .disabled(meeting?.hasUntranscribedAudio != true || locked || state.queuedIDs.contains(meeting?.id ?? UUID()))
            }
            Divider()
            ForEach([ProcessingRequest.Mode.summaryOnly, .speakerRefresh, .newAudio, .fullRetranscription]) { mode in
                Button(mode.title) { if let id = meeting?.id { state.enqueue(id, mode: mode) } }
                    .disabled(meeting?.tracks.isEmpty != false || locked || state.queuedIDs.contains(meeting?.id ?? UUID()))
            }
            Menu("Template") {
                if let meeting { TemplateMenuItems(state: state, meetingID: meeting.id) }
            }
            .disabled(meeting == nil)
            Divider()
            Button("Add Bookmark") { if let id = state.recordingID { state.addHighlight(id) } }
                .keyboardShortcut("d")
                .disabled(state.recordingID == nil)
            Button("Adjust Timing…") { state.activeSheet = .adjustTiming(nil) }
                .disabled(meeting.map { $0.tracks.count < 2 } ?? true)
            Button("Review Earlier Corrections…") { state.activeSheet = .reviewCorrections }
                .disabled(meeting?.correctionTransferIssues?.isEmpty != false)
            Divider()
            Menu("Move to Folder") {
                if let meeting { FolderMenuItems(state: state, meetingIDs: [meeting.id]) }
            }
            .disabled(meeting == nil)
            Button(meeting?.effectivePlacement == .personal ? "Move to Work" : "Move to Personal") {
                if let meeting { state.setPlacement([meeting.id], meeting.effectivePlacement == .personal ? .work : .personal) }
            }
            .disabled(meeting == nil)
            Divider()
            Button("Version History…") { state.activeSheet = .versionHistory }
                .disabled(meeting?.revisions.isEmpty != false)
        }
        CommandMenu("Controls") {
            PlayPauseMenuItem(activity: state.playback.activity) { state.playback.toggle() }
                .disabled(meeting?.tracks.isEmpty != false || state.isRecording)
            Button("Jump Back 15 Seconds") { state.playback.skip(-15) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Jump Forward 15 Seconds") { state.playback.skip(15) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Show Welcome") { openWindow(id: WindowID.welcome) }
        }
    }
}

/// Controls › Play or Pause, as playback is. It follows only whether playback is playing, so the
/// menu isn't rebuilt as the position moves.
private struct PlayPauseMenuItem: View {
    @ObservedObject var activity: PlaybackActivity
    let toggle: () -> Void
    var body: some View { Button(activity.isPlaying ? "Pause" : "Play", action: toggle) }
}

/// Template choices for a conversation, shared by the colophon, inspector, and Conversation menu.
struct TemplateMenuItems: View {
    @ObservedObject var state: AppState
    let meetingID: UUID
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Picker("Template", selection: state.templateSelection(for: meetingID)) {
            Text(automaticTitle).tag("auto")
            Divider()
            ForEach(state.templates.filter(\.isBuiltIn)) { template in Text(template.name).tag(template.id) }
            let custom = state.templates.filter { !$0.isBuiltIn }
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { template in Text(template.name).tag(template.id) }
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Edit Templates…") { openWindow(id: WindowID.templates) }
    }
    private var automaticTitle: String {
        guard let kind = state.meetings.first(where: { $0.id == meetingID })?.summary?.kind, kind != .auto else { return "Automatic" }
        return "Automatic (\(kind.title))"
    }
}

/// Folder choices for one or more conversations.
struct FolderMenuItems: View {
    @ObservedObject var state: AppState
    let meetingIDs: [UUID]
    var body: some View {
        Button("None") { state.moveToFolder(meetingIDs, nil) }
        if !state.folders.isEmpty { Divider() }
        ForEach(state.folders) { folder in
            Button(folder.name) { state.moveToFolder(meetingIDs, folder.id) }
        }
        Divider()
        Button("New Folder") { state.requestNewFolder(moving: meetingIDs) }
    }
}

@MainActor
final class DaybookDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let state else { return .terminateNow }
        terminating = true
        Task {
            // Cancelling gives back requests this Mac held, so another Mac can take them over once
            // this one syncs again, or when their lease runs out if it never does.
            state.cancelDownload(); state.cancelProcessing()
            if state.isRecording || state.isStartingRecording { await state.stopRecording() }
            // Recorders and phones that recorded along hear the stop before the link goes (briefly).
            await state.sources.recorders.settle(within: .seconds(5))
            await state.flush()
            state.recordReplicaIdentity()
            await state.phoneLink.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A CloudKit push: the iPhone sent files by courier. CKSyncEngine fetches on its own pushes; asking too costs
    /// nothing and covers a fetch the system put off.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        state?.sync.fetchCourier()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        PerfProbe.start()
        switch LaunchOptions.value(after: "--appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // `--snapshot <dir>` renders each visible window to PNG from inside the app, then exits.
        // It works while the screen is locked, when screen capture can't.
        if let directory = LaunchOptions.value(after: "--snapshot") {
            let delay = Double(LaunchOptions.value(after: "--snapshot-delay") ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                WindowSnapshot.write(to: URL(fileURLWithPath: directory, isDirectory: true))
                Darwin.exit(0)
            }
        }
        #endif
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let state else { return nil }
        let menu = NSMenu()
        menu.addItem(DockMenuItem(state.isRecording ? "Stop Recording" : "Start Recording") {
            Task { if state.isRecording { await state.stopRecording() } else { await state.startRecording() } }
        })
        if let id = state.recordingID {
            menu.addItem(DockMenuItem("Add Bookmark") { state.addHighlight(id) })
        }
        menu.addItem(DockMenuItem("Show Floating Notes") { state.showFloatingNotes(focus: state.recordingID) })
        menu.addItem(DockMenuItem("Import Audio…") { state.chooseImport() })
        return menu
    }
}

private final class DockMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void
    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { MainActor.assumeIsolated { handler() } }
}

#if DEBUG
/// Debug-only launch arguments that open a specific surface, so every screen can be captured
/// without clicking: `--place work|personal|all|device|device:<name>|folder:<name>`, `--select <title>`,
/// `--page transcript`, `--inspector`, `--open-settings <pane>`, `--open-window <id>`,
/// `--show-notes`, `--show-setup`, `--simulate-recording <title> [--demo-captions]`, `--library-demo`.
private struct DebugLaunchActions: ViewModifier {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var applied = false
    func body(content: Content) -> some View {
        content.onChange(of: state.isReady) { _, ready in
            guard ready, !applied else { return }
            applied = true
            if let place = LaunchOptions.value(after: "--place") {
                switch place {
                case "work": state.place = .section(.work)
                case "personal": state.place = .section(.personal)
                case "device": state.place = state.devices.sessions.first.map { .device($0.id) } ?? .section(.all)
                default:
                    if place.hasPrefix("device:"), let device = state.devices.sessions.first(where: { $0.device.name == place.dropFirst(7) }) { state.place = .device(device.id) }
                    else if place.hasPrefix("folder:"), let folder = state.folders.first(where: { $0.name == place.dropFirst(7) }) { state.place = .folder(folder.id) }
                    else { state.place = .section(.all) }
                }
            }
            if let title = LaunchOptions.value(after: "--select") { state.selectedID = state.meetings.first { $0.title == title }?.id }
            if LaunchOptions.value(after: "--page") == "transcript" { state.pageMode = .transcript }
            if CommandLine.arguments.contains("--inspector") { LaunchOptions.defaults.set(true, forKey: "isInspectorPresented") }
            if let pane = LaunchOptions.value(after: "--open-settings") {
                LaunchOptions.defaults.set(pane, forKey: "settingsPane")
                openSettings()
            }
            if let id = LaunchOptions.value(after: "--open-window") { openWindow(id: id) }
            if CommandLine.arguments.contains("--show-notes") { state.showFloatingNotes(focus: state.selectedID) }
            if CommandLine.arguments.contains("--show-setup") { state.requestAddDevice() }
            DeviceDemo.apply(to: state)
            PhoneDemo.apply(to: state)
            FloatingNotesDemo.apply(to: state)
            PhotoDemo.apply(to: state)
            LibraryDemo.apply(to: state)
            if let query = LaunchOptions.value(after: "--search") { state.search = query }
            PerfProbe.stage = {
                guard let id = state.processingID else { return "idle" }
                let status = state.meetings.first { $0.id == id }?.status.rawValue ?? ""
                return "\(status): \(state.processingProgress.message)"
            }
            PerfProbe.driveProgress(state.processingActivity)
            PerfProbe.driveTouches(state)
            // `DAYBOOK_IMPORT_AUDIO=<file>` imports a recording into a new conversation, which then processes. (A path
            // among the arguments would be opened as a document, and the window wouldn't open.)
            if LaunchOptions.libraryURL != nil, let path = ProcessInfo.processInfo.environment["DAYBOOK_IMPORT_AUDIO"] {
                Task { try? await state.importFiles([URL(fileURLWithPath: path)], source: .imported, attachTo: nil) }
            }
            // A sheet is for the selected conversation, which the library demo selects once it's seeded.
            if let sheet = LaunchOptions.value(after: "--sheet") {
                Task {
                    await LibraryDemo.seeding?.value
                    switch sheet {
                    case "history": state.activeSheet = .versionHistory
                    case "timing": state.activeSheet = .adjustTiming(nil)
                    case "corrections": state.activeSheet = .reviewCorrections
                    default: break
                    }
                }
            }
            // Fakes the recording state without touching the microphone, for screenshots. A title the
            // library doesn't have yet becomes a new conversation; `--demo-captions` scripts captions.
            if let title = LaunchOptions.value(after: "--simulate-recording") {
                let id = state.meetings.first(where: { $0.title == title })?.id ?? state.newMeeting(title: title)
                state.selectedID = id
                state.recordingID = id
                state.recordingStartedAt = Date().addingTimeInterval(-761)
                state.update(id) { $0.status = .recording }
                if DemoCaptions.isRequested { state.startDemoCaptions(id) }
                if !CommandLine.arguments.contains("--no-panel") { state.showNotes(for: id) }
            }
            // Plays silently, so the player can be seen without sound.
            if CommandLine.arguments.contains("--play-muted"), let meeting = state.selectedMeeting, let track = meeting.tracks.first {
                Task {
                    guard let url = await state.audioURL(for: track, meetingID: meeting.id) else { return }
                    state.playback.play(url: url, at: 9, trackID: track.id, meetingID: meeting.id)
                    state.playback.mute()
                }
            }
        }
    }
}

@MainActor
enum WindowSnapshot {
    static func write(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let listing = NSApp.windows.map { "\($0.title.isEmpty ? "untitled" : $0.title) visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))" }
        try? listing.joined(separator: "\n").write(to: directory.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 50 {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: rep)
            let name = (window.title.isEmpty ? "window-\(index)" : window.title).replacingOccurrences(of: "/", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
#endif

extension View {
    func debugLaunchActions(state: AppState) -> some View {
        #if DEBUG
        modifier(DebugLaunchActions(state: state))
        #else
        self
        #endif
    }
}
