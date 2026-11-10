import CryptoKit
import DaybookCore
import Foundation
import Network
import Observation
import Synchronization

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
    /// The folder this Mac synced through before is there, but this build can't open it (in the App Sandbox, a
    /// bookmark made before can stop working): the person chooses it again (`regrantPreviousFolder`). Carries where it
    /// was, to start the panel there.
    case previousFolderAccessLost(URL?)
    /// Copying the previous sync folder's journal into the container.
    case migrating(SyncMigrationProgress)
    /// Syncing with iCloud.
    case connected
    /// The library in iCloud is encrypted and this device doesn't hold its key yet: nothing is exchanged until iCloud
    /// Keychain (or a paired device, or a recovery key) brings it. Every pass checks again.
    case waitingForKey
}

/// Whether the library in iCloud is encrypted, as this device sees it (docs/icloud-sync.md, "Encryption").
public enum LibraryEncryptionState: Equatable, Sendable {
    /// This build can't keep library keys (no keychain group: unsigned and ad hoc builds, tests without a store).
    case unavailable
    /// Not encrypted (or not known yet).
    case off
    /// Encrypted, and this device is waiting for the key.
    case waitingForKey
    /// Encrypted, and this device holds the key.
    case on(SealingSummary)

    public var isOn: Bool { if case .on = self { return true } else { return false } }
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
    public var accountSignedIn: @Sendable () async -> Bool?
    /// `FileManager.url(forUbiquityContainerIdentifier:)`. Called off the main actor.
    public var resolveContainer: @Sendable (String) -> URL?
    public var cloud: SyncCloudFiles
    /// How long to wait before retrying a migration that's waiting for iCloud downloads.
    public var retryInterval: Duration
    /// This app's bundle ID, kept with the account it records. iCloud's account token is per app, so a token another
    /// app recorded can't be compared with this one's (`LibrarySyncController`, "Another app's account"). Nil: never
    /// compared across apps.
    public var appIdentifier: String?
    /// Which app recorded an account before the app was kept with it: on the Mac the only signed build then,
    /// `local.daybook.app` (signed Mac builds are `local.daybook` now); on the iPhone the app itself.
    public var earlierAccountApp: String?
    /// Whether the network is up now: an empty listing of the container made offline says nothing about what iCloud
    /// holds, so a new library waits for one made online (`LibrarySyncController`, "Monitoring"). Tests: always.
    public var networkReachable: @Sendable () -> Bool

    public init(containerIdentifier: String?, hasEntitlement: @escaping @Sendable (String) -> Bool,
                accountIdentity: @escaping @Sendable () -> Data?, accountSignedIn: @escaping @Sendable () async -> Bool? = { nil },
                resolveContainer: @escaping @Sendable (String) -> URL?, cloud: SyncCloudFiles = .system,
                retryInterval: Duration = .seconds(5), appIdentifier: String? = nil, earlierAccountApp: String? = nil,
                networkReachable: @escaping @Sendable () -> Bool = { true }) {
        self.containerIdentifier = Self.valid(containerIdentifier)
        self.hasEntitlement = hasEntitlement; self.accountIdentity = accountIdentity; self.accountSignedIn = accountSignedIn
        self.resolveContainer = resolveContainer; self.cloud = cloud; self.retryInterval = retryInterval
        self.appIdentifier = appIdentifier; self.earlierAccountApp = earlierAccountApp; self.networkReachable = networkReachable
    }

    public static var system: SyncContainerEnvironment {
        let containerIdentifier = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
        // Started now, so it has reported by the time the container's first listing comes back.
        let network = SyncNetworkPath.shared
        return SyncContainerEnvironment(
            containerIdentifier: containerIdentifier,
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
                // CloudKit's account status for the app's container (`ICloudAccountCheck`), which works in the App
                // Sandbox. Unknown without the CloudKit entitlement, or when CloudKit can't tell.
                return await ICloudAccountCheck.signedIn(containerIdentifier: containerIdentifier)
                #else
                return nil
                #endif
            },
            resolveContainer: { FileManager.default.url(forUbiquityContainerIdentifier: $0) },
            appIdentifier: Bundle.main.bundleIdentifier,
            earlierAccountApp: {
                #if os(macOS)
                return "local.daybook.app"
                #else
                return Bundle.main.bundleIdentifier
                #endif
            }(),
            networkReachable: { network.isSatisfied })
    }

    static func valid(_ identifier: String?) -> String? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespaces), !identifier.isEmpty, !identifier.contains("$(") else { return nil }
        return identifier
    }

    #if os(macOS)
    /// The `com.apple.developer.ubiquity-container-identifiers` this process is signed with.
    static func signedUbiquityContainers() -> [String] {
        Entitlements.strings("com.apple.developer.ubiquity-container-identifiers")
    }
    #endif
}

/// Whether this device's network is up now, from one `NWPathMonitor` started with the first `.system` environment.
/// Optimistic until the monitor first reports, which it does at once.
final class SyncNetworkPath: Sendable {
    static let shared = SyncNetworkPath()
    private let satisfied = Mutex(true)
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in self.satisfied.withLock { $0 = path.status == .satisfied } }
        monitor.start(queue: DispatchQueue(label: "local.daybook.sync.network", qos: .utility))
    }

    var isSatisfied: Bool { satisfied.withLock { $0 } }
}

@MainActor
@Observable
public final class LibrarySyncController {
    public private(set) var folder: URL?
    public internal(set) var isICloudLocation = false
    /// Where sync stands (`SyncStatus`): what both apps show, and whether it needs the person (`status.problem`).
    public internal(set) var status: SyncStatus = .off
    /// `status` in the controller's sentence, for logs and test messages. Views read `status` and its `problem`.
    public var statusText: String { status.text }
    /// Something worth knowing that doesn't stop sync.
    public internal(set) var warning: SyncWarning?
    public internal(set) var isSyncing = false { didSet { if oldValue && !isSyncing { passEnded() } } }
    public internal(set) var lastSync: Date?
    public internal(set) var warnings: [String] = []
    public internal(set) var pendingDownloads = 0
    public internal(set) var pendingUploads = 0
    /// Where sync runs now.
    public internal(set) var transport: SyncTransport = .none
    /// iCloud container sync, for Settings.
    public internal(set) var iCloud: ICloudSyncState
    /// The move from a previously chosen folder into the container, when there was one.
    public internal(set) var migrationRecord: SyncMigrationRecord?
    @ObservationIgnored public var onSyncRequested: (() async -> Void)?
    let localRoot: URL
    let defaults: UserDefaults
    public let environment: SyncContainerEnvironment
    /// This replica's identity in the sync journal, kept on this device (`SyncDeviceIdentityStore`) and mirrored in
    /// preferences. It changes only when another device turns out to share it.
    public internal(set) var deviceID: String
    /// A random ID for this installation, in the presence record.
    public internal(set) var installation: String
    /// A random ID for this app on this device, kept in its own preferences (`Key.appInstallation`): apps that share the
    /// device's identity through the keychain differ in it.
    public let appInstallation: String
    private let identityStore: SyncDeviceIdentityStore
    /// Another device writes presence under this device ID; a new identity is taken once the pass ends.
    private var needsNewIdentity = false
    /// The container sync uses, once restored.
    public internal(set) var containerIdentifier: String?
    /// The engine for the connected library: on-demand audio (`fetchAudio`, `evictAudio`), presence
    /// (`knownDevices`), and the cheap `hasRemoteChanges` check.
    public internal(set) var engine: LibrarySyncEngine?
    /// The last pass stopped at its `SyncPassLimits`; run another soon.
    public internal(set) var hasMoreWork = false
    /// Whether the library is encrypted here, updated after every pass.
    public internal(set) var encryption: LibraryEncryptionState = .off
    /// A plaintext library is encrypted once every device in use can read it (`encryptOnceEveryDeviceCan`). Rigs that
    /// check plaintext sync turn it off.
    public var encryptsAutomatically = true
    /// Waiting for the key, Start Over may be offered: no other device has said it holds the key recently
    /// (`LibrarySyncEngine.mayStartOver`).
    public internal(set) var mayStartOverEncryption = false
    /// Each run of the move from a chosen folder, so progress it reported arriving after it ended (a run that failed,
    /// say) doesn't cover what the end said.
    @ObservationIgnored var migrationAttempt = 0
    @ObservationIgnored var settledMigrationAttempt = 0
    /// Bumped when the retired folder's bookmark is kept or forgotten (it lives in preferences), so what reads
    /// `hasRetiredFolderJournal` reads it again.
    var retiredFolderChanges = 0
    /// The courier beside iCloud Drive, and its state (LibrarySyncController+Courier.swift).
    @ObservationIgnored let courierBridge = SyncCourierBridge()
    /// The last acknowledged pass found iCloud refusing uploads for lack of storage.
    @ObservationIgnored var lastResultStorageFull = false
    /// What this device's presence was last told stands in the way of its sync (`tellPresenceProblem`).
    @ObservationIgnored var toldPresenceProblem: SyncPresenceProblem?
    /// Library keys this device asked paired devices for, still open (LibraryKeyExchange.swift).
    @ObservationIgnored var keyRequests: [LibraryKeyRequestRecord] = []
    @ObservationIgnored var activeTask: Task<SyncResult, Error>?
    @ObservationIgnored var pendingReceipt: UUID?
    /// Where sync stood before the pass in flight, which is still true if that pass is cancelled.
    @ObservationIgnored var statusBeforePass: SyncStatus?
    /// The account signed in when a chosen folder connected.
    @ObservationIgnored var folderAccount: Data?
    @ObservationIgnored var polling: Task<Void, Never>?
    @ObservationIgnored var debounce: Task<Void, Never>?
    @ObservationIgnored var debounceToken = UUID()
    /// The requested pass is running; a request now waits for it to end.
    @ObservationIgnored var debounceRunsPass = false
    @ObservationIgnored var requestedDuringPass = false
    @ObservationIgnored var passEndWaiters: [CheckedContinuation<Void, Never>] = []
    /// How long a request waits before it runs a pass, so a burst of edits makes one. Nil: requests never run a
    /// pass on their own; test rigs drive passes themselves.
    public var syncDebounce: Duration? = .seconds(2)
    /// A requested pass is waiting out `syncDebounce` or running.
    public var hasPendingSyncRequest: Bool { debounce != nil }
    @ObservationIgnored var query: NSMetadataQuery?
    @ObservationIgnored var observers: [NSObjectProtocol] = []
    @ObservationIgnored var scopedURL: URL?
    @ObservationIgnored var configurationID = UUID()
    @ObservationIgnored var containerTask: Task<Void, Never>?
    @ObservationIgnored var migrationTask: Task<Void, Never>?
    @ObservationIgnored var containerGeneration = UUID()
    @ObservationIgnored var accountObserver: NSObjectProtocol?
    /// The person chose to sync with another iCloud account: forget the container's library was encrypted.
    @ObservationIgnored var forgetsSealedLibrary = false
    /// iCloud has listed the connected folder once (its metadata query finished gathering).
    private(set) var containerListed = false
    /// The first listing was empty and made offline: it counts once one has something in it or the network is up
    /// (`noteListing`).
    @ObservationIgnored private(set) var listingDeferred = false
    /// Something here asked for a pass (`requestSync`: an edit saved, a delivery, iCloud's listing changing) since the
    /// last one started.
    @ObservationIgnored var requestedSinceLastPass = false
    /// When the last pass started.
    @ObservationIgnored var lastPassStarted: Date?
    /// Polls that skipped their pass because it would change nothing (tests).
    @ObservationIgnored private(set) var pollsSkipped = 0

    /// Unsigned and ad hoc development builds can't use the iCloud container. Setting this preference
    /// (`-DaybookDevelopmentFolderSync YES` as a launch argument, or `defaults write`) brings back the folder
    /// transport there: Settings offers Choose Folder… and a chosen folder is restored at launch. Builds signed
    /// for iCloud ignore it. See docs/icloud-sync.md, "Development builds".
    public static let developmentFolderSyncKey = "DaybookDevelopmentFolderSync"

    /// How many checks, `retryInterval` apart, a container without any manifest gets before another app's recorded
    /// account counts as another account (`prepareContainer`): about two minutes at the usual five seconds.
    static let accountJournalWaitPasses = 24

    enum Key {
        static let folderBookmark = "syncFolderBookmark"
        /// A plain (not security-scoped) bookmark of the same folder, kept beside it: it still says where the folder is
        /// when the scoped one can't be opened, so the panel can start there.
        static let folderLocation = "syncFolderLocation"
        static let migratedFolderBookmark = "syncMigratedFolderBookmark"
        static let migration = "syncContainerMigration"
        /// The account this library syncs with: the SHA-256 of its archived identity token (`accountDigest`), or, as
        /// releases before it kept it, the archive itself. Never decoded.
        static let account = "syncICloudAccount"
        /// The bundle ID of the app that recorded `account`.
        static let accountApp = "syncICloudAccountApp"
        /// The library this device last synced with that account (`prepareContainer`).
        static let accountLibrary = "syncICloudAccountLibrary"
        static let turnedOff = "syncICloudTurnedOff"
        static let deviceID = "syncDeviceID"
        static let installation = "syncInstallation"
        /// The identity moved to this device's keychain. Seen without the keychain item, the preferences (and the
        /// library) were copied from another Mac.
        static let identityStored = "syncDeviceIDInKeychain"
        /// When the last pass was acknowledged.
        static let lastCompleted = "syncLastCompleted"
        /// A random ID for this app's own installation, in its own preferences (`LibrarySyncEngine.appInstallation`).
        static let appInstallation = "syncAppInstallation"
        /// When another installation of Daybook on this device last wrote this device's presence (`warning`).
        static let otherInstallationWrote = "syncOtherInstallationWrote"
    }

    /// `identityStore` defaults to this device's keychain (`SyncDeviceIdentityStore.keychain(for:)`).
    public init(localRoot: URL, defaults: UserDefaults, environment: SyncContainerEnvironment = .system,
                identityStore: SyncDeviceIdentityStore? = nil) {
        self.localRoot = localRoot; self.defaults = defaults; self.environment = environment
        let store = identityStore ?? .keychain(for: localRoot)
        self.identityStore = store
        let identity = Self.resolveIdentity(store: store, defaults: defaults, localRoot: localRoot)
        deviceID = identity.deviceID; installation = identity.installation
        if let stored = defaults.string(forKey: Key.appInstallation) { appInstallation = stored } else {
            appInstallation = UUID().uuidString
            defaults.set(appInstallation, forKey: Key.appInstallation)
        }
        lastSync = defaults.object(forKey: Key.lastCompleted) as? Date
        warning = Self.otherInstallationWarning(defaults.object(forKey: Key.otherInstallationWrote) as? Date, now: Date())
        migrationRecord = defaults.data(forKey: Key.migration).flatMap { try? JSONDecoder().decode(SyncMigrationRecord.self, from: $0) }
        let usable = environment.containerIdentifier.map(environment.hasEntitlement) ?? false
        iCloud = usable ? .checking : .unavailableInThisBuild
    }

    /// The identity from this device's keychain. On the first launch with it, the one in preferences moves there
    /// unchanged. Preferences that say it moved, with no keychain item here, came from another Mac (Migration
    /// Assistant, a backup): this Mac takes a new identity and keeps its place in the journal. Without a keychain
    /// (unsigned builds, tests), preferences hold it as before.
    static func resolveIdentity(store: SyncDeviceIdentityStore, defaults: UserDefaults, localRoot: URL) -> StoredSyncIdentity {
        let inPreferences = defaults.string(forKey: Key.deviceID)
        if let stored = store.read() {
            if inPreferences != stored.deviceID { defaults.set(stored.deviceID, forKey: Key.deviceID) }
            return stored
        }
        if defaults.bool(forKey: Key.identityStored), let copied = inPreferences {
            let fresh = StoredSyncIdentity(deviceID: UUID().uuidString, installation: UUID().uuidString)
            LibrarySyncEngine.carryOverCheckpoints(localRoot: localRoot, from: copied, to: fresh.deviceID)
            _ = store.write(fresh)
            defaults.set(fresh.deviceID, forKey: Key.deviceID)
            return fresh
        }
        let identity = StoredSyncIdentity(deviceID: inPreferences ?? UUID().uuidString,
                                          installation: defaults.string(forKey: Key.installation) ?? UUID().uuidString)
        if store.write(identity) { defaults.set(true, forKey: Key.identityStored) } else { defaults.set(identity.installation, forKey: Key.installation) }
        defaults.set(identity.deviceID, forKey: Key.deviceID)
        return identity
    }

    /// Another device shares this device ID (presence says so): this one takes a new identity, keeps its place in
    /// the journal, and reconnects.
    private func takeNewIdentity() {
        guard needsNewIdentity, !isSyncing else { return }
        needsNewIdentity = false
        let fresh = StoredSyncIdentity(deviceID: UUID().uuidString, installation: installation)
        LibrarySyncEngine.carryOverCheckpoints(localRoot: localRoot, from: deviceID, to: fresh.deviceID)
        if !identityStore.write(fresh) { defaults.set(fresh.installation, forKey: Key.installation) }
        defaults.set(fresh.deviceID, forKey: Key.deviceID)
        deviceID = fresh.deviceID
        guard let folder else { return }
        let transport = self.transport
        stopMonitoring(); engine = nil
        do { try attach(folder, transport: transport, monitorChanges: true) } catch {
            // Reconnecting failed: sync says so, as a container that can't be attached does, rather than stopping quietly.
            self.folder = nil; self.transport = .none
            if transport == .iCloudContainer {
                iCloud = .containerUnavailable(error.localizedDescription); status = .iCloudUnavailable(details: error.localizedDescription)
            } else {
                status = .reconnectFolder(details: error.localizedDescription)
            }
        }
    }

    /// Whether this build may sync through a chosen folder: only without iCloud, and only when asked for.
    public var allowsFolderSync: Bool {
        iCloud == .unavailableInThisBuild && defaults.bool(forKey: Self.developmentFolderSyncKey)
    }

    /// Syncs through a folder (the folder transport).
    public func connect(to url: URL, monitorChanges: Bool = true) throws {
        try attach(url, transport: .folder, monitorChanges: monitorChanges)
        containerTask?.cancel(); containerTask = nil; migrationTask?.cancel(); migrationTask = nil
    }

    func attach(_ url: URL, transport: SyncTransport, monitorChanges: Bool) throws {
        guard !isSyncing else { throw SyncControllerError.busy }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let local = localRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard root != local, !root.path.hasPrefix(local.path + "/"), !local.path.hasPrefix(root.path + "/") else { throw SyncControllerError.overlappingLibrary }
        stopMonitoring()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        // In the container, a fresh device waits for iCloud's first listing before it starts a library of its own.
        do { engine = try LibrarySyncEngine(localRoot: localRoot, remoteRoot: url, deviceID: deviceID, replica: replica,
                                            waitsForListing: transport == .iCloudContainer && monitorChanges, installation: installation,
                                            appInstallation: appInstallation) }
        catch { scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil; throw error }
        folder = url; self.transport = transport; status = .preparing; configurationID = UUID()
        toldPresenceProblem = nil
        encryption = replica.keyStore == nil ? .unavailable : .off
        isICloudLocation = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true || root.path.contains("/Library/Mobile Documents/")
        // Other devices learn this one exists (and what it is) right away, not only after its first full
        // pass, which can take minutes on a new library. Presence is advisory, so a failure is ignored.
        if let engine, replica.device != nil {
            let activity = self.activity
            Task { if let activity { try? await engine.publishActivity(activity) } else { try? await engine.publishPresence() } }
        }
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
            status = .off; warnings = []; pendingDownloads = 0
            return
        }
        configurationID = UUID(); stopMonitoring(); engine = nil; folder = nil; transport = .none
        defaults.removeObject(forKey: Key.folderBookmark)
        status = .off; warnings = []; pendingDownloads = 0
    }

    public func requestSync() {
        guard folder != nil else { return }
        requestedSinceLastPass = true
        // A request made by the pass a request started (an edit saved meanwhile, a courier delivery) mustn't cancel
        // that pass: it runs again once the pass is over.
        if debounceRunsPass { requestedDuringPass = true; return }
        debounce?.cancel(); debounce = nil
        guard let delay = syncDebounce else { return }
        let token = UUID()
        debounceToken = token
        debounce = Task { [weak self] in
            if (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled {
                self?.debounceRunsPass = true
                await self?.onSyncRequested?()
                self?.debounceRunsPass = false
            }
            if self?.debounceToken == token { self?.debounce = nil }
            if self?.requestedDuringPass == true { self?.requestedDuringPass = false; self?.requestSync() }
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
    func waitForPassToEnd() async {
        guard isSyncing else { return }
        await withCheckedContinuation { passEndWaiters.append($0) }
    }

    private func passEnded() {
        let waiters = passEndWaiters
        passEndWaiters = []
        waiters.forEach { $0.resume() }
    }

    public func deferUntilIdle() { if folder != nil && !isSyncing { status = .deferred } }

    public func synchronize(meetings: [Meeting], deletedMeetingIDs: Set<UUID>, metadata: Data,
                            limits: SyncPassLimits = .unlimited, protecting: Set<UUID> = [], scope: SyncPassScope = .full) async throws -> SyncResult? {
        try Task.checkCancellation()
        guard let engine, !isSyncing else { return nil }
        let generation = configurationID
        statusBeforePass = status
        isSyncing = true; status = .syncing
        requestedSinceLastPass = false; lastPassStarted = Date()
        do {
            let task = Task { try await engine.synchronize(meetings: meetings, deletedMeetingIDs: deletedMeetingIDs, libraryMetadata: metadata,
                                                           limits: limits, protecting: protecting, scope: scope) }
            activeTask = task
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            activeTask = nil
            try Task.checkCancellation()
            guard generation == configurationID else { isSyncing = false; return nil }
            if await engine.sharesIdentity { needsNewIdentity = true }
            await noteOtherInstallation(engine)
            await noteEncryption(engine)
            handToCourier(result.writtenFiles, engine: engine)
            schedulePublication(result.nextPublication)
            pendingReceipt = result.checkpointID
            pendingDownloads = result.pendingDownloads; pendingUploads = result.pendingUploads; warnings = result.warnings
            hasMoreWork = result.hasMoreWork
            status = .applying
            return result
        } catch LibrarySyncError.waitingForICloud {
            // Not a failure: the pass runs again once iCloud has listed the container.
            activeTask = nil; isSyncing = false; pendingReceipt = nil
            status = .waitingForICloud
            return nil
        } catch let error as LibrarySyncError where error == .libraryRemoved || error == .sealingRemoved {
            // The encrypted library this device synced is gone from iCloud (the person may start a new one,
            // `startNewLibrary`), or what's there now isn't encrypted (nothing goes there; sync carries on once it is).
            activeTask = nil; isSyncing = false; pendingReceipt = nil
            guard generation == configurationID else { return nil }
            status = error == .libraryRemoved ? .libraryRemoved : .libraryNotEncrypted
            return nil
        } catch LibrarySyncError.keyStoreUnreadable {
            // Not a failure, and not a missing key: the keychain can't be read right now (an iPhone not unlocked since it
            // started). Nothing changed; the next pass reads it again.
            activeTask = nil; isSyncing = false; pendingReceipt = nil
            guard generation == configurationID else { return nil }
            status = .keyStoreUnreadable
            return nil
        } catch LibrarySyncError.keyUnavailable {
            // Not a failure either: the library is encrypted and its key hasn't reached this device. Every pass checks
            // the keychain again; local edits wait.
            activeTask = nil; isSyncing = false; pendingReceipt = nil
            guard generation == configurationID else { return nil }
            encryption = .waitingForKey
            if transport == .iCloudContainer { iCloud = .waitingForKey }
            status = .waitingForKey
            let mayStartOver = await engine.mayStartOver()
            if mayStartOverEncryption != mayStartOver { mayStartOverEncryption = mayStartOver }
            return nil
        } catch {
            activeTask = nil; isSyncing = false; pendingReceipt = nil
            // Nor is a pass that was cancelled (the app left the foreground), or whose account or folder was replaced
            // while it ran: whatever stopped it says where sync stands.
            guard !(error is CancellationError), generation == configurationID else {
                if generation == configurationID, let before = statusBeforePass { status = before }
                throw CancellationError()
            }
            status = .failure(details: error.localizedDescription); throw error
        }
    }

    public func canApply(_ result: SyncResult) -> Bool { pendingReceipt == result.checkpointID && folder != nil }

    public func acknowledge(_ result: SyncResult) async throws {
        guard let engine, canApply(result) else { throw SyncControllerError.busy }
        defer { isSyncing = false; pendingReceipt = nil }
        try await engine.acknowledge(result.checkpointID)
        guard canApply(result) else { throw SyncControllerError.busy }
        let completed = Date()
        lastResultStorageFull = result.storageFull
        // The library this account's container holds, for telling a token that archived differently from another account.
        if transport == .iCloudContainer, let library = await engine.libraryID {
            defaults.set(library.uuidString, forKey: Key.accountLibrary)
        }
        status = settledStatus(uploads: result.pendingUploads, downloads: result.pendingDownloads, at: completed)
        lastSync = completed; defaults.set(completed, forKey: Key.lastCompleted)
        isSyncing = false
        tellPresenceProblem()
        takeNewIdentity()
        if encryptsAutomatically, encryption == .off, !isStorageFull { Task { await encryptOnceEveryDeviceCan() } }
    }

    /// iCloud is refusing uploads for lack of storage (the last pass found it, or the courier did): encrypting or rotating
    /// the key, which writes a sealed copy of the library before the old one goes, waits.
    public var isStorageFull: Bool { status == .storageFull || lastResultStorageFull || courierStatus.storageFull }

    /// Where sync stands after a pass: iCloud storage is full when the pass found iCloud refusing uploads for it, or the
    /// courier did while uploads wait (CloudKit and iCloud Drive share the quota); else files still moving; else up to
    /// date, which needs nothing waiting to upload.
    private func settledStatus(uploads: Int, downloads: Int, at date: Date) -> SyncStatus {
        if lastResultStorageFull || (courierStatus.storageFull && uploads > 0) { return .storageFull }
        return uploads > 0 || downloads > 0 ? .exchanged(uploads: uploads, downloads: downloads) : .upToDate(at: date)
    }

    /// The courier's status changed (`SyncCourierBridge`): storage full there turns a settled status with uploads waiting
    /// into `storageFull`, and back once it clears.
    func courierStatusChanged() {
        switch status {
        case .exchanged, .storageFull:
            status = settledStatus(uploads: pendingUploads, downloads: pendingDownloads, at: lastSync ?? Date())
        default:
            break
        }
        tellPresenceProblem()
    }

    /// What this device's presence says stands in the way of its sync: iCloud storage is full while it is (the last pass
    /// found iCloud refusing uploads for it, or the courier did), so another device can say why its work hasn't arrived.
    var presenceProblem: SyncPresenceProblem? { isStorageFull ? .storageFull : nil }

    /// Tells the engine when `presenceProblem` changes; it rewrites its presence at once.
    func tellPresenceProblem() {
        let problem = presenceProblem
        guard problem != toldPresenceProblem, let engine else { return }
        toldPresenceProblem = problem
        Task { try? await engine.setPresenceProblem(problem) }
    }

    public func reportFailure(_ message: String) {
        isSyncing = false; pendingReceipt = nil; status = .failure(details: message)
        takeNewIdentity()
    }

    /// Ends a pass that was cancelled while its changes were being applied. Nothing failed: where sync stood
    /// before the pass is still true.
    public func passCancelled() {
        isSyncing = false; pendingReceipt = nil
        if status == .applying, let before = statusBeforePass { status = before }
        takeNewIdentity()
    }

    // MARK: Presence

    /// What this device is doing, in its presence record. Kept across reconnections.
    @ObservationIgnored var activity: SyncDeviceActivity?

    /// Tells the other devices this one is recording into `conversationID` (nil: it stopped), and which recorders
    /// it drives. Written at once and kept fresh every few minutes, even while recording holds sync passes back, so
    /// the iPhone sees this Mac as present and busy rather than asleep.
    public func publishActivity(recording conversationID: UUID?, since: Date? = nil, recorders: [SyncDeviceActivity.Recorder] = []) {
        let next = conversationID == nil && recorders.isEmpty ? nil
            : SyncDeviceActivity(recordingConversationID: conversationID, since: since, recorders: recorders.isEmpty ? nil : recorders)
        activity = next
        guard let engine, replica.device != nil else { return }
        Task { try? await engine.publishActivity(next) }
    }

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

    // MARK: Held publications

    @ObservationIgnored var publicationTimer: Task<Void, Never>?
    /// The last pass held back an edit to a large conversation (`SyncReplicaConfiguration.holdsEditBursts`): the app
    /// publishes it when it leaves the foreground (`publishHeldEdits`).
    public internal(set) var holdsEdits = false

    /// A large conversation edited here again soon after it was published is held back by the engine
    /// (`LibrarySyncEngine.publicationInterval`): a pass is asked for when it may go.
    private func schedulePublication(_ due: Date?) {
        publicationTimer?.cancel(); publicationTimer = nil
        if holdsEdits != (due != nil) { holdsEdits = due != nil }
        guard let due else { return }
        publicationTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.requestSync()
        }
    }

    /// Lets edits the engine held back (`LibrarySyncEngine.publicationInterval`) go on the next pass: of `conversation`,
    /// or every one. The iPhone calls it when the person leaves a conversation's page, and before its last pass when it
    /// goes to the background (`requestingPass: false`, since it runs that pass itself). Returns whether anything was
    /// held; then, with `requestingPass`, a pass is asked for.
    @discardableResult
    public func publishHeldEdits(of conversation: UUID? = nil, requestingPass: Bool = true) async -> Bool {
        guard let engine else { return false }
        let released = await engine.publishHeldEdits(of: conversation.map { [$0] })
        if conversation == nil { publicationTimer?.cancel(); publicationTimer = nil; holdsEdits = false }
        if released, requestingPass { requestSync() }
        return released
    }

    func detach() {
        if activeTask == nil { isSyncing = false }
        activeTask?.cancel(); configurationID = UUID(); pendingReceipt = nil
        stopMonitoring(); engine = nil; folder = nil; transport = .none
        publicationTimer?.cancel(); publicationTimer = nil; holdsEdits = false
    }

    // MARK: Monitoring

    /// How long the 30-second poll may go without a pass while nothing changed here or in iCloud: time-based work rides
    /// on passes (the sealer's grace periods, a migrator or claim gone quiet, requests waiting for a device), and the
    /// status says when sync last checked. The iPhone's own cadence is the same (`PhoneSync.presenceInterval`).
    static let idlePassInterval: TimeInterval = 10 * 60

    private func startMonitoring(_ root: URL) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryUbiquitousDataScope, NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path + "/")
        query.notificationBatchingInterval = 2
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            let gathered = name == .NSMetadataQueryDidFinishGathering
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if gathered || self.listingDeferred { await self.noteListing() }
                    self.requestSync()
                }
            })
        }
        self.query = query; query.start()
        // Reconcile after missed metadata events, sleep/wake, or a temporary offline period. The loop holds the controller
        // only while it acts, so it ends once the controller is gone.
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                await self.poll()
            }
        }
        // The container has its own account handling (`accountDidChange`). A chosen folder disconnects.
        guard transport == .folder else { return }
        folderAccount = environment.accountIdentity()
        observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.transport == .folder, !self.isOnSameAccount else { return }
                self.detach()
                self.defaults.removeObject(forKey: Key.folderBookmark)
                self.status = .folderAccountChanged
            }
        })
    }

    /// iCloud has listed the container (the query's first gather, or an update after one made offline). An empty listing
    /// made offline says nothing about what iCloud holds: a device that started a library then would start a second one
    /// beside one it can't see yet, so it waits until a listing has something in it or the network is up.
    private func noteListing() async {
        guard let engine, let query, !containerListed else { listingDeferred = false; return }
        guard query.resultCount > 0 || environment.networkReachable() else { listingDeferred = true; return }
        listingDeferred = false
        await engine.listingGathered()
        containerListed = true
    }

    /// The 30-second fallback. Presence stays fresh while passes wait (recording, processing): rewritten when it's due.
    /// The pass itself is skipped while it would change nothing: the last one finished up to date, nothing here asked
    /// for one since, it hasn't been `idlePassInterval`, and iCloud's listing hasn't changed (`hasRemoteChanges`, which
    /// lists without reading).
    func poll() async {
        if listingDeferred { await noteListing() }
        if await mayIdle() { pollsSkipped += 1 } else { await onSyncRequested?() }
        if let engine {
            try? await engine.refreshPresence()
            await noteOtherInstallation(engine)
        }
    }

    /// How long after another installation of Daybook on this device last synced as it the warning stays: it may run
    /// only now and then (opened, or woken in the background), and once it's deleted, the warning goes after this long.
    static let otherInstallationWindow: TimeInterval = 24 * 60 * 60

    /// Notes another installation of Daybook syncing as this device (`LibrarySyncEngine.otherInstallationWrote`), kept
    /// across launches, and says so in `warning` while it's recent.
    private func noteOtherInstallation(_ engine: LibrarySyncEngine) async {
        var seen = defaults.object(forKey: Key.otherInstallationWrote) as? Date
        if let wrote = await engine.otherInstallationWrote, wrote > (seen ?? .distantPast) {
            seen = wrote
            defaults.set(wrote, forKey: Key.otherInstallationWrote)
        }
        let next = Self.otherInstallationWarning(seen, now: Date())
        if warning != next { warning = next }
    }

    static func otherInstallationWarning(_ seen: Date?, now: Date) -> SyncWarning? {
        guard let seen, now.timeIntervalSince(seen) < otherInstallationWindow else { return nil }
        return .otherInstallation
    }

    /// Whether the poll may skip its pass (`poll`).
    private func mayIdle(now: Date = Date()) async -> Bool {
        guard case .upToDate = status, !requestedSinceLastPass, !hasMoreWork, !isSyncing, let engine,
              let started = lastPassStarted, now.timeIntervalSince(started) < Self.idlePassInterval else { return false }
        return await !engine.hasRemoteChanges()
    }

    private func stopMonitoring() {
        polling?.cancel(); polling = nil; debounce?.cancel(); debounce = nil; containerListed = false; listingDeferred = false
        debounceRunsPass = false; requestedDuringPass = false
        query?.stop(); query = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
    }

    /// Stops everything the controller started, for good: the pass in flight, monitoring and its timer, a requested
    /// pass, the container lookup and the move from a chosen folder, the courier, and the account observer. For a
    /// controller about to be dropped (tests, a library closed); nothing is turned off or forgotten.
    public func invalidate() {
        activeTask?.cancel(); configurationID = UUID(); pendingReceipt = nil
        containerTask?.cancel(); containerTask = nil; migrationTask?.cancel(); migrationTask = nil
        containerGeneration = UUID()
        stopMonitoring()
        stopCourier()
        publicationTimer?.cancel(); publicationTimer = nil
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        accountObserver = nil
        engine = nil; folder = nil; transport = .none
    }
}

/// Numbers reports made on any thread so they're applied in the order they were made: one that arrives after a later
/// one is dropped.
final class StatusNumbering: Sendable {
    private let numbers = Mutex((issued: 0, applied: 0))

    /// The next report's number.
    func issue() -> Int { numbers.withLock { $0.issued += 1; return $0.issued } }

    /// Whether the report numbered `number` is newer than every one applied so far; it counts as applied when it is.
    func apply(_ number: Int) -> Bool {
        numbers.withLock { state in
            guard number > state.applied else { return false }
            state.applied = number
            return true
        }
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

    private final class Gate: Sendable {
        let state = Mutex<(isOpen: Bool, continuation: CheckedContinuation<Void, Never>?)>((false, nil))

        func hold(_ waiting: CheckedContinuation<Void, Never>) {
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.continuation = waiting
                return false
            }
            if resumeNow { waiting.resume() }
        }

        func open() {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.isOpen = true
                defer { state.continuation = nil }
                return state.continuation
            }
            waiting?.resume()
        }
    }
}

enum SyncControllerError: LocalizedError, Equatable {
    case busy, overlappingLibrary, notConnected
    /// Encrypting or rotating the key waits for room in iCloud.
    case storageFull
    public var errorDescription: String? {
        switch self {
        case .busy: return "Wait for the current sync to finish before changing folders."
        case .overlappingLibrary: return "Choose a separate iCloud Drive folder, outside the local working library."
        case .notConnected: return "Sync isn’t on."
        case .storageFull: return "iCloud storage is full. Free up space in iCloud, then try again."
        }
    }
}
