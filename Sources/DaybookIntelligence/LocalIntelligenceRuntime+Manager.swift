import DaybookKit
import Foundation

// What the model manager needs beyond the runtime's core API (docs/models.md, "The model
// manager"): a look at what adding a repository would add, before anything is written; recording
// an update without downloading it, so the download joins the app's queue; and the revisions
// garbage collection can remove. Additive: the core types are unchanged.

/// What adding a Hugging Face repository would add, for each engine and role that can run it.
public struct ModelAdditionPreview: Sendable {
    /// One way to add it: an engine that accepted the files, for one of its roles.
    public struct Candidate: Identifiable, Sendable {
        public var id: String { "\(engine.id.rawValue)|\(role.rawValue)" }
        public var engine: ModelEngineDescriptor
        public var role: ModelRole
        public var proposal: ModelAdditionProposal
        /// An existing family that already uses this repository with this engine, which the model joins.
        public var familyID: String?
        public var familyName: String?
        /// The name of a model in the catalog that already has exactly these files.
        public var duplicateOf: String?

        public var files: [ModelFile] { proposal.artifacts.flatMap(\.files) }
        public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    /// An engine and role that can't run it, with each reason in plain words.
    public struct Rejection: Sendable, Equatable {
        public var engine: ModelEngineDescriptor
        public var role: ModelRole
        public var reasons: [String]
    }

    public var repository: String
    /// The commit the branch or revision named when it was checked; adding pins exactly this one.
    public var commit: ModelHubCommit
    /// The license the repository's card declares, in Daybook's terms.
    public var license: ModelLicense
    public var candidates: [Candidate]
    public var rejections: [Rejection]
}

extension LocalIntelligenceRuntime {
    /// Lists `repository` at `revision` once and asks every registered engine, for each role it
    /// serves, whether it can run it. Nothing is written or downloaded; `addModel` with the chosen
    /// candidate's engine and role (and `commit.id` as the revision) adds exactly what was shown.
    public func previewAddition(repository: String, revision: String = "main", options: [String: String] = [:],
                                client: any ModelHubClient) async throws -> ModelAdditionPreview {
        let info = try? await client.info(repository: repository)
        if info?.gated == true { throw ModelAdditionError.gated(repository) }
        let snapshot = try await ModelRepositorySnapshot.load(repository, revision: revision, client: client)
        let catalog = catalog
        var candidates: [ModelAdditionPreview.Candidate] = []
        var rejections: [ModelAdditionPreview.Rejection] = []
        for engine in registry.engines {
            let roles = engine.descriptor.roles.sorted { Self.order($0) < Self.order($1) }
            for role in roles {
                let request = ModelAdditionRequest(repository: repository, revision: snapshot.commit.id, role: role,
                                                   engine: engine.descriptor.id, variantName: repository, options: options)
                do {
                    let proposal = try await engine.proposeAddition(request, repository: snapshot)
                    let family = catalog.models.first { model in
                        model.engine == engine.descriptor.id && model.variant.revisions.contains { $0.artifacts.first?.repository == repository }
                    }
                    let duplicate = catalog.models.first { model in model.variant.revisions.contains { $0.artifacts == proposal.artifacts } }
                    candidates.append(.init(engine: engine.descriptor, role: role, proposal: proposal, familyID: family?.familyID,
                                            familyName: family?.familyName, duplicateOf: duplicate?.name))
                } catch ModelAdditionError.invalid(let reasons) {
                    rejections.append(.init(engine: engine.descriptor, role: role, reasons: reasons))
                } catch {
                    rejections.append(.init(engine: engine.descriptor, role: role, reasons: [error.localizedDescription]))
                }
            }
        }
        return ModelAdditionPreview(repository: repository, commit: snapshot.commit,
                                    license: ModelIdentifier.license(from: info, repository: repository),
                                    candidates: candidates, rejections: rejections)
    }

    /// Records an update's revision in the person's manifest without downloading it, so the app can
    /// queue `download(modelID: "<key>@<revision>")` with its other downloads (behind processing,
    /// cancellable). `installUpdate` is this plus that download.
    @discardableResult
    public func recordUpdate(_ update: ModelUpdate) throws -> ModelCatalog {
        guard let model = catalog.model(update.model) else { throw LocalIntelligenceError.unknownModel(update.model) }
        guard model.revision(update.revision.id) == nil else { return catalog }
        let manifest = UserModelManifest(url: modelsDirectory.appendingPathComponent("UserModels.json"))
        let current = manifest.read().manifest ?? ModelManifest()
        try manifest.write(UserModelManifest.adding(update.revision, to: model, in: current))
        return reloadCatalog()
    }

    private static func order(_ role: ModelRole) -> Int { ModelRole.known.firstIndex(of: role) ?? ModelRole.known.count }
}

extension ModelInventory {
    /// Revisions a newer ready revision of the same variant replaced: what "Remove old revisions"
    /// (garbage collection) can take, unless something still protects them.
    public var replacedRevisions: [InstalledModelRevision] {
        var newest: [String: ModelInstallKey] = [:]
        for revision in revisions where revision.isReady && newest[revision.key.variantKey] == nil {
            newest[revision.key.variantKey] = revision.key
        }
        return revisions.filter { revision in
            guard let current = newest[revision.key.variantKey] else { return false }
            return revision.key != current
        }
    }
}
