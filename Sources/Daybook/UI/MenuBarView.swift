import AppKit
import DaybookIntelligence
import DaybookKit
import SwiftUI

/// The menu bar extra: a standard menu. Personal conversations are never named here,
/// since the menu bar is visible while sharing a screen.
struct MenuBarView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openWindow) private var openSettingsWindow

    var body: some View {
        // Items show the shortcuts they have in the app's menus, as Settings… and Quit do.
        if state.isRecording, let start = state.recordingStartedAt {
            Text("Recording · \(TimeLabel.short(Date().timeIntervalSince(start)))")
            Button("Stop Recording") { Task { await state.stopRecording() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.isStoppingRecording)
            Button("Add Bookmark") { if let id = state.recordingID { state.addHighlight(id) } }
                .keyboardShortcut("d")
        } else {
            Button("Start Recording") { Task { await state.startRecording(from: .elsewhere) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.isReady || state.isStartingRecording)
        }
        // Where Window › Floating Notes opens it, with the same shortcut: on the recording, else the conversation
        // the library window shows, else its home.
        // Floating Notes' one rule for where it opens from a menu (`AppState.floatingNotesFocus`).
        Button("Show Floating Notes") { state.showFloatingNotes(focus: state.floatingNotesFocus) }
            .keyboardShortcut("n", modifiers: [.command, .option])
        Divider()
        Picker("When a Call Starts", selection: $state.callPolicy) {
            ForEach(CallRecordingPolicy.allCases) { Text($0.title).tag($0) }
        }
        if state.callPolicy != .off { DetectionStatusText(monitor: state.monitor) }
        // What's going on, when there's something to say; it reads the job's progress apart from the rest.
        MenuBarStatusItems(state: state)
        Divider()
        Button("Open Daybook") { open(nil) }
        Button("Settings…") {
            openSettingsWindow.settings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Daybook") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func open(_ place: LibraryPlace?) {
        if let place { state.place = place }
        openWindow(id: WindowID.library)
        NSApp.activate()
    }
}

/// The menu's status: each line an item that opens what it's about, or a heading over the choices it offers, then the
/// recorder handoffs this Mac can ask for. Nothing when there's nothing to say.
private struct MenuBarStatusItems: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openWindow) private var openSettingsWindow

    var body: some View {
        let lines = MenuBarStatus.lines(MenuBarStatus.inputs(state))
        let managed = state.devices.sessions.filter { $0.managedElsewhere != nil && $0.kind.id != DaybookPhoneIntegration.id }
        if !lines.isEmpty || !managed.isEmpty {
            Divider()
            ForEach(lines) { line in
                if line.choices.isEmpty {
                    // An item that opens it reads at full strength, not as a dimmed status line.
                    Button(line.title) { open(line.opens) }
                } else {
                    Section(line.title) {
                        ForEach(line.choices, id: \.title) { choice in
                            Button(choice.title) { perform(choice.action) }
                        }
                    }
                }
            }
            ForEach(managed) { session in
                RecorderHandoffMenuItems(state: state, session: session, namesRecorder: true)
            }
        }
    }

    private func open(_ target: MenuBarStatus.Opens) {
        switch target {
        case .conversation(let id):
            state.showConversation(id)
            showLibrary()
        case .device(let id):
            state.showDevice(id)
            showLibrary()
        case .modelSettings: showSettings(.models)
        case .syncSettings: showSettings(.library)
        }
    }

    private func perform(_ action: MenuBarStatus.ChoiceAction) {
        switch action {
        case .placement(let choice, let id): state.chooseSummaryPlacement(choice, for: id)
        case .openSyncSettings: showSettings(.library)
        }
    }

    private func showLibrary() {
        openWindow(id: WindowID.library)
        NSApp.activate()
    }

    private func showSettings(_ pane: SettingsPane) {
        LaunchOptions.defaults.set(pane.rawValue, forKey: SettingsPane.storageKey)
        openSettingsWindow.settings()
        NSApp.activate()
    }
}

/// What the menu bar extra says is going on (docs/interface.md, "Menu bar extra"), from plain facts, so tests read
/// what each state says. The words are the ones Floating Notes' home and the iPhone's status sheet use
/// (`RecorderStatusWords`, `PeerStatusWords`, `ProcessingWords`, `SyncStatus`), each naming what it's about, since a
/// menu has no title column; a Personal conversation is "a personal conversation". It speaks only when there's
/// something to say: this Mac's work and a summary's countdown with its choices, model downloads (one phrase over the
/// whole set, or one that stopped, or waiting for Wi‑Fi), a recorder
/// that's moving, importing, listening live, recording, has new recordings, or needs the person, a paired iPhone
/// that's recording or paused, and iCloud when it's a problem.
enum MenuBarStatus {
    /// This Mac's processing, as the menu needs it.
    struct Work: Equatable {
        var id: UUID
        /// Nil for a Personal conversation, which the menu never names.
        var title: String?
        var stage: ProcessingRequest.Stage
        var fraction: Double?
        var waiting = 0
        /// Its summary counts down to starting on this Mac until then, with these choices.
        var countdown: Date?
        var choices: [SummaryPlacementPlanner.Action] = []
        /// Its summary runs in the cloud, with this model.
        var cloudModel: String?
    }

    struct Inputs: Equatable {
        var work: Work?
        /// How this Mac's model downloads stand.
        var models: ModelDownloadState?
        var recorders: [RecorderFacts] = []
        var phones: [PeerFacts] = []
        var sync: SyncStatus = .off
    }

    /// What choosing an item opens.
    enum Opens: Equatable {
        case conversation(UUID)
        case device(String)
        case modelSettings
        case syncSettings
    }

    enum ChoiceAction: Equatable {
        case placement(SummaryPlacementPlanner.Action, UUID)
        case openSyncSettings
    }

    struct Choice: Equatable {
        var title: String
        var action: ChoiceAction
    }

    /// One thing going on: an item that opens it, or, with choices, a heading over them.
    struct Line: Equatable, Identifiable {
        var id: String
        var title: String
        var opens: Opens
        var choices: [Choice] = []
    }

    static let here = "this Mac"

    static func lines(_ inputs: Inputs, now: Date = Date()) -> [Line] {
        var lines: [Line] = []
        if let work = inputs.work { lines.append(workLine(work, now: now)) }
        // "Downloading models · 40%" over the whole set, as every surface says it; or that one stopped, or waits for Wi‑Fi.
        if let models = inputs.models {
            lines.append(Line(id: "download", title: ProcessingWords.modelDownloadLine(models), opens: .modelSettings))
        }
        for facts in inputs.recorders { lines += recorderLines(facts, now: now) }
        for peer in inputs.phones where peer.activity != .idle {
            let line = PeerStatusWords.line(peer, now: now)
            lines.append(Line(id: line.id, title: "\(peer.name) · \(line.text)", opens: .device(peer.id)))
        }
        if inputs.sync.problem != nil {
            let words = inputs.sync.shortText
            lines.append(Line(id: "sync", title: words.localizedCaseInsensitiveContains("iCloud") ? words : "iCloud · \(words)", opens: .syncSettings,
                              choices: [Choice(title: "Open Sync Settings…", action: .openSyncSettings)]))
        }
        return lines
    }

    /// "Transcribing “Weekly product sync” · 40% · 2 waiting", "Summarizing a personal conversation in 12 s" over Use
    /// the Cloud and Start Now, "Summarizing “Roadmap” with Claude Sonnet 5.5".
    static func workLine(_ work: Work, now: Date = Date()) -> Line {
        let name = work.title.map { "“\($0)”" } ?? "a personal conversation"
        let waiting = work.waiting > 0 ? " · \(work.waiting) waiting" : ""
        if let until = work.countdown {
            let seconds = SummaryPlacementWords.secondsLeft(until: until, at: now)
            return Line(id: "work", title: SummaryPlacementWords.countdown(of: name, seconds: seconds), opens: .conversation(work.id),
                        choices: work.choices.map { Choice(title: $0.title, action: .placement($0, work.id)) })
        }
        if let model = work.cloudModel {
            return Line(id: "work", title: SummaryPlacementWords.inCloud(model, of: name) + waiting, opens: .conversation(work.id))
        }
        let verb = ProcessingWords.verb(work.stage)
        let figure = work.stage == .summarizing ? "…" : work.fraction.map { " · \(ProcessingWords.percentText($0))" } ?? "…"
        return Line(id: "work", title: "\(verb) \(name)\(figure)\(waiting)", opens: .conversation(work.id))
    }

    /// A recorder's items: what it's doing when it's worth saying ("Importing from Soundcore Work · 1 of 3", "Soundcore
    /// Work · Listening live"), then its new recordings ("Soundcore Work · 2 New Recordings…"). Connected and idle, or
    /// away, it says nothing here.
    static func recorderLines(_ facts: RecorderFacts, now: Date = Date()) -> [Line] {
        var lines: [Line] = []
        if let item = RecorderStatusWords.menuItem(facts, here: here) {
            lines.append(Line(id: "recorder-\(facts.id)", title: item, opens: .device(facts.id)))
        } else {
            let line = RecorderStatusWords.line(facts, here: here, now: now)
            if [.working, .recording, .attention].contains(line.tone) {
                lines.append(Line(id: line.id, title: "\(facts.name) · \(line.text)", opens: .device(facts.id)))
            }
        }
        if let new = RecorderStatusWords.newRecordingsItem(facts) {
            lines.append(Line(id: "recorder-\(facts.id)-new", title: new, opens: .device(facts.id)))
        }
        return lines
    }

    /// The facts, from the app.
    @MainActor
    static func inputs(_ state: AppState) -> Inputs {
        var inputs = Inputs(sync: state.sync.status)
        if let id = state.processingID, let meeting = state.meetings.first(where: { $0.id == id }) {
            var work = Work(id: id, title: meeting.effectivePlacement == .personal ? nil : meeting.title, stage: state.runningStage,
                            fraction: state.processingProgress.fraction, waiting: state.processingQueue.count)
            switch state.placements[id]?.phase {
            case .countingDown(_, let until)?:
                work.countdown = until
                work.choices = state.placements[id]?.actions ?? []
            case .started(.cloud(let model))?:
                work.cloudModel = model.name
            default:
                break
            }
            inputs.work = work
        }
        inputs.models = state.modelDownloadState
        for session in state.devices.sessions {
            if session.kind.id == DaybookPhoneIntegration.id {
                guard session.direct != nil else { continue }
                var activity: PeerFacts.Activity = .idle
                if session.isLinked, let id = UUID(uuidString: session.id), let recording = state.phoneLink.recordingStates[id] {
                    switch recording.phase {
                    case .recording, .starting: activity = .recording
                    case .paused: activity = .paused
                    default: activity = .idle
                    }
                }
                inputs.phones.append(PeerFacts(id: session.id, name: session.device.name, kind: .iPhone, isConnected: session.isLinked,
                                               activity: activity, lastSeen: session.direct?.lastConnectedAt))
            } else {
                inputs.recorders.append(RecorderFacts(session: session, handoff: state.recorderHandoff.state(of: session)))
            }
        }
        return inputs
    }
}

/// "Listening for calls", from the call detector itself.
private struct DetectionStatusText: View {
    let monitor: MeetingMonitor
    var body: some View { Text(monitor.statusText) }
}
