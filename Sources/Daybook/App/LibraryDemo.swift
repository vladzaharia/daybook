#if DEBUG
import AppKit
import DaybookCaptions
import DaybookCore
import DaybookDevices
import DaybookIntelligence
import DaybookKit
import Foundation

/// Debug-only: `--library-demo` (or `--demo-library`) fills the `--library` folder (never the everyday library)
/// with the conversations the iPhone's demo has too (DaybookKit's `ReadingDemo`): every state the list, the page,
/// and the inspector show, so each can be captured without recording or processing, and a Mac snapshot and an
/// iPhone screenshot of one conversation show the same content. This Mac's own states go on top at every launch,
/// since they're its queue's and aren't stored: "Roadmap review" transcribing here (40%), the Northwind call waiting
/// in the queue after it, "1:1 with Priya" paused, and "Research interview" waiting for models; the queue itself
/// never runs.
///
/// `--select "<title>"` opens the conversation with exactly that title, as on the iPhone; `--info` (or
/// `--inspector`) opens the inspector, the iPhone's Info; `--page` and `--search` work as everywhere.
/// `--window-size <W>x<H>` sizes the main window (with or without the demo); with it, `--multi-select
/// "<title>|<title>"` selects several conversations and `--notice "<text>"` shows a library notice.
@MainActor
enum LibraryDemo {
    static var isRequested: Bool { ReadingDemo.isRequested && LaunchOptions.libraryURL != nil }

    static let ready = ReadingDemo.Title.ready
    static let transcribing = ReadingDemo.Title.transcribing
    static let queued = ReadingDemo.Title.queued
    static let paused = ReadingDemo.Title.paused
    static let waitingForModels = ReadingDemo.Title.waitingForModels
    static let older = ReadingDemo.Title.older

    /// Filling the library and selecting `--select`'s conversation. Other demos that change the
    /// place or add conversations wait for it, so they land in the same order every launch.
    private(set) static var seeding: Task<Void, Never>?

    static func apply(to state: AppState) {
        resizeWindow()
        runWindowActions(state)
        // `--info` is the iPhone's word for the inspector.
        if CommandLine.arguments.contains("--info") { LaunchOptions.defaults.set(true, forKey: AppState.Preference.isInspectorPresented) }
        guard isRequested else { return }
        // Each capture starts from the same chrome: the inspector only with `--inspector` (or `--info`), and
        // `--inspector-all` opens every section of it.
        LaunchOptions.defaults.set(CommandLine.arguments.contains("--inspector") || CommandLine.arguments.contains("--info"),
                                   forKey: AppState.Preference.isInspectorPresented)
        if CommandLine.arguments.contains("--inspector-all") {
            for key in ["inspector.details", "inspector.people", "inspector.audio", "inspector.processing"] { LaunchOptions.defaults.set(true, forKey: key) }
        }
        seeding = Task {
            let store = LiveCaptionStore(libraryRoot: state.library.rootURL)
            let finishing = ReadingDemo.seed(state.library, as: .mac) { meetingID, trackID, locale, lines in
                try? store.save(LiveCaptions(meetingID: meetingID, trackID: trackID, localeIdentifier: locale, segments: lines.map { line in
                    LiveCaptionSegment(start: line.start, end: line.end, text: line.text, isTentative: line.isTentative,
                                       speaker: line.speakerSlot.map { LiveCaptionSpeaker(slot: $0, name: line.speakerName) })
                }))
            }
            await finishing?.value
            // The demo's captions were saved through a store of its own: the pages read them now.
            await state.captions.readSaved()
            if finishing != nil, let id = state.meetings.first(where: { $0.title == ready })?.id { state.window.openID = id }
            if SpeakerProfileDemo.isRequested { await SpeakerProfileDemo.seed(state.library) }
            settle(state)
            if FloatingNotesDemo.scenario == nil {
                PlacementDemo.apply(to: state, processing: state.meetings.first { $0.title == transcribing }?.id)
            }
            UpgradeDemo.apply(to: state)
            // Seeding is asynchronous: the launch's own `--select` and `--place` ran before it.
            if let title = LaunchOptions.value(after: "--select"), let id = state.meetings.first(where: { $0.title == title })?.id {
                state.window.openID = id
            }
            if let place = LaunchOptions.value(after: "--place"), place.hasPrefix("folder:"),
               let folder = state.folders.first(where: { $0.name == place.dropFirst(7) }) {
                state.window.place = .folder(folder.id)
            }
            // `--multi-select "<title>|<title>…"` selects several rows; `--notice "<text>"` shows a library notice.
            if let titles = LaunchOptions.value(after: "--multi-select")?.split(separator: "|").map(String.init) {
                state.window.selection = Set(state.meetings.filter { titles.contains($0.title) }.map(\.id))
            }
            if let notice = LaunchOptions.value(after: "--notice") { state.notice = notice }
            // `--lock-demo` (PersonalLockDemo): the place shows what it would after choosing it, so with Personal
            // locked its page waits for Unlock rather than showing the demo's Work conversation beside it.
            if PersonalLockDemo.state() != nil, let id = state.window.openID, !state.visibleMeetings.contains(where: { $0.id == id }) {
                state.selectQuietly(state.visibleMeetings.first?.id)
            }
        }
    }

    /// `--window-size <W>x<H>`: the main window's size, to check narrow and wide layouts.
    private static func resizeWindow() {
        guard let value = LaunchOptions.value(after: "--window-size") else { return }
        let parts = value.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WindowID.library) == true || $0.title == "Daybook" }) else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: parts[0], height: parts[1])), display: true)
    }

    /// `--window-actions activate,fullscreen,toolbar,zoom,top,sidebar,inspector,…`: what the main window goes
    /// through, a step every 1.5 s, so a snapshot after them shows whether every column still starts
    /// under the toolbar. A step named twice undoes itself (full screen in and out, the toolbar hidden
    /// and shown); `activate` brings the app forward first, which full screen needs and which only an
    /// app opened through Launch Services (`open`) is allowed to do. `inspector` asks for the inspector as Tags… does,
    /// so a narrow window shows whether it widens.
    private static func runWindowActions(_ state: AppState) {
        guard let steps = LaunchOptions.value(after: "--window-actions")?.split(separator: ",").map(String.init) else { return }
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(index + 1)) {
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WindowID.library) == true }) else { return }
                switch step {
                case "activate":
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                case "fullscreen": window.toggleFullScreen(nil)
                case "toolbar": window.toggleToolbarShown(nil)
                case "zoom": window.zoom(nil)
                case "top":
                    // Against the top of the screen, as a window dragged under the menu bar can be.
                    if let screen = window.screen { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: screen.frame.maxY)) }
                case "sidebar": NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                case "inspector": state.showInspector()
                default: break
                }
            }
        }
    }

    /// This Mac's side of the processing states, which aren't stored in the library.
    private static func settle(_ state: AppState) {
        // The models count as installed, so audio reads as not transcribed rather than waiting for
        // models, and synced requests stay for another Mac. A queue that never starts keeps it so.
        state.processSyncedAudio = false
        state.installedModels = Set(state.routedRequiredModelIDs)
        // The launch's own look at the models folder can land after this; say it again.
        for delay in [1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { state.installedModels = Set(state.routedRequiredModelIDs) }
        }
        state.processingTask = Task { try? await Task.sleep(for: .seconds(86_400)) }
        func id(_ title: String) -> UUID? { state.meetings.first { $0.title == title }?.id }
        // A Floating Notes scenario (`--notes-demo`) sets what this Mac is processing itself.
        if FloatingNotesDemo.scenario == nil, let running = id(transcribing) {
            state.update(running) { $0.status = .transcribing }
            state.processingID = running
            state.processingProgress = IntelligenceProgress(0.4, "Transcribing", stage: .transcribing)
        }
        if let waiting = id(queued) { state.processingQueue = [state.makeJob(meetingID: waiting, mode: .newAudio)] }
        if let held = id(paused) { state.pausedIDs = [held] }
        if let models = id(waitingForModels) { state.awaitingModels = [models] }
        // On this Mac the walkthrough waits for an iPhone's audio, which says where it is: "· Sending 40%".
        if let walkthrough = id(ReadingDemo.Title.awaiting), let meeting = state.meetings.first(where: { $0.id == walkthrough }) {
            var phone = CompanionRecording(deviceID: "demo-iphone", deviceKind: DaybookPhoneIntegration.id, deviceName: "Alex’s iPhone",
                                           macStartedAt: meeting.date, state: .stopped, startedByDaybook: true)
            phone.macEndedAt = meeting.date.addingTimeInterval(20)
            phone.recordingID = UUID().uuidString
            state.update(walkthrough) { $0.companions = [phone] }
            state.phones.demoArrivals[walkthrough] = [AwaitedRecording.arrivalKey(deviceKind: phone.deviceKind, deviceName: phone.deviceName): .sending(0.4)]
        }
    }
}

/// Where the demos' silent recordings wait to be added: a folder for the run in the temporary
/// directory, removed as the app exits, since a snapshot can exit while a demo is still adding them.
enum DemoAudio {
    private static var path: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Daybook Library Demo \(getpid())", isDirectory: true)
    }

    private static let folder: URL = {
        atexit { try? FileManager.default.removeItem(at: DemoAudio.path) }
        return path
    }()

    /// An empty folder of its own for one recording, so its file can keep the name it's added under.
    static func newFolder() -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
