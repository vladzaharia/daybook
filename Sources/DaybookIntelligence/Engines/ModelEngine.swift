import DaybookCore
import DaybookKit
import Foundation

/// Code that knows how to check, load, and run one kind of model (docs/models.md, "Engines").
/// Models are data in manifests; an engine is needed only when no existing one can run a model.
/// Adding one is one conforming type, one line in `ModelEngineRegistry.standard`, and its tests.
public protocol ModelEngine: Sendable {
    /// Identity, version, roles, platforms, and residency.
    var descriptor: ModelEngineDescriptor { get }

    /// Cheap check before every load: what loading needs beyond the verified files (the Core ML
    /// bundles, a tokenizer). Throws `LocalIntelligenceError.modelNotInstalled` when unusable.
    func validate(_ installation: ModelInstallation) throws

    /// The deeper check run once, on a freshly downloaded or migrated install before it counts
    /// (for example, that the tokenizer parses). Defaults to `validate`.
    func verifyNewInstallation(_ installation: ModelInstallation) async throws

    /// For a model someone adds from Hugging Face: which files to fetch, as artifacts, and what the
    /// variant can do. Throws `ModelAdditionError.invalid` with the reasons it can't run.
    func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal

    /// Loads an install to serve `role`. The returned model conforms to that role's protocol.
    func load(_ installation: ModelInstallation, role: ModelRole,
              progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel
}

extension ModelEngine {
    public func verifyNewInstallation(_ installation: ModelInstallation) async throws { try validate(installation) }

    /// Throws `modelNotInstalled` unless every path exists under the artifact's folder.
    func require(_ paths: [String], in artifact: String, of installation: ModelInstallation) throws {
        let folder = installation.folder(for: artifact)
        for path in paths where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) {
            throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey)
        }
    }
}

/// A model in memory. The runtime keeps at most one per role and calls `unload` before dropping it.
/// Small tasks' protocol, `PerformingSmallTasks`, is in SmallTasks.swift.
public protocol LoadedModel: AnyObject, Sendable {
    /// Releases caches that outlive the object (the MLX buffer cache).
    func unload()
}

extension LoadedModel {
    public func unload() {}
}

/// Speech to timed words.
public protocol Transcribing: LoadedModel {
    func transcribe(url: URL, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult
    /// The same in a known language (a BCP-47 code such as "de"); nil detects it. Transcribers that
    /// can't take a language hint use the default, which ignores it.
    func transcribe(url: URL, glossary: [String], language: String?,
                    progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult
}

extension Transcribing {
    public func transcribe(url: URL, glossary: [String], language: String?,
                           progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        try await transcribe(url: url, glossary: glossary, progress: progress)
    }
}

/// Who spoke when. A diarizer whose capabilities declare `voiceEmbeddings` returns them with its turns.
public protocol Diarizing: LoadedModel {
    func diarize(url: URL, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis
}

/// Voice profiles for speaker turns another model found (Nemotron's turns, embedded with WeSpeaker).
public protocol EmbeddingVoices: LoadedModel {
    /// `analysis`'s turns with an embedding per speaker and the embedding space's identity.
    func embedVoices(url: URL, analysis: SpeakerAnalysis, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis
}

/// Meeting notes from a transcript.
public protocol Summarizing: LoadedModel {
    func summarize(_ request: SummaryRequest, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes
}

/// What a summary is made from.
public struct SummaryRequest: Sendable {
    public var transcript: String
    public var notes: String
    public var template: MeetingKind
    public var glossary: [String]
    public var templateInstructions: String?
    public var highlightEvidence: String?
    /// What the summary records as its model: the variant key.
    public var modelID: String

    public init(transcript: String, notes: String, template: MeetingKind = .auto, glossary: [String] = [],
                templateInstructions: String? = nil, highlightEvidence: String? = nil, modelID: String) {
        self.transcript = transcript; self.notes = notes; self.template = template; self.glossary = glossary
        self.templateInstructions = templateInstructions; self.highlightEvidence = highlightEvidence; self.modelID = modelID
    }
}

/// Every engine this build can run, by ID.
public struct ModelEngineRegistry: Sendable {
    public private(set) var engines: [any ModelEngine]

    public init(_ engines: [any ModelEngine]) {
        self.engines = []
        for engine in engines { register(engine) }
    }

    /// The engines Daybook ships. Adding an engine means adding it here.
    public static var standard: ModelEngineRegistry {
        ModelEngineRegistry([
            WhisperKitEngine(),
            Community1Engine(),
            SortformerEngine(),
            MLXLanguageEngine(),
            ParakeetEngine(),
            NemotronDiarizerEngine(),
            AppleFoundationModelsEngine()
        ])
    }

    /// Adds an engine, replacing one with the same ID.
    public mutating func register(_ engine: any ModelEngine) {
        engines.removeAll { $0.descriptor.id == engine.descriptor.id }
        engines.append(engine)
    }

    public func registering(_ engine: any ModelEngine) -> ModelEngineRegistry {
        var copy = self
        copy.register(engine)
        return copy
    }

    public func engine(_ id: ModelEngineID) -> (any ModelEngine)? { engines.first { $0.descriptor.id == id } }

    /// What the catalog needs to decide availability ("Needs a newer Daybook").
    public var descriptors: [ModelEngineDescriptor] { engines.map(\.descriptor) }
}
