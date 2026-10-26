import DaybookKit
import Foundation

/// The one place model files live (docs/models.md, "Storage"):
///
///     Models/<engine>/<family>/<variant>/<revision>/   an installed revision: one folder per artifact
///                                                      ("model", "tokenizer") and receipt.json
///     Models/.partial/…                                downloads in progress; they resume
///     Models/.staging/…                                installs being assembled, then renamed into place
///     Models/.store.json                               pinned revisions
///
/// A revision counts as installed only once every file matched its size and digest and the engine
/// accepted it; it then appears by one atomic rename, so a selection can never see half an install.
/// Revisions of one variant sit side by side, which is how updates install without disturbing the
/// revision a queued or running job froze. Garbage collection never removes a selected, in-use,
/// or pinned revision.
public actor ModelStore {
    public let root: URL
    private var leases: [UUID: Set<ModelInstallKey>] = [:]
    private var installing: Set<ModelInstallKey> = []
    let files = FileManager.default

    public init(root: URL) { self.root = root }

    // MARK: Layout

    nonisolated func directory(for key: ModelInstallKey) -> URL {
        key.pathComponents.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    nonisolated func partialDirectory(for key: ModelInstallKey) -> URL {
        key.pathComponents.reduce(root.appendingPathComponent(".partial", isDirectory: true)) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    nonisolated var stagingRoot: URL { root.appendingPathComponent(".staging", isDirectory: true) }
    nonisolated var stateURL: URL { root.appendingPathComponent(".store.json") }

    // MARK: Inventory

    /// Every installed revision, checked by file size (fast); digests were checked when it was installed.
    public func inventory() -> ModelInventory {
        var found: [InstalledModelRevision] = []
        for engine in subdirectories(of: root) {
            for family in subdirectories(of: engine) {
                for variant in subdirectories(of: family) {
                    for revision in subdirectories(of: variant) {
                        let key = ModelInstallKey(engine: engine.lastPathComponent, family: family.lastPathComponent,
                                                  variant: variant.lastPathComponent, revision: revision.lastPathComponent)
                        if let installed = read(key) { found.append(installed) }
                    }
                }
            }
        }
        return ModelInventory(revisions: found)
    }

    /// One revision, if it's on disk.
    public func revision(_ key: ModelInstallKey) -> InstalledModelRevision? { read(key) }

    func read(_ key: ModelInstallKey) -> InstalledModelRevision? {
        let folder = directory(for: key)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ModelInstallReceipt.fileName)),
              let receipt = try? JSONDecoder.receipts.decode(ModelInstallReceipt.self, from: data),
              receipt.key == key else { return nil }
        let installation = ModelInstallation(receipt: receipt, directory: folder)
        for artifact in receipt.artifacts {
            for file in artifact.files {
                do { try ModelFileDigest.verify(installation.url(for: file, in: artifact.name), against: file, checkContent: false) }
                catch { return InstalledModelRevision(installation: installation, state: .damaged("\(artifact.name)/\(file.path)")) }
            }
        }
        return InstalledModelRevision(installation: installation, state: .ready)
    }

    // MARK: Installing

    /// Downloads `revision` beside any other revision of the variant, verifies every file, lets
    /// `validate` (the engine) inspect the assembled install, and renames it into place. Progress
    /// reports a fraction and a message. Cancelling keeps the partial download for next time.
    @discardableResult
    public func install(_ model: CatalogModel, revision: ModelRevisionEntry, fetcher: any ModelArtifactFetcher,
                        validate: @Sendable (ModelInstallation) async throws -> Void = { _ in },
                        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> InstalledModelRevision {
        let key = ModelInstallKey(model: model, revision: revision)
        if let existing = read(key), existing.isReady {
            progress(1, "Already downloaded")
            return existing
        }
        guard installing.insert(key).inserted else { throw ModelStoreError.busy(model.name) }
        defer { installing.remove(key) }

        let partial = partialDirectory(for: key)
        try makeDirectory(partial)
        let total = Double(max(1, revision.totalBytes))
        var completed: Int64 = 0
        var sources: [String: URL] = [:]
        progress(0, "Downloading \(model.name)")
        for artifact in revision.artifacts {
            let bytes = artifact.files.reduce(Int64(0)) { $0 + $1.size }
            let message = artifact.name == "tokenizer" ? "Downloading tokenizer" : "Downloading \(model.name)"
            let base = Double(completed)
            sources[artifact.name] = try await fetcher.fetch(artifact, into: partial.appendingPathComponent(artifact.name, isDirectory: true)) { fraction in
                progress((base + min(1, max(0, fraction)) * Double(bytes)) / total * 0.97, message)
            }
            try Task.checkCancellation()
            completed += bytes
        }

        progress(0.97, "Checking \(model.name)")
        for artifact in revision.artifacts {
            for file in artifact.files {
                try Task.checkCancellation()
                let url = sources[artifact.name]!.appendingPathComponent(file.path)
                do { try ModelFileDigest.verify(url, against: file) }
                catch ModelFileDigest.Failure.noDigest {
                    try? files.removeItem(at: url)
                    throw ModelStoreError.unverifiable(model: model.name, file: file.path)
                } catch {
                    // Removed, so the next attempt downloads this file again instead of trusting it.
                    try? files.removeItem(at: url)
                    throw ModelStoreError.verificationFailed(model: model.name, file: file.path)
                }
            }
        }

        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            for artifact in revision.artifacts {
                for file in artifact.files {
                    let destination = staging.appendingPathComponent(artifact.name, isDirectory: true).appendingPathComponent(file.path)
                    try makeDirectory(destination.deletingLastPathComponent())
                    try files.moveItem(at: sources[artifact.name]!.appendingPathComponent(file.path), to: destination)
                }
            }
            let receipt = ModelInstallReceipt(model: model, revision: revision)
            try JSONEncoder.receipts.encode(receipt).write(to: staging.appendingPathComponent(ModelInstallReceipt.fileName), options: .atomic)
            try await validate(ModelInstallation(receipt: receipt, directory: staging))
            try place(staging, at: key)
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
        try? files.removeItem(at: partial)
        pruneEmptyParents(of: partial, upTo: root.appendingPathComponent(".partial", isDirectory: true))
        progress(1, "\(model.name) is ready for offline use")
        guard let installed = read(key) else { throw ModelStoreError.notInstalled(model.name) }
        return installed
    }

    /// The atomic step: an assembled folder becomes the revision.
    func place(_ assembled: URL, at key: ModelInstallKey) throws {
        let target = directory(for: key)
        try makeDirectory(target.deletingLastPathComponent())
        if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
        try files.moveItem(at: assembled, to: target)
    }

    // MARK: Removing

    /// Removes every revision of a variant and any partial download of it.
    @discardableResult
    public func remove(variantKey: String) throws -> [ModelInstallKey] {
        let keys = inventory().revisions(of: variantKey).map(\.key)
        if let busy = keys.first(where: leasedKeys.contains) { throw ModelStoreError.inUse(busy.variantKey) }
        for key in keys { try remove(key) }
        let partials = root.appendingPathComponent(".partial", isDirectory: true)
        for engine in subdirectories(of: partials) {
            let parts = variantKey.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let folder = engine.appendingPathComponent(parts[0], isDirectory: true).appendingPathComponent(parts[1], isDirectory: true)
            if files.fileExists(atPath: folder.path) {
                try files.removeItem(at: folder)
                pruneEmptyParents(of: folder, upTo: partials)
            }
        }
        return keys
    }

    /// Removes one revision.
    public func remove(_ key: ModelInstallKey) throws {
        guard !leasedKeys.contains(key) else { throw ModelStoreError.inUse(key.variantKey) }
        let folder = directory(for: key)
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
        pruneEmptyParents(of: folder, upTo: root)
        if pinned.contains(key) { setPinned(key, false) }
    }

    // MARK: Pins and leases

    /// Pinned revisions are kept by garbage collection until unpinned or removed.
    public var pinned: Set<ModelInstallKey> { Set(storeState().pinned) }

    public func setPinned(_ key: ModelInstallKey, _ isPinned: Bool) {
        var state = storeState()
        state.pinned.removeAll { $0 == key }
        if isPinned { state.pinned.append(key) }
        try? makeDirectory(root)
        try? JSONEncoder.receipts.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Marks revisions as in use (a running job, a loaded model) until the lease ends.
    public func lease(_ keys: Set<ModelInstallKey>) -> UUID {
        let id = UUID()
        leases[id] = keys
        return id
    }

    public func endLease(_ id: UUID) { leases[id] = nil }

    public var leasedKeys: Set<ModelInstallKey> { leases.values.reduce(into: Set()) { $0.formUnion($1) } }

    // MARK: Garbage collection

    /// Removes revisions that newer ready revisions of the same variant have replaced, except those
    /// `protecting` names (selected or queued), pinned ones, and leased ones. A variant's newest
    /// ready revision is always kept, and nothing is removed from a variant with no ready revision.
    @discardableResult
    public func collectGarbage(protecting: Set<ModelInstallKey>) -> [ModelInstallKey] {
        let inventory = inventory()
        let kept = protecting.union(pinned).union(leasedKeys)
        var removed: [ModelInstallKey] = []
        for variantKey in Set(inventory.revisions.map(\.key.variantKey)) {
            let revisions = inventory.revisions(of: variantKey)
            guard let newest = revisions.first(where: \.isReady)?.key else { continue }
            for revision in revisions where revision.key != newest && !kept.contains(revision.key) {
                if (try? remove(revision.key)) != nil { removed.append(revision.key) }
            }
        }
        return removed
    }

    // MARK: Disk use

    public func diskUsage() -> ModelDiskUsage {
        var installed: [ModelInstallKey: Int64] = [:]
        for revision in inventory().revisions { installed[revision.key] = size(of: revision.installation.directory) }
        var partial: [String: Int64] = [:]
        for engine in subdirectories(of: root.appendingPathComponent(".partial", isDirectory: true)) {
            for family in subdirectories(of: engine) {
                for variant in subdirectories(of: family) {
                    partial["\(family.lastPathComponent)/\(variant.lastPathComponent)", default: 0] += size(of: variant)
                }
            }
        }
        var legacy: [String: Int64] = [:]
        for folder in legacyFolders() { legacy[folder.lastPathComponent] = size(of: folder) }
        return ModelDiskUsage(installed: installed, partial: partial, legacy: legacy)
    }

    /// Clears install folders a crash left half assembled. Call when no install is running.
    public func removeStaleStaging() {
        for folder in subdirectories(of: stagingRoot) where !folder.lastPathComponent.hasPrefix(Self.migrationPrefix) {
            try? files.removeItem(at: folder)
        }
    }

    // MARK: Helpers

    struct StoreState: Codable { var pinned: [ModelInstallKey] = [] }

    func storeState() -> StoreState {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder.receipts.decode(StoreState.self, from: $0) } ?? StoreState()
    }

    /// Visible subdirectories only: `.partial`, `.staging`, and HubApi's `.cache` are skipped.
    func subdirectories(of url: URL) -> [URL] {
        guard let items = try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func makeDirectory(_ url: URL) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func size(of url: URL) -> Int64 {
        guard let enumerator = files.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Removes empty folders from `url` up to (not including) `limit`.
    func pruneEmptyParents(of url: URL, upTo limit: URL) {
        var current = url.deletingLastPathComponent().standardizedFileURL
        let stop = limit.standardizedFileURL.path
        while current.path.hasPrefix(stop), current.path != stop,
              let contents = try? files.contentsOfDirectory(atPath: current.path), contents.isEmpty {
            try? files.removeItem(at: current)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }
}

extension JSONEncoder {
    /// Receipts and store state: readable, stable, with millisecond timestamps so installs made in
    /// the same second still order.
    static var receipts: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ReceiptDates.formatter.string(from: date))
        }
        return encoder
    }
}

extension JSONDecoder {
    static var receipts: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ReceiptDates.formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return decoder
    }
}

enum ReceiptDates {
    static var formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
