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
    /// What it does with its own models for other devices: transcribes, finds speakers, summarizes,
    /// and with which model for each role. Optional: older builds don't send it, so it's unknown.
    public var processing: LinkProcessingCapabilities?

    public init(deviceClass: LinkDeviceClass, name: String, appVersion: String, libraryID: UUID? = nil,
                canProcess: Bool = false, features: [String] = [], syncDeviceID: String? = nil,
                processing: LinkProcessingCapabilities? = nil) {
        self.deviceClass = deviceClass
        self.name = name
        self.appVersion = appVersion
        self.libraryID = libraryID
        self.canProcess = canProcess
        self.features = features
        self.syncDeviceID = syncDeviceID
        self.processing = processing
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
        // A newer build's capabilities this one can't read are unknown, never a reason to drop the rest.
        processing = (try? c.decodeIfPresent(LinkProcessingCapabilities.self, forKey: .processing)) ?? nil
    }
}

/// What a device does with its own models for other devices (`ProcessingCapabilities` in DaybookKit):
/// a Mac says so in its capabilities, so a phone knows which Macs can summarize what it sends them.
public struct LinkProcessingCapabilities: Codable, Sendable, Equatable {
    public var transcribes: Bool
    public var findsSpeakers: Bool
    public var summarizes: Bool
    /// The model it would use for each role (a role's name, "transcription", to the model's catalog key,
    /// "whisper/large-v3"). Nil when it didn't say.
    public var models: [String: String]?

    public init(transcribes: Bool, findsSpeakers: Bool, summarizes: Bool, models: [String: String]? = nil) {
        self.transcribes = transcribes
        self.findsSpeakers = findsSpeakers
        self.summarizes = summarizes
        self.models = models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcribes = try c.decodeIfPresent(Bool.self, forKey: .transcribes) ?? false
        findsSpeakers = try c.decodeIfPresent(Bool.self, forKey: .findsSpeakers) ?? false
        summarizes = try c.decodeIfPresent(Bool.self, forKey: .summarizes) ?? false
        models = (try? c.decodeIfPresent([String: String].self, forKey: .models)) ?? nil
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
    /// The recorders the sender manages (Soundcore Work), as it last knew them. Optional: older builds
    /// don't send it, and one this build can't read is dropped rather than the whole state.
    public var recorders: [LinkRecorderState]?
    /// A shared recording the sender takes part in only through its recorders, its own microphone not
    /// recording (an iPhone that couldn't start its microphone in the background while its Soundcore
    /// Work records). Optional: older builds neither send nor read it.
    public var sharedConversationID: UUID?

    public init(phase: Phase, conversationID: UUID? = nil, startedAt: Date? = nil, elapsed: TimeInterval = 0,
                sentAt: Date = Date(), recorders: [LinkRecorderState]? = nil, sharedConversationID: UUID? = nil) {
        self.phase = phase
        self.conversationID = conversationID
        self.startedAt = startedAt
        self.elapsed = elapsed
        self.sentAt = sentAt
        self.recorders = recorders
        self.sharedConversationID = sharedConversationID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decode(Phase.self, forKey: .phase)
        conversationID = try c.decodeIfPresent(UUID.self, forKey: .conversationID)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        elapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .elapsed) ?? 0
        sentAt = try c.decode(Date.self, forKey: .sentAt)
        recorders = try? c.decodeIfPresent([LinkRecorderState].self, forKey: .recorders)
        sharedConversationID = try? c.decodeIfPresent(UUID.self, forKey: .sharedConversationID)
    }

    /// Whether the sender takes part in recording this conversation: with its own microphone (recording,
    /// paused, or starting), or only through its recorders.
    public func takesPart(in conversation: UUID) -> Bool {
        (conversationID == conversation && phase != .idle && phase != .stopping) || sharedConversationID == conversation
    }
}

/// A recorder a device manages (Soundcore Work over Bluetooth), as that device last knew it, so the
/// other side can show it: "Soundcore Work · Recording since 10:02".
public struct LinkRecorderState: Codable, Sendable, Equatable {
    /// The device kind (`soundcore.work`) and its serial number, when known.
    public var kind: String
    public var serial: String?
    /// What the sender calls it.
    public var name: String?
    public var isRecording: Bool
    /// The recorder's ID for the recording it's making.
    public var recordingID: String?
    /// When that recording started, on the sender's clock.
    public var startedAt: Date?
    /// When the sender last confirmed this, on its clock.
    public var asOf: Date
    /// The conversation it records along with, when the sender knows.
    public var conversationID: UUID?

    public init(kind: String, serial: String? = nil, name: String? = nil, isRecording: Bool, recordingID: String? = nil,
                startedAt: Date? = nil, asOf: Date, conversationID: UUID? = nil) {
        self.kind = kind
        self.serial = serial
        self.name = name
        self.isRecording = isRecording
        self.recordingID = recordingID
        self.startedAt = startedAt
        self.asOf = asOf
        self.conversationID = conversationID
    }

    /// The same, with its times moved onto another clock (the receiver's).
    public func moved(by convert: (Date) -> Date) -> LinkRecorderState {
        var moved = self
        moved.startedAt = startedAt.map(convert)
        moved.asOf = convert(asOf)
        return moved
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
    /// Start (or stop) a recorder the receiver manages (Soundcore Work), not the receiver's own
    /// microphone. Sent only to a receiver whose capabilities list `recorderControlFeature`: an older
    /// one would record its own microphone instead.
    public var recorder: LinkRecorderTarget?
    /// The requester started recording and asks every device connected to it to join on its own
    /// (cascading start), rather than the person choosing this device. Optional: older builds treat
    /// the request as before.
    public var cascade: LinkCascade?

    public init(id: UUID = UUID(), action: Action, conversationID: UUID, timing: LinkTiming? = nil, sentAt: Date = Date(),
                title: String? = nil, date: Date? = nil, standalone: Bool? = nil, recorder: LinkRecorderTarget? = nil,
                cascade: LinkCascade? = nil) {
        self.id = id
        self.action = action
        self.conversationID = conversationID
        self.timing = timing
        self.sentAt = sentAt
        self.title = title
        self.date = date
        self.standalone = standalone
        self.recorder = recorder
        self.cascade = cascade
    }

    /// The receiver records a conversation of its own rather than alongside the requester.
    public var isStandalone: Bool {
        standalone == true || (action == .start && timing?.startedAt == nil && recorder == nil && cascade == nil)
    }
}

/// How a cascading start came about, so the receiver can join the same conversation and say why.
public struct LinkCascade: Codable, Sendable, Equatable {
    public struct Trigger: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The person started recording on the requester (or a Shortcut, the control, the Action button).
        public static let person: Self = "person"
        /// A recorder's own button started it (Soundcore Work, managed by the requester).
        public static let recorder: Self = "recorder"
        /// The requester detected a meeting and started on its own.
        public static let automatic: Self = "automatic"
        /// Another device asked the requester, which passes it on.
        public static let device: Self = "device"
    }

    public var trigger: Trigger
    /// The requester records the conversation with its own microphone. False when only its recorders
    /// do (an iPhone that couldn't start its microphone in the background): the receiver then doesn't
    /// expect a recording from the requester itself. Sent only to receivers that list `cascadeFeature`.
    public var requesterRecords: Bool
    /// The recorders recording along on the requester's side, as it knows them.
    public var recorders: [LinkRecorderState]?

    public init(trigger: Trigger, requesterRecords: Bool = true, recorders: [LinkRecorderState]? = nil) {
        self.trigger = trigger
        self.requesterRecords = requesterRecords
        self.recorders = recorders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try c.decodeIfPresent(Trigger.self, forKey: .trigger) ?? .person
        requesterRecords = try c.decodeIfPresent(Bool.self, forKey: .requesterRecords) ?? true
        recorders = try? c.decodeIfPresent([LinkRecorderState].self, forKey: .recorders)
    }
}

/// A recorder a record request is about: one the receiver manages over Bluetooth.
public struct LinkRecorderTarget: Codable, Sendable, Equatable {
    /// The device kind (`soundcore.work`) and its serial number, when known.
    public var kind: String
    public var serial: String?
    /// Stopping: the recording to stop, by the recorder's ID for it. One it's recording instead is left alone.
    public var recordingID: String?

    public init(kind: String, serial: String? = nil, recordingID: String? = nil) {
        self.kind = kind
        self.serial = serial
        self.recordingID = recordingID
    }
}

extension LinkCapabilities {
    /// Starts and stops the recorders it manages when another device asks (`LinkRecordRequest.recorder`).
    public static let recorderControlFeature = "recorderControl"
    /// Understands cascading starts and stops (`LinkRecordRequest.cascade`, a requester that records
    /// only through its recorders, `LinkRecordingState.sharedConversationID`), and accepts a stop from
    /// a device it records a conversation with.
    public static let cascadeFeature = "cascade"
    /// Takes notes and bookmark changes made on the other device during a shared recording (`note`,
    /// `bookmark.change`, and `bookmark` in both directions).
    public static let sharedNotesFeature = "sharedNotes"
    /// Shows the other device's live captions of a shared recording beside its own (`captions`).
    public static let liveCaptionsFeature = "liveCaptions"
    /// Counts down before summarizing and says so (`processing.progress` with `summaryCountdown`), and takes
    /// the person's choice from the other device (`processing.choice`: Use the Cloud, Start Now).
    public static let summaryPlacementFeature = "summaryPlacement"

    public var controlsRecorders: Bool { features.contains(Self.recorderControlFeature) }
    public var cascades: Bool { features.contains(Self.cascadeFeature) }
    public var sharesNotes: Bool { features.contains(Self.sharedNotesFeature) }
    public var showsCaptions: Bool { features.contains(Self.liveCaptionsFeature) }
    public var placesSummaries: Bool { features.contains(Self.summaryPlacementFeature) }
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
        /// A recorder it was asked to start or stop isn't nearby or didn't confirm.
        public static let recorderUnavailable: Self = "recorderUnavailable"
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

/// A bookmark changed on the sender during a shared recording: its label, or it was deleted. The
/// bookmark is the same item (`id`) on both devices and in the library, so the change also arrives
/// through sync later, with nothing doubled.
public struct LinkBookmarkChange: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    /// The label as it is now (nil when only deleted).
    public var label: String?
    public var deleted: Bool
    /// When it was changed, on the sender's clock: a receiver keeps the latest change of each bookmark.
    public var changedAt: Date

    public init(id: UUID, conversationID: UUID, label: String? = nil, deleted: Bool = false, changedAt: Date = Date()) {
        self.id = id
        self.conversationID = conversationID
        self.label = label
        self.deleted = deleted
        self.changedAt = changedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        changedAt = try c.decodeIfPresent(Date.self, forKey: .changedAt) ?? Date()
    }
}

/// One paragraph of the notes, written, edited, or deleted on the sender during a shared recording
/// (Floating Notes on a Mac, Write Notes on an iPhone). The paragraph is the same item on both devices
/// and in the library: its `id` is the note's anchor ID (`TimedNote.id`), so the copy the link brings
/// and the one sync brings later are one paragraph.
public struct LinkNote: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var text: String
    /// Its time in the conversation, as the sender files it (seconds; nil for a note made outside the
    /// recording). The receiver keeps exactly this, so both copies agree when they meet.
    public var time: TimeInterval?
    /// When it was first written, on the sender's clock: where the receiver shows it on its own
    /// recording while both record.
    public var madeAt: Date
    public var deleted: Bool
    /// When it was last changed, on the sender's clock: a receiver keeps the latest change of each note.
    public var changedAt: Date

    public init(id: UUID, conversationID: UUID, text: String, time: TimeInterval?, madeAt: Date = Date(), deleted: Bool = false,
                changedAt: Date = Date()) {
        self.id = id
        self.conversationID = conversationID
        self.text = text
        self.time = time
        self.madeAt = madeAt
        self.deleted = deleted
        self.changedAt = changedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        time = try c.decodeIfPresent(TimeInterval.self, forKey: .time)
        madeAt = try c.decodeIfPresent(Date.self, forKey: .madeAt) ?? Date()
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        changedAt = try c.decodeIfPresent(Date.self, forKey: .changedAt) ?? madeAt
    }
}

/// Live captions the sender is making of a shared recording, for a device recording it too to show
/// beside its own: the lines that changed since it last sent, by ID. Tentative feedback like every
/// live caption: never synced, never the transcript.
public struct LinkCaptions: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        /// Seconds into the sender's recording.
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
        public var isTentative: Bool
        /// The voice its live speaker model heard ("S2"), and the person it recognized.
        public var speakerSlot: String?
        public var speakerName: String?
        /// Heard by a recorder the sender manages ("Soundcore") rather than its own microphone.
        public var device: String?

        public init(id: UUID, start: TimeInterval, end: TimeInterval, text: String, isTentative: Bool,
                    speakerSlot: String? = nil, speakerName: String? = nil, device: String? = nil) {
            self.id = id; self.start = start; self.end = end; self.text = text; self.isTentative = isTentative
            self.speakerSlot = speakerSlot; self.speakerName = speakerName; self.device = device
        }
    }

    public var conversationID: UUID
    /// When the sender's recording began, on its clock: where its lines' times count from.
    public var startedAt: Date
    public var lines: [Line]
    public var sentAt: Date

    public init(conversationID: UUID, startedAt: Date, lines: [Line], sentAt: Date = Date()) {
        self.conversationID = conversationID; self.startedAt = startedAt; self.lines = lines; self.sentAt = sentAt
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
        /// The transcript is ready and the summary starts on the Mac when `countdown` runs out, unless the
        /// person chooses otherwise (`LinkSummaryChoice`). Sent only by a Mac listing `summaryPlacement`.
        public static let summaryCountdown: Self = "summaryCountdown"
    }

    public var meetingID: UUID
    public var phase: Phase
    /// 0...1 within the phase, when known.
    public var fraction: Double?
    public var macName: String
    /// The Mac's own words, for failures in particular.
    public var detail: String?
    /// While it counts down (`summaryCountdown`): how long is left and what the person may choose. Optional:
    /// older builds neither send nor read it.
    public var countdown: LinkSummaryCountdown?
    /// Summarizing in the cloud: the model's name ("Claude Sonnet 5.5"). Optional, as `countdown`.
    public var cloudModel: String?

    public init(meetingID: UUID, phase: Phase, fraction: Double? = nil, macName: String, detail: String? = nil,
                countdown: LinkSummaryCountdown? = nil, cloudModel: String? = nil) {
        self.meetingID = meetingID
        self.phase = phase
        self.fraction = fraction
        self.macName = macName
        self.detail = detail
        self.countdown = countdown
        self.cloudModel = cloudModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try c.decode(UUID.self, forKey: .meetingID)
        phase = try c.decode(Phase.self, forKey: .phase)
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
        macName = try c.decode(String.self, forKey: .macName)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        countdown = (try? c.decodeIfPresent(LinkSummaryCountdown.self, forKey: .countdown)) ?? nil
        cloudModel = (try? c.decodeIfPresent(String.self, forKey: .cloudModel)) ?? nil
    }
}

/// A Mac's countdown before it summarizes a conversation, as it sends it to a phone.
public struct LinkSummaryCountdown: Codable, Sendable, Equatable {
    /// Seconds left when it was sent; the phone counts on from when it arrives.
    public var secondsLeft: Double
    /// Use the Cloud is on offer there (a key, and the policy isn't Never).
    public var cloudOffered: Bool

    public init(secondsLeft: Double, cloudOffered: Bool) {
        self.secondsLeft = secondsLeft
        self.cloudOffered = cloudOffered
    }
}

/// The person's choice, on a phone, for a summary a Mac counts down to: Use the Cloud, or Start Now. The Mac
/// acts on it as if the person had chosen there; a choice for a countdown that has ended does nothing.
public struct LinkSummaryChoice: Codable, Sendable, Equatable {
    public struct Choice: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let useCloud: Self = "useCloud"
        public static let startNow: Self = "startNow"
    }

    public var meetingID: UUID
    public var choice: Choice
    /// When it was made, on the sender's clock.
    public var sentAt: Date

    public init(meetingID: UUID, choice: Choice, sentAt: Date = Date()) {
        self.meetingID = meetingID
        self.choice = choice
        self.sentAt = sentAt
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
    /// An encrypted library's key (LinkLibraryKey.swift): asked for by a device waiting for it, and sent by one that
    /// holds it.
    case libraryKeyRequest(LinkLibraryKeyRequest)
    case libraryKeyGrant(LinkLibraryKeyGrant)
    /// Notes and bookmarks during a shared recording: a paragraph written, edited, or deleted, and a
    /// bookmark's label changed or the bookmark deleted (a new bookmark is `bookmark`). Additive within
    /// version 1: an older build ignores them.
    case note(LinkNote)
    case bookmarkChange(LinkBookmarkChange)
    /// Live captions of a shared recording, for a device that shows them (`liveCaptionsFeature`).
    /// Additive within version 1: an older build ignores them.
    case captions(LinkCaptions)
    /// The person's choice on a phone for a summary a Mac counts down to (`summaryPlacementFeature`).
    /// Additive within version 1: an older build ignores it.
    case summaryChoice(LinkSummaryChoice)
}
