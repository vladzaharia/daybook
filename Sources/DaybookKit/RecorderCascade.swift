import Combine
import DaybookCore
import DaybookDevices
import DaybookLink
import Foundation

/// The recorders this device manages recording along with one of its conversations (a cascading
/// start, docs/multipoint.md): started with it, their audio saved into it as they record (the stream
/// Listen Live uses, `DeviceSession.captureLive`), and stopped with it, their own files imported into it
/// afterwards. One shared recording at a time, as a device records one conversation at a time.
///
/// Each recorder starts once per conversation, however many ways it's asked (this device's own start,
/// another device asking for it over the link, its button): a second ask waits for the first and gets
/// its answer. Nothing here can stop or delay the device's own recording; trouble is one quiet line.
@MainActor
public final class RecorderCascade: ObservableObject {
    public struct Timing: Sendable {
        public var connect: Duration = .seconds(20)
        public var confirm: Duration = .seconds(15)
        /// For its list, read on this connection, before deciding what it's recording.
        public var inventory: Duration = .seconds(5)
        public var poll: Duration = .milliseconds(100)
        public init() {}
    }

    /// Why a recorder records along, which decides whether it stops with the conversation.
    public enum Role: String, Equatable, Sendable {
        /// Daybook started it for this conversation.
        case started
        /// Its own button started this conversation.
        case led
        /// Its button started it while this conversation was being recorded.
        case joined
        /// It was recording already when the conversation began: it records along, and is left running.
        case alreadyRecording
    }

    public enum State: Equatable, Sendable {
        case starting
        case recording
        case stopping
        case stopped
        /// It couldn't be reached or didn't start, in words.
        case unavailable(String)
        /// It couldn't be stopped, in words.
        case stopFailed(String)
    }

    /// One recorder recording along.
    public struct Member: Equatable, Sendable, Identifiable {
        public var sessionID: String
        public var kind: String
        public var serial: String?
        public var name: String
        public var role: Role
        public var state: State
        /// The recorder's ID for the recording it makes for this conversation.
        public var recordingID: String?
        /// When that recording started, on this device's clock.
        public var startedAt: Date?
        public var id: String { sessionID }

        /// It records this conversation now.
        public var isRecording: Bool { state == .recording }
        /// It stops when the conversation does (only the recording it makes for it).
        public var stopsWithConversation: Bool { role != .alreadyRecording }
    }

    /// The shared recording the recorders record along with.
    public struct Conversation: Equatable, Sendable {
        public var id: UUID
        /// As the device leading it has it, for creating it here if it hasn't synced yet.
        public var title: String?
        public var date: Date?
        /// This device leads it (its own recording, or its recorder's, began it), rather than another device.
        public var ledHere = false
        public var members: [Member] = []
    }

    @Published public private(set) var conversation: Conversation?
    /// One line about the recorders, when there's something to say ("Also recording on Soundcore Work.").
    @Published public private(set) var status: String?
    /// The devices to consider: the hub's sessions.
    public var sessions: () -> [DeviceSession]
    public var timing = Timing()
    /// A recorder joined, started, or stopped (the app sends its recording state).
    public var onChange: (() -> Void)?

    /// Starts under way, by session: for which conversation, and the start every ask for it waits on.
    private var starting: [String: (conversation: UUID, task: Task<Member?, Never>)] = [:]
    /// Conversations ended recently, kept a little so a late start for one is refused rather than
    /// beginning it again (by ID, with when they ended).
    private var ended: [UUID: Date] = [:]

    public init(sessions: @escaping () -> [DeviceSession] = { [] }) {
        self.sessions = sessions
    }

    /// Recorders that record along with this device: record control, managed here, set up, the direct
    /// method on, and "record along" on (`ConfiguredDevice.recordsAlongsideMac`).
    public func eligible() -> [DeviceSession] {
        sessions().filter { session in
            guard session.device.recordsAlongsideMac, session.device.isEnabled(.direct), session.managedElsewhere == nil,
                  let control = session.direct as? any RecordControlConnection else { return false }
            return control.capabilities.contains(.recordControl) && control.isSetUp
        }
    }

    public func member(_ sessionID: String) -> Member? { conversation?.members.first { $0.sessionID == sessionID } }

    /// A conversation this device records along with, possibly not in its library yet: its title and
    /// date as the device leading it has them.
    public func pendingConversation(_ id: UUID) -> (title: String?, date: Date?, ledHere: Bool)? {
        guard let conversation, conversation.id == id else { return nil }
        return (conversation.title, conversation.date, conversation.ledHere)
    }

    // MARK: Starting

    /// Begins a shared recording (or carries on with the same one): its recorders are started with
    /// `startRecorders`, or one by one as they're asked for. A conversation that ended here isn't begun
    /// again (a late or repeated ask never restarts its recorders), nor one while another is under way
    /// (it's stopped first): false then.
    @discardableResult
    public func begin(_ id: UUID, title: String? = nil, date: Date? = nil, ledHere: Bool = false, now: Date = Date()) -> Bool {
        if conversation?.id == id {
            if let title, conversation?.title == nil { conversation?.title = title }
            if let date, conversation?.date == nil { conversation?.date = date }
            if ledHere { conversation?.ledHere = true }
            return true
        }
        ended = ended.filter { now.timeIntervalSince($0.value) < Self.endedMemory }
        guard ended[id] == nil, conversation == nil else { return false }
        conversation = Conversation(id: id, title: title, date: date, ledHere: ledHere)
        status = nil
        return true
    }

    /// How long a conversation that ended here is remembered as ended.
    static let endedMemory: TimeInterval = 12 * 3_600

    /// Starts every eligible recorder for the shared recording; `lead` is the one whose button began it.
    /// Returns when each has answered (bounded by `timing`).
    public func startRecorders(lead: String? = nil) async {
        guard let id = conversation?.id else { return }
        let tasks = eligible().map { session in
            Task { _ = await self.start(session, for: id, role: session.id == lead ? .led : nil) }
        }
        for task in tasks { await task.value }
    }

    /// Starts one recorder for the shared recording `id` (beginning it if none is under way), or answers
    /// with what it's doing already for it. `role` forces how it records along (its button led).
    @discardableResult
    public func start(_ session: DeviceSession, for id: UUID, role forced: Role? = nil) async -> Member? {
        if conversation == nil { begin(id) }
        guard conversation?.id == id else { return nil }
        if let existing = member(session.id), existing.state == .recording || existing.state == .stopping {
            // Asked again for one already recording along: the same answer.
            return existing
        }
        if let running = starting[session.id], running.conversation == id { return await running.task.value }
        let task = Task { await self.run(session, for: id, role: forced) }
        starting[session.id] = (id, task)
        let member = await task.value
        if starting[session.id]?.task == task { starting[session.id] = nil }
        return member
    }

    private func run(_ session: DeviceSession, for id: UUID, role forced: Role?) async -> Member? {
        guard let control = session.direct as? any RecordControlConnection else { return nil }
        let name = session.device.name
        var member = Member(sessionID: session.id, kind: session.kind.id, serial: session.recorderSerial, name: name,
                            role: forced ?? .started, state: .starting)
        put(member)
        let asked = Date(), wasConnected = control.state.isConnected
        guard await connected(control) else {
            member.state = .unavailable("\(name) isn’t nearby.")
            put(member)
            say("\(name) isn’t nearby. Its recording isn’t part of this one.")
            return member
        }
        // Whether it's recording already, and what, comes with its list after the connection.
        if !wasConnected { _ = await wait(timing.inventory) { Self.listed(control, since: asked) } }
        guard conversation?.id == id else { return nil }
        if control.status?.isRecording == true {
            member.role = forced ?? .alreadyRecording
            member.state = .recording
        } else {
            control.startRecording()
            guard await wait(timing.confirm, until: { control.status?.isRecording == true && !control.recordCommandPending }) else {
                member.state = .unavailable("\(name) didn’t start recording.")
                put(member)
                say("\(name) didn’t start recording.")
                return member
            }
            member.role = forced ?? .started
            member.state = .recording
        }
        member.recordingID = control.recordings.first(where: \.isInProgress)?.id
        member.startedAt = control.status?.recordingStartedAt
        member.serial = session.recorderSerial ?? member.serial
        guard conversation?.id == id else {
            // The conversation ended while it started: a recorder started for it stops again.
            if member.role == .started { await stopRecorder(member, session: session, conversation: id) }
            return nil
        }
        put(member)
        say("Also recording on \(name).")
        captureLive(session, member: member, into: id)
        return member
    }

    /// The recorder's button started a recording while this device records `id`: it records along, and
    /// stops with the conversation.
    public func join(_ session: DeviceSession, conversation id: UUID) {
        guard conversation?.id == id, let control = session.direct as? any RecordControlConnection else { return }
        var member = member(session.id) ?? Member(sessionID: session.id, kind: session.kind.id, serial: session.recorderSerial,
                                                  name: session.device.name, role: .joined, state: .recording)
        if member.state != .recording { member.role = .joined }
        member.state = .recording
        member.startedAt = control.status?.recordingStartedAt ?? member.startedAt ?? Date()
        put(member)
        say("Also recording on \(session.device.name).")
        // Its list names the new recording once it's read again (the button relists it).
        Task {
            _ = await wait(timing.inventory) { control.recordings.contains(where: \.isInProgress) && !control.isRefreshing }
            guard self.conversation?.id == id, var current = self.member(session.id) else { return }
            current.recordingID = control.recordings.first(where: \.isInProgress)?.id ?? current.recordingID
            self.put(current)
            self.captureLive(session, member: current, into: id)
        }
    }

    /// Saves the recorder's audio into the conversation as it records.
    private func captureLive(_ session: DeviceSession, member: Member, into id: UUID) {
        guard session.liveCaptureConversation != id else { return }
        session.captureLive(into: id)
    }

    // MARK: Stopping

    /// The shared recording ended: each recorder's live audio is saved into it, recorders that stop with
    /// it are paused (only the recording each made for it), and their files import into it once
    /// they're finished. Returns once each has answered. With `id`, only when that's the shared recording
    /// (a stop that comes late never ends the next one).
    public func stop(_ id: UUID? = nil) async {
        guard let current = conversation, id == nil || current.id == id else { return }
        let id = current.id
        ended[id] = Date()
        conversation = nil
        for running in starting.values where running.conversation == id { _ = await running.task.value }
        let all = sessions()
        for member in current.members {
            guard let session = all.first(where: { $0.id == member.sessionID }) else { continue }
            if member.isRecording { await stopRecorder(member, session: session, conversation: id) }
            else { await session.endLiveCapture() }
        }
        onChange?()
    }

    /// A recorder of the shared recording stopped on its own (its button): its live audio is saved, and
    /// its file imports into the conversation when finished. Returns whether it was recording along.
    @discardableResult
    public func recorderStopped(_ session: DeviceSession) async -> Bool {
        guard let current = conversation, var member = member(session.id), member.isRecording else { return false }
        member.state = .stopped
        put(member)
        await session.endLiveCapture()
        if let recordingID = member.recordingID { session.importWhenFinished(recordingID, into: current.id) }
        return true
    }

    /// Another device asks this one to stop a recorder it manages (`LinkRecordRequest.recorder`): its live
    /// audio is saved first, so its list can be read and the pause goes through.
    public func prepareToStop(_ session: DeviceSession) async {
        await session.endLiveCapture()
        if var member = member(session.id), member.isRecording {
            member.state = .stopping
            put(member)
        }
    }

    /// After another device's stop of a recorder this one manages went through.
    public func remoteStopped(_ session: DeviceSession, recordingID: String?) {
        guard var member = member(session.id) else { return }
        member.state = .stopped
        member.recordingID = member.recordingID ?? recordingID
        put(member)
    }

    private func stopRecorder(_ member: Member, session: DeviceSession, conversation id: UUID) async {
        var member = member
        member.state = .stopping
        put(member, in: id)
        await session.endLiveCapture()
        guard let control = session.direct as? any RecordControlConnection else { return }
        if member.stopsWithConversation, control.state.isConnected {
            let asked = Date()
            control.refresh()
            let listed = await wait(timing.inventory) { Self.listed(control, since: asked) }
            let inProgress = control.recordings.first(where: \.isInProgress)?.id
            // Pause only the recording it made for this conversation: the person may have started another.
            let same = member.recordingID == nil || (listed ? inProgress == member.recordingID : true)
            if control.status?.isRecording == true, same {
                control.pauseRecording()
                if !(await wait(timing.confirm, until: { control.status?.isRecording == false && !control.recordCommandPending })) {
                    member.state = .stopFailed("\(member.name) didn’t confirm it stopped. Stop it on the recorder.")
                    put(member, in: id)
                    say("\(member.name) didn’t confirm it stopped. Stop it on the recorder.")
                    return
                }
            }
        } else if member.stopsWithConversation {
            member.state = .stopFailed("Couldn’t reach \(member.name) to stop it. Stop it on the recorder.")
            put(member, in: id)
            say("Couldn’t reach \(member.name) to stop it. Stop it on the recorder.")
        }
        if case .stopFailed = member.state {} else { member.state = .stopped; put(member, in: id) }
        // Its own file, the authoritative copy, joins the conversation once it's finished and listed.
        if let recordingID = member.recordingID { session.importWhenFinished(recordingID, into: id) }
    }

    // MARK: What it says

    /// The shared recording a recorder records along with now, for `recording.state`.
    public func sharedConversation(of session: DeviceSession) -> UUID? {
        guard let conversation, let member = member(session.id), member.isRecording else { return nil }
        return conversation.id
    }

    /// Whether any recorder still records the shared recording along.
    public var hasRecordingMembers: Bool { conversation?.members.contains(where: \.isRecording) == true }

    // MARK: Plumbing

    private func put(_ member: Member, in id: UUID? = nil) {
        guard var current = conversation, id == nil || current.id == id else { return }
        if let index = current.members.firstIndex(where: { $0.sessionID == member.sessionID }) { current.members[index] = member }
        else { current.members.append(member) }
        if current != conversation { conversation = current }
        onChange?()
    }

    private func say(_ line: String) { status = line }

    private func connected(_ control: any RecordControlConnection) async -> Bool {
        if control.state.isConnected { return true }
        guard control.isSetUp, control.state != .unavailable else { return false }
        if !control.state.isBusy { control.connect() }
        return await wait(timing.connect) { control.state.isConnected || control.state == .unavailable } && control.state.isConnected
    }

    private func wait(_ limit: Duration, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !condition() {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: timing.poll)) != nil else { return condition() }
        }
        return true
    }

    private static func listed(_ control: any DeviceConnection, since: Date) -> Bool {
        !control.isRefreshing && control.isInventoryCurrent && (control.inventoryUpdatedAt.map { $0 >= since } ?? false)
    }
}
