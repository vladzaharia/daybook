import DaybookKit
import DaybookModelStore
import FluidAudio
import Foundation

/// The engines live captions run (docs/models.md, "Live models"), as the catalog sees them, and the
/// checks an install must pass before they load it. The Mac registers these engines' processing
/// counterparts in DaybookIntelligence; the iPhone, which runs no processing engines, reads its
/// models' availability from `descriptors`.
public enum LiveEngines {
    /// NVIDIA's cache-aware streaming recognizers through FluidAudio
    /// (`StreamingNemotronMultilingualAsrManager`).
    public static let streamingTranscription = ModelEngineDescriptor(
        id: .nemotronStreaming, name: "FluidAudio Nemotron Streaming", version: 1, runtime: "FluidAudio 0.17.7",
        roles: [.liveTranscription], platforms: [.macOS, .iOS], residency: .shared)
    /// Nemotron 3 Diarization's streaming presets (`Nemotron3Diarizer`). The Mac's descriptor for the
    /// same engine also serves final speaker detection.
    public static let speakerDetection = ModelEngineDescriptor(
        id: .nemotronDiarizer, name: "FluidAudio Nemotron 3 Diarization", version: 1, runtime: "FluidAudio 0.17.7",
        roles: [.liveDiarization], platforms: [.macOS, .iOS], residency: .shared)
    /// Community-1's WeSpeaker model, for voice profiles in the space the Mac's profiles use.
    public static let voiceProfiles = ModelEngineDescriptor(
        id: .community1, name: "FluidAudio Community-1", version: 1, runtime: "FluidAudio 0.17.7",
        roles: [.speakerEmbedding], platforms: [.macOS, .iOS], residency: .shared)

    /// What a device that runs only live models can run.
    public static let descriptors = [streamingTranscription, speakerDetection, voiceProfiles]

    /// Throws `LiveModelError.damaged` unless the install has what loading it for `role` needs.
    public static func validate(_ installation: ModelInstallation, role: ModelRole) throws {
        let folder = installation.folder(for: "model")
        let required: [String]
        switch role {
        case .liveTranscription: required = StreamingTranscriptionFiles.required
        case .liveDiarization:
            guard let config = LiveDiarizationPreset.configuration(installation.engineOptions) else {
                throw LiveModelError.damaged(installation.receipt.name)
            }
            required = LiveDiarizationPreset.requiredFiles(config)
        case .speakerEmbedding: required = WeSpeakerEmbedder.requiredFiles
        default: throw LiveModelError.unsupportedRole(role)
        }
        for path in required where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) {
            throw LiveModelError.damaged(installation.receipt.name)
        }
    }

    /// The live role an install serves on this device, from its engine.
    public static func role(of installation: ModelInstallation) -> ModelRole? {
        switch ModelEngineID(installation.key.engine) {
        case .nemotronStreaming: return .liveTranscription
        case .nemotronDiarizer: return .liveDiarization
        case .community1: return .speakerEmbedding
        default: return nil
        }
    }
}

/// The files a Nemotron streaming bundle needs: the encoder, the fused decoder and joint (FluidAudio's
/// default decode path, so the bare decoder and joint aren't downloaded), its metadata (chunk size,
/// language prompts), and the tokenizer. FluidAudio computes the mel features itself.
enum StreamingTranscriptionFiles {
    static let required = ["encoder.mlmodelc/coremldata.bin", "decoder_joint.mlmodelc/coremldata.bin",
                           ModelNames.NemotronMultilingualStreaming.metadata, ModelNames.NemotronMultilingualStreaming.tokenizer]
}

/// Nemotron 3 Diarization for live speakers: `engineOptions["preset"]` names a streaming shape
/// FluidAudio knows ("fast32-split-w8a8", 2.88 s behind the audio), loaded from FluidInference's layout.
enum LiveDiarizationPreset {
    static func configuration(_ options: [String: String]) -> Nemotron3Config? {
        guard var config = Nemotron3Config.preset(named: options["preset"] ?? "fast32-split-w8a8") else { return nil }
        if !config.modelFileName.contains("/") { config.modelFileName = "\(config.hubSubdirectory)/\(config.modelFileName)" }
        return config
    }

    static func requiredFiles(_ config: Nemotron3Config) -> [String] {
        [config.modelFileName + "/coremldata.bin", ModelNames.Nemotron3.silenceEmbeddingFile]
            + (config.splitGraph ? [ModelNames.Nemotron3.preEncodeProjectionFile] : [])
    }
}

/// The models one live capture runs, resolved to verified installs. Any may be missing: without a
/// transcription model the system's recognizer captions; without a speaker model there are no
/// speakers; without a voice-profile model, no names.
public struct LiveModelSet: Sendable {
    public var transcription: ModelInstallation?
    public var diarization: ModelInstallation?
    public var voiceProfiles: ModelInstallation?

    public init(transcription: ModelInstallation? = nil, diarization: ModelInstallation? = nil, voiceProfiles: ModelInstallation? = nil) {
        self.transcription = transcription; self.diarization = diarization; self.voiceProfiles = voiceProfiles
    }

    public var isEmpty: Bool { transcription == nil && diarization == nil }

    /// Each live role's chosen model, when its newest ready revision is installed and checks out.
    /// For transcription, when the chosen model doesn't cover `locale` and one of `alternatives` (the
    /// catalog's other live recognizers, best first) is installed and does, that one runs instead: a
    /// Mac with both the Latin and the multilingual model captions Japanese with the second.
    public static func resolve(_ choices: [ModelRole: String], inventory: ModelInventory, locale: Locale? = nil,
                               alternatives: [String] = []) -> LiveModelSet {
        func installed(_ key: String?, _ role: ModelRole) -> ModelInstallation? {
            guard let key, let revision = inventory.resolve(key) else { return nil }
            return (try? LiveEngines.validate(revision.installation, role: role)) == nil ? nil : revision.installation
        }
        var set = LiveModelSet(transcription: installed(choices[.liveTranscription], .liveTranscription),
                               diarization: installed(choices[.liveDiarization], .liveDiarization),
                               voiceProfiles: installed(choices[.speakerEmbedding], .speakerEmbedding))
        if let locale, !set.transcribes(locale) {
            for key in alternatives where key != choices[.liveTranscription] {
                guard let other = installed(key, .liveTranscription) else { continue }
                var candidate = set
                candidate.transcription = other
                if candidate.transcribes(locale) { set = candidate; break }
            }
        }
        return set
    }

    /// Whether the transcription model covers `locale`'s language (its `languages` capability; nil
    /// or "*" covers every language).
    public func transcribes(_ locale: Locale) -> Bool {
        guard let languages = transcription?.capabilities.languages, !languages.contains("*") else { return transcription != nil }
        guard let code = locale.language.languageCode?.identifier.lowercased() else { return false }
        return languages.contains { $0.lowercased() == code || $0.lowercased().hasPrefix(code + "-") }
    }
}

public enum LiveModelError: LocalizedError, Equatable {
    case damaged(String)
    case unsupportedRole(ModelRole)
    case unsupportedDevice

    public var errorDescription: String? {
        switch self {
        case .damaged(let name): return "\(name) needs downloading again."
        case .unsupportedRole(let role): return "Live captions don’t use models for \(role.rawValue)."
        case .unsupportedDevice: return "Live transcription needs Apple silicon."
        }
    }
}
