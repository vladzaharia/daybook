import Foundation

// An encrypted library (docs/icloud-sync.md, "Encryption"). Its manifest says `schemaVersion: 2` and names the keys its
// files are sealed with (SealedObject.swift); every Daybook before this one stops at that manifest ("Update Daybook to
// sync") and changes nothing. The logical journal is the same as a plaintext library's: an entry's ID is still the
// SHA-256 of its plaintext record, so parents, heads, and checkpoints don't change. Only the files do: each is sealed
// under the library's current key in `Sealed/Events`, `Sealed/Metadata`, or `Sealed/Blobs`, named by a keyed hash of
// its plaintext. Plaintext files from before (`Events/`, `Metadata/`, `Blobs/`) are read, never written, until the
// sealer has sealed what's live and retires them (LibrarySyncSealer.swift).

extension SyncManifest {
    /// The schema version of an encrypted library.
    static let sealedSchemaVersion = 2

    /// How an encrypted library is sealed. Mutable, unlike the rest of the journal: keys are added (a device enabled
    /// encryption, a recovery key was saved, the key rotated) and retired. Two devices writing it at once leave iCloud
    /// conflict versions, which every device merges the same way (`merged(with:)`).
    struct Sealing: Codable, Equatable {
        static let currentScheme = "DBSEAL-1"
        var scheme = Sealing.currentScheme
        /// The key new files are sealed with, by ID (hex).
        var current: String
        /// When the library became encrypted.
        var sealedSince: Date
        /// The device that seals the library's history and retires what's no longer needed.
        var migrator: String
        /// When the plaintext files from before were deleted. Nil until then.
        var legacyRetired: Date?
        var keys: [Key]
        /// Libraries this one started over from (Start Over, LibrarySyncStartOver.swift): their key was lost, so their
        /// files are deleted where they're found, and no device carries a checkpoint over from them. Nil for a library
        /// that didn't start over.
        var replaces: [UUID]?

        struct Key: Codable, Equatable {
            var id: String
            var created: Date
            /// The key wrapped with a recovery key (`RecoveryKey.wrap`), when one was saved.
            var recovery: String?
        }

        /// The key current among `keys`: the newest, by creation and then ID, so every device picks the same one.
        static func newest(_ keys: [Key]) -> Key? { keys.max { ($0.created, $0.id) < ($1.created, $1.id) } }

        /// One description from two versions written at once: every key of both (a recovery wrap kept from either), the
        /// newest current, the earliest start, the plaintext retired if either retired it, and every library either
        /// replaced. The same whichever order the versions come in.
        func merged(with other: Sealing) -> Sealing {
            var byID: [String: Key] = [:]
            for key in keys + other.keys {
                if var existing = byID[key.id] {
                    existing.recovery = [existing.recovery, key.recovery].compactMap { $0 }.min()
                    existing.created = min(existing.created, key.created)
                    byID[key.id] = existing
                } else { byID[key.id] = key }
            }
            var result = self
            result.keys = byID.values.sorted { $0.id < $1.id }
            let currents = [current, other.current].compactMap { id in result.keys.first { $0.id == id } }
            result.current = Self.newest(currents)?.id ?? min(current, other.current)
            result.sealedSince = min(sealedSince, other.sealedSince)
            result.migrator = [self, other].filter { $0.current == result.current }.map(\.migrator).min() ?? min(migrator, other.migrator)
            result.legacyRetired = [legacyRetired, other.legacyRetired].compactMap { $0 }.max()
            result.replaces = Self.union(replaces, other.replaces)
            return result
        }

        /// Two lists of replaced libraries as one, sorted; nil when both are.
        static func union(_ a: [UUID]?, _ b: [UUID]?) -> [UUID]? {
            guard a != nil || b != nil else { return nil }
            return Set((a ?? []) + (b ?? [])).sorted { $0.uuidString < $1.uuidString }
        }
    }

    var isSealed: Bool { schemaVersion == Self.sealedSchemaVersion }

    /// The version gate, strict however tolerant decoding is: 1 is plaintext, 2 encrypted with a scheme this version
    /// reads; anything else (or 2 with an unknown scheme) is a newer Daybook's.
    static func checked(_ manifest: SyncManifest) throws -> SyncManifest {
        guard manifest.format == "DaybookSync" else { throw LibrarySyncError.invalidManifest }
        switch manifest.schemaVersion {
        case 1:
            return manifest
        case sealedSchemaVersion:
            guard let sealing = manifest.sealing, sealing.scheme == Sealing.currentScheme else { throw LibrarySyncError.unsupportedVersion(manifest.schemaVersion) }
            guard sealing.keys.contains(where: { $0.id == sealing.current }),
                  sealing.keys.allSatisfy({ $0.id.count == 32 && SealedFormat.data(hex: $0.id) != nil }) else { throw LibrarySyncError.invalidManifest }
            return manifest
        default:
            throw LibrarySyncError.unsupportedVersion(manifest.schemaVersion)
        }
    }

    /// Decodes a manifest: the version first, so a newer one reads as newer, not as damaged.
    static func decode(_ data: Data) throws -> SyncManifest {
        struct Header: Decodable { var format: String; var schemaVersion: Int }
        struct Scheme: Decodable { var scheme: String? }
        struct SealingHeader: Decodable { var sealing: Scheme? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard header.format == "DaybookSync" else { throw LibrarySyncError.invalidManifest }
        guard header.schemaVersion == 1 || header.schemaVersion == sealedSchemaVersion else { throw LibrarySyncError.unsupportedVersion(header.schemaVersion) }
        // An encryption scheme this version doesn't know is a newer Daybook's, whatever shape the rest has.
        if header.schemaVersion == sealedSchemaVersion,
           (try? decoder.decode(SealingHeader.self, from: data))?.sealing?.scheme != Sealing.currentScheme {
            throw LibrarySyncError.unsupportedVersion(header.schemaVersion)
        }
        return try decoder.decode(SyncManifest.self, from: data)
    }

    /// The manifest's bytes. A plaintext library's are exactly what earlier versions wrote (no dates, sorted keys).
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// An encrypted library as this device sees it on a pass: its manifest's description and the keys this device holds.
struct SealingState {
    var libraryID: UUID
    var manifest: SyncManifest.Sealing
    /// Every key this device holds for the library, by ID.
    var keys: [Data: LibraryKey]
    var current: LibraryKey

    var keyring: SealedObject.Keyring { { [keys] in keys[$0] } }
    /// Held keys, the current one first: where an object may be sealed.
    var readingOrder: [LibraryKey] { [current] + keys.values.filter { $0.id != current.id }.sorted { $0.idHex < $1.idHex } }
    /// A key the manifest saved a recovery wrap for: the current one.
    var hasRecovery: Bool { manifest.keys.first { $0.id == current.idHex }?.recovery != nil }
    /// Whether this library started over from `library` (Start Over).
    func replaces(_ library: UUID) -> Bool { manifest.replaces?.contains(library) == true }
}

/// What this device remembers about encrypted libraries, beside its checkpoints (`Sync/sealing.json`): once it has
/// synced an encrypted library in a sync folder, it never publishes plaintext there. A manifest replaced by a plaintext
/// one (or removed) pauses sync instead (`LibrarySyncError.sealingRemoved`). Choosing another iCloud account forgets it.
struct SealingMemory: Codable, Equatable {
    struct Remote: Codable, Equatable {
        var libraryID: UUID
        var since: Date
    }
    var schemaVersion = 1
    /// By the SHA-256 (16 hex digits) of the sync folder's path.
    var remotes: [String: Remote] = [:]

    static func url(localRoot: URL) -> URL { localRoot.appendingPathComponent("Sync/sealing.json") }
    static func key(remoteRoot: URL) -> String { String(SyncDigest.sha256(data: Data(remoteRoot.standardizedFileURL.path.utf8)).prefix(16)) }

    static func load(localRoot: URL) -> SealingMemory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(localRoot: localRoot)), let memory = try? decoder.decode(SealingMemory.self, from: data),
              memory.schemaVersion == 1 else { return SealingMemory() }
        return memory
    }

    func save(localRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = Self.url(localRoot: localRoot)
        try SyncFiles.noSymlinks(url, below: localRoot)
        try DurableFiles.write(try encoder.encode(self), to: url)
    }
}

/// A journal file a pass reads: a plaintext one (`Events/<SHA-256>.json`, named by its content) or a sealed one
/// (`Sealed/Events/<name>`), as a sync-folder URL (it may be a courier delivery in the inbox).
struct JournalEntry {
    var url: URL
    /// Relative to the sync folder.
    var path: String
    /// The folder, `Events` or `Sealed/Events` (or the metadata ones).
    var directory: String
    /// The file name without `.json`: the entry's ID when plaintext, its sealed name otherwise.
    var name: String
    var isSealed: Bool
}

/// Where an object (an audio or photo original, a sidecar) is in the sync folder.
enum RemoteObject {
    case legacy(URL)
    case sealed(URL, name: String, key: LibraryKey)

    var url: URL {
        switch self {
        case .legacy(let url), .sealed(let url, _, _): return url
        }
    }
}

/// A sealed entry whose key this device doesn't hold yet (rotated elsewhere, iCloud Keychain still catching up). Read
/// again every pass; it holds back what depends on it, like a download.
struct SyncKeyPending: LocalizedError {
    var keyID: String
    var errorDescription: String? { "Some changes are waiting for this library’s key." }
}

extension LibrarySyncEngine {
    /// Whether a library this engine creates is encrypted from the start. Off until the owner's device checks pass
    /// (docs/icloud-sync.md, "Encryption", "Turning it on for new libraries"); flip this one constant to turn it on.
    /// Any build reads and writes encrypted libraries either way.
    public static let sealsNewLibraries = false

    /// The presence feature saying a device reads and writes encrypted libraries.
    public static let sealingFeature = "sealed-1"

    // MARK: Keys

    /// The keys this device holds for an encrypted library, or `keyUnavailable` when it lacks the current one. Read
    /// again on every pass, so a key iCloud Keychain (or another device) brings is picked up at once.
    func loadSealing(_ manifest: SyncManifest) throws {
        manifestChecked = true
        guard manifest.isSealed, let description = manifest.sealing else {
            sealing = nil; waitingForKey = nil; waitingSealing = nil
            return
        }
        // Seen encrypted once, never published to in plaintext: remembered even before the key arrives.
        try rememberSealed(manifest.libraryID)
        var held: [Data: LibraryKey] = [:]
        if let keyStore {
            for key in (try? keyStore.keys(for: manifest.libraryID)) ?? [] where key.libraryID == manifest.libraryID { held[key.id] = key }
        }
        guard let currentID = SealedFormat.data(hex: description.current), let current = held[currentID] else {
            sealing = nil; waitingForKey = description.current; waitingSealing = description
            throw LibrarySyncError.keyUnavailable(description.current)
        }
        if sealing?.current.id != current.id { sealerVerified = [] }
        sealing = SealingState(libraryID: manifest.libraryID, manifest: description, keys: held, current: current)
        waitingForKey = nil; waitingSealing = nil
    }

    /// Before any pass has read the manifest (presence written when sync connects): reads it when it's downloaded, so a
    /// name or activity never goes out in plaintext into an encrypted library. False when it's still unknown.
    func checkManifestForPresence() -> Bool {
        if manifestChecked { return true }
        let url = remoteRoot.appendingPathComponent("daybook-sync.json")
        guard SyncFiles.itemState(url) == .local, let bytes = try? SyncFiles.read(url, below: remoteRoot, cloud: cloud),
              let manifest = try? SyncManifest.checked(SyncManifest.decode(bytes)) else { return false }
        try? loadSealing(manifest)
        return true
    }

    /// Records that this device synced an encrypted library in this sync folder (`SealingMemory`).
    func rememberSealed(_ libraryID: UUID) throws {
        var memory = SealingMemory.load(localRoot: localRoot)
        let key = SealingMemory.key(remoteRoot: remoteRoot)
        guard memory.remotes[key]?.libraryID != libraryID else { return }
        memory.remotes[key] = SealingMemory.Remote(libraryID: libraryID, since: Date())
        try memory.save(localRoot: localRoot)
    }

    /// Whether this device has synced an encrypted library in this sync folder.
    nonisolated var syncedSealedLibraryHere: Bool {
        SealingMemory.load(localRoot: localRoot).remotes[SealingMemory.key(remoteRoot: remoteRoot)] != nil
    }

    /// Whether this device has synced an encrypted library in any sync folder: the iPhone keeps that library's
    /// conversations out of backups (the sealed journal is their backup). Readable before any engine exists.
    public static func hasSyncedEncryptedLibrary(localRoot: URL) -> Bool {
        !SealingMemory.load(localRoot: localRoot.standardizedFileURL).remotes.isEmpty
    }

    /// Forgets that this sync folder held an encrypted library: the person chose to sync with another iCloud account,
    /// whose library may well be plaintext.
    public static func forgetSealedLibrary(localRoot: URL, remoteRoot: URL) {
        let root = localRoot.standardizedFileURL
        var memory = SealingMemory.load(localRoot: root)
        guard memory.remotes.removeValue(forKey: SealingMemory.key(remoteRoot: remoteRoot)) != nil else { return }
        try? memory.save(localRoot: root)
    }

    // MARK: Listing

    /// The journal folders for `kind` a pass reads: in an encrypted library the sealed one first, then the plaintext one
    /// from before (missing once retired); in a plaintext library just the plaintext one, as always.
    func journalEntries(_ kind: SealedKind) throws -> [JournalEntry] {
        let legacy = kind == .event ? "Events" : "Metadata"
        var entries: [JournalEntry] = []
        if sealing != nil || waitingForKey != nil, let directory = kind.directory {
            entries += try sealedListing(in: directory).map { url in
                JournalEntry(url: url, path: "\(directory)/\(url.lastPathComponent)", directory: directory, name: url.lastPathComponent, isSealed: true)
            }
            guard fm.fileExists(atPath: remoteRoot.appendingPathComponent(legacy, isDirectory: true).path) else { return entries }
        }
        entries += try journalListing(in: legacy).map { url in
            JournalEntry(url: url, path: "\(legacy)/\(url.lastPathComponent)", directory: legacy, name: url.deletingPathExtension().lastPathComponent, isSealed: false)
        }
        return entries
    }

    /// A sealed folder's entries (downloaded, evicted, or placeholders) and courier deliveries iCloud Drive hasn't
    /// brought yet, as sync-folder URLs. A missing folder is empty.
    func sealedListing(in directory: String) throws -> [URL] {
        let folder = remoteRoot.appendingPathComponent(directory, isDirectory: true)
        try SyncFiles.noSymlinks(folder, below: remoteRoot)
        var names = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            if SyncFiles.isHash(name) { names.insert(name) }
            else if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let logical = String(name.dropFirst().dropLast(7))
                if SyncFiles.isHash(logical) { names.insert(logical) }
            }
        }
        names.formUnion(inboxNames(directory).filter(SyncFiles.isHash))
        return names.sorted().map { folder.appendingPathComponent($0) }
    }

    /// The listing `hasRemoteChanges` compares: every journal file's path.
    func listingPaths() throws -> Set<String> {
        Set(try journalEntries(.event).map(\.path) + journalEntries(.metadata).map(\.path))
    }

    // MARK: Reading

    /// The entry's ID and its plaintext record. A plaintext entry's bytes must match its name; a sealed one must open
    /// (this library, a key held here, its name) and its ID is the SHA-256 of what it holds.
    func readEntry(_ entry: JournalEntry, kind: SealedKind) throws -> (id: String, bytes: Data) {
        guard entry.isSealed else {
            let bytes = try readJournal(entry.url, in: entry.directory)
            let expected = entry.name
            guard SyncFiles.isHash(expected) else { throw LibrarySyncError.invalidEvent(entry.url.lastPathComponent) }
            guard SyncDigest.sha256(data: bytes) == expected else { throw SyncHashMismatch(name: entry.url.lastPathComponent) }
            return (expected, bytes)
        }
        guard let sealing else { throw SyncKeyPending(keyID: waitingForKey ?? "") }
        let (plaintext, key) = try readSealed(entry, kind: kind, sealing: sealing)
        let id = SyncDigest.sha256(data: plaintext)
        sealedNames[entry.path] = id
        sealedKeys[entry.path] = key.id
        return (id, plaintext)
    }

    /// Reads and opens a sealed entry from the sync folder, or from a courier delivery while the sync folder's copy
    /// isn't downloaded (or doesn't open).
    func readSealed(_ entry: JournalEntry, kind: SealedKind, sealing: SealingState) throws -> (Data, LibraryKey) {
        func open(_ bytes: Data) throws -> (Data, LibraryKey) {
            do {
                let opened = try SealedObject.open(bytes, kind: kind, libraryID: sealing.libraryID, keyring: sealing.keyring, expectedName: entry.name)
                return (opened.plaintext, opened.key)
            } catch let error as SealedObjectError {
                // A library this one started over from: its files go (LibrarySyncStartOver.swift).
                if error == .wrongLibrary, let header = SealedObject.header(of: bytes), sealing.replaces(header.libraryID) { throw SyncReplacedFile() }
                throw Self.syncError(error, name: entry.path)
            }
        }
        guard let delivered = inboxCopy(entry.path) else {
            return try open(try SyncFiles.read(entry.url, below: remoteRoot, cloud: cloud))
        }
        switch SyncFiles.itemState(entry.url) {
        case .local:
            if let bytes = try? SyncFiles.read(entry.url, below: remoteRoot, cloud: cloud), let opened = try? open(bytes) { return opened }
        case .inCloud:
            try? cloud.requestDownload(entry.url)
        case .absent:
            break
        }
        let bytes = try SyncFiles.coordinateRead(delivered, below: inboxBase) { try Data(contentsOf: $0) }
        do { return try open(bytes) } catch let error as SyncKeyPending { throw error } catch {
            // A delivery damaged after it was stored is discarded; iCloud Drive's copy takes over.
            discardDelivery(delivered)
            throw SyncPendingDownload()
        }
    }

    /// How a sealed object that doesn't open counts for a pass: a newer format or a foreign object is unreadable for
    /// good; a key not here yet is waited for; anything else (damage, a file still settling) is read again next pass.
    static func syncError(_ error: SealedObjectError, name: String) -> Error {
        switch error {
        case .unsupportedVersion(let version): return LibrarySyncError.unsupportedVersion(version)
        case .wrongKind, .wrongLibrary: return LibrarySyncError.invalidEvent(name)
        case .unknownKey(let id): return SyncKeyPending(keyID: id)
        case .malformed, .nameMismatch, .authenticationFailed, .digestMismatch: return SyncHashMismatch(name: name)
        }
    }

    /// Where an event's sealed file is, to read its snapshot again: where it was read (if that's still there), else its
    /// name under the current key, else under another key held here. Nil: only the plaintext one from before.
    func sealedLocation(of id: String, sealing: SealingState) -> URL? {
        if let known = journalLocations[id], SyncFiles.itemState(known) != .absent || inboxCopy("Sealed/Events/\(known.lastPathComponent)") != nil {
            return known
        }
        for key in sealing.readingOrder {
            guard let name = key.objectName(.event, plaintextSHA256: id) else { continue }
            let url = remoteRoot.appendingPathComponent("Sealed/Events/\(name)")
            if SyncFiles.itemState(url) != .absent || inboxCopy("Sealed/Events/\(name)") != nil { journalLocations[id] = url; return url }
        }
        return nil
    }

    // MARK: Writing

    /// Writes a journal record sealed under the current key (the same bytes again for the same record), and reports it
    /// for the courier. Returns its path.
    @discardableResult
    func writeSealed(_ plaintext: Data, id: String, kind: SealedKind, key: LibraryKey) throws -> String {
        try Task.checkCancellation()
        guard let directory = kind.directory else { throw LibrarySyncError.invalidEvent(id) }
        let sealed = SealedObject.seal(plaintext, kind: kind, key: key)
        let path = "\(directory)/\(sealed.name)"
        let url = remoteRoot.appendingPathComponent(path)
        let folder = url.deletingLastPathComponent()
        try SyncFiles.noSymlinks(folder, below: remoteRoot)
        try LocalFiles.directory(folder)
        try SyncFiles.coordinateWrite(url, below: remoteRoot) { target in
            if self.fm.fileExists(atPath: target.path) {
                guard try Data(contentsOf: target) == sealed.bytes else { throw LibrarySyncError.invalidEvent(path) }
            } else { try LocalFiles.atomicWrite(sealed.bytes, to: target) }
        }
        ownJournalWrites.insert(path)
        courierWrites[path] = SyncJournalFile(path: path, sha256: SyncDigest.sha256(data: sealed.bytes), size: Int64(sealed.bytes.count))
        sealedNames[path] = id
        sealedKeys[path] = key.id
        if kind == .event { journalLocations[id] = url }
        return path
    }

    // MARK: Objects

    /// Where the object with plaintext SHA-256 `sha256` is: sealed under a key this device holds, else the plaintext one
    /// from before, whichever is there (downloaded or not). With neither, where this replica would write it.
    func remoteObject(_ sha256: String) -> RemoteObject {
        guard let sealing else { return .legacy(blobURL(sha256)) }
        var candidates: [RemoteObject] = []
        for key in sealing.readingOrder {
            guard let name = key.objectName(.blob, plaintextSHA256: sha256) else { continue }
            candidates.append(.sealed(remoteRoot.appendingPathComponent("Sealed/Blobs/\(name)"), name: name, key: key))
        }
        candidates.append(.legacy(blobURL(sha256)))
        return candidates.first { SyncFiles.itemState($0.url) != .absent } ?? candidates[0]
    }

    /// Whether the sync folder has the object.
    func hasRemoteObject(_ sha256: String) -> Bool { SyncFiles.itemState(remoteObject(sha256).url) != .absent }

    /// Whether an on-demand replica may publish an object it doesn't hold by reference: one the journal names or the sync
    /// folder holds, as always. An encrypted library retires objects only live conversations no longer use, so there the
    /// object itself must be in the sync folder; one the journal names that isn't there (yet) waits, as does any for two
    /// weeks after the library started over, while devices publish their libraries again.
    func mayPublishByReference(_ sha256: String, journalAssets: Set<String>) throws -> Bool {
        guard let sealing else { return journalAssets.contains(sha256) || hasRemoteObject(sha256) }
        if hasRemoteObject(sha256) { return true }
        if journalAssets.contains(sha256) { throw SyncPendingDownload() }
        // A library that started over lately: another device may yet publish this recording again.
        if sealing.manifest.replaces != nil, sealerClock().timeIntervalSince(sealing.manifest.sealedSince) < Self.keyHolderAbsence {
            throw SyncPendingDownload()
        }
        return false
    }

    /// The files written since a pass last returned, for the courier. In an encrypted library, only sealed ones: a
    /// plaintext file left by a pass that stopped before the library was encrypted never goes out now.
    func takeCourierWrites() -> [SyncJournalFile] {
        let written = courierWrites.values.filter { sealing == nil || $0.isSealed }.sorted { $0.path < $1.path }
        courierWrites = [:]
        return written
    }

    /// A courier delivery of the object, sealed under a held key or plaintext, while the sync folder's copy isn't
    /// downloaded. Asks iCloud for the sync folder's copy, so the delivery can be pruned once it's there.
    func courierObject(_ sha256: String) -> (delivery: URL, object: RemoteObject)? {
        var candidates: [RemoteObject] = []
        if let sealing {
            for key in sealing.readingOrder {
                guard let name = key.objectName(.blob, plaintextSHA256: sha256) else { continue }
                candidates.append(.sealed(remoteRoot.appendingPathComponent("Sealed/Blobs/\(name)"), name: name, key: key))
            }
        }
        candidates.append(.legacy(blobURL(sha256)))
        for object in candidates {
            let path: String
            switch object {
            case .legacy: path = "Blobs/\(sha256)"
            case .sealed(_, let name, _): path = "Sealed/Blobs/\(name)"
            }
            guard let delivered = inboxCopy(path) else { continue }
            switch SyncFiles.itemState(object.url) {
            case .local: return nil
            case .inCloud: try? cloud.requestDownload(object.url); return (delivered, object)
            case .absent: return (delivered, object)
            }
        }
        return nil
    }

    /// Copies an object into `temporary` as plaintext, returning the plaintext's SHA-256 ("" when a sealed object doesn't
    /// open: damaged, or not this object). A sealed object whose key isn't here throws `SyncKeyPending`.
    nonisolated func copyPlaintext(_ source: URL, of object: RemoteObject, below root: URL, libraryID: UUID?, to temporary: URL,
                                   expected: String, progress: ((Int64, Int64) -> Void)? = nil) throws -> String {
        switch object {
        case .legacy:
            try SyncFiles.coordinateRead(source, below: root) { try FileManager.default.copyItem(at: $0, to: temporary) }
            return try SyncDigest.sha256(fileURL: temporary)
        case .sealed(_, let name, let key):
            do {
                return try SyncFiles.coordinateRead(source, below: root) {
                    try SealedObject.openFile($0, to: temporary, kind: .blob, libraryID: libraryID ?? key.libraryID,
                                              keyring: { $0 == key.id ? key : nil }, expectedName: name, expectedSHA256: expected,
                                              progress: progress).plaintextSHA256
                }
            } catch let error as SealedObjectError {
                if case .unknownKey(let id) = error { throw SyncKeyPending(keyID: id) }
                return ""
            }
        }
    }

    /// Whether an object in the sync folder holds the plaintext with SHA-256 `digest` (opened through, when sealed).
    func objectHolds(_ object: RemoteObject, digest: String) throws -> Bool {
        switch object {
        case .legacy(let url):
            return try SyncFiles.coordinateRead(url, below: remoteRoot) { try SyncDigest.sha256(fileURL: $0) == digest }
        case .sealed(let url, let name, let key):
            return try SyncFiles.coordinateRead(url, below: remoteRoot) { source in
                (try? SealedObject.openFile(source, to: nil, kind: .blob, libraryID: key.libraryID, keyring: { $0 == key.id ? key : nil },
                                            expectedName: name, expectedSHA256: digest)) != nil
            }
        }
    }

    /// Seals a local original into `Sealed/Blobs/` under the current key: the encrypted library's `upload`.
    func uploadSealed(_ asset: SyncAsset, from source: URL, sealing: SealingState) throws {
        let key = sealing.current
        guard let name = key.objectName(.blob, plaintextSHA256: asset.sha256) else { throw LibrarySyncError.invalidBlob(asset.sha256) }
        let path = "Sealed/Blobs/\(name)"
        let target = remoteRoot.appendingPathComponent(path)
        let object = RemoteObject.sealed(target, name: name, key: key)
        // Never download an object just to re-verify it: on a phone that would fetch every recording.
        if audioPolicy == .onDemand, SyncFiles.itemState(target) == .inCloud { return }
        if fm.fileExists(atPath: target.path) {
            try SyncFiles.available(target, cloud: cloud)
            if let stamp = try? assetStamp(target, digest: asset.sha256), verifiedAssets[target.path] == stamp { return }
            guard try objectHolds(object, digest: asset.sha256) else { throw LibrarySyncError.invalidBlob(asset.sha256) }
            verifiedAssets[target.path] = try assetStamp(target, digest: asset.sha256)
            sealerVerified.insert(path)
            return
        }
        // A courier brought this object from the device that recorded it, and that device uploads it.
        if inboxCopy(path) != nil { return }
        let folder = target.deletingLastPathComponent()
        try SyncFiles.noSymlinks(folder, below: remoteRoot)
        try LocalFiles.directory(folder)
        var written: SealedFile?
        try SyncFiles.coordinateWrite(target, below: remoteRoot) { url in
            if self.fm.fileExists(atPath: url.path) {
                guard try self.objectHolds(object, digest: asset.sha256) else { throw LibrarySyncError.invalidBlob(asset.sha256) }
                return
            }
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".upload-\(UUID().uuidString)")
            defer { try? self.fm.removeItem(at: temporary) }
            let size = ((try? self.fm.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.int64Value ?? .max
            do {
                // The courier carries files up to 50 MB; only those need the sealed bytes' SHA-256.
                written = try SealedObject.sealFile(source, to: temporary, kind: .blob, key: key, plaintextSHA256: asset.sha256,
                                                    sealedDigest: size <= Self.courierHashLimit)
            } catch is SealedObjectError { throw LibrarySyncError.missingLocalAudio(asset.relativePath) }
            try self.fm.moveItem(at: temporary, to: url)
        }
        verifiedAssets[target.path] = try? assetStamp(target, digest: asset.sha256)
        if let written, let digest = written.sealedSHA256 { courierWrites[path] = SyncJournalFile(path: path, sha256: digest, size: written.size) }
    }

    /// Sealed objects up to this size are hashed as they're written, for the courier (which carries up to 50 MB).
    static let courierHashLimit: Int64 = 64 << 20
}
