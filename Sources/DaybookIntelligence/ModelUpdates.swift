import DaybookKit
import Foundation

/// A newer revision of a variant on Hugging Face, found by an opt-in check.
public struct ModelUpdate: Equatable, Sendable {
    /// The variant key: "whisper/base".
    public var model: String
    public var name: String
    /// The newest revision the catalog knows now.
    public var currentRevision: String
    /// The revision to install beside it, with its full file list.
    public var revision: ModelRevisionEntry
    public var publishedAt: Date?
    /// Paths that are new or changed, for "what changed".
    public var changedFiles: [String]
    /// What installing it downloads.
    public var downloadBytes: Int64 { revision.totalBytes }
}

/// Asks Hugging Face whether a tracked variant's repository has moved on (docs/models.md,
/// "Revision checks (opt-in)"). Daybook never installs an update by itself: the person sees what
/// changed, its size, and when it was published, and chooses.
public struct ModelUpdateChecker: Sendable {
    let client: any ModelHubClient

    public init(client: any ModelHubClient) { self.client = client }

    /// Updates for `models`, skipping any whose check fails (offline, a repository gone).
    public func check(_ models: [CatalogModel]) async -> [ModelUpdate] {
        var updates: [ModelUpdate] = []
        for model in models {
            if let update = try? await check(model) { updates.append(update) }
        }
        return updates
    }

    /// Compares each artifact's tracked branch with its pinned commit. A branch that moved only
    /// counts if the files the artifact selects (its `include` patterns) actually changed.
    public func check(_ model: CatalogModel) async throws -> ModelUpdate? {
        guard let current = model.latestRevision else { return nil }
        var artifacts: [ModelArtifact] = []
        var changed: [String] = []
        var commits: [(index: Int, commit: ModelHubCommit)] = []
        for (index, artifact) in current.artifacts.enumerated() {
            try Task.checkCancellation()
            let head = try await client.commit(repository: artifact.repository, reference: artifact.track ?? "main")
            guard head.id != artifact.revision, !artifact.include.isEmpty else { artifacts.append(artifact); continue }
            let listed = try await client.files(repository: artifact.repository, revision: head.id, path: Self.listingRoot(artifact.include))
            let selected = listed.filter { file in artifact.include.contains { ModelGlob.matches($0, file.path) } }
                .map(\.manifestFile).sorted { $0.path < $1.path }
            guard !selected.isEmpty else { artifacts.append(artifact); continue }
            let before = Set(artifact.files)
            let different = selected.filter { !before.contains($0) }.map(\.path)
            let removed = Set(artifact.files.map(\.path)).subtracting(selected.map(\.path))
            guard !different.isEmpty || !removed.isEmpty else { artifacts.append(artifact); continue }
            var updated = artifact
            updated.revision = head.id
            updated.files = selected
            artifacts.append(updated)
            changed += different.map { "\(artifact.name)/\($0)" } + removed.sorted().map { "\(artifact.name)/\($0) (removed)" }
            commits.append((index, head))
        }
        guard let newest = commits.max(by: { ($0.commit.date ?? .distantPast) < ($1.commit.date ?? .distantPast) }) else { return nil }
        let primary = artifacts[0].revision
        let id = commits.contains { $0.index == 0 } ? primary : "\(primary.prefix(12))-\(newest.commit.id.prefix(12))"
        let day = newest.commit.date.map { Self.day.string(from: $0) }
        let revision = ModelRevisionEntry(id: id, releaseDate: day, summary: newest.commit.title, artifacts: artifacts)
        return ModelUpdate(model: model.key, name: model.name, currentRevision: current.id, revision: revision,
                           publishedAt: newest.commit.date, changedFiles: changed)
    }

    /// The deepest folder every pattern is inside, so the listing stays small ("openai_whisper-base").
    static func listingRoot(_ patterns: [String]) -> String? {
        let folders = patterns.map { pattern -> [Substring] in
            let literal = pattern.prefix { !"*?[".contains($0) }
            return Array(literal.split(separator: "/", omittingEmptySubsequences: false).dropLast())
        }
        guard var common = folders.first else { return nil }
        for folder in folders.dropFirst() {
            common = Array(zip(common, folder).prefix { $0 == $1 }.map(\.0))
        }
        let path = common.joined(separator: "/")
        return path.isEmpty ? nil : path
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// The person's manifest, `Models/UserModels.json`: models they added and updates they installed.
struct UserModelManifest {
    let url: URL

    /// The manifest, or an empty one. A file this build can't read is left untouched (not overwritten).
    func read() -> (manifest: ModelManifest?, warnings: [String]) {
        guard let data = try? Data(contentsOf: url) else { return (nil, []) }
        do {
            let result = try ModelManifestReader.read(data)
            return (result.manifest, result.warnings.map { "Your models: \($0)" })
        } catch {
            return (nil, ["Your added models couldn’t be read: \(error.localizedDescription)"])
        }
    }

    func write(_ manifest: ModelManifest) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ModelManifestReader.encode(manifest).write(to: url, options: .atomic)
    }

    /// Adds `variant` to family `familyID`, creating the family from `family` when needed.
    static func adding(_ variant: ModelVariantEntry, to family: ModelFamilyEntry, in manifest: ModelManifest) -> ModelManifest {
        var manifest = manifest
        if let index = manifest.families.firstIndex(where: { $0.id == family.id }) {
            manifest.families[index].variants.removeAll { $0.id == variant.id }
            manifest.families[index].variants.append(variant)
        } else {
            var copy = family
            copy.variants = [variant]
            manifest.families.append(copy)
        }
        return manifest
    }

    /// Adds a revision to an existing variant (built in or added): the overlay `ModelCatalog` merges.
    static func adding(_ revision: ModelRevisionEntry, to model: CatalogModel, in manifest: ModelManifest) -> ModelManifest {
        var manifest = manifest
        if let family = manifest.families.firstIndex(where: { $0.id == model.familyID }),
           let variant = manifest.families[family].variants.firstIndex(where: { $0.id == model.variant.id }) {
            manifest.families[family].variants[variant].revisions.removeAll { $0.id == revision.id }
            manifest.families[family].variants[variant].revisions.append(revision)
            return manifest
        }
        let overlay = ModelVariantEntry(id: model.variant.id, name: model.name, revisions: [revision])
        let family = ModelFamilyEntry(id: model.familyID, name: model.familyName, engine: model.engine, roles: model.roles)
        return adding(overlay, to: family, in: manifest)
    }

    /// Removes an added variant; built-in variants only lose the revisions the person added.
    static func removing(_ variantKey: String, from manifest: ModelManifest) -> ModelManifest {
        var manifest = manifest
        for index in manifest.families.indices {
            let familyID = manifest.families[index].id
            manifest.families[index].variants.removeAll { "\(familyID)/\($0.id)" == variantKey }
        }
        manifest.families.removeAll { $0.variants.isEmpty }
        return manifest
    }
}
