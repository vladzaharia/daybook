import Foundation

/// Where a catalog entry came from.
public enum ModelOrigin: String, Codable, Sendable {
    /// The built-in catalog, shipped with the app.
    case builtIn
    /// The person's UserModels.json: a model they added, or a newer revision they installed.
    case addedByYou

    /// The label the model manager shows ("Added by you"), or nil for built-in models.
    public var label: String? { self == .addedByYou ? "Added by you" : nil }
}

/// Whether this build can run a catalog entry.
public enum ModelAvailability: Equatable, Sendable {
    case available
    /// The entry asks for a newer app.
    case needsNewerApp(minimum: String)
    /// The entry asks for a newer version of its engine (a new architecture, a new feature).
    case needsNewerEngine(ModelEngineID, minimum: Int, current: Int)
    /// No engine with this ID is registered: it arrives in a later Daybook.
    case unknownEngine(ModelEngineID)
    /// The engine exists but doesn't run on this device.
    case unsupportedPlatform(ModelPlatform)
    /// The engine runs here, but the system can't provide the model right now (Apple Intelligence
    /// is off, or the system is too old), in the engine's words.
    case unavailableOnDevice(reason: String)

    public var isAvailable: Bool { self == .available }

    /// What the interface shows instead of offering the model.
    public var label: String? {
        switch self {
        case .available: return nil
        case .needsNewerApp, .needsNewerEngine, .unknownEngine: return "Needs a newer Daybook"
        case .unsupportedPlatform(let platform): return platform == .iOS ? "Not available on iPhone" : "Not available on this Mac"
        case .unavailableOnDevice(let reason): return reason
        }
    }
}

/// One variant as the app uses it, with its family's engine, roles, and license applied.
public struct CatalogModel: Identifiable, Equatable, Sendable {
    public let familyID: String
    public let familyName: String
    public let maker: String?
    public let variant: ModelVariantEntry
    public let engine: ModelEngineID
    public let roles: [ModelRole]
    public let license: ModelLicense?
    public let homepage: String?
    /// Built in, or added by the person.
    public let origin: ModelOrigin
    /// Revisions the person's manifest contributed (installed updates), by revision ID.
    public let userRevisionIDs: Set<String>

    /// "whisper/base": what selections, jobs, and new results name.
    public var key: String { "\(familyID)/\(variant.id)" }
    public var id: String { key }
    public var name: String { variant.name }
    public var detail: String { variant.detail ?? "" }
    public var capabilities: ModelCapabilities { variant.capabilities }
    public var engineOptions: [String: String] { variant.engineOptions }
    public var recommendedMemoryGB: Int { variant.recommendedMemoryGB ?? 8 }

    /// Newest first: by release date, then by the order the manifests list them (later is newer).
    public var revisions: [ModelRevisionEntry] {
        variant.revisions.enumerated().sorted { left, right in
            let a = left.element.releaseDate ?? "", b = right.element.releaseDate ?? ""
            return a == b ? left.offset > right.offset : a > b
        }.map(\.element)
    }

    /// The revision a download installs.
    public var latestRevision: ModelRevisionEntry? { revisions.first }
    public func revision(_ id: String) -> ModelRevisionEntry? { variant.revisions.first { $0.id == id } }

    /// Download size of the newest revision.
    public var approximateBytes: Int64 { latestRevision?.totalBytes ?? 0 }

    /// Catalog IDs from before the model system that name this variant (the migration table).
    public var legacyIDs: [String] { variant.revisions.flatMap { $0.legacy?.ids ?? [] } }

    public func serves(_ role: ModelRole) -> Bool { roles.contains(role) }

    /// Provided by the operating system (Apple Foundation Models): nothing to download or remove.
    public var isSystemModel: Bool { variant.systemProvided }

    /// Whether this build can run it here. `engines` are the registered engines' descriptions;
    /// `appVersion` nil (a development build) satisfies every minimum.
    public func availability(engines: [ModelEngineDescriptor], appVersion: ModelVersion? = ModelVersion.app,
                             platform: ModelPlatform = .current) -> ModelAvailability {
        if let minimum = variant.minimumAppVersion, let appVersion {
            guard let required = ModelVersion(minimum) else { return .needsNewerApp(minimum: minimum) }
            if appVersion < required { return .needsNewerApp(minimum: minimum) }
        }
        guard let descriptor = engines.first(where: { $0.id == engine }) else { return .unknownEngine(engine) }
        if let minimum = variant.minimumEngineVersion, descriptor.version < minimum {
            return .needsNewerEngine(engine, minimum: minimum, current: descriptor.version)
        }
        guard descriptor.platforms.contains(platform) else { return .unsupportedPlatform(platform) }
        if let reason = descriptor.unavailableReason { return .unavailableOnDevice(reason: reason) }
        return .available
    }
}

/// Every model Daybook knows: the built-in manifest merged with the person's own. Lookups accept
/// variant keys ("whisper/base"), legacy IDs ("whisper-base"), and "key@revision".
public struct ModelCatalog: Sendable {
    public private(set) var models: [CatalogModel]
    public let presets: [ModelPresetEntry]
    public let recommendedPreset: ModelRecommendedPreset?
    public let initialSelection: ModelChoiceTable?
    public let catalogVersion: String?
    /// What reading the manifests skipped.
    public let warnings: [String]

    /// Merges `user` into `builtIn`: a user family with a built-in family's ID adds variants to it,
    /// and a user variant with a built-in variant's ID adds revisions (installed updates). Built-in
    /// metadata is never overridden. Presets come from the built-in manifest only.
    public init(builtIn: ModelManifest, user: ModelManifest? = nil, warnings: [String] = []) {
        var families: [(family: ModelFamilyEntry, origin: ModelOrigin, variantOrigins: [String: ModelOrigin], userRevisions: [String: Set<String>])] =
            builtIn.families.map { ($0, .builtIn, Dictionary(uniqueKeysWithValues: $0.variants.map { ($0.id, .builtIn) }), [:]) }
        for family in user?.families ?? [] {
            if let index = families.firstIndex(where: { $0.family.id == family.id }) {
                for variant in family.variants {
                    if let existing = families[index].family.variants.firstIndex(where: { $0.id == variant.id }) {
                        let known = Set(families[index].family.variants[existing].revisions.map(\.id))
                        let added = variant.revisions.filter { !known.contains($0.id) }
                        families[index].family.variants[existing].revisions += added
                        families[index].userRevisions[variant.id, default: []].formUnion(added.map(\.id))
                    } else {
                        families[index].family.variants.append(variant)
                        families[index].variantOrigins[variant.id] = .addedByYou
                        families[index].userRevisions[variant.id] = Set(variant.revisions.map(\.id))
                    }
                }
            } else {
                families.append((family, .addedByYou, Dictionary(uniqueKeysWithValues: family.variants.map { ($0.id, .addedByYou) }),
                                 Dictionary(uniqueKeysWithValues: family.variants.map { ($0.id, Set($0.revisions.map(\.id))) })))
            }
        }
        var models: [CatalogModel] = []
        var problems = warnings
        for entry in families {
            for variant in entry.family.variants {
                guard let engine = variant.engine ?? entry.family.engine else {
                    problems.append("“\(entry.family.id)/\(variant.id)” names no engine and was skipped."); continue
                }
                models.append(CatalogModel(
                    familyID: entry.family.id, familyName: entry.family.name, maker: entry.family.maker, variant: variant,
                    engine: engine, roles: variant.roles ?? entry.family.roles, license: variant.license ?? entry.family.license,
                    homepage: variant.homepage ?? entry.family.homepage, origin: entry.variantOrigins[variant.id] ?? entry.origin,
                    userRevisionIDs: entry.userRevisions[variant.id] ?? []))
            }
        }
        self.models = models
        presets = builtIn.presets
        recommendedPreset = builtIn.recommendedPreset
        initialSelection = builtIn.initialSelection
        catalogVersion = builtIn.catalogVersion
        self.warnings = problems
    }

    /// The catalog that ships with this build.
    public static let builtIn: ModelCatalog = {
        do {
            let result = try readBuiltInManifest()
            return ModelCatalog(builtIn: result.manifest, warnings: result.warnings)
        } catch {
            return ModelCatalog(builtIn: ModelManifest(), warnings: ["The built-in model list couldn’t be read: \(error.localizedDescription)"])
        }
    }()

    /// The ModelCatalog folder from DaybookKit's resources.
    public static func readBuiltInManifest() throws -> ModelManifestReader.Result {
        guard let folder = Bundle.module.url(forResource: "ModelCatalog", withExtension: nil) else {
            throw ModelManifestError.unreadable("The built-in model list is missing from the app.")
        }
        return try readManifestFolder(folder)
    }

    /// A catalog folder: Catalog.json (presets and initial choices) plus one manifest per family in
    /// Families/, so adding a model is adding a file. Families load in file-name order. A family file
    /// that can't be read, or that needs a newer Daybook, is skipped with a warning and the rest load.
    public static func readManifestFolder(_ folder: URL) throws -> ModelManifestReader.Result {
        var result = try ModelManifestReader.read(Data(contentsOf: folder.appendingPathComponent("Catalog.json")))
        let families = folder.appendingPathComponent("Families", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: families, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let name = file.lastPathComponent
            do {
                let part = try ModelManifestReader.read(Data(contentsOf: file))
                result.warnings += part.warnings.map { "\(name): \($0)" }
                for family in part.manifest.families {
                    guard !result.manifest.families.contains(where: { $0.id == family.id }) else {
                        result.warnings.append("\(name): Skipped a second family “\(family.id)”."); continue
                    }
                    result.manifest.families.append(family)
                }
            } catch {
                result.warnings.append("Skipped \(name): \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: Lookup

    /// A variant by key, legacy ID, or "key@revision".
    public func model(_ reference: String) -> CatalogModel? {
        let id = ModelReference(reference).id
        return models.first { $0.key == id } ?? models.first { $0.legacyIDs.contains(id) }
    }

    public func model(for provenance: ModelProvenance) -> CatalogModel? {
        models.first { $0.familyID == provenance.family && $0.variant.id == provenance.variant }
    }

    /// The variants that can serve `role`, in catalog order.
    public func models(for role: ModelRole) -> [CatalogModel] { models.filter { $0.serves(role) } }

    /// The variant and exact revision a legacy catalog ID named.
    public func legacyRevision(for legacyID: String) -> (model: CatalogModel, revision: ModelRevisionEntry)? {
        for model in models {
            if let revision = model.variant.revisions.first(where: { $0.legacy?.ids.contains(legacyID) == true }) {
                return (model, revision)
            }
        }
        return nil
    }

    /// The variant a reference names and, when a job froze one, its exact revision. Nil revision
    /// means the newest installed one; a legacy ID names the variant, not its old revision.
    public func revision(for reference: ModelReference) -> (model: CatalogModel, revision: ModelRevisionEntry?)? {
        guard let model = model(reference.id) else { return nil }
        return (model, reference.revision.flatMap(model.revision))
    }

    // MARK: Results

    /// How the interface names the model behind a stored result: the catalog's name, else the name
    /// its provenance recorded (a model this device doesn't know), else the stored ID itself.
    public func name(for storedModelID: String, provenance: ModelProvenance? = nil) -> String {
        if let provenance, let model = model(for: provenance) { return model.name }
        if let model = model(storedModelID) { return model.name }
        return provenance?.name ?? storedModelID
    }

    /// The provenance of a result: what it recorded, or, for results from before the model system,
    /// what its legacy model ID maps to through the migration table (engine version "legacy").
    public func provenance(of settings: ProcessingSettings?, modelID: String) -> ModelProvenance? {
        if let recorded = settings?.model { return recorded }
        return provenance(forStoredModelID: settings?.modelID ?? modelID)
    }

    public func provenance(forStoredModelID storedID: String) -> ModelProvenance? {
        let revision: ModelRevisionEntry?
        let model: CatalogModel
        if let legacy = legacyRevision(for: storedID) { (model, revision) = (legacy.model, legacy.revision) }
        else if let resolved = self.revision(for: ModelReference(storedID)) { (model, revision) = (resolved.model, resolved.revision) }
        else { return nil }
        // A key without a recorded revision can't say which revision made it.
        return ModelProvenance(family: model.familyID, variant: model.variant.id, revision: revision?.id ?? "",
                               engine: model.engine.rawValue, engineVersion: "legacy", name: model.name,
                               repository: revision?.artifacts.first?.repository)
    }
}
