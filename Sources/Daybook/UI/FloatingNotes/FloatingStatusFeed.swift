import AppKit
import Combine
import CoreAudio
import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import DaybookLink
import Foundation

// Where Floating Notes' status comes from: the device hub and every recorder session, the iPhone
// link, recorder handoff, sync, and the few level facts that change rarely (call audio detected,
// a silent microphone). Each publishes on its own; the feed turns them into one quiet signal so the
// status bar redraws a few times a second at most, never at the meters' 15 Hz.

@MainActor
final class FloatingStatusFeed: ObservableObject {
    @Published private(set) var revision = 0
    private var subscriptions: Set<AnyCancellable> = []

    init(state: AppState) {
        let levels = state.recorder.levels
        let rare: [AnyPublisher<Void, Never>] = [
            levels.$isCallAudioDetected.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            levels.$isMicrophoneSilent.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            levels.$isCapturingCall.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            state.devices.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            state.recorderHandoff.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            state.phoneLink.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            state.sync.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            // Not forwarded through AppState: the recorder's state, the processing job's progress, and
            // the multipoint recorders.
            state.recorder.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            state.processingActivity.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            state.sources.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            // Every session's own changes: battery, connection, recording, imports.
            state.devices.$sessions
                .map { sessions in Publishers.MergeMany(sessions.map { $0.objectWillChange.map { _ in () } }).eraseToAnyPublisher() }
                .switchToLatest()
                .eraseToAnyPublisher()
        ]
        Publishers.MergeMany(rare)
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.revision &+= 1 }
            .store(in: &subscriptions)
    }
}

extension FloatingStatusInputs {
    /// Gathers the panel's facts. `meeting` is the conversation the panel shows; `afterStop` says
    /// the panel watched it record and stop.
    @MainActor
    static func make(_ state: AppState, meeting: Meeting?, afterStop: Bool, inputDevice: String?) -> FloatingStatusInputs {
        var inputs = FloatingStatusInputs()
        let levels = state.recorder.levels
        let isRecording = meeting.map { state.recordingID == $0.id } ?? false
        if isRecording {
            inputs.phase = state.isStoppingRecording ? .saving : .recording
        } else if state.isStartingRecording {
            inputs.phase = .starting
        } else if afterStop, let meeting {
            inputs.phase = meeting.status == .failed && meeting.tracks.isEmpty ? .stopped : .saved
        }
        inputs.duration = meeting?.duration
        inputs.inputDevice = inputDevice
        inputs.microphoneSilent = isRecording && levels.isMicrophoneSilent
        if isRecording, state.includeComputerAudio {
            if levels.isCapturingCall {
                inputs.call = levels.isCallAudioDetected ? .detected : .quiet
            } else if state.recorder.isRecording, state.recorder.elapsedTime > 5 {
                inputs.call = .missing
            }
        }
        let links = isRecording ? (meeting?.companions ?? []).filter { $0.macEndedAt == nil } : []
        for session in state.devices.sessions where session.direct != nil {
            if session.kind.id == DaybookPhoneIntegration.id {
                inputs.phones.append(phone(session, state: state, links: links))
            } else {
                inputs.recorders.append(recorder(session, state: state, links: links))
            }
        }
        // A recording that failed has nothing to process; the panel says what happened instead.
        if let meeting, !isRecording, inputs.phase != .stopped { inputs.work = work(for: meeting, state: state) }
        inputs.queue = queue(state)
        inputs.syncProblem = syncProblem(state.sync.status)
        #if DEBUG
        FloatingNotesDemo.adjust(&inputs, meeting: meeting)
        #endif
        return inputs
    }

    @MainActor
    private static func recorder(_ session: DeviceSession, state: AppState, links: [CompanionRecording]) -> Recorder {
        var recorder = Recorder(id: session.id, name: session.device.name, shortName: session.kind.shortName,
                                symbol: session.kind.systemImage, state: session.state)
        recorder.isLinked = session.isLinked
        recorder.battery = session.status?.battery?.level
        recorder.charging = session.status?.battery?.charging == true
        recorder.isRecording = session.isLinked && session.status?.isRecording == true
        recorder.along = links.last { $0.deviceID == session.id }?.state
        recorder.managedBy = session.managedElsewhere?.ownerName
        recorder.managedByPhone = session.managedElsewhere?.ownerClass == .phone
        recorder.handoff = state.recorderHandoff.state(of: session)
        recorder.handoffLine = state.handoffLine(for: session)
        recorder.problem = session.problem?.title
        recorder.newCount = session.managedElsewhere == nil ? session.newRecordings.count : 0
        if session.queue.isActive {
            recorder.importing = Importing(position: session.queue.position, total: session.queue.total, fraction: session.importProgress,
                                           suspended: session.queue.isSuspended)
        }
        recorder.lastConnected = session.direct?.lastConnectedAt ?? session.primary?.lastConnectedAt
        return recorder
    }

    @MainActor
    private static func phone(_ session: DeviceSession, state: AppState, links: [CompanionRecording]) -> Phone {
        var phone = Phone(id: session.id, name: session.device.name)
        phone.isConnected = session.isLinked
        if let id = UUID(uuidString: session.id), let recording = state.phoneLink.recordingStates[id], phone.isConnected {
            switch recording.phase {
            case .recording, .starting: phone.activity = .recording
            case .paused: phone.activity = .paused
            default: phone.activity = .idle
            }
        }
        phone.along = links.last { $0.deviceID == session.id }?.state
        phone.lastConnected = session.direct?.lastConnectedAt
        return phone
    }

    @MainActor
    static func work(for meeting: Meeting, state: AppState) -> Work? {
        switch state.processingStatus(for: meeting) {
        case .processing(let progress):
            if let device = progress.device {
                let verb = progress.stage == .summarizing ? "Summarizing" : progress.stage == .identifyingSpeakers ? "Identifying speakers" : "Transcribing"
                return .elsewhere(device: device.name, verb: verb, fraction: progress.fraction)
            }
            switch progress.stage {
            case .transcribing: return .transcribing(progress.fraction)
            case .identifyingSpeakers: return .identifyingSpeakers
            case .summarizing: return .summarizing
            }
        case .requested(.queued): return .waiting
        case .requested(.models): return .models
        case .requested(.paused): return .paused
        case .requested(.device(let request)): return .requested(device: request.requestedBy.name)
        case .failed(let failure): return .failed(FriendlyError.message(for: failure.reason))
        case .recorded: return nil
        case .awaitingRecordings(let recordings): return .awaiting(ProcessingStatus.awaitingLine(recordings))
        case .done:
            if meeting.summary != nil { return .ready(summary: true) }
            return meeting.unifiedTranscript.isEmpty ? nil : .ready(summary: false)
        }
    }

    @MainActor
    private static func queue(_ state: AppState) -> Queue {
        var queue = Queue()
        if let id = state.processingID, let meeting = state.meetings.first(where: { $0.id == id }) {
            let message = state.processingProgress.message.lowercased()
            queue.running = meeting.status == .summarizing ? .summarizing
                : message.contains("speaker") || message.contains("sortformer") ? .identifyingSpeakers : .transcribing
            queue.fraction = state.processingProgress.fraction
        }
        queue.waiting = state.processingQueue.count
        queue.awaitingModels = state.awaitingModels.count
        return queue
    }

    /// A paused or failed sync, in the words Settings › Library uses. The system's own words stay in Settings, behind
    /// Details: here a reason is given only when it's one of Daybook's.
    static func syncProblem(_ status: String) -> String? {
        guard status.hasPrefix("Sync paused") || status.hasPrefix("Couldn") || status.hasPrefix("Reconnect")
                || status.hasPrefix("Apple Account") else { return nil }
        guard let colon = status.range(of: ": ") else { return status }
        let reason = String(status[colon.upperBound...])
        if status.hasPrefix("Sync paused") {
            return ownReasons.contains(reason) ? "iCloud sync is paused: " + reason : "iCloud sync is paused."
        }
        return String(status[..<colon.lowerBound]) + "."
    }

    /// Reasons the sync controller gives in its own words.
    private static let ownReasons: Set<String> = ["the iCloud account changed", "choose the folder this Mac synced through again",
                                                  "the folder this Mac synced through can’t be found"]
}

// MARK: - The input device

/// The default input device's name ("MacBook Pro Microphone"), kept current. Reading a device's
/// name needs no permission and never touches the microphone.
@MainActor
final class InputDeviceName: ObservableObject {
    @Published private(set) var name: String?
    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        refresh()
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listener = block
        }
    }

    func stop() {
        guard let listener else { return }
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        self.listener = nil
    }

    private func refresh() {
        let device: AudioObjectID? = CoreAudioProperty.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        let value = device.flatMap { $0 == kAudioObjectUnknown ? nil : CoreAudioProperty.string($0, kAudioObjectPropertyName) }
        if value != name { name = value }
    }
}

// MARK: - Levels

/// The two rolling meters' trails, sampled from the recorder's level monitor fifteen times a second
/// while recording. Only the meters read the trails, so nothing else redraws as levels arrive.
@MainActor
final class PanelLevels {
    let you = LevelTrail(capacity: 160)
    let call = LevelTrail(capacity: 160)
    private var timer: Timer?
    private weak var monitor: CaptureLevelMonitor?
    private var synthetic = false
    private var tick = 0

    var isRunning: Bool { timer != nil }

    /// Starts sampling `monitor`, or stops when `running` is false (the meters fall flat).
    func run(_ running: Bool, monitor: CaptureLevelMonitor, synthetic: Bool = false) {
        guard running else {
            timer?.invalidate()
            timer = nil
            you.reset()
            call.reset()
            return
        }
        guard timer == nil else { return }
        self.monitor = monitor
        self.synthetic = synthetic
        if synthetic {
            // A simulated recording has no audio: draw a plausible conversation, already under way.
            for _ in 0..<you.capacity { sample() }
        }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        tick &+= 1
        if synthetic {
            let t = Double(tick) / 15
            you.append(Self.speech(t, phase: 0))
            call.append(Self.speech(t, phase: 2.1))
            return
        }
        guard let monitor else { return }
        you.append(Double(monitor.microphone.meterValue))
        call.append(monitor.isCapturingCall ? Double(monitor.call.meterValue) : 0)
    }

    /// Syllables in phrases, taking turns: a deterministic stand-in for speech.
    private static func speech(_ t: Double, phase: Double) -> Double {
        let turn = sin((t + phase) * 0.45) > -0.2 ? 1.0 : 0.15
        let phrase = sin((t + phase) * 1.3) > -0.55 ? 1.0 : 0.1
        let syllable = abs(sin((t + phase) * 7.7)) * (0.6 + 0.4 * abs(sin((t + phase) * 2.9 + 0.7)))
        return min(1, 0.06 + turn * phrase * (0.25 + 0.7 * syllable))
    }

    deinit { timer?.invalidate() }
}
