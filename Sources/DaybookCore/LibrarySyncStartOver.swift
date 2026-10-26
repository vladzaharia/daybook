import Foundation

// Starting over (docs/icloud-sync.md, "Encryption", "Starting over"). When an encrypted library's key is lost on every
// device (none holds it, iCloud Keychain doesn't bring it, and there's no recovery key), the person can start over: a new
// library, with a new ID and a new key, replaces it. No checkpoint carries over to the new library, so every device
// publishes its own library into it, as when a device meets a different library identity; devices holding the same
// conversation merge like concurrent edits. The old library's files go: its sealed files wherever their header says
// they're its, and its plaintext history from before encryption (another library's, which the new one must never read
// as its own). Plaintext recordings from before encryption (`Blobs/`) stay, so a conversation a device publishes again
// can still use one; the new library's sealer seals what's used and retires the rest. Whatever existed only in iCloud
// is lost.
//
// Two devices starting over at once each write a library. Their manifests resolve like any (`resolveManifest`): the
// smallest new library ID wins and replaces the other, whose files then go the same way, and whose devices publish again
// into the winner once they have its key.

/// A sealed file of a library this one replaced: deleted, never warned about or waited for.
struct SyncReplacedFile: Error {}

extension LibrarySyncEngine {
    /// Start Over isn't offered while another device has said it holds the key within this long: get it from there.
    static let keyHolderAbsence: TimeInterval = migratorAbsence

    /// Whether Start Over may be offered: this device waits for an encrypted library's key, can keep a new one, and no
    /// other device may hold that key (`keyHeldElsewhere`).
    public func mayStartOver(now: Date = Date()) -> Bool {
        guard keyStore != nil, sealing == nil, waitingForKey != nil, let description = waitingSealing else { return false }
        return !keyHeldElsewhere(description, now: now)
    }

    /// Whether another device may hold the current key: its presence said so within `keyHolderAbsence`, or it made
    /// the key (the migrator) that recently and hasn't said it's waiting for it.
    private func keyHeldElsewhere(_ manifest: SyncManifest.Sealing, now: Date) -> Bool {
        let records = presenceRecords()
        if records.contains(where: {
            $0.deviceID != deviceID && $0.key == SyncDeviceKeyState(state: .ready, id: manifest.current)
                && now.timeIntervalSince($0.lastSeen) < Self.keyHolderAbsence
        }) { return true }
        guard manifest.migrator != deviceID else { return false }
        let migrator = records.first { $0.deviceID == manifest.migrator }
        if migrator?.key == SyncDeviceKeyState(state: .waiting, id: manifest.current) { return false }
        return now.timeIntervalSince(max(migrator?.lastSeen ?? .distantPast, manifest.sealedSince)) < Self.keyHolderAbsence
    }

    /// Replaces an encrypted library whose key is lost with a new one: a new library ID and key (stored and read back
    /// first), a manifest naming the old library as replaced, and the old library's files deleted. This device becomes
    /// the migrator; its next pass publishes its library into the new one. Refused (`keyAvailable`) while this device
    /// holds the key or another may (`keyHeldElsewhere`). When another device started over first, this one joins its
    /// library and waits for that key. A plaintext library has nothing to start over. Returns the library synced now.
    @discardableResult
    public func startOver(recovery: RecoveryKey? = nil, now: Date = Date()) throws -> UUID {
        guard keyStore != nil else { throw LibrarySyncError.keyStoreUnavailable }
        let manifest = try prepareRemote()
        libraryID = manifest.libraryID
        guard manifest.isSealed, let description = manifest.sealing else { return manifest.libraryID }
        do {
            try loadSealing(manifest)
            throw LibrarySyncError.keyAvailable
        } catch LibrarySyncError.keyUnavailable {}
        guard !keyHeldElsewhere(description, now: now) else { throw LibrarySyncError.keyAvailable }
        return try replaceLibrary(manifest, recovery: recovery, now: now)
    }

    /// Writes the new library over `manifest`'s (read again under coordination: another device may have started over
    /// meanwhile, and then its library stands and this device joins it), and deletes the old library's files.
    func replaceLibrary(_ manifest: SyncManifest, recovery: RecoveryKey?, now: Date) throws -> UUID {
        guard let keyStore else { throw LibrarySyncError.keyStoreUnavailable }
        let newID = UUID()
        let key = LibraryKey.generate(libraryID: newID, createdBy: deviceID, now: now)
        try keyStore.store(key)
        guard try keyStore.keys(for: newID).contains(where: { $0.id == key.id }) else { throw LibraryKeyStoreError.notKept }
        var fresh = SyncManifest(libraryID: newID)
        fresh.schemaVersion = SyncManifest.sealedSchemaVersion
        fresh.sealing = SyncManifest.Sealing(current: key.idHex, sealedSince: now, migrator: deviceID,
                                             keys: [SyncManifest.Sealing.Key(id: key.idHex, created: key.createdAt, recovery: recovery?.wrap(key))],
                                             replaces: SyncManifest.Sealing.union([manifest.libraryID], manifest.sealing?.replaces))
        let url = remoteRoot.appendingPathComponent("daybook-sync.json")
        var standing: SyncManifest?
        try SyncFiles.coordinateWrite(url, below: remoteRoot) { target in
            let there = try SyncManifest.checked(SyncManifest.decode(Data(contentsOf: target)))
            if there.libraryID == manifest.libraryID {
                try LocalFiles.atomicWrite(fresh.encoded(), to: target)
            } else if there.sealing?.replaces?.contains(manifest.libraryID) == true {
                standing = there
            } else {
                throw LibrarySyncError.manifestConflict
            }
        }
        if let standing {
            try? keyStore.remove(keyID: key.id, libraryID: newID)
            libraryID = standing.libraryID
            try? loadSealing(standing)
            return standing.libraryID
        }
        libraryID = newID
        forgetOtherLibraries(newID)
        try loadSealing(fresh)
        deleteReplacedFiles(Set(fresh.sealing?.replaces ?? []), starting: true)
        return newID
    }

    /// A journal entry of a replaced library, found by a pass: deleted, and left out of what the pass read.
    func setAside(_ entry: JournalEntry) {
        deleteRemote(entry.url)
        if let delivered = inboxCopy(entry.path) { discardDelivery(delivered) }
        replacedEntries.insert(entry.path)
    }

    /// After a pass of a library that started over: objects here whose header names a library it replaced (a rival that
    /// started over at the same moment and lost, or what Start Over couldn't read), and the courier's inbox for those
    /// libraries. Only objects this device has downloaded are checked; their journal entries go as passes read them.
    func deleteReplacedObjects() {
        guard let replaced = sealing?.manifest.replaces, !replaced.isEmpty else { return }
        deleteReplacedFiles(Set(replaced), starting: false)
        for id in replaced {
            let inbox = inboxBase.appendingPathComponent(id.uuidString, isDirectory: true)
            if (try? SyncFiles.noSymlinks(inbox, below: inboxBase)) != nil { try? fm.removeItem(at: inbox) }
        }
    }

    /// Deletes the replaced libraries' files. Downloaded sealed files go when their header names one of them. Starting
    /// over also deletes the plaintext history from before encryption and every sealed object not downloaded here (no
    /// other library's can be there yet: the new one has written nothing); entries not downloaded go as passes read them.
    private func deleteReplacedFiles(_ replaced: Set<UUID>, starting: Bool) {
        guard !replaced.isEmpty else { return }
        if starting {
            for name in ["Events", "Metadata"] {
                for url in (try? journalFiles(in: name)) ?? [] { deleteRemote(url) }
            }
        }
        let kinds: [SealedKind] = starting ? [.event, .metadata, .blob] : [.blob]
        for kind in kinds {
            guard let directory = kind.directory else { continue }
            let folder = remoteRoot.appendingPathComponent(directory, isDirectory: true)
            guard (try? SyncFiles.noSymlinks(folder, below: remoteRoot)) != nil,
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names {
                let stem = name.hasPrefix(".") && name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(7)) : name
                guard SyncFiles.isHash(stem) else { continue }
                let url = folder.appendingPathComponent(stem), path = "\(directory)/\(stem)"
                switch SyncFiles.itemState(url) {
                case .local:
                    guard let library = checkedObjects[path] ?? sealedLibrary(of: url) else { continue }
                    if replaced.contains(library) { deleteRemote(url); checkedObjects[path] = nil } else { checkedObjects[path] = library }
                case .inCloud:
                    if starting && kind == .blob { deleteRemote(url) }
                case .absent:
                    continue
                }
            }
        }
    }

    /// The library a downloaded sealed file's header names, reading its header alone.
    private func sealedLibrary(of url: URL) -> UUID? {
        let header = try? SyncFiles.coordinateRead(url, below: remoteRoot) { source -> Data in
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            return try handle.read(upToCount: SealedHeader.size) ?? Data()
        }
        return header.flatMap(SealedObject.header(of:))?.libraryID
    }
}
