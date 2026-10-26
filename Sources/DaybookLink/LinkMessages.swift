import Foundation

// MARK: Open values

/// A string-backed value that keeps values it doesn't know, so a newer peer can add cases
/// (a refusal reason, a processing phase) without breaking an older one.
public protocol LinkOpenValue: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible where RawValue == String {
    init(rawValue: String)
}

extension LinkOpenValue {
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
}

/// What kind of device is on the other end.
public struct LinkDeviceClass: LinkOpenValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let mac: Self = "mac"
    public static let iPhone: Self = "iPhone"
    public static let iPad: Self = "iPad"
}

// MARK: Capabilities

/// Who a device is and what it can do. Sent in hello/welcome and again whenever it changes.
public struct LinkCapabilities: Codable, Sendable, Equatable {
    public var deviceClass: LinkDeviceClass
    public var name: String
    public var appVersion: String
    /// The synced library this device has open, if any.
    public var libraryID: UUID?
    /// True on a Mac that has the models to transcribe and summarize.
    public var canProcess: Bool
    /// Optional abilities by name, for additions that don't need a new protocol version.
    public var features: [String]
    /// The device's sync replica ID (`LibrarySyncController.deviceID`), which the library's records
    /// (recorder ownership, processing requests) use. Optional: older builds don't send it, and on a
    /// Mac it equals the link device ID.
    public var syncDeviceID: String?

    public init(deviceClass: LinkDeviceClass, name: String, appVersion: String, libraryID: UUID? = nil,
                canProcess: Bool = false, features: [String] = [], syncDeviceID: String? = nil) {
        self.deviceClass = deviceClass
        self.name = name
        self.appVersion = appVersion
        self.libraryID = libraryID
        self.canProcess = canProcess
        self.features = features
        self.syncDeviceID = syncDeviceID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceClass = try c.decode(LinkDeviceClass.self, forKey: .deviceClass)
        name = try c.decode(String.self, forKey: .name)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        libraryID = try c.decodeIfPresent(UUID.self, forKey: .libraryID)
        canProcess = try c.decodeIfPresent(Bool.self, forKey: .canProcess) ?? false
        features = try c.decodeIfPresent([String].self, forKey: .features) ?? []
        syncDeviceID = try c.decodeIfPresent(String.self, forKey: .syncDeviceID)
    }
}

// MARK: Recording state

/// The sender's recorder, sent whenever it changes and every few seconds while recording.
public struct LinkRecordingState: Codable, Sendable, Equatable {
    public struct Phase: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let idle: Self = "idle"
        public static let starting: Self = "starting"
        public static let recording: Self = "recording"
        public static let paused: Self = "paused"
        public static let stopping: Self = "stopping"
    }

    public var phase: Phase
    /// The conversation being recorded.
    public var conversationID: UUID?
    /// When this recording started, on the sender's clock.
    public var startedAt: Date?
    /// Seconds recorded so far, as of `sentAt`.
    public var elapsed: TimeInterval
    /// When this was sent, on the sender's clock, so the receiver can keep counting.
    public var sentAt: Date

    public init(phase: Phase, conversationID: UUID? = nil, startedAt: Date? = nil, elapsed: TimeInterval = 0,
                sentAt: Date = Date()) {
        self.phase = phase
        self.conversationID = conversationID
        self.startedAt = startedAt
        self.elapsed = elapsed
        self.sentAt = sentAt
    }
}

// MARK: Record control

/// Timing the requester already knows, so the other side can place its recording on the
/// conversation's timeline before any sound is compared.
public struct LinkTiming: Codable, Sendable, Equatable {
    /// When the requester's own recording of this conversation started, on the requester's clock.
    public var startedAt: Date?
    /// Seconds of the conversation's timeline that had passed when the request was sent (nil when
    /// the timeline's zero isn't known).
    public var elapsed: TimeInterval?
    /// The requester's estimate of (receiver's clock − requester's clock), from clock samples.
    public var clockOffset: TimeInterval?
    /// How far `clockOffset` could be off (half the best round trip).
    public var clockUncertainty: TimeInterval?
    /// When the conversation's timeline zero happened, on the requester's clock: its own
    /// recording's start for a new conversation, earlier for one that already had recordings. Nil
    /// when it isn't known, or from older builds (whose `elapsed` counted from `startedAt`).
    public var timelineStart: Date?

    public init(startedAt: Date? = nil, elapsed: TimeInterval? = nil, clockOffset: TimeInterval? = nil,
                clockUncertainty: TimeInterval? = nil, timelineStart: Date? = nil) {
        self.startedAt = startedAt
        self.elapsed = elapsed
        self.clockOffset = clockOffset
        self.clockUncertainty = clockUncertainty
        self.timelineStart = timelineStart
    }
}

/// "Start (or stop) recording this conversation too." Sending the same `id` again is safe: the
/// receiver answers a repeated request with its first reply.
public struct LinkRecordRequest: Codable, Sendable, Equatable, Identifiable {
    public struct Action: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let start: Self = "start"
        public static let stop: Self = "stop"
    }

    public var id: UUID
    public var action: Action
    public var conversationID: UUID
    public var timing: LinkTiming?
    /// When this was sent, on the requester's clock.
    public var sentAt: Date
    /// The conversation's title and date as the requester has them (starts), so a receiver that
    /// hasn't synced it yet creates the same record rather than one of its own. Optional: older
    /// builds don't send them.
    public var title: String?
    public var date: Date?
    /// Start a conversation of the receiver's own (a device page's Start Recording), not one
    /// recorded alongside the requester. Older builds don't send it; their requests without timing
    /// mean the same.
    public var standalone: Bool?

    public init(id: UUID = UUID(), action: Action, conversationID: UUID, timing: LinkTiming? = nil, sentAt: Date = Date(),
                title: String? = nil, date: Date? = nil, standalone: Bool? = nil) {
        self.id = id
        self.action = action
        self.conversationID = conversationID
        self.timing = timing
        self.sentAt = sentAt
        self.title = title
        self.date = date
        self.standalone = standalone
    }

    /// The receiver records a conversation of its own rather than alongside the requester.
    public var isStandalone: Bool { standalone == true || (action == .start && timing?.startedAt == nil) }
}

/// The receiver did what was asked.
public struct LinkRecordAck: Codable, Sendable, Equatable {
    public var conversationID: UUID
    /// When its recording started, on the receiver's clock (start requests).
    public var startedAt: Date?
    /// When its recording stopped, on the receiver's clock (stop requests).
    public var stoppedAt: Date?
    /// How the receiver names the recording, so it can be matched when it arrives through sync.
    public var recordingID: String?
    /// It was already recording this conversation; nothing new was started.
    public var wasAlreadyRecording: Bool

    public init(conversationID: UUID, startedAt: Date? = nil, stoppedAt: Date? = nil, recordingID: String? = nil,
                wasAlreadyRecording: Bool = false) {
        self.conversationID = conversationID
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.recordingID = recordingID
        self.wasAlreadyRecording = wasAlreadyRecording
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        stoppedAt = try c.decodeIfPresent(Date.self, forKey: .stoppedAt)
        recordingID = try c.decodeIfPresent(String.self, forKey: .recordingID)
        wasAlreadyRecording = try c.decodeIfPresent(Bool.self, forKey: .wasAlreadyRecording) ?? false
    }
}

/// The receiver didn't do what was asked, and why.
public struct LinkRecordRefusal: Codable, Sendable, Equatable {
    public struct Reason: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Recording another conversation (`conversationID` says which).
        public static let recordingSomethingElse: Self = "recordingSomethingElse"
        /// Asked to stop, but not recording that conversation.
        public static let notRecording: Self = "notRecording"
        public static let microphoneUnavailable: Self = "microphoneUnavailable"
        public static let permissionDenied: Self = "permissionDenied"
        public static let storageFull: Self = "storageFull"
        public static let busy: Self = "busy"
        /// The person said no, or turned off "Also record when the Mac records".
        public static let declined: Self = "declined"
        /// This device doesn't take record requests.
        public static let unsupported: Self = "unsupported"
    }

    public var reason: Reason
    /// Words to show, when the receiver has better ones than the reason.
    public var message: String?
    public var conversationID: UUID?

    public init(reason: Reason, message: String? = nil, conversationID: UUID? = nil) {
        self.reason = reason
        self.message = message
        self.conversationID = conversationID
    }
}

/// The answer to a `LinkRecordRequest`.
public struct LinkRecordReply: Codable, Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case accepted(LinkRecordAck)
        case refused(LinkRecordRefusal)
    }

    public var requestID: UUID
    public var outcome: Outcome
    /// When this was sent, on the replier's clock.
    public var sentAt: Date

    public init(requestID: UUID, outcome: Outcome, sentAt: Date = Date()) {
        self.requestID = requestID
        self.outcome = outcome
        self.sentAt = sentAt
    }

    private enum CodingKeys: String, CodingKey { case requestID, accepted, refused, sentAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
        if let ack = try c.decodeIfPresent(LinkRecordAck.self, forKey: .accepted) {
            outcome = .accepted(ack)
        } else {
            // A reply this build can't read as an acknowledgment is a refusal, never a silent yes.
            outcome = .refused(try c.decodeIfPresent(LinkRecordRefusal.self, forKey: .refused)
                ?? LinkRecordRefusal(reason: "unknown"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(sentAt, forKey: .sentAt)
        switch outcome {
        case .accepted(let ack): try c.encode(ack, forKey: .accepted)
        case .refused(let refusal): try c.encode(refusal, forKey: .refused)
        }
    }
}

// MARK: Bookmarks, processing

/// A bookmark made while recording, timed on the recording that the sender is making.
public struct LinkBookmark: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    /// Seconds into the sender's recording.
    public var recordingTime: TimeInterval
    /// When it was made, on the sender's clock.
    public var createdAt: Date
    public var label: String?

    public init(id: UUID = UUID(), conversationID: UUID, recordingTime: TimeInterval, createdAt: Date = Date(),
                label: String? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.recordingTime = recordingTime
        self.createdAt = createdAt
        self.label = label
    }
}

/// Live progress of processing on a Mac. Coarse progress also travels through sync.
public struct LinkProcessingProgress: Codable, Sendable, Equatable {
    public struct Phase: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let queued: Self = "queued"
        public static let aligning: Self = "aligning"
        public static let transcribing: Self = "transcribing"
        public static let identifyingSpeakers: Self = "identifyingSpeakers"
        public static let summarizing: Self = "summarizing"
        public static let paused: Self = "paused"
        public static let waitingForModels: Self = "waitingForModels"
        public static let finished: Self = "finished"
        public static let failed: Self = "failed"
    }

    public var meetingID: UUID
    public var phase: Phase
    /// 0...1 within the phase, when known.
    public var fraction: Double?
    public var macName: String
    /// The Mac's own words, for failures in particular.
    public var detail: String?

    public init(meetingID: UUID, phase: Phase, fraction: Double? = nil, macName: String, detail: String? = nil) {
        self.meetingID = meetingID
        self.phase = phase
        self.fraction = fraction
        self.macName = macName
        self.detail = detail
    }
}

/// "I just wrote this processing request." The request itself travels through sync; this only
/// tells a Mac that's listening to look now instead of at the next sync pass.
public struct LinkProcessingNudge: Codable, Sendable, Equatable {
    public struct Mode: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let transcribe: Self = "transcribe"
        public static let summarizeAgain: Self = "summarizeAgain"
        public static let changeTemplate: Self = "changeTemplate"
        public static let identifySpeakersAgain: Self = "identifySpeakersAgain"
        public static let transcribeEverythingAgain: Self = "transcribeEverythingAgain"
    }

    public var requestID: UUID
    public var meetingID: UUID
    public var mode: Mode
    public var requestedAt: Date

    public init(requestID: UUID, meetingID: UUID, mode: Mode, requestedAt: Date = Date()) {
        self.requestID = requestID
        self.meetingID = meetingID
        self.mode = mode
        self.requestedAt = requestedAt
    }
}

// MARK: App messages

/// Messages the apps send and receive. Control traffic (hello, heartbeats, clock samples, record
/// requests and replies, unpairing) is handled by the link itself.
public enum LinkMessage: Sendable, Equatable {
    case recordingState(LinkRecordingState)
    case bookmark(LinkBookmark)
    case processingProgress(LinkProcessingProgress)
    case processingNudge(LinkProcessingNudge)
    /// Recorder handoff (LinkRecorderHandoff.swift): ask for a recorder or offer one, the answer, and
    /// the old owner's word that it has let go.
    case recorderHandoffRequest(LinkRecorderHandoffRequest)
    case recorderHandoffReply(LinkRecorderHandoffReply)
    case recorderRelease(LinkRecorderRelease)
}
