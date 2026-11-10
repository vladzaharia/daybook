import AppKit
import CoreAudio
import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import DaybookLink
import DaybookUI
import Foundation
import Observation

// Where Floating Notes' status comes from: the device hub and every recorder session, the iPhone
// link, recorder handoff, sync, and the few capture facts that change rarely (call audio detected,
// a microphone that isn't hearing anything, the disk running out of room). The panel reads them through
// `FloatingStatusInputs.make`, and redraws for what it read; the meters, which change 15 times a second, are sampled
// apart (`RecorderLevels`).

extension StatusOverviewInputs {
    /// The Mac's gatherer of the overview both apps draw (the iPhone's is `StatusSheetInputs.make`): the recording, with
    /// this Mac's recorders and the iPhones paired with it, this Mac's queue, and iCloud while sync needs the person.
    /// `meeting` is the conversation the panel shows; `afterStop` says the panel watched it record and stop.
    @MainActor
    static func make(_ state: AppState, meeting: Meeting?, afterStop: Bool, inputDevice: String?) -> StatusOverviewInputs {
        var inputs = StatusOverviewInputs(words: .mac(id: state.library.thisDevice.id))
        let levels = state.recorder.levels
        let isRecording = meeting.map { state.recordingID == $0.id } ?? false
        if isRecording {
            inputs.recording.phase = state.isStoppingRecording ? .saving : .recording
        } else if state.isStartingRecording {
            inputs.recording.phase = .starting
        } else if afterStop, let meeting {
            inputs.recording.phase = FloatingStatusInputs.stoppedShort(meeting, state: state) ? .stopped : .saved
        }
        inputs.recording.here = AppState.thisDeviceWords
        inputs.recording.duration = meeting?.duration
        inputs.recording.inputDevice = inputDevice
        // The band's phase is the input menu while recording (`MicrophoneMenu`).
        inputs.recording.choosesInput = isRecording
        inputs.recording.microphoneSilent = isRecording && levels.isMicrophoneSilent
        // Call audio stopped for the disk's last minutes: the storage chip says so, not a missing call.
        let callStoppedForSpace = isRecording && state.recorder.callStoppedForSpace
        inputs.recording.spaceLeft = isRecording ? state.recorder.spaceLeft : nil
        inputs.recording.callStoppedForSpace = callStoppedForSpace
        inputs.recording.includesCall = isRecording && state.includeComputerAudio && !callStoppedForSpace
        if isRecording, state.includeComputerAudio, !callStoppedForSpace {
            if levels.isCapturingCall {
                inputs.recording.call = levels.isCallAudioDetected ? .detected : .quiet
            } else if state.recorder.isRecording, state.recorder.elapsedTime > 5 {
                inputs.recording.call = .missing
            }
        }
        let links = isRecording ? (meeting?.companions ?? []).filter { $0.macEndedAt == nil } : []
        for session in state.devices.sessions where session.direct != nil {
            let along = links.last { $0.deviceID == session.id }?.state
            if session.kind.id == DaybookPhoneIntegration.id {
                inputs.recording.peers.append(phone(session, state: state, along: along))
            } else {
                inputs.recording.recorders.append(RecorderFacts(session: session, handoff: state.recorderHandoff.state(of: session), along: along))
            }
        }
        inputs.local = queue(state)
        if state.sync.status.problem != nil {
            // The line names iCloud sync; the chip's menu says what's wrong (`FloatingStatusInputs.syncProblem`).
            inputs.syncTone = .attention
            inputs.syncLine = "Not syncing"
        }
        return inputs
    }

    @MainActor
    private static func phone(_ session: DeviceSession, state: AppState, along: CompanionRecording.State?) -> RecordingStatusInputs.Peer {
        var phone = RecordingStatusInputs.Peer(id: session.id, name: session.device.name, kind: .iPhone, isConnected: session.isLinked,
                                               along: along, lastConnected: session.direct?.lastConnectedAt)
        // The phone this Mac records for, out of reach: its chip says so while this Mac keeps recording.
        if let lead = state.phones.leadOutOfReach, lead.sessionID == session.id, lead.meetingID == state.recordingID { phone.outOfReach = true }
        if let id = UUID(uuidString: session.id), let recording = state.phoneLink.recordingStates[id], phone.isConnected {
            switch recording.phase {
            case .recording, .starting: phone.activity = .recording
            case .paused: phone.activity = .paused
            default: phone.activity = .idle
            }
        }
        return phone
    }

    /// This Mac's queue, as the line both apps use for a device's own work counts it.
    @MainActor
    private static func queue(_ state: AppState) -> QueueStatusWords.Queue {
        var queue = QueueStatusWords.Queue()
        if let id = state.processingID, state.meetings.contains(where: { $0.id == id }) {
            // The step the page and the claim say (`AppState.runningStage`), never guessed from the engine's words.
            queue.running = state.runningStage
            queue.fraction = state.processingProgress.fraction
            switch state.placements[id]?.phase {
            case .countingDown(_, let until)?: queue.countdown = until
            case .started(.cloud(let model))?: queue.cloudModel = model.name
            default: break
            }
        }
        queue.waiting = state.processingQueue.count
        queue.awaitingModels = state.awaitingModels.count
        queue.models = state.modelDownloadState
        return queue
    }
}

extension FloatingStatusInputs {
    /// Gathers the panel's facts: the overview (`StatusOverviewInputs.make`), and the conversation the panel shows once
    /// that isn't recording.
    @MainActor
    static func make(_ state: AppState, meeting: Meeting?, afterStop: Bool, inputDevice: String?) -> FloatingStatusInputs {
        var inputs = FloatingStatusInputs(overview: .make(state, meeting: meeting, afterStop: afterStop, inputDevice: inputDevice))
        let isRecording = meeting.map { state.recordingID == $0.id } ?? false
        // A recording that failed with nothing saved has nothing to process; the panel says what happened instead.
        if let meeting, !isRecording, inputs.phase != .stopped || !meeting.tracks.isEmpty {
            inputs.conversation = conversation(meeting, state: state)
        }
        inputs.syncProblem = syncProblem(state.sync.status.problem)
        #if DEBUG
        FloatingNotesDemo.adjust(&inputs, meeting: meeting)
        #endif
        return inputs
    }

    /// The recording ended short: nothing reached the conversation, or this Mac's capture stopped on its own
    /// (`AppState.unexpectedStops`), so what's saved ends early.
    @MainActor
    static func stoppedShort(_ meeting: Meeting, state: AppState) -> Bool {
        (meeting.status == .failed && meeting.tracks.isEmpty) || state.unexpectedStops[meeting.id] != nil
    }

    /// The shown conversation in the words its list row uses on this Mac (`MacRowStatus`), and, once its work is done,
    /// what's ready: the summary, or the transcript with what the summary waits for, as the page says.
    @MainActor
    static func conversation(_ meeting: Meeting, state: AppState) -> Conversation {
        let status = state.processingStatus(for: meeting)
        var shown = Conversation(status: status, row: MacRowStatus.make(state, meeting))
        switch status {
        case .done:
            shown.ready = meeting.summary != nil ? true : meeting.unifiedTranscript.isEmpty ? nil : false
        case .transcribed:
            // Transcript first: its summary waits for this Mac's summary model, as the page says.
            shown.ready = false
            if state.summaryWaitsForModel(meeting), let models = state.modelDownloadState {
                shown.summaryWaits = ProcessingWords.summaryWaitsLine(models)
            }
        default:
            break
        }
        return shown
    }

    /// What needs the person about sync, in a line that names iCloud sync (the panel has no section saying so). The
    /// system's own words stay in Settings, behind Details.
    static func syncProblem(_ problem: SyncProblem?) -> String? {
        switch problem {
        case nil: return nil
        case .failure: return "iCloud sync is paused."
        case .accountChanged: return "iCloud sync is paused: the iCloud account changed"
        case .previousFolderAccessLost: return "iCloud sync is paused: choose the folder this Mac synced through again"
        case .previousFolderMissing: return "iCloud sync is paused: the folder this Mac synced through can’t be found"
        case .libraryRemoved: return "iCloud sync is paused: the library in iCloud was removed"
        case .libraryNotEncrypted: return "iCloud sync is paused: the library in iCloud isn’t encrypted"
        case .migrationPaused: return "Moving to iCloud is paused."
        case .storageFull, .folderAccountChanged, .iCloudUnavailable, .reconnectFolder, .couldNotUseFolder: return problem?.text
        }
    }
}

// MARK: - The microphone

/// The Mac's inputs and the person's choice among them, kept current for Floating Notes' input menu and Settings ›
/// Recording, and the name of the input recording uses ("MacBook Pro Microphone"): the recording's own while one
/// runs, otherwise the one the choice resolves to now (`MicrophoneChoice`). Reading devices needs no permission and
/// never touches a microphone.
@MainActor
@Observable
final class MicrophoneInputs {
    private(set) var devices: [MicrophoneChoice.Device] = []
    private(set) var preference: MicrophoneChoice.Preference = .automatic
    /// The input a recording would use now.
    private(set) var resolved: MicrophoneChoice.Device?
    @ObservationIgnored private let store: MicrophonePreferenceStore
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var observer: NSObjectProtocol?
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    init(store: MicrophonePreferenceStore = .live) { self.store = store }

    /// The input recording uses, or would.
    var name: String? { MicrophoneInUse.shared.device?.name ?? resolved?.name }

    /// What a menu of inputs lists after Automatic.
    var menuDevices: [MicrophoneChoice.Device] { MicrophoneChoice.menuDevices(devices, preference: preference) }

    func start() {
        guard listener == nil else { return }
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        for selector in Self.selectors {
            var address = CoreAudioProperty.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listener = block
        observer = NotificationCenter.default.addObserver(forName: MicrophonePreferenceStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        if let listener {
            for selector in Self.selectors {
                var address = CoreAudioProperty.address(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            }
        }
        listener = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Records from `preference` from now on; a recording under way moves to it at once.
    func choose(_ preference: MicrophoneChoice.Preference) {
        store.save(preference)
        refresh()
    }

    private func refresh() {
        let snapshot = CoreAudioInputs.snapshot(preference: store.load())
        if snapshot.devices != devices { devices = snapshot.devices }
        if snapshot.preference != preference { preference = snapshot.preference }
        let now = snapshot.resolved
        if now != resolved { resolved = now }
    }
}

// MARK: - Levels

extension RecorderLevels.Readers {
    /// The live sources: this Mac's level monitor (the call only while it's captured), each recorder's live audio
    /// saved into the recording, and each iPhone's levels over the link.
    @MainActor
    static func live(_ state: AppState) -> Self {
        let monitor = state.recorder.levels
        return Self(
            microphone: { [weak monitor] in monitor.map { $0.microphone.meterValue } },
            call: { [weak monitor] in
                guard let monitor, monitor.isCapturingCall else { return nil }
                return monitor.call.meterValue
            },
            recorder: { [weak state] id in
                guard let state, let conversation = state.recordingID else { return nil }
                return state.devices.session(id)?.liveLevel(into: conversation)
            },
            peer: { [weak state] id in
                guard let state, let conversation = state.recordingID, let phone = UUID(uuidString: id) else { return nil }
                return state.phoneLevels.next(phone, conversation: conversation)
            })
    }
}
