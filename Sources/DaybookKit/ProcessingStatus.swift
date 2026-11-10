import DaybookCore
import DaybookDevices
import DaybookLink
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
    /// A recording made alongside never arrived within `AwaitedRecording.lifetime`: what's here was transcribed and
    /// summarized without it. Said rather than read as done, with Don't Wait and Wait Again.
    case missingRecordings([AwaitedRecording])
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
        /// What kind of failure it was, as the request's outcome stored it; for an older record, or a failure kept
        /// only on the conversation, what `reason` says (`FailureKind(legacyMessage:)`). Both apps word it from
        /// this (`FailureWords`), never from `reason`.
        public var kind: ProcessingRequest.FailureKind

        public init(reason: String, hadTranscripts: Bool, device: ProcessingRequest.Device? = nil, request: ProcessingRequest? = nil,
                    kind: ProcessingRequest.FailureKind? = nil) {
            self.reason = reason; self.hadTranscripts = hadTranscripts; self.device = device; self.request = request
            self.kind = kind ?? ProcessingRequest.FailureKind(legacyMessage: reason)
        }

        /// Trying again can't find speech that isn't there.
        public var isNoSpeech: Bool { kind == .noSpeech }
    }

    /// What this device's processing queue is doing: the Mac's, and the iPhone's own recordings'
    /// (`PhoneProcessor`).
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
        /// The running conversation's step, when the queue knows it; nil reads it from the conversation
        /// (the Mac marks one being summarized).
        public var stage: ProcessingRequest.Stage?

        public init(running: UUID? = nil, fraction: Double = 0, identifyingSpeakers: Bool = false, queued: [UUID] = [],
                    paused: Set<UUID> = [], awaitingModels: Set<UUID> = [], canProcess: Bool = true,
                    stage: ProcessingRequest.Stage? = nil) {
            self.running = running; self.fraction = fraction; self.identifyingSpeakers = identifyingSpeakers
            self.queued = queued; self.paused = paused; self.awaitingModels = awaitingModels; self.canProcess = canProcess
            self.stage = stage
        }
    }

    /// Derives a conversation's status. Precedence: this device's queue (running, waiting, waiting
    /// for models, paused), then synced requests (claimed, then waiting), then a failure, then
    /// whether audio still needs transcribing, then whether a transcript still needs its summary.
    public init(_ meeting: Meeting, queue: LocalQueue? = nil, now: Date = Date()) {
        if let queue {
            if queue.running == meeting.id {
                let stage: ProcessingRequest.Stage = queue.stage ?? (meeting.status == .summarizing ? .summarizing
                    : queue.identifyingSpeakers ? .identifyingSpeakers : .transcribing)
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
            let reason = meeting.errorMessage ?? lastFailure?.outcome?.message ?? ""
            // The request's stored kind, when the conversation's message is that request's; otherwise the message says.
            let outcome = lastFailure?.outcome
            let kind = outcome.flatMap { ($0.message ?? "") == reason || meeting.errorMessage == nil ? $0.failureKind : nil }
            self = .failed(Failure(reason: reason, hadTranscripts: !meeting.transcripts.isEmpty, device: outcome?.device,
                                   request: lastFailure, kind: kind))
            return
        }
        // A Try Again taken back (`isWithdrawn`) did nothing, so the failure before it still stands.
        if let lastFailure, let outcome = lastFailure.outcome, !lastFailure.isSatisfied(by: meeting),
           !(meeting.processingRequests ?? []).contains(where: {
               $0.outcome?.result == .completed && !$0.isWithdrawn && $0.outcome!.finishedAt > outcome.finishedAt
           }) {
            self = .failed(Failure(reason: outcome.message ?? "", hadTranscripts: !meeting.transcripts.isEmpty,
                                   device: outcome.device, request: lastFailure, kind: outcome.failureKind))
            return
        }
        if meeting.hasUntranscribedTranscribableAudio { self = .recorded; return }
        if meeting.summary == nil, !meeting.unifiedTranscript.isEmpty { self = .transcribed; return }
        let awaited = meeting.awaitedRecordings(now: now)
        if !awaited.isEmpty { self = .awaitingRecordings(awaited); return }
        let missing = meeting.missingRecordings(now: now)
        self = missing.isEmpty ? .done : .missingRecordings(missing)
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
    /// The last attempt couldn't finish.
    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
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

    /// What a device's arrival status is kept under (`ConversationStatusPresentation.Inputs.arrivals`).
    public var arrivalKey: String { Self.arrivalKey(deviceKind: deviceKind, deviceName: deviceName) }
    public static func arrivalKey(deviceKind: String, deviceName: String) -> String { "\(deviceKind)|\(deviceName)" }
}

/// Where a recording a conversation waits for is, as far as this device can tell (docs/multipoint.md, "Mac first"): the
/// device that made it says so over the local link, or its sync presence does. Nil, nothing to add: it's on its way
/// through sync.
public enum ArrivalStatus: Equatable, Sendable {
    /// The device is saving it after Stop.
    case filing
    /// On its way from the device: a share of its bytes, when known.
    case sending(Double?)
    /// The device's iCloud storage is full, so it can't send it.
    case storageFull
    /// The device waits for the encrypted library's key, so nothing it records syncs yet.
    case waitingForKey
    /// The device hasn't been online since then (its presence).
    case lastOnline(Date)

    /// The device's word over the link counts for this long after it's heard (always, while it's connected).
    public static let reportLifetime: TimeInterval = 10 * 60

    /// From what this device knows: the other device's word over the link (`LinkRecordingArrival`, received at
    /// `reportedAt`), while it's connected or recent, else its presence: iCloud storage full, the library's key not there
    /// yet, not heard from for a while (`KnownSyncDevice.isPresent`, "Last online" at its own last write), or files still
    /// to upload.
    public static func resolve(report: LinkRecordingArrival?, reportedAt: Date?, connected: Bool, presence: KnownSyncDevice?,
                               now: Date = Date()) -> ArrivalStatus? {
        if let report, connected || reportedAt.map({ now.timeIntervalSince($0) < reportLifetime }) == true {
            switch report.phase {
            case .filing: return .filing
            case .sending: return .sending(report.fraction)
            case .storageFull: return .storageFull
            case .waitingForKey: return .waitingForKey
            default: return nil
            }
        }
        guard let presence, let lastSeen = presence.lastSeen else { return nil }
        if presence.problem == .storageFull { return .storageFull }
        if presence.keyState?.state == .waiting { return .waitingForKey }
        if !presence.isPresent(at: now) { return .lastOnline(lastSeen) }
        if (presence.pendingUploads ?? 0) > 0 { return .sending(nil) }
        return nil
    }

    /// The clause after the wait: "Sending 40%", "Last online 10:02", "Alex’s iPhone is out of iCloud storage".
    public func clause(device: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch self {
        case .filing: return "Saving"
        case .sending(let fraction):
            guard let fraction, fraction > 0, fraction < 1 else { return "Sending" }
            return "Sending \(Int(fraction * 100))%"
        case .storageFull: return "\(device) is out of iCloud storage"
        case .waitingForKey: return "\(device) is waiting for this library’s key"
        case .lastOnline(let date):
            if calendar.isDate(date, inSameDayAs: now) { return "Last online \(date.formatted(date: .omitted, time: .shortened))" }
            return "Last online \(DeviceDateFormat.lastSeen(date, now: now, calendar: calendar))"
        }
    }
}

extension ProcessingStatus {
    /// For a list row or a chip: "Waiting for iPhone audio", "Waiting for iPhone and Soundcore Work audio".
    public static func awaitingLine(_ recordings: [AwaitedRecording]) -> String {
        var names: [String] = []
        for name in recordings.map(\.shortName) where !names.contains(name) { names.append(name) }
        return "Waiting for \(names.formatted(.list(type: .and))) audio"
    }

    /// For a page: "Waiting for audio from Alex's iPhone", and one clause on where it is when this device knows
    /// ("Waiting for audio from Alex's iPhone · Sending 40%").
    public static func awaitingDetail(_ recordings: [AwaitedRecording], arrivals: [String: ArrivalStatus] = [:], now: Date = Date()) -> String {
        var names: [String] = []
        for name in recordings.map(\.deviceName) where !names.contains(name) { names.append(name) }
        let line = "Waiting for audio from \(names.formatted(.list(type: .and)))"
        guard let known = recordings.first(where: { arrivals[$0.arrivalKey] != nil }), let arrival = arrivals[known.arrivalKey] else { return line }
        return "\(line) · \(arrival.clause(device: known.deviceName, now: now))"
    }

    /// This device's own recording a Mac waits for, while it isn't on its way: "Sending this iPhone’s audio to your Mac",
    /// "This iPhone’s audio can’t be sent · iCloud storage is full". `here` is how this device calls itself ("this iPhone").
    public static func unsentLine(_ status: ArrivalStatus, here: String) -> String {
        let device = here.prefix(1).uppercased() + here.dropFirst()
        switch status {
        case .filing: return "Saving \(here)’s audio"
        case .sending(let fraction):
            guard let fraction, fraction > 0, fraction < 1 else { return "Sending \(here)’s audio to your Mac" }
            return "Sending \(here)’s audio to your Mac · \(Int(fraction * 100))%"
        case .storageFull: return "\(device)’s audio can’t be sent · iCloud storage is full"
        case .waitingForKey: return "\(device)’s audio can’t be sent · waiting for this library’s key"
        case .lastOnline: return "Sending \(here)’s audio to your Mac"
        }
    }

    /// For a page, a recording that never arrived: "Alex's iPhone audio didn't arrive".
    public static func missingDetail(_ recordings: [AwaitedRecording]) -> String {
        var names: [String] = []
        for name in recordings.map(\.deviceName) where !names.contains(name) { names.append(name) }
        return "\(names.formatted(.list(type: .and))) audio didn’t arrive"
    }

    /// For a list row or a chip: "iPhone audio didn't arrive".
    public static func missingLine(_ recordings: [AwaitedRecording]) -> String {
        var names: [String] = []
        for name in recordings.map(\.shortName) where !names.contains(name) { names.append(name) }
        return "\(names.formatted(.list(type: .and))) audio didn’t arrive"
    }
}

extension Meeting {
    /// Recordings made alongside this conversation's on other devices that haven't arrived: a
    /// multipoint link that recorded (or may have) after this Mac's recording ended, with no recording
    /// of that device's in the conversation yet, for at most `AwaitedRecording.lifetime`, until the
    /// person chooses Don't Wait (`stopWaitingForRecordings`).
    public func awaitedRecordings(now: Date = Date()) -> [AwaitedRecording] {
        (companions ?? []).compactMap { link in
            guard waits(for: link, now: now) else { return nil }
            return AwaitedRecording(deviceName: link.deviceName, deviceKind: link.deviceKind, since: link.macEndedAt ?? link.macStartedAt)
        }
    }

    /// Recordings it waited for that never came: a link that recorded (or may have), past `AwaitedRecording.lifetime`
    /// with no recording of its device's here, and no Don't Wait. Said ("Alex's iPhone audio didn't arrive") until the
    /// person chooses Don't Wait or Wait Again, or it arrives after all.
    public func missingRecordings(now: Date = Date()) -> [AwaitedRecording] {
        (companions ?? []).compactMap { link in
            guard isMissing(link, now: now) else { return nil }
            return AwaitedRecording(deviceName: link.deviceName, deviceKind: link.deviceKind, since: link.macEndedAt ?? link.macStartedAt)
        }
    }

    /// The links whose recordings never came: what Wait Again waits for again, and Don't Wait lets go.
    public func missingLinks(now: Date = Date()) -> Set<UUID> {
        Set((companions ?? []).filter { isMissing($0, now: now) }.map(\.id))
    }

    /// The links whose recordings it waits for now: what Don't Wait stops waiting for.
    public func awaitedLinks(now: Date = Date()) -> Set<UUID> {
        Set((companions ?? []).filter { waits(for: $0, now: now) }.map(\.id))
    }

    /// A recording this conversation was waiting for has arrived and isn't added yet: a multipoint
    /// link that recorded (or may have), not yet attached, and an untranscribed recording of that
    /// device's here that it was waiting for, within `AwaitedRecording.lifetime`. A Mac adds it
    /// whatever "Transcribe synced recordings" says: it completes a recording made with a Mac, whose
    /// own audio was processed straight away (docs/multipoint.md, "Mac first").
    public func hasAwaitedRecordingToAdd(now: Date = Date()) -> Bool {
        (companions ?? []).contains { link in
            guard link.expectsRecording, link.trackID == nil else { return false }
            guard now.timeIntervalSince(link.waitingSince) <= AwaitedRecording.lifetime else { return false }
            return tracks.contains { track in
                Self.track(track, fulfills: link) && !transcripts.contains { $0.trackID == track.id }
            }
        }
    }

    /// Don't Wait: stops waiting for every recording it waits for now, and lets go of one that never came (of `links`
    /// alone, when given), so its status says what's here. A recording that still arrives is added
    /// (`hasAwaitedRecordingToAdd`, within its lifetime). Returns whether anything was waited for.
    @discardableResult
    public mutating func stopWaitingForRecordings(at now: Date = Date(), links only: Set<UUID>? = nil) -> Bool {
        guard var links = companions else { return false }
        var stopped = false
        for index in links.indices where (only?.contains(links[index].id) ?? true)
            && (waits(for: links[index], now: now) || isMissing(links[index], now: now)) {
            links[index].stoppedWaitingAt = now
            stopped = true
        }
        if stopped { companions = links }
        return stopped
    }

    /// Takes back Don't Wait for these links alone: each is waited for again. The other links, and everything else
    /// these say (a recording that arrived since), stay as they are. Returns whether any link changed.
    @discardableResult
    public mutating func waitAgain(for only: Set<UUID>) -> Bool {
        guard var links = companions else { return false }
        var resumed = false
        for index in links.indices where only.contains(links[index].id) && links[index].stoppedWaitingAt != nil {
            links[index].stoppedWaitingAt = nil
            resumed = true
        }
        if resumed { companions = links }
        return resumed
    }

    /// Wait Again for a recording that never came (of `links` alone, when given): it's waited for once more, for
    /// `AwaitedRecording.lifetime` from now. Returns whether any link changed.
    @discardableResult
    public mutating func waitAgainForMissingRecordings(at now: Date = Date(), links only: Set<UUID>? = nil) -> Bool {
        guard var links = companions else { return false }
        var resumed = false
        for index in links.indices where (only?.contains(links[index].id) ?? true) && isMissing(links[index], now: now) {
            links[index].waitedAgainAt = now
            resumed = true
        }
        if resumed { companions = links }
        return resumed
    }

    /// It waits for the link's recording: the recorder recorded, or may have, and its recording isn't here, within
    /// `AwaitedRecording.lifetime` of this Mac's recording (or of Wait Again), until Don't Wait.
    private func waits(for link: CompanionRecording, now: Date) -> Bool {
        link.expectsRecording && link.trackID == nil && link.stoppedWaitingAt == nil
            && now.timeIntervalSince(link.waitingSince) <= AwaitedRecording.lifetime
            && !hasRecording(fulfilling: link)
    }

    /// The link's recording never came: it was waited for, past `AwaitedRecording.lifetime`, and nobody chose Don't Wait.
    private func isMissing(_ link: CompanionRecording, now: Date) -> Bool {
        link.expectsRecording && link.trackID == nil && link.stoppedWaitingAt == nil
            && now.timeIntervalSince(link.waitingSince) > AwaitedRecording.lifetime
            && !hasRecording(fulfilling: link)
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
