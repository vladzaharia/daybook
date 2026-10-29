import Combine
import DaybookCore
import DaybookDevices
import DaybookLink
import Foundation

// Recorders over the local link: the device that manages a recorder says what it last knew of it in
// `recording.state`, and the other device shows it (docs/link.md, "Recording state").

extension LinkRecorderState {
    /// A recorder this device manages, from what its device session knows now: live while connected,
    /// otherwise what it last confirmed, with when. Nil for one another device manages, without record
    /// control, or that hasn't said.
    @MainActor
    public init?(session: DeviceSession, conversationID: UUID? = nil) {
        guard session.managedElsewhere == nil, let control = session.direct as? any RecordControlConnection, control is any ManagedConnection else { return nil }
        if let soundcore = session.direct as? SoundcoreConnection {
            // Its recording state: live while connected, then what it last confirmed (for a while), including a
            // recording paused with its file still open.
            guard let state = soundcore.recordingState else { return nil }
            let open = state.isRecording || state.activeRecordingID != nil
            self.init(kind: session.kind.id, serial: session.recorderSerial ?? control.status?.serial, name: session.device.name,
                      isRecording: state.isRecording, recordingID: open ? state.activeRecordingID.map { String($0) } : nil,
                      startedAt: open ? state.startedAt : nil, asOf: state.asOf, conversationID: conversationID)
            return
        }
        guard let status = control.status, let isRecording = status.isRecording else { return nil }
        self.init(kind: session.kind.id, serial: session.recorderSerial ?? status.serial, name: session.device.name,
                  isRecording: isRecording, recordingID: isRecording ? control.recordings.first(where: \.isInProgress)?.id : nil,
                  startedAt: isRecording ? status.recordingStartedAt : nil, asOf: status.updatedAt, conversationID: conversationID)
    }

    /// Whether it's the recorder of this session: by kind, and by serial when both have one.
    public func describes(kind: String, serial: String?) -> Bool {
        guard self.kind == kind else { return false }
        guard let mine = self.serial, let theirs = serial, !mine.isEmpty, !theirs.isEmpty else { return true }
        return mine == theirs
    }

    /// What it says lasts this long past its as-of time; after that it's unknown.
    public static let lifetime: TimeInterval = 20 * 60

    /// "Recording since 10:02" or "Not recording", with "as of 10:14" once it isn't fresh; nil once
    /// it's too old to say (`lifetime`). Times on this device's clock.
    public func summary(now: Date = Date()) -> String? {
        let age = now.timeIntervalSince(asOf)
        guard age <= Self.lifetime else { return nil }
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let what = isRecording ? (startedAt.map { "Recording since \(time($0))" } ?? "Recording") : "Not recording"
        return age > 60 ? "\(what), as of \(time(asOf))" : what
    }
}

extension LinkRecorderState {
    /// The recorders among `sessions` this device manages, as `recording.state` carries them.
    @MainActor
    public static func states(of sessions: [DeviceSession], conversation: (DeviceSession) -> UUID? = { _ in nil }) -> [LinkRecorderState] {
        sessions.compactMap { LinkRecorderState(session: $0, conversationID: conversation($0)) }
    }
}

extension DeviceHub {
    /// The recorders this device manages, as `recording.state` carries them.
    public func recorderStates(conversation: (DeviceSession) -> UUID? = { _ in nil }) -> [LinkRecorderState] {
        LinkRecorderState.states(of: sessions, conversation: conversation)
    }

    /// Fires when a session publishes (a status read, a push, a new list), at most once per `interval`.
    public func recorderChanges(every interval: RunLoop.SchedulerTimeType.Stride = .seconds(1)) -> AnyPublisher<Void, Never> {
        $sessions.map { sessions in Publishers.MergeMany(sessions.map(\.objectWillChange)) }
            .switchToLatest()
            .debounce(for: interval, scheduler: RunLoop.main)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}

/// Starting and stopping a recorder this device manages because another device asked: multipoint
/// through the recorder's owner (a Mac records, and the phone that manages its Soundcore Work starts
/// it alongside), so only one device ever drives the recorder.
@MainActor
public enum RecorderRemoteControl {
    public struct Timing: Sendable {
        public var connect: Duration = .seconds(20)
        public var confirm: Duration = .seconds(15)
        /// For its list, read on this connection, before deciding what it's recording.
        public var inventory: Duration = .seconds(5)
        /// For the finished recording to appear in its list, to import it.
        public var listing: Duration = .seconds(20)
        public var poll: Duration = .milliseconds(100)
        public init() {}
    }

    /// The answer to `request` about `target`, among this device's `sessions`. A start that finds it
    /// recording already says so (and leaves it to the person); a stop pauses only the recording it
    /// names, then imports it into the requester's conversation.
    ///
    /// With `cascade` (the device's shared recordings), a start for the conversation it records along
    /// with already, or that it starts at the same moment on its own, is the same start, answered once;
    /// the recorder's audio is saved into that conversation as it records; and a stop saves that audio
    /// before it pauses the recorder.
    public static func answer(_ request: LinkRecordRequest, target: LinkRecorderTarget, sessions: [DeviceSession],
                              timing: Timing = Timing(), cascade: RecorderCascade? = nil) async -> LinkRecordReply.Outcome {
        guard let session = sessions.first(where: { session in
                  session.kind.id == target.kind && (target.serial == nil || session.recorderSerial == nil || session.recorderSerial == target.serial)
              }), session.managedElsewhere == nil, let control = session.direct as? any RecordControlConnection else {
            return .refused(LinkRecordRefusal(reason: .unsupported, message: "This device doesn’t manage that recorder."))
        }
        let name = session.device.name
        if let cascade, request.action == .start, cascade.conversation == nil || cascade.conversation?.id == request.conversationID {
            cascade.begin(request.conversationID, title: request.title, date: request.date)
            guard let member = await cascade.start(session, for: request.conversationID) else {
                return .refused(LinkRecordRefusal(reason: .recorderUnavailable, message: "\(name) didn’t start recording."))
            }
            switch member.state {
            case .recording, .stopping, .stopped:
                return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: member.startedAt, recordingID: member.recordingID,
                                               wasAlreadyRecording: member.role == .alreadyRecording))
            case .unavailable(let words), .stopFailed(let words):
                return .refused(LinkRecordRefusal(reason: .recorderUnavailable, message: words))
            case .starting:
                return .refused(LinkRecordRefusal(reason: .busy, message: "\(name) is still starting."))
            }
        }
        if let cascade, request.action == .stop { await cascade.prepareToStop(session) }
        let asked = Date()
        if !control.state.isConnected {
            guard control.isSetUp, control.state != .unavailable else {
                return .refused(LinkRecordRefusal(reason: .recorderUnavailable, message: "\(name) isn’t nearby."))
            }
            if !control.state.isBusy { control.connect() }
            guard await wait(timing.connect, timing.poll, until: { control.state.isConnected || control.state == .unavailable }),
                  control.state.isConnected else {
                return .refused(LinkRecordRefusal(reason: .recorderUnavailable, message: "\(name) isn’t nearby."))
            }
        } else if request.action == .stop {
            control.refresh()
        }
        // What it's recording comes with its list, read on this connection.
        let listed = await wait(timing.inventory, timing.poll) {
            !control.isRefreshing && control.isInventoryCurrent && (control.inventoryUpdatedAt.map { $0 >= asked } ?? false)
        }
        let inProgress = { control.recordings.first(where: \.isInProgress)?.id }
        switch request.action {
        case .start:
            if control.status?.isRecording == true {
                return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: control.status?.recordingStartedAt,
                                               recordingID: inProgress(), wasAlreadyRecording: true))
            }
            control.startRecording()
            guard await wait(timing.confirm, timing.poll, until: { control.status?.isRecording == true && !control.recordCommandPending }) else {
                return .refused(LinkRecordRefusal(reason: .recorderUnavailable, message: "\(name) didn’t start recording."))
            }
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: control.status?.recordingStartedAt ?? Date(),
                                           recordingID: inProgress()))
        case .stop:
            // Which recording it's making is known only from a list read now: an older one may name a
            // recording the person has stopped since, and pausing would stop theirs.
            if target.recordingID != nil, !listed {
                return .refused(LinkRecordRefusal(reason: .recorderUnavailable, message: "\(name) didn’t say what it’s recording."))
            }
            guard control.status?.isRecording == true, target.recordingID == nil || inProgress() == target.recordingID else {
                return .refused(LinkRecordRefusal(reason: .notRecording))
            }
            control.pauseRecording()
            guard await wait(timing.confirm, timing.poll, until: { control.status?.isRecording == false && !control.recordCommandPending }) else {
                return .refused(LinkRecordRefusal(reason: .recorderUnavailable, message: "\(name) didn’t confirm it stopped."))
            }
            cascade?.remoteStopped(session, recordingID: target.recordingID ?? inProgress())
            // Brought in for the requester's conversation once it's finished, which its link joins wherever it lands.
            if let recordingID = target.recordingID {
                Task {
                    let finished = { control.recordings.first { $0.id == recordingID && !$0.isInProgress } }
                    guard await wait(timing.listing, timing.poll, until: { finished() != nil }), let recording = finished(),
                          !session.queue.contains(recording.id), session.links.imported[recording.id] == nil else { return }
                    session.importRecordings([recording], attachTo: request.conversationID, automatic: true)
                }
            }
            return .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: Date(), recordingID: target.recordingID))
        default:
            return .refused(LinkRecordRefusal(reason: .unsupported))
        }
    }

    private static func wait(_ limit: Duration, _ poll: Duration, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !condition() {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: poll)) != nil else { return condition() }
        }
        return true
    }
}
