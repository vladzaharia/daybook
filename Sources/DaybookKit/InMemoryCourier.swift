import DaybookCore
import Foundation

/// A courier's server held in memory: what the private CloudKit database is to `CloudKitCourier`. Tests and
/// previews use it with `InMemoryCourier`; nothing leaves the process.
public final class InMemoryCourierService: @unchecked Sendable {
    public enum Failure: Sendable, Equatable {
        /// Saves fail as a network failure would: files keep waiting and go on the next flush.
        case network
        /// Saves are refused because iCloud storage is full: files wait out a growing delay.
        case storageFull
    }

    private struct Stored { var file: CourierFile; var data: Data; var version: Int }
    private let lock = NSLock()
    private var stored: [String: Stored] = [:]
    private var version = 0
    private var _failure: Failure?
    private var _isAvailable = true
    private var _saves = 0

    public init() {}

    /// Nil: saves succeed.
    public var failure: Failure? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    /// False: as if no iCloud account were signed in.
    public var isAvailable: Bool {
        get { lock.withLock { _isAvailable } }
        set { lock.withLock { _isAvailable = newValue } }
    }
    /// Successful saves, a resend of the same file included.
    public var saveCount: Int { lock.withLock { _saves } }
    public var fileIDs: [String] { lock.withLock { stored.keys.sorted() } }
    public func file(_ id: String) -> CourierFile? { lock.withLock { stored[id]?.file } }
    public func data(_ id: String) -> Data? { lock.withLock { stored[id]?.data } }

    /// Replaces a stored file's bytes, as damage in transit would.
    public func corrupt(_ id: String, with data: Data) {
        lock.withLock {
            guard var entry = stored[id] else { return }
            version += 1
            entry.data = data; entry.version = version
            stored[id] = entry
        }
    }

    /// Makes a stored file look older, for expiry.
    public func backdate(_ id: String, by interval: TimeInterval) {
        lock.withLock { stored[id]?.file.createdAt.addTimeInterval(-interval) }
    }

    func save(_ file: CourierFile, data: Data) throws -> Failure? {
        try lock.withLock {
            if let failure = _failure { return failure }
            guard _isAvailable else { throw CocoaError(.userCancelled) }
            version += 1
            stored[file.id] = Stored(file: file, data: data, version: version)
            _saves += 1
            return nil
        }
    }

    func delete(_ id: String) { lock.withLock { _ = stored.removeValue(forKey: id) } }

    /// Files changed after `token`, and the new token.
    func changes(since token: Int) -> ([(CourierFile, Data)], Int) {
        lock.withLock {
            let changed = stored.values.filter { $0.version > token }.sorted { $0.version < $1.version }
            return (changed.map { ($0.file, $0.data) }, version)
        }
    }
}

/// A courier over `InMemoryCourierService`, with the same outbox as `CloudKitCourier`: each file is sent once, a
/// refused file waits out a growing delay, and files expire after `CourierPolicy.expiry`. Sends happen on `send` and
/// `flush`, deliveries on `fetch`, as CloudKit pushes would trigger them.
public actor InMemoryCourier: SyncCourier {
    private let service: InMemoryCourierService
    private let deviceID: String
    private let policy: CourierPolicy
    private let clock: @Sendable () -> Date
    private let directory: URL
    private let outbox: CourierOutbox
    private var role: CourierRole = []
    private var receiver: CourierReceiver?
    private var onStatus: (@Sendable (CourierStatus) -> Void)?
    private var availability: CourierAvailability = .checking
    private var token = 0
    /// The zones this courier fetches, as `CloudKitCourier` names them: both, or only `Courier` to play Daybook 0.3.0,
    /// which never reads (or clears) an encrypted library's zone.
    private let zones: Set<String>
    /// Files handed to the receiver, by ID, in order (tests).
    public private(set) var delivered: [String] = []

    /// `directory` holds the outbox (the CloudKit courier uses `Sync/Courier` in the library).
    public init(service: InMemoryCourierService, directory: URL, deviceID: String, policy: CourierPolicy = CourierPolicy(),
                clock: @escaping @Sendable () -> Date = { Date() },
                zones: Set<String> = [CloudKitCourier.zoneName, CloudKitCourier.sealedZoneName]) {
        self.service = service; self.directory = directory; self.deviceID = deviceID; self.policy = policy; self.clock = clock
        self.zones = zones
        outbox = CourierOutbox(directory: directory, policy: policy)
    }

    private func zone(of id: String) -> String { CloudKitCourier.isSealed(id) ? CloudKitCourier.sealedZoneName : CloudKitCourier.zoneName }

    public func start(role: CourierRole, receiver: CourierReceiver?, onStatus: @escaping @Sendable (CourierStatus) -> Void) async -> CourierAvailability {
        self.role = role; self.receiver = receiver; self.onStatus = onStatus
        availability = service.isAvailable ? .available : .unavailable("No iCloud account")
        if availability != .available { outbox.dropAllWaiting(now: clock()); outbox.save(now: clock()) }
        publish()
        return availability
    }

    public func stop() async {
        availability = .unavailable("Off")
        publish()
    }

    public func send(_ files: [CourierOutgoingFile]) async {
        guard role.contains(.send), availability == .available else { return }
        outbox.accept(files, now: clock())
        await flush()
    }

    public func flush() async {
        guard availability == .available else { return }
        let now = clock()
        for file in outbox.due(now: now) {
            guard let data = try? Data(contentsOf: outbox.stagedURL(file.id)) else { outbox.drop(file.id, now: now); continue }
            do {
                switch try service.save(file, data: data) {
                case nil: outbox.markSent(file.id, now: now)
                case .network: outbox.noteTransient(file.id, error: "The network connection was lost.")
                case .storageFull: outbox.markRetry(file.id, error: "iCloud storage is full.", storageFull: true, now: now)
                }
            } catch {
                outbox.noteTransient(file.id, error: error.localizedDescription)
            }
        }
        outbox.save(now: now)
        publish()
    }

    public func fetch() async {
        guard availability == .available else { return }
        let now = clock()
        let (changes, next) = service.changes(since: token)
        token = next
        var incoming: [CourierIncomingFile] = []
        let scratch = directory.appendingPathComponent("Fetched-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (file, data) in changes where zones.contains(zone(of: file.id)) {
            if now.timeIntervalSince(file.createdAt) >= policy.expiry { service.delete(file.id); outbox.forget(file.id); continue }
            guard role.contains(.receive), receiver != nil, file.deviceID != deviceID else { continue }
            outbox.noteKnown(file.id, createdAt: file.createdAt)
            let url = scratch.appendingPathComponent(file.id)
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try data.write(to: url)
            } catch { continue }
            incoming.append(CourierIncomingFile(file: file, contents: url))
        }
        if let receiver, !incoming.isEmpty {
            delivered += incoming.map(\.file.id)
            let settled = await receiver(incoming)
            for id in settled { service.delete(id); outbox.forget(id) }
        }
        outbox.save(now: now)
        publish()
    }

    public func removeExpired() async {
        guard availability == .available else { return }
        let now = clock()
        for id in outbox.expired(now: now) { service.delete(id); outbox.forget(id) }
        outbox.save(now: now)
        publish()
    }

    public func status() async -> CourierStatus { outbox.status(availability: availability) }

    public func forgetPlaintext() async {
        for id in outbox.dropPlaintext(now: clock()) { service.delete(id) }
        outbox.save(now: clock())
        publish()
    }

    private func publish() { onStatus?(outbox.status(availability: availability)) }
}
