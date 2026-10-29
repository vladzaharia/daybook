import Foundation

// Turning encryption on, and the sealer (docs/icloud-sync.md, "Encryption"). Enabling stores a new key in iCloud
// Keychain, reads it back, and only then rewrites the manifest as version 2 naming it; from the next pass every device
// with the key seals what it writes. The library's history is sealed again, not rewritten: an entry's ID is its
// plaintext's SHA-256 either way, so nothing is republished and no merge changes. One device, the migrator, seals it:
//
// - every event of a live conversation, and only the deletion of a deleted one (its snapshots and audio are left
//   behind, and go when the plaintext is retired);
// - every library settings version;
// - the audio, photos, and sidecars live conversations use now (their merged heads, and highlight sidecars).
//
// Each device also seals plaintext entries it wrote itself after encryption began (a pass already running), and every
// device reads plaintext and sealed entries alike, so nothing waits for the sealer. Once everything live is sealed,
// read back, and uploaded, and either another device holds the key or a recovery key was saved, and a week has passed,
// the migrator deletes the plaintext (`legacyRetired`). Rotating the key works the same way: the new key's files are
// sealed from the old key's, and once every device seen recently holds the new key and a week has passed, the old
// key's files and the key itself are deleted. A deleted conversation's history isn't carried over, so rotating is how
// it's erased from iCloud.

/// How far the sealer has got, on the device that runs it.
public struct SealerProgress: Equatable, Sendable {
    /// Entries and objects still to seal (from before, or under a key no longer current).
    public var remaining = 0
    /// Sealed on the last pass.
    public var sealed = 0
    /// No plaintext from before is left (it was retired, or there never was any).
    public var legacyRetired = false
    /// No files under keys that aren't current are left.
    public var oldKeysRetired = true
    /// What retiring the rest waits for, if anything.
    public var waitingFor: [RetirementWait] = []
    /// An iPhone sealing history waits for Wi‑Fi to download recordings (`SyncReplicaConfiguration.network`).
    public var waitsForWiFi = false

    public enum RetirementWait: String, Sendable {
        /// The grace period (a week after encryption began, or after the key changed).
        case gracePeriod
        /// Another device holding the key, or a saved recovery key.
        case anotherDeviceOrRecoveryKey
        /// Every device seen recently holding the current key.
        case devicesWithCurrentKey
        /// iCloud uploading what was sealed.
        case uploads
        /// A complete read of the journal (downloads, a bounded pass).
        case completeRead
    }

    public init() {}
}

/// What the sealer needs of a pass.
struct SealerInput {
    var events: [String: SyncEventHeader]
    var metadata: [String: SyncMetadataRecord]
    var eventEntries: [JournalEntry]
    var metadataEntries: [JournalEntry]
    /// Compaction records (LibrarySyncCompaction.swift): history like the rest, sealed again under a new key before an old
    /// one retires.
    var compactionEntries: [JournalEntry] = []
    /// Deleted conversations.
    var deleted: Set<UUID>
    /// The objects each live conversation's merged heads use (and highlight sidecars).
    var liveAssets: [UUID: [SyncAsset]]
    /// Every live conversation applied this pass, nothing pending or deferred.
    var complete: Bool
}

extension LibrarySyncEngine {
    /// How long plaintext stays after encryption began, and an old key's files after a rotation.
    static let retirementGrace: TimeInterval = 7 * 24 * 60 * 60
    /// Devices seen within this long must hold the current key before an old key's files go.
    static let recentDevice: TimeInterval = 30 * 24 * 60 * 60
    /// A migrator not seen for this long is replaced by the next Mac with the key.
    static let migratorAbsence: TimeInterval = 14 * 24 * 60 * 60
    /// How many recordings an on-demand replica's sealer has iCloud download at once.
    static let sealerDownloadBatch = 4

    // MARK: Turning it on

    /// Encrypts this library from now on: a new key goes to the keychain (and is read back), then the manifest becomes
    /// version 2 naming it, with this device as the migrator. A key this device made before (an attempt that stopped
    /// before the manifest) is used rather than a second one; another device enabling at the same moment ends with
    /// both keys listed and the newer one current. With `recovery`, the key is also kept wrapped with it. Returns the
    /// current key. There's no turning it off; resetting means a new library.
    @discardableResult
    public func enableSealing(recovery: RecoveryKey? = nil, now: Date = Date()) throws -> LibraryKey {
        guard let keyStore else { throw LibrarySyncError.keyStoreUnavailable }
        let manifest = try prepareRemote()
        libraryID = manifest.libraryID
        if manifest.isSealed {
            try loadSealing(manifest)
            if let recovery, let sealing, !sealing.hasRecovery { try saveRecoveryKey(recovery) }
            return sealing!.current
        }
        let held = try keyStore.keys(for: manifest.libraryID)
        let key: LibraryKey
        if let existing = held.max(by: { ($0.createdAt, $0.idHex) < ($1.createdAt, $1.idHex) }) {
            key = existing
        } else {
            key = LibraryKey.generate(libraryID: manifest.libraryID, createdBy: deviceID, now: now)
            try keyStore.store(key)
        }
        let entry = SyncManifest.Sealing.Key(id: key.idHex, created: key.createdAt, recovery: recovery?.wrap(key))
        let updated = try updateManifest { manifest in
            let mine = SyncManifest.Sealing(current: key.idHex, sealedSince: now, migrator: self.deviceID, keys: [entry])
            manifest.sealing = manifest.sealing.map { $0.merged(with: mine) } ?? mine
            // A compacted library (version 3) stays compacted.
            manifest.schemaVersion = max(manifest.schemaVersion, SyncManifest.sealedSchemaVersion)
        }
        try prepareRemoteFolders()
        try loadSealing(updated)
        return sealing!.current
    }

    /// Keeps every key this device holds for the library wrapped with `recovery` in the manifest, so a device that can't
    /// get the key from iCloud Keychain or another device can still open the library (`recoverKeys(with:)`).
    public func saveRecoveryKey(_ recovery: RecoveryKey) throws {
        guard let current = sealing else { throw LibrarySyncError.keyUnavailable(waitingForKey ?? "") }
        let updated = try updateManifest { manifest in
            guard var description = manifest.sealing else { return }
            for index in description.keys.indices {
                guard let id = SealedFormat.data(hex: description.keys[index].id), let key = current.keys[id] else { continue }
                description.keys[index].recovery = recovery.wrap(key)
            }
            manifest.sealing = description
        }
        if let description = updated.sealing { sealing?.manifest = description }
    }

    /// Opens the keys the manifest keeps wrapped with `recovery` and stores them. Returns how many; none means it isn't
    /// this library's recovery key (or none was saved).
    public func recoverKeys(with recovery: RecoveryKey) throws -> Int {
        guard let keyStore else { throw LibrarySyncError.keyStoreUnavailable }
        let manifest = try prepareRemote()
        libraryID = manifest.libraryID
        guard let description = manifest.sealing else { return 0 }
        var recovered = 0
        for entry in description.keys {
            guard let wrapped = entry.recovery, let id = SealedFormat.data(hex: entry.id),
                  let key = recovery.unwrap(wrapped, keyID: id, libraryID: manifest.libraryID, createdAt: entry.created) else { continue }
            try keyStore.store(key)
            recovered += 1
        }
        if recovered > 0 { try? loadSealing(manifest) }
        return recovered
    }

    /// Stores a key another device sent (the local link) when it's one of this library's keys. True when stored.
    public func acceptKey(_ material: Data, keyID: Data, libraryID: UUID) throws -> Bool {
        guard let keyStore else { throw LibrarySyncError.keyStoreUnavailable }
        guard libraryID == self.libraryID, let key = try? LibraryKey(libraryID: libraryID, material: material, createdAt: Date(), createdBy: "link"),
              key.id == keyID else { return false }
        try keyStore.store(key)
        return true
    }

    /// The keys this device holds for its library, to send to a paired device that's waiting for one.
    public func heldKeys() -> [LibraryKey] {
        guard let libraryID, let keyStore else { return [] }
        return (try? keyStore.keys(for: libraryID)) ?? []
    }

    /// Replaces the current key with a new one (this device becomes the migrator). Everything live is sealed again
    /// under it; once every device seen recently holds it and a week has passed, the old key's files (and with them
    /// the history of deleted conversations) and the old key are deleted.
    @discardableResult
    public func rotateKey(now: Date = Date()) throws -> LibraryKey {
        guard let keyStore else { throw LibrarySyncError.keyStoreUnavailable }
        guard let current = sealing else { throw LibrarySyncError.keyUnavailable(waitingForKey ?? "") }
        let key = LibraryKey.generate(libraryID: current.libraryID, createdBy: deviceID, now: max(now, current.current.createdAt.addingTimeInterval(1)))
        try keyStore.store(key)
        let updated = try updateManifest { manifest in
            guard var description = manifest.sealing else { return }
            description.keys.append(SyncManifest.Sealing.Key(id: key.idHex, created: key.createdAt))
            description.current = key.idHex
            description.migrator = self.deviceID
            manifest.sealing = description
        }
        try loadSealing(updated)
        return key
    }

    /// The library's encryption as this device sees it: nil for a plaintext library.
    public func sealingSummary() -> SealingSummary? {
        if let waitingForKey { return SealingSummary(currentKey: waitingForKey, hasKey: false, hasRecoveryKey: false, isMigrator: false, progress: nil) }
        guard let sealing else { return nil }
        return SealingSummary(currentKey: sealing.current.idHex, hasKey: true, hasRecoveryKey: sealing.hasRecovery,
                              isMigrator: sealing.manifest.migrator == deviceID, progress: sealerProgress)
    }

    // MARK: The manifest

    /// Changes the manifest with a coordinated write after reading it again (another device may have changed it). It
    /// must stay this library, and pass the version gate.
    func updateManifest(_ change: (inout SyncManifest) throws -> Void) throws -> SyncManifest {
        let url = remoteRoot.appendingPathComponent("daybook-sync.json")
        var result: SyncManifest?
        try SyncFiles.coordinateWrite(url, below: remoteRoot) { target in
            var manifest = try SyncManifest.checked(SyncManifest.decode(Data(contentsOf: target)))
            guard manifest.libraryID == self.libraryID else { throw LibrarySyncError.manifestConflict }
            try change(&manifest)
            manifest = try SyncManifest.checked(manifest)
            try LocalFiles.atomicWrite(manifest.encoded(), to: target)
            result = manifest
        }
        guard let result else { throw LibrarySyncError.invalidManifest }
        return result
    }

    private func prepareRemoteFolders() throws {
        for name in ["Sealed", "Sealed/Events", "Sealed/Metadata", "Sealed/Blobs"] {
            let directory = remoteRoot.appendingPathComponent(name, isDirectory: true)
            try SyncFiles.noSymlinks(directory, below: remoteRoot); try LocalFiles.directory(directory)
        }
    }

    // MARK: Eviction

    /// Whether originals recorded here may be evicted in an encrypted library: another device holds the current key,
    /// or a recovery key was saved. Until then the local copy stays, in case it's the only one this device could open.
    func sealedOriginalsMayEvict(now: Date = Date()) -> Bool {
        guard let sealing else { return true }
        return sealing.hasRecovery || otherDevicesHolding(sealing.current.idHex).count > 0
    }

    /// Other devices whose presence says they hold the key `id`.
    func otherDevicesHolding(_ id: String) -> [SyncDeviceRecord] {
        presenceRecords().filter { $0.deviceID != deviceID && $0.key == SyncDeviceKeyState(state: .ready, id: id) }
    }

    /// Every presence record in the sync folder that reads (downloaded ones; others are requested).
    func presenceRecords() -> [SyncDeviceRecord] {
        guard let urls = try? journalFiles(in: SyncPresenceFiles.directory) else { return [] }
        return urls.compactMap { url in
            guard let bytes = try? SyncFiles.read(url, below: remoteRoot, cloud: cloud), let record = SyncPresenceFiles.decode(bytes),
                  url.lastPathComponent == SyncPresenceFiles.fileName(for: record.deviceID) else { return nil }
            return record
        }
    }

    // MARK: The sealer

    /// One pass of the sealer, after a pass has read the journal and merged: seals what's live from before (or under an
    /// older key) within the pass's budget, then retires what's no longer needed once it's safe. Best effort: a failure
    /// leaves the rest for the next pass.
    func runSealer(_ input: SealerInput, budget: inout SyncPassBudget, now: Date = Date()) -> SealerProgress {
        var progress = SealerProgress()
        guard let sealing else { return progress }
        let current = sealing.current
        // What the sealer writes is history every device already has: the courier doesn't carry it.
        let reported = courierWrites
        defer { courierWrites = reported }
        var isMigrator = sealing.manifest.migrator == deviceID
        if !isMigrator, audioPolicy == .eager, migratorIsAbsent(sealing.manifest.migrator, now: now),
           let updated = try? updateManifest({ $0.sealing?.migrator = self.deviceID }), let description = updated.sealing {
            self.sealing?.manifest = description
            isMigrator = true
        }
        var sealedPaths = Set((input.eventEntries + input.metadataEntries + input.compactionEntries).filter(\.isSealed).map(\.path)).union(ownJournalWrites)
        func counterpart(_ kind: SealedKind, _ id: String) -> String { "\(kind.directory!)/\(current.objectName(kind, plaintextSHA256: id) ?? "")" }

        // Journal entries and compaction records: from before, or sealed under another key.
        for (entries, kind) in [(input.eventEntries, SealedKind.event), (input.metadataEntries, .metadata), (input.compactionEntries, .compaction)] {
            for entry in entries where !entry.isSealed || sealedKeys[entry.path] != current.id {
                guard let id = entry.isSealed ? sealedNames[entry.path] : entry.name else { progress.remaining += 1; continue }
                let author: String
                if kind == .event {
                    guard let header = input.events[id] else { progress.remaining += 1; continue }
                    // A deleted conversation keeps only its deletion.
                    if input.deleted.contains(header.meetingID), !header.deleted { continue }
                    author = header.deviceID
                } else if kind == .compaction {
                    guard let record = compactionRecords[entry.path], record.id == id else { progress.remaining += 1; continue }
                    author = record.record.deviceID
                } else {
                    guard let record = input.metadata[id] else { progress.remaining += 1; continue }
                    author = record.deviceID
                }
                if sealedPaths.contains(counterpart(kind, id)) { continue }
                guard isMigrator || author == deviceID, !budget.timeExceeded, budget.admitJournalRead() else { progress.remaining += 1; continue }
                do {
                    let (read, bytes) = try readEntry(entry, kind: kind)
                    guard read == id else { progress.remaining += 1; continue }
                    sealedPaths.insert(try writeSealed(bytes, id: id, kind: kind, key: current))
                    progress.sealed += 1
                } catch { progress.remaining += 1 }
            }
        }

        // Objects live conversations use, sealed by the migrator.
        if isMigrator {
            // Downloads asked for that arrived, or whose object went, make room for the next batch.
            sealerDownloads = sealerDownloads.filter { SyncFiles.itemState(remoteRoot.appendingPathComponent($0)) == .inCloud }
            for (meetingID, assets) in input.liveAssets.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where !input.deleted.contains(meetingID) {
                for asset in assets {
                    guard let name = current.objectName(.blob, plaintextSHA256: asset.sha256) else { continue }
                    let path = "Sealed/Blobs/\(name)"
                    let url = remoteRoot.appendingPathComponent(path)
                    if SyncFiles.itemState(url) != .absent || inboxCopy(path) != nil { continue }
                    guard !budget.timeExceeded else { progress.remaining += 1; continue }
                    if (try? sealObject(asset, meetingID: meetingID, sealing: sealing, progress: &progress)) == true { progress.sealed += 1 } else { progress.remaining += 1 }
                }
            }
        }

        progress.legacyRetired = sealing.manifest.legacyRetired != nil && !hasLegacyFiles()
        progress.oldKeysRetired = sealing.manifest.keys.count == 1
        guard isMigrator else { return progress }
        guard input.complete, progress.remaining == 0 else {
            if !(progress.legacyRetired && progress.oldKeysRetired) { progress.waitingFor.append(input.complete ? .uploads : .completeRead) }
            return progress
        }
        retire(input, progress: &progress, now: now)
        return progress
    }

    /// Seals one object from this device's verified local copy, or from the sync folder's copy (plaintext, or under an
    /// older key) once it's downloaded. False while it waits for a download or its recording to arrive. An on-demand
    /// replica (an iPhone) asks for downloads only on an unrestricted network, `sealerDownloadBatch` at a time, and lets
    /// iCloud drop the downloaded copy once it's sealed.
    private func sealObject(_ asset: SyncAsset, meetingID: UUID, sealing: SealingState, progress: inout SealerProgress) throws -> Bool {
        let directory = localRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        if let local = try? LocalFiles.relativeURL(asset.relativePath, in: directory), (try? verified(local, digest: asset.sha256)) == true {
            try uploadSealed(asset, from: local, sealing: sealing)
            return true
        }
        let candidates = sealing.readingOrder.filter { $0.id != sealing.current.id }.compactMap { key -> RemoteObject? in
            key.objectName(.blob, plaintextSHA256: asset.sha256).map { .sealed(remoteRoot.appendingPathComponent("Sealed/Blobs/\($0)"), name: $0, key: key) }
        } + [.legacy(blobURL(asset.sha256))]
        guard let object = candidates.first(where: { SyncFiles.itemState($0.url) != .absent }) else { return false }
        let path = String(object.url.standardizedFileURL.path.dropFirst(remoteRoot.path.count + 1))
        guard SyncFiles.itemState(object.url) == .local else {
            guard audioPolicy == .onDemand else { try? cloud.requestDownload(object.url); return false }
            if sealerDownloads.contains(path) { return false }
            guard network() == .unrestricted else { progress.waitsForWiFi = true; return false }
            guard sealerDownloads.count < Self.sealerDownloadBatch else { return false }
            sealerDownloads.insert(path)
            try? cloud.requestDownload(object.url)
            return false
        }
        let staging = localRoot.appendingPathComponent("Sync/Sealing", isDirectory: true)
        try LocalFiles.directory(staging)
        let temporary = staging.appendingPathComponent(".seal-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        guard try copyPlaintext(object.url, of: object, below: remoteRoot, libraryID: sealing.libraryID, to: temporary,
                                expected: asset.sha256) == asset.sha256 else { return false }
        try uploadSealed(asset, from: temporary, sealing: sealing)
        if audioPolicy == .onDemand {
            // Downloaded only to seal it, and in iCloud: iCloud may drop this device's copy.
            sealerDownloads.remove(path)
            cloud.evictLocalCopy(object.url)
        }
        return true
    }

    /// The migrator hasn't been seen for `migratorAbsence` (or, without presence, encryption began that long ago).
    private func migratorIsAbsent(_ migrator: String, now: Date) -> Bool {
        guard migrator != deviceID, let sealing else { return false }
        let record = presenceRecords().first { $0.deviceID == migrator }
        return now.timeIntervalSince(record?.lastSeen ?? sealing.manifest.sealedSince) > Self.migratorAbsence
    }

    // MARK: Retirement

    /// Deletes what an encrypted library no longer needs, once it's safe: the plaintext from before, and files under
    /// keys that aren't current. Only files this pass read and accounted for are deleted, and only when each live one
    /// has a counterpart under the current key that was read back whole and that iCloud reports uploaded.
    private func retire(_ input: SealerInput, progress: inout SealerProgress, now: Date) {
        guard let sealing else { return }
        let current = sealing.current
        let liveShas = Set(input.liveAssets.filter { !input.deleted.contains($0.key) }.values.joined().map(\.sha256))
        let knownShas = Set(input.events.values.flatMap { $0.assets.map(\.sha256) }).union(liveShas)

        // Retiring the plaintext from before.
        let legacyEntries = (input.eventEntries + input.metadataEntries + input.compactionEntries).filter { !$0.isSealed }
        let legacyBlobs = (try? journalBlobNames()) ?? []
        if !legacyEntries.isEmpty || !legacyBlobs.isEmpty || sealing.manifest.legacyRetired == nil {
            // Once retired, plaintext that reappears (iCloud.com's Data Recovery restores deleted files for 30 days) is
            // sealed if it's live and deleted at once.
            var ready = true
            if sealing.manifest.legacyRetired == nil {
                if now.timeIntervalSince(sealing.manifest.sealedSince) < Self.retirementGrace { ready = false; progress.waitingFor.append(.gracePeriod) }
                if !sealing.hasRecovery, otherDevicesHolding(current.idHex).isEmpty { ready = false; progress.waitingFor.append(.anotherDeviceOrRecoveryKey) }
            }
            // A library that started over never wrote plaintext: a recording from before nothing uses is the old library's.
            if ready, let plan = retirementPlan(entries: legacyEntries, blobs: legacyBlobs.map { ($0, Optional<Data>.none) }, input: input,
                                                liveShas: liveShas, knownShas: knownShas, unnamedAreReplaced: sealing.manifest.replaces != nil,
                                                progress: &progress) {
                for url in plan { deleteRemote(url) }
                // Plaintext entries compaction pruned need no sealed counterpart: they go too, once what says they're pruned
                // is in iCloud.
                if compactionRecords.values.filter(\.record.isCommit).allSatisfy({ cloud.isUploaded($0.url) }) {
                    for path in prunedEntryPaths where !path.hasPrefix("Sealed/") { deleteRemote(remoteRoot.appendingPathComponent(path)) }
                }
                deleteStalePresence()
                if sealing.manifest.legacyRetired == nil, let updated = try? updateManifest({ $0.sealing?.legacyRetired = now }), let description = updated.sealing {
                    self.sealing?.manifest = description
                }
                progress.legacyRetired = !hasLegacyFiles()
            }
        } else {
            progress.legacyRetired = true
        }

        // Retiring keys that aren't current.
        let oldKeys = sealing.keys.values.filter { $0.id != current.id }
        let listedOld = sealing.manifest.keys.filter { $0.id != current.idHex }
        let oldEntriesListed = (input.eventEntries + input.metadataEntries + input.compactionEntries).contains { $0.isSealed && sealedKeys[$0.path] != current.id }
        guard !listedOld.isEmpty || oldEntriesListed else { progress.oldKeysRetired = true; return }
        progress.oldKeysRetired = false
        var ready = true
        if now.timeIntervalSince(current.createdAt) < Self.retirementGrace { ready = false; progress.waitingFor.append(.gracePeriod) }
        // Devices seen recently that read encrypted libraries; a Daybook that doesn't can't sync this library under any
        // key, and gets the current one from iCloud Keychain once it's updated.
        let recent = presenceRecords().filter {
            $0.deviceID != deviceID && now.timeIntervalSince($0.lastSeen) < Self.recentDevice && ($0.features ?? []).contains(Self.sealingFeature)
        }
        if recent.contains(where: { $0.key != SyncDeviceKeyState(state: .ready, id: current.idHex) }) { ready = false; progress.waitingFor.append(.devicesWithCurrentKey) }
        guard ready else { return }
        let oldEntries = (input.eventEntries + input.metadataEntries + input.compactionEntries).filter { $0.isSealed && sealedKeys[$0.path] != current.id }
        // An old key's objects: every object the journal ever named, under every old key the manifest still lists (once
        // it doesn't, they're gone; a stray one is left, unreadable to no one with the key).
        var oldBlobs: [(String, Data?)] = []
        for key in oldKeys where listedOld.contains(where: { $0.id == key.idHex }) {
            for sha in knownShas {
                guard let name = key.objectName(.blob, plaintextSHA256: sha) else { continue }
                if SyncFiles.itemState(remoteRoot.appendingPathComponent("Sealed/Blobs/\(name)")) != .absent { oldBlobs.append((sha, key.id)) }
            }
        }
        guard let plan = retirementPlan(entries: oldEntries, blobs: oldBlobs, input: input, liveShas: liveShas, knownShas: knownShas,
                                        progress: &progress) else { return }
        for url in plan { deleteRemote(url) }
        let retiredIDs = Set(listedOld.map(\.id))
        if !retiredIDs.isEmpty, let updated = try? updateManifest({ manifest in
            guard var description = manifest.sealing else { return }
            description.keys.removeAll { retiredIDs.contains($0.id) }
            let already = Set((description.retired ?? []).map(\.id))
            let added = retiredIDs.subtracting(already).sorted().map { SyncManifest.Sealing.RetiredKey(id: $0, at: now) }
            if !added.isEmpty { description.retired = (description.retired ?? []) + added }
            manifest.sealing = description
        }), let description = updated.sealing {
            self.sealing?.manifest = description
        }
        // The old key itself stays in iCloud Keychain for `retiredKeyRemoval`: a file sealed with it later (a device that
        // was away) or restored from iCloud.com stays readable meanwhile, and is sealed again or deleted like this. Its
        // files are what held the history, and they're gone. Then it goes too (`removeRetiredKeys`).
        progress.oldKeysRetired = true
    }

    // MARK: Retired keys

    /// How long a retired key stays in iCloud Keychain: iCloud.com's Data Recovery keeps deleted files 30 days, and a
    /// device away that long may still bring a file sealed with it. Every device seen in the last 30 days must have moved
    /// on to the current key as well.
    static let retiredKeyRemoval: TimeInterval = 30 * 24 * 60 * 60

    /// Removes the keys of libraries this one replaced (Start Over, or two new libraries started at once): their files go
    /// wherever they're found, so nothing can need them. On iCloud Keychain this removes them from every device.
    func removeReplacedLibraryKeys() {
        guard let keyStore, let replaced = sealing?.manifest.replaces else { return }
        for library in replaced where library != sealing?.libraryID {
            for key in (try? keyStore.keys(for: library)) ?? [] { try? keyStore.remove(keyID: key.id, libraryID: library) }
        }
    }

    /// Removes a key this library retired once it's no longer needed: retired `retiredKeyRemoval` ago, every device seen
    /// in the last 30 days holds the current key, and nothing in the sync folder this pass read (`entries`, compaction
    /// records included) is still sealed with it. A file found sealed with it after that is a leftover nobody can open,
    /// and is deleted where it's found (`readSealed`).
    func removeRetiredKeys(entries: [JournalEntry], now: Date) {
        guard let keyStore, let sealing, let retired = sealing.manifest.retired else { return }
        let due = Set(retired.filter { now.timeIntervalSince($0.at) >= Self.retiredKeyRemoval && sealing.manifest.isRetired($0.id) }.map(\.id))
        let held = sealing.keys.values.filter { due.contains($0.idHex) && $0.id != sealing.current.id }
        guard !held.isEmpty else { return }
        // Every presence record must be read: one still downloading might be a device that hasn't moved on.
        guard let recent = recentPresence(now: now)?.filter({ ($0.features ?? []).contains(Self.sealingFeature) }),
              recent.allSatisfy({ $0.key == SyncDeviceKeyState(state: .ready, id: sealing.current.idHex) }) else { return }
        let inUse = Set((entries + compactionRecords.values.map(\.entry)).filter(\.isSealed).compactMap { sealedKeys[$0.path] })
        for key in held where !inUse.contains(key.id) {
            guard (try? keyStore.remove(keyID: key.id, libraryID: sealing.libraryID)) != nil else { continue }
            self.sealing?.keys[key.id] = nil
        }
    }

    /// The files to delete when retiring `entries` and objects `blobs` (by plaintext SHA-256, under the key whose ID is
    /// given, or plaintext with nil), or nil when something isn't safe yet: an entry not read, a live counterpart under
    /// the current key not read back whole, or not uploaded. An object nothing names is left alone, unless
    /// `unnamedAreReplaced` (it's a replaced library's).
    private func retirementPlan(entries: [JournalEntry], blobs: [(String, Data?)], input: SealerInput, liveShas: Set<String>,
                                knownShas: Set<String>, unnamedAreReplaced: Bool = false, progress: inout SealerProgress) -> [URL]? {
        guard let sealing else { return nil }
        let current = sealing.current
        var delete: [URL] = []
        var waitingForUploads = false
        for entry in entries {
            let kind: SealedKind = entry.directory.hasSuffix("Events") ? .event : entry.directory.hasSuffix(Self.compactionDirectory) ? .compaction : .metadata
            guard let id = entry.isSealed ? sealedNames[entry.path] : entry.name else { progress.waitingFor.append(.completeRead); return nil }
            let wanted: Bool
            switch kind {
            case .event:
                guard let header = input.events[id] else { progress.waitingFor.append(.completeRead); return nil }
                wanted = !input.deleted.contains(header.meetingID) || header.deleted
            case .compaction:
                guard compactionRecords[entry.path]?.id == id else { progress.waitingFor.append(.completeRead); return nil }
                wanted = true
            default:
                guard input.metadata[id] != nil else { progress.waitingFor.append(.completeRead); return nil }
                wanted = true
            }
            if wanted {
                guard let name = current.objectName(kind, plaintextSHA256: id) else { return nil }
                let path = "\(kind.directory!)/\(name)"
                switch confirmSealed(path, kind: kind, id: id) {
                case .confirmed: break
                case .uploading: waitingForUploads = true
                case .waitingForWiFi: waitingForUploads = true; progress.waitsForWiFi = true
                case .missing: progress.remaining += 1; return nil
                }
            }
            delete.append(entry.url)
        }
        for (sha, keyID) in blobs {
            let url: URL
            if let keyID {
                guard let key = sealing.keys[keyID], let name = key.objectName(.blob, plaintextSHA256: sha) else { continue }
                url = remoteRoot.appendingPathComponent("Sealed/Blobs/\(name)")
            } else {
                url = blobURL(sha)
            }
            if liveShas.contains(sha) {
                guard let name = current.objectName(.blob, plaintextSHA256: sha) else { return nil }
                switch confirmSealed("Sealed/Blobs/\(name)", kind: .blob, id: sha) {
                case .confirmed: break
                case .uploading: waitingForUploads = true
                case .waitingForWiFi: waitingForUploads = true; progress.waitsForWiFi = true
                case .missing: progress.remaining += 1; return nil
                }
            } else if !knownShas.contains(sha), !unnamedAreReplaced {
                // Not named by anything this pass read (an upload whose entry hasn't arrived): left alone.
                continue
            }
            delete.append(url)
        }
        if waitingForUploads { progress.waitingFor.append(.uploads); return nil }
        return delete
    }

    private enum Confirmation { case confirmed, uploading, missing, waitingForWiFi }

    /// Whether the sealed file at `path` (under the current key) was read back whole and iCloud has it.
    private func confirmSealed(_ path: String, kind: SealedKind, id: String) -> Confirmation {
        guard let sealing else { return .missing }
        let url = remoteRoot.appendingPathComponent(path)
        if !sealerVerified.contains(path) {
            switch SyncFiles.itemState(url) {
            case .absent: return .missing
            case .inCloud:
                // An iPhone reads a recording back only on Wi‑Fi.
                if kind == .blob, audioPolicy == .onDemand, network() != .unrestricted { return .waitingForWiFi }
                try? cloud.requestDownload(url); return .uploading
            case .local: break
            }
            let whole: Bool
            switch kind {
            case .blob:
                whole = (try? objectHolds(.sealed(url, name: url.lastPathComponent, key: sealing.current), digest: id)) == true
            case .event, .metadata, .presence, .compaction:
                let entry = JournalEntry(url: url, path: path, directory: kind.directory ?? "", name: url.lastPathComponent, isSealed: true)
                whole = (try? readSealed(entry, kind: kind, sealing: sealing)).map { SyncDigest.sha256(data: $0.0) == id } == true
            }
            guard whole else { return .missing }
            sealerVerified.insert(path)
        }
        return cloud.isUploaded(url) ? .confirmed : .uploading
    }

    /// Plaintext objects in `Blobs/` from before, by name (downloaded or not).
    private func journalBlobNames() throws -> [String] {
        let folder = remoteRoot.appendingPathComponent("Blobs", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return Set(names.compactMap { name -> String? in
            if SyncFiles.isHash(name) { return name }
            if name.hasPrefix("."), name.hasSuffix(".icloud") { let stem = String(name.dropFirst().dropLast(7)); return SyncFiles.isHash(stem) ? stem : nil }
            return nil
        }).sorted()
    }

    /// Whether any plaintext journal file from before is still in the sync folder.
    func hasLegacyFiles() -> Bool {
        for name in ["Events", "Metadata", "Blobs", Self.compactionDirectory] {
            let folder = remoteRoot.appendingPathComponent(name, isDirectory: true)
            if let names = try? fm.contentsOfDirectory(atPath: folder.path), names.contains(where: { !$0.hasPrefix(".") || $0.hasSuffix(".icloud") }) { return true }
        }
        return false
    }

    /// Deletes a file from the sync folder (and its placeholder, when evicted), coordinated. Best effort.
    func deleteRemote(_ url: URL) {
        guard (try? SyncFiles.noSymlinks(url, below: remoteRoot)) != nil else { return }
        try? SyncFiles.coordinateDelete(url, below: remoteRoot)
        try? fm.removeItem(at: SyncFiles.placeholder(for: url))
        verifiedAssets.removeValue(forKey: url.path)
    }

    /// Presence records still saying a name or activity in plaintext (written before encryption, or by a Daybook that
    /// doesn't encrypt). A device of this version writes its own sealed again on its next pass.
    private func deleteStalePresence() {
        guard let urls = try? journalFiles(in: SyncPresenceFiles.directory) else { return }
        for url in urls {
            guard let bytes = try? SyncFiles.read(url, below: remoteRoot, cloud: cloud), let record = SyncPresenceFiles.decode(bytes),
                  !record.displayName.isEmpty || record.activity != nil else { continue }
            deleteRemote(url)
        }
    }
}

/// An encrypted library as Settings shows it.
public struct SealingSummary: Equatable, Sendable {
    /// The current key's ID (hex).
    public var currentKey: String
    /// This device holds it.
    public var hasKey: Bool
    /// A recovery key was saved for it.
    public var hasRecoveryKey: Bool
    /// This device seals the library's history.
    public var isMigrator: Bool
    public var progress: SealerProgress?
}
