import Foundation

public struct LibraryFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try unknownFields.encode(to: encoder)
    }
}

/// Per-item versions avoid losing an unrelated folder or template edited on another Mac.
/// A nil value is a durable deletion marker, including for vocabulary entries.
public struct LibraryValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var id: String
    public var value: Value? { didSet { unreadableValue = nil } }
    public var modifiedAt: Date
    /// A value a newer Daybook wrote in a shape this version can't read. It isn't shown here (`value` is nil),
    /// isn't a deletion, and is written back exactly as it came, so this device never drops it for the others.
    public private(set) var unreadableValue: SyncJSONValue?
    /// Keys a newer Daybook wrote beside the value that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()
    public init(id: String, value: Value?, modifiedAt: Date = Date()) {
        self.id = id; self.value = value; self.modifiedAt = modifiedAt
    }

    /// A deletion marker, as opposed to a value this version can't read.
    public var isDeletion: Bool { value == nil && unreadableValue == nil }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, value, modifiedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        do { value = try values.decodeIfPresent(Value.self, forKey: .value) }
        catch { value = nil; unreadableValue = try values.decode(SyncJSONValue.self, forKey: .value) }
        unknownFields = try UnknownFields(from: decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(modifiedAt, forKey: .modifiedAt)
        if let unreadableValue { try values.encode(unreadableValue, forKey: .value) } else { try values.encodeIfPresent(value, forKey: .value) }
        try unknownFields.encode(to: encoder)
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
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(kind: String, serial: String, ownerID: String, ownerName: String, ownerClass: SyncDeviceClass, claimedAt: Date = Date()) {
        self.kind = kind; self.serial = serial; self.ownerID = ownerID; self.ownerName = ownerName
        self.ownerClass = ownerClass; self.claimedAt = claimedAt
    }

    /// The record's key in `LibraryMetadata.recorders`.
    public static func id(kind: String, serial: String) -> String { "\(kind)|\(serial)" }
    public var id: String { Self.id(kind: kind, serial: serial) }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, serial, ownerID, ownerName, ownerClass, claimedAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        serial = try values.decode(String.self, forKey: .serial)
        ownerID = try values.decode(String.self, forKey: .ownerID)
        ownerName = try values.decode(String.self, forKey: .ownerName)
        _ownerClass = try values.decode(Extensible<SyncDeviceClass>.self, forKey: .ownerClass)
        claimedAt = try values.decode(Date.self, forKey: .claimedAt)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(serial, forKey: .serial)
        try values.encode(ownerID, forKey: .ownerID)
        try values.encode(ownerName, forKey: .ownerName)
        try values.encode(_ownerClass, forKey: .ownerClass)
        try values.encode(claimedAt, forKey: .claimedAt)
        try unknownFields.encode(to: encoder)
    }
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
        /// For `recordingInProgress`: Daybook started it for `attachTo`'s recording, which is still going,
        /// so the new owner stops it when that recording ends. Optional, so earlier records decode and
        /// earlier versions ignore it.
        public var stopsWithConversation: Bool?

        public init(recordingID: String, attachTo: UUID? = nil, isAutomatic: Bool = false, stopsWithConversation: Bool? = nil) {
            self.recordingID = recordingID; self.attachTo = attachTo; self.isAutomatic = isAutomatic
            self.stopsWithConversation = stopsWithConversation
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
    /// With `released`: the recording it was making, and the conversation waiting for it. Optional,
    /// so earlier records decode and earlier versions ignore it.
    public var recordingInProgress: PendingImport?
    public var requestedAt: Date
    public var updatedAt: Date
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, serial, ownerID, ownerName, requesterID, requesterName, requesterClass, phase, message,
            pendingImports, importedRecordingIDs, recorderIsRecording, recordingInProgress, requestedAt, updatedAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(String.self, forKey: .kind)
        serial = try values.decode(String.self, forKey: .serial)
        ownerID = try values.decode(String.self, forKey: .ownerID)
        ownerName = try values.decode(String.self, forKey: .ownerName)
        requesterID = try values.decode(String.self, forKey: .requesterID)
        requesterName = try values.decode(String.self, forKey: .requesterName)
        _requesterClass = try values.decode(Extensible<SyncDeviceClass>.self, forKey: .requesterClass)
        _phase = try values.decode(Extensible<Phase>.self, forKey: .phase)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        pendingImports = try values.decodeIfPresent([PendingImport].self, forKey: .pendingImports)
        importedRecordingIDs = try values.decodeIfPresent([String].self, forKey: .importedRecordingIDs)
        recorderIsRecording = try values.decodeIfPresent(Bool.self, forKey: .recorderIsRecording)
        recordingInProgress = try values.decodeIfPresent(PendingImport.self, forKey: .recordingInProgress)
        requestedAt = try values.decode(Date.self, forKey: .requestedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(serial, forKey: .serial)
        try values.encode(ownerID, forKey: .ownerID)
        try values.encode(ownerName, forKey: .ownerName)
        try values.encode(requesterID, forKey: .requesterID)
        try values.encode(requesterName, forKey: .requesterName)
        try values.encode(_requesterClass, forKey: .requesterClass)
        try values.encode(_phase, forKey: .phase)
        try values.encodeIfPresent(message, forKey: .message)
        try values.encodeIfPresent(pendingImports, forKey: .pendingImports)
        try values.encodeIfPresent(importedRecordingIDs, forKey: .importedRecordingIDs)
        try values.encodeIfPresent(recorderIsRecording, forKey: .recorderIsRecording)
        try values.encodeIfPresent(recordingInProgress, forKey: .recordingInProgress)
        try values.encode(requestedAt, forKey: .requestedAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try unknownFields.encode(to: encoder)
    }
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
    /// People Daybook knows by voice, by `SpeakerProfile.id`, and their voiceprints, one record each by
    /// `Voiceprint.id`, so two devices teaching one profile keep every voiceprint (SpeakerProfiles.swift).
    /// Optional, like `recorders`, so earlier files decode and earlier versions keep them as they came.
    public var speakerProfiles: [LibraryValue<SpeakerProfile>]?
    public var voiceprints: [LibraryValue<Voiceprint>]?
    /// Settings a newer Daybook keeps under keys this version doesn't know, written back as they came
    /// and merged by `merging` (a list of per-item records item by item).
    public var unknownFields = UnknownFields()
    public init() {}

    public func merging(_ other: Self) -> Self {
        var value = self
        value.folders = Self.merge(folders, other.folders)
        value.templates = Self.merge(templates, other.templates)
        value.vocabulary = Self.merge(vocabulary, other.vocabulary)
        if recorders != nil || other.recorders != nil { value.recorders = Self.merge(recorders ?? [], other.recorders ?? []) }
        if handoffs != nil || other.handoffs != nil { value.handoffs = Self.merge(handoffs ?? [], other.handoffs ?? []) }
        if speakerProfiles != nil || other.speakerProfiles != nil {
            value.speakerProfiles = Self.merge(speakerProfiles ?? [], other.speakerProfiles ?? [])
        }
        if voiceprints != nil || other.voiceprints != nil { value.voiceprints = Self.merge(voiceprints ?? [], other.voiceprints ?? []) }
        var unknown: [String: SyncJSONValue] = [:]
        for key in Set(unknownFields.values.keys).union(other.unknownFields.values.keys) {
            switch (unknownFields[key], other.unknownFields[key]) {
            case let (a?, b?): unknown[key] = SyncJSONValue.mergedLibrarySetting(a, b)
            case let (a, b): unknown[key] = a ?? b
            }
        }
        value.unknownFields = UnknownFields(unknown)
        return value
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, folders, templates, vocabulary, recorders, handoffs, speakerProfiles, voiceprints
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        folders = try values.decode([LibraryValue<LibraryFolder>].self, forKey: .folders)
        templates = try values.decode([LibraryValue<SummaryTemplate>].self, forKey: .templates)
        vocabulary = try values.decode([LibraryValue<GlossaryTerm>].self, forKey: .vocabulary)
        recorders = try values.decodeIfPresent([LibraryValue<RecorderOwnership>].self, forKey: .recorders)
        handoffs = try values.decodeIfPresent([LibraryValue<RecorderHandoffRecord>].self, forKey: .handoffs)
        speakerProfiles = try values.decodeIfPresent([LibraryValue<SpeakerProfile>].self, forKey: .speakerProfiles)
        voiceprints = try values.decodeIfPresent([LibraryValue<Voiceprint>].self, forKey: .voiceprints)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(folders, forKey: .folders)
        try values.encode(templates, forKey: .templates)
        try values.encode(vocabulary, forKey: .vocabulary)
        try values.encodeIfPresent(recorders, forKey: .recorders)
        try values.encodeIfPresent(handoffs, forKey: .handoffs)
        try values.encodeIfPresent(speakerProfiles, forKey: .speakerProfiles)
        try values.encodeIfPresent(voiceprints, forKey: .voiceprints)
        try unknownFields.encode(to: encoder)
    }

    /// Some settings were written by a newer Daybook in a shape this version can't read.
    public var hasUnreadableValues: Bool {
        folders.contains { $0.unreadableValue != nil } || templates.contains { $0.unreadableValue != nil }
            || vocabulary.contains { $0.unreadableValue != nil } || (recorders ?? []).contains { $0.unreadableValue != nil }
            || (handoffs ?? []).contains { $0.unreadableValue != nil }
            || (speakerProfiles ?? []).contains { $0.unreadableValue != nil } || (voiceprints ?? []).contains { $0.unreadableValue != nil }
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

    /// Speaker profiles (deletion markers, ones merged into another, and ones a newer Daybook wrote
    /// left out), by name.
    public var activeSpeakerProfiles: [SpeakerProfile] {
        let merges = speakerProfileMerges
        return (speakerProfiles ?? []).compactMap(\.value).filter { merges.isActive($0.id) }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedSame ? $0.id.uuidString < $1.id.uuidString
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Which profile each profile ID stands for, after merges.
    public var speakerProfileMerges: SpeakerProfileMerges { SpeakerProfileMerges(speakerProfiles ?? []) }

    /// The profile `id` stands for: itself, or the profile it was merged into.
    public func speakerProfile(_ id: UUID) -> SpeakerProfile? {
        guard let target = speakerProfileMerges.resolve(id) else { return nil }
        return speakerProfiles?.first { $0.id == target.uuidString }?.value
    }

    /// A profile's voiceprints (those of profiles merged into it too), newest first.
    public func voiceprints(of profileID: UUID) -> [Voiceprint] {
        let members = speakerProfileMerges.members(of: profileID)
        return (voiceprints ?? []).compactMap(\.value).filter { members.contains($0.profileID) }
            .sorted { $0.recordedAt == $1.recordedAt ? $0.id < $1.id : $0.recordedAt > $1.recordedAt }
    }

    /// Every voiceprint, each under the profile it stands for now (merges followed).
    public var resolvedVoiceprints: [Voiceprint] {
        let merges = speakerProfileMerges
        return (voiceprints ?? []).compactMap(\.value).map { print in
            var print = print
            if let target = merges.resolve(print.profileID) { print.profileID = target }
            return print
        }
    }

    static func merge<T>(_ lhs: [LibraryValue<T>], _ rhs: [LibraryValue<T>]) -> [LibraryValue<T>] {
        var entries: [String: LibraryValue<T>] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for candidate in lhs + rhs {
            if let old = entries[candidate.id] {
                if old.modifiedAt > candidate.modifiedAt { continue }
                if old.modifiedAt == candidate.modifiedAt {
                    // Equal clocks resolve identically regardless of device ordering; deletion wins ties.
                    if old.isDeletion { continue }
                    if !candidate.isDeletion {
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
