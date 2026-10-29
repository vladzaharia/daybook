import DaybookKit
import DaybookLive
import Foundation

/// Nemotron 3.5 ASR Streaming, for live captions (`liveTranscription`). Registered so the Mac's
/// model manager can download, check, and remove its bundles like any model; the runtime never loads
/// it, because live captions load their models through DaybookLive's `LiveModelHost`, beside the
/// recording, rather than waiting behind the processing queue (docs/model-runtime.md, "Live").
public struct NemotronStreamingEngine: ModelEngine {
    public init() {}

    public var descriptor: ModelEngineDescriptor { LiveEngines.streamingTranscription }

    public func validate(_ installation: ModelInstallation) throws {
        do { try LiveEngines.validate(installation, role: .liveTranscription) }
        catch { throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey) }
    }

    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        throw ModelAdditionError.invalid(["Live transcription models come with Daybook’s model list."])
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        throw LocalIntelligenceError.unsupportedRole(model: installation.key.variantKey, role: role.rawValue)
    }
}
