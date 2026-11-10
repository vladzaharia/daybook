#if DEBUG
import AppKit
import DaybookCore
import DaybookDevices
import DaybookIntelligence
import DaybookKit
import Foundation

/// Debug-only Floating Notes states for snapshots, without a microphone, a call, or an iPhone:
///
///     --notes-demo multipoint|paused|trouble|processing|stopped|slept|failed|home   [--notes-size 340x230] [--notes-contrast]
///
/// - `multipoint`: with `--simulate-recording`: the iPhone and Soundcore record along (links written
///   to the conversation as multipoint writes them), and call audio is detected.
/// - `paused`: the same, with the iPhone paused (its link state is what the phone would send).
/// - `trouble`: with `--simulate-recording`: the microphone isn't hearing and the disk has room for 25 minutes.
/// - `processing`: after Stop, the conversation transcribing on this Mac at 40%.
/// - `models`, `models-failed`, `models-wifi`: after Stop, the conversation waiting for this Mac's models while they
///   download (a download that reports 42% and waits, never the network), after one stopped, or waiting for Wi‑Fi.
/// - `summary-waits`: after Stop, the conversation transcribed, its summary waiting for this Mac's summary model while
///   it downloads (transcript first; with `--cloud-demo anthropic`, Use the Cloud too).
/// - `stopped`: after Stop, the recording itself failed. `failed`: transcription couldn't finish.
/// - `slept`: this Mac went to sleep mid-recording and the Soundcore and the iPhone kept recording.
/// - `home`: the panel opened from the menu bar, nothing recording, this Mac transcribing another.
///
/// `--notes-open` closes the main window once the scenario shows, then opens the conversation from the panel as
/// Open does, so a snapshot shows the window come back.
///
/// Combine with `--device-demo connected` (a Soundcore at 80%), `--phone-demo connected` (a paired
/// iPhone on loopback), and `--handoff-demo managed` (the Soundcore managed by the iPhone).
/// `--notes-size` sets the panel's size; `--notes-contrast` draws it in the Increase Contrast
/// appearance. Nothing reaches the network beyond loopback, Bluetooth, or the microphone.
@MainActor
enum FloatingNotesDemo {
    enum Scenario: String {
        case multipoint, paused, trouble, processing, stopped, slept, failed, home
        case models, modelsFailed = "models-failed", modelsWiFi = "models-wifi"
        case summaryWaits = "summary-waits"
    }

    static let scenario = LaunchOptions.value(after: "--notes-demo").flatMap(Scenario.init(rawValue:))
    static let size: NSSize? = LaunchOptions.value(after: "--notes-size").flatMap { value in
        let parts = value.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }
    static let increasedContrast = CommandLine.arguments.contains("--notes-contrast")
    /// A simulated recording has no audio, so the meters draw a stand-in conversation.
    static let syntheticLevels = CommandLine.arguments.contains("--simulate-recording")
    /// `--notes-open`: the panel opens its conversation (as Open does) after the main window was closed.
    static let openRequested = Notification.Name("FloatingNotesDemo.openRequested")

    /// Sets up the scenario once the library is ready (after `--simulate-recording`, if any).
    static func apply(to state: AppState) {
        if CommandLine.arguments.contains("--notes-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(WindowID.library) == true { window.close() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NotificationCenter.default.post(name: openRequested, object: nil) }
            }
        }
        guard let scenario else { return }
        switch scenario {
        case .multipoint, .paused:
            // Give the device demos a moment to connect, then link them as multipoint would.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { linkCompanions(state) }
        case .trouble:
            break
        case .slept:
            let id = conversation(state, title: "Design review", notes: notes)
            let start = Date().addingTimeInterval(-900)
            let links = [("demo-soundcore", SoundcoreWorkIntegration.id, "Soundcore Work"), ("demo-iphone", DaybookPhoneIntegration.id, "Alex’s iPhone")].map {
                CompanionRecording(deviceID: $0.0, deviceKind: $0.1, deviceName: $0.2, macStartedAt: start, state: .recording, startedByDaybook: true)
            }
            state.update(id) { $0.status = .failed; $0.companions = links }
            state.phones.sleptRecording = SleptRecording(meetingID: id, startedAt: start, endedAt: Date(), cause: nil)
            show(state, id, afterStop: true)
        case .processing:
            let id = conversation(state, title: "Design review", notes: notes)
            state.update(id) { $0.status = .transcribing; $0.date = Date().addingTimeInterval(-900) }
            state.processingID = id
            state.processingProgress = IntelligenceProgress(0.4, "Transcribing")
            // `--placement-demo countdown|cloud`: its summary's countdown, or the cloud at work.
            PlacementDemo.apply(to: state, processing: id)
            show(state, id, afterStop: true)
        case .models, .modelsFailed, .modelsWiFi:
            let id = conversation(state, title: "Design review", notes: notes)
            state.update(id) { $0.date = Date().addingTimeInterval(-900) }
            state.queue.awaitModels(id)
            let demo: AppState.DownloadDemo = scenario == .models ? .downloading : scenario == .modelsFailed ? .failed : .waitingForWiFi
            state.demoDownloads(state.missingSelectedModels, demo)
            show(state, id, afterStop: true)
        case .summaryWaits:
            let id = conversation(state, title: "Design review", notes: notes)
            let lines = ["Ship the status bar first.", "Captions follow next week.", "Priya owns the handoff copy."]
            let track = UUID()
            state.update(id) { meeting in
                meeting.date = Date().addingTimeInterval(-900)
                meeting.unifiedTranscript = lines.enumerated().map { TranscriptSegment(trackID: track, start: Double($0) * 6, end: Double($0) * 6 + 5, text: $1) }
                meeting.status = .imported
            }
            // The queue never runs, and the summary model isn't here, whatever the launch's own look at the models finds.
            state.processingTask = Task { try? await Task.sleep(for: .seconds(86_400)) }
            func waitForSummaryModel() {
                state.installedModels.remove(state.summaryModel)
                state.queue.removeJobs(for: id)
                state.queue.awaitSummaryModel(id)
            }
            waitForSummaryModel()
            for delay in [1.0, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { waitForSummaryModel() } }
            state.demoDownloads([state.summaryModel], .downloading)
            show(state, id, afterStop: true)
        case .stopped:
            let id = conversation(state, title: "Design review", notes: notes)
            state.update(id) { $0.status = .failed; $0.errorMessage = "The microphone stopped responding." }
            show(state, id, afterStop: true)
        case .failed:
            guard let id = state.meetings.first(where: { $0.status == .failed && !$0.tracks.isEmpty })?.id else { return }
            show(state, id, afterStop: true)
        case .home:
            if let busy = state.meetings.first(where: { $0.title == "Onboarding design review" })?.id {
                state.processingID = busy
                state.update(busy) { $0.status = .transcribing }
                state.processingProgress = IntelligenceProgress(0.62, "Transcribing")
            }
            FloatingNotesWindow.shared.show(state: state, focus: nil)
        }
    }

    /// What the iPhone would report that the demo phone can't send: a pause. And capture trouble no demo makes.
    static func adjust(_ inputs: inout FloatingStatusInputs, meeting: Meeting?) {
        if scenario == .trouble, inputs.phase == .recording {
            inputs.recording.microphoneSilent = true
            inputs.recording.spaceLeft = 25 * 60 + 20
        }
        guard scenario == .paused, inputs.phase == .recording else { return }
        for index in inputs.recording.peers.indices where inputs.recording.peers[index].along != nil {
            inputs.recording.peers[index].activity = .paused
        }
    }

    private static let notes = """
    Agenda: the floating panel, then the shared design pieces.
    Ship the status bar first; captions follow.
    Ask Priya about the iPhone handoff copy.
    """

    private static func conversation(_ state: AppState, title: String, notes: String) -> UUID {
        if let existing = state.meetings.first(where: { $0.title == title })?.id { return existing }
        let id = state.newMeeting(title: title, date: Date().addingTimeInterval(-900))
        state.update(id) { $0.notes = notes }
        return id
    }

    private static func show(_ state: AppState, _ id: UUID, afterStop: Bool) {
        state.window.openID = id
        FloatingNotesWindow.shared.show(state: state, focus: id, afterStop: afterStop)
    }

    /// The links multipoint writes when the iPhone and the Soundcore record along, and the call
    /// audio the level monitor would report.
    private static func linkCompanions(_ state: AppState) {
        guard let id = state.recordingID, let start = state.recordingStartedAt else { return }
        var links: [CompanionRecording] = []
        for session in state.devices.sessions where session.direct != nil {
            var link = CompanionRecording(deviceID: session.id, deviceKind: session.kind.id, deviceName: session.device.name,
                                          macStartedAt: start, state: .recording, startedByDaybook: true)
            link.recorderStartedAt = start.addingTimeInterval(1.2)
            links.append(link)
        }
        state.update(id) { $0.companions = links }
        let now = state.recorder.levels
        let uptime = ProcessInfo.processInfo.systemUptime
        let heard = AudioLevelMeter.Reading(rms: -18, peak: -9, lastAudibleHostTime: uptime, lastSignalHostTime: uptime, lastHeardHostTime: uptime)
        now.update(microphone: heard, call: heard, hostTime: uptime, elapsed: 761)
    }
}
#endif
