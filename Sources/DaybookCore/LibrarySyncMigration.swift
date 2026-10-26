import Foundation

/// How far copying one sync journal into another has got.
public struct SyncMigrationProgress: Equatable, Sendable {
    /// Journal files in the source: the manifest, events, metadata, audio objects, and presence records.
    public var total = 0
    /// Of those, the ones now present (and, where they're local, verified) in the destination.
    public var completed = 0
    /// Files the source is still downloading from iCloud. They're requested, then retried.
    public var waitingForDownload = 0
    /// Of the waiting files, the manifest, events, and metadata. Sync moves over once this is zero;
    /// audio objects can keep copying afterwards.
    public var waitingJournal = 0
    /// Files that weren't copied and never will be: a source file whose contents don't match its name,
    /// or a destination that already holds different bytes under that name. Nothing is overwritten.
    public var skipped: [String] = []

    public init() {}
    /// The manifest, every event, and every metadata version are in the destination.
    public var journalComplete: Bool { waitingJournal == 0 }
    /// Everything that can be copied has been.
    public var isComplete: Bool { waitingForDownload == 0 }
}

public struct SyncMigrationOutcome: Sendable {
    public var progress: SyncMigrationProgress
    /// The library identity in the source's manifest, when it has one.
    public var sourceLibraryID: UUID?
    /// The destination's library identity: the source's, when the destination had no journal yet.
    public var destinationLibraryID: UUID?
    /// When the two identities differ, this device's checkpoint for the source library was copied to
    /// the destination's identity, so its applied history carries over instead of being republished.
    public var adoptedCheckpoint: Bool
}

/// Copies a sync journal (the folder transport: a folder someone chose in iCloud Drive) into another
/// sync root (the app's iCloud container), so a library can move without losing history.
///
/// - The source is only read. Nothing in it is changed, moved, or deleted; evicted files are asked to
///   download, which doesn't change their contents.
/// - The journal is content-addressed (`Events/` and `Metadata/` are named by the SHA-256 of their bytes,
///   `Blobs/` by the SHA-256 of the audio), so copying is idempotent: every copy is hashed before it's
///   moved into place, a name already in the destination is kept (and verified when it's local), and
///   running again only copies what's missing.
/// - A destination that already has a journal (another Mac moved first, or the iPhone started one) is
///   merged into by content. Its manifest is never replaced. When its library identity differs from the
///   source's, this device's checkpoint is carried over to that identity (`adoptedCheckpoint`) so the
///   engine continues from the same applied heads.
/// - Files the source is still downloading are skipped and counted; run again to pick them up.
/// - Presence records (`Devices/`) are copied only where the destination has none for that device.
/// - A destination that's an encrypted library (docs/icloud-sync.md, "Encryption") gets every journal entry and object
///   sealed under its current key as it's copied, nothing in plaintext, and no presence; without that key the move
///   waits (`keyUnavailable`).
public actor LibrarySyncMigration {
    public nonisolated let source: URL
    public nonisolated let destination: URL
    let localRoot: URL
    let deviceID: String
    let cloud: SyncCloudFiles
    let keyStore: (any LibraryKeyStore)?
    private let fm = FileManager.default
    /// The destination's current key, when it's an encrypted library.
    private var sealingKey: LibraryKey?
    /// Destination paths already confirmed in this process, so retries don't re-hash audio.
    private var confirmed: Set<String> = []
    private var localAudio: [String: URL]?

    public init(source: URL, destination: URL, localRoot: URL, deviceID: String, cloud: SyncCloudFiles = .system,
                keyStore: (any LibraryKeyStore)? = nil) throws {
        self.source = source.standardizedFileURL
        self.destination = destination.standardizedFileURL
        self.localRoot = localRoot.standardizedFileURL
        self.deviceID = deviceID
        self.cloud = cloud
        self.keyStore = keyStore
        let paths = [self.source, self.destination, self.localRoot].map { $0.resolvingSymlinksInPath().path }
        for (index, path) in paths.enumerated() {
            for other in paths[(index + 1)...] where path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/") {
                throw LibrarySyncError.unsafeLocation
            }
        }
        guard !deviceID.isEmpty else { throw LibrarySyncError.unsafeLocation }
    }

    /// One pass: copies whatever is available and reports what's left. Safe to repeat and to cancel.
    public func run(progress report: (@Sendable (SyncMigrationProgress) -> Void)? = nil) throws -> SyncMigrationOutcome {
        try Task.checkCancellation()
        try SyncFiles.noSymlinks(source, below: source)
        try SyncFiles.noSymlinks(destination, below: destination)
        try LocalFiles.directory(destination)
        var progress = SyncMigrationProgress()
        let items = try sourceItems()
        progress.total = items.count + 1
        var lastReport = ContinuousClock.now
        func publish(force: Bool = false) {
            guard let report else { return }
            let now = ContinuousClock.now
            if force || now - lastReport >= .milliseconds(100) { lastReport = now; report(progress) }
        }
        publish(force: true)

        // The manifest decides the library identity, so it goes first.
        let sourceManifest = try manifest(in: source, root: source)
        // A chosen folder holds a plaintext library; one that's encrypted isn't moved.
        if case .found(let from) = sourceManifest, from.isSealed { throw LibrarySyncError.unsupportedVersion(from.schemaVersion) }
        var destinationManifest = try manifest(in: destination, root: destination)
        switch (sourceManifest, destinationManifest) {
        case (.pending, _), (_, .pending):
            // Both identities are needed to know whether this device's checkpoint carries over.
            progress.waitingForDownload += 1; progress.waitingJournal += 1
        case (.found, .absent):
            destinationManifest = try copyManifest()
            progress.completed += 1
        case (.absent, .absent):
            // A folder that never held a journal: nothing to carry over, and the engine makes a manifest.
            progress.completed += 1
        case (_, .found):
            progress.completed += 1
        }
        // An encrypted destination: its current key seals what's copied. The source must be plaintext.
        sealingKey = nil
        if case .found(let manifest) = destinationManifest, let sealing = manifest.sealing {
            guard let id = LibraryKey.id(hex: sealing.current),
                  let key = (try? keyStore?.keys(for: manifest.libraryID))??.first(where: { $0.id == id }) else {
                throw LibrarySyncError.keyUnavailable(sealing.current)
            }
            sealingKey = key
        }
        publish()

        for item in items {
            try Task.checkCancellation()
            switch try migrate(item) {
            case .copied: progress.completed += 1
            case .waiting:
                progress.waitingForDownload += 1
                if item.kind == .journal { progress.waitingJournal += 1 }
            case .skipped(let reason): progress.completed += 1; progress.skipped.append(reason)
            }
            publish()
        }

        var adopted = false
        if case .found(let from) = sourceManifest, case .found(let to) = destinationManifest,
           from.libraryID != to.libraryID, progress.journalComplete {
            adopted = try adoptCheckpoint(from: from.libraryID, to: to.libraryID)
        }
        publish(force: true)
        return SyncMigrationOutcome(progress: progress, sourceLibraryID: sourceManifest.libraryID,
                                    destinationLibraryID: destinationManifest.libraryID, adoptedCheckpoint: adopted)
    }

    // MARK: Items

    enum Kind { case journal, blob, presence }
    struct Item { var path: String; var kind: Kind; var hash: String? }
    enum ItemResult { case copied, waiting, skipped(String) }

    /// Every journal file in the source, including evicted ones (`.name.icloud` placeholders).
    private func sourceItems() throws -> [Item] {
        var items: [Item] = []
        for (directory, kind) in [("Events", Kind.journal), ("Metadata", .journal), ("Blobs", .blob), ("Devices", .presence)] {
            let folder = source.appendingPathComponent(directory, isDirectory: true)
            try SyncFiles.noSymlinks(folder, below: source)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            var seen = Set<String>()
            for raw in names {
                var name = raw
                if raw.hasPrefix("."), raw.hasSuffix(".icloud") { name = String(raw.dropFirst().dropLast(7)) }
                else if raw.hasPrefix(".") { continue }
                let stem = kind == .blob ? name : (name.hasSuffix(".json") ? String(name.dropLast(5)) : "")
                switch kind {
                case .journal, .blob: guard SyncFiles.isHash(stem) else { continue }
                case .presence: guard name.hasSuffix(".json"), !stem.isEmpty, !stem.contains("/") else { continue }
                }
                guard seen.insert(name).inserted else { continue }
                items.append(Item(path: "\(directory)/\(name)", kind: kind, hash: kind == .presence ? nil : stem))
            }
        }
        // Small journal files first, so sync can move over before the audio has finished.
        let order: [Kind: Int] = [.journal: 0, .blob: 1, .presence: 2]
        return items.sorted { (order[$0.kind]!, $0.path) < (order[$1.kind]!, $1.path) }
    }

    private func migrate(_ item: Item) throws -> ItemResult {
        if let sealingKey { return try migrateSealing(item, key: sealingKey) }
        let target = destination.appendingPathComponent(item.path)
        let origin = source.appendingPathComponent(item.path)
        try SyncFiles.noSymlinks(target, below: destination)
        try SyncFiles.noSymlinks(origin, below: source)
        if confirmed.contains(item.path) { return .copied }
        switch SyncFiles.itemState(target) {
        case .inCloud:
            // Already in iCloud from another device. Content-addressed, so the name is the content; the
            // engine verifies it when it reads it.
            confirmed.insert(item.path); return .copied
        case .local:
            guard let hash = item.hash else { confirmed.insert(item.path); return .copied }
            let digest = try SyncFiles.coordinateRead(target, below: destination) { try SyncDigest.sha256(fileURL: $0) }
            guard digest == hash else {
                return .skipped("\(item.path) is already in iCloud with different contents. It was left as it is.")
            }
            confirmed.insert(item.path); return .copied
        case .absent:
            break
        }
        // This Mac's own verified copy of an audio object saves downloading it from the old folder.
        if item.kind == .blob, let hash = item.hash, let local = localAudioIndex()[hash],
           try copy(from: local, below: localRoot, to: target, expecting: hash) {
            confirmed.insert(item.path); return .copied
        }
        do { try SyncFiles.available(origin, cloud: cloud) } catch is SyncPendingDownload { return .waiting }
        guard fm.fileExists(atPath: origin.path) else { return .skipped("\(item.path) is no longer in the old sync folder.") }
        if item.kind == .presence {
            let size = (try? fm.attributesOfItem(atPath: origin.path)[.size] as? NSNumber)?.intValue ?? .max
            guard size <= 64 * 1024 else { return .skipped("\(item.path) is too large for a presence record. It wasn't copied.") }
        }
        guard try copy(from: origin, below: source, to: target, expecting: item.hash) else {
            return .skipped("\(item.path) in the old sync folder is damaged: its contents don’t match its name. It wasn’t copied.")
        }
        confirmed.insert(item.path)
        return .copied
    }

    /// Copies an item into an encrypted destination, sealed under `key` at its sealed name; presence isn't copied.
    private func migrateSealing(_ item: Item, key: LibraryKey) throws -> ItemResult {
        guard item.kind != .presence, let hash = item.hash else { return .copied }
        let kind: SealedKind = item.kind == .blob ? .blob : item.path.hasPrefix("Events/") ? .event : .metadata
        guard let name = key.objectName(kind, plaintextSHA256: hash), let directory = kind.directory else { return .skipped("\(item.path) can’t be sealed.") }
        let path = "\(directory)/\(name)"
        let target = destination.appendingPathComponent(path)
        let origin = source.appendingPathComponent(item.path)
        try SyncFiles.noSymlinks(target, below: destination)
        try SyncFiles.noSymlinks(origin, below: source)
        if confirmed.contains(path) { return .copied }
        // Already there (another device sealed it): sealing is deterministic, so the name is the content.
        if SyncFiles.itemState(target) != .absent { confirmed.insert(path); return .copied }
        var plaintext = origin, below = source
        if item.kind == .blob, let local = localAudioIndex()[hash] {
            plaintext = local; below = localRoot
        } else {
            do { try SyncFiles.available(origin, cloud: cloud) } catch is SyncPendingDownload { return .waiting }
            guard fm.fileExists(atPath: origin.path) else { return .skipped("\(item.path) is no longer in the old sync folder.") }
        }
        let folder = target.deletingLastPathComponent()
        try LocalFiles.directory(folder)
        let temporary = folder.appendingPathComponent(".migrate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        do {
            if kind == .blob {
                _ = try SyncFiles.coordinateRead(plaintext, below: below) {
                    try SealedObject.sealFile($0, to: temporary, kind: .blob, key: key, plaintextSHA256: hash)
                }
            } else {
                let bytes = try SyncFiles.coordinateRead(plaintext, below: below) { try Data(contentsOf: $0) }
                guard SyncDigest.sha256(data: bytes) == hash else { throw SealedObjectError.digestMismatch }
                try SealedObject.seal(bytes, kind: kind, key: key).bytes.write(to: temporary)
            }
        } catch is SealedObjectError {
            return .skipped("\(item.path) in the old sync folder is damaged: its contents don’t match its name. It wasn’t copied.")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try SyncFiles.coordinateWrite(target, below: destination) { url in
            guard !self.fm.fileExists(atPath: url.path) else { return }
            try self.fm.moveItem(at: temporary, to: url)
        }
        confirmed.insert(path)
        return .copied
    }

    /// Copies through a temporary file that's hashed before it's moved into place. False when the bytes
    /// don't match `expecting`. A file that appears at the target meanwhile (another device) is kept.
    private func copy(from origin: URL, below root: URL, to target: URL, expecting hash: String?) throws -> Bool {
        let directory = target.deletingLastPathComponent()
        try LocalFiles.directory(directory)
        let temporary = directory.appendingPathComponent(".migrate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try SyncFiles.coordinateRead(origin, below: root) { try self.fm.copyItem(at: $0, to: temporary) }
        if let hash, try SyncDigest.sha256(fileURL: temporary) != hash { return false }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try SyncFiles.coordinateWrite(target, below: destination) { url in
            guard !self.fm.fileExists(atPath: url.path) else { return }
            try self.fm.moveItem(at: temporary, to: url)
        }
        return true
    }

    /// SHA-256 → file for every original this library holds, active or in Trash, from its meeting records.
    private func localAudioIndex() -> [String: URL] {
        if let localAudio { return localAudio }
        var index: [String: URL] = [:]
        let decoder = JSONDecoder()
        for folder in ["Meetings", "Trash"] {
            let parent = localRoot.appendingPathComponent(folder, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for directory in children where UUID(uuidString: directory.lastPathComponent) != nil {
                guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("meeting.json")),
                      let meeting = try? decoder.decode(Meeting.self, from: bytes) else { continue }
                for track in meeting.tracks where SyncFiles.isHash(track.sha256) && index[track.sha256] == nil {
                    if let url = try? LocalFiles.relativeURL(track.relativePath, in: directory), fm.fileExists(atPath: url.path) {
                        index[track.sha256] = url
                    }
                }
            }
        }
        localAudio = index
        return index
    }

    // MARK: Manifest and checkpoint

    private enum ManifestState {
        case absent, pending, found(SyncManifest)
        var libraryID: UUID? { if case .found(let manifest) = self { return manifest.libraryID } else { return nil } }
    }

    private func manifest(in root: URL, root below: URL) throws -> ManifestState {
        let url = root.appendingPathComponent("daybook-sync.json")
        if !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty { throw LibrarySyncError.manifestConflict }
        do { try SyncFiles.available(url, cloud: cloud) } catch is SyncPendingDownload { return .pending }
        guard fm.fileExists(atPath: url.path) else { return .absent }
        let bytes = try SyncFiles.coordinateRead(url, below: below) { try Data(contentsOf: $0) }
        let manifest: SyncManifest
        do { manifest = try SyncManifest.checked(SyncManifest.decode(bytes)) }
        catch let error as LibrarySyncError { throw error }
        catch { throw LibrarySyncError.invalidManifest }
        return .found(manifest)
    }

    /// Writes the source's manifest into an empty destination, keeping one another device wrote first.
    private func copyManifest() throws -> ManifestState {
        let name = "daybook-sync.json"
        let bytes = try SyncFiles.coordinateRead(source.appendingPathComponent(name), below: source) { try Data(contentsOf: $0) }
        try SyncFiles.coordinateWrite(destination.appendingPathComponent(name), below: destination) { url in
            guard !self.fm.fileExists(atPath: url.path) else { return }
            try LocalFiles.atomicWrite(bytes, to: url)
        }
        return try manifest(in: destination, root: destination)
    }

    /// The engine keeps one checkpoint per library identity and device (`Sync/<library>-<device>.json`).
    /// Copies this device's checkpoint for `old` to `new` when it has none there yet.
    private func adoptCheckpoint(from old: UUID, to new: UUID) throws -> Bool {
        try LibrarySyncEngine.adoptCheckpoint(localRoot: localRoot, deviceID: deviceID, from: old, to: new)
    }
}
