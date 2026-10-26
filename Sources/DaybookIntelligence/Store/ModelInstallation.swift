import DaybookCore
import DaybookKit
import Foundation

/// Where one revision lives: `Models/<engine>/<family>/<variant>/<revision>/`.
public struct ModelInstallKey: Codable, Hashable, Sendable, CustomStringConvertible {
    public var engine: String
    public var family: String
    public var variant: String
    public var revision: String

    public init(engine: String, family: String, variant: String, revision: String) {
        self.engine = engine; self.family = family; self.variant = variant; self.revision = revision
    }

    public init(model: CatalogModel, revision: ModelRevisionEntry) {
        self.init(engine: model.engine.rawValue, family: model.familyID, variant: model.variant.id, revision: revision.id)
    }

    /// "whisper/base"
    public var variantKey: String { "\(family)/\(variant)" }
    public var description: String { "\(engine)/\(family)/\(variant)/\(revision)" }
    var pathComponents: [String] { [engine, family, variant, revision] }
}

/// Written into each installed revision once every file is verified. It describes the install by
/// itself, so a revision stays loadable and explainable even if a later catalog drops its entry.
public struct ModelInstallReceipt: Codable, Equatable, Sendable {
    public static let fileName = "receipt.json"
    public var formatVersion: Int
    public var key: ModelInstallKey
    public var name: String
    public var releaseDate: String?
    public var artifacts: [ModelArtifact]
    public var capabilities: ModelCapabilities
    public var engineOptions: [String: String]
    public var installedAt: Date
    /// The legacy folder this install was moved from, if it was migrated rather than downloaded.
    public var migratedFrom: String?

    public init(model: CatalogModel, revision: ModelRevisionEntry, installedAt: Date = Date(), migratedFrom: String? = nil) {
        formatVersion = 1
        key = ModelInstallKey(model: model, revision: revision)
        name = model.name
        releaseDate = revision.releaseDate
        artifacts = revision.artifacts
        capabilities = model.capabilities
        engineOptions = model.engineOptions
        self.installedAt = installedAt
        self.migratedFrom = migratedFrom
    }

    public var totalBytes: Int64 { artifacts.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.size } } }
}

/// A verified revision on disk, as an engine loads it.
public struct ModelInstallation: Sendable {
    public let receipt: ModelInstallReceipt
    public let directory: URL

    public init(receipt: ModelInstallReceipt, directory: URL) { self.receipt = receipt; self.directory = directory }

    public var key: ModelInstallKey { receipt.key }
    public var capabilities: ModelCapabilities { receipt.capabilities }
    public var engineOptions: [String: String] { receipt.engineOptions }

    public func artifact(_ name: String) -> ModelArtifact? { receipt.artifacts.first { $0.name == name } }

    /// The folder an engine loads an artifact from: `<revision>/<artifact>/<root>`.
    public func folder(for artifact: String) -> URL {
        let base = directory.appendingPathComponent(artifact, isDirectory: true)
        guard let root = self.artifact(artifact)?.root, !root.isEmpty else { return base }
        return base.appendingPathComponent(root, isDirectory: true)
    }

    /// Where one of an artifact's files is.
    public func url(for file: ModelFile, in artifact: String) -> URL {
        directory.appendingPathComponent(artifact, isDirectory: true).appendingPathComponent(file.path)
    }

    /// What provenance records for results this install produces.
    public func provenance(engine: ModelEngineDescriptor) -> ModelProvenance {
        ModelProvenance(family: key.family, variant: key.variant, revision: key.revision, engine: key.engine,
                        engineVersion: engine.versionString, name: receipt.name, repository: receipt.artifacts.first?.repository)
    }
}

/// One revision found on disk.
public struct InstalledModelRevision: Sendable {
    public enum State: Equatable, Sendable {
        case ready
        /// Files are missing or changed size since the install was verified.
        case damaged(String)
    }
    public let installation: ModelInstallation
    public let state: State
    public var key: ModelInstallKey { installation.key }
    public var bytes: Int64 { installation.receipt.totalBytes }
    public var isReady: Bool { state == .ready }
}

/// What the store holds: every installed revision, newest first within each variant.
public struct ModelInventory: Sendable {
    public var revisions: [InstalledModelRevision]

    public init(revisions: [InstalledModelRevision]) {
        self.revisions = revisions.sorted { ModelInventory.isNewer($0.installation.receipt, than: $1.installation.receipt) }
    }

    /// Release date first, then install time: a re-downloaded old revision doesn't outrank a newer one.
    static func isNewer(_ left: ModelInstallReceipt, than right: ModelInstallReceipt) -> Bool {
        let a = left.releaseDate ?? "", b = right.releaseDate ?? ""
        return a == b ? left.installedAt > right.installedAt : a > b
    }

    /// The revision a selection of `variantKey` resolves to: the newest ready one, or exactly
    /// `revision` when a job froze it.
    public func resolve(_ variantKey: String, revision: String? = nil) -> InstalledModelRevision? {
        revisions.first { $0.key.variantKey == variantKey && $0.isReady && (revision == nil || $0.key.revision == revision) }
    }

    /// Variant keys with a ready revision.
    public var usableVariantKeys: Set<String> { Set(revisions.filter(\.isReady).map(\.key.variantKey)) }

    /// Variant key → the revision a new job would freeze.
    public var resolvedRevisions: [String: String] {
        var result: [String: String] = [:]
        for revision in revisions where revision.isReady && result[revision.key.variantKey] == nil {
            result[revision.key.variantKey] = revision.key.revision
        }
        return result
    }

    public func revisions(of variantKey: String) -> [InstalledModelRevision] { revisions.filter { $0.key.variantKey == variantKey } }
}

/// Disk use, for the model manager.
public struct ModelDiskUsage: Sendable, Equatable {
    /// Installed revisions.
    public var installed: [ModelInstallKey: Int64]
    /// Unfinished downloads that can resume, by variant key.
    public var partial: [String: Int64]
    /// Folders from before the model system that couldn't be migrated, by folder name.
    public var legacy: [String: Int64]

    public var total: Int64 { installed.values.reduce(0, +) + partial.values.reduce(0, +) + legacy.values.reduce(0, +) }

    /// Everything one variant takes: its revisions and any partial download.
    public func bytes(for variantKey: String) -> Int64 {
        installed.filter { $0.key.variantKey == variantKey }.values.reduce(0, +) + (partial[variantKey] ?? 0)
    }
}

public enum ModelStoreError: LocalizedError, Equatable {
    case verificationFailed(model: String, file: String)
    /// The manifest gives no checksum for a file, so it can't be checked and isn't installed.
    case unverifiable(model: String, file: String)
    case inUse(String)
    case busy(String)
    case notInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let model, let file):
            return "\(model) didn’t download correctly (\(file) didn’t match). Try downloading it again."
        case .unverifiable(let model, let file):
            return "\(model) can’t be checked: Hugging Face lists no checksum for \(file), so it wasn’t installed."
        case .inUse(let model): return "\(model) is in use. Try again when processing finishes."
        case .busy(let model): return "\(model) is already downloading."
        case .notInstalled(let model): return "\(model) isn’t downloaded."
        }
    }
}
