import DaybookKit
import Foundation
import FluidAudio

/// What the speaker engines make of the options (DaybookKit's `SpeakerAnalysisOptions`, which both apps share).
extension SpeakerAnalysisOptions {
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
}
