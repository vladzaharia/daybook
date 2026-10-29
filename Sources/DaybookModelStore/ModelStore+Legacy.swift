import DaybookKit
import Foundation

/// What moving installs from before the model system did.
public struct ModelMigrationReport: Equatable, Sendable {
    /// Legacy ID → the revision it became.
    public var migrated: [String: ModelInstallKey] = [:]
    /// Legacy folders whose revision was already installed; the duplicate folder was removed.
    public var alreadyInstalled: [String] = []
    /// Legacy ID → why it stayed where it was (a file didn't match). The model needs downloading again.
    public var failed: [String: String] = [:]
    /// Folders without a complete-install marker (an unfinished download), left untouched.
    public var incomplete: [String] = []

    public var isEmpty: Bool { migrated.isEmpty && alreadyInstalled.isEmpty && failed.isEmpty && incomplete.isEmpty }

    public init(migrated: [String: ModelInstallKey] = [:], alreadyInstalled: [String] = [], failed: [String: String] = [:],
                incomplete: [String] = []) {
        self.migrated = migrated; self.alreadyInstalled = alreadyInstalled; self.failed = failed; self.incomplete = incomplete
    }
}

/// Migration of `Models/<legacy ID>/` folders (the layout before docs/models.md) into
/// `Models/<engine>/<family>/<variant>/<revision>/`, without downloading anything:
///
/// 1. The legacy folder's marker must name the legacy ID and the revision the manifest's migration
///    table maps it to.
/// 2. Every file the manifest lists is verified where it is (size and digest). If one fails, nothing
///    moves and the report says why.
/// 3. The folder is renamed into `.staging/migrate-<ID>/legacy` (one atomic step), its files are
///    moved into the installed layout beside it, a receipt is written, the engine checks it, and the
///    result is renamed into place. Leftovers (HubApi's caches, files the model never read) go.
///
/// Every step is idempotent: a migration interrupted at any point resumes from `.staging` on the
/// next launch, and a folder whose revision is already installed is simply removed.
extension ModelStore {
    static let migrationPrefix = "migrate-"

    /// The marker the pre-model-system runtime wrote once a download completed.
    struct LegacyMarker: Decodable {
        let modelID: String
        let revision: String
        let files: [String: Int64]
    }

    public func migrateLegacyInstalls(catalog: ModelCatalog,
                                      validate: @Sendable (ModelInstallation) async throws -> Void = { _ in }) async -> ModelMigrationReport {
        var report = ModelMigrationReport()
        // Finish migrations a previous launch started.
        for work in subdirectories(of: stagingRoot) where work.lastPathComponent.hasPrefix(Self.migrationPrefix) {
            let legacyID = String(work.lastPathComponent.dropFirst(Self.migrationPrefix.count))
            guard let (model, revision) = catalog.legacyRevision(for: legacyID) else { continue }
            do { report.migrated[legacyID] = try await finishMigration(legacyID, model: model, revision: revision, work: work,
                                                                       contentVerified: false, validate: validate) }
            catch { report.failed[legacyID] = Self.describe(error) }
        }
        for model in catalog.models {
            for revision in model.variant.revisions {
                for legacyID in revision.legacy?.ids ?? [] where report.migrated[legacyID] == nil && report.failed[legacyID] == nil {
                    guard ManifestSafety.isSafeFolderName(legacyID) else { continue }
                    let folder = root.appendingPathComponent(legacyID, isDirectory: true)
                    guard files.fileExists(atPath: folder.path) else { continue }
                    guard let marker = legacyMarker(in: folder), marker.modelID == legacyID, !marker.files.isEmpty,
                          marker.revision == revision.artifacts.first?.revision else {
                        report.incomplete.append(legacyID); continue
                    }
                    let key = ModelInstallKey(model: model, revision: revision)
                    if read(key)?.isReady == true {
                        try? files.removeItem(at: folder)
                        report.alreadyInstalled.append(legacyID); continue
                    }
                    do {
                        try verifyInPlace(folder, revision: revision)
                        let work = stagingRoot.appendingPathComponent(Self.migrationPrefix + legacyID, isDirectory: true)
                        try makeDirectory(work)
                        try files.moveItem(at: folder, to: work.appendingPathComponent("legacy", isDirectory: true))
                        report.migrated[legacyID] = try await finishMigration(legacyID, model: model, revision: revision, work: work,
                                                                              contentVerified: true, validate: validate)
                    } catch { report.failed[legacyID] = Self.describe(error) }
                }
            }
        }
        if (try? files.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty == true { try? files.removeItem(at: stagingRoot) }
        return report
    }

    /// Top-level folders from before the model system that are still here (unfinished downloads,
    /// failed migrations), for disk use and removal.
    func legacyFolders() -> [URL] {
        subdirectories(of: root).filter { files.fileExists(atPath: $0.appendingPathComponent("installed.json").path) || isLegacyPartial($0) }
    }

    /// Removes what `legacyFolders` reports. The model manager offers this as "Remove old downloads".
    @discardableResult
    public func removeLegacyLeftovers() -> [String] {
        legacyFolders().compactMap { folder in (try? files.removeItem(at: folder)) != nil ? folder.lastPathComponent : nil }
    }

    // MARK: Steps

    private func verifyInPlace(_ folder: URL, revision: ModelRevisionEntry) throws {
        for artifact in revision.artifacts {
            guard let base = revision.legacy?.artifactPaths[artifact.name] else { throw MigrationFailure.noLegacyPath(artifact.name) }
            for file in artifact.files {
                try Task.checkCancellation()
                do { try ModelFileDigest.verify(folder.appendingPathComponent(base, isDirectory: true).appendingPathComponent(file.path), against: file) }
                catch { throw MigrationFailure.mismatch("\(artifact.name)/\(file.path)") }
            }
        }
    }

    /// Moves `work/legacy`'s files into `work/new` in the installed layout, then installs `work/new`.
    private func finishMigration(_ legacyID: String, model: CatalogModel, revision: ModelRevisionEntry, work: URL,
                                 contentVerified: Bool, validate: @Sendable (ModelInstallation) async throws -> Void) async throws -> ModelInstallKey {
        let key = ModelInstallKey(model: model, revision: revision)
        if read(key)?.isReady == true { try? files.removeItem(at: work); return key }
        let legacy = work.appendingPathComponent("legacy", isDirectory: true)
        let assembled = work.appendingPathComponent("new", isDirectory: true)
        for artifact in revision.artifacts {
            guard let base = revision.legacy?.artifactPaths[artifact.name] else { throw MigrationFailure.noLegacyPath(artifact.name) }
            for file in artifact.files {
                let destination = assembled.appendingPathComponent(artifact.name, isDirectory: true).appendingPathComponent(file.path)
                if !files.fileExists(atPath: destination.path) {
                    let source = legacy.appendingPathComponent(base, isDirectory: true).appendingPathComponent(file.path)
                    guard files.fileExists(atPath: source.path) else { throw MigrationFailure.mismatch("\(artifact.name)/\(file.path)") }
                    try makeDirectory(destination.deletingLastPathComponent())
                    try files.moveItem(at: source, to: destination)
                }
                // A move can't change content; after an interrupted run, check content again.
                do { try ModelFileDigest.verify(destination, against: file, checkContent: !contentVerified) }
                catch { throw MigrationFailure.mismatch("\(artifact.name)/\(file.path)") }
            }
        }
        let receiptURL = assembled.appendingPathComponent(ModelInstallReceipt.fileName)
        let receipt = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder.receipts.decode(ModelInstallReceipt.self, from: $0) }
            ?? ModelInstallReceipt(model: model, revision: revision, migratedFrom: legacyID)
        try JSONEncoder.receipts.encode(receipt).write(to: receiptURL, options: .atomic)
        try await validate(ModelInstallation(receipt: receipt, directory: assembled))
        try place(assembled, at: key)
        try? files.removeItem(at: work)
        return key
    }

    private func legacyMarker(in folder: URL) -> LegacyMarker? {
        (try? Data(contentsOf: folder.appendingPathComponent("installed.json"))).flatMap { try? JSONDecoder().decode(LegacyMarker.self, from: $0) }
    }

    /// An unfinished legacy download: a top-level folder named like a legacy ID, holding HubApi's or
    /// FluidAudio's layout. Store folders (engines) never contain these.
    private func isLegacyPartial(_ folder: URL) -> Bool {
        let models = folder.appendingPathComponent("models", isDirectory: true)
        let fluid = folder.appendingPathComponent("speaker-diarization", isDirectory: true)
        return files.fileExists(atPath: models.path) || files.fileExists(atPath: fluid.path)
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? MigrationFailure { return failure.description }
        return error.localizedDescription
    }

    enum MigrationFailure: Error, CustomStringConvertible {
        case noLegacyPath(String), mismatch(String)
        var description: String {
            switch self {
            case .noLegacyPath(let artifact): return "The migration table has no legacy folder for \(artifact)."
            case .mismatch(let path): return "\(path) is missing or doesn’t match the catalog."
            }
        }
    }
}

enum ManifestSafety {
    /// Legacy IDs become folder names under Models/.
    static func isSafeFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
    }
}
