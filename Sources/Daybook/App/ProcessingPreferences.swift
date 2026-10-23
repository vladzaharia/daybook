import CryptoKit
import Foundation

/// New quality controls are persisted together; existing ASR/summary model
/// UserDefaults selections remain compatible and are frozen into each request.
struct ProcessingPreferences: Codable, Equatable, Sendable {
    var speakerModelID: String
    var speakerOptions: SpeakerAnalysisOptions
    var matchSpeakersAcrossSources: Bool
    var speakerMatchThreshold: Double
    var speakerMatchMargin: Double

    init(speakerModelID: String = DaybookModelCatalog.diarization,
         speakerOptions: SpeakerAnalysisOptions = .init(),
         matchSpeakersAcrossSources: Bool = true,
         speakerMatchThreshold: Double = 0.82, speakerMatchMargin: Double = 0.06) {
        self.speakerModelID = speakerModelID
        self.speakerOptions = speakerOptions.normalized
        self.matchSpeakersAcrossSources = matchSpeakersAcrossSources
        self.speakerMatchThreshold = Self.unitInterval(speakerMatchThreshold, fallback: 0.82)
        self.speakerMatchMargin = Self.unitInterval(speakerMatchMargin, fallback: 0.06)
    }

    var normalized: Self {
        Self(speakerModelID: speakerModelID, speakerOptions: speakerOptions,
             matchSpeakersAcrossSources: matchSpeakersAcrossSources,
             speakerMatchThreshold: speakerMatchThreshold, speakerMatchMargin: speakerMatchMargin)
    }

    private static func unitInterval(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case speakerModelID, speakerOptions, matchSpeakersAcrossSources, speakerMatchThreshold, speakerMatchMargin
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(speakerModelID: try values.decodeIfPresent(String.self, forKey: .speakerModelID) ?? DaybookModelCatalog.diarization,
                  speakerOptions: try values.decodeIfPresent(SpeakerAnalysisOptions.self, forKey: .speakerOptions) ?? .init(),
                  matchSpeakersAcrossSources: try values.decodeIfPresent(Bool.self, forKey: .matchSpeakersAcrossSources) ?? true,
                  speakerMatchThreshold: try values.decodeIfPresent(Double.self, forKey: .speakerMatchThreshold) ?? 0.82,
                  speakerMatchMargin: try values.decodeIfPresent(Double.self, forKey: .speakerMatchMargin) ?? 0.06)
    }
}

/// A value snapshot: preferences changed while a request is queued cannot alter it.
struct ProcessingRequest: Codable, Equatable, Identifiable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case newAudio, summaryOnly, speakerRefresh, fullRetranscription
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newAudio: return "Process new audio"
            case .summaryOnly: return "Refresh summary"
            case .speakerRefresh: return "Re-label speakers"
            case .fullRetranscription: return "Re-transcribe audio"
            }
        }
    }

    let id: UUID
    let meetingID: UUID
    let createdAt: Date
    let mode: Mode
    let transcriptionModelID: String
    let summaryModelID: String
    let detectSpeakers: Bool
    let preferences: ProcessingPreferences

    init(id: UUID = UUID(), meetingID: UUID, createdAt: Date = Date(), mode: Mode = .newAudio,
         transcriptionModelID: String, summaryModelID: String, detectSpeakers: Bool = true,
         preferences: ProcessingPreferences = .init()) {
        self.id = id; self.meetingID = meetingID; self.createdAt = createdAt; self.mode = mode
        self.transcriptionModelID = transcriptionModelID; self.summaryModelID = summaryModelID
        self.detectSpeakers = detectSpeakers; self.preferences = preferences.normalized
    }

    /// Summary refresh works with saved transcripts even after the ASR model is removed.
    func requiredModelIDs(hasUntranscribedAudio: Bool) -> Set<String> {
        var models: Set<String> = [summaryModelID]
        let transcribe = mode == .fullRetranscription || (mode != .summaryOnly && hasUntranscribedAudio)
        if transcribe { models.insert(transcriptionModelID) }
        if detectSpeakers && (transcribe || mode == .speakerRefresh) {
            models.insert(preferences.speakerModelID)
        }
        return models
    }

    /// Excludes request IDs, dates, mode, and meeting identity so equivalent model
    /// settings compare consistently after queue restoration and across stages.
    var configurationFingerprint: String {
        struct Configuration: Encodable {
            let transcriptionModelID: String
            let summaryModelID: String
            let detectSpeakers: Bool
            let preferences: ProcessingPreferences
        }
        let value = Configuration(transcriptionModelID: transcriptionModelID, summaryModelID: summaryModelID,
                                  detectSpeakers: detectSpeakers, preferences: preferences.normalized)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // All fields are finite normalized primitives; this encoding cannot fail.
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
