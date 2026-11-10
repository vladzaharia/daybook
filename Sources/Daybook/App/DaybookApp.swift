import AppKit
import DaybookCore
import DaybookIntelligence
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
        // One synthetic conversation summarized with a cloud model, with its tokens and cost (docs/cloud.md).
        if CommandLine.arguments.contains("--cloud-check") {
            Darwin.exit(await CloudCheck.run(arguments: CommandLine.arguments))
        }
        // Whether process taps work in the App Sandbox (docs/sandbox.md): the tap alone, nothing recorded.
        if CommandLine.arguments.contains("--capture-probe") {
            let code = await CaptureProbe.run(arguments: CommandLine.arguments)
            Darwin.exit(code)
        }
        if let name = LaunchOptions.deviceName { ProcessingRequest.Device.currentName = name }
        LaunchOptions.forgetSavedWindowForWindowSize()
        #endif
        // Before anything opens the library, syncs, or listens: one copy at a time. A copy opened to start over after a
        // library move waits for the one that opened it to quit. Nothing from here to `DaybookApp.main()` may suspend:
        // the app would then run inside one main-queue job, where no main-actor task ever runs.
        SingleInstance.ensureOnlyCopy()
        // Before anything reads a setting: the earlier bundle ID's preferences, once (docs/sandbox.md, "One bundle ID").
        PreferencesCarryOver.atLaunch()
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

    /// Debug builds' `--window-size <W>x<H>`: the size the library window opens at.
    static let windowSize: CGSize? = {
        #if DEBUG
        let parts = value(after: "--window-size")?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
        #else
        return nil
        #endif
    }()

    #if DEBUG
    /// With `--window-size`, the library window opens at that size and with its columns as the launch sets them, not as
    /// the last run left the window: its saved frame and columns are forgotten before the window is made. (Every run of
    /// `.build/debug/Daybook` shares them, whatever its library.)
    static func forgetSavedWindowForWindowSize() {
        guard windowSize != nil else { return }
        for key in ["NSWindow Frame \(WindowID.library)", "NSSplitView Subview Frames \(WindowID.library), SidebarNavigationSplitView"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    #endif
}

enum WindowID {
    static let library = "library"
    static let vocabulary = "vocabulary"
    static let templates = "templates"
    static let speakerProfiles = "speaker-profiles"
    static let welcome = "welcome"
    static let settings = "settings"
}

struct DaybookApp: App {
    @NSApplicationDelegateAdaptor(DaybookDelegate.self) private var delegate
    /// The app's state. The scenes only pass it on: every view, the menus, and the menu bar item read what they
    /// show, and redraw for that alone. Read here, each change would rebuild every scene and draw the library window
    /// twice, so the only thing the scenes read is whether a library move holds the library.
    @State private var state = AppState(libraryURL: LaunchOptions.libraryURL ?? AppState.libraryURL, defaults: LaunchOptions.defaults)
    @AppStorage(AppState.Preference.showsMenuBarExtra, store: LaunchOptions.defaults) private var showsMenuBarExtra = true
    @AppStorage(AppState.Preference.onboardingCompleted, store: LaunchOptions.defaults) private var onboardingCompleted = false

    var body: some Scene {
        Window("Daybook", id: WindowID.library) {
            LibraryView(state: state)
                .defaultAppStorage(LaunchOptions.defaults)
                // The rows, results, and the Trash's page ask it what the Personal lock hides.
                .environment(state.personalLock)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    delegate.state = state
                    await state.initialize()
                }
                .debugLaunchActions(state: state)
                .systemEntryPoints(state: state)
        }
        .defaultSize(LaunchOptions.windowSize ?? CGSize(width: 1280, height: 820))
        .commands { DaybookCommands(state: state) }

        Window("Welcome to Daybook", id: WindowID.welcome) { WelcomeWindow(state: state).defaultAppStorage(LaunchOptions.defaults) }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)
            // Help › Show Welcome opens it; the Window menu doesn't list it as well.
            .commandsRemoved()
            // A library to move first (docs/sandbox.md) is asked about in the library window, which opens instead.
            .defaultLaunchBehavior(onboardingCompleted || LaunchOptions.libraryURL != nil || state.launchCheck.offer?.holdsLibrary == true
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

        // A window rather than SwiftUI's Settings scene, whose title bar and toolbar are two rows: back and the page's
        // title share one bar, as System Settings has them. Daybook › Settings… (⌘,) opens it (DaybookCommands).
        Window("Settings", id: WindowID.settings) { SettingsView(state: state).defaultAppStorage(LaunchOptions.defaults) }
            .windowToolbarStyle(.unified)
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)
            .defaultLaunchBehavior(.suppressed)
            .commandsRemoved()

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

/// The menu bar item: a symbol only, since a ticking text label makes the status item re-layout every
/// second. The menu's first line shows the elapsed time.
private struct MenuBarLabel: View {
    let state: AppState
    var body: some View {
        Image(systemName: state.isRecording ? "record.circle.fill" : "waveform")
            .symbolRenderingMode(.palette)
            .foregroundStyle(state.isRecording ? Color.red : Color.primary)
            .accessibilityLabel(state.isRecording ? "Daybook, recording" : "Daybook")
    }
}

/// What a request to quit does (`DaybookDelegate.applicationShouldTerminate`).
enum QuitDecision: Equatable {
    /// Nothing to finish (the library never opened), or the work an earlier request started is done: quit now.
    case now
    /// Quitting already: this request is turned down. The quit under way asks again once its work is done, so a second
    /// ⌘Q or the Dock's Quit never cuts the stop and save short.
    case alreadyQuitting
    /// Logging out, restarting, or shutting down while quitting already: the Mac waits for that work, then Daybook quits.
    case waitForQuit
    /// A recording is under way: ask before stopping it.
    case askToStopRecording
    /// Stop what's running, save, then quit.
    case finishThenQuit

    static func decide(finished: Bool = false, quitting: Bool, hasState: Bool, recording: Bool, poweringOff: Bool) -> QuitDecision {
        if finished { return .now }
        if quitting { return poweringOff ? .waitForQuit : .alreadyQuitting }
        guard hasState else { return .now }
        // Logging out, restarting, or shutting down stops the recording without asking: nobody is there to answer.
        return recording && !poweringOff ? .askToStopRecording : .finishThenQuit
    }

    /// The reasons a quit event carries (`kAEQuitReason`) when the Mac quits apps itself: logging out, restarting,
    /// shutting down, or quitting every app. A quit the person chose (the menu, ⌘Q, the Dock) carries none.
    static let powerOffReasons = Set([kAEReallyLogOut, kAELogOut, kAERestart, kAEShutDown, kAEQuitAll].map { OSType($0) })

    /// Whether `event`, the Apple event being handled, is the quit the Mac sends as it logs out, restarts, or shuts down.
    /// Read for each request, so a logout another app called off leaves nothing behind.
    static func isPowerOff(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else { return false }
        let key = AEKeyword(kAEQuitReason)
        guard let reason = (event.attributeDescriptor(forKeyword: key) ?? event.paramDescriptor(forKeyword: key))?.typeCodeValue else { return false }
        return powerOffReasons.contains(reason)
    }
}

extension NSApplication {
    /// Quits as the Quit menu item does, from the run loop. Called from a main-actor task, which runs as a main-queue
    /// job, `terminate(_:)` would hold the main queue, and a quit that waits for work there (`DaybookDelegate`) would
    /// never finish.
    func terminateFromRunLoop() {
        perform(#selector(terminate(_:)), with: nil, afterDelay: 0, inModes: [.common])
    }
}

@MainActor
final class DaybookDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    /// The quit's work under way (`finish`).
    private var quitWork: Task<Void, Never>?
    /// That work is done: the quit it asks for goes ahead.
    private var readyToQuit = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate(poweringOff: QuitDecision.isPowerOff(NSAppleEventManager.shared().currentAppleEvent),
                        reply: { sender.reply(toApplicationShouldTerminate: true) }, quitAgain: { sender.terminateFromRunLoop() })
    }

    /// `applicationShouldTerminate`, with what it calls on the app passed in: `reply` answers a pending `.terminateLater`,
    /// and `quitAgain` asks to quit once more.
    func shouldTerminate(poweringOff: Bool, reply: @escaping @MainActor () -> Void,
                         quitAgain: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        let recording = state.map { $0.isRecording || $0.isStartingRecording } ?? false
        switch QuitDecision.decide(finished: readyToQuit, quitting: quitWork != nil, hasState: state != nil, recording: recording,
                                   poweringOff: poweringOff) {
        case .now: return .terminateNow
        case .alreadyQuitting: return .terminateCancel
        case .waitForQuit:
            let work = quitWork
            Task { await work?.value; reply() }
            return .terminateLater
        case .askToStopRecording: guard askToStopRecording() else { return .terminateCancel }
        case .finishThenQuit: break
        }
        guard let state else { return .terminateNow }
        let work = Task { await Self.finish(state) }
        quitWork = work
        if poweringOff {
            // The Mac waits for the answer; turned down, the logout, restart, or shutdown would stop. (While an answer
            // is pending, AppKit quits at once on another request, without asking here.)
            Task { await work.value; reply() }
            return .terminateLater
        }
        // Turned down for now and asked again once the work is done, so a quit asked meanwhile comes here and is
        // turned down too.
        Task {
            await work.value
            readyToQuit = true
            quitAgain()
        }
        return .terminateCancel
    }

    /// Before quitting: what runs stops, recorders and phones that recorded along hear it, and everything is saved.
    private static func finish(_ state: AppState) async {
        // Cancelling gives back requests this Mac held, so another Mac can take them over once
        // this one syncs again, or when their lease runs out if it never does. A model download stops with it and stays
        // owed for the next launch (the person's Cancel is `cancelDownload`).
        state.cancelProcessing()
        if state.isRecording || state.isStartingRecording { await state.stopRecording() }
        // Recorders and phones that recorded along hear the stop before the link goes (briefly).
        await state.sources.recorders.settle(within: .seconds(5))
        await state.flush()
        // What the queue still owes, as the stop left it, is on disk before Daybook goes.
        ProcessingQueue.drainWrites()
        state.recordReplicaIdentity()
        await state.phoneLink.shutDown()
    }

    /// QuickTime's question, before a quit ends a recording: the rest of the call wouldn't be recorded.
    private func askToStopRecording() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop recording and quit?"
        alert.addButton(withTitle: "Stop and Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        // Quit can come from the menu bar extra or the Dock while another app is in front.
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A CloudKit push: the iPhone sent files by courier. CKSyncEngine fetches on its own pushes; asking too costs
    /// nothing and covers a fetch the system put off.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        state?.sync.fetchCourier()
    }

    /// Coming to the front: a courier that's off only because the account couldn't be checked tries again now.
    func applicationDidBecomeActive(_ notification: Notification) {
        state?.sync.resumeCourier()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // What a share left behind (`ExportFiles`), as the iPhone clears it at launch. A run on a library of its own
        // (`--library`) may sit beside the app mid-share, so it leaves them.
        if LaunchOptions.libraryURL == nil { Task.detached(priority: .utility) { ExportFiles.clear() } }
        // Audio copies a crashed run's processing left (`ProcessingScratch`); a run still going keeps its own.
        Task.detached(priority: .utility) { ProcessingScratch.clear() }
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
            Task { if state.isRecording { await state.stopRecording() } else { await state.startRecording(from: .elsewhere) } }
        })
        if let id = state.recordingID {
            menu.addItem(DockMenuItem("Add Bookmark") { state.addHighlight(id) })
        }
        menu.addItem(DockMenuItem("Show Floating Notes") { state.showFloatingNotes(focus: state.floatingNotesFocus) })
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
/// without clicking: `--place work|personal|all|trash|device|device:<name>|folder:<name>`, `--select <title>`,
/// `--page transcript`, `--inspector`, `--open-settings <pane>`, `--open-window <id>`,
/// `--show-notes`, `--show-setup`, `--simulate-recording <title> [--demo-captions]`, `--library-demo`,
/// `--notice <text> --notice-action <title>`.
private struct DebugLaunchActions: ViewModifier {
    let state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var applied = false
    func body(content: Content) -> some View {
        content.onChange(of: state.isReady) { _, ready in
            guard ready, !applied else { return }
            applied = true
            if let place = LaunchOptions.value(after: "--place") {
                switch place {
                case "work": state.window.place = .section(.work)
                case "personal": state.window.place = .section(.personal)
                case "trash": state.window.place = .trash
                case "device": state.window.place = state.devices.sessions.first.map { .device($0.id) } ?? .section(.all)
                default:
                    if place.hasPrefix("device:"), let device = state.devices.sessions.first(where: { $0.device.name == place.dropFirst(7) }) { state.window.place = .device(device.id) }
                    else if place.hasPrefix("folder:"), let folder = state.folders.first(where: { $0.name == place.dropFirst(7) }) { state.window.place = .folder(folder.id) }
                    else { state.window.place = .section(.all) }
                }
            }
            if let title = LaunchOptions.value(after: "--select") { state.window.openID = state.meetings.first { $0.title == title }?.id }
            // `--page transcript`; `summary-only` and `transcript-only` collapse a wide window's two pages to one.
            switch LaunchOptions.value(after: "--page") {
            case "transcript"?: state.window.pageMode = .transcript
            case "summary-only"?: state.window.pageSpreadChosen = false
            case "transcript-only"?: state.window.pageMode = .transcript; state.window.pageSpreadChosen = false
            default: break
            }
            if CommandLine.arguments.contains("--inspector") { LaunchOptions.defaults.set(true, forKey: AppState.Preference.isInspectorPresented) }
            if let pane = LaunchOptions.value(after: "--open-settings").flatMap(SettingsPane.init(rawValue:)) {
                pane.open(with: openWindow, activating: false)
            }
            if let id = LaunchOptions.value(after: "--open-window") { openWindow(id: id) }
            if CommandLine.arguments.contains("--show-notes") { state.showFloatingNotes(focus: state.window.openID) }
            if CommandLine.arguments.contains("--show-setup") { state.requestAddDevice() }
            DeviceDemo.apply(to: state)
            PhoneDemo.apply(to: state)
            FloatingNotesDemo.apply(to: state)
            CallPromptDemo.apply(to: state)
            PhotoDemo.apply(to: state)
            LibraryDemo.apply(to: state)
            CloudSettingsDemo.apply(to: state)
            // `--notice <text> --notice-action <title>`: the library notice with its text link on the last line. Lines
            // before it (`$'Exported Standup.md\nMoved “Roadmap” to the Trash.'`) are posted first, without one.
            if let notice = LaunchOptions.value(after: "--notice"), let title = LaunchOptions.value(after: "--notice-action") {
                let lines = notice.components(separatedBy: "\n")
                state.post(Array(lines.dropLast()))
                state.post(lines.last ?? notice, action: LibraryNoticeAction(title: title) {})
            }
            if let query = LaunchOptions.value(after: "--search") { state.window.searchText = query }
            PerfProbe.stage = {
                guard let id = state.processor.queue.runningID else { return "idle" }
                let status = state.meetings.first { $0.id == id }?.status.rawValue ?? ""
                return "\(status): \(state.processor.queue.activity.value.message)"
            }
            PerfProbe.driveProgress(state.processor.queue.activity)
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
                    case "history": state.window.sheet = .versionHistory
                    case "timing": state.window.sheet = .adjustTiming(nil)
                    case "corrections": state.window.sheet = .reviewCorrections
                    default: break
                    }
                }
            }
            // Fakes the recording state without touching the microphone, for screenshots. A title the
            // library doesn't have yet becomes a new conversation; `--demo-captions` scripts captions.
            if let title = LaunchOptions.value(after: "--simulate-recording") {
                let id = state.meetings.first(where: { $0.title == title })?.id ?? state.newMeeting(title: title)
                state.window.openID = id
                state.recordingID = id
                state.recordingStartedAt = Date().addingTimeInterval(-761)
                state.update(id) { $0.status = .recording }
                if DemoCaptions.isRequested { state.startDemoCaptions(id) }
                if !CommandLine.arguments.contains("--no-panel") { state.showNotes(for: id) }
            }
            // Plays silently, so the player can be seen without sound: the conversation selected once a demo is seeded.
            if CommandLine.arguments.contains("--play-muted") {
                Task {
                    await LibraryDemo.seeding?.value
                    guard let meeting = state.selectedMeeting, let track = meeting.tracks.first,
                          let url = await state.audioURL(for: track, meetingID: meeting.id) else { return }
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
