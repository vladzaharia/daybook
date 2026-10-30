#if DEBUG
import AppKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// Debug-only: `--library-demo` fills the `--library` folder (never the everyday library) with
/// conversations in every state the list, the page, and the inspector show, so each can be
/// captured without recording or processing:
///
/// - ready with a summary, next steps, bookmarks, and tags; one with a very long title and a
///   recording that couldn't be lined up; one with a transcript and no summary;
/// - transcribing on this Mac (40%), waiting after it, paused, and waiting for models;
/// - transcribing on another Mac, and requested on an iPhone with no Mac to take it;
/// - failed transcribing, failed summarizing, and a recording with no speech;
/// - recorded and not transcribed; notes only;
/// - a recorder's recording still to come, and a recording that may belong elsewhere;
/// - a folder with conversations in it, and an empty one.
///
/// The recordings are short silent files with the lengths of real ones. The processing states
/// are this Mac's queue, so they're set again at every launch; the queue itself never runs.
/// `--window-size <W>x<H>` sizes the main window (with or without the demo); with it, `--multi-select
/// "<title>|<title>"` selects several conversations and `--notice "<text>"` shows a library notice.
@MainActor
enum LibraryDemo {
    static var isRequested: Bool { CommandLine.arguments.contains("--library-demo") && LaunchOptions.libraryURL != nil }

    static let ready = "Weekly product sync"
    static let longTitle = "Quarterly planning with finance, design, and platform on the spring launch budget, hiring, and the packaging timeline"
    static let transcribing = "Roadmap review"
    static let queued = "Customer call: Northwind Traders"
    static let paused = "1:1 with Priya"
    static let waitingForModels = "Research interview"
    static let elsewhere = "Standup"
    static let requested = "Dentist appointment"
    static let failedTranscribing = "Board prep"
    static let failedSummarizing = "Interview debrief"
    static let noSpeech = "Hallway chat"
    static let recorded = "Vendor walkthrough"
    static let transcriptOnly = "Onboarding design review"
    static let notesOnly = "Grocery list for the weekend"
    static let older = "Offsite retro"

    /// Filling the library and selecting `--select`'s conversation. Other demos that change the
    /// place or add conversations wait for it, so they land in the same order every launch.
    private(set) static var seeding: Task<Void, Never>?

    static func apply(to state: AppState) {
        resizeWindow()
        runWindowActions()
        guard isRequested else { return }
        // Each capture starts from the same chrome: the inspector only with `--inspector`, and
        // `--inspector-all` opens every section of it.
        LaunchOptions.defaults.set(CommandLine.arguments.contains("--inspector"), forKey: "isInspectorPresented")
        if CommandLine.arguments.contains("--inspector-all") {
            for key in ["inspector.details", "inspector.people", "inspector.audio", "inspector.processing"] { LaunchOptions.defaults.set(true, forKey: key) }
        }
        seeding = Task {
            if !state.meetings.contains(where: { $0.title == ready }) { await seed(state) }
            if SpeakerProfileDemo.isRequested { await SpeakerProfileDemo.seed(state.library) }
            settle(state)
            // Seeding is asynchronous: the launch's own `--select` and `--place` ran before it.
            if let title = LaunchOptions.value(after: "--select"), let id = state.meetings.first(where: { $0.title == title })?.id {
                state.selectedID = id
            }
            if let place = LaunchOptions.value(after: "--place"), place.hasPrefix("folder:"),
               let folder = state.folders.first(where: { $0.name == place.dropFirst(7) }) {
                state.place = .folder(folder.id)
            }
            // `--multi-select "<title>|<title>…"` selects several rows; `--notice "<text>"` shows a library notice.
            if let titles = LaunchOptions.value(after: "--multi-select")?.split(separator: "|").map(String.init) {
                state.multiSelection = Set(state.meetings.filter { titles.contains($0.title) }.map(\.id))
            }
            if let notice = LaunchOptions.value(after: "--notice") { state.notice = notice }
        }
    }

    /// `--window-size <W>x<H>`: the main window's size, to check narrow and wide layouts.
    private static func resizeWindow() {
        guard let value = LaunchOptions.value(after: "--window-size") else { return }
        let parts = value.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WindowID.library) == true || $0.title == "Daybook" }) else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: parts[0], height: parts[1])), display: true)
    }

    /// `--window-actions activate,fullscreen,toolbar,zoom,top,sidebar,…`: what the main window goes
    /// through, a step every 1.5 s, so a snapshot after them shows whether every column still starts
    /// under the toolbar. A step named twice undoes itself (full screen in and out, the toolbar hidden
    /// and shown); `activate` brings the app forward first, which full screen needs and which only an
    /// app opened through Launch Services (`open`) is allowed to do.
    private static func runWindowActions() {
        guard let steps = LaunchOptions.value(after: "--window-actions")?.split(separator: ",").map(String.init) else { return }
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(index + 1)) {
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WindowID.library) == true }) else { return }
                switch step {
                case "activate":
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                case "fullscreen": window.toggleFullScreen(nil)
                case "toolbar": window.toggleToolbarShown(nil)
                case "zoom": window.zoom(nil)
                case "top":
                    // Against the top of the screen, as a window dragged under the menu bar can be.
                    if let screen = window.screen { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: screen.frame.maxY)) }
                case "sidebar": NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
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
            state.processingProgress = IntelligenceProgress(0.4, "Transcribing")
        }
        if let waiting = id(queued) { state.processingQueue = [state.makeJob(meetingID: waiting, mode: .newAudio)] }
        if let held = id(paused) { state.pausedIDs = [held] }
        if let models = id(waitingForModels) { state.awaitingModels = [models] }
    }

    // MARK: Seeding

    private static func seed(_ state: AppState) async {
        let now = Date()
        func ago(days: Double = 0, hours: Double = 0, minutes: Double = 0) -> Date {
            now.addingTimeInterval(-(days * 86_400 + hours * 3600 + minutes * 60))
        }
        let clients = LibraryFolder(name: "Clients")
        state.saveFolder(clients)
        state.saveFolder(LibraryFolder(name: "Archive"))

        // Ready, with everything the page shows.
        let sync = await conversation(state, ready, at: ago(hours: 2), minutes: 28)
        state.update(sync.id) { meeting in
            meeting.speakers = [Speaker(id: "0", name: "Alex"), Speaker(id: "1", name: "Priya"), Speaker(id: "2", name: "Sam")]
            transcribe(&meeting, track: sync.track, lines: [
                (5, "0", "Let's start with the launch checklist. We're two weeks out and most of it is green."),
                (31, "1", "The onboarding flow is done. QA found two issues in the permissions step, both small."),
                (64, "2", "I can take those today. The second one is just copy."),
                (240, "0", "Good. Pricing page next. Marketing wants the annual plan to lead."),
                (282, "1", "Then the comparison table has to change too, or it contradicts the headline."),
                (610, "2", "On support: we'll staff the chat for the first week, mornings and evenings."),
                (902, "0", "Last thing, the press note. Priya, can you send the draft by Thursday?"),
                (931, "1", "Yes, Thursday works.")
            ])
            meeting.notes = "Launch is two weeks out\nAnnual plan leads the pricing page\nPress note draft by Thursday"
            meeting.timedNotes = [TimedNote(time: 12, text: "Launch is two weeks out"),
                                  TimedNote(time: 250, text: "Annual plan leads the pricing page"),
                                  TimedNote(time: 910, text: "Press note draft by Thursday")]
            meeting.highlights = [Highlight(time: 290, text: "Comparison table must match"), Highlight(time: 905)]
            meeting.tags = ["launch", "pricing"]
            meeting.placement = .work
            // A recorder that recorded along and hasn't sent its recording yet.
            var link = CompanionRecording(deviceID: "soundcore-work", deviceKind: "soundcore.work", deviceName: "Soundcore Work",
                                          macStartedAt: meeting.date, state: .stopped, startedByDaybook: true)
            link.macEndedAt = meeting.date.addingTimeInterval(28 * 60)
            meeting.companions = [link]
            meeting.kind = .general
            meeting.setSummary(MeetingSummary(kind: .general, title: ready,
                overview: "The launch is on track for two weeks out. Onboarding is done apart from two small QA fixes, the pricing page will lead with the annual plan, and support covers the first week.",
                sections: [
                    SummarySection(heading: "Launch checklist", body: "- Onboarding is complete; two QA issues remain in the permissions step.\n- **Sam** fixes both today."),
                    SummarySection(heading: "Pricing", body: "- The annual plan leads the page.\n- The comparison table changes to match the headline.")
                ],
                actionItems: [ActionItem(text: "Fix the two permissions issues QA found", owner: "Sam", completed: true),
                              ActionItem(text: "Update the comparison table to lead with the annual plan", owner: "Priya"),
                              ActionItem(text: "Send the press note draft by Thursday", owner: "Priya"),
                              ActionItem(text: "Staff support chat mornings and evenings for launch week")],
                modelID: "gemma-4/e2b-4bit"))
            meeting.status = .ready
        }

        // A very long title, and a second recording that couldn't be lined up.
        let planning = await conversation(state, longTitle, at: ago(days: 1, hours: 3), minutes: 52)
        let soundcore = await addTrack(state, to: planning.id, source: .soundcore, minutes: 49, seconds: 11)
        state.update(planning.id) { meeting in
            meeting.speakers = [Speaker(id: "0", name: "Dana"), Speaker(id: "1", name: "Speaker 2")]
            transcribe(&meeting, track: planning.track, lines: [
                (8, "0", "We have three things today: the budget, hiring, and packaging."),
                (44, "1", "Marketing is about ten percent over. Events are under by about the same."),
                (1220, "0", "Then we move the difference over and keep the launch date.")
            ])
            if let soundcore {
                meeting.transcripts.append(TrackTranscript(trackID: soundcore, segments: [
                    TranscriptSegment(trackID: soundcore, start: 30, end: 40, text: "Marketing is about ten percent over.", speakerID: "1")
                ], modelID: "parakeet-tdt-0.6b-v3"))
                meeting.alignmentReports.append(TrackAlignment(trackID: soundcore, method: .unaligned))
            }
            meeting.notes = "Budget: move events → marketing"
            meeting.placement = .work
            meeting.setSummary(MeetingSummary(kind: .general, title: longTitle,
                overview: "The team moved the events underspend to marketing, kept the launch date, and agreed to revisit packaging next week.",
                actionItems: [ActionItem(text: "Revisit the packaging timeline next week", owner: "Dana")],
                modelID: "gemma-4/e2b-4bit"))
            meeting.status = .ready
        }

        // Transcribing on this Mac, and one waiting after it.
        let design = await conversation(state, transcribing, at: ago(minutes: 40), minutes: 41)
        state.update(design.id) { $0.notes = "Agenda: the floating panel, then the shared design pieces." }
        let northwind = await conversation(state, queued, at: ago(hours: 1), minutes: 33)
        state.update(northwind.id) { $0.folderID = clients.id; $0.placement = .work }

        let priya = await conversation(state, paused, at: ago(days: 1, hours: 6), minutes: 24)
        state.update(priya.id) { $0.placement = .work }
        let research = await conversation(state, waitingForModels, at: ago(days: 20), minutes: 22)
        state.update(research.id) { $0.folderID = clients.id }

        // On another device: transcribing on another Mac, and asked for on an iPhone.
        let standup = await conversation(state, elsewhere, at: ago(hours: 3), minutes: 12)
        state.update(standup.id) { meeting in
            let studio = ProcessingRequest.Device(id: "studio-mac", name: "Studio Mac")
            let phone = ProcessingRequest.Device(id: "alex-iphone", name: "Alex’s iPhone")
            meeting.processingRequests = [ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: ago(hours: 3),
                claim: .init(device: studio, claimedAt: now, heartbeat: now, expiresAt: now.addingTimeInterval(3600), stage: .transcribing, fraction: 0.55))]
            meeting.status = .imported
        }
        let dentist = await conversation(state, requested, at: ago(days: 2, hours: 1), minutes: 8, source: .imported)
        state.update(dentist.id) { meeting in
            meeting.processingRequests = [ProcessingRequest(meetingID: meeting.id, mode: .newAudio,
                requestedBy: ProcessingRequest.Device(id: "alex-iphone", name: "Alex’s iPhone"), createdAt: ago(days: 2))]
            meeting.placement = .personal
            meeting.status = .imported
        }

        // Couldn't finish: transcribing, summarizing, and a recording with nothing said.
        let board = await conversation(state, failedTranscribing, at: ago(days: 3), minutes: 18)
        state.update(board.id) { $0.status = .failed; $0.errorMessage = "Transcription stopped: the model process exited unexpectedly (code 5)." }
        let debrief = await conversation(state, failedSummarizing, at: ago(days: 4), minutes: 45)
        state.update(debrief.id) { meeting in
            meeting.speakers = [Speaker(id: "0", name: "Alex"), Speaker(id: "1", name: "Jordan")]
            transcribe(&meeting, track: debrief.track, lines: [
                (3, "0", "Strong on systems design. A little quiet in the product round."),
                (40, "1", "Agreed. I'd hire, with a note about pairing in the first month.")
            ])
            meeting.status = .failed
            meeting.errorMessage = "The language model couldn’t allocate enough memory."
            meeting.placement = .work
        }
        let hallway = await conversation(state, noSpeech, at: ago(days: 5), minutes: 2)
        state.update(hallway.id) { $0.status = .failed; $0.errorMessage = "No speech was detected in this recording." }

        // Recorded and not transcribed, a transcript without a summary, and notes only.
        let vendor = await conversation(state, recorded, at: ago(days: 6), minutes: 15)
        state.update(vendor.id) { meeting in
            meeting.status = .imported
            meeting.folderID = clients.id
            // A recording that may belong with another conversation.
            if let track = vendor.track {
                meeting.sourceSuggestions = [SourceSuggestion(trackID: track, candidateMeetingIDs: [northwind.id], reason: .lowConfidence)]
            }
        }
        let onboarding = await conversation(state, transcriptOnly, at: ago(days: 12), minutes: 36)
        state.update(onboarding.id) { meeting in
            meeting.speakers = [Speaker(id: "0", name: "Priya"), Speaker(id: "1", name: "Sam")]
            transcribe(&meeting, track: onboarding.track, lines: [
                (2, "0", "The first screen asks for too much. Can we move the workspace name later?"),
                (19, "1", "Yes, it can default to the account name and be renamed in Settings."),
                (55, "0", "Then the welcome screen is just the sign-in and one sentence.")
            ])
            meeting.notes = "Workspace name moves to Settings"
            meeting.status = .ready
        }
        let groceries = state.newMeeting(title: notesOnly, date: ago(days: 2, hours: 20), selecting: false)
        state.update(groceries) { $0.notes = "Tomatoes, basil, mozzarella\nBread from the bakery on Saturday\nAsk about the farmers’ market hours"; $0.placement = .personal }

        let retro = await conversation(state, older, at: ago(days: 41), minutes: 61)
        state.update(retro.id) { meeting in
            meeting.speakers = [Speaker(id: "0", name: "Alex")]
            transcribe(&meeting, track: retro.track, lines: [(4, "0", "What went well this quarter, and what we'd change.")])
            meeting.setSummary(MeetingSummary(kind: .general, title: older, overview: "The team kept the weekly demo and dropped the Friday status email.", modelID: "gemma-4/e2b-4bit"))
            meeting.status = .ready
        }
        state.selectedID = sync.id
    }

    /// A conversation with one recording of the given length.
    private static func conversation(_ state: AppState, _ title: String, at date: Date, minutes: Double,
                                     source: AudioSource = .microphone) async -> (id: UUID, track: UUID?) {
        let id = state.library.newMeeting(title: title, date: date)
        let track = await addTrack(state, to: id, source: source, minutes: minutes)
        return (id, track)
    }

    /// Adds a short silent file as a recording, then gives the track the length a real one would have.
    private static func addTrack(_ state: AppState, to id: UUID, source: AudioSource, minutes: Double, seconds: Int = 4) async -> UUID? {
        let folder = DemoAudio.newFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent(source == .soundcore ? "REC0042.wav" : "\(source.recordingName).wav")
        try? PhotoDemo.silentWAV(seconds: seconds).write(to: audio)
        await state.library.acquireLock()
        defer { state.library.releaseLock() }
        guard let ingested = try? await state.library.ingest(audio, into: id, provenance: RecordingProvenance(
            source: source, offset: 0, duration: minutes * 60, startedAt: state.meetings.first { $0.id == id }?.date, capture: TrackCaptureDetails())),
              let track = ingested.track else { return nil }
        state.update(id) { meeting in
            if let index = meeting.tracks.firstIndex(where: { $0.id == track.id }) { meeting.tracks[index].duration = minutes * 60 }
        }
        return track.id
    }

    /// The transcript a run would have made: one track's passages, fused as they are.
    private static func transcribe(_ meeting: inout Meeting, track: UUID?, lines: [(TimeInterval, String, String)]) {
        guard let track else { return }
        let segments = lines.enumerated().map { index, line in
            TranscriptSegment(trackID: track, start: line.0, end: index + 1 < lines.count ? lines[index + 1].0 - 1 : line.0 + 12,
                              text: line.2, speakerID: line.1)
        }
        meeting.transcripts = [TrackTranscript(trackID: track, segments: segments, modelID: "parakeet-tdt-0.6b-v3")]
        meeting.unifiedTranscript = segments
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
