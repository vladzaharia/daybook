import CryptoKit
import Foundation

/// How a replica treats original audio. Nothing about the policy is synchronized: it describes this
/// device's local copy of the library, and every replica publishes the same events either way.
public enum SyncAudioPolicy: String, Codable, Sendable {
    /// Every original is copied into the local library before its conversation applies. The Mac default.
    case eager
    /// Conversations, transcripts, summaries, notes, and metadata apply as soon as their events are readable.
    /// Track audio stays in the sync folder until `fetchAudio` makes it local, and fetched copies can be evicted.
    case onDemand
}

/// What kind of device a replica runs on. Unknown values written by newer versions decode as `.other`.
public enum SyncDeviceClass: String, Codable, Sendable, CaseIterable {
    case mac, phone, other
    public init(from decoder: Decoder) throws {
        self = SyncDeviceClass(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

/// How this replica describes itself to the others through its presence record.
public struct SyncDeviceIdentity: Codable, Equatable, Sendable {
    public var deviceClass: SyncDeviceClass
    public var displayName: String
    /// Whether this device has models and can transcribe, identify speakers, and summarize.
    public var canProcess: Bool
    public init(deviceClass: SyncDeviceClass, displayName: String, canProcess: Bool) {
        self.deviceClass = deviceClass; self.displayName = displayName; self.canProcess = canProcess
    }
}

/// Per-replica settings for `LibrarySyncEngine`. The defaults reproduce the original Mac behaviour:
/// eager audio, no presence record, and no audio eviction.
public struct SyncReplicaConfiguration: Sendable {
    public var audioPolicy: SyncAudioPolicy
    /// Nil writes no presence record (the behaviour of Daybook before presence existed).
    public var device: SyncDeviceIdentity?
    /// Size budget for local audio on an on-demand replica. Ignored by eager replicas.
    public var audioCache: AudioCachePolicy?
    /// A presence record is rewritten when its identity changes or when it is older than this.
    public var presenceRefreshInterval: TimeInterval
    /// File-provider operations. Tests substitute a simulated iCloud.
    public var cloud: SyncCloudFiles

    public init(audioPolicy: SyncAudioPolicy = .eager, device: SyncDeviceIdentity? = nil,
                audioCache: AudioCachePolicy? = nil, presenceRefreshInterval: TimeInterval = 600,
                cloud: SyncCloudFiles = .system) {
        self.audioPolicy = audioPolicy; self.device = device; self.audioCache = audioCache
        self.presenceRefreshInterval = presenceRefreshInterval; self.cloud = cloud
    }

    public static func mac(displayName: String, canProcess: Bool) -> Self {
        Self(audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: displayName, canProcess: canProcess))
    }

    public static func phone(displayName: String, canProcess: Bool = false, audioCache: AudioCachePolicy = .phoneDefault) -> Self {
        Self(audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: displayName, canProcess: canProcess),
             audioCache: audioCache)
    }
}

/// The file-provider calls the engine makes. `.system` uses Foundation's iCloud APIs; any folder that is
/// not ubiquitous (for example a temporary test folder) behaves as fully downloaded and uploaded.
public struct SyncCloudFiles: Sendable {
    /// Ask the provider to download an evicted item (`startDownloadingUbiquitousItem`).
    public var requestDownload: @Sendable (URL) throws -> Void
    /// Fraction downloaded (0...1) of an item that is downloading, when the provider reports it. The
    /// controller can answer from its NSMetadataQuery (`NSMetadataUbiquitousItemPercentDownloadedKey`).
    public var downloadFraction: @Sendable (URL) -> Double?
    /// Whether an item has reached the cloud. Gates evicting originals recorded on this device.
    public var isUploaded: @Sendable (URL) -> Bool
    /// Best-effort request to drop the provider's local copy of an item that is safely in the cloud.
    public var evictLocalCopy: @Sendable (URL) -> Void

    public init(requestDownload: @escaping @Sendable (URL) throws -> Void,
                downloadFraction: @escaping @Sendable (URL) -> Double? = { _ in nil },
                isUploaded: @escaping @Sendable (URL) -> Bool,
                evictLocalCopy: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.requestDownload = requestDownload; self.downloadFraction = downloadFraction
        self.isUploaded = isUploaded; self.evictLocalCopy = evictLocalCopy
    }

    public static let system = SyncCloudFiles(
        requestDownload: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
        isUploaded: { url in
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
            if values?.isUbiquitousItem == true { return values?.ubiquitousItemIsUploaded == true }
            return FileManager.default.fileExists(atPath: url.path)
        },
        evictLocalCopy: { url in
            guard (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true else { return }
            try? FileManager.default.evictUbiquitousItem(at: url)
        })
}

/// Bounds the work of one synchronization pass so a phone can sync in short foreground or background
/// windows. Anything left over is reported through `SyncResult.hasMoreWork` and picked up by the next pass.
public struct SyncPassLimits: Equatable, Sendable {
    /// Journal files (events and metadata) read and validated for the first time in one pass.
    public var maxJournalReads: Int?
    /// Wall-clock budget for reading the journal and, on an eager replica, copying audio.
    public var timeBudget: Duration?
    public init(maxJournalReads: Int? = nil, timeBudget: Duration? = nil) {
        self.maxJournalReads = maxJournalReads; self.timeBudget = timeBudget
    }
    /// Read everything in one pass (the Mac default).
    public static let unlimited = SyncPassLimits()
    /// Foreground passes on a phone: responsive, continued immediately while `hasMoreWork`.
    public static let interactive = SyncPassLimits(maxJournalReads: 400, timeBudget: .seconds(8))
    /// Background app refresh: well inside the system's time allowance.
    public static let background = SyncPassLimits(maxJournalReads: 100, timeBudget: .seconds(15))
}

/// Whether a track's audio is on this device. A track that is not local is still a complete, valid track.
public enum TrackAudioAvailability: String, Codable, Sendable {
    case local
    /// The audio is in the sync folder (or still uploading from the device that recorded it). Fetch it to play.
    case notLocal
}

/// What a device is doing right now, in its presence record (docs/icloud-sync.md, "Devices and presence"): the
/// conversation it's recording into and the recorders it drives. The device rewrites it at the start and end of a
/// recording and every few minutes while it lasts, even while its sync passes wait; readers ignore it after
/// `expiresAt`. Additive: older readers skip it, and one that can't be read is left out of the record.
public struct SyncDeviceActivity: Codable, Equatable, Sendable {
    /// A recorder (a Soundcore, a phone) this device drives, as of `asOf`.
    public struct Recorder: Codable, Equatable, Sendable {
        public var kind: String
        public var serial: String?
        public var isRecording: Bool
        public var recordingID: String?
        public var startedAt: Date?
        public var asOf: Date
        public init(kind: String, serial: String? = nil, isRecording: Bool, recordingID: String? = nil, startedAt: Date? = nil, asOf: Date = Date()) {
            self.kind = kind; self.serial = serial; self.isRecording = isRecording; self.recordingID = recordingID
            self.startedAt = startedAt; self.asOf = asOf
        }
    }
    public var recordingConversationID: UUID?
    /// When the recording started.
    public var since: Date?
    public var recorders: [Recorder]?
    /// When to stop believing it, by the writer's clock; renewed while it lasts.
    public var expiresAt: Date
    public init(recordingConversationID: UUID? = nil, since: Date? = nil, recorders: [Recorder]? = nil, expiresAt: Date = .distantFuture) {
        self.recordingConversationID = recordingConversationID; self.since = since; self.recorders = recorders; self.expiresAt = expiresAt
    }
    /// Recording, into a conversation or on a recorder it drives.
    public var isRecording: Bool { recordingConversationID != nil || recorders?.contains(where: \.isRecording) == true }
}

/// One device known to the library: from its presence record, or (for a replica running an older
/// Daybook) only from the device ID on its journal entries.
public struct KnownSyncDevice: Equatable, Identifiable, Sendable {
    public var id: String
    /// Nil when the device has never written a presence record.
    public var deviceClass: SyncDeviceClass?
    public var displayName: String?
    public var canProcess: Bool?
    public var audioPolicy: SyncAudioPolicy?
    /// When the device last completed a sync pass, by its own clock (clamped to now). Nil without presence.
    public var lastSeen: Date?
    public var isCurrentDevice: Bool
    /// What it's doing, as its presence record last said (nil without one, or with nothing to say).
    public var activity: SyncDeviceActivity?
    public var reportsPresence: Bool { lastSeen != nil }
    public init(id: String, deviceClass: SyncDeviceClass? = nil, displayName: String? = nil, canProcess: Bool? = nil,
                audioPolicy: SyncAudioPolicy? = nil, lastSeen: Date? = nil, isCurrentDevice: Bool = false, activity: SyncDeviceActivity? = nil) {
        self.id = id; self.deviceClass = deviceClass; self.displayName = displayName; self.canProcess = canProcess
        self.audioPolicy = audioPolicy; self.lastSeen = lastSeen; self.isCurrentDevice = isCurrentDevice; self.activity = activity
    }
    /// Recording now, by an activity that hasn't expired (`now` on the reader's clock).
    public func isRecording(at now: Date = Date()) -> Bool {
        guard let activity, activity.expiresAt > now else { return false }
        return activity.isRecording
    }
}

extension Array where Element == KnownSyncDevice {
    /// The most recently seen other device that can process, for "Waiting for your Mac · last seen 2 h ago".
    /// Nil means no such device has synced this library (or none has written presence yet).
    public var latestProcessor: KnownSyncDevice? {
        filter { !$0.isCurrentDevice && $0.canProcess == true && $0.lastSeen != nil }
            .max { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }
    }
    /// Other replicas that wrote to the journal without a presence record (an older Daybook on a Mac).
    public var hasPeersWithoutPresence: Bool { contains { !$0.isCurrentDevice && !$0.reportsPresence } }
    /// Another Mac that's recording now, by its presence.
    public func recordingMac(at now: Date = Date()) -> KnownSyncDevice? {
        first { !$0.isCurrentDevice && $0.deviceClass == .mac && $0.isRecording(at: now) }
    }
}

/// Local audio budget for an on-demand replica.
public struct AudioCachePolicy: Equatable, Sendable {
    public var budgetBytes: UInt64
    /// Originals recorded or imported on this device become evictable once they have reached the cloud.
    /// Until then they are never evicted, whatever the budget.
    public var evictsUploadedOriginals: Bool
    public init(budgetBytes: UInt64, evictsUploadedOriginals: Bool = true) {
        self.budgetBytes = budgetBytes; self.evictsUploadedOriginals = evictsUploadedOriginals
    }
    /// About 30 hours of 64 kbit/s AAC.
    public static let phoneDefault = AudioCachePolicy(budgetBytes: 1_000_000_000)
}

public enum CachedAudioOrigin: String, Codable, Sendable {
    /// Downloaded by `fetchAudio`; the sync folder holds the original.
    case fetched
    /// Recorded or imported on this device and published from here.
    case recordedHere
}

/// Local audio an on-demand replica tracks for eviction.
public struct CachedAudio: Equatable, Sendable {
    public var meetingID: UUID
    public var trackID: UUID?
    public var relativePath: String
    public var sha256: String
    public var bytes: UInt64
    public var origin: CachedAudioOrigin
    public var addedAt: Date
    public var lastPlayedAt: Date?
}

public struct AudioEvictionReport: Equatable, Sendable {
    /// In eviction order: least recently played first.
    public var evicted: [CachedAudio]
    public var bytesFreed: UInt64
    /// Tracked local audio remaining after eviction.
    public var bytesInUse: UInt64
    public var budgetBytes: UInt64?
    /// False when the remaining audio cannot be evicted yet (originals not uploaded, protected tracks).
    public var isWithinBudget: Bool { budgetBytes.map { bytesInUse <= $0 } ?? true }
}

public struct AudioFetchOptions: Sendable {
    /// How often to check on an iCloud download or a recording still uploading elsewhere.
    public var pollInterval: Duration
    /// Nil waits until the calling task is cancelled.
    public var timeout: Duration?
    public init(pollInterval: Duration = .milliseconds(500), timeout: Duration? = .seconds(600)) {
        self.pollInterval = pollInterval; self.timeout = timeout
    }
}

public struct AudioFetchProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        /// The recording has not reached the sync folder yet (it is uploading from the device that made it).
        case waitingForUpload
        /// iCloud is downloading the recording.
        case downloading
        /// Copying into the library while checking its SHA-256.
        case copying
        /// Verified and installed in the library.
        case installed
    }
    public var phase: Phase
    public var completedBytes: Int64
    public var totalBytes: Int64?
    /// The provider's download fraction while `downloading`, when it reports one.
    public var downloadFraction: Double?
    public init(phase: Phase, completedBytes: Int64 = 0, totalBytes: Int64? = nil, downloadFraction: Double? = nil) {
        self.phase = phase; self.completedBytes = completedBytes; self.totalBytes = totalBytes; self.downloadFraction = downloadFraction
    }
    /// Progress through the current phase, when known.
    public var fractionCompleted: Double? {
        switch phase {
        case .waitingForUpload: return nil
        case .downloading: return downloadFraction
        case .copying: return totalBytes.flatMap { $0 > 0 ? Double(completedBytes) / Double($0) : nil }
        case .installed: return 1
        }
    }
}

public enum AudioFetchError: LocalizedError, Equatable {
    case invalidTrack(String), meetingInTrash, integrityMismatch(String), downloadFailed(String), notUploadedYet, downloadTimedOut
    public var errorDescription: String? {
        switch self {
        case .invalidTrack(let name): return "\(name) can’t be downloaded."
        case .meetingInTrash: return "This conversation is in the Trash. Restore it before playing its audio."
        case .integrityMismatch(let name): return "The copy of \(name) in iCloud is damaged. Nothing in your library changed."
        case .downloadFailed(let reason): return "iCloud couldn’t download this recording: \(reason)"
        case .notUploadedYet: return "This recording hasn’t finished uploading."
        case .downloadTimedOut: return "iCloud is still downloading this recording. Try again in a moment."
        }
    }
}

/// SHA-256 with CryptoKit. Produces exactly the same lowercase hex as `AudioDigest`, much faster, which
/// matters for journal hashing and audio verification on a phone.
enum SyncDigest {
    static func sha256(data: Data) -> String { hex(SHA256.hash(data: data)) }
    static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: bytes)
        }
        return hex(hasher.finalize())
    }
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(64)
        for byte in digest { result.append(digits[Int(byte >> 4)]); result.append(digits[Int(byte & 0x0f)]) }
        return result
    }
}
