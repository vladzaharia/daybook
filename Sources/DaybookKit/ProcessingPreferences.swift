import Foundation

/// How hard the speaker model works. Processing presets change inference work, not the downloaded weights.
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

/// The speaker model's options: its effort and, for Community-1, how many speakers to expect. What each engine makes of
/// them is DaybookIntelligence's (`communityConfiguration()`, `sortformerOverlapFrames`).
public struct SpeakerAnalysisOptions: Codable, Equatable, Sendable {
    public var quality: SpeakerQuality = .balanced
    /// A clustering target for Community-1, not a guaranteed number of output speakers.
    public var expectedSpeakerCount: Int? = nil

    public var normalized: Self {
        var value = self
        value.expectedSpeakerCount = expectedSpeakerCount.flatMap { (1...32).contains($0) ? $0 : nil }
        return value
    }

    public init(quality: SpeakerQuality = .balanced, expectedSpeakerCount: Int? = nil) {
        self.quality = quality
        self.expectedSpeakerCount = expectedSpeakerCount
    }
}

/// What a processing job runs with besides its models, frozen into it when it's queued. Both apps read it; where each
/// part lives differs:
/// - The speaker settings (the speaker model, its options, matching across sources and its thresholds) and the model
///   for other languages are the device's: a Mac keeps them in its preferences and changes them in Settings › Models;
///   the iPhone runs the defaults.
/// - The transcription language is the library's (`LibraryMetadata.transcriptionLanguage`), the same on every device; a
///   job copies it in as it's queued, so changing it later never changes a job.
///
/// The speaker model mirrors a Mac's `modelSelections` diarization choice, a variant key ("community-1/offline").
public struct ProcessingPreferences: Codable, Equatable, Sendable {
    public var speakerModelID: String
    public var speakerOptions: SpeakerAnalysisOptions
    public var matchSpeakersAcrossSources: Bool
    public var speakerMatchThreshold: Double
    public var speakerMatchMargin: Double
    /// The transcription language, a BCP-47 code ("de"); nil for Automatic (`TranscriptionRouting`). A job's is the
    /// library's when it was queued.
    public var transcriptionLanguage: String?
    /// The model for languages the transcription model doesn't cover; nil picks one
    /// (`TranscriptionRouting.otherLanguagesModel`).
    public var otherLanguagesModelID: String?

    /// The first-launch speaker model, from the catalog's initial selection.
    public static var defaultSpeakerModelID: String { ModelRecommendations.initialSelections()[.diarization] ?? "community-1/offline" }

    public init(speakerModelID: String = ProcessingPreferences.defaultSpeakerModelID,
                speakerOptions: SpeakerAnalysisOptions = .init(),
                matchSpeakersAcrossSources: Bool = true,
                speakerMatchThreshold: Double = 0.82, speakerMatchMargin: Double = 0.06,
                transcriptionLanguage: String? = nil, otherLanguagesModelID: String? = nil) {
        self.speakerModelID = speakerModelID
        self.speakerOptions = speakerOptions.normalized
        self.matchSpeakersAcrossSources = matchSpeakersAcrossSources
        self.speakerMatchThreshold = Self.unitInterval(speakerMatchThreshold, fallback: 0.82)
        self.speakerMatchMargin = Self.unitInterval(speakerMatchMargin, fallback: 0.06)
        self.transcriptionLanguage = TranscriptionLanguages.normalize(transcriptionLanguage)
        self.otherLanguagesModelID = otherLanguagesModelID?.isEmpty == true ? nil : otherLanguagesModelID
    }

    public var normalized: Self {
        Self(speakerModelID: speakerModelID, speakerOptions: speakerOptions,
             matchSpeakersAcrossSources: matchSpeakersAcrossSources,
             speakerMatchThreshold: speakerMatchThreshold, speakerMatchMargin: speakerMatchMargin,
             transcriptionLanguage: transcriptionLanguage, otherLanguagesModelID: otherLanguagesModelID)
    }

    private static func unitInterval(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case speakerModelID, speakerOptions, matchSpeakersAcrossSources, speakerMatchThreshold, speakerMatchMargin
        // Absent (Automatic, no choice) encodes nothing, so earlier preferences fingerprint as before.
        case transcriptionLanguage, otherLanguagesModelID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Speaker models stored before the model system ("speaker-community-1") map through the
        // catalog's migration table to variant keys; unknown IDs are kept, never switched.
        let stored = try values.decodeIfPresent(String.self, forKey: .speakerModelID)
        self.init(speakerModelID: stored.map { ModelCatalog.builtIn.model($0)?.key ?? $0 } ?? Self.defaultSpeakerModelID,
                  speakerOptions: try values.decodeIfPresent(SpeakerAnalysisOptions.self, forKey: .speakerOptions) ?? .init(),
                  matchSpeakersAcrossSources: try values.decodeIfPresent(Bool.self, forKey: .matchSpeakersAcrossSources) ?? true,
                  speakerMatchThreshold: try values.decodeIfPresent(Double.self, forKey: .speakerMatchThreshold) ?? 0.82,
                  speakerMatchMargin: try values.decodeIfPresent(Double.self, forKey: .speakerMatchMargin) ?? 0.06,
                  transcriptionLanguage: try values.decodeIfPresent(String.self, forKey: .transcriptionLanguage),
                  otherLanguagesModelID: try values.decodeIfPresent(String.self, forKey: .otherLanguagesModelID))
    }
}
