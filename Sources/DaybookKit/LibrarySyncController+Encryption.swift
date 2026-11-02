import DaybookCore
import Foundation

// An encrypted library through the controller (docs/icloud-sync.md, "Encryption"): turning it on (by itself once every
// device can read it, or from Settings), recovery keys, rotating the key, starting over, a library removed from or
// replaced in iCloud, and keys from a paired device. Its state is the controller's, which both apps observe
// (`encryption`, `mayStartOverEncryption`).
extension LibrarySyncController {
    // MARK: Encryption

    /// After a pass: the library's encryption, and once it's found encrypted, plaintext files the courier still holds
    /// are dropped (and those it sent, deleted).
    func noteEncryption(_ engine: LibrarySyncEngine) async {
        let summary = await engine.sealingSummary()
        let next: LibraryEncryptionState
        if let summary { next = summary.hasKey ? .on(summary) : .waitingForKey }
        else { next = replica.keyStore == nil ? .unavailable : .off }
        if encryption != next { encryption = next }
        let mayStartOver = next == .waitingForKey ? await engine.mayStartOver() : false
        if mayStartOverEncryption != mayStartOver { mayStartOverEncryption = mayStartOver }
        if case .on = next, iCloud == .waitingForKey { iCloud = .connected }
        if next.isOn, let libraryID = await engine.libraryID { courierBridge.forgetPlaintext(of: libraryID) }
    }

    /// Encrypts a plaintext library on its own once every device in use reads encrypted libraries (docs/icloud-sync.md,
    /// "Encryption", "Turning it on"): every other device seen in `automaticEncryptionWindow`. One not seen for longer,
    /// if it's still on an earlier Daybook, says to update when it's back, and changes nothing. An iPhone leaves it to a
    /// Mac that's around, which seals the history from its own audio rather than downloading it.
    func encryptOnceEveryDeviceCan(now: Date = Date()) async {
        guard encryptsAutomatically, encryption == .off, !isSyncing, !isStorageFull, engine != nil else { return }
        // Every identity, superseded or not: one that only looks like an earlier install of another device (the same name)
        // may be a device that's merely away, and encrypting would stop it syncing until it's updated.
        let others = await knownDevices().filter {
            !$0.isCurrentDevice && $0.lastSeen.map { now.timeIntervalSince($0) < Self.automaticEncryptionWindow } == true
        }
        guard others.allSatisfy(\.readsEncryptedLibraries) else { return }
        if replica.device?.deviceClass == .phone, others.contains(where: { $0.deviceClass == .mac }) { return }
        guard encryption == .off, !isSyncing else { return }
        // A pass that started meanwhile is refused as busy; the next one tries again.
        try? await enableEncryption()
    }

    /// How recently a device must have synced for automatic encryption to wait for it to read encrypted libraries.
    static let automaticEncryptionWindow: TimeInterval = 30 * 86_400

    /// Encrypts the library in iCloud from now on (`LibrarySyncEngine.enableSealing`). With `recoveryKey`, its key is
    /// also kept wrapped with it. The next passes seal what's new and the history. There's no turning it off.
    public func enableEncryption(recoveryKey: RecoveryKey? = nil) async throws {
        guard let engine else { throw SyncControllerError.notConnected }
        guard !isSyncing else { throw SyncControllerError.busy }
        // It writes a sealed copy of the library into iCloud before the plaintext goes: not while iCloud is full.
        guard !isStorageFull else { throw SyncControllerError.storageFull }
        try await engine.enableSealing(recovery: recoveryKey)
        await noteEncryption(engine)
        requestSync()
    }

    /// Makes a recovery key, keeps the library's keys wrapped with it in iCloud, and returns it to show once.
    public func createRecoveryKey() async throws -> RecoveryKey {
        guard let engine else { throw SyncControllerError.notConnected }
        let recovery = RecoveryKey.generate()
        try await engine.saveRecoveryKey(recovery)
        await noteEncryption(engine)
        return recovery
    }

    /// Opens the library's keys with a recovery key someone typed. False when it isn't this library's (or doesn't read
    /// as a recovery key).
    public func enterRecoveryKey(_ text: String) async throws -> Bool {
        guard let engine else { throw SyncControllerError.notConnected }
        guard let recovery = RecoveryKey(text) else { return false }
        let recovered = try await engine.recoverKeys(with: recovery)
        guard recovered > 0 else { return false }
        requestSync()
        return true
    }

    /// Replaces the library's key ("Erase Deleted Conversations from iCloud"): everything live is sealed again under a
    /// new key, and once every device has it, the old key's files go, and with them deleted conversations' history.
    public func rotateEncryptionKey() async throws {
        guard let engine else { throw SyncControllerError.notConnected }
        guard !isSyncing else { throw SyncControllerError.busy }
        guard !isStorageFull else { throw SyncControllerError.storageFull }
        try await engine.rotateKey()
        await noteEncryption(engine)
        requestSync()
    }

    /// Starts over with a new encrypted library when the key is lost on every device
    /// (`LibrarySyncEngine.startOver`): what's only in iCloud is lost, and the next pass publishes this device's library
    /// into the new one. Offered only while `mayStartOverEncryption`.
    public func startOverEncryption() async throws {
        guard let engine else { throw SyncControllerError.notConnected }
        guard !isSyncing else { throw SyncControllerError.busy }
        try await engine.startOver()
        await noteEncryption(engine)
        requestSync()
    }

    /// The library this device synced is gone from iCloud (`status == .libraryRemoved`: someone deleted Daybook's data
    /// there): starts a new encrypted library in its place ("Start a New Library in iCloud",
    /// `LibrarySyncEngine.startNewLibrary`). This device publishes its library into it, and every other device does the
    /// same once it has the key. A library another device started meanwhile is joined instead.
    public func startNewLibrary() async throws {
        guard let engine else { throw SyncControllerError.notConnected }
        guard !isSyncing else { throw SyncControllerError.busy }
        try await engine.startNewLibrary()
        await noteEncryption(engine)
        status = .preparing
        requestSync()
    }

    /// iCloud holds a library that isn't encrypted where this device synced an encrypted one (`status == .newLibrary`):
    /// syncs with it anyway. This device forgets the folder held an encrypted library; the library is encrypted again on
    /// its own once every device in use can read encrypted libraries.
    public func syncWithLibraryInICloud() {
        guard let folder, !isSyncing else { return }
        LibrarySyncEngine.forgetSealedLibrary(localRoot: localRoot, remoteRoot: folder)
        status = .preparing
        requestSync()
    }

    /// Devices that would stop syncing if the library were encrypted now: their Daybook doesn't say it reads encrypted
    /// libraries (an earlier version, or one seen only in the journal).
    /// Each device once (`inUse`): an earlier identity of a reinstalled device isn't listed beside it.
    public func devicesNotReadyForEncryption() async -> [KnownSyncDevice] {
        await knownDevices().inUse().filter { !$0.isCurrentDevice && !$0.readsEncryptedLibraries }
    }

    /// The library and key this device waits for, to ask a paired device for it over the local link.
    public func keyRequest() async -> (libraryID: UUID, keyID: String)? {
        guard let engine, let libraryID = await engine.libraryID, let keyID = await engine.waitingForKey else { return nil }
        return (libraryID, keyID)
    }

    /// The keys this device can give a paired device of the same library.
    public func keysToGrant(libraryID: UUID) async -> [LibraryKey] {
        guard let engine, await engine.libraryID == libraryID else { return [] }
        return await engine.heldKeys()
    }

    /// A key a paired device sent, kept only when it answers a request this device made (`libraryKeyRequest`, to `peer`
    /// when `noteKeyRequested(from:)` named one) and the library's manifest lists it while this device doesn't hold it
    /// (`LibrarySyncEngine.acceptKey`). A pass runs. True when kept.
    @discardableResult
    public func acceptKey(_ material: Data, keyID: Data, libraryID: UUID, from peer: UUID? = nil) async -> Bool {
        guard let engine, answersKeyRequest(keyID: keyID, libraryID: libraryID, from: peer),
              (try? await engine.acceptKey(material, keyID: keyID, libraryID: libraryID)) == true else { return false }
        keyRequests.removeAll { $0.libraryID == libraryID }
        requestSync()
        return true
    }

    /// The folder this Mac synced through before the move into iCloud still holds a plaintext copy of the journal, and
    /// the library is now encrypted: Settings offers to delete that copy.
    public var hasRetiredFolderJournal: Bool {
        _ = retiredFolderChanges
        return encryption.isOn && migrationRecord?.completedAt != nil && defaults.data(forKey: Key.migratedFolderBookmark) != nil
    }

    /// Deletes the previous sync folder's journal (its manifest, `Events/`, `Metadata/`, `Blobs/`, and `Devices/`),
    /// nothing else in it, and forgets the folder.
    public func deleteRetiredFolderJournal() throws {
        guard hasRetiredFolderJournal, let bookmark = defaults.data(forKey: Key.migratedFolderBookmark) else { return }
        if let folder = Self.resolve(bookmark) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator(filePresenter: nil)
            for name in ["daybook-sync.json", "Events", "Metadata", "Blobs", "Devices"] {
                let item = folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: item.path) else { continue }
                var coordinationError: NSError?, failure: Error?
                coordinator.coordinate(writingItemAt: item, options: .forDeleting, error: &coordinationError) { target in
                    do { try FileManager.default.removeItem(at: target) } catch { failure = error }
                }
                if let error = coordinationError ?? failure { throw error }
            }
        }
        defaults.removeObject(forKey: Key.migratedFolderBookmark)
        retiredFolderChanges &+= 1
    }
}
