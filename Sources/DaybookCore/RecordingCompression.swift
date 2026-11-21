import Foundation

/// A recording whose file was replaced by a verified lossy copy (Compress Older Recordings, docs/architecture.md,
/// "Recordings"): how it was encoded, and what it was before. The track's `relativePath`, `fileName`, and `sha256` name
/// the copy; this keeps the original's, so the recording is still known by the bytes it was captured as (an import of the
/// recorder's file again, a merge, a measurement made on the original), and so a device holding the original can tell it
/// may let it go. Optional on the track: versions before it keep it as an unknown field and write it back unchanged.
public struct TrackEncoding: Codable, Equatable, Sendable {
    /// The rule this version encodes by (`RecordingCompressionTable.rule`). A recording encoded under a later rule is left as it is.
    public static var currentRule: Int { RecordingCompressionTable.rule }

    /// How the copy was made, such as `aac-lc-64` (AAC-LC at 64 kbit/s) or `aac-lc-96-stereo`.
    public var method: String
    /// The rule it was made under (`currentRule` when it was made here).
    public var rule: Int
    /// What the original was, in words for diagnostics: "Linear PCM, 32-bit float, 48000 Hz, 1 channel".
    public var sourceFormat: String
    /// The SHA-256 of the original's bytes: the recording's identity before it was compressed.
    public var previousSHA256: String
    /// Where the original was in the conversation's folder, so another device holding it can find it to let it go.
    public var previousRelativePath: String
    /// The original's file name, as the track named it.
    public var previousFileName: String
    /// The original's size and the copy's, in bytes.
    public var previousSize: Int64?
    public var size: Int64?
    public var encodedAt: Date
    /// The sync device that made the copy (`LibrarySyncController.deviceID`), when the library syncs.
    public var device: String?
    /// The transcript quality bar (`TranscriptAgreement`): whether it ran, with which model, and what it found.
    public var transcriptCheck: TranscriptCheck?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(method: String, rule: Int = TrackEncoding.currentRule, sourceFormat: String, previousSHA256: String,
                previousRelativePath: String, previousFileName: String, previousSize: Int64? = nil, size: Int64? = nil,
                encodedAt: Date, device: String? = nil, transcriptCheck: TranscriptCheck? = nil) {
        self.method = method; self.rule = rule; self.sourceFormat = sourceFormat; self.previousSHA256 = previousSHA256
        self.previousRelativePath = previousRelativePath; self.previousFileName = previousFileName
        self.previousSize = previousSize; self.size = size; self.encodedAt = encodedAt; self.device = device
        self.transcriptCheck = transcriptCheck
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case method, rule, sourceFormat, previousSHA256, previousRelativePath, previousFileName, previousSize, size, encodedAt, device,
            transcriptCheck
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        method = try values.decode(String.self, forKey: .method)
        rule = try values.decode(Int.self, forKey: .rule)
        sourceFormat = try values.decodeIfPresent(String.self, forKey: .sourceFormat) ?? ""
        previousSHA256 = try values.decode(String.self, forKey: .previousSHA256)
        previousRelativePath = try values.decode(String.self, forKey: .previousRelativePath)
        previousFileName = try values.decodeIfPresent(String.self, forKey: .previousFileName) ?? ""
        previousSize = try values.decodeIfPresent(Int64.self, forKey: .previousSize)
        size = try values.decodeIfPresent(Int64.self, forKey: .size)
        encodedAt = try values.decode(Date.self, forKey: .encodedAt)
        device = try values.decodeIfPresent(String.self, forKey: .device)
        transcriptCheck = (try? values.decodeIfPresent(TranscriptCheck.self, forKey: .transcriptCheck)) ?? nil
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(method, forKey: .method)
        try values.encode(rule, forKey: .rule)
        try values.encode(sourceFormat, forKey: .sourceFormat)
        try values.encode(previousSHA256, forKey: .previousSHA256)
        try values.encode(previousRelativePath, forKey: .previousRelativePath)
        try values.encode(previousFileName, forKey: .previousFileName)
        try values.encodeIfPresent(previousSize, forKey: .previousSize)
        try values.encodeIfPresent(size, forKey: .size)
        try values.encode(encodedAt, forKey: .encodedAt)
        try values.encodeIfPresent(device, forKey: .device)
        try values.encodeIfPresent(transcriptCheck, forKey: .transcriptCheck)
        try unknownFields.encode(to: encoder)
    }
}

/// Settings › Storage › Compress Older Recordings: the library's choice (`LibraryChoice.Name.compressOlderRecordings`),
/// so every device agrees; only Macs act on it.
public enum RecordingCompressionAge: String, CaseIterable, Sendable {
    case after30Days = "30d"
    case after90Days = "90d"
    case never

    /// What a library that never chose has.
    public static let standard = RecordingCompressionAge.after30Days

    /// How long after a conversation was last processed and edited its recordings are kept as captured; nil for Never.
    public var interval: TimeInterval? {
        switch self {
        case .after30Days: return 30 * 86_400
        case .after90Days: return 90 * 86_400
        case .never: return nil
        }
    }
}

extension LibraryMetadata {
    /// The library's Compress Older Recordings choice: 30 days while nobody has chosen, and Never for a value this
    /// version can't read (a newer Daybook's, or one in another shape), since what it would allow can't be known.
    public var recordingCompression: RecordingCompressionAge {
        guard let record = choice(.compressOlderRecordings) else { return .standard }
        if record.unreadableValue != nil { return .never }
        guard let value = record.value else { return .standard }
        // Something a newer Daybook wrote beside the selection might qualify it: not understood, so Never.
        guard value.unknownFields.isEmpty else { return .never }
        guard let selection = value.selection else { return .standard }
        return RecordingCompressionAge(rawValue: selection) ?? .never
    }
}

extension RecordingTrack {
    /// Its file is a lossy copy that replaced the original (`encoding`).
    public var isCompressed: Bool { encoding != nil }

    /// Its file is, or was before it was compressed, the bytes with this SHA-256: how a recording is recognised by its
    /// bytes (an import of the same file, a merge, a measurement made on them).
    public func holdsBytes(_ digest: String) -> Bool {
        guard !digest.isEmpty else { return false }
        return sha256 == digest || encoding?.previousSHA256 == digest
    }

    /// Every SHA-256 the recording is known by: its file's, and the original's when it was compressed.
    public var knownDigests: [String] {
        [sha256, encoding?.previousSHA256].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

/// Where a compressed copy goes and how its track merges (docs/icloud-sync.md, "Compressed recordings").
public enum RecordingCompression {
    /// The copy's path in its conversation's folder: named by the track and the copy's own bytes, so it never meets
    /// another file at its path (two Macs' copies of one recording differ in bytes, and so in path), and never
    /// the original's, which keeps its own path until it's let go.
    public static func relativePath(trackID: UUID, sha256: String) -> String {
        "Originals/\(trackID.uuidString).aac-\(sha256.prefix(16)).m4a"
    }

    /// A temporary copy being made or checked, hidden in the folder the copy goes to. A launch deletes any it finds.
    public static let temporaryPrefix = ".compress-"

    /// The file a track names, which merges as one thing apart from the rest of the track: a track whose file was
    /// compressed on one device and edited on another keeps both changes.
    public struct File: Codable, Equatable, Sendable {
        public var relativePath: String
        public var fileName: String
        public var sha256: String
        public var encoding: TrackEncoding?

        public init(relativePath: String, fileName: String, sha256: String, encoding: TrackEncoding?) {
            self.relativePath = relativePath; self.fileName = fileName; self.sha256 = sha256; self.encoding = encoding
        }

        public init(_ track: RecordingTrack) {
            relativePath = track.relativePath; fileName = track.fileName; sha256 = track.sha256; encoding = track.encoding
        }

        public func apply(to track: inout RecordingTrack) {
            track.relativePath = relativePath; track.fileName = fileName; track.sha256 = sha256; track.encoding = encoding
        }

        /// The hash this file was made from: the original's when it's a compressed copy, its own otherwise.
        var origin: String { encoding?.previousSHA256 ?? sha256 }
    }

    /// Two devices' versions of one track's file, with their common ancestor's when there is one.
    ///
    /// A compressed copy wins over the original it was made from, whatever the ancestor says: the device that made it
    /// may already have let the original go, so going back to it would name bytes nobody holds. Two copies of the same
    /// original made on two devices keep the one with the smaller SHA-256, so every device keeps the same one (the other
    /// is let go where it was made). Anything else merges three-way like the rest of the track. Commutative, and
    /// associative over versions of one recording: the winner of any set of versions is the copy with the smallest hash
    /// among those made from the original, or the original when none was.
    public static func merged(_ lhs: File, _ rhs: File, ancestor: File?,
                              conflict: (_ smaller: File, _ larger: File) -> Void) -> File {
        if lhs == rhs { return lhs }
        switch (lhs.encoding, rhs.encoding) {
        case (.some(let encoding), _) where rhs.encoding == nil && encoding.previousSHA256 == rhs.sha256: return lhs
        case (_, .some(let encoding)) where lhs.encoding == nil && encoding.previousSHA256 == lhs.sha256: return rhs
        case (.some, .some) where lhs.origin == rhs.origin: return smaller(lhs, rhs)
        default: break
        }
        if let ancestor {
            if lhs == ancestor { return rhs }
            if rhs == ancestor { return lhs }
        }
        let (a, b) = (SyncEncoding.string(lhs), SyncEncoding.string(rhs))
        if a <= b { conflict(lhs, rhs) } else { conflict(rhs, lhs) }
        return a > b ? lhs : rhs
    }

    private static func smaller(_ lhs: File, _ rhs: File) -> File {
        if lhs.sha256 != rhs.sha256 { return lhs.sha256 < rhs.sha256 ? lhs : rhs }
        return SyncEncoding.string(lhs) <= SyncEncoding.string(rhs) ? lhs : rhs
    }
}
