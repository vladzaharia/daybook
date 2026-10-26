import Combine
import DaybookCore
import DaybookDevices
import DaybookIntelligence
import DaybookKit
import Foundation

/// Lines up one recording against another from their sound: `AudioAligner.align` in the app,
/// a stub in tests. Runs off the main actor.
typealias AudioAlignmentFunction = @Sendable (_ other: URL, _ reference: URL, _ expectedOffset: TimeInterval?,
                                              _ searchRadius: TimeInterval) throws -> AudioAlignment?

/// The state behind multipoint recording and post-hoc sources: the recorders that record alongside
/// this Mac, how arriving recordings are matched, and what a recording moving between
/// conversations carries with it. The decisions themselves live in `SourceMatcher` and
/// `SourceFusion`; `AppState+Sources` connects them to the library and the processing queue.
@MainActor
final class MultiSourceCoordinator: ObservableObject {
    /// What a conversation held when this Mac started recording into it.
    struct CaptureContext: Equatable {
        var preexistingTrackIDs: Set<UUID>
        var date: Date
        var noteIDs: Set<UUID>
        var highlightIDs: Set<UUID>
        /// Photos already there; ones taken while this Mac records follow its recording.
        var photoIDs: Set<UUID> = []
        /// A phone started the conversation and asked this Mac to record: it keeps the phone's date.
        var keepsDate = false
    }

    /// A recording moving into another conversation keeps its transcript, speakers, and placement,
    /// so it isn't transcribed twice.
    struct Carried {
        var transcript: TrackTranscript?
        var speakers: [Speaker]
        /// In the recording's own time.
        var highlights: [Highlight]
        var placement: SourceAlignment?
        var clockOffset: TimeInterval?
        var startedAt: Date?
    }

    let recorders: CompanionRecorders
    var policy = SourceMatcher.Policy()
    var alignAudio: AudioAlignmentFunction = { other, reference, expected, radius in
        try AudioAligner.align(other: other, reference: reference, expectedOffset: expected, searchRadius: radius)
    }
    /// Replaces the local runtime for processing (tests).
    var inference: (any MeetingInference)?
    /// Files imported by hand join a conversation they overlap, like recorder recordings do.
    @Published var matchesImportedFiles: Bool {
        didSet { defaults.set(matchesImportedFiles, forKey: Self.matchesImportedFilesKey) }
    }
    var captures: [UUID: CaptureContext] = [:]
    /// By the recording's SHA-256.
    var carried: [String: Carried] = [:]

    static let matchesImportedFilesKey = "matchesImportedFilesToConversations"
    private let defaults: UserDefaults
    private var subscription: AnyCancellable?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        matchesImportedFiles = defaults.bool(forKey: Self.matchesImportedFilesKey)
        recorders = CompanionRecorders()
        subscription = recorders.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
}

/// Record control that answers each command, as Daybook on iPhone does over the local link, rather
/// than reporting only through its status as a recorder does. Multipoint uses the answer directly:
/// the phone's recording ID and start, its clock, or its reason for not recording.
@MainActor
protocol AnsweringRecordControl: RecordControlConnection {
    /// Asks it to record a conversation too.
    func requestStart(_ start: CompanionStart) async -> CompanionAnswer
    func requestStop(conversationID: UUID, macEndedAt: Date?) async -> CompanionAnswer
}

/// What a device that answers is asked to record: the conversation as this Mac has it, so a device
/// that hasn't synced it yet makes the same record, and when this Mac's recording started.
struct CompanionStart: Equatable {
    var conversationID: UUID
    var title: String?
    var date: Date?
    var macStartedAt: Date?
    /// When the conversation's timeline zero happened, on this Mac's clock: this Mac's start for a new
    /// conversation, earlier for one recorded into again; nil when that isn't known.
    var timelineStart: Date?
}

/// A conversation as a device that answers is told about it when asked to record.
struct CompanionConversation: Equatable {
    var title: String
    var date: Date
    var timelineStart: Date?
}

/// What a device with `AnsweringRecordControl` said.
enum CompanionAnswer: Equatable {
    /// Recording: its ID for the recording and its start, on its own clock, and that clock against this Mac's.
    case recording(recordingID: String?, startedAt: Date?, alreadyRecording: Bool, clock: CompanionClock?)
    case stopped(at: Date?)
    /// It said no, and why, in a sentence.
    case refused(String)
    /// It isn't connected.
    case unavailable
    /// It didn't answer in time.
    case noAnswer
}

/// A recording this Mac started because a device asked it to (an iPhone leading multipoint). That
/// device is recording already, so it's linked as such rather than asked.
struct CompanionLead: Equatable {
    var sessionID: String
    var deviceKind: String
    var deviceName: String
    /// When its recording started, on its own clock.
    var startedAt: Date?
    var clock: CompanionClock?
}

/// Starts recorders with record control when this Mac starts recording, and stops them when it
/// stops. Each recorder's link is stored on the conversation (`CompanionRecording`), so its
/// recording joins that conversation whenever and however it arrives. Nothing here can affect the
/// Mac recording: it runs after the capture started, never throws, and reports one quiet line.
@MainActor
final class CompanionRecorders: ObservableObject {
    struct Timing {
        var connect: Duration = .seconds(20)
        /// A little longer than the recorder's own confirmation window.
        var confirm: Duration = .seconds(15)
        /// How long to wait for the finished recording to appear in the recorder's list.
        var listing: Duration = .seconds(20)
        var poll: Duration = .milliseconds(100)
    }

    /// One line for the recording surfaces: "Also recording on Soundcore Work."
    @Published private(set) var status: String?
    /// The devices to consider: the hub's sessions in the app.
    var sessions: () -> [DeviceSession] = { [] }
    /// A conversation's links, and a way to change them.
    var links: (UUID) -> [CompanionRecording] = { _ in [] }
    /// A conversation as devices that answer are told about it when asked to record it.
    var conversation: (UUID) -> CompanionConversation? = { _ in nil }
    var write: (UUID, (inout [CompanionRecording]) -> Void) -> Void = { _, _ in }
    var timing = Timing()

    private var starting: [UUID: Task<Void, Never>] = [:]
    private var stopping: [UUID: Task<Void, Never>] = [:]
    private var stopRequested: Set<UUID> = []
    /// When each Mac recording in progress started, so only its own links are stopped.
    private var recordingSince: [UUID: Date] = [:]

    /// Recorders that record alongside this Mac: record control, set up, its direct method on, and
    /// "Also record on <device>" on.
    func eligible() -> [(session: DeviceSession, control: any RecordControlConnection)] {
        sessions().compactMap { session in
            guard session.device.recordsAlongsideMac, session.device.isEnabled(.direct),
                  let control = session.direct as? any RecordControlConnection,
                  control.capabilities.contains(.recordControl), control.isSetUp else { return nil }
            return (session, control)
        }
    }

    /// This Mac started recording `meetingID` at `start`, on its own or because `lead` asked it to.
    func macRecordingStarted(_ meetingID: UUID, at start: Date, lead: CompanionLead? = nil) {
        if let lead {
            var link = CompanionRecording(deviceID: lead.sessionID, deviceKind: lead.deviceKind, deviceName: lead.deviceName,
                                          macStartedAt: start, state: .alreadyRecording, startedByDaybook: false)
            link.recorderStartedAt = lead.startedAt
            link.clock = lead.clock
            write(meetingID) { $0.append(link) }
        }
        let recorders = eligible().filter { $0.session.id != lead?.sessionID }
        guard !recorders.isEmpty else { status = lead.map { "Recording here because \($0.deviceName) asked." }; return }
        recordingSince[meetingID] = start
        stopRequested.remove(meetingID)
        starting[meetingID] = Task { [weak self] in
            guard let self else { return }
            let each = recorders.map { recorder in
                Task { await self.start(recorder.session, recorder.control, meetingID: meetingID, at: start) }
            }
            for task in each { await task.value }
        }
    }

    /// This Mac stopped recording `meetingID` at `end`. Recorders Daybook started are stopped once
    /// they finish starting; one that was already recording keeps going.
    func macRecordingStopped(_ meetingID: UUID, at end: Date) {
        stopRequested.insert(meetingID)
        let started = starting.removeValue(forKey: meetingID)
        // Links left by an earlier recording (one interrupted by a crash, say) are never acted on.
        guard let since = recordingSince.removeValue(forKey: meetingID) else { stopRequested.remove(meetingID); return }
        stopping[meetingID] = Task { [weak self] in
            await started?.value
            guard let self else { return }
            for link in self.links(meetingID) where link.macStartedAt >= since && link.macEndedAt == nil {
                self.update(meetingID, link.id) { $0.macEndedAt = end }
                guard let session = self.sessions().first(where: { $0.id == link.deviceID }),
                      let control = session.direct as? any RecordControlConnection else { continue }
                switch link.state {
                case .recording:
                    if let answering = control as? any AnsweringRecordControl {
                        await self.stop(session, answering, link: link, meetingID: meetingID, at: end)
                    } else {
                        await self.stop(session, control, link: link, meetingID: meetingID)
                    }
                case .failed where control is any AnsweringRecordControl:
                    continue
                case .failed where control.status?.isRecording == true
                        && (control.status?.recordingStartedAt).map({ $0 >= link.macStartedAt.addingTimeInterval(-5) }) == true:
                    // It started after all, from Daybook's command: stop it like one that confirmed.
                    self.update(meetingID, link.id) {
                        $0.state = .recording; $0.startedByDaybook = true
                        $0.recorderStartedAt = control.status?.recordingStartedAt
                        $0.recordingID = Self.inProgressID(control)
                    }
                    await self.stop(session, control, link: self.links(meetingID).first { $0.id == link.id } ?? link, meetingID: meetingID)
                case .alreadyRecording:
                    self.status = "\(link.deviceName) is still recording. Its recording will be added here."
                default:
                    continue
                }
            }
            self.stopRequested.remove(meetingID)
            self.stopping[meetingID] = nil
        }
    }

    /// Waits for every start and stop in flight (tests, and quitting).
    func settle() async {
        for task in Array(starting.values) + Array(stopping.values) { await task.value }
    }

    // MARK: Start and stop

    private func start(_ session: DeviceSession, _ control: any RecordControlConnection, meetingID: UUID, at start: Date) async {
        if let answering = control as? any AnsweringRecordControl {
            await self.start(session, answering, meetingID: meetingID, at: start)
            return
        }
        let name = session.device.name
        let link = CompanionRecording(deviceID: session.id, deviceKind: session.kind.id, deviceSerial: Self.serial(session, control),
                                      deviceName: name, macStartedAt: start)
        write(meetingID) { $0.append(link) }
        if let owner = session.managedElsewhere {
            // Another device manages the recorder over Bluetooth; this Mac doesn't reach for it.
            update(meetingID, link.id) { $0.state = .unavailable }
            status = "\(name) is managed by \(owner.ownerName). Recording on this Mac only."
            return
        }
        status = "Connecting to \(name)…"
        guard await connected(control), !stopRequested.contains(meetingID) else {
            update(meetingID, link.id) { $0.state = .unavailable }
            status = stopRequested.contains(meetingID) ? nil : "\(name) isn’t nearby. Recording on this Mac only."
            return
        }
        if control.status?.isRecording == true {
            update(meetingID, link.id) {
                $0.state = .alreadyRecording
                $0.recorderStartedAt = control.status?.recordingStartedAt
                $0.recordingID = Self.inProgressID(control)
                $0.deviceSerial = Self.serial(session, control) ?? $0.deviceSerial
            }
            status = "\(name) was already recording. Its recording will be added here."
            return
        }
        status = "Starting \(name)…"
        control.startRecording()
        let confirmed = await wait(timing.confirm) { control.status?.isRecording == true && !control.recordCommandPending }
        if confirmed {
            update(meetingID, link.id) {
                $0.state = .recording
                $0.startedByDaybook = true
                $0.recorderStartedAt = control.status?.recordingStartedAt ?? Date()
                $0.recordingID = Self.inProgressID(control)
                $0.deviceSerial = Self.serial(session, control) ?? $0.deviceSerial
            }
            status = "Also recording on \(name)."
        } else {
            update(meetingID, link.id) { $0.state = .failed }
            status = "\(name) didn’t start recording. Recording on this Mac only."
        }
    }

    private func stop(_ session: DeviceSession, _ control: any RecordControlConnection, link: CompanionRecording, meetingID: UUID) async {
        let name = link.deviceName
        update(meetingID, link.id) { $0.state = .stopping }
        status = "Stopping \(name)…"
        guard await connected(control) else {
            update(meetingID, link.id) { $0.state = .stopFailed }
            status = "Couldn’t reach \(name) to stop it. Stop it on the recorder."
            return
        }
        if control.status?.isRecording == true {
            control.pauseRecording()
            guard await wait(timing.confirm, until: { control.status?.isRecording == false && !control.recordCommandPending }) else {
                update(meetingID, link.id) { $0.state = .stopFailed }
                status = "\(name) didn’t confirm it stopped. Stop it on the recorder."
                return
            }
        }
        update(meetingID, link.id) { $0.state = .stopped }
        status = "\(name) stopped. Its recording will be added here."
        // Bring it in now rather than at the next automatic import. It appears in the recorder's
        // list once it's finished; the link attaches it however it ends up arriving.
        guard let recordingID = links(meetingID).first(where: { $0.id == link.id })?.recordingID else { return }
        let finished = { control.recordings.first { $0.id == recordingID && !$0.isInProgress } }
        guard await wait(timing.listing, until: { finished() != nil }), let recording = finished(),
              !session.queue.contains(recording.id), session.links.imported[recording.id] == nil else { return }
        session.importRecordings([recording], attachTo: meetingID, automatic: true)
    }

    // MARK: Devices that answer (Daybook on iPhone)

    /// Asks a device that answers to record too. It connects to this Mac on its own, so one that
    /// isn't connected now is unavailable. Its recording arrives through sync.
    private func start(_ session: DeviceSession, _ control: any AnsweringRecordControl, meetingID: UUID, at start: Date) async {
        let name = session.device.name
        let link = CompanionRecording(deviceID: session.id, deviceKind: session.kind.id, deviceName: name, macStartedAt: start)
        write(meetingID) { $0.append(link) }
        guard control.state.isConnected, !stopRequested.contains(meetingID) else {
            update(meetingID, link.id) { $0.state = .unavailable }
            status = stopRequested.contains(meetingID) ? nil : "\(name) isn’t connected. Recording on this Mac only."
            return
        }
        status = "Asking \(name) to record…"
        let conversation = self.conversation(meetingID)
        switch await control.requestStart(CompanionStart(conversationID: meetingID, title: conversation?.title, date: conversation?.date,
                                                         macStartedAt: start, timelineStart: conversation?.timelineStart)) {
        case .recording(let recordingID, let startedAt, let already, let clock):
            update(meetingID, link.id) {
                $0.state = already ? .alreadyRecording : .recording
                $0.startedByDaybook = !already
                $0.recorderStartedAt = startedAt
                $0.recordingID = recordingID
                $0.clock = clock
            }
            status = already ? "\(name) was already recording. Its recording will be added here." : "Also recording on \(name)."
            // This Mac stopped while the device was starting: stop it as well.
            if stopRequested.contains(meetingID), !already, let current = links(meetingID).first(where: { $0.id == link.id }) {
                await stop(session, control, link: current, meetingID: meetingID, at: Date())
            }
        case .refused(let reason):
            update(meetingID, link.id) { $0.state = .failed }
            status = "\(name) didn’t record. \(reason) Recording on this Mac only."
        case .unavailable:
            update(meetingID, link.id) { $0.state = .unavailable }
            status = "\(name) isn’t connected. Recording on this Mac only."
        case .noAnswer, .stopped:
            update(meetingID, link.id) { $0.state = .failed }
            status = "\(name) didn’t answer. Recording on this Mac only."
        }
    }

    private func stop(_ session: DeviceSession, _ control: any AnsweringRecordControl, link: CompanionRecording, meetingID: UUID, at end: Date) async {
        let name = link.deviceName
        update(meetingID, link.id) { $0.state = .stopping }
        status = "Stopping \(name)…"
        switch await control.requestStop(conversationID: meetingID, macEndedAt: end) {
        case .stopped, .recording:
            update(meetingID, link.id) { $0.state = .stopped }
            status = "\(name) stopped. Its recording will be added here."
        case .refused, .unavailable, .noAnswer:
            update(meetingID, link.id) { $0.state = .stopFailed }
            status = "Couldn’t reach \(name) to stop it. Stop it on the iPhone."
        }
    }

    /// Connects when needed. Gives up when the connection does (out of range, Bluetooth off) or
    /// after `timing.connect`.
    private func connected(_ control: any RecordControlConnection) async -> Bool {
        if control.state.isConnected { return true }
        guard control.isSetUp, control.state != .unavailable else { return false }
        if !control.state.isBusy { control.connect() }
        var tried = false
        return await wait(timing.connect) {
            if control.state.isBusy { tried = true }
            return control.state.isConnected || control.state == .unavailable || (tried && !control.state.isBusy)
        } && control.state.isConnected
    }

    private func wait(_ limit: Duration, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !condition() {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: timing.poll)) != nil else { return condition() }
        }
        return true
    }

    private func update(_ meetingID: UUID, _ linkID: UUID, _ change: @escaping (inout CompanionRecording) -> Void) {
        write(meetingID) { links in
            if let index = links.firstIndex(where: { $0.id == linkID }) { change(&links[index]) }
        }
    }

    /// The recorder's ID for the recording it's making now, from its list.
    static func inProgressID(_ control: any DeviceConnection) -> String? {
        control.recordings.first(where: \.isInProgress)?.id
    }

    private static func serial(_ session: DeviceSession, _ control: any DeviceConnection) -> String? {
        control.status?.serial ?? session.status?.serial ?? (control as? SoundcoreConnection)?.remembered?.serial
    }
}
