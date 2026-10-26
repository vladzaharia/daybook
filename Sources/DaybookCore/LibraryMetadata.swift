import Foundation

public struct LibraryFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

/// Per-item versions avoid losing an unrelated folder or template edited on another Mac.
/// A nil value is a durable deletion marker, including for vocabulary entries.
public struct LibraryValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var id: String
    public var value: Value?
    public var modifiedAt: Date
    public init(id: String, value: Value?, modifiedAt: Date = Date()) {
        self.id = id; self.value = value; self.modifiedAt = modifiedAt
    }
}

/// Which device manages a recorder over Bluetooth (docs/iphone.md, "One Bluetooth owner per recorder").
/// A recorder talks to one device at a time, so the phone and a Mac must not both reach for it: the
/// owner connects and imports, and every other device shows "Managed by …" and gets the recordings
/// through sync. No record means nobody claimed it, and every device behaves as before.
public struct RecorderOwnership: Codable, Equatable, Sendable {
    /// The device kind, `soundcore.work`.
    public var kind: String
    /// The recorder's serial number: the only identity every device sees the same way (Bluetooth
    /// identifiers differ per device).
    public var serial: String
    /// The owner's sync device ID (`LibrarySyncController.deviceID`).
    public var ownerID: String
    /// "Alex's iPhone", "Studio Mac".
    public var ownerName: String
    @Extensible public var ownerClass: SyncDeviceClass
    public var claimedAt: Date

    public init(kind: String, serial: String, ownerID: String, ownerName: String, ownerClass: SyncDeviceClass, claimedAt: Date = Date()) {
        self.kind = kind; self.serial = serial; self.ownerID = ownerID; self.ownerName = ownerName
        self.ownerClass = ownerClass; self.claimedAt = claimedAt
    }

    /// The record's key in `LibraryMetadata.recorders`.
    public static func id(kind: String, serial: String) -> String { "\(kind)|\(serial)" }
    public var id: String { Self.id(kind: kind, serial: serial) }
}

/// A recorder moving from one device to another through sync, when the two aren't on the local link
/// (docs/devices.md, "Handing a recorder over"). The requester writes it; the owner answers in it;
/// the new owner clears it once it has taken over. One per recorder, keyed like `RecorderOwnership`.
public struct RecorderHandoffRecord: Codable, Equatable, Sendable {
    /// Where the handoff is. Raw values are stored in the library and must not change.
    public enum Phase: String, Codable, Sendable {
        /// The requester asked; the owner hasn't answered yet.
        case requested
        /// The owner accepted and is finishing what can't move (an import in progress).
        case releasing
        /// The owner let go: the new owner claims the recorder and connects.
        case released
        /// The owner said no (`message` says why).
        case refused
        /// The requester changed its mind.
        case cancelled

        public init(from decoder: Decoder) throws {
            // A phase from a later version is treated as still waiting, never as a release.
            self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .requested
        }
    }

    /// A recording that was waiting to import on the old owner.
    public struct PendingImport: Codable, Equatable, Sendable {
        public var recordingID: String
        public var attachTo: UUID?
        public var isAutomatic: Bool

        public init(recordingID: String, attachTo: UUID? = nil, isAutomatic: Bool = false) {
            self.recordingID = recordingID; self.attachTo = attachTo; self.isAutomatic = isAutomatic
        }
    }

    /// The request's ID; the link messages for the same handoff carry it too.
    public var id: UUID
    public var kind: String
    public var serial: String
    /// The device asked to let go (sync device ID) and its name.
    public var ownerID: String
    public var ownerName: String
    /// The device that will manage the recorder.
    public var requesterID: String
    public var requesterName: String
    @Extensible public var requesterClass: SyncDeviceClass
    @Extensible public var phase: Phase
    /// A refusal's words.
    public var message: String?
    /// With `released`: recordings the new owner should import, and recordings the old owner imported
    /// that may still be on their way through sync (so they aren't imported twice).
    public var pendingImports: [PendingImport]?
    public var importedRecordingIDs: [String]?
    /// With `released`: the recorder was recording, and keeps recording.
    public var recorderIsRecording: Bool?
    public var requestedAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), kind: String, serial: String, ownerID: String, ownerName: String, requesterID: String,
                requesterName: String, requesterClass: SyncDeviceClass, phase: Phase = .requested, message: String? = nil,
                pendingImports: [PendingImport]? = nil, importedRecordingIDs: [String]? = nil, recorderIsRecording: Bool? = nil,
                requestedAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.serial = serial
        self.ownerID = ownerID; self.ownerName = ownerName
        self.requesterID = requesterID; self.requesterName = requesterName; self.requesterClass = requesterClass
        self.phase = phase; self.message = message
        self.pendingImports = pendingImports; self.importedRecordingIDs = importedRecordingIDs
        self.recorderIsRecording = recorderIsRecording
        self.requestedAt = requestedAt; self.updatedAt = updatedAt ?? requestedAt
    }

    /// The record's key in `LibraryMetadata.handoffs`: the recorder's.
    public var recorderID: String { RecorderOwnership.id(kind: kind, serial: serial) }
}

public struct LibraryMetadata: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var folders: [LibraryValue<LibraryFolder>] = []
    public var templates: [LibraryValue<SummaryTemplate>] = []
    public var vocabulary: [LibraryValue<GlossaryTerm>] = []
    /// Who manages each recorder, by `RecorderOwnership.id`. Optional, so library files and journal
    /// metadata written before ownership existed still decode; Daybook versions without it ignore it.
    public var recorders: [LibraryValue<RecorderOwnership>]?
    /// Recorder handoffs travelling through sync, by recorder (`RecorderOwnership.id`). Optional, like
    /// `recorders`, so earlier files decode and earlier versions ignore it.
    public var handoffs: [LibraryValue<RecorderHandoffRecord>]?
    public init() {}

    public func merging(_ other: Self) -> Self {
        var value = self
        value.folders = Self.merge(folders, other.folders)
        value.templates = Self.merge(templates, other.templates)
        value.vocabulary = Self.merge(vocabulary, other.vocabulary)
        if recorders != nil || other.recorders != nil { value.recorders = Self.merge(recorders ?? [], other.recorders ?? []) }
        if handoffs != nil || other.handoffs != nil { value.handoffs = Self.merge(handoffs ?? [], other.handoffs ?? []) }
        return value
    }

    /// Handoffs under way or answered (cleared ones left out).
    public var recorderHandoffs: [RecorderHandoffRecord] { (handoffs ?? []).compactMap(\.value) }

    public func recorderHandoff(kind: String, serial: String) -> RecorderHandoffRecord? {
        let id = RecorderOwnership.id(kind: kind, serial: serial)
        return handoffs?.first { $0.id == id }?.value
    }

    /// Recorders some device manages (deletion markers left out).
    public var recorderOwners: [RecorderOwnership] { (recorders ?? []).compactMap(\.value) }

    public func recorderOwner(kind: String, serial: String) -> RecorderOwnership? {
        let id = RecorderOwnership.id(kind: kind, serial: serial)
        return recorders?.first { $0.id == id }?.value
    }

    private static func merge<T>(_ lhs: [LibraryValue<T>], _ rhs: [LibraryValue<T>]) -> [LibraryValue<T>] {
        var entries: [String: LibraryValue<T>] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for candidate in lhs + rhs {
            if let old = entries[candidate.id] {
                if old.modifiedAt > candidate.modifiedAt { continue }
                if old.modifiedAt == candidate.modifiedAt {
                    // Equal clocks resolve identically regardless of device ordering; deletion wins ties.
                    if old.value == nil { continue }
                    if candidate.value != nil {
                        let a = (try? encoder.encode(old)) ?? Data(), b = (try? encoder.encode(candidate)) ?? Data()
                        if !a.lexicographicallyPrecedes(b) { continue }
                    }
                }
            }
            entries[candidate.id] = candidate
        }
        return entries.values.sorted { $0.id < $1.id }
    }
}
