#if DEBUG
import AppKit
import DaybookCore
import DaybookDevices
import DaybookIntelligence
import DaybookKit
import Foundation

/// Debug-only Floating Notes states for snapshots, without a microphone, a call, or an iPhone:
///
///     --notes-demo multipoint|paused|processing|stopped|failed|home   [--notes-size 340x230] [--notes-contrast]
///
/// - `multipoint`: with `--simulate-recording`: the iPhone and Soundcore record along (links written
///   to the conversation as multipoint writes them), and call audio is detected.
/// - `paused`: the same, with the iPhone paused (its link state is what the phone would send).
/// - `processing`: after Stop, the conversation transcribing on this Mac at 40%.
/// - `stopped`: after Stop, the recording itself failed. `failed`: transcription couldn't finish.
/// - `home`: the panel opened from the menu bar, nothing recording, this Mac transcribing another.
///
/// Combine with `--device-demo connected` (a Soundcore at 80%), `--phone-demo connected` (a paired
/// iPhone on loopback), and `--handoff-demo managed` (the Soundcore managed by the iPhone).
/// `--notes-size` sets the panel's size; `--notes-contrast` draws it in the Increase Contrast
/// appearance. Nothing reaches the network beyond loopback, Bluetooth, or the microphone.
@MainActor
enum FloatingNotesDemo {
    enum Scenario: String { case multipoint, paused, processing, stopped, failed, home }

    static let scenario = LaunchOptions.value(after: "--notes-demo").flatMap(Scenario.init(rawValue:))
    static let size: NSSize? = LaunchOptions.value(after: "--notes-size").flatMap { value in
        let parts = value.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }
    static let increasedContrast = CommandLine.arguments.contains("--notes-contrast")
    /// A simulated recording has no audio, so the meters draw a stand-in conversation.
    static let syntheticLevels = CommandLine.arguments.contains("--simulate-recording")

    /// Sets up the scenario once the library is ready (after `--simulate-recording`, if any).
    static func apply(to state: AppState) {
        guard let scenario else { return }
        switch scenario {
        case .multipoint, .paused:
            // Give the device demos a moment to connect, then link them as multipoint would.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { linkCompanions(state) }
        case .processing:
            let id = conversation(state, title: "Design review", notes: notes)
            state.update(id) { $0.status = .transcribing; $0.date = Date().addingTimeInterval(-900) }
            state.processingID = id
            state.processingProgress = IntelligenceProgress(0.4, "Transcribing")
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

    /// What the iPhone would report that the demo phone can't send: a pause.
    static func adjust(_ inputs: inout FloatingStatusInputs, meeting: Meeting?) {
        guard scenario == .paused, inputs.phase == .recording else { return }
        for index in inputs.phones.indices where inputs.phones[index].along != nil {
            inputs.phones[index].activity = .paused
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
        state.selectedID = id
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
        let heard = AudioLevelMeter.Reading(rms: -18, peak: -9, lastAudibleHostTime: ProcessInfo.processInfo.systemUptime, receivedSignal: true)
        now.update(microphone: heard, call: heard, hostTime: ProcessInfo.processInfo.systemUptime, elapsed: 761)
    }
}
#endif
