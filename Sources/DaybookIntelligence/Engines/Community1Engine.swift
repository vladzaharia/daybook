import CoreML
import DaybookCore
import DaybookKit
import FluidAudio
import Foundation

/// pyannote Community-1 through FluidAudio's offline pipeline: whole-file segmentation, WeSpeaker
/// embeddings, and VBx clustering. Returns turns and a voice embedding per speaker, in the space
/// its manifest entry declares (`capabilities.voiceEmbeddings`). It also makes voice profiles for
/// another diarizer's turns (`speakerEmbedding`, Community1VoiceEmbedder.swift).
public struct Community1Engine: ModelEngine {
    static let bundles = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"]
    static let parameters = "plda-parameters.json"
    /// The space built-in Community-1 embeddings live in, if a manifest entry doesn't say.
    static let defaultEmbeddingSpace = "fluid-community1-embedding-df2625ac79a7ac6b"

    public init() {}

    public let descriptor = ModelEngineDescriptor(
        id: .community1, name: "FluidAudio Community-1", version: 1, runtime: "FluidAudio 0.17.7",
        roles: [.diarization, .speakerEmbedding], platforms: [.macOS, .iOS], residency: .shared)

    public func validate(_ installation: ModelInstallation) throws {
        try require(Self.bundles + [Self.parameters], in: "model", of: installation)
    }

    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        let folder = request.options["subdirectory"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
        let prefix = folder.isEmpty ? "" : folder + "/"
        var problems: [String] = []
        for bundle in Self.bundles where !repository.files.contains(where: { $0.path.hasPrefix(prefix + bundle + "/") }) {
            problems.append("\(prefix + bundle) is missing.")
        }
        if !repository.contains(prefix + Self.parameters) { problems.append("\(prefix + Self.parameters) is missing.") }
        guard problems.isEmpty else { throw ModelAdditionError.invalid(problems) }
        let model = try repository.artifact("model", include: Self.bundles.map { prefix + $0 + "/*" } + [prefix + Self.parameters],
                                            root: folder.isEmpty ? nil : folder)
        // A different conversion is a different embedding space: profiles never compare across it.
        let space = "community1-\(repository.repository.replacingOccurrences(of: "/", with: "-"))-\(repository.commit.id.prefix(16))"
        return ModelAdditionProposal(artifacts: [model],
                                     capabilities: ModelCapabilities(voiceEmbeddings: VoiceEmbeddingSpace(space: space, dimensions: 256),
                                                                     expectedSpeakerCount: true, streaming: false),
                                     recommendedMemoryGB: 8)
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        progress(.init(0, "Loading speaker models locally"))
        let space = installation.capabilities.voiceEmbeddings?.space ?? Self.defaultEmbeddingSpace
        return Community1Diarizer(models: try Self.loadModels(at: installation.folder(for: "model"), id: installation.key.variantKey),
                                  embeddingSpace: space)
    }

    /// Loading Core ML assets directly avoids ModelHub's online repair fallback.
    static func loadModels(at folder: URL, id: String) throws -> OfflineDiarizerModels {
        let started = Date()
        func load(_ name: String, units: MLComputeUnits = .all) throws -> MLModel {
            let config = MLModelConfiguration(); config.computeUnits = units
            return try MLModel(contentsOf: folder.appendingPathComponent(name + ".mlmodelc"), configuration: config)
        }
        let parameters = try JSONDecoder().decode(PLDAParameters.self, from: Data(contentsOf: folder.appendingPathComponent(Self.parameters)))
        guard let bytes = Data(base64Encoded: parameters.tensors.psi.data_base64), bytes.count % 4 == 0, !bytes.isEmpty else {
            throw LocalIntelligenceError.modelNotInstalled(id)
        }
        let psi: [Double] = bytes.withUnsafeBytes { buffer in
            stride(from: 0, to: bytes.count, by: 4).map {
                Double(Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self))))
            }
        }
        return try OfflineDiarizerModels(segmentationModel: load("Segmentation"), fbankModel: load("FBank", units: .cpuOnly),
                                         embeddingModel: load("Embedding"), pldaRhoModel: load("PldaRho"), pldaPsi: psi,
                                         compilationDuration: Date().timeIntervalSince(started))
    }

    private struct PLDAParameters: Decodable {
        struct Tensors: Decodable { let psi: Tensor }
        struct Tensor: Decodable { let data_base64: String }
        let tensors: Tensors
    }
}

/// Loaded Community-1 models. The expensive Core ML models stay cached between runs.
final class Community1Diarizer: Diarizing, @unchecked Sendable {
    let models: OfflineDiarizerModels
    let embeddingSpace: String

    init(models: OfflineDiarizerModels, embeddingSpace: String) { self.models = models; self.embeddingSpace = embeddingSpace }

    func diarize(url: URL, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
        // A fresh manager prevents a previous run's settings or clustering state
        // from leaking into this run.
        let manager = OfflineDiarizerManager(config: options.communityConfiguration())
        manager.initialize(models: models)
        try Task.checkCancellation()
        let result = try await manager.process(url) { completed, total in
            progress(.init(Double(completed) / Double(max(1, total)) * 0.95, "Detecting speaker turns"))
        }
        try Task.checkCancellation()
        progress(.init(1, "Speaker detection complete"))
        return SpeakerAnalysis(turns: result.segments.map {
            .init(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds),
                  confidence: Double($0.qualityScore))
        }, embeddings: result.speakerDatabase ?? [:], embeddingModelID: embeddingSpace)
    }
}
