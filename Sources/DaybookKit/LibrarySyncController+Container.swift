import CryptoKit
import DaybookCore
import Foundation

// Connecting sync to iCloud (docs/icloud-sync.md, "The iCloud container" and "Moving from a chosen folder"): finding the
// container for the account signed in, telling the account the library synced with from another, moving a folder this
// Mac synced through before, and the folder transport of development builds. Its state is the controller's, which both
// apps observe (`status`, `iCloud`, `migrationRecord`).
extension LibrarySyncController {
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
            else if folder == nil { status = .unavailableInThisBuild }
            return
        }
        startContainer(identifier)
    }

    func restoreFolder() {
        guard let data = defaults.data(forKey: Key.folderBookmark) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: Self.bookmarkResolution, relativeTo: nil, bookmarkDataIsStale: &stale)
            try connect(to: url)
            if stale { try saveBookmark(url) } else if defaults.data(forKey: Key.folderLocation) == nil { rememberLocation(of: url) }
        } catch { status = .reconnectFolder(details: error.localizedDescription) }
    }

    /// Connects a folder the person chose (an open panel on the Mac, the Files picker on iPhone)
    /// and remembers it with a security-scoped bookmark. The folder transport: development and tests.
    public func connectChosenFolder(_ url: URL) {
        do { try connect(to: url); try saveBookmark(url) }
        catch { status = .couldNotUseFolder(details: error.localizedDescription) }
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
        defaults.removeObject(forKey: Key.accountApp)
        defaults.removeObject(forKey: Key.accountLibrary)
        guard let identifier = containerIdentifier else { return }
        // The other account's library is another library: whether this one was encrypted says nothing about it.
        forgetsSealedLibrary = true
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

    func saveBookmark(_ url: URL) throws {
        let data = try url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Key.folderBookmark)
        rememberLocation(of: url)
    }

    /// Keeps a plain bookmark of the chosen folder beside the scoped one (`Key.folderLocation`).
    func rememberLocation(of url: URL) {
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: Key.folderLocation)
        }
    }

    /// Where the previous folder was, from the plain bookmark, when it's there at all.
    func previousFolderLocation() -> URL? {
        guard let data = defaults.data(forKey: Key.folderLocation) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The previous folder, chosen again after this build lost access to it (`previousFolderAccessLost`): its bookmark is
    /// replaced and the move to iCloud tries again.
    public func regrantPreviousFolder(_ url: URL) {
        do { try saveBookmark(url) } catch { status = .couldNotUseFolder(details: error.localizedDescription); return }
        retryContainer()
    }

    // A sandboxed Mac keeps access through a security-scoped bookmark. On iPhone a folder picked in
    // Files is security-scoped already; its bookmark is a minimal one, resolved the same way.
    #if os(macOS)
    static let bookmarkCreation: URL.BookmarkCreationOptions = [.withSecurityScope]
    static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    static let bookmarkCreation: URL.BookmarkCreationOptions = [.minimalBookmark]
    static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif

    // MARK: iCloud container

    func startContainer(_ identifier: String) {
        containerIdentifier = identifier
        observeAccount()
        containerTask?.cancel(); migrationTask?.cancel(); migrationTask = nil
        let generation = UUID()
        containerGeneration = generation
        containerTask = Task { [weak self] in await self?.prepareContainer(identifier, generation: generation) }
    }

    func isCurrent(_ generation: UUID) -> Bool { generation == containerGeneration && !Task.isCancelled }

    /// Connects the container, in three phases: the account (`checkAccount`), whose journal the container holds when the
    /// account record reads differently (`waitForThisLibrary`), and attaching it (`attachContainer`). Each says where sync
    /// stands when it stops.
    func prepareContainer(_ identifier: String, generation: UUID) async {
        if transport == .iCloudContainer { detach() }
        if defaults.bool(forKey: Key.turnedOff) {
            iCloud = .turnedOff; status = .off; return
        }
        guard let check = await checkAccount(generation: generation) else { return }
        iCloud = .checking; status = .connecting
        let resolve = environment.resolveContainer
        let container = await Task.detached(priority: .utility) { resolve(identifier) }.value
        guard isCurrent(generation) else { return }
        guard let container else {
            let unavailable = SyncStatus.iCloudUnavailable(details: nil)
            iCloud = .containerUnavailable(unavailable.text); status = unavailable
            return
        }
        let root = container.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Daybook", isDirectory: true)
        if check.readsDifferently {
            guard await waitForThisLibrary(in: root, expected: check.expectedLibrary, generation: generation) else { return }
        }
        await attachContainer(root, account: check.account, identifier: identifier, generation: generation)
    }

    /// The account signed in, and whether the account this library synced with reads differently from it.
    struct AccountCheck {
        var account: Data
        /// The record reads differently: another app's (iCloud's account token is per app), or this app's own with the
        /// library it last synced there known. The container decides (`waitForThisLibrary`).
        var readsDifferently = false
        /// The library this device last synced with the recorded account, which the container must hold.
        var expectedLibrary: UUID?
    }

    /// The account phase: signed out or iCloud Drive off, another account (paused), or the account to connect with. Nil
    /// when sync stops here (and `status` says why).
    ///
    /// Another app's account: iCloud's account token is per app, so a token another app recorded never equals this one's,
    /// even for the same account. That's an earlier Mac release (`local.daybook.app`) whose preferences this one
    /// (`local.daybook`) carried over, or the other way round. The container decides: holding this library's journal,
    /// it's the same account. This app's own record reading differently is another account, unless the container holds
    /// the very library this device last synced with it (`Key.accountLibrary`): the token archived to other bytes.
    func checkAccount(generation: UUID) async -> AccountCheck? {
        guard let account = environment.accountIdentity() else {
            let signedIn = await environment.accountSignedIn()
            guard isCurrent(generation) else { return nil }
            if signedIn == false {
                iCloud = .signedOut; status = .signedOut
            } else {
                iCloud = .iCloudDriveOff; status = .iCloudDriveOff
            }
            return nil
        }
        var check = AccountCheck(account: account)
        if let previous = defaults.data(forKey: Key.account), !Self.sameAccount(previous, account) {
            let recorder = defaults.string(forKey: Key.accountApp) ?? environment.earlierAccountApp
            if let recorder, let app = environment.appIdentifier, recorder != app {
                check.readsDifferently = true
            } else if let library = defaults.string(forKey: Key.accountLibrary).flatMap(UUID.init(uuidString:)) {
                check.readsDifferently = true; check.expectedLibrary = library
            } else {
                iCloud = .accountChanged; status = .accountChanged
                return nil
            }
        }
        return check
    }

    /// The other-app phase: whether the container at `root` holds this library's journal (`expected`, when known). The
    /// manifest may still be in iCloud (the first launch after the change, or a fresh install): it's asked for, and sync
    /// keeps saying "Connecting to iCloud…" until it's here. Only a manifest naming another library, or none turning up
    /// after a while (`accountJournalWaitPasses`), means another account: false, paused.
    func waitForThisLibrary(in root: URL, expected: UUID?, generation: UUID) async -> Bool {
        let (localRoot, deviceID, cloud) = (localRoot, deviceID, environment.cloud)
        var passesWithoutManifest = 0
        while true {
            let ownership = await Task.detached(priority: .utility) {
                LibrarySyncEngine.journalOwnership(localRoot: localRoot, deviceID: deviceID, remoteRoot: root, cloud: cloud)
            }.value
            guard isCurrent(generation) else { return false }
            switch ownership {
            case .thisLibrary:
                if let expected, LibrarySyncEngine.manifestLibraryID(remoteRoot: root) != expected {
                    iCloud = .accountChanged; status = .accountChanged
                    return false
                }
                return true
            case .anotherLibrary:
                iCloud = .accountChanged; status = .accountChanged
                return false
            case .absent:
                passesWithoutManifest += 1
                if passesWithoutManifest > Self.accountJournalWaitPasses {
                    iCloud = .accountChanged; status = .accountChanged
                    return false
                }
            case .inCloud:
                break
            }
            try? await Task.sleep(for: environment.retryInterval)
            guard isCurrent(generation) else { return false }
        }
    }

    /// The attach phase: records the account (the library is bound to it from here on, so a change mid-migration pauses
    /// too), moves a folder this Mac synced through before, waits out a cancelled pass still unwinding, and attaches the
    /// engine to the container.
    func attachContainer(_ root: URL, account: Data, identifier: String, generation: UUID) async {
        if forgetsSealedLibrary {
            forgetsSealedLibrary = false
            LibrarySyncEngine.forgetSealedLibrary(localRoot: localRoot, remoteRoot: root)
        }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            iCloud = .containerUnavailable(error.localizedDescription); status = .iCloudUnavailable(details: error.localizedDescription)
            return
        }
        defaults.set(Self.accountDigest(account), forKey: Key.account)
        if let app = environment.appIdentifier { defaults.set(app, forKey: Key.accountApp) } else { defaults.removeObject(forKey: Key.accountApp) }
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
            iCloud = .containerUnavailable(error.localizedDescription); status = .iCloudUnavailable(details: error.localizedDescription)
            return
        }
        if let record = migrationRecord, record.switchedAt != nil, record.completedAt == nil, !record.abandoned {
            migrationTask = Task { [weak self] in await self?.finishMigration(into: root, identifier: identifier, generation: generation) }
        }
    }

    /// Moves a previously chosen folder's journal into the container, once. True when sync can switch over:
    /// there was nothing to move, or the manifest, events, and metadata are all copied. Waits (retrying)
    /// while iCloud downloads the source's files.
    func migrateFolder(into root: URL, identifier: String, generation: UUID) async -> Bool {
        guard let bookmark = defaults.data(forKey: Key.folderBookmark) else { return true }
        guard let source = Self.resolve(bookmark), Self.canOpen(source) else {
            // There but unreadable (a bookmark made before the App Sandbox), or gone.
            if let location = Self.resolve(bookmark) ?? previousFolderLocation() {
                iCloud = .previousFolderAccessLost(location)
                status = .previousFolderAccessLost
            } else {
                iCloud = .previousFolderMissing
                status = .previousFolderMissing
            }
            return false
        }
        if defaults.data(forKey: Key.folderLocation) == nil { rememberLocation(of: source) }
        if Self.samePlace(source, root) {
            // An earlier build connected the container itself through a bookmark: nothing to move.
            retireFolderBookmark(); return true
        }
        var record = migrationRecord.flatMap { $0.sourcePath == source.path && $0.container == identifier ? $0 : nil }
            ?? SyncMigrationRecord(sourcePath: source.path, container: identifier)
        saveMigration(record)
        iCloud = .migrating(SyncMigrationProgress()); status = .migrating(SyncMigrationProgress())
        let migration: LibrarySyncMigration
        do { migration = try LibrarySyncMigration(source: source, destination: root, localRoot: localRoot, deviceID: deviceID, cloud: environment.cloud,
                                                  keyStore: replica.keyStore) }
        catch {
            iCloud = .containerUnavailable(error.localizedDescription); status = .iCloudUnavailable(details: error.localizedDescription)
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
                status = .migrating(outcome.progress)
            case .failure(let error):
                if error is CancellationError { return false }
                status = error as? LibrarySyncError == .keyStoreUnreadable ? .keyStoreUnreadable : .migrationPaused(details: error.localizedDescription)
            }
            do { try await Task.sleep(for: environment.retryInterval) } catch { return false }
        }
        return false
    }

    /// After the switch, keeps copying the previous folder's remaining audio objects in the background.
    func finishMigration(into root: URL, identifier: String, generation: UUID) async {
        guard let bookmark = defaults.data(forKey: Key.migratedFolderBookmark), let source = Self.resolve(bookmark),
              var record = migrationRecord,
              let migration = try? LibrarySyncMigration(source: source, destination: root, localRoot: localRoot, deviceID: deviceID, cloud: environment.cloud,
                                                        keyStore: replica.keyStore)
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
    func run(_ migration: LibrarySyncMigration, generation: UUID) async -> Result<SyncMigrationOutcome, Error> {
        let source = migration.source
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        migrationAttempt += 1
        let attempt = migrationAttempt
        defer { settledMigrationAttempt = attempt }
        do {
            let outcome = try await migration.run { [weak self] progress in
                Task { @MainActor [weak self] in self?.showMigration(progress, generation: generation, attempt: attempt) }
            }
            return .success(outcome)
        } catch { return .failure(error) }
    }

    func showMigration(_ progress: SyncMigrationProgress, generation: UUID, attempt: Int) {
        guard generation == containerGeneration, attempt > settledMigrationAttempt, case .migrating = iCloud else { return }
        iCloud = .migrating(progress); status = .migrating(progress)
    }

    func saveMigration(_ record: SyncMigrationRecord) {
        migrationRecord = record
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Key.migration) }
    }

    /// The previous folder is never connected again. Its bookmark is kept apart, only to finish copying audio.
    func retireFolderBookmark() {
        if let data = defaults.data(forKey: Key.folderBookmark) { defaults.set(data, forKey: Key.migratedFolderBookmark) }
        defaults.removeObject(forKey: Key.folderBookmark)
        retiredFolderChanges &+= 1
    }

    func observeAccount() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accountDidChange() }
        }
    }

    /// Pauses: the pass in flight is cancelled and its receipt can't be acknowledged. Then the container is
    /// checked again, which waits for the person if the account is now a different one.
    func accountDidChange() {
        guard transport != .folder, !isOnSameAccount, let identifier = containerIdentifier else { return }
        detach()
        startContainer(identifier)
    }

    /// Whether sync is connected with the account signed in now. The account-change notification also arrives when
    /// nothing changed (at launch, for one), and then sync carries on.
    public var isOnSameAccount: Bool {
        switch transport {
        case .iCloudContainer: return Self.sameAccount(defaults.data(forKey: Key.account), environment.accountIdentity())
        case .folder: return Self.sameAccount(folderAccount, environment.accountIdentity())
        case .none: return false
        }
    }

    static func sameAccount(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return sameAccount(a, b)
    }

    /// How the account is recorded (`Key.account`): the SHA-256 of its archived identity token. Archives of the same
    /// token are the same bytes, so equal digests are the same account.
    static func accountDigest(_ archive: Data) -> Data { Data(SHA256.hash(data: archive)) }

    static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: bookmarkResolution, relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Whether this build can list `url`, with its security scope held while it checks.
    static func canOpen(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    static func samePlace(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether `recorded` (a digest, `accountDigest`, or an archive as releases before it kept it) is the account whose
    /// archived token is `current`. Bytes are compared, never decoded: preferences another process of the person's can
    /// write never instantiate anything in this one. A record that reads differently is settled by the container
    /// (`prepareContainer`).
    static func sameAccount(_ recorded: Data, _ current: Data) -> Bool {
        recorded == current || recorded == accountDigest(current)
    }
}

extension SyncMigrationRecord {
    mutating func update(with outcome: SyncMigrationOutcome) {
        copiedFiles = outcome.progress.completed; totalFiles = outcome.progress.total
        remainingFiles = outcome.progress.waitingForDownload
        sourceLibraryID = outcome.sourceLibraryID ?? sourceLibraryID
        containerLibraryID = outcome.destinationLibraryID ?? containerLibraryID
        adoptedCheckpoint = adoptedCheckpoint || outcome.adoptedCheckpoint
        skipped = Array(Set(skipped + outcome.progress.skipped)).sorted()
    }
}
