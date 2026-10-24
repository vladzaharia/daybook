import Foundation
import DaybookCore
import DaybookKit

// What the engines return. The catalog of models itself is data: DaybookKit's ModelCatalog folder
// (docs/models.md).

public struct IntelligenceProgress: Sendable {
    public let fraction: Double
    public let message: String
    public init(_ fraction: Double, _ message: String) {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        self.message = message
    }
}

public typealias IntelligenceProgressHandler = @Sendable (IntelligenceProgress) -> Void

public struct RecognizedWord: Codable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public let confidence: Double

    public init(text: String, start: Double, end: Double, confidence: Double) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct RecognizedSegment: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let confidence: Double
    public let words: [RecognizedWord]

    public init(start: Double, end: Double, text: String, confidence: Double, words: [RecognizedWord]) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.words = words
    }
}

public struct RecognitionResult: Sendable {
    public let segments: [RecognizedSegment]
    public let language: String?
    public let duration: Double
    /// The exact model that produced it; the runtime fills this in.
    public var provenance: ModelProvenance?

    public init(segments: [RecognizedSegment], language: String?, duration: Double, provenance: ModelProvenance? = nil) {
        self.segments = segments
        self.language = language
        self.duration = duration
        self.provenance = provenance
    }
}

public struct SpeakerTurn: Sendable {
    public let speakerID: String
    public let start: Double
    public let end: Double
    public let confidence: Double

    public init(speakerID: String, start: Double, end: Double, confidence: Double) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct SpeakerAnalysis: Sendable {
    public let turns: [SpeakerTurn]
    public var embeddings: [String: [Float]]
    /// Nil when the selected pipeline does not produce reusable voice profiles.
    public var embeddingModelID: String? = nil
    public var warnings: [String] = []
    /// The diarizer that found the turns; the runtime fills this in.
    public var provenance: ModelProvenance?
    /// The model that embedded the voices, when it isn't the diarizer.
    public var embeddingProvenance: ModelProvenance?

    public init(turns: [SpeakerTurn], embeddings: [String: [Float]], embeddingModelID: String? = nil, warnings: [String] = [],
                provenance: ModelProvenance? = nil, embeddingProvenance: ModelProvenance? = nil) {
        self.turns = turns
        self.embeddings = embeddings
        self.embeddingModelID = embeddingModelID
        self.warnings = warnings
        self.provenance = provenance
        self.embeddingProvenance = embeddingProvenance
    }
}

public struct GeneratedMeetingNotes: Sendable {
    public let summary: MeetingSummary
    public let suggestedTerms: [String]
    /// Preserved for audit and recovery if the model returned malformed structured data.
    public let rawResponse: String
    public let warnings: [String]
    /// The exact model that wrote it; the runtime fills this in.
    public var provenance: ModelProvenance?
    /// How long loading and generating took, where the engine measures it (MLX); for diagnostics.
    public var statistics: GenerationStatistics?

    public init(summary: MeetingSummary, suggestedTerms: [String], rawResponse: String, warnings: [String],
                provenance: ModelProvenance? = nil, statistics: GenerationStatistics? = nil) {
        self.summary = summary
        self.suggestedTerms = suggestedTerms
        self.rawResponse = rawResponse
        self.warnings = warnings
        self.provenance = provenance
        self.statistics = statistics
    }
}

/// Token counts and timings for one summary, across its passes. Free-form passes report prompt
/// processing and generation separately; constrained (guided) passes are timed whole.
public struct GenerationStatistics: Codable, Equatable, Sendable {
    /// Loading the model's weights and tokenizer, once per load.
    public var loadSeconds: Double?
    public var passes = 0
    public var constrainedPasses = 0
    public var promptTokens = 0
    public var promptSeconds: Double = 0
    public var generatedTokens = 0
    public var generationSeconds: Double = 0
    /// Constrained passes: prompt plus generated tokens, and their time together.
    public var constrainedTokens = 0
    public var constrainedSeconds: Double = 0

    public init() {}

    public var promptTokensPerSecond: Double? { promptSeconds > 0 ? Double(promptTokens) / promptSeconds : nil }
    public var generatedTokensPerSecond: Double? { generationSeconds > 0 ? Double(generatedTokens) / generationSeconds : nil }
}

public enum LocalIntelligenceError: LocalizedError {
    case unknownModel(String), modelNotInstalled(String), busy, invalidAudio, invalidTokenizer(String), emptyResponse, invalidSpeakerOutput
    /// The model's engine can't serve the role asked of it.
    case unsupportedRole(model: String, role: String)
    /// The catalog lists the model, but this build can't run it.
    case unavailable(model: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Unknown model: \(id)."
        case .modelNotInstalled(let id): return "Download \(ModelCatalog.builtIn.name(for: id)) in Models before processing."
        case .busy: return "Another model operation is running. Wait for it to finish or cancel it."
        case .invalidAudio: return "The recording has no readable audio."
        case .invalidTokenizer(let token): return "The local tokenizer is incomplete (\(token)). Remove and download this model again."
        case .emptyResponse: return "The local model returned no summary. Try a larger model or shorten the notes."
        case .invalidSpeakerOutput: return "The local speaker model returned invalid predictions. Try another speaker model."
        case .unsupportedRole(let model, let role): return "\(ModelCatalog.builtIn.name(for: model)) can’t be used for \(role). Choose another model."
        case .unavailable(let model, let reason): return "\(ModelCatalog.builtIn.name(for: model)): \(reason)."
        }
    }
}
