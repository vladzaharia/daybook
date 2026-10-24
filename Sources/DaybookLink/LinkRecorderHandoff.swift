import Foundation

// Recorder handoff: moving a recorder (Soundcore Work) between a Mac and an iPhone in seconds when
// both are on the link (docs/devices.md, "Handing a recorder over"). A recorder talks to one device
// at a time, and who manages it is a synced library setting; these messages only make the change
// fast. Without the link, the same request travels through sync.
//
//   requester                      owner
//   recorder.handoff.request  →
//                             ←    recorder.handoff.reply   accepted (what it finishes first) or refused (why)
//                             ←    recorder.release         once it has let go: what was still waiting to import
//
// Additive within protocol version 1: older builds ignore the types, so a requester that hears no
// reply falls back to sync.

/// A device in a handoff, by its sync replica ID: the identity the library's ownership records use
/// (link device IDs differ from it on the iPhone).
public struct LinkHandoffDevice: Codable, Sendable, Equatable {
    /// `LibrarySyncController.deviceID`.
    public var syncID: String
    /// "Alex’s iPhone", "Studio Mac".
    public var name: String
    public var deviceClass: LinkDeviceClass

    public init(syncID: String, name: String, deviceClass: LinkDeviceClass) {
        self.syncID = syncID
        self.name = name
        self.deviceClass = deviceClass
    }
}

/// "Let me have this recorder" (`take`), or "please take this recorder" (`give`, sent by its owner).
/// Sending the same `id` again is safe: the receiver answers a repeat with its first reply.
public struct LinkRecorderHandoffRequest: Codable, Sendable, Equatable, Identifiable {
    public struct Intent: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The requester wants the recorder; the receiver owns it and lets go.
        public static let take: Self = "take"
        /// The requester owns the recorder and offers it; the receiver takes it if it has it set up.
        public static let give: Self = "give"
    }

    public var id: UUID
    public var intent: Intent
    /// The device kind (`soundcore.work`) and the recorder's serial: the identity every device shares.
    public var kind: String
    public var serial: String
    /// "Soundcore Work", for the receiver's words.
    public var recorderName: String
    /// The sync ID of the device this is meant for (the owner for `take`), so a device that isn't it
    /// says so instead of acting.
    public var addressedTo: String
    public var requester: LinkHandoffDevice
    /// When this was sent, on the requester's clock.
    public var sentAt: Date

    public init(id: UUID = UUID(), intent: Intent = .take, kind: String, serial: String, recorderName: String,
                addressedTo: String, requester: LinkHandoffDevice, sentAt: Date = Date()) {
        self.id = id
        self.intent = intent
        self.kind = kind
        self.serial = serial
        self.recorderName = recorderName
        self.addressedTo = addressedTo
        self.requester = requester
        self.sentAt = sentAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        intent = try c.decodeIfPresent(Intent.self, forKey: .intent) ?? .take
        kind = try c.decode(String.self, forKey: .kind)
        serial = try c.decode(String.self, forKey: .serial)
        recorderName = try c.decodeIfPresent(String.self, forKey: .recorderName) ?? "Recorder"
        addressedTo = try c.decode(String.self, forKey: .addressedTo)
        requester = try c.decode(LinkHandoffDevice.self, forKey: .requester)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
    }
}

/// The receiver agreed and is letting go (or, for `give`, will take the recorder).
public struct LinkRecorderHandoffAck: Codable, Sendable, Equatable {
    /// What the owner finishes before it lets go.
    public struct Finishing: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// A transfer that can't resume elsewhere (it would start again from the beginning).
        public static let `import`: Self = "import"
        /// Listen Live, which stops and saves what arrived.
        public static let liveListening: Self = "liveListening"
    }

    public var finishing: Finishing?
    /// "Today, 10:02 AM": the recording being imported.
    public var finishingTitle: String?
    /// The owner's estimate, when it has one.
    public var secondsLeft: TimeInterval?
    /// The recorder is recording; it keeps recording, and record control moves with ownership.
    public var recorderIsRecording: Bool?

    public init(finishing: Finishing? = nil, finishingTitle: String? = nil, secondsLeft: TimeInterval? = nil,
                recorderIsRecording: Bool? = nil) {
        self.finishing = finishing
        self.finishingTitle = finishingTitle
        self.secondsLeft = secondsLeft
        self.recorderIsRecording = recorderIsRecording
    }
}

/// The receiver won't hand the recorder over, and why.
public struct LinkRecorderHandoffRefusal: Codable, Sendable, Equatable {
    public struct Reason: LinkOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The receiver doesn't manage this recorder (`ownerName` says who does, when it knows).
        public static let notOwner: Self = "notOwner"
        /// The receiver has no such recorder set up (a `give` to a device that can't take it).
        public static let notSetUp: Self = "notSetUp"
        /// Another handoff of this recorder is under way.
        public static let busy: Self = "busy"
        /// The person said no.
        public static let declined: Self = "declined"
        /// This device doesn't hand recorders over.
        public static let unsupported: Self = "unsupported"
    }

    public var reason: Reason
    /// Words to show, when the receiver has better ones than the reason.
    public var message: String?
    /// Who manages the recorder, as far as the receiver knows.
    public var ownerName: String?

    public init(reason: Reason, message: String? = nil, ownerName: String? = nil) {
        self.reason = reason
        self.message = message
        self.ownerName = ownerName
    }
}

/// The answer to a `LinkRecorderHandoffRequest`.
public struct LinkRecorderHandoffReply: Codable, Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case accepted(LinkRecorderHandoffAck)
        case refused(LinkRecorderHandoffRefusal)
    }

    public var requestID: UUID
    public var outcome: Outcome
    /// Who answered.
    public var from: LinkHandoffDevice?
    public var sentAt: Date

    public init(requestID: UUID, outcome: Outcome, from: LinkHandoffDevice? = nil, sentAt: Date = Date()) {
        self.requestID = requestID
        self.outcome = outcome
        self.from = from
        self.sentAt = sentAt
    }

    private enum CodingKeys: String, CodingKey { case requestID, accepted, refused, from, sentAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        from = try c.decodeIfPresent(LinkHandoffDevice.self, forKey: .from)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
        if let ack = try c.decodeIfPresent(LinkRecorderHandoffAck.self, forKey: .accepted) {
            outcome = .accepted(ack)
        } else {
            // An answer this build can't read is a refusal, never a silent yes.
            outcome = .refused(try c.decodeIfPresent(LinkRecorderHandoffRefusal.self, forKey: .refused)
                ?? LinkRecorderHandoffRefusal(reason: "unknown"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encode(sentAt, forKey: .sentAt)
        switch outcome {
        case .accepted(let ack): try c.encode(ack, forKey: .accepted)
        case .refused(let refusal): try c.encode(refusal, forKey: .refused)
        }
    }
}

/// A recording that was waiting to import on the old owner; the new owner imports it.
public struct LinkHandoffImport: Codable, Sendable, Equatable {
    /// The recorder's stable recording ID (a Soundcore start time).
    public var recordingID: String
    /// The conversation to add it to, when one was chosen.
    public var attachTo: UUID?
    /// Queued by automatic import rather than by the person.
    public var isAutomatic: Bool

    public init(recordingID: String, attachTo: UUID? = nil, isAutomatic: Bool = false) {
        self.recordingID = recordingID
        self.attachTo = attachTo
        self.isAutomatic = isAutomatic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordingID = try c.decode(String.self, forKey: .recordingID)
        attachTo = try c.decodeIfPresent(UUID.self, forKey: .attachTo)
        isAutomatic = try c.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? false
    }
}

/// "I've let go": the old owner finished what couldn't move, disconnected, and recorded the new
/// owner. Sent after an accepted request (`requestID`), or unprompted when a recorder was taken over.
public struct LinkRecorderRelease: Codable, Sendable, Equatable {
    public var requestID: UUID?
    public var kind: String
    public var serial: String
    public var newOwner: LinkHandoffDevice
    public var releasedAt: Date
    /// Recordings that were waiting to import, for the new owner to import.
    public var pendingImports: [LinkHandoffImport]
    /// Recordings the old owner imported that may not have synced yet, so the new owner doesn't import
    /// them a second time while they travel.
    public var importedRecordingIDs: [String]
    /// The recorder was recording when it was let go; it keeps recording.
    public var recorderIsRecording: Bool?

    public init(requestID: UUID?, kind: String, serial: String, newOwner: LinkHandoffDevice, releasedAt: Date = Date(),
                pendingImports: [LinkHandoffImport] = [], importedRecordingIDs: [String] = [], recorderIsRecording: Bool? = nil) {
        self.requestID = requestID
        self.kind = kind
        self.serial = serial
        self.newOwner = newOwner
        self.releasedAt = releasedAt
        self.pendingImports = pendingImports
        self.importedRecordingIDs = importedRecordingIDs
        self.recorderIsRecording = recorderIsRecording
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decodeIfPresent(UUID.self, forKey: .requestID)
        kind = try c.decode(String.self, forKey: .kind)
        serial = try c.decode(String.self, forKey: .serial)
        newOwner = try c.decode(LinkHandoffDevice.self, forKey: .newOwner)
        releasedAt = try c.decodeIfPresent(Date.self, forKey: .releasedAt) ?? Date()
        pendingImports = try c.decodeIfPresent([LinkHandoffImport].self, forKey: .pendingImports) ?? []
        importedRecordingIDs = try c.decodeIfPresent([String].self, forKey: .importedRecordingIDs) ?? []
        recorderIsRecording = try c.decodeIfPresent(Bool.self, forKey: .recorderIsRecording)
    }
}

extension LinkCapabilities {
    /// The capability feature a device advertises when it understands the recorder handoff messages.
    public static let recorderHandoffFeature = "recorderHandoff"

    /// Whether the peer understands `recorder.handoff.*` and `recorder.release`.
    public var handsOffRecorders: Bool { features.contains(Self.recorderHandoffFeature) }
}
