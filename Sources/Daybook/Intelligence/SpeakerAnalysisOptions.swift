import Foundation
import FluidAudio

/// Processing presets change inference work, not the downloaded weights.
enum SpeakerQuality: String, Codable, CaseIterable, Sendable {
    case fast, balanced, accurate

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Detailed"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "Reuse similar voice embeddings or use less window overlap to reduce processing."
        case .balanced: return "Standard analysis with the selected model's recommended settings."
        case .accurate: return "Analyze more overlapping windows and refine ambiguous turns. Takes longer; accuracy still depends on the recording."
        }
    }
}

struct SpeakerAnalysisOptions: Codable, Equatable, Sendable {
    var quality: SpeakerQuality = .balanced
    /// A clustering target for Community-1, not a guaranteed number of output speakers.
    var expectedSpeakerCount: Int? = nil

    var normalized: Self {
        var value = self
        value.expectedSpeakerCount = expectedSpeakerCount.flatMap { (1...32).contains($0) ? $0 : nil }
        return value
    }

    func communityConfiguration() -> OfflineDiarizerConfig {
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

    var sortformerOverlapFrames: Int {
        switch quality {
        case .fast: return 50      // Four seconds
        case .balanced: return 100 // Eight seconds, upstream default
        case .accurate: return 200 // Sixteen seconds
        }
    }
}
