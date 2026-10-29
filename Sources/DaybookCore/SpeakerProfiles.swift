import Foundation

// Speaker profiles (docs/architecture.md, "Speakers and profiles"): people Daybook knows by voice
// across conversations. A profile is a name plus voiceprints, the voice embeddings of speakers the
// person named (or confirmed) and of speakers Daybook recognized with high confidence. Both are
// library settings (`LibraryMetadata.speakerProfiles`, `.voiceprints`), one record per item, so two
// devices that teach the same profile keep every voiceprint. Each conversation says which of its
// speakers is which profile, and how that was decided (`Meeting.speakerIdentities`).

/// A person Daybook recognizes by voice.
public struct SpeakerProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// The profile this one was merged into (the same person): everything that names this profile
    /// (voiceprints, speakers' identities, a name that started it) stands for that one instead
    /// (`SpeakerProfileMerges`). The record stays, with its name, so the name still finds the person.
    public var mergedInto: UUID?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(id: UUID, name: String, createdAt: Date = Date(), mergedInto: UUID? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.mergedInto = mergedInto
    }

    /// The profile a name starts: the same name gives the same ID on every device, so two devices
    /// that name the same person before they sync teach one profile.
    public static func id(forName name: String) -> UUID { SyncEncoding.uuid("speaker-profile:\(normalizedName(name))") }

    /// Names compare without case, accents, or extra spaces.
    public static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "Speaker 3" and empty names are placeholders, never a person.
    public static func isPlaceholder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard trimmed.hasPrefix("Speaker ") else { return false }
        let number = trimmed.dropFirst("Speaker ".count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, name, createdAt, mergedInto }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        mergedInto = try values.decodeIfPresent(UUID.self, forKey: .mergedInto)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(mergedInto, forKey: .mergedInto)
        try unknownFields.encode(to: encoder)
    }
}

/// Which profile each profile ID stands for now. Merging one profile into another (the same person,
/// named two ways) writes a single record, the merged profile with `mergedInto`, so it's safe through
/// sync: voiceprints and identities another device adds to the merged profile meanwhile follow it
/// when the merge arrives, and nothing has to be rewritten for them to. Chains are followed to the
/// end. Two devices merging each profile into the other make a cycle; the merge made first is set
/// aside, so the later choice stands, the same on every device. A profile merged into one that was
/// deleted is gone too.
public struct SpeakerProfileMerges: Sendable {
    /// Every profile ID with a record, and the active profile it stands for (nil: deleted).
    private var targets: [UUID: UUID] = [:]

    public init(_ records: [LibraryValue<SpeakerProfile>]) {
        var latest: [String: LibraryValue<SpeakerProfile>] = [:]
        for record in records where latest[record.id].map({ $0.modifiedAt < record.modifiedAt }) ?? true { latest[record.id] = record }
        var byID: [UUID: (profile: SpeakerProfile, modifiedAt: Date)] = [:]
        for record in latest.values {
            if let profile = record.value { byID[profile.id] = (profile, record.modifiedAt) }
        }
        for id in byID.keys {
            var path: [UUID] = [], current = id
            while true {
                guard let entry = byID[current] else { break }
                guard let next = entry.profile.mergedInto, next != current else { targets[id] = current; break }
                if let start = path.firstIndex(of: current) {
                    // A cycle: the merge made first is set aside; its profile stays.
                    let cycle = path[start...]
                    targets[id] = cycle.min { a, b in
                        let x = byID[a]!.modifiedAt, y = byID[b]!.modifiedAt
                        return x == y ? a.uuidString < b.uuidString : x < y
                    }
                    break
                }
                path.append(current)
                current = next
            }
        }
    }

    /// The active profile `id` stands for: itself, the profile it was merged into, or nil when that
    /// profile (or this one) was deleted or isn't known here.
    public func resolve(_ id: UUID) -> UUID? { targets[id] }

    /// Whether `id` is a profile of its own (not merged into another, not deleted).
    public func isActive(_ id: UUID) -> Bool { targets[id] == id }

    /// Profile IDs that stand for `id`, itself included.
    public func members(of id: UUID) -> Set<UUID> { Set(targets.filter { $0.value == id }.keys).union([id]) }
}

/// A voice embedding and the space it lives in. Embeddings from different spaces (models, or
/// conversions of one) are never compared. Stored as IEEE half floats in base64, so a 256-value
/// embedding takes 684 characters; the vector is rounded to half precision when it's made, so what's
/// in memory is exactly what's stored and read back.
public struct VoiceVector: Codable, Equatable, Sendable {
    public var space: String
    public private(set) var values: [Float]

    public init(space: String, values: [Float]) {
        self.space = space
        self.values = values.map { HalfFloat.float(HalfFloat.bits($0)) }
    }

    /// Finite, not all zero, and in a named space: something cosine similarity can use.
    public var isUsable: Bool {
        !space.isEmpty && !values.isEmpty && values.allSatisfy(\.isFinite) && values.contains { $0 != 0 }
    }

    private enum CodingKeys: String, CodingKey { case space, dimensions, half }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        space = try values.decode(String.self, forKey: .space)
        let dimensions = try values.decode(Int.self, forKey: .dimensions)
        // A newer encoding (another precision) has no `half`: the voiceprint stays unreadable here and travels on as it came.
        let encoded = try values.decode(String.self, forKey: .half)
        guard let bytes = Data(base64Encoded: encoded), bytes.count == dimensions * 2 else {
            throw DecodingError.dataCorruptedError(forKey: .half, in: values, debugDescription: "The voice vector doesn't have \(dimensions) half floats.")
        }
        self.values = bytes.withUnsafeBytes { buffer in
            (0..<dimensions).map { HalfFloat.float(UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self))) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(space, forKey: .space)
        try container.encode(values.count, forKey: .dimensions)
        var bytes = Data(capacity: values.count * 2)
        for value in values {
            let bits = HalfFloat.bits(value).littleEndian
            withUnsafeBytes(of: bits) { bytes.append(contentsOf: $0) }
        }
        try container.encode(bytes.base64EncodedString(), forKey: .half)
    }
}

/// One voice sample a profile learned from: a speaker's embedding in one conversation.
public struct Voiceprint: Codable, Equatable, Identifiable, Sendable {
    /// How the voiceprint came to belong to its profile. Raw values are stored and must not change.
    public enum Origin: String, Codable, Sendable {
        /// The person named the speaker.
        case named
        /// The person confirmed Daybook's label or suggestion.
        case confirmed
        /// Daybook recognized the speaker with high confidence and learned from it.
        case recognized

        /// Named and confirmed voiceprints anchor a profile; recognized ones only refine it.
        public var isPersonChosen: Bool { self != .recognized }
    }

    /// Deterministic: the same sample learned on two devices is one record (`Voiceprint.id(…)`).
    public var id: String
    public var profileID: UUID
    @Extensible public var origin: Origin
    public var vector: VoiceVector
    /// Where it came from, so it can be shown, removed, or undone with the label it came from.
    public var meetingID: UUID
    /// The speaker whose embedding this is (for a fused speaker, the recording's own speaker).
    public var speakerID: String
    public var trackID: UUID?
    /// The kind of recording ("microphone", "soundcore.work"): a profile keeps a centroid per kind,
    /// so a voice through a laptop microphone and a room recorder are both recognized.
    public var condition: String?
    /// Speech without overlap behind the embedding, in seconds.
    public var speechSeconds: Double
    /// For a recognized voiceprint: how alike the voice was to the profile when it was learned.
    public var similarity: Double?
    /// When the conversation happened; older voiceprints count for less.
    public var recordedAt: Date
    public var addedAt: Date
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(id: String, profileID: UUID, origin: Origin, vector: VoiceVector, meetingID: UUID, speakerID: String,
                trackID: UUID? = nil, condition: String? = nil, speechSeconds: Double, similarity: Double? = nil,
                recordedAt: Date, addedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.origin = origin; self.vector = vector
        self.meetingID = meetingID; self.speakerID = speakerID; self.trackID = trackID; self.condition = condition
        self.speechSeconds = speechSeconds; self.similarity = similarity; self.recordedAt = recordedAt; self.addedAt = addedAt
    }

    /// The same sample gets the same ID on every device. A named one is keyed by the rename it came
    /// from, so naming the speaker again later is a new sample even after the first was removed.
    public static func id(origin: Origin, profileID: UUID, meetingID: UUID, speakerID: String, space: String, basis: String = "") -> String {
        "vp-" + String(AudioDigest.sha256(data: Data("\(origin.rawValue)|\(profileID.uuidString)|\(meetingID.uuidString)|\(speakerID)|\(space)|\(basis)".utf8)).prefix(32))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, profileID, origin, vector, meetingID, speakerID, trackID, condition, speechSeconds, similarity, recordedAt, addedAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        _origin = try values.decode(Extensible<Origin>.self, forKey: .origin)
        vector = try values.decode(VoiceVector.self, forKey: .vector)
        meetingID = try values.decode(UUID.self, forKey: .meetingID)
        speakerID = try values.decode(String.self, forKey: .speakerID)
        trackID = try values.decodeIfPresent(UUID.self, forKey: .trackID)
        condition = try values.decodeIfPresent(String.self, forKey: .condition)
        speechSeconds = try values.decode(Double.self, forKey: .speechSeconds)
        similarity = try values.decodeIfPresent(Double.self, forKey: .similarity)
        recordedAt = try values.decode(Date.self, forKey: .recordedAt)
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(profileID, forKey: .profileID)
        try values.encode(_origin, forKey: .origin)
        try values.encode(vector, forKey: .vector)
        try values.encode(meetingID, forKey: .meetingID)
        try values.encode(speakerID, forKey: .speakerID)
        try values.encodeIfPresent(trackID, forKey: .trackID)
        try values.encodeIfPresent(condition, forKey: .condition)
        try values.encode(speechSeconds, forKey: .speechSeconds)
        try values.encodeIfPresent(similarity, forKey: .similarity)
        try values.encode(recordedAt, forKey: .recordedAt)
        try values.encode(addedAt, forKey: .addedAt)
        try unknownFields.encode(to: encoder)
    }
}

/// Which profile one of a conversation's speakers is, and how that was decided.
public struct SpeakerIdentity: Codable, Equatable, Identifiable, Sendable {
    /// Raw values are stored and must not change.
    public enum Source: String, Codable, Sendable {
        /// The person named the speaker (`basis` is the rename).
        case named
        /// The person confirmed Daybook's label or suggestion.
        case confirmed
        /// Daybook labelled the speaker: the voice matched the profile closely, and clearly better
        /// than any other.
        case recognized
        /// The voice resembles the profile, not closely enough to label it. The name is unchanged.
        case suggested
        /// No profile, but the person said this speaker isn't `rejectedProfileIDs`.
        case dismissed

        public var isPersonChosen: Bool { self == .named || self == .confirmed }
    }

    public var id: String { speakerID }
    public var speakerID: String
    public var profileID: UUID?
    @Extensible public var source: Source
    /// How alike the voice was to the profile, for recognized and suggested speakers.
    public var similarity: Double?
    /// For `recognized`: the name Daybook gave the speaker, and the one it had before, put back if
    /// the label is withdrawn and the name wasn't changed since.
    public var appliedName: String?
    public var previousName: String?
    /// For `named`: the rename (`MeetingRevision.id`) the identity came from.
    public var basis: UUID?
    /// Profiles the person said this speaker isn't; never suggested again.
    public var rejectedProfileIDs: [UUID]?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(speakerID: String, profileID: UUID?, source: Source, similarity: Double? = nil, appliedName: String? = nil,
                previousName: String? = nil, basis: UUID? = nil, rejectedProfileIDs: [UUID]? = nil) {
        self.speakerID = speakerID; self.profileID = profileID; self.source = source; self.similarity = similarity
        self.appliedName = appliedName; self.previousName = previousName; self.basis = basis
        self.rejectedProfileIDs = rejectedProfileIDs?.isEmpty == true ? nil : rejectedProfileIDs
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case speakerID, profileID, source, similarity, appliedName, previousName, basis, rejectedProfileIDs
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        speakerID = try values.decode(String.self, forKey: .speakerID)
        profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID)
        _source = try values.decode(Extensible<Source>.self, forKey: .source)
        similarity = try values.decodeIfPresent(Double.self, forKey: .similarity)
        appliedName = try values.decodeIfPresent(String.self, forKey: .appliedName)
        previousName = try values.decodeIfPresent(String.self, forKey: .previousName)
        basis = try values.decodeIfPresent(UUID.self, forKey: .basis)
        rejectedProfileIDs = try values.decodeIfPresent([UUID].self, forKey: .rejectedProfileIDs)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(speakerID, forKey: .speakerID)
        try values.encodeIfPresent(profileID, forKey: .profileID)
        try values.encode(_source, forKey: .source)
        try values.encodeIfPresent(similarity, forKey: .similarity)
        try values.encodeIfPresent(appliedName, forKey: .appliedName)
        try values.encodeIfPresent(previousName, forKey: .previousName)
        try values.encodeIfPresent(basis, forKey: .basis)
        try values.encodeIfPresent(rejectedProfileIDs, forKey: .rejectedProfileIDs)
        try unknownFields.encode(to: encoder)
    }
}

extension Voiceprint.Origin: ExtensibleSyncEnum {
    /// An origin from a newer Daybook counts as least trusted.
    public static var syncFallback: Voiceprint.Origin { .recognized }
}

extension SpeakerIdentity.Source: ExtensibleSyncEnum {
    /// A source from a newer Daybook never labels a speaker; such identities are left as they are.
    public static var syncFallback: SpeakerIdentity.Source { .suggested }
}

extension SpeakerProfile: PreservesUnknownFields {}
extension Voiceprint: PreservesUnknownFields {}
extension SpeakerIdentity: PreservesUnknownFields {}

extension LibraryMetadata {
    /// Merges profile `id` into `target` (the same person, named two ways): `id`'s record says so
    /// (`mergedInto`), and from then on its voiceprints count for `target`, its speakers are
    /// `target`'s (the Mac moves their identities, and labels take `target`'s name), and its name
    /// finds `target`. Names the person gave speakers stay. Returns whether it merged.
    @discardableResult
    public mutating func mergeSpeakerProfile(_ id: UUID, into target: UUID, at now: Date = Date()) -> Bool {
        let merges = speakerProfileMerges
        guard id != target, merges.isActive(id), merges.isActive(target),
              let index = speakerProfiles?.firstIndex(where: { $0.id == id.uuidString }),
              let record = speakerProfiles?[index], var profile = record.value else { return false }
        profile.mergedInto = target
        // Later than the record it replaces, whatever this device's clock says.
        speakerProfiles?[index] = LibraryValue(id: record.id, value: profile, modifiedAt: max(now, record.modifiedAt.addingTimeInterval(0.001)))
        return true
    }
}

extension Meeting {
    /// The identity recorded for one of the conversation's speakers.
    public func speakerIdentity(_ speakerID: String) -> SpeakerIdentity? {
        speakerIdentities?.first { $0.speakerID == speakerID }
    }

    /// Records (or, with nil, removes) a speaker's identity.
    public mutating func setSpeakerIdentity(_ identity: SpeakerIdentity?, for speakerID: String) {
        var list = speakerIdentities ?? []
        list.removeAll { $0.speakerID == speakerID }
        if let identity { list.append(identity) }
        list.sort { $0.speakerID < $1.speakerID }
        speakerIdentities = list.isEmpty ? nil : list
    }

    /// The person's latest rename of a speaker, when the speaker still has that name: the name is the
    /// person's, never Daybook's to change.
    public func handRename(of speakerID: String) -> MeetingRevision? {
        let field = "speaker:\(speakerID)"
        guard let latest = revisions.filter({ $0.field == field })
            .max(by: { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }),
              let speaker = speakers.first(where: { $0.id == speakerID }), speaker.name == latest.newValue else { return nil }
        return latest
    }
}

/// IEEE 754 binary16, converted by hand: Swift's `Float16` isn't available on every Mac slice.
enum HalfFloat {
    /// Round to nearest, ties to even; NaN stays NaN, overflow becomes infinity.
    static func bits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let rawExponent = Int((bits >> 23) & 0xff)
        var mantissa = bits & 0x7f_ffff
        if rawExponent == 0xff { return sign | 0x7c00 | (mantissa != 0 ? 0x200 : 0) }
        let exponent = rawExponent - 127 + 15
        if exponent >= 0x1f { return sign | 0x7c00 }
        if exponent <= 0 {
            if exponent < -10 { return sign }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - exponent)
            var half = mantissa >> shift
            let remainder = mantissa & ((UInt32(1) << shift) - 1)
            let halfway = UInt32(1) << (shift - 1)
            if remainder > halfway || (remainder == halfway && half & 1 == 1) { half += 1 }
            return sign | UInt16(half)
        }
        var half = UInt32(exponent) << 10 | (mantissa >> 13)
        let remainder = mantissa & 0x1fff
        if remainder > 0x1000 || (remainder == 0x1000 && half & 1 == 1) { half += 1 }
        return sign | UInt16(truncatingIfNeeded: half)
    }

    static func float(_ half: UInt16) -> Float {
        let sign: UInt32 = UInt32(half & 0x8000) << 16
        let exponent = UInt32((half >> 10) & 0x1f)
        let mantissa = UInt32(half & 0x3ff)
        switch exponent {
        case 0:
            guard mantissa != 0 else { return Float(bitPattern: sign) }
            let magnitude = Float(mantissa) * Float(bitPattern: 0x3380_0000) // 2^-24
            return sign == 0 ? magnitude : -magnitude
        case 0x1f:
            return Float(bitPattern: sign | 0x7f80_0000 | (mantissa << 13))
        default:
            return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
        }
    }
}
