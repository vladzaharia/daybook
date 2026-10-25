import CloudKit
import DaybookCore
import Foundation
#if os(macOS)
import Security
#endif

/// The courier over CloudKit (docs/icloud-sync.md, "Courier (CloudKit)"): a `CKSyncEngine` on the private database
/// of the app's container, with one custom zone, `Courier`, and one `CourierFile` record per journal file, named by
/// its library and path so a resend replaces itself. The engine schedules sends and fetches, subscribes to the
/// database for pushes, and retries network failures and rate limits itself; this courier retries refusals for lack
/// of storage with a growing delay, deletes what a Mac stored and anything older than seven days, and turns itself
/// off quietly when CloudKit can't be used.
public actor CloudKitCourier: SyncCourier {
    public static let zoneName = "Courier"
    public static let recordType = "CourierFile"

    enum Field {
        static let path = "path", sha256 = "sha256", size = "size", deviceID = "deviceID"
        static let libraryID = "libraryID", createdAt = "createdAt", asset = "asset"
    }

    private let containerIdentifier: String
    private let deviceID: String
    private let directory: URL
    private let policy: CourierPolicy
    private let outbox: CourierOutbox
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitCourier.zoneName, ownerName: CKCurrentUserDefaultName)
    private var engine: CKSyncEngine?
    private var role: CourierRole = []
    private var receiver: CourierReceiver?
    private var onStatus: (@Sendable (CourierStatus) -> Void)?
    private var availability: CourierAvailability = .checking
    private var stopped = false
    /// Saves refused for reasons that won't pass (a schema missing in Production, say), in a row.
    private var refusals = 0
    private var retryTask: Task<Void, Never>?
    private var accountObserver: (any NSObjectProtocol)?

    /// A courier for this app, or nil when this build isn't signed for CloudKit with the container (development and ad
    /// hoc builds, tests). Creating a `CKContainer` without the entitlement stops the app, so nothing here touches
    /// CloudKit until that's known. `directory` keeps the outbox and the engine's state (`Sync/Courier` in the library).
    public static func ifEntitled(containerIdentifier: String?, directory: URL, deviceID: String,
                                  policy: CourierPolicy = CourierPolicy()) -> CloudKitCourier? {
        guard let identifier = SyncContainerEnvironment.valid(containerIdentifier), isEntitled(for: identifier) else { return nil }
        return CloudKitCourier(containerIdentifier: identifier, directory: directory, deviceID: deviceID, policy: policy)
    }

    /// Whether the running app is signed for CloudKit with `identifier`. On macOS this reads the code signature. iOS
    /// has no API for it; a build that runs on an iPhone is signed with the project's entitlements (CloudKit included),
    /// and the app never creates a courier in tests.
    static func isEntitled(for identifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        func strings(_ key: String) -> [String] { SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? [String] ?? [] }
        return strings("com.apple.developer.icloud-services").contains("CloudKit")
            && strings("com.apple.developer.icloud-container-identifiers").contains(identifier)
        #else
        return true
        #endif
    }

    init(containerIdentifier: String, directory: URL, deviceID: String, policy: CourierPolicy) {
        self.containerIdentifier = containerIdentifier; self.directory = directory; self.deviceID = deviceID; self.policy = policy
        outbox = CourierOutbox(directory: directory, policy: policy)
    }

    // MARK: SyncCourier

    public func start(role: CourierRole, receiver: CourierReceiver?, onStatus: @escaping @Sendable (CourierStatus) -> Void) async -> CourierAvailability {
        self.role = role; self.receiver = receiver; self.onStatus = onStatus
        stopped = false
        observeAccount()
        if engine == nil { await connect() }
        publish()
        return availability
    }

    public func stop() async {
        stopped = true
        retryTask?.cancel(); retryTask = nil
        if let engine { await engine.cancelOperations() }
        engine = nil
        availability = .unavailable("Sync is off")
        publish()
    }

    public func send(_ files: [CourierOutgoingFile]) async {
        guard role.contains(.send), !stopped, availability == .available, let engine else { return }
        let taken = outbox.accept(files, now: Date())
        guard !taken.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: taken.map { .saveRecord(recordID($0.id)) })
        publish()
    }

    public func flush() async {
        guard let engine, availability == .available else { return }
        requeueDue()
        do { try await engine.sendChanges() } catch { note(error) }
        publish()
    }

    public func fetch() async {
        guard let engine, availability == .available else { return }
        do { try await engine.fetchChanges() } catch { note(error) }
        publish()
    }

    public func removeExpired() async {
        guard let engine, availability == .available else { return }
        let expired = outbox.expired(now: Date())
        guard !expired.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: expired.map { .deleteRecord(recordID($0)) })
        outbox.save()
        publish()
    }

    public func status() async -> CourierStatus { outbox.status(availability: availability) }

    // MARK: Connecting

    /// Checks the account and creates the engine. Without an account (or while it can't be determined) the courier
    /// stays off and tries again when the account changes.
    private func connect() async {
        let container = CKContainer(identifier: containerIdentifier)
        let account: CKAccountStatus
        do { account = try await container.accountStatus() } catch { return turnOff(error.localizedDescription) }
        guard !stopped, engine == nil else { return }
        switch account {
        case .available: break
        case .noAccount: return turnOff("No iCloud account")
        case .restricted: return turnOff("iCloud is restricted on this device")
        case .temporarilyUnavailable: return turnOff("iCloud is temporarily unavailable")
        case .couldNotDetermine: return turnOff("The iCloud account couldn’t be checked")
        @unknown default: return turnOff("The iCloud account couldn’t be checked")
        }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: loadState(), delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        availability = .available
        refusals = 0
        if role.contains(.send) { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
        requeueDue()
        await removeExpired()
    }

    private func turnOff(_ reason: String) {
        availability = .unavailable(reason)
        outbox.dropAllWaiting(now: Date())
        outbox.save()
        publish()
    }

    /// CloudKit won't serve this container for this app or account (a restricted managed account, a container or
    /// entitlement it doesn't recognize). Retrying wouldn't help until something changes.
    static func isUnusable(_ error: CKError) -> Bool {
        switch error.code {
        case .badContainer, .badDatabase, .missingEntitlement, .permissionFailure, .managedAccountRestricted, .incompatibleVersion:
            return true
        default:
            return false
        }
    }

    /// Turns the courier off and lets the engine go, after the event being handled (the engine mustn't be driven
    /// from its own delegate). An account change, or the next launch, tries again.
    private func giveUp(_ reason: String) {
        retryTask?.cancel(); retryTask = nil
        turnOff(reason)
        Task { await self.releaseEngine() }
    }

    private func releaseEngine() async {
        guard let engine, availability != .available else { return }
        self.engine = nil
        await engine.cancelOperations()
    }

    private func observeAccount() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            Task { await self.accountChanged() }
        }
    }

    /// The engine follows account changes itself once it exists; before that, try again.
    private func accountChanged() async {
        guard engine == nil, !stopped else { return }
        availability = .checking
        await connect()
        publish()
    }

    // MARK: Sending

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    /// Puts every file that's due back in the engine's pending changes, and waits for the next one that isn't.
    private func requeueDue() {
        guard let engine else { return }
        let now = Date()
        let pending = Set(engine.state.pendingRecordZoneChanges)
        let due = outbox.due(now: now).map { CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID($0.id)) }.filter { !pending.contains($0) }
        if !due.isEmpty { engine.state.add(pendingRecordZoneChanges: due) }
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel(); retryTask = nil
        guard let next = outbox.nextRetry else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.retryDue()
        }
    }

    private func retryDue() async {
        retryTask = nil
        requeueDue()
        publish()
    }

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let entry = outbox.waiting(id.recordName) else { return nil }
        let staged = outbox.stagedURL(id.recordName)
        guard FileManager.default.fileExists(atPath: staged.path) else {
            outbox.drop(id.recordName, now: Date())
            return nil
        }
        let file = entry.file
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record[Field.path] = file.journal.path as NSString
        record[Field.sha256] = file.journal.sha256 as NSString
        record[Field.size] = NSNumber(value: file.journal.size)
        record[Field.deviceID] = file.deviceID as NSString
        record[Field.libraryID] = file.libraryID.uuidString as NSString
        record[Field.createdAt] = file.createdAt as NSDate
        record[Field.asset] = CKAsset(fileURL: staged)
        return record
    }

    static func file(from record: CKRecord) -> CourierFile? {
        guard let path = record[Field.path] as? String, let sha256 = record[Field.sha256] as? String,
              let size = (record[Field.size] as? NSNumber)?.int64Value, let deviceID = record[Field.deviceID] as? String,
              let library = (record[Field.libraryID] as? String).flatMap(UUID.init(uuidString:)),
              let createdAt = record[Field.createdAt] as? Date else { return nil }
        let file = CourierFile(libraryID: library, journal: SyncJournalFile(path: path, sha256: sha256, size: size),
                               deviceID: deviceID, createdAt: createdAt)
        return file.journal.isContentAddressed && file.id == record.recordID.recordName ? file : nil
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        let now = Date()
        var resend: [CKSyncEngine.PendingRecordZoneChange] = []
        var zoneMissing = false
        for record in sent.savedRecords {
            outbox.markSent(record.recordID.recordName, now: now)
            refusals = 0
        }
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID, name = id.recordName
            let reason = failure.error.localizedDescription
            switch failure.error.code {
            case .serverRecordChanged:
                // The server has a record by this name: the same file, sent before. Names are content addresses.
                outbox.markSent(name, now: now)
            case .zoneNotFound, .userDeletedZone:
                zoneMissing = true; resend.append(.saveRecord(id))
            case .unknownItem:
                resend.append(.saveRecord(id))
            case .quotaExceeded:
                outbox.markRetry(name, error: reason, storageFull: true, now: now)
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
                 .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
                // CKSyncEngine retries these itself, when the network is back and after any retry-after.
                outbox.noteTransient(name, error: reason)
            case .assetFileNotFound, .assetFileModified, .limitExceeded:
                outbox.drop(name, now: now, error: reason)
            default:
                outbox.drop(name, now: now, error: reason)
                refusals += Self.isUnusable(failure.error) ? 3 : 1
            }
        }
        if zoneMissing { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
        if !resend.isEmpty { engine.state.add(pendingRecordZoneChanges: resend) }
        for id in sent.deletedRecordIDs { outbox.forget(id.recordName) }
        for (id, error) in sent.failedRecordDeletes {
            switch error.code {
            case .unknownItem, .zoneNotFound, .userDeletedZone: outbox.forget(id.recordName)
            default: break  // Still known: the next expiry pass deletes it.
            }
        }
        // Saves that keep failing for reasons that won't pass would upload every recording for nothing.
        if refusals >= 3 {
            engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges.filter {
                if case .saveRecord = $0 { return true } else { return false }
            })
            giveUp(outbox.ledger.lastError ?? "CloudKit refused the courier’s files")
            return
        }
        scheduleRetry()
        outbox.save(now: now)
    }

    // MARK: Receiving

    private func receive(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, engine: CKSyncEngine) async {
        let now = Date()
        var incoming: [CourierIncomingFile] = []
        var delete: [String] = []
        for modification in changes.modifications {
            let record = modification.record
            guard record.recordID.zoneID == zoneID, record.recordType == Self.recordType else { continue }
            guard let file = Self.file(from: record) else {
                // Nobody can use a malformed file; the receiver clears it.
                if role.contains(.receive) { delete.append(record.recordID.recordName) }
                continue
            }
            if now.timeIntervalSince(file.createdAt) >= policy.expiry { delete.append(file.id); continue }
            guard role.contains(.receive), receiver != nil, file.deviceID != deviceID,
                  let url = (record[Field.asset] as? CKAsset)?.fileURL else { continue }
            outbox.noteKnown(file.id, createdAt: file.createdAt)
            incoming.append(CourierIncomingFile(file: file, contents: url))
        }
        for deletion in changes.deletions { outbox.forget(deletion.recordID.recordName) }
        if let receiver, !incoming.isEmpty {
            // Asset files are in CloudKit's staging area, which the system clears: the receiver copies them now.
            let settled = await receiver(incoming)
            delete += incoming.map(\.file.id).filter(settled.contains)
        }
        if !delete.isEmpty { engine.state.add(pendingRecordZoneChanges: delete.map { .deleteRecord(recordID($0)) }) }
        outbox.save(now: now)
    }

    // MARK: State

    private var stateURL: URL { directory.appendingPathComponent("cloudkit-state.json") }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            // Without the saved state the engine starts over next launch: it fetches again, which is harmless.
        }
    }

    private func note(_ error: Error) {
        guard !(error is CancellationError) else { return }
        if let error = error as? CKError, Self.isUnusable(error) { return giveUp(error.localizedDescription) }
        outbox.noteError(error.localizedDescription)
    }

    private func publish() { onStatus?(outbox.status(availability: availability)) }
}

extension CloudKitCourier: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)
        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                availability = .available
                if role.contains(.send) { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
            case .signOut:
                // The engine has dropped its pending changes; nothing here belongs to the new state of things.
                outbox.reset()
                availability = .unavailable("Signed out of iCloud")
            case .switchAccounts:
                outbox.reset()
                availability = .available
                if role.contains(.send) { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
            @unknown default:
                break
            }
            outbox.save()
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                switch deletion.reason {
                case .purged, .encryptedDataReset:
                    // The person removed the app's iCloud data: keep nothing and resend nothing.
                    outbox.reset()
                case .deleted:
                    if role.contains(.send) { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
                @unknown default:
                    break
                }
            }
            outbox.save()
        case .fetchedRecordZoneChanges(let changes):
            await receive(changes, engine: syncEngine)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves where failure.zone.zoneID == zoneID { note(failure.error) }
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine)
        case .didFetchRecordZoneChanges(let fetched):
            if fetched.zoneID == zoneID, let error = fetched.error { note(error) }
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
        publish()
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let now = Date()
        var ready: [CKSyncEngine.PendingRecordZoneChange] = []
        var dropped: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in syncEngine.state.pendingRecordZoneChanges where scope.contains(change) {
            switch change {
            case .saveRecord(let id):
                // Not waiting any more (sent, given up), or waiting out a refusal: the retry adds it back when due.
                if outbox.isDue(id.recordName, now: now) { ready.append(change) } else { dropped.append(change) }
            case .deleteRecord:
                ready.append(change)
            @unknown default:
                break
            }
        }
        if !dropped.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: dropped); scheduleRetry() }
        guard !ready.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: ready) { [weak self] id in
            await self?.record(for: id)
        }
    }

    public func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        // A device that only sends never downloads the zone: it would fetch its own recordings back.
        guard !role.contains(.receive) else { return context.options }
        var options = context.options
        options.scope = .allExcluding([zoneID])
        return options
    }
}
