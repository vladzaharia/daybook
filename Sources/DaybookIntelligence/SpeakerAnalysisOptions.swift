import Foundation
import FluidAudio

/// Processing presets change inference work, not the downloaded weights.
public enum SpeakerQuality: String, Codable, CaseIterable, Sendable {
    case fast, balanced, accurate

    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Detailed"
        }
    }

    public var detail: String {
        switch self {
        case .fast: return "Reuse similar voice embeddings or use less window overlap to reduce processing."
        case .balanced: return "Standard analysis with the selected model’s recommended settings."
        case .accurate: return "Analyze more overlapping windows and refine ambiguous turns. Takes longer; accuracy still depends on the recording."
        }
    }
}

public struct SpeakerAnalysisOptions: Codable, Equatable, Sendable {
    public var quality: SpeakerQuality = .balanced
    /// A clustering target for Community-1, not a guaranteed number of output speakers.
    public var expectedSpeakerCount: Int? = nil

    public var normalized: Self {
        var value = self
        value.expectedSpeakerCount = expectedSpeakerCount.flatMap { (1...32).contains($0) ? $0 : nil }
        return value
    }

    public func communityConfiguration() -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        switch quality {
        case .fast:
            config.embedding.skipStrategy = .maskSimilarity(threshold: 0.95)
        case .balanced:
            break
        case .accurate:
            config.segmentation.stepRatio = 0.1
            config.embedding.minSegmentDurationSeconds = 0.5
            config.vbx.maxIterations = 40
            config.zeroVoteReembed.enabled = true
        }
        config.clustering.numSpeakers = normalized.expectedSpeakerCount
        return config
    }

    public var sortformerOverlapFrames: Int {
        switch quality {
        case .fast: return 50      // Four seconds
        case .balanced: return 100 // Eight seconds, upstream default
        case .accurate: return 200 // Sixteen seconds
        }
    }

    public init(quality: SpeakerQuality = .balanced, expectedSpeakerCount: Int? = nil) {
        self.quality = quality
        self.expectedSpeakerCount = expectedSpeakerCount
    }
}
