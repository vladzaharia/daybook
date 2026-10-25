import DaybookCore
import Foundation

// The courier: a fast path for journal files beside iCloud Drive (docs/icloud-sync.md, "Courier (CloudKit)").
// iCloud Drive still carries every file, so the courier is best effort: when it's unavailable, slow, or refuses a
// file, sync is exactly what it was without it.

/// One journal file on its way between devices, named by its library and path.
public struct CourierFile: Codable, Hashable, Sendable {
    public var libraryID: UUID
    public var journal: SyncJournalFile
    /// The sync device ID of the device that wrote it.
    public var deviceID: String
    /// When it was handed to the courier. Couriers delete files older than `CourierPolicy.expiry`.
    public var createdAt: Date

    public init(libraryID: UUID, journal: SyncJournalFile, deviceID: String, createdAt: Date) {
        self.libraryID = libraryID; self.journal = journal; self.deviceID = deviceID; self.createdAt = createdAt
    }

    /// The same for a library and path on every device, so sending a file again replaces it rather than adding a
    /// second copy. It's the CloudKit record name: ASCII letters, digits, `-`, and `.` only.
    public var id: String { Self.id(libraryID: libraryID, path: journal.path) }

    public static func id(libraryID: UUID, path: String) -> String {
        "\(libraryID.uuidString).\(path.replacingOccurrences(of: "/", with: "."))"
    }
}

/// A file this device wrote, offered to a courier. `copy` writes its bytes to a URL; a courier calls it only for a
/// file it hasn't taken before.
public struct CourierOutgoingFile: Sendable {
    public var libraryID: UUID
    public var journal: SyncJournalFile
    public var deviceID: String
    public var copy: @Sendable (URL) throws -> Void

    public init(libraryID: UUID, journal: SyncJournalFile, deviceID: String, copy: @escaping @Sendable (URL) throws -> Void) {
        self.libraryID = libraryID; self.journal = journal; self.deviceID = deviceID; self.copy = copy
    }

    public var id: String { CourierFile.id(libraryID: libraryID, path: journal.path) }
}

/// A file a courier brought from another device. `contents` stays readable until the receiver returns.
public struct CourierIncomingFile: Sendable {
    public var file: CourierFile
    public var contents: URL

    public init(file: CourierFile, contents: URL) { self.file = file; self.contents = contents }
}

/// Takes files a courier brought and returns the IDs of those the courier may now delete: stored, already held, or
/// rejected. A file left out is kept on the courier until it expires.
public typealias CourierReceiver = @Sendable ([CourierIncomingFile]) async -> Set<String>

/// What a device does with the courier: the iPhone sends what its passes write, a Mac receives.
public struct CourierRole: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let send = CourierRole(rawValue: 1 << 0)
    public static let receive = CourierRole(rawValue: 1 << 1)
}

public enum CourierAvailability: Equatable, Sendable {
    case checking
    case available
    /// Off quietly, with the reason for diagnostics: no CloudKit in this build, no account, restricted, refused.
    /// iCloud Drive carries everything.
    case unavailable(String)
}

/// The courier's state, for the sync status.
public struct CourierStatus: Equatable, Sendable {
    public var availability: CourierAvailability
    /// Files taken to send and not yet confirmed by the server.
    public var waitingToSend: Int
    /// When the oldest of them was taken.
    public var oldestWaiting: Date?
    public var lastError: String?
    /// The server refused files because the person's iCloud storage is full.
    public var storageFull: Bool

    public init(availability: CourierAvailability = .checking, waitingToSend: Int = 0, oldestWaiting: Date? = nil,
                lastError: String? = nil, storageFull: Bool = false) {
        self.availability = availability; self.waitingToSend = waitingToSend; self.oldestWaiting = oldestWaiting
        self.lastError = lastError; self.storageFull = storageFull
    }

    /// A send is stuck once something has waited this long.
    public static let stuckAfter: TimeInterval = 15 * 60

    public func isStuck(now: Date = Date()) -> Bool {
        guard availability == .available, waitingToSend > 0, let oldestWaiting else { return false }
        return now.timeIntervalSince(oldestWaiting) >= Self.stuckAfter
    }
}

/// Limits and timing every courier follows.
public struct CourierPolicy: Equatable, Sendable {
    /// The largest file a courier takes; bigger ones travel by iCloud Drive alone. Apple documents 50 MB as the
    /// maximum size of a CloudKit asset field (CloudKit Web Services Reference, "Data Size Limits"); about 100 minutes
    /// of the phone's 64 kbit/s AAC.
    public var maxFileBytes: Int64
    /// Files older than this are deleted from the courier by any device that knows about them.
    public var expiry: TimeInterval
    /// The first wait after the server refused a file for lack of storage; each refusal doubles it, up to `maxRetry`.
    /// Network failures and rate limits are retried by the transport itself.
    public var firstRetry: TimeInterval
    public var maxRetry: TimeInterval
    /// How long a sent file is remembered, so a later pass that reports it again doesn't send it twice.
    public var sentMemory: TimeInterval

    public init(maxFileBytes: Int64 = 50_000_000, expiry: TimeInterval = 7 * 86_400, firstRetry: TimeInterval = 60,
                maxRetry: TimeInterval = 6 * 3_600, sentMemory: TimeInterval = 30 * 86_400) {
        self.maxFileBytes = maxFileBytes; self.expiry = expiry; self.firstRetry = firstRetry
        self.maxRetry = maxRetry; self.sentMemory = sentMemory
    }
}

/// A fast, best-effort carrier of journal files between devices, beside iCloud Drive.
public protocol SyncCourier: AnyObject, Sendable {
    /// Starts carrying files in `role`. Files from other devices go to `receiver`; status changes to `onStatus`.
    /// Returns once it knows whether it can run: unavailable means it stays off quietly.
    func start(role: CourierRole, receiver: CourierReceiver?, onStatus: @escaping @Sendable (CourierStatus) -> Void) async -> CourierAvailability
    /// Stops carrying files (sync was turned off). What's waiting is kept for the next start.
    func stop() async
    /// Takes files to send, each once: a file already sent, waiting, or too large is ignored, so a retried pass
    /// never sends a duplicate.
    func send(_ files: [CourierOutgoingFile]) async
    /// Sends what's waiting now rather than when the system schedules it (the iPhone, under a background task).
    func flush() async
    /// Fetches what other devices sent now (a push arrived, or the app came to the front).
    func fetch() async
    /// Deletes files older than `CourierPolicy.expiry` that this device knows about.
    func removeExpired() async
    func status() async -> CourierStatus
}

// MARK: - The outbox

/// What a courier on this device has taken: files waiting to send (with staged copies of their bytes), files sent,
/// files left to iCloud Drive, and files known to be on the server, for expiry. Shared by every courier, so sending
/// once, retries, and expiry behave the same over CloudKit and in tests. Kept in `<directory>/outbox.json`, with the
/// staged copies in `<directory>/Outbox/`. Not thread-safe: its courier (an actor) owns it.
final class CourierOutbox {
    struct Waiting: Codable, Equatable {
        var file: CourierFile
        var queuedAt: Date
        var attempts = 0
        var retryAfter: Date?
        var lastError: String?
    }

    struct Ledger: Codable, Equatable {
        var schemaVersion = 1
        var waiting: [String: Waiting] = [:]
        var sent: [String: Date] = [:]
        /// Files left to iCloud Drive (too large, or refused for good), by when.
        var skipped: [String: Date] = [:]
        /// Files this device knows are on the server, by when they were created: its own, and any it fetched and kept.
        var known: [String: Date] = [:]
        var storageFull = false
        var lastError: String?
    }

    let directory: URL
    let policy: CourierPolicy
    private(set) var ledger: Ledger
    private let fm = FileManager.default

    init(directory: URL, policy: CourierPolicy) {
        self.directory = directory; self.policy = policy
        let url = directory.appendingPathComponent("outbox.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder.courier.decode(Ledger.self, from: data),
           decoded.schemaVersion == 1 {
            ledger = decoded
        } else {
            ledger = Ledger()
        }
    }

    var stagingDirectory: URL { directory.appendingPathComponent("Outbox", isDirectory: true) }
    func stagedURL(_ id: String) -> URL { stagingDirectory.appendingPathComponent(id) }

    /// Takes the files it hasn't seen, staging a copy of each; returns those it took.
    @discardableResult
    func accept(_ files: [CourierOutgoingFile], now: Date) -> [CourierFile] {
        var taken: [CourierFile] = []
        for outgoing in files {
            let id = outgoing.id
            guard outgoing.journal.isContentAddressed, ledger.waiting[id] == nil, ledger.sent[id] == nil, ledger.skipped[id] == nil else { continue }
            guard outgoing.journal.size <= policy.maxFileBytes else { ledger.skipped[id] = now; continue }
            do {
                try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try outgoing.copy(stagedURL(id))
            } catch {
                // The file can't be read now (iCloud evicted it, say). iCloud Drive carries it.
                try? fm.removeItem(at: stagedURL(id))
                continue
            }
            let file = CourierFile(libraryID: outgoing.libraryID, journal: outgoing.journal, deviceID: outgoing.deviceID, createdAt: now)
            ledger.waiting[id] = Waiting(file: file, queuedAt: now)
            ledger.known[id] = now
            taken.append(file)
        }
        if !files.isEmpty { save(now: now) }
        return taken
    }

    func waiting(_ id: String) -> Waiting? { ledger.waiting[id] }

    func isDue(_ id: String, now: Date) -> Bool {
        guard let entry = ledger.waiting[id] else { return false }
        return entry.retryAfter.map { $0 <= now } ?? true
    }

    /// Files ready to send now, oldest first.
    func due(now: Date) -> [CourierFile] {
        ledger.waiting.values.filter { $0.retryAfter.map { $0 <= now } ?? true }
            .sorted { ($0.queuedAt, $0.file.id) < ($1.queuedAt, $1.file.id) }.map(\.file)
    }

    /// When the next file waiting out a refusal may go again.
    var nextRetry: Date? { ledger.waiting.values.compactMap(\.retryAfter).min() }

    func markSent(_ id: String, now: Date) {
        guard ledger.waiting.removeValue(forKey: id) != nil else { return }
        try? fm.removeItem(at: stagedURL(id))
        ledger.sent[id] = now
        if ledger.waiting.values.allSatisfy({ $0.retryAfter == nil }) { ledger.storageFull = false }
    }

    /// The server refused the file for now (storage full): wait, doubling each time, then try again.
    func markRetry(_ id: String, error: String, storageFull: Bool, now: Date) {
        guard var entry = ledger.waiting[id] else { return }
        entry.attempts += 1
        let delay = min(policy.firstRetry * pow(2, Double(entry.attempts - 1)), policy.maxRetry)
        entry.retryAfter = now.addingTimeInterval(delay)
        entry.lastError = error
        ledger.waiting[id] = entry
        ledger.lastError = error
        if storageFull { ledger.storageFull = true }
    }

    /// A failure the transport retries itself (network, rate limit): the file keeps waiting.
    func noteTransient(_ id: String, error: String) {
        ledger.waiting[id]?.lastError = error
        ledger.lastError = error
    }

    func noteError(_ error: String) { ledger.lastError = error }

    /// Gives up on a file for good; iCloud Drive carries it.
    func drop(_ id: String, now: Date, error: String? = nil) {
        guard ledger.waiting.removeValue(forKey: id) != nil else { return }
        try? fm.removeItem(at: stagedURL(id))
        ledger.skipped[id] = now
        if let error { ledger.lastError = error }
    }

    /// Gives up on everything waiting (the courier went off, or the account's data was reset).
    func dropAllWaiting(now: Date) {
        for id in ledger.waiting.keys { drop(id, now: now) }
        ledger.storageFull = false
    }

    func noteKnown(_ id: String, createdAt: Date) { ledger.known[id] = createdAt }

    /// The file is gone from the server.
    func forget(_ id: String) { ledger.known.removeValue(forKey: id) }

    /// Known files old enough to delete. Any still waiting are given up.
    func expired(now: Date) -> [String] {
        let ids = ledger.known.filter { now.timeIntervalSince($0.value) >= policy.expiry }.map(\.key).sorted()
        for id in ids where ledger.waiting[id] != nil { drop(id, now: now) }
        return ids
    }

    /// Another account, or its data was reset: nothing here applies any more.
    func reset() {
        ledger = Ledger()
        try? fm.removeItem(at: stagingDirectory)
    }

    func status(availability: CourierAvailability) -> CourierStatus {
        CourierStatus(availability: availability, waitingToSend: ledger.waiting.count,
                      oldestWaiting: ledger.waiting.values.map(\.queuedAt).min(), lastError: ledger.lastError,
                      storageFull: ledger.storageFull)
    }

    func save(now: Date = Date()) {
        ledger.sent = ledger.sent.filter { now.timeIntervalSince($0.value) < policy.sentMemory }
        ledger.skipped = ledger.skipped.filter { now.timeIntervalSince($0.value) < policy.sentMemory }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("outbox.json")
            try JSONEncoder.courier.encode(ledger).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // The outbox is an optimization: losing it at worst sends a file twice, which replaces itself.
        }
    }
}

extension JSONEncoder {
    static var courier: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var courier: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
