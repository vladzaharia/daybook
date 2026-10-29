import DaybookCore
import Foundation

/// Where a conversation's processing stands, shown the same way on the Mac and the iPhone
/// (docs/iphone.md, "Processing on the Mac"). It's derived, never stored: from the conversation's
/// data and its synced `ProcessingRequest`s, and, on a device that processes, from that device's
/// own queue (`LocalQueue`), which takes precedence because it's live.
///
/// Recording is not a processing state; each app checks its own capture first.
public enum ProcessingStatus: Equatable, Sendable {
    /// Audio that isn't transcribed yet, and nothing has asked for it. A complete, normal state:
    /// everything but the transcript and summary works.
    case recorded
    /// Asked for and waiting.
    case requested(Waiting)
    /// Being processed, on this device or another one.
    case processing(Progress)
    /// Transcribed, with no summary, and nothing has asked for one (a summary stopped partway, say):
    /// the transcript reads, and Summarize asks for the rest.
    case transcribed
    /// Nothing waits: transcripts and summary are in, or there's no audio to process.
    case done
    /// This Mac's audio is transcribed and summarized, and a recording made alongside it on another
    /// device (Daybook on iPhone, a recorder) hasn't arrived yet. When it does, it's added and the
    /// transcript and summary are enhanced (docs/multipoint.md, "Mac first").
    case awaitingRecordings([AwaitedRecording])
    /// The last attempt couldn't finish.
    case failed(Failure)

    public enum Waiting: Equatable, Sendable {
        /// In this device's queue; position 0 is next, after the conversation running now.
        case queued(position: Int, after: UUID?)
        /// Until the models this device needs finish downloading.
        case models
        /// The person paused it on this device; it resumes only when asked.
        case paused
        /// A request in the library waits for a device that processes (a Mac).
        case device(ProcessingRequest)
    }

    public struct Progress: Equatable, Sendable {
        public var stage: ProcessingRequest.Stage
        /// 0...1; nil when the device reported no figure.
        public var fraction: Double?
        /// The device doing the work; nil for this one.
        public var device: ProcessingRequest.Device?
        /// Recordings made alongside this one that haven't arrived: the work now is on the audio that has.
        public var awaiting: [AwaitedRecording]

        public init(stage: ProcessingRequest.Stage, fraction: Double?, device: ProcessingRequest.Device? = nil,
                    awaiting: [AwaitedRecording] = []) {
            self.stage = stage; self.fraction = fraction; self.device = device; self.awaiting = awaiting
        }
    }

    public struct Failure: Equatable, Sendable {
        /// The device's own words, for Details.
        public var reason: String
        /// Transcripts were made before it stopped, so it was the summary that failed.
        public var hadTranscripts: Bool
        /// The device that reported it, when another device ran the request.
        public var device: ProcessingRequest.Device?
        /// The failed request, when there was one; Try Again writes a new request.
        public var request: ProcessingRequest?

        public init(reason: String, hadTranscripts: Bool, device: ProcessingRequest.Device? = nil, request: ProcessingRequest? = nil) {
            self.reason = reason; self.hadTranscripts = hadTranscripts; self.device = device; self.request = request
        }
    }

    /// What this device's processing queue is doing. The Mac supplies it; the iPhone has none.
    public struct LocalQueue: Equatable, Sendable {
        /// The conversation being processed now.
        public var running: UUID?
        /// How far it has got, 0...1.
        public var fraction: Double
        /// Its current step identifies speakers.
        public var identifyingSpeakers: Bool
        /// Waiting, in order.
        public var queued: [UUID]
        public var paused: Set<UUID>
        /// Waiting for models to download before they start.
        public var awaitingModels: Set<UUID>
        /// The models automatic processing needs are installed.
        public var canProcess: Bool

        public init(running: UUID? = nil, fraction: Double = 0, identifyingSpeakers: Bool = false, queued: [UUID] = [],
                    paused: Set<UUID> = [], awaitingModels: Set<UUID> = [], canProcess: Bool = true) {
            self.running = running; self.fraction = fraction; self.identifyingSpeakers = identifyingSpeakers
            self.queued = queued; self.paused = paused; self.awaitingModels = awaitingModels; self.canProcess = canProcess
        }
    }

    /// Derives a conversation's status. Precedence: this device's queue (running, waiting, waiting
    /// for models, paused), then synced requests (claimed, then waiting), then a failure, then
    /// whether audio still needs transcribing, then whether a transcript still needs its summary.
    public init(_ meeting: Meeting, queue: LocalQueue? = nil, now: Date = Date()) {
        if let queue {
            if queue.running == meeting.id {
                let stage: ProcessingRequest.Stage = meeting.status == .summarizing ? .summarizing
                    : queue.identifyingSpeakers ? .identifyingSpeakers : .transcribing
                self = .processing(Progress(stage: stage, fraction: queue.fraction, awaiting: meeting.awaitedRecordings(now: now)))
                return
            }
            if let position = queue.queued.firstIndex(of: meeting.id) {
                self = .requested(.queued(position: position, after: queue.running))
                return
            }
            if queue.awaitingModels.contains(meeting.id) || (meeting.hasUntranscribedTranscribableAudio && !queue.canProcess && meeting.status != .failed) {
                self = .requested(.models)
                return
            }
            if queue.paused.contains(meeting.id) {
                self = .requested(.paused)
                return
            }
        }
        let open = meeting.openProcessingRequests.filter { !$0.isSatisfied(by: meeting) }
        if let claimed = open.compactMap({ request in request.activeClaim(at: now) }).max(by: { $0.heartbeat < $1.heartbeat }) {
            self = .processing(Progress(stage: claimed.stage ?? .transcribing, fraction: claimed.fraction, device: claimed.device,
                                        awaiting: meeting.awaitedRecordings(now: now)))
            return
        }
        if let waiting = open.first {
            self = .requested(.device(waiting))
            return
        }
        let lastFailure = (meeting.processingRequests ?? []).filter { $0.outcome?.result == .failed }
            .max { $0.outcome!.finishedAt < $1.outcome!.finishedAt }
        if meeting.status == .failed {
            self = .failed(Failure(reason: meeting.errorMessage ?? lastFailure?.outcome?.message ?? "",
                                   hadTranscripts: !meeting.transcripts.isEmpty, device: lastFailure?.outcome?.device, request: lastFailure))
            return
        }
        if let lastFailure, let outcome = lastFailure.outcome, !lastFailure.isSatisfied(by: meeting),
           !(meeting.processingRequests ?? []).contains(where: { $0.outcome?.result == .completed && $0.outcome!.finishedAt > outcome.finishedAt }) {
            self = .failed(Failure(reason: outcome.message ?? "", hadTranscripts: !meeting.transcripts.isEmpty,
                                   device: outcome.device, request: lastFailure))
            return
        }
        if meeting.hasUntranscribedTranscribableAudio { self = .recorded; return }
        if meeting.summary == nil, !meeting.unifiedTranscript.isEmpty { self = .transcribed; return }
        let awaited = meeting.awaitedRecordings(now: now)
        self = awaited.isEmpty ? .done : .awaitingRecordings(awaited)
    }

    /// Recorded audio that isn't transcribed yet.
    public var isRecorded: Bool { self == .recorded }
    /// Asked for, or being processed.
    public var isPending: Bool {
        switch self {
        case .requested, .processing: return true
        default: return false
        }
    }
}

/// A recording another device made alongside this conversation's (multipoint: Daybook on iPhone, a
/// recorder) that hasn't arrived yet. Derived from the conversation's synced links, so the Mac and the
/// iPhone say the same thing.
public struct AwaitedRecording: Equatable, Sendable {
    /// The device's own name: "Alex's iPhone", "Soundcore Work".
    public var deviceName: String
    /// Its kind (`daybook.iphone`, `soundcore.work`).
    public var deviceKind: String
    /// When the recording it goes with ended (or began, when that's all that's known).
    public var since: Date

    public init(deviceName: String, deviceKind: String, since: Date) {
        self.deviceName = deviceName; self.deviceKind = deviceKind; self.since = since
    }

    /// A recording that hasn't come in this long is let go: it may never arrive.
    public static let lifetime: TimeInterval = 2 * 86_400

    /// For a short line: "iPhone" for any Daybook on iPhone, otherwise the device's name ("Soundcore Work").
    public var shortName: String { deviceKind == DaybookPhoneIntegration.id ? "iPhone" : deviceName }
}

extension ProcessingStatus {
    /// For a list row or a chip: "Waiting for iPhone audio", "Waiting for iPhone and Soundcore Work audio".
    public static func awaitingLine(_ recordings: [AwaitedRecording]) -> String {
        var names: [String] = []
        for name in recordings.map(\.shortName) where !names.contains(name) { names.append(name) }
        return "Waiting for \(names.formatted(.list(type: .and))) audio"
    }

    /// For a page: "Waiting for audio from Alex's iPhone".
    public static func awaitingDetail(_ recordings: [AwaitedRecording]) -> String {
        var names: [String] = []
        for name in recordings.map(\.deviceName) where !names.contains(name) { names.append(name) }
        return "Waiting for audio from \(names.formatted(.list(type: .and)))"
    }
}

extension Meeting {
    /// Recordings made alongside this conversation's on other devices that haven't arrived: a
    /// multipoint link that recorded (or may have) after this Mac's recording ended, with no recording
    /// of that device's in the conversation yet, for at most `AwaitedRecording.lifetime`.
    public func awaitedRecordings(now: Date = Date()) -> [AwaitedRecording] {
        (companions ?? []).compactMap { link in
            guard link.expectsRecording, link.trackID == nil else { return nil }
            let since = link.macEndedAt ?? link.macStartedAt
            guard now.timeIntervalSince(since) <= AwaitedRecording.lifetime, !hasRecording(fulfilling: link) else { return nil }
            return AwaitedRecording(deviceName: link.deviceName, deviceKind: link.deviceKind, since: since)
        }
    }

    /// A recording this conversation was waiting for has arrived and isn't added yet: a multipoint
    /// link that recorded (or may have), not yet attached, and an untranscribed recording of that
    /// device's here that it was waiting for, within `AwaitedRecording.lifetime`. A Mac adds it
    /// whatever "Transcribe synced recordings" says: it completes a recording made with a Mac, whose
    /// own audio was processed straight away (docs/multipoint.md, "Mac first").
    public func hasAwaitedRecordingToAdd(now: Date = Date()) -> Bool {
        (companions ?? []).contains { link in
            guard link.expectsRecording, link.trackID == nil else { return false }
            guard now.timeIntervalSince(link.macEndedAt ?? link.macStartedAt) <= AwaitedRecording.lifetime else { return false }
            return tracks.contains { track in
                Self.track(track, fulfills: link) && !transcripts.contains { $0.trackID == track.id }
            }
        }
    }

    /// The conversation holds a recording from the link's device that it was waiting for.
    private func hasRecording(fulfilling link: CompanionRecording) -> Bool {
        tracks.contains { Self.track($0, fulfills: link) }
    }

    /// A recording from the link's device that it was waiting for: by its recording ID when the
    /// device reported one, otherwise one from that device that started after this Mac did.
    private static func track(_ track: RecordingTrack, fulfills link: CompanionRecording) -> Bool {
        guard track.deviceKind == link.deviceKind else { return false }
        if let a = link.deviceSerial, let b = track.deviceSerial, !a.isEmpty, !b.isEmpty, a != b { return false }
        if let id = link.recordingID, let recording = track.deviceRecordingID {
            return recording == id || recording.hasPrefix(id)
        }
        return (track.startedAt ?? track.createdAt) >= link.macStartedAt.addingTimeInterval(-120)
    }
}

extension ProcessingRequest {
    /// The conversation already has what this request asked for, made after it was asked: for
    /// example, a Mac transcribed new audio as it arrived through sync. Its status then reads
    /// from the conversation itself rather than "waiting".
    public func isSatisfied(by meeting: Meeting) -> Bool {
        guard let summary = meeting.summary, summary.createdAt >= createdAt else { return false }
        switch mode {
        case .newAudio, .summaryOnly:
            return !meeting.hasUntranscribedTranscribableAudio
        case .speakerRefresh, .fullRetranscription:
            let tracks = meeting.transcribableTracks
            return !tracks.isEmpty && tracks.allSatisfy { track in
                meeting.transcripts.contains { $0.trackID == track.id && $0.createdAt >= createdAt }
            }
        }
    }
}
