import Foundation
import DaybookCore

enum LocalModelRole: String, Codable, Sendable { case transcription, summarization, diarization }

struct LocalModelDescriptor: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let role: LocalModelRole
    let approximateBytes: Int64
    let recommendedMemoryGB: Int
    let detail: String
    let repository: String
    let revision: String
    var modelSubdirectory: String? = nil
    var tokenizerRepository: String? = nil
    var tokenizerRevision: String? = nil
}

struct IntelligenceProgress: Sendable {
    let fraction: Double
    let message: String
    init(_ fraction: Double, _ message: String) {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        self.message = message
    }
}

typealias IntelligenceProgressHandler = @Sendable (IntelligenceProgress) -> Void

struct RecognizedWord: Codable, Sendable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Double
}

struct RecognizedSegment: Codable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let confidence: Double
    let words: [RecognizedWord]
}

struct RecognitionResult: Sendable {
    let segments: [RecognizedSegment]
    let language: String?
    let duration: Double
}

struct SpeakerTurn: Sendable {
    let speakerID: String
    let start: Double
    let end: Double
    let confidence: Double
}

struct SpeakerAnalysis: Sendable {
    let turns: [SpeakerTurn]
    let embeddings: [String: [Float]]
    /// Nil when the selected pipeline does not produce reusable voice profiles.
    var embeddingModelID: String? = nil
    var warnings: [String] = []
}

struct GeneratedMeetingNotes: Sendable {
    let summary: MeetingSummary
    let suggestedTerms: [String]
    /// Preserved for audit and recovery if the model returned malformed structured data.
    let rawResponse: String
    let warnings: [String]
}

enum LocalIntelligenceError: LocalizedError {
    case unknownModel(String), modelNotInstalled(String), busy, invalidAudio, invalidTokenizer(String), emptyResponse, invalidSpeakerOutput
    var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Unknown model: \(id)."
        case .modelNotInstalled(let id): return "Download \(id) in Models before processing. No network request was made."
        case .busy: return "Another model operation is running. Wait for it to finish or cancel it."
        case .invalidAudio: return "The recording has no readable audio."
        case .invalidTokenizer(let token): return "The local tokenizer is incomplete (\(token)). Remove and download this model again."
        case .emptyResponse: return "The local model returned no summary. Try a larger model or shorten the notes."
        case .invalidSpeakerOutput: return "The local speaker model returned invalid predictions. Try another speaker model."
        }
    }
}

enum DaybookModelCatalog {
    static let defaultTranscription = "whisper-base"
    static var defaultSummarization: String {
        ProcessInfo.processInfo.physicalMemory >= 16 * 1_024 * 1_024 * 1_024 ? "qwen-7b" : "qwen-1.5b"
    }
    static let diarization = "speaker-community-1"
    static let sortformer = "speaker-sortformer-v2.1"
    static let sortformerCompact = "speaker-sortformer-v2.1-compact"
    static let communityEmbeddingID = "fluid-community1-embedding-df2625ac79a7ac6b"

    static func supportsVoiceMatching(_ modelID: String) -> Bool { modelID == diarization }
    static func supportsExpectedSpeakerCount(_ modelID: String) -> Bool { modelID == diarization }
    static let models: [LocalModelDescriptor] = [
        .init(id: "whisper-base", name: "Whisper Base", role: .transcription,
              approximateBytes: 150_000_000, recommendedMemoryGB: 8, detail: "Fast multilingual transcription; best for clear audio.",
              repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482",
              modelSubdirectory: "openai_whisper-base", tokenizerRepository: "openai/whisper-base",
              tokenizerRevision: "e37978b90ca9030d5170a5c07aadb050351a65bb"),
        .init(id: "whisper-small", name: "Whisper Small", role: .transcription,
              approximateBytes: 500_000_000, recommendedMemoryGB: 8, detail: "More accurate multilingual recognition with moderate memory use.",
              repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482",
              modelSubdirectory: "openai_whisper-small", tokenizerRepository: "openai/whisper-small",
              tokenizerRevision: "973afd24965f72e36ca33b3055d56a652f456b4d"),
        .init(id: "whisper-large-turbo", name: "Whisper Large v3 Turbo", role: .transcription,
              approximateBytes: 650_000_000, recommendedMemoryGB: 16, detail: "Compressed large model for difficult conversations and accents.",
              repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482",
              modelSubdirectory: "openai_whisper-large-v3-v20240930_turbo_632MB", tokenizerRepository: "openai/whisper-large-v3-turbo",
              tokenizerRevision: "41f01f3fe87f28c78e2fbf8b568835947dd65ed9"),
        .init(id: "qwen-1.5b", name: "Qwen 2.5 · 1.5B", role: .summarization,
              approximateBytes: 1_000_000_000, recommendedMemoryGB: 8, detail: "Small, fast summaries. Review detail and speaker attribution carefully.",
              repository: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", revision: "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"),
        .init(id: "qwen-3b", name: "Qwen 2.5 · 3B", role: .summarization,
              approximateBytes: 1_900_000_000, recommendedMemoryGB: 16, detail: "Balanced quality and speed. Qwen Research license; review terms for commercial use.",
              repository: "mlx-community/Qwen2.5-3B-Instruct-4bit", revision: "4f83f8f146fdf28b512a06562b671d7af4fab457"),
        .init(id: "qwen-7b", name: "Qwen 2.5 · 7B", role: .summarization,
              approximateBytes: 4_300_000_000, recommendedMemoryGB: 16, detail: "Recommended for nuanced conversations when memory permits.",
              repository: "mlx-community/Qwen2.5-7B-Instruct-4bit", revision: "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed"),
        .init(id: diarization, name: "Community-1 Speaker Detection", role: .diarization,
              approximateBytes: 25_000_000, recommendedMemoryGB: 8, detail: "Recommended for recorded conversations and reusable voice profiles. Supports an expected speaker count.",
              repository: "FluidInference/speaker-diarization-coreml", revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232"),
        .init(id: sortformerCompact, name: "Sortformer 2.1 · Compact", role: .diarization,
              approximateBytes: 92_000_000, recommendedMemoryGB: 8, detail: "6-bit weights for a smaller download. At most 4 speakers; no voice profile matching. May miss quiet speech.",
              repository: "FluidInference/diar-streaming-sortformer-coreml", revision: "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1",
              modelSubdirectory: "v3/palettized/SortformerOffline_v2.1.mlmodelc"),
        .init(id: sortformer, name: "Sortformer 2.1 · Full Precision", role: .diarization,
              approximateBytes: 242_000_000, recommendedMemoryGB: 8, detail: "FP16 weights for noisy conversations. At most 4 speakers; no voice profile matching. May miss quiet speech.",
              repository: "FluidInference/diar-streaming-sortformer-coreml", revision: "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1",
              modelSubdirectory: "v3/fp16/SortformerOffline_v2.1.mlmodelc")
    ]
}
