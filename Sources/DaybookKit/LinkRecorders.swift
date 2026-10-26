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
    /// control, or that hasn't said. (With the hardware integration's `SoundcoreConnection.recordingState`,
    /// read that here instead.)
    @MainActor
    public init?(session: DeviceSession, conversationID: UUID? = nil) {
        guard session.managedElsewhere == nil, let control = session.direct as? any RecordControlConnection, control is any ManagedConnection,
              let status = control.status, let isRecording = status.isRecording else { return nil }
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
