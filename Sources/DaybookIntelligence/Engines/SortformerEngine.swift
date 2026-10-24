import DaybookCore
import DaybookKit
import FluidAudio
import Foundation

/// NVIDIA Sortformer v2.1 (offline, four speaker slots) through FluidAudio, applied to bounded
/// windows by `BoundedSortformer`. No voice embeddings. The manifest's `engineOptions["precision"]`
/// says which Core ML export the "model" artifact holds: "palettized" or "fp16".
public struct SortformerEngine: ModelEngine {
    public init() {}

    public let descriptor = ModelEngineDescriptor(
        id: .sortformer, name: "FluidAudio Sortformer", version: 1, runtime: "FluidAudio 0.17.7",
        roles: [.diarization], platforms: [.macOS, .iOS], residency: .shared)

    public func validate(_ installation: ModelInstallation) throws {
        try require(["coremldata.bin", "model.mil"], in: "model", of: installation)
    }

    /// `subdirectory` names the compiled model bundle ("v3/fp16/SortformerOffline_v2.1.mlmodelc");
    /// `precision` defaults from its path.
    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        guard let folder = request.options["subdirectory"]?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              folder.hasSuffix(".mlmodelc") else {
            throw ModelAdditionError.invalid(["Name the Sortformer bundle to use (a folder ending in .mlmodelc)."])
        }
        guard repository.contains(folder + "/coremldata.bin"), repository.contains(folder + "/model.mil") else {
            throw ModelAdditionError.invalid(["\(folder) isn’t a compiled Core ML model in \(repository.repository)."])
        }
        let precision = request.options["precision"] ?? (folder.contains("palettized") ? "palettized" : "fp16")
        guard ["palettized", "fp16"].contains(precision) else {
            throw ModelAdditionError.invalid(["Sortformer precision must be palettized or fp16."])
        }
        return ModelAdditionProposal(artifacts: [try repository.artifact("model", include: [folder + "/*"], root: folder)],
                                     capabilities: ModelCapabilities(maxSpeakers: 4, expectedSpeakerCount: false, streaming: false),
                                     engineOptions: ["precision": precision], recommendedMemoryGB: 8)
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        progress(.init(0, "Loading Sortformer locally"))
        let precision: ModelNames.Sortformer.ModelPrecision = installation.engineOptions["precision"] == "palettized" ? .palettized : .fp16
        let models = try await OfflineSortformerModels.load(config: .init(precision: precision), modelPath: installation.folder(for: "model"))
        return SortformerDiarizer(models: models)
    }
}

final class SortformerDiarizer: Diarizing, @unchecked Sendable {
    let models: OfflineSortformerModels
    init(models: OfflineSortformerModels) { self.models = models }

    func diarize(url: URL, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
        try BoundedSortformer.process(url: url, models: models, options: options, progress: progress)
    }
}
