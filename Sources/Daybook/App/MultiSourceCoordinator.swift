import Combine
import DaybookCore
import DaybookDevices
import DaybookIntelligence
import DaybookKit
import DaybookLink
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
    /// Recordings recovered at launch whose links are closed once devices are available.
    var recovered: [(meetingID: UUID, startedAt: Date, endedAt: Date)] = []

    static let matchesImportedFilesKey = "matchesImportedFilesToConversations"
    /// Stops owed to devices that answer, kept across relaunches (never synced).
    static let owedStopsKey = "multipoint.owedStops"
    private let defaults: UserDefaults
    private var subscription: AnyCancellable?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        matchesImportedFiles = defaults.bool(forKey: Self.matchesImportedFilesKey)
        recorders = CompanionRecorders(owed: OwedStopsStore(defaults: defaults, key: Self.owedStopsKey))
        subscription = recorders.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
}

/// Record control that answers each command, as Daybook on iPhone does over the local link, rather
/// than reporting only through its status as a recorder does. Multipoint uses the answer directly:
/// the phone's recording ID and start, its clock, or its reason for not recording.
@MainActor
protocol AnsweringRecordControl: RecordControlConnection {
    /// Asks it to record a conversation too. Asking again with the same `requestID` is safe: it
    /// answers a repeat with its first answer.
    func requestStart(_ start: CompanionStart) async -> CompanionAnswer
    /// Asks it to stop recording a conversation; with `recorder`, to stop that recorder it manages.
    func requestStop(conversationID: UUID, macEndedAt: Date?, recorder: LinkRecorderTarget?) async -> CompanionAnswer
    /// The conversation it says it's recording (or paused in), when it says.
    var recordingConversationID: UUID? { get }
    /// Its clock against this Mac's, as measured now.
    var clock: CompanionClock? { get }
}

/// What a device that answers is asked to record: the conversation as this Mac has it, so a device
/// that hasn't synced it yet makes the same record, and when this Mac's recording started.
struct CompanionStart: Equatable {
    var requestID = UUID()
    var conversationID: UUID
    var title: String?
    var date: Date?
    var macStartedAt: Date?
    /// When the conversation's timeline zero happened, on this Mac's clock: this Mac's start for a new
    /// conversation, earlier for one recorded into again; nil when that isn't known.
    var timelineStart: Date?
    /// A conversation of the device's own (the device page's Start Recording), not one alongside this Mac.
    var standalone = false
    /// A recorder the device manages, to start rather than the device itself.
    var recorder: LinkRecorderTarget?
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
        /// How long a device that answers (Daybook on iPhone) is asked again when its answer doesn't come.
        var answer: Duration = .seconds(45)
        /// How long to wait for a recorder's list, read on a new connection, before deciding from it.
        var inventory: Duration = .seconds(5)
    }

    /// One line for the recording surfaces: "Also recording on Soundcore Work."
    @Published private(set) var status: String?
    /// The devices to consider: the hub's sessions in the app.
    var sessions: () -> [DeviceSession] = { [] }
    /// A conversation's links, and a way to change them.
    var links: (UUID) -> [CompanionRecording] = { _ in [] }
    /// A conversation as devices that answer are told about it when asked to record it.
    var conversation: (UUID) -> CompanionConversation? = { _ in nil }
    /// The connected device managing a recorder another device owns, when it starts and stops its
    /// recorders when asked (Daybook on iPhone): multipoint goes through it.
    var owner: (RecorderOwnership) -> (session: DeviceSession, control: any AnsweringRecordControl)? = { _ in nil }
    var write: (UUID, (inout [CompanionRecording]) -> Void) -> Void = { _, _ in }
    var timing = Timing()

    /// A stop that didn't reach a device that answers: sent again when it reconnects, even after a
    /// relaunch. With `recorder`, a stop of a recorder that device manages.
    struct PendingStop: OwedStop {
        /// The device that answers (its session).
        var sessionID: String
        var meetingID: UUID
        var linkID: UUID
        var end: Date
        var recorder: LinkRecorderTarget?
        var owedAt: Date
    }

    private var starting: [UUID: Task<Void, Never>] = [:]
    private var stopping: [UUID: Task<Void, Never>] = [:]
    private var stopRequested: Set<UUID> = []
    /// Links to devices that answer whose start never got an answer: they may be recording.
    private var unanswered: Set<UUID> = []
    /// Stops that didn't reach a device that answers, by device: sent again when it reconnects. Kept in
    /// `owed` too, so a relaunch still sends them, except a stop of a recorder that doesn't name the
    /// recording (it would pause whatever the recorder records by then): that one lasts until Daybook quits.
    private(set) var pendingStops: [String: [PendingStop]] = [:] {
        didSet {
            guard pendingStops != oldValue else { return }
            owed?.save(pendingStops.values.flatMap { $0 }.filter { $0.recorder.map { $0.recordingID != nil } ?? true })
        }
    }
    private let owed: OwedStopsStore<PendingStop>?
    /// When each Mac recording in progress started, so only its own links are stopped.
    private var recordingSince: [UUID: Date] = [:]

    /// `owed` keeps stops for devices that answer across relaunches; those still owed are loaded now.
    init(owed: OwedStopsStore<PendingStop>? = nil) {
        self.owed = owed
        pendingStops = Dictionary(grouping: owed?.load() ?? [], by: \.sessionID)
    }

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
                // The clock prior its recording is placed by: the latest the link measured (the burst
                // after connecting may not have finished when it was asked to record).
                if let fresh = (control as? any AnsweringRecordControl)?.clock, fresh.measuredAt > (link.clock?.measuredAt ?? .distantPast) {
                    self.update(meetingID, link.id) { $0.clock = fresh }
                }
                switch link.state {
                case .recording:
                    if let answering = control as? any AnsweringRecordControl {
                        await self.stop(session, answering, link: link, meetingID: meetingID, at: end)
                    } else {
                        await self.stop(session, control, link: link, meetingID: meetingID)
                    }
                case .failed:
                    if let answering = control as? any AnsweringRecordControl {
                        // It never answered, or says it's recording this conversation after all: stop it.
                        guard self.unanswered.contains(link.id) || answering.recordingConversationID == meetingID else { continue }
                        await self.stop(session, answering, link: link, meetingID: meetingID, at: end)
                        continue
                    }
                    // Only what it says live counts: a recorder not connected reports its last-known state.
                    guard control.state.isConnected, control.status?.isRecording == true,
                          (control.status?.recordingStartedAt).map({ $0 >= link.macStartedAt.addingTimeInterval(-5) }) == true else { continue }
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

    /// The same, waiting at most `limit` (quitting, going to sleep): what can't reach a device by then won't.
    func settle(within limit: Duration) async {
        let done = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { await self.settle(); if done.set() { continuation.resume() } }
            Task { try? await Task.sleep(for: limit); if done.set() { continuation.resume() } }
        }
    }

    /// After a crash, once devices are available: a recovered recording's links are closed as its
    /// stop would have closed them. One still starting is unknown, so a device that answers is asked to
    /// stop (it says when it wasn't recording) and a recorder only if it is recording live since
    /// Daybook's command; one Daybook didn't start is left running.
    func recordingRecovered(_ meetingID: UUID, startedAt: Date, endedAt: Date) {
        let since = startedAt.addingTimeInterval(-5)
        let open = links(meetingID).filter { $0.macStartedAt >= since && $0.macEndedAt == nil }
        guard !open.isEmpty, recordingSince[meetingID] == nil else { return }
        for link in open where link.state == .starting {
            update(meetingID, link.id) { $0.state = .failed }
            if sessions().first(where: { $0.id == link.deviceID })?.direct is any AnsweringRecordControl { unanswered.insert(link.id) }
        }
        recordingSince[meetingID] = since
        macRecordingStopped(meetingID, at: endedAt)
    }

    /// A device that answers connected again: stops that didn't reach it go now.
    func reconnected(_ sessionID: String) {
        guard let owed = pendingStops[sessionID], !owed.isEmpty,
              let session = sessions().first(where: { $0.id == sessionID }),
              let control = session.direct as? any AnsweringRecordControl else { return }
        let previous = stopping[owed[0].meetingID]
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            for stop in owed {
                // Each stays owed (and kept) until it's sent: one a stop owes again goes back.
                guard self.pendingStops[sessionID]?.contains(where: { $0.linkID == stop.linkID }) == true else { continue }
                self.pendingStops[sessionID]?.removeAll { $0.linkID == stop.linkID }
                if self.pendingStops[sessionID]?.isEmpty == true { self.pendingStops[sessionID] = nil }
                guard let link = self.links(stop.meetingID).first(where: { $0.id == stop.linkID }), link.state != .attached else { continue }
                if let recorder = stop.recorder {
                    await self.stop(link, through: (session, control), recorder: recorder, meetingID: stop.meetingID, at: stop.end)
                } else {
                    await self.stop(session, control, link: link, meetingID: stop.meetingID, at: stop.end)
                }
            }
        }
        stopping[owed[0].meetingID] = task
        Task { [weak self] in
            await task.value
            if self?.stopping[owed[0].meetingID] == task { self?.stopping[owed[0].meetingID] = nil }
        }
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
            // Another device manages the recorder over Bluetooth; this Mac doesn't reach for it, but asks
            // that device to start it when it can (a connected iPhone), so one device drives it.
            if let through = self.owner(owner) {
                await self.start(link, of: session, through: through, meetingID: meetingID, at: start)
                return
            }
            update(meetingID, link.id) { $0.state = .unavailable }
            status = "\(name) is managed by \(owner.ownerName). Recording on this Mac only."
            return
        }
        status = "Connecting to \(name)…"
        let asked = Date(), wasConnected = control.state.isConnected
        guard await connected(control), !stopRequested.contains(meetingID) else {
            update(meetingID, link.id) { $0.state = .unavailable }
            status = stopRequested.contains(meetingID) ? nil : "\(name) isn’t nearby. Recording on this Mac only."
            return
        }
        // Whether it's recording already, and what, comes with its list, after the connection: decide
        // nothing before (bounded).
        if !wasConnected { _ = await wait(timing.inventory) { Self.hasCurrentListing(control, since: asked) } }
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
        if let owner = session.managedElsewhere {
            // Another device manages it now (handed over while it recorded, or it always did): stop it there.
            let recorder = LinkRecorderTarget(kind: session.kind.id, serial: link.deviceSerial ?? session.recorderSerial, recordingID: link.recordingID)
            if let through = self.owner(owner) {
                await stop(link, through: through, recorder: recorder, meetingID: meetingID, at: link.macEndedAt ?? Date())
            } else {
                update(meetingID, link.id) { $0.state = .stopFailed }
                status = "Couldn’t reach \(name) to stop it. Stop it on \(owner.ownerName)."
            }
            return
        }
        update(meetingID, link.id) { $0.state = .stopping }
        status = "Stopping \(name)…"
        let asked = Date()
        guard await connected(control) else {
            update(meetingID, link.id) { $0.state = .stopFailed }
            status = "Couldn’t reach \(name) to stop it. Stop it on the recorder."
            return
        }
        // Pause only the recording Daybook started: since then the person may have stopped it and
        // started another. Its list says which, once read on this connection (bounded).
        control.refresh()
        let current = await wait(timing.inventory) { Self.hasCurrentListing(control, since: asked) }
        if control.status?.isRecording == true, Self.isRecording(link, control, listingIsCurrent: current) {
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
        let answer = await ask(control, toStart: companionStart(meetingID, at: start), meetingID: meetingID)
        if answer == .noAnswer { unanswered.insert(link.id) }
        switch answer {
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

    /// The start a device that answers is asked for: the conversation as this Mac has it, and its timing.
    private func companionStart(_ meetingID: UUID, at start: Date, recorder: LinkRecorderTarget? = nil) -> CompanionStart {
        let conversation = self.conversation(meetingID)
        return CompanionStart(conversationID: meetingID, title: conversation?.title, date: conversation?.date,
                              macStartedAt: start, timelineStart: conversation?.timelineStart, recorder: recorder)
    }

    /// Asks it to start; without an answer yet (a microphone prompt, a reconnect), asks again with the
    /// same request, which it answers once, until this Mac stops or `timing.answer` passes.
    private func ask(_ control: any AnsweringRecordControl, toStart request: CompanionStart, meetingID: UUID) async -> CompanionAnswer {
        var answer = await control.requestStart(request)
        let deadline = ContinuousClock.now.advanced(by: timing.answer)
        while answer == .noAnswer, !stopRequested.contains(meetingID), ContinuousClock.now < deadline {
            guard (try? await Task.sleep(for: timing.poll)) != nil else { break }
            guard control.state.isConnected else { continue }
            answer = await control.requestStart(request)
        }
        return answer
    }

    // MARK: Recorders another device manages

    /// Asks the device managing a recorder (a connected iPhone) to start it along with this Mac. Its
    /// recording joins this conversation by its ID, however it arrives.
    private func start(_ link: CompanionRecording, of session: DeviceSession, through owner: (session: DeviceSession, control: any AnsweringRecordControl),
                       meetingID: UUID, at start: Date) async {
        let name = session.device.name, ownerName = owner.session.device.name
        status = "Asking \(ownerName) to start \(name)…"
        let recorder = LinkRecorderTarget(kind: session.kind.id, serial: link.deviceSerial ?? session.recorderSerial)
        let answer = await ask(owner.control, toStart: companionStart(meetingID, at: start, recorder: recorder), meetingID: meetingID)
        switch answer {
        case .recording(let recordingID, let startedAt, let already, _):
            // Its start is by the recorder's own clock, which the link to the phone doesn't measure.
            update(meetingID, link.id) {
                $0.state = already ? .alreadyRecording : .recording
                $0.startedByDaybook = !already
                $0.recorderStartedAt = startedAt
                $0.recordingID = recordingID
            }
            status = already ? "\(name) was already recording. Its recording will be added here." : "Also recording on \(name)."
            if stopRequested.contains(meetingID), !already, let current = links(meetingID).first(where: { $0.id == link.id }) {
                var target = recorder
                target.recordingID = recordingID
                await stop(current, through: owner, recorder: target, meetingID: meetingID, at: Date())
            }
        case .refused(let reason):
            update(meetingID, link.id) { $0.state = .failed }
            status = "\(name) didn’t record. \(reason) Recording on this Mac only."
        case .unavailable:
            update(meetingID, link.id) { $0.state = .unavailable }
            status = "\(name) is managed by \(ownerName). Recording on this Mac only."
        case .noAnswer, .stopped:
            update(meetingID, link.id) { $0.state = .failed }
            status = "\(ownerName) didn’t answer. Recording on this Mac only."
        }
    }

    /// Asks the device managing a recorder to stop the recording this Mac's link names; one it's
    /// recording since is left alone. Owed until that device reconnects when it can't be reached.
    private func stop(_ link: CompanionRecording, through owner: (session: DeviceSession, control: any AnsweringRecordControl),
                      recorder: LinkRecorderTarget, meetingID: UUID, at end: Date) async {
        let name = link.deviceName, ownerName = owner.session.device.name
        update(meetingID, link.id) { $0.state = .stopping }
        status = "Stopping \(name)…"
        switch await owner.control.requestStop(conversationID: meetingID, macEndedAt: end, recorder: recorder) {
        case .stopped, .recording:
            update(meetingID, link.id) { $0.state = .stopped }
            status = "\(name) stopped. Its recording will be added here."
        case .refused:
            update(meetingID, link.id) { $0.state = .stopFailed }
            status = "\(name) didn’t stop. Stop it on \(ownerName)."
        case .unavailable, .noAnswer:
            update(meetingID, link.id) { $0.state = .stopFailed }
            owe(PendingStop(sessionID: owner.session.id, meetingID: meetingID, linkID: link.id, end: end, recorder: recorder, owedAt: Date()))
            status = "Couldn’t reach \(ownerName) to stop \(name). It stops when it reconnects."
        }
    }

    private func stop(_ session: DeviceSession, _ control: any AnsweringRecordControl, link: CompanionRecording, meetingID: UUID, at end: Date) async {
        let name = link.deviceName
        update(meetingID, link.id) { $0.state = .stopping }
        status = "Stopping \(name)…"
        switch await control.requestStop(conversationID: meetingID, macEndedAt: end, recorder: nil) {
        case .stopped, .recording:
            unanswered.remove(link.id)
            update(meetingID, link.id) { $0.state = .stopped }
            status = "\(name) stopped. Its recording will be added here."
        case .refused:
            update(meetingID, link.id) { $0.state = .stopFailed }
            status = "\(name) didn’t stop. Stop it on the iPhone."
        case .unavailable, .noAnswer:
            // Owed until it reconnects (it connects to this Mac, never the reverse).
            update(meetingID, link.id) { $0.state = .stopFailed }
            owe(PendingStop(sessionID: session.id, meetingID: meetingID, linkID: link.id, end: end, recorder: nil, owedAt: Date()))
            status = "Couldn’t reach \(name) to stop it. It stops when it reconnects."
        }
    }

    /// Owes a stop until its device reconnects; one owed again for the same link keeps when it was first owed.
    func owe(_ stop: PendingStop) {
        var stop = stop
        var owed = pendingStops[stop.sessionID] ?? []
        if let earlier = owed.first(where: { $0.linkID == stop.linkID }) { stop.owedAt = min(stop.owedAt, earlier.owedAt) }
        owed.removeAll { $0.linkID == stop.linkID }
        owed.append(stop)
        pendingStops[stop.sessionID] = owed
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

    /// Whether the recorder's list was read on this connection and after `since`, so what it says is in
    /// progress is so now.
    static func hasCurrentListing(_ control: any DeviceConnection, since: Date) -> Bool {
        control.isInventoryCurrent && (control.inventoryUpdatedAt.map { $0 >= since } ?? false)
    }

    /// Whether what the recorder is recording now is the link's recording: by its ID in a current
    /// list, else by its start; with nothing to compare, as before (it is).
    static func isRecording(_ link: CompanionRecording, _ control: any DeviceConnection, listingIsCurrent: Bool) -> Bool {
        if listingIsCurrent, let id = link.recordingID { return inProgressID(control) == id }
        if let started = control.status?.recordingStartedAt, let ours = link.recorderStartedAt {
            return abs(started.timeIntervalSince(ours)) <= 5
        }
        return link.recordingID.map { id in inProgressID(control).map { $0 == id } ?? true } ?? true
    }

    private static func serial(_ session: DeviceSession, _ control: any DeviceConnection) -> String? {
        control.status?.serial ?? session.status?.serial ?? (control as? SoundcoreConnection)?.remembered?.serial
    }
}

/// Set once, from any task.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// True the first time only.
    func set() -> Bool { lock.withLock { defer { isSet = true }; return !isSet } }
}
