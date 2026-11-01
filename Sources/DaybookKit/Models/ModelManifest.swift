import Foundation

// The manifest format (docs/models.md, "Manifests"): the built-in ModelCatalog folder's files and the
// person's own UserModels.json share it. Reading is deliberately forgiving:
//   • unknown fields are ignored;
//   • an entry that can't be read (a wrong type, an unsafe identifier or path) is skipped with a
//     warning, and the rest of the manifest still loads;
//   • a newer `schemaVersion` is read as far as this build understands it;
//   • only a `minimumReaderVersion` above `ModelManifest.readerVersion` rejects the whole file,
//     which a manifest author sets for a change older readers would misread.

/// One manifest file.
public struct ModelManifest: Equatable, Sendable {
    /// The schema this build reads and writes.
    public static let readerVersion = 1

    public var schemaVersion: Int
    /// The oldest reader that can interpret this file correctly.
    public var minimumReaderVersion: Int
    /// The built-in catalog's edition, "2026.10.24".
    public var catalogVersion: String?
    public var families: [ModelFamilyEntry]
    /// Quality presets (Quick, Balanced, Detailed): ordered choices per role.
    public var presets: [ModelPresetEntry]
    /// Which preset suits each device tier.
    public var recommendedPreset: ModelRecommendedPreset?
    /// What a new installation selects before anyone chooses.
    public var initialSelection: ModelChoiceTable?
    /// The live roles' defaults (`ModelRole.live`), best first, per platform and tier: live captions
    /// on the Mac and the iPhone (docs/models.md, "Live models"). Readers before it ignore it.
    public var liveSelection: ModelChoiceTable?

    public init(schemaVersion: Int = ModelManifest.readerVersion, minimumReaderVersion: Int = 1, catalogVersion: String? = nil,
                families: [ModelFamilyEntry] = [], presets: [ModelPresetEntry] = [],
                recommendedPreset: ModelRecommendedPreset? = nil, initialSelection: ModelChoiceTable? = nil,
                liveSelection: ModelChoiceTable? = nil) {
        self.schemaVersion = schemaVersion; self.minimumReaderVersion = minimumReaderVersion
        self.catalogVersion = catalogVersion; self.families = families; self.presets = presets
        self.recommendedPreset = recommendedPreset; self.initialSelection = initialSelection
        self.liveSelection = liveSelection
    }
}

/// One model as people know it: Whisper, Qwen 2.5, Community-1.
public struct ModelFamilyEntry: Equatable, Sendable {
    public var id: String
    public var name: String
    public var maker: String?
    /// The engine that runs its variants unless a variant names another.
    public var engine: ModelEngineID?
    public var roles: [ModelRole]
    public var summary: String?
    public var homepage: String?
    public var license: ModelLicense?
    public var variants: [ModelVariantEntry]

    public init(id: String, name: String, maker: String? = nil, engine: ModelEngineID? = nil, roles: [ModelRole] = [],
                summary: String? = nil, homepage: String? = nil, license: ModelLicense? = nil, variants: [ModelVariantEntry] = []) {
        self.id = id; self.name = name; self.maker = maker; self.engine = engine; self.roles = roles
        self.summary = summary; self.homepage = homepage; self.license = license; self.variants = variants
    }
}

/// A distinct build people choose between: a size, a quantization, a format.
public struct ModelVariantEntry: Equatable, Sendable {
    public var id: String
    public var name: String
    public var detail: String?
    /// Overrides the family's engine, roles, license, or homepage.
    public var engine: ModelEngineID?
    public var roles: [ModelRole]?
    public var license: ModelLicense?
    public var homepage: String?
    /// When the upstream model was published, "2024-09-17".
    public var releaseDate: String?
    public var recommendedMemoryGB: Int?
    /// How good it is at each role it serves (`ModelRole.rawValue` → 0–100; docs/models.md, "Quality ranks"), for
    /// "Upgrade" offers: comparable within a role, and for summaries on the cloud catalog's `summaryQuality` scale.
    /// Empty when unranked: a result it made offers no upgrade.
    public var quality: [String: Int]
    public var capabilities: ModelCapabilities
    /// Engine-specific settings, such as Sortformer's "precision" or an MLX "architecture".
    public var engineOptions: [String: String]
    /// An entry this build can't run reads "Needs a newer Daybook" and is never offered.
    public var minimumAppVersion: String?
    public var minimumEngineVersion: Int?
    /// Variant keys ("family/variant") this one replaces, and the one that replaces it.
    public var supersedes: [String]
    public var supersededBy: String?
    /// Provided by the operating system (Apple Foundation Models): no revisions, nothing to
    /// download or remove; its engine decides whether this device has it.
    public var systemProvided: Bool
    /// Immutable file sets, any order; the newest by release date is preferred.
    public var revisions: [ModelRevisionEntry]

    public init(id: String, name: String, detail: String? = nil, engine: ModelEngineID? = nil, roles: [ModelRole]? = nil,
                license: ModelLicense? = nil, homepage: String? = nil, releaseDate: String? = nil, recommendedMemoryGB: Int? = nil,
                quality: [String: Int] = [:], capabilities: ModelCapabilities = .init(), engineOptions: [String: String] = [:], minimumAppVersion: String? = nil,
                minimumEngineVersion: Int? = nil, supersedes: [String] = [], supersededBy: String? = nil,
                systemProvided: Bool = false, revisions: [ModelRevisionEntry] = []) {
        self.id = id; self.name = name; self.detail = detail; self.engine = engine; self.roles = roles
        self.license = license; self.homepage = homepage; self.releaseDate = releaseDate
        self.recommendedMemoryGB = recommendedMemoryGB; self.quality = quality; self.capabilities = capabilities
        self.engineOptions = engineOptions
        self.minimumAppVersion = minimumAppVersion; self.minimumEngineVersion = minimumEngineVersion
        self.supersedes = supersedes; self.supersededBy = supersededBy; self.systemProvided = systemProvided
        self.revisions = revisions
    }
}

/// One exact, immutable set of files for a variant.
public struct ModelRevisionEntry: Equatable, Sendable {
    /// Unique within its variant and safe as a folder name: the primary repository commit.
    public var id: String
    /// When these files were published (the commit date).
    public var releaseDate: String?
    /// What changed, in a line (the commit title).
    public var summary: String?
    public var artifacts: [ModelArtifact]
    /// How Daybook stored this revision before the model system, for migrating installs and naming
    /// old results: the legacy catalog IDs and each artifact's folder inside `Models/<legacy ID>/`.
    public var legacy: ModelLegacyInstall?

    public init(id: String, releaseDate: String? = nil, summary: String? = nil, artifacts: [ModelArtifact],
                legacy: ModelLegacyInstall? = nil) {
        self.id = id; self.releaseDate = releaseDate; self.summary = summary; self.artifacts = artifacts; self.legacy = legacy
    }

    /// Bytes to download.
    public var totalBytes: Int64 { artifacts.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.size } } }
}

/// Files from one repository at one commit, installed under the revision's `<name>/` folder.
public struct ModelArtifact: Equatable, Sendable {
    /// "model", "tokenizer": the folder name in the install and how engines ask for it.
    public var name: String
    public var repository: String
    /// The commit the files come from.
    public var revision: String
    /// The glob patterns that chose `files` from the repository, reused to compare newer revisions.
    public var include: [String]
    /// The folder within the repository an engine loads from ("openai_whisper-base"); nil for the root.
    public var root: String?
    /// The branch update checks follow; nil follows "main".
    public var track: String?
    public var files: [ModelFile]

    public init(name: String, repository: String, revision: String, include: [String] = [], root: String? = nil,
                track: String? = nil, files: [ModelFile]) {
        self.name = name; self.repository = repository; self.revision = revision; self.include = include
        self.root = root; self.track = track; self.files = files
    }
}

/// One file and how to verify it. Hugging Face publishes SHA-256 for large (LFS) files and a git
/// blob ID (SHA-1 over a header and the content) for small ones; the store checks whichever is given.
public struct ModelFile: Hashable, Sendable {
    /// Relative to the repository root.
    public var path: String
    public var size: Int64
    public var sha256: String?
    public var gitOID: String?

    public init(path: String, size: Int64, sha256: String? = nil, gitOID: String? = nil) {
        self.path = path; self.size = size; self.sha256 = sha256; self.gitOID = gitOID
    }
}

/// The pre-model-system layout of a revision (`Models/<legacy ID>/installed.json`).
public struct ModelLegacyInstall: Equatable, Sendable {
    public var ids: [String]
    /// Artifact name → its repository root inside the legacy folder ("models/argmaxinc/whisperkit-coreml").
    public var artifactPaths: [String: String]
    public init(ids: [String], artifactPaths: [String: String] = [:]) { self.ids = ids; self.artifactPaths = artifactPaths }
}

/// A model's license as Daybook presents it. Daybook's code is MIT; models keep their own terms,
/// and those that don't allow commercial use are labelled wherever a model is chosen.
public struct ModelLicense: Hashable, Sendable {
    /// SPDX or a short identifier: "MIT", "Apache-2.0", "Qwen-Research".
    public var id: String?
    /// "Apache License 2.0", "NVIDIA Open Model License".
    public var name: String
    public var url: String
    /// False for research-only or non-commercial terms.
    public var allowsCommercialUse: Bool
    /// Credit the terms require Daybook to show (CC BY attribution, NVIDIA's notice).
    public var attribution: String?

    public init(id: String? = nil, name: String, url: String, allowsCommercialUse: Bool, attribution: String? = nil) {
        self.id = id; self.name = name; self.url = url; self.allowsCommercialUse = allowsCommercialUse; self.attribution = attribution
    }
}

/// What a variant can do, read by the pipeline and the interface instead of comparing model IDs.
/// Every field is optional; nil means "not declared", which callers treat as "no".
public struct ModelCapabilities: Hashable, Sendable {
    // Transcription
    public var wordTimestamps: Bool?
    public var wordConfidence: Bool?
    /// BCP-47 codes; ["*"] means the model's own broad set (Whisper's 99 languages).
    public var languages: [String]?
    /// Accepts the approved vocabulary as a decoding hint.
    public var vocabularyPrompt: Bool?
    // Speakers
    /// The most speakers it can tell apart; nil for no fixed limit.
    public var maxSpeakers: Int?
    /// Produces voice embeddings, and in which space. Profiles from different spaces are never compared.
    public var voiceEmbeddings: VoiceEmbeddingSpace?
    /// Uses an expected speaker count as a clustering target.
    public var expectedSpeakerCount: Bool?
    // Language
    public var contextLength: Int?
    /// Can constrain output to a JSON schema.
    public var structuredOutput: Bool?
    // Images
    /// Takes images as input (a vision-language model, or Apple Vision).
    public var imageInput: Bool?
    // Running
    public var streaming: Bool?
    /// Resident memory while running, in GB.
    public var memoryGB: Double?
    /// Expected multiple of real time on a typical Mac.
    public var realTimeFactor: Double?

    public init(wordTimestamps: Bool? = nil, wordConfidence: Bool? = nil, languages: [String]? = nil, vocabularyPrompt: Bool? = nil,
                maxSpeakers: Int? = nil, voiceEmbeddings: VoiceEmbeddingSpace? = nil, expectedSpeakerCount: Bool? = nil,
                contextLength: Int? = nil, structuredOutput: Bool? = nil, streaming: Bool? = nil, memoryGB: Double? = nil,
                realTimeFactor: Double? = nil, imageInput: Bool? = nil) {
        self.wordTimestamps = wordTimestamps; self.wordConfidence = wordConfidence; self.languages = languages
        self.vocabularyPrompt = vocabularyPrompt; self.maxSpeakers = maxSpeakers; self.voiceEmbeddings = voiceEmbeddings
        self.expectedSpeakerCount = expectedSpeakerCount; self.contextLength = contextLength
        self.structuredOutput = structuredOutput; self.streaming = streaming; self.memoryGB = memoryGB
        self.realTimeFactor = realTimeFactor; self.imageInput = imageInput
    }
}

/// A voice-embedding space: "fluid-community1-embedding-df2625ac79a7ac6b", 256 dimensions.
public struct VoiceEmbeddingSpace: Codable, Hashable, Sendable {
    public var space: String
    public var dimensions: Int?
    public init(space: String, dimensions: Int? = nil) { self.space = space; self.dimensions = dimensions }
}

/// Ordered choices per role ("family/variant" keys, best first), with per-tier and per-platform
/// overrides.
public struct ModelChoiceTable: Equatable, Sendable {
    public var roles: [String: [String]]
    /// Device tier → role → choices, replacing `roles` for that role on that tier.
    public var tiers: [String: [String: [String]]]
    /// Platform ("macOS", "iOS") → role → choices, replacing `roles` and `tiers` for that role on
    /// that platform: an iPhone's defaults differ from a Mac's of the same memory.
    public var platforms: [String: [String: [String]]]
    /// Platform → that platform's own tier → role → choices, replacing the platform's list for that
    /// role on that tier: an iPhone's memory tiers (`PhoneTier`) aren't a Mac's.
    public var platformTiers: [String: [String: [String: [String]]]]

    public init(roles: [String: [String]] = [:], tiers: [String: [String: [String]]] = [:],
                platforms: [String: [String: [String]]] = [:], platformTiers: [String: [String: [String: [String]]]] = [:]) {
        self.roles = roles; self.tiers = tiers; self.platforms = platforms; self.platformTiers = platformTiers
    }

    /// The choices for `role` on `tier`, on any platform the table doesn't single out.
    public func choices(for role: ModelRole, tier: String) -> [String] {
        tiers[tier]?[role.rawValue] ?? roles[role.rawValue] ?? []
    }

    /// The choices for `role` on `platform` and `tier`: the platform's own list first, then the tier's.
    public func choices(for role: ModelRole, tier: String, platform: ModelPlatform) -> [String] {
        platforms[platform.rawValue]?[role.rawValue] ?? choices(for: role, tier: tier)
    }

    /// The choices for `role` on `platform` in one of that platform's own tiers: the tier's list, then
    /// the platform's, then the table's own roles.
    public func choices(for role: ModelRole, platform: ModelPlatform, platformTier: String) -> [String] {
        platformTiers[platform.rawValue]?[platformTier]?[role.rawValue] ?? platforms[platform.rawValue]?[role.rawValue]
            ?? roles[role.rawValue] ?? []
    }
}

/// One quality preset.
public struct ModelPresetEntry: Equatable, Sendable {
    /// "quick", "balanced", "detailed" (`ModelQuality`).
    public var id: String
    /// The speaker-analysis effort the preset uses ("fast", "balanced", "accurate").
    public var speakerQuality: String?
    public var choices: ModelChoiceTable

    public init(id: String, speakerQuality: String? = nil, choices: ModelChoiceTable) {
        self.id = id; self.speakerQuality = speakerQuality; self.choices = choices
    }
}

/// Which preset each device tier starts with.
public struct ModelRecommendedPreset: Equatable, Sendable {
    public var `default`: String
    public var tiers: [String: String]
    public init(default value: String, tiers: [String: String] = [:]) { self.default = value; self.tiers = tiers }
}

// MARK: - Reading

public enum ModelManifestError: LocalizedError, Equatable {
    /// The file declares that this build can't interpret it.
    case needsNewerDaybook(minimumReaderVersion: Int)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .needsNewerDaybook: return "This model list needs a newer Daybook."
        case .unreadable(let reason): return "The model list couldn’t be read: \(reason)"
        }
    }
}

/// Reads and writes manifests, collecting what it had to skip.
public enum ModelManifestReader {
    public struct Result: Sendable {
        public var manifest: ModelManifest
        /// Entries skipped and other things a reader should know, in plain words.
        public var warnings: [String]
        public init(manifest: ModelManifest, warnings: [String] = []) { self.manifest = manifest; self.warnings = warnings }
    }

    public static func read(_ data: Data) throws -> Result {
        let collector = WarningCollector()
        let decoder = JSONDecoder()
        decoder.userInfo[WarningCollector.key] = collector
        let manifest: ModelManifest
        do { manifest = try decoder.decode(ModelManifest.self, from: data) }
        catch let error as ModelManifestError { throw error }
        catch { throw ModelManifestError.unreadable(String(describing: error)) }
        var warnings = collector.messages
        if manifest.schemaVersion > ModelManifest.readerVersion {
            warnings.insert("The model list uses schema \(manifest.schemaVersion); this Daybook reads what schema \(ModelManifest.readerVersion) defines and ignores the rest.", at: 0)
        }
        return Result(manifest: manifest, warnings: warnings)
    }

    /// Stable, readable JSON: sorted keys and indentation, so diffs of the user manifest stay small.
    public static func encode(_ manifest: ModelManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
}

/// Shared by every decoder of one read, so nested entries can report what they skipped.
final class WarningCollector: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "daybook.modelManifest.warnings")!
    private let lock = NSLock()
    private var stored: [String] = []
    var messages: [String] { lock.withLock { stored } }
    func add(_ message: String) { lock.withLock { stored.append(message) } }
    static func report(_ message: String, in decoder: Decoder) { (decoder.userInfo[key] as? WarningCollector)?.add(message) }
}

/// Decodes each element on its own, skipping (and reporting) the ones that fail.
struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var index = 0
        while !container.isAtEnd {
            do { elements.append(try container.decode(Element.self)) }
            catch {
                // A failed element doesn't advance the container; consume it as anything.
                _ = try? container.decode(AnyValue.self)
                WarningCollector.report("Skipped \(String(describing: Element.self)) #\(index + 1) at \(Self.path(decoder.codingPath)): \(Self.describe(error))", in: decoder)
            }
            index += 1
        }
    }

    static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.isEmpty ? "the top level" : codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context): return "unexpected value at \(path(context.codingPath))"
        case DecodingError.dataCorrupted(let context): return context.debugDescription
        default: return error.localizedDescription
        }
    }
}

/// Accepts any JSON value; used to step over unreadable entries.
struct AnyValue: Decodable { init(from decoder: Decoder) throws {} }

/// Identifiers become folder names (`Models/<engine>/<family>/<variant>/<revision>/`), so they are
/// restricted to a safe alphabet.
enum ManifestValidation {
    static func identifier(_ value: String, _ what: String, _ decoder: Decoder) throws -> String {
        guard isSafeIdentifier(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsafe \(what) “\(value)”"))
        }
        return value
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.count), value != ".", value != "..", let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// A relative path inside a repository: no absolute paths, no "..", no empty components.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

// MARK: - Codable

extension ModelManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, minimumReaderVersion, catalogVersion, families, presets, recommendedPreset, initialSelection, liveSelection
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? values.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        minimumReaderVersion = (try? values.decodeIfPresent(Int.self, forKey: .minimumReaderVersion)) ?? 1
        guard minimumReaderVersion <= ModelManifest.readerVersion else {
            throw ModelManifestError.needsNewerDaybook(minimumReaderVersion: minimumReaderVersion)
        }
        catalogVersion = try? values.decodeIfPresent(String.self, forKey: .catalogVersion)
        families = (try values.decodeIfPresent(LossyList<ModelFamilyEntry>.self, forKey: .families))?.elements ?? []
        presets = (try? values.decodeIfPresent(LossyList<ModelPresetEntry>.self, forKey: .presets))?.elements ?? []
        recommendedPreset = (try? values.decodeIfPresent(ModelRecommendedPreset.self, forKey: .recommendedPreset)) ?? nil
        initialSelection = (try? values.decodeIfPresent(ModelChoiceTable.self, forKey: .initialSelection)) ?? nil
        liveSelection = (try? values.decodeIfPresent(ModelChoiceTable.self, forKey: .liveSelection)) ?? nil
        // Duplicate family IDs: the first wins.
        var seen = Set<String>()
        families = families.filter { family in
            guard seen.insert(family.id).inserted else {
                WarningCollector.report("Skipped a second family “\(family.id)”.", in: decoder); return false
            }
            return true
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(minimumReaderVersion, forKey: .minimumReaderVersion)
        try values.encodeIfPresent(catalogVersion, forKey: .catalogVersion)
        try values.encode(families, forKey: .families)
        if !presets.isEmpty { try values.encode(presets, forKey: .presets) }
        try values.encodeIfPresent(recommendedPreset, forKey: .recommendedPreset)
        try values.encodeIfPresent(initialSelection, forKey: .initialSelection)
        try values.encodeIfPresent(liveSelection, forKey: .liveSelection)
    }
}

extension ModelFamilyEntry: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, maker, engine, roles, summary, homepage, license, variants }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try ManifestValidation.identifier(try values.decode(String.self, forKey: .id), "family ID", decoder)
        name = try values.decode(String.self, forKey: .name)
        maker = try? values.decodeIfPresent(String.self, forKey: .maker)
        engine = (try? values.decodeIfPresent(ModelEngineID.self, forKey: .engine)) ?? nil
        roles = (try? values.decodeIfPresent([ModelRole].self, forKey: .roles)) ?? []
        summary = try? values.decodeIfPresent(String.self, forKey: .summary)
        homepage = try? values.decodeIfPresent(String.self, forKey: .homepage)
        license = (try? values.decodeIfPresent(ModelLicense.self, forKey: .license)) ?? nil
        var variants = (try values.decodeIfPresent(LossyList<ModelVariantEntry>.self, forKey: .variants))?.elements ?? []
        var seen = Set<String>()
        let familyID = id
        variants = variants.filter { variant in
            guard seen.insert(variant.id).inserted else {
                WarningCollector.report("Skipped a second variant “\(familyID)/\(variant.id)”.", in: decoder); return false
            }
            return true
        }
        self.variants = variants
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(maker, forKey: .maker)
        try values.encodeIfPresent(engine, forKey: .engine)
        if !roles.isEmpty { try values.encode(roles, forKey: .roles) }
        try values.encodeIfPresent(summary, forKey: .summary)
        try values.encodeIfPresent(homepage, forKey: .homepage)
        try values.encodeIfPresent(license, forKey: .license)
        try values.encode(variants, forKey: .variants)
    }
}

extension ModelVariantEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, detail, engine, roles, license, homepage, releaseDate, recommendedMemoryGB, quality, capabilities, engineOptions
        case minimumAppVersion, minimumEngineVersion, supersedes, supersededBy, systemProvided, revisions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try ManifestValidation.identifier(try values.decode(String.self, forKey: .id), "variant ID", decoder)
        name = try values.decode(String.self, forKey: .name)
        detail = try? values.decodeIfPresent(String.self, forKey: .detail)
        engine = (try? values.decodeIfPresent(ModelEngineID.self, forKey: .engine)) ?? nil
        roles = (try? values.decodeIfPresent([ModelRole].self, forKey: .roles)) ?? nil
        license = (try? values.decodeIfPresent(ModelLicense.self, forKey: .license)) ?? nil
        homepage = try? values.decodeIfPresent(String.self, forKey: .homepage)
        releaseDate = try? values.decodeIfPresent(String.self, forKey: .releaseDate)
        recommendedMemoryGB = try? values.decodeIfPresent(Int.self, forKey: .recommendedMemoryGB)
        // Ranks outside 0–100 are dropped one by one; a map that can't be read at all leaves the model unranked.
        quality = ((try? values.decodeIfPresent([String: Int].self, forKey: .quality)) ?? [:]).filter { (0...100).contains($0.value) }
        capabilities = (try? values.decodeIfPresent(ModelCapabilities.self, forKey: .capabilities)) ?? .init()
        engineOptions = (try? values.decodeIfPresent([String: String].self, forKey: .engineOptions)) ?? [:]
        minimumAppVersion = try? values.decodeIfPresent(String.self, forKey: .minimumAppVersion)
        // A minimum this build can't parse is treated as unmet rather than ignored.
        if values.contains(.minimumEngineVersion), (try? values.decode(Int.self, forKey: .minimumEngineVersion)) == nil {
            minimumEngineVersion = Int.max
        } else {
            minimumEngineVersion = try? values.decodeIfPresent(Int.self, forKey: .minimumEngineVersion)
        }
        supersedes = (try? values.decodeIfPresent([String].self, forKey: .supersedes)) ?? []
        supersededBy = try? values.decodeIfPresent(String.self, forKey: .supersededBy)
        systemProvided = (try? values.decodeIfPresent(Bool.self, forKey: .systemProvided)) ?? false
        var revisions = (try values.decodeIfPresent(LossyList<ModelRevisionEntry>.self, forKey: .revisions))?.elements ?? []
        var seen = Set<String>()
        revisions = revisions.filter { seen.insert($0.id).inserted }
        self.revisions = revisions
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(detail, forKey: .detail)
        try values.encodeIfPresent(engine, forKey: .engine)
        try values.encodeIfPresent(roles, forKey: .roles)
        try values.encodeIfPresent(license, forKey: .license)
        try values.encodeIfPresent(homepage, forKey: .homepage)
        try values.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try values.encodeIfPresent(recommendedMemoryGB, forKey: .recommendedMemoryGB)
        if !quality.isEmpty { try values.encode(quality, forKey: .quality) }
        if capabilities != .init() { try values.encode(capabilities, forKey: .capabilities) }
        if !engineOptions.isEmpty { try values.encode(engineOptions, forKey: .engineOptions) }
        try values.encodeIfPresent(minimumAppVersion, forKey: .minimumAppVersion)
        try values.encodeIfPresent(minimumEngineVersion, forKey: .minimumEngineVersion)
        if !supersedes.isEmpty { try values.encode(supersedes, forKey: .supersedes) }
        try values.encodeIfPresent(supersededBy, forKey: .supersededBy)
        if systemProvided { try values.encode(systemProvided, forKey: .systemProvided) }
        try values.encode(revisions, forKey: .revisions)
    }
}

extension ModelRevisionEntry: Codable {
    private enum CodingKeys: String, CodingKey { case id, releaseDate, summary, artifacts, legacy }

    /// Strict inside: a revision missing any artifact or file can't be installed, so it is skipped whole.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try ManifestValidation.identifier(try values.decode(String.self, forKey: .id), "revision ID", decoder)
        releaseDate = try? values.decodeIfPresent(String.self, forKey: .releaseDate)
        summary = try? values.decodeIfPresent(String.self, forKey: .summary)
        artifacts = try values.decode([ModelArtifact].self, forKey: .artifacts)
        guard Set(artifacts.map(\.name)).count == artifacts.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Two artifacts share a name"))
        }
        legacy = (try? values.decodeIfPresent(ModelLegacyInstall.self, forKey: .legacy)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try values.encodeIfPresent(summary, forKey: .summary)
        try values.encode(artifacts, forKey: .artifacts)
        try values.encodeIfPresent(legacy, forKey: .legacy)
    }
}

extension ModelArtifact: Codable {
    private enum CodingKeys: String, CodingKey { case name, repository, revision, include, root, track, files }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try ManifestValidation.identifier(try values.decode(String.self, forKey: .name), "artifact name", decoder)
        repository = try values.decode(String.self, forKey: .repository)
        revision = try values.decode(String.self, forKey: .revision)
        include = (try? values.decodeIfPresent([String].self, forKey: .include)) ?? []
        root = try values.decodeIfPresent(String.self, forKey: .root)
        track = try? values.decodeIfPresent(String.self, forKey: .track)
        files = try values.decode([ModelFile].self, forKey: .files)
        let repositoryParts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard repositoryParts.count == 2, repositoryParts.allSatisfy({ ManifestValidation.isSafeIdentifier(String($0)) }),
              !revision.isEmpty, !files.isEmpty, root.map(ManifestValidation.isSafeRelativePath) ?? true,
              Set(files.map(\.path)).count == files.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsafe or empty artifact “\(name)”"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(repository, forKey: .repository)
        try values.encode(revision, forKey: .revision)
        if !include.isEmpty { try values.encode(include, forKey: .include) }
        try values.encodeIfPresent(root, forKey: .root)
        try values.encodeIfPresent(track, forKey: .track)
        try values.encode(files, forKey: .files)
    }
}

extension ModelFile: Codable {
    private enum CodingKeys: String, CodingKey { case path, size, sha256, gitOID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        size = try values.decode(Int64.self, forKey: .size)
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)?.lowercased()
        gitOID = try values.decodeIfPresent(String.self, forKey: .gitOID)?.lowercased()
        func hex(_ value: String?, _ count: Int) -> Bool { value.map { $0.count == count && $0.allSatisfy(\.isHexDigit) } ?? true }
        guard ManifestValidation.isSafeRelativePath(path), size >= 0, hex(sha256, 64), hex(gitOID, 40) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsafe file entry “\(path)”"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(size, forKey: .size)
        try values.encodeIfPresent(sha256, forKey: .sha256)
        try values.encodeIfPresent(gitOID, forKey: .gitOID)
    }
}

extension ModelLegacyInstall: Codable {}

extension ModelLicense: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, url, allowsCommercialUse, attribution }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try? values.decodeIfPresent(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        url = (try? values.decodeIfPresent(String.self, forKey: .url)) ?? ""
        // Unknown terms are treated as non-commercial until someone checks them.
        allowsCommercialUse = (try? values.decodeIfPresent(Bool.self, forKey: .allowsCommercialUse)) ?? false
        attribution = try? values.decodeIfPresent(String.self, forKey: .attribution)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(url, forKey: .url)
        try values.encode(allowsCommercialUse, forKey: .allowsCommercialUse)
        try values.encodeIfPresent(attribution, forKey: .attribution)
    }
}

extension ModelCapabilities: Codable {
    private enum CodingKeys: String, CodingKey {
        case wordTimestamps, wordConfidence, languages, vocabularyPrompt, maxSpeakers, voiceEmbeddings, expectedSpeakerCount
        case contextLength, structuredOutput, streaming, memoryGB, realTimeFactor, imageInput
    }

    /// Each field on its own: one a newer manifest types differently is dropped, not the variant.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { (try? values.decodeIfPresent(type, forKey: key)) ?? nil }
        wordTimestamps = optional(Bool.self, .wordTimestamps)
        wordConfidence = optional(Bool.self, .wordConfidence)
        languages = optional([String].self, .languages)
        vocabularyPrompt = optional(Bool.self, .vocabularyPrompt)
        maxSpeakers = optional(Int.self, .maxSpeakers)
        voiceEmbeddings = optional(VoiceEmbeddingSpace.self, .voiceEmbeddings)
        expectedSpeakerCount = optional(Bool.self, .expectedSpeakerCount)
        contextLength = optional(Int.self, .contextLength)
        structuredOutput = optional(Bool.self, .structuredOutput)
        streaming = optional(Bool.self, .streaming)
        memoryGB = optional(Double.self, .memoryGB)
        realTimeFactor = optional(Double.self, .realTimeFactor)
        imageInput = optional(Bool.self, .imageInput)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(wordTimestamps, forKey: .wordTimestamps)
        try values.encodeIfPresent(wordConfidence, forKey: .wordConfidence)
        try values.encodeIfPresent(languages, forKey: .languages)
        try values.encodeIfPresent(vocabularyPrompt, forKey: .vocabularyPrompt)
        try values.encodeIfPresent(maxSpeakers, forKey: .maxSpeakers)
        try values.encodeIfPresent(voiceEmbeddings, forKey: .voiceEmbeddings)
        try values.encodeIfPresent(expectedSpeakerCount, forKey: .expectedSpeakerCount)
        try values.encodeIfPresent(contextLength, forKey: .contextLength)
        try values.encodeIfPresent(structuredOutput, forKey: .structuredOutput)
        try values.encodeIfPresent(streaming, forKey: .streaming)
        try values.encodeIfPresent(memoryGB, forKey: .memoryGB)
        try values.encodeIfPresent(realTimeFactor, forKey: .realTimeFactor)
        try values.encodeIfPresent(imageInput, forKey: .imageInput)
    }
}

extension ModelChoiceTable: Codable {
    private enum CodingKeys: String, CodingKey { case roles, tiers, platforms, platformTiers }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roles = (try? values.decodeIfPresent([String: [String]].self, forKey: .roles)) ?? [:]
        tiers = (try? values.decodeIfPresent([String: [String: [String]]].self, forKey: .tiers)) ?? [:]
        platforms = (try? values.decodeIfPresent([String: [String: [String]]].self, forKey: .platforms)) ?? [:]
        platformTiers = (try? values.decodeIfPresent([String: [String: [String: [String]]]].self, forKey: .platformTiers)) ?? [:]
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(roles, forKey: .roles)
        if !tiers.isEmpty { try values.encode(tiers, forKey: .tiers) }
        if !platforms.isEmpty { try values.encode(platforms, forKey: .platforms) }
        if !platformTiers.isEmpty { try values.encode(platformTiers, forKey: .platformTiers) }
    }
}

extension ModelPresetEntry: Codable {
    private enum CodingKeys: String, CodingKey { case id, speakerQuality, roles, tiers }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        speakerQuality = try? values.decodeIfPresent(String.self, forKey: .speakerQuality)
        choices = try ModelChoiceTable(from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(speakerQuality, forKey: .speakerQuality)
        try choices.encode(to: encoder)
    }
}

extension ModelRecommendedPreset: Codable {
    private enum CodingKeys: String, CodingKey { case `default`, tiers }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        `default` = try values.decode(String.self, forKey: .default)
        tiers = (try? values.decodeIfPresent([String: String].self, forKey: .tiers)) ?? [:]
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(`default`, forKey: .default)
        if !tiers.isEmpty { try values.encode(tiers, forKey: .tiers) }
    }
}
