import Combine
import DaybookCore
import Foundation
#if os(macOS)
import Security
#endif

/// Where library sync runs.
public enum SyncTransport: String, Sendable {
    case none
    /// The app's own iCloud container, `<container>/Documents/Daybook`: the product setup on Mac and iPhone.
    case iCloudContainer
    /// A folder someone chose: development builds without iCloud entitlements, and tests.
    case folder
}

/// What iCloud sync is doing on this device, in the terms Settings uses.
public enum ICloudSyncState: Equatable, Sendable {
    case checking
    /// This build can't use iCloud: Info.plist names no container, or the app isn't signed with the iCloud
    /// entitlement (unsigned and ad hoc development builds, tests). See `developmentFolderSyncKey`.
    case unavailableInThisBuild
    /// Sync was turned off on this device.
    case turnedOff
    /// No iCloud account is signed in.
    case signedOut
    /// iCloud Drive is off in System Settings (or, when that can't be told apart, no account is signed in).
    case iCloudDriveOff
    /// Signed in and entitled, but the container couldn't be reached.
    case containerUnavailable(String)
    /// A different iCloud account from the one this library synced with. Paused until the person chooses.
    case accountChanged
    /// The folder this Mac synced through before can't be found, so its journal can't be moved yet.
    case previousFolderMissing
    /// Copying the previous sync folder's journal into the container.
    case migrating(SyncMigrationProgress)
    /// Syncing with iCloud.
    case connected
}

/// The one-time move from a chosen folder to the iCloud container, as recorded on this device.
public struct SyncMigrationRecord: Codable, Equatable, Sendable {
    public var sourcePath: String
    public var container: String
    public var startedAt: Date
    /// When sync moved to the container: the manifest, events, and metadata were all copied.
    public var switchedAt: Date?
    /// When every file was copied, audio included.
    public var completedAt: Date?
    public var copiedFiles = 0
    public var totalFiles = 0
    public var remainingFiles = 0
    public var sourceLibraryID: UUID?
    public var containerLibraryID: UUID?
    /// The container already held a different library; this device's checkpoint was carried over to it.
    public var adoptedCheckpoint = false
    public var skipped: [String] = []
    /// The previous folder couldn't be found and the person chose to sync without it.
    public var abandoned = false

    public init(sourcePath: String, container: String, startedAt: Date = Date()) {
        self.sourcePath = sourcePath; self.container = container; self.startedAt = startedAt
    }
}

/// What the controller asks of the system about iCloud. Tests supply their own.
public struct SyncContainerEnvironment: Sendable {
    public static let infoKey = "DaybookICloudContainerIdentifier"
    /// Info.plist's `DaybookICloudContainerIdentifier`; nil when it's missing or unexpanded.
    public var containerIdentifier: String?
    /// Whether the running app is signed with the iCloud entitlement for the container. On macOS this reads
    /// the code signature; elsewhere it trusts Info.plist and lets container resolution decide.
    public var hasEntitlement: @Sendable (String) -> Bool
    /// The signed-in iCloud account, archived (`FileManager.ubiquityIdentityToken`); nil when there's no
    /// account or iCloud Drive is off.
    public var accountIdentity: @Sendable () -> Data?
    /// Whether any iCloud account is signed in, to tell "signed out" from "iCloud Drive off"; nil if unknown.
    public var accountSignedIn: @Sendable () -> Bool?
    /// `FileManager.url(forUbiquityContainerIdentifier:)`. Called off the main actor.
    public var resolveContainer: @Sendable (String) -> URL?
    public var cloud: SyncCloudFiles
    /// How long to wait before retrying a migration that's waiting for iCloud downloads.
    public var retryInterval: Duration

    public init(containerIdentifier: String?, hasEntitlement: @escaping @Sendable (String) -> Bool,
                accountIdentity: @escaping @Sendable () -> Data?, accountSignedIn: @escaping @Sendable () -> Bool? = { nil },
                resolveContainer: @escaping @Sendable (String) -> URL?, cloud: SyncCloudFiles = .system,
                retryInterval: Duration = .seconds(5)) {
        self.containerIdentifier = Self.valid(containerIdentifier)
        self.hasEntitlement = hasEntitlement; self.accountIdentity = accountIdentity; self.accountSignedIn = accountSignedIn
        self.resolveContainer = resolveContainer; self.cloud = cloud; self.retryInterval = retryInterval
    }

    public static var system: SyncContainerEnvironment {
        SyncContainerEnvironment(
            containerIdentifier: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
            hasEntitlement: { identifier in
                #if os(macOS)
                return signedUbiquityContainers().contains(identifier)
                #else
                return true
                #endif
            },
            accountIdentity: {
                FileManager.default.ubiquityIdentityToken.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) }
            },
            accountSignedIn: {
                #if os(macOS)
                // Best effort: the Apple Account list in the user's preferences (only whether it's empty is
                // read). Unknown when it can't be read.
                return (UserDefaults(suiteName: "MobileMeAccounts")?.array(forKey: "Accounts")).map { !$0.isEmpty }
                #else
                return nil
                #endif
            },
            resolveContainer: { FileManager.default.url(forUbiquityContainerIdentifier: $0) })
    }

    static func valid(_ identifier: String?) -> String? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespaces), !identifier.isEmpty, !identifier.contains("$(") else { return nil }
        return identifier
    }

    #if os(macOS)
    /// The `com.apple.developer.ubiquity-container-identifiers` this process is signed with.
    static func signedUbiquityContainers() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-container-identifiers" as CFString, nil) as? [String] ?? []
    }
    #endif
}

@MainActor
public final class LibrarySyncController: ObservableObject {
    @Published public private(set) var folder: URL?
    @Published public private(set) var isICloudLocation = false
    @Published public private(set) var status = "iCloud sync is off"
    @Published public private(set) var isSyncing = false { didSet { if oldValue && !isSyncing { passEnded() } } }
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var warnings: [String] = []
    @Published public private(set) var pendingDownloads = 0
    @Published public private(set) var pendingUploads = 0
    /// Where sync runs now.
    @Published public private(set) var transport: SyncTransport = .none
    /// iCloud container sync, for Settings.
    @Published public private(set) var iCloud: ICloudSyncState
    /// The move from a previously chosen folder into the container, when there was one.
    @Published public private(set) var migrationRecord: SyncMigrationRecord?
    public var onSyncRequested: (() async -> Void)?
    private let localRoot: URL
    private let defaults: UserDefaults
    public let environment: SyncContainerEnvironment
    /// This replica's identity in the sync journal, kept in preferences.
    public let deviceID: String
    /// The container sync uses, once restored.
    public private(set) var containerIdentifier: String?
    /// The engine for the connected library: on-demand audio (`fetchAudio`, `evictAudio`), presence
    /// (`knownDevices`), and the cheap `hasRemoteChanges` check.
    public private(set) var engine: LibrarySyncEngine?
    /// The last pass stopped at its `SyncPassLimits`; run another soon.
    @Published public private(set) var hasMoreWork = false
    private var activeTask: Task<SyncResult, Error>?
    private var pendingReceipt: UUID?
    private var polling: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var debounceToken = UUID()
    private var passEndWaiters: [CheckedContinuation<Void, Never>] = []
    /// How long a request waits before it runs a pass, so a burst of edits makes one. Nil: requests never run a
    /// pass on their own; test rigs drive passes themselves.
    public var syncDebounce: Duration? = .seconds(2)
    /// A requested pass is waiting out `syncDebounce` or running.
    public var hasPendingSyncRequest: Bool { debounce != nil }
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var scopedURL: URL?
    private var configurationID = UUID()
    private var containerTask: Task<Void, Never>?
    private var migrationTask: Task<Void, Never>?
    private var containerGeneration = UUID()
    private var accountObserver: NSObjectProtocol?

    /// Unsigned and ad hoc development builds can't use the iCloud container. Setting this preference
    /// (`-DaybookDevelopmentFolderSync YES` as a launch argument, or `defaults write`) brings back the folder
    /// transport there: Settings offers Choose Folder… and a chosen folder is restored at launch. Builds signed
    /// for iCloud ignore it. See docs/icloud-sync.md, "Development builds".
    public static let developmentFolderSyncKey = "DaybookDevelopmentFolderSync"

    private enum Key {
        static let folderBookmark = "syncFolderBookmark"
        static let migratedFolderBookmark = "syncMigratedFolderBookmark"
        static let migration = "syncContainerMigration"
        static let account = "syncICloudAccount"
        static let turnedOff = "syncICloudTurnedOff"
    }

    public init(localRoot: URL, defaults: UserDefaults, environment: SyncContainerEnvironment = .system) {
        self.localRoot = localRoot; self.defaults = defaults; self.environment = environment
        deviceID = defaults.string(forKey: "syncDeviceID") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "syncDeviceID")
        lastSync = defaults.object(forKey: "syncLastCompleted") as? Date
        migrationRecord = defaults.data(forKey: Key.migration).flatMap { try? JSONDecoder().decode(SyncMigrationRecord.self, from: $0) }
        let usable = environment.containerIdentifier.map(environment.hasEntitlement) ?? false
        iCloud = usable ? .checking : .unavailableInThisBuild
    }

    /// Whether this build may sync through a chosen folder: only without iCloud, and only when asked for.
    public var allowsFolderSync: Bool {
        iCloud == .unavailableInThisBuild && defaults.bool(forKey: Self.developmentFolderSyncKey)
    }

    /// Starts sync at launch. With the iCloud entitlement and an account, sync uses the app's container
    /// automatically, moving a previously chosen folder's journal there first (once). Builds without iCloud
    /// stay off, unless `developmentFolderSyncKey` brings back the chosen folder.
    /// Returns once the container lookup that `restore()` (or a retry) started has finished, whether it
    /// connected or failed; `folder` and `iCloud` then say which. The lookup runs in the background, so
    /// reading `folder` right after `restore()` sees nil until it's done.
    public func waitForContainer() async {
        while let task = containerTask {
            await task.value
            if task == containerTask { return }
        }
    }

    public func restore() {
        guard let identifier = environment.containerIdentifier, environment.hasEntitlement(identifier) else {
            iCloud = .unavailableInThisBuild
            if allowsFolderSync { restoreFolder() }
            else if folder == nil { status = "iCloud sync isn’t available in this build" }
            return
        }
        startContainer(identifier)
    }

    private func restoreFolder() {
        guard let data = defaults.data(forKey: Key.folderBookmark) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: Self.bookmarkResolution, relativeTo: nil, bookmarkDataIsStale: &stale)
            try connect(to: url)
            if stale { try saveBookmark(url) }
        } catch { status = "Reconnect your iCloud folder: \(error.localizedDescription)" }
    }

    /// Connects a folder the person chose (an open panel on the Mac, the Files picker on iPhone)
    /// and remembers it with a security-scoped bookmark. The folder transport: development and tests.
    public func connectChosenFolder(_ url: URL) {
        do { try connect(to: url); try saveBookmark(url) }
        catch { status = "Couldn’t connect: \(error.localizedDescription)" }
    }

    /// Turns iCloud sync back on after `disconnect()` turned it off.
    public func turnOnICloudSync() {
        defaults.removeObject(forKey: Key.turnedOff)
        guard let identifier = containerIdentifier ?? environment.containerIdentifier else { return }
        startContainer(identifier)
    }

    /// After the iCloud account changed: sync this library with the account that's signed in now.
    public func useCurrentICloudAccount() {
        defaults.removeObject(forKey: Key.account)
        guard let identifier = containerIdentifier else { return }
        startContainer(identifier)
    }

    /// Tries the move to iCloud again (for example after the previous folder becomes available).
    public func retryContainer() {
        guard let identifier = containerIdentifier ?? environment.containerIdentifier else { return }
        startContainer(identifier)
    }

    /// The previous sync folder can't be found: sync with iCloud without moving its journal. The folder,
    /// wherever it is, is left alone; this Mac's library still publishes everything it holds.
    public func continueWithoutPreviousFolder() {
        guard let identifier = containerIdentifier else { return }
        var record = migrationRecord ?? SyncMigrationRecord(sourcePath: "", container: identifier)
        record.abandoned = true; record.switchedAt = record.switchedAt ?? Date()
        saveMigration(record)
        retireFolderBookmark()
        startContainer(identifier)
    }

    private func saveBookmark(_ url: URL) throws {
        let data = try url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Key.folderBookmark)
    }

    // A sandboxed Mac keeps access through a security-scoped bookmark. On iPhone a folder picked in
    // Files is security-scoped already; its bookmark is a minimal one, resolved the same way.
    #if os(macOS)
    private static let bookmarkCreation: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    private static let bookmarkCreation: URL.BookmarkCreationOptions = [.minimalBookmark]
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif

    /// Syncs through a folder (the folder transport).
    public func connect(to url: URL, monitorChanges: Bool = true) throws {
        try attach(url, transport: .folder, monitorChanges: monitorChanges)
        containerTask?.cancel(); containerTask = nil; migrationTask?.cancel(); migrationTask = nil
    }

    private func attach(_ url: URL, transport: SyncTransport, monitorChanges: Bool) throws {
        guard !isSyncing else { throw SyncControllerError.busy }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let local = localRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard root != local, !root.path.hasPrefix(local.path + "/"), !local.path.hasPrefix(root.path + "/") else { throw SyncControllerError.overlappingLibrary }
        stopMonitoring()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        do { engine = try LibrarySyncEngine(localRoot: localRoot, remoteRoot: url, deviceID: deviceID, replica: replica) }
        catch { scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil; throw error }
        folder = url; self.transport = transport; status = "Connected · preparing sync"; configurationID = UUID()
        isICloudLocation = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true || root.path.contains("/Library/Mobile Documents/")
        // Other devices learn this one exists (and what it is) right away, not only after its first full
        // pass, which can take minutes on a new library. Presence is advisory, so a failure is ignored.
        if let engine, replica.device != nil { Task { try? await engine.publishPresence() } }
        startCourier()
        if monitorChanges { startMonitoring(url); requestSync() }
    }

    /// Stops syncing. A chosen folder is forgotten; iCloud sync is turned off on this device until
    /// `turnOnICloudSync()`. Local and iCloud copies are kept either way.
    public func disconnect() {
        guard !isSyncing else { return }
        stopCourier()
        if transport == .iCloudContainer || (transport == .none && containerIdentifier != nil) {
            defaults.set(true, forKey: Key.turnedOff)
            containerTask?.cancel(); containerTask = nil; migrationTask?.cancel(); migrationTask = nil
            containerGeneration = UUID()
            configurationID = UUID(); stopMonitoring(); engine = nil; folder = nil; transport = .none
            iCloud = .turnedOff
            status = "iCloud sync is off. Local and iCloud copies are retained."; warnings = []; pendingDownloads = 0
            return
        }
        configurationID = UUID(); stopMonitoring(); engine = nil; folder = nil; transport = .none
        defaults.removeObject(forKey: Key.folderBookmark)
        status = "Sync is off. Local and iCloud copies are retained."; warnings = []; pendingDownloads = 0
    }

    public func requestSync() {
        guard folder != nil else { return }
        debounce?.cancel(); debounce = nil
        guard let delay = syncDebounce else { return }
        let token = UUID()
        debounceToken = token
        debounce = Task { [weak self] in
            if (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled { await self?.onSyncRequested?() }
            if self?.debounceToken == token { self?.debounce = nil }
        }
    }

    /// Returns once no requested pass is waiting or running: for tests, and for anything that must not overlap one.
    public func awaitIdle() async {
        while true {
            if let task = debounce { await task.value; if debounce == task { debounce = nil }; continue }
            if isSyncing { await waitForPassToEnd(); continue }
            return
        }
    }

    /// Returns when the pass in flight (if any) has ended: acknowledged, failed, or cancelled and unwound.
    private func waitForPassToEnd() async {
        guard isSyncing else { return }
        await withCheckedContinuation { passEndWaiters.append($0) }
    }

    private func passEnded() {
        let waiters = passEndWaiters
        passEndWaiters = []
        waiters.forEach { $0.resume() }
    }

    public func deferUntilIdle() { if folder != nil && !isSyncing { status = "Waiting for recording or local processing to finish" } }

    public func synchronize(meetings: [Meeting], deletedMeetingIDs: Set<UUID>, metadata: Data,
                            limits: SyncPassLimits = .unlimited, protecting: Set<UUID> = []) async throws -> SyncResult? {
        try Task.checkCancellation()
        guard let engine, !isSyncing else { return nil }
        let generation = configurationID
        isSyncing = true; status = "Syncing recordings and conversations…"
        do {
            let task = Task { try await engine.synchronize(meetings: meetings, deletedMeetingIDs: deletedMeetingIDs, libraryMetadata: metadata,
                                                           limits: limits, protecting: protecting) }
            activeTask = task
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            activeTask = nil
            try Task.checkCancellation()
            guard generation == configurationID else { isSyncing = false; return nil }
            handToCourier(result.writtenFiles, engine: engine)
            pendingReceipt = result.checkpointID
            pendingDownloads = result.pendingDownloads; pendingUploads = result.pendingUploads; warnings = result.warnings
            hasMoreWork = result.hasMoreWork
            status = "Applying library changes…"
            return result
        } catch {
            activeTask = nil; isSyncing = false; pendingReceipt = nil
            status = "Sync paused: \(error.localizedDescription)"; throw error
        }
    }

    public func canApply(_ result: SyncResult) -> Bool { pendingReceipt == result.checkpointID && folder != nil }

    public func acknowledge(_ result: SyncResult) async throws {
        guard let engine, canApply(result) else { throw SyncControllerError.busy }
        defer { isSyncing = false; pendingReceipt = nil }
        try await engine.acknowledge(result.checkpointID)
        guard canApply(result) else { throw SyncControllerError.busy }
        status = result.hasPendingTransfers ? "Waiting for iCloud: \(result.pendingUploads) upload(s), \(result.pendingDownloads) download(s)" : "Library changes exchanged"
        lastSync = Date(); defaults.set(lastSync, forKey: "syncLastCompleted")
    }

    public func reportFailure(_ message: String) { isSyncing = false; pendingReceipt = nil; status = "Sync paused: " + message }

    // MARK: Presence

    /// How this replica describes itself to the other devices (its presence record) and keeps
    /// audio. Set it before connecting; `updatePresence(_:)` changes a connected engine's identity.
    /// The default writes no presence, as before presence existed.
    public var replica = SyncReplicaConfiguration()

    /// Changes how this device describes itself, for example when a Mac gains or loses the models
    /// it needs. The next pass rewrites the presence record.
    public func updatePresence(_ device: SyncDeviceIdentity?) {
        guard replica.device != device else { return }
        replica.device = device
        guard let engine else { return }
        Task { await engine.updateDevice(device) }
    }

    /// Devices known to the library, most recently seen first (presence records, and devices seen
    /// only in the journal). Empty while sync is off.
    public func knownDevices() async -> [KnownSyncDevice] {
        guard let engine else { return [] }
        return (try? await engine.knownDevices()) ?? []
    }

    /// Whether sync has published `id`'s deletion from this device's point of view (any library it synced),
    /// so that ID is deleted everywhere. Works with sync off too.
    public func isSyncedDeletion(_ id: UUID) -> Bool {
        LibrarySyncEngine.recordsDeletion(of: id, localRoot: localRoot, deviceID: deviceID)
    }

    /// The sync library's ID (its manifest's), once a pass has read it.
    public func libraryID() async -> UUID? {
        guard let engine else { return nil }
        return await engine.libraryID
    }

    // MARK: Courier

    /// The fast path beside iCloud Drive (docs/icloud-sync.md, "Courier (CloudKit)"): the iPhone sends the files its
    /// passes write, a Mac receives them into the engine's inbox. Set it and `courierRole` before connecting. Nil, or
    /// unavailable: iCloud Drive carries everything, exactly as without a courier.
    public var courier: (any SyncCourier)?
    public var courierRole: CourierRole = []
    /// The courier's state for the sync status: how many files wait to send, and whether a send is stuck.
    @Published public private(set) var courierStatus = CourierStatus()
    /// Called once the courier is available. The apps register for remote notifications, which CKSyncEngine needs.
    public var onCourierAvailable: (() -> Void)?
    private var courierStart: Task<Void, Never>?
    private var courierSends: Task<Void, Never>?
    private var courierExpiryCheck: Date?

    private func startCourier() {
        guard let courier, !courierRole.isEmpty, courierStart == nil else { return }
        let role = courierRole
        weak let weakSelf = self
        var receiver: CourierReceiver?
        if role.contains(.receive) {
            receiver = { files in await weakSelf?.receiveCourierFiles(files) ?? [] }
        }
        let onStatus: @Sendable (CourierStatus) -> Void = { status in
            Task { @MainActor in weakSelf?.courierStatus = status }
        }
        courierStart = Task {
            let availability = await courier.start(role: role, receiver: receiver, onStatus: onStatus)
            guard availability == .available else { return }
            weakSelf?.onCourierAvailable?()
            if role.contains(.receive) { await courier.fetch() }
        }
    }

    private func stopCourier() {
        guard let courier, let start = courierStart else { return }
        courierStart = nil
        Task { await start.value; await courier.stop() }
    }

    /// Hands the files a pass wrote to the courier and asks it to send them now. Each file is sent once, however
    /// often a pass reports it. Expired courier files are cleared at most hourly, after a pass.
    private func handToCourier(_ files: [SyncJournalFile], engine: LibrarySyncEngine) {
        guard let courier, let start = courierStart else { return }
        let now = Date()
        if courierExpiryCheck.map({ now.timeIntervalSince($0) >= 3_600 }) ?? true {
            courierExpiryCheck = now
            Task { await start.value; await courier.removeExpired() }
        }
        guard courierRole.contains(.send), !files.isEmpty else { return }
        let deviceID = self.deviceID, previous = courierSends
        courierSends = Task {
            await start.value
            await previous?.value
            guard let libraryID = await engine.libraryID else { return }
            let outgoing = files.map { file in
                CourierOutgoingFile(libraryID: libraryID, journal: file, deviceID: deviceID) { try engine.copyJournalFile(file, to: $0) }
            }
            await courier.send(outgoing)
            await courier.flush()
        }
    }

    /// Waits until the courier has taken what the latest passes wrote and tried sending it. The iPhone waits under its
    /// background-task assertion. Returns at once if the calling task is cancelled; the courier carries on as the
    /// system allows, and iCloud Drive carries everything regardless.
    public func finishCourierSends() async {
        guard let sends = courierSends else { return }
        await TaskWaiter.wait(for: sends)
    }

    /// Asks the courier for what other devices sent (a push arrived).
    public func fetchCourier() {
        guard let courier, let start = courierStart else { return }
        Task { await start.value; await courier.fetch() }
    }

    /// Files a courier brought. Each is verified and kept in the engine's inbox, never written into the sync folder;
    /// a pass then applies them. Returns those the courier may delete: stored, already here, or rejected.
    private func receiveCourierFiles(_ files: [CourierIncomingFile]) async -> Set<String> {
        guard let engine else { return [] }
        var settled = Set<String>()
        var stored = false
        for incoming in files {
            guard let delivery = try? await engine.receiveCourierFile(incoming.file.journal, libraryID: incoming.file.libraryID,
                                                                      contents: incoming.contents) else { continue }
            if delivery == .stored { stored = true }
            if delivery.isSettled { settled.insert(incoming.file.id) }
        }
        if stored { requestSync() }
        return settled
    }

    // MARK: iCloud container

    private func startContainer(_ identifier: String) {
        containerIdentifier = identifier
        observeAccount()
        containerTask?.cancel(); migrationTask?.cancel(); migrationTask = nil
        let generation = UUID()
        containerGeneration = generation
        containerTask = Task { [weak self] in await self?.prepareContainer(identifier, generation: generation) }
    }

    private func isCurrent(_ generation: UUID) -> Bool { generation == containerGeneration && !Task.isCancelled }

    private func prepareContainer(_ identifier: String, generation: UUID) async {
        if transport == .iCloudContainer { detach() }
        if defaults.bool(forKey: Key.turnedOff) {
            iCloud = .turnedOff; status = "iCloud sync is off"; return
        }
        guard let account = environment.accountIdentity() else {
            if environment.accountSignedIn() == false {
                iCloud = .signedOut; status = "Signed out of iCloud"
            } else {
                iCloud = .iCloudDriveOff; status = "iCloud is off in System Settings"
            }
            return
        }
        if let previous = defaults.data(forKey: Key.account), !Self.sameAccount(previous, account) {
            iCloud = .accountChanged; status = "Sync paused: the iCloud account changed"
            return
        }
        iCloud = .checking; status = "Connecting to iCloud…"
        let resolve = environment.resolveContainer
        let container = await Task.detached(priority: .utility) { resolve(identifier) }.value
        guard isCurrent(generation) else { return }
        guard let container else {
            let reason = "iCloud isn’t available for Daybook. Check that iCloud Drive is on for Daybook in System Settings."
            iCloud = .containerUnavailable(reason); status = reason
            return
        }
        let root = container.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Daybook", isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            iCloud = .containerUnavailable(error.localizedDescription); status = "Couldn’t open iCloud: \(error.localizedDescription)"
            return
        }
        // The library is bound to this account from here on, so a change mid-migration pauses too.
        defaults.set(account, forKey: Key.account)
        guard await migrateFolder(into: root, identifier: identifier, generation: generation), isCurrent(generation) else { return }
        // An account change cancels the pass in flight, but it may still be unwinding (a long audio copy): attaching
        // now would be refused as busy and leave sync off. Wait for it.
        while isSyncing {
            await waitForPassToEnd()
            guard isCurrent(generation) else { return }
        }
        do {
            try attach(root, transport: .iCloudContainer, monitorChanges: true)
            iCloud = .connected
        } catch {
            iCloud = .containerUnavailable(error.localizedDescription); status = "Couldn’t connect iCloud: \(error.localizedDescription)"
            return
        }
        if let record = migrationRecord, record.switchedAt != nil, record.completedAt == nil, !record.abandoned {
            migrationTask = Task { [weak self] in await self?.finishMigration(into: root, identifier: identifier, generation: generation) }
        }
    }

    /// Moves a previously chosen folder's journal into the container, once. True when sync can switch over:
    /// there was nothing to move, or the manifest, events, and metadata are all copied. Waits (retrying)
    /// while iCloud downloads the source's files.
    private func migrateFolder(into root: URL, identifier: String, generation: UUID) async -> Bool {
        guard let bookmark = defaults.data(forKey: Key.folderBookmark) else { return true }
        guard let source = Self.resolve(bookmark) else {
            iCloud = .previousFolderMissing
            status = "Sync paused: the folder this Mac synced through can’t be found"
            return false
        }
        if Self.samePlace(source, root) {
            // An earlier build connected the container itself through a bookmark: nothing to move.
            retireFolderBookmark(); return true
        }
        var record = migrationRecord.flatMap { $0.sourcePath == source.path && $0.container == identifier ? $0 : nil }
            ?? SyncMigrationRecord(sourcePath: source.path, container: identifier)
        saveMigration(record)
        iCloud = .migrating(SyncMigrationProgress()); status = Self.migrationStatus(SyncMigrationProgress())
        let migration: LibrarySyncMigration
        do { migration = try LibrarySyncMigration(source: source, destination: root, localRoot: localRoot, deviceID: deviceID, cloud: environment.cloud) }
        catch {
            iCloud = .containerUnavailable(error.localizedDescription); status = "Couldn’t move sync to iCloud: \(error.localizedDescription)"
            return false
        }
        while isCurrent(generation) {
            switch await run(migration, generation: generation) {
            case .success(let outcome):
                record.update(with: outcome)
                if outcome.progress.journalComplete {
                    record.switchedAt = record.switchedAt ?? Date()
                    if outcome.progress.isComplete { record.completedAt = Date() }
                    saveMigration(record); retireFolderBookmark()
                    return true
                }
                saveMigration(record)
                iCloud = .migrating(outcome.progress)
                status = Self.migrationStatus(outcome.progress)
            case .failure(let error):
                if error is CancellationError { return false }
                status = "Moving sync to iCloud paused: \(error.localizedDescription)"
            }
            do { try await Task.sleep(for: environment.retryInterval) } catch { return false }
        }
        return false
    }

    /// After the switch, keeps copying the previous folder's remaining audio objects in the background.
    private func finishMigration(into root: URL, identifier: String, generation: UUID) async {
        guard let bookmark = defaults.data(forKey: Key.migratedFolderBookmark), let source = Self.resolve(bookmark),
              var record = migrationRecord,
              let migration = try? LibrarySyncMigration(source: source, destination: root, localRoot: localRoot, deviceID: deviceID, cloud: environment.cloud)
        else { return }
        while isCurrent(generation) {
            do { try await Task.sleep(for: environment.retryInterval * 6) } catch { return }
            guard isCurrent(generation) else { return }
            guard case .success(let outcome) = await run(migration, generation: generation) else { continue }
            record.update(with: outcome)
            if outcome.progress.isComplete { record.completedAt = Date() }
            saveMigration(record)
            if outcome.progress.isComplete { requestSync(); return }
        }
    }

    /// One pass of `migration`, with access to the previous folder for its duration.
    private func run(_ migration: LibrarySyncMigration, generation: UUID) async -> Result<SyncMigrationOutcome, Error> {
        let source = migration.source
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let outcome = try await migration.run { [weak self] progress in
                Task { @MainActor [weak self] in self?.showMigration(progress, generation: generation) }
            }
            return .success(outcome)
        } catch { return .failure(error) }
    }

    private func showMigration(_ progress: SyncMigrationProgress, generation: UUID) {
        guard generation == containerGeneration, case .migrating = iCloud else { return }
        iCloud = .migrating(progress); status = Self.migrationStatus(progress)
    }

    static func migrationStatus(_ progress: SyncMigrationProgress) -> String {
        guard progress.total > 0 else { return "Preparing to move sync to iCloud…" }
        let waiting = progress.waitingForDownload > 0 ? " Waiting for iCloud to download \(progress.waitingForDownload)." : ""
        return "Migrating \(progress.completed) of \(progress.total) files…" + waiting
    }

    private func saveMigration(_ record: SyncMigrationRecord) {
        migrationRecord = record
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Key.migration) }
    }

    /// The previous folder is never connected again. Its bookmark is kept apart, only to finish copying audio.
    private func retireFolderBookmark() {
        if let data = defaults.data(forKey: Key.folderBookmark) { defaults.set(data, forKey: Key.migratedFolderBookmark) }
        defaults.removeObject(forKey: Key.folderBookmark)
    }

    private func observeAccount() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accountDidChange() }
        }
    }

    /// Pauses: the pass in flight is cancelled and its receipt can't be acknowledged. Then the container is
    /// checked again, which waits for the person if the account is now a different one.
    private func accountDidChange() {
        guard transport != .folder, let identifier = containerIdentifier else { return }
        detach()
        startContainer(identifier)
    }

    private func detach() {
        if activeTask == nil { isSyncing = false }
        activeTask?.cancel(); configurationID = UUID(); pendingReceipt = nil
        stopMonitoring(); engine = nil; folder = nil; transport = .none
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: bookmarkResolution, relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func samePlace(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Identity tokens compare with `isEqual`; archives of the same token are usually identical bytes too.
    static func sameAccount(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        func token(_ data: Data) -> NSObject? {
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
        }
        guard let first = token(a), let second = token(b) else { return false }
        return first.isEqual(second)
    }

    // MARK: Monitoring

    private func startMonitoring(_ root: URL) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryUbiquitousDataScope, NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path + "/")
        query.notificationBatchingInterval = 2
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.requestSync() }
            })
        }
        self.query = query; query.start()
        // Reconcile after missed metadata events, sleep/wake, or a temporary offline period.
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.onSyncRequested?()
            }
        }
        // The container has its own account handling (`accountDidChange`). A chosen folder disconnects.
        guard transport == .folder else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.activeTask == nil { self.isSyncing = false }
                self.activeTask?.cancel(); self.configurationID = UUID(); self.pendingReceipt = nil; self.stopMonitoring(); self.engine = nil; self.folder = nil
                self.transport = .none
                self.defaults.removeObject(forKey: Key.folderBookmark)
                self.status = "Apple Account changed · reconnect the intended iCloud folder"
            }
        })
    }

    private func stopMonitoring() {
        polling?.cancel(); polling = nil; debounce?.cancel(); debounce = nil
        query?.stop(); query = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
    }
}

private extension SyncMigrationRecord {
    mutating func update(with outcome: SyncMigrationOutcome) {
        copiedFiles = outcome.progress.completed; totalFiles = outcome.progress.total
        remainingFiles = outcome.progress.waitingForDownload
        sourceLibraryID = outcome.sourceLibraryID ?? sourceLibraryID
        containerLibraryID = outcome.destinationLibraryID ?? containerLibraryID
        adoptedCheckpoint = adoptedCheckpoint || outcome.adoptedCheckpoint
        skipped = Array(Set(skipped + outcome.progress.skipped)).sorted()
    }
}

/// Waits for a task, or until the waiting task is cancelled, whichever comes first. Awaiting `task.value` alone can't
/// be cut short.
enum TaskWaiter {
    static func wait(for task: Task<Void, Never>) async {
        let gate = Gate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.hold(continuation)
                Task { await task.value; gate.open() }
            }
        } onCancel: { gate.open() }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func hold(_ waiting: CheckedContinuation<Void, Never>) {
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                continuation = waiting
                return false
            }
            if resumeNow { waiting.resume() }
        }

        func open() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                isOpen = true
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume()
        }
    }
}

private enum SyncControllerError: LocalizedError {
    case busy, overlappingLibrary
    public var errorDescription: String? {
        switch self {
        case .busy: return "Wait for the current sync to finish before changing folders."
        case .overlappingLibrary: return "Choose a separate iCloud Drive folder, outside the local working library."
        }
    }
}
