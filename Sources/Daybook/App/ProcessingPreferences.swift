import CryptoKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// New quality controls are persisted together and frozen into each request. The speaker model
/// mirrors `AppState.modelSelections`' diarization choice, a variant key ("community-1/offline").
struct ProcessingPreferences: Codable, Equatable, Sendable {
    var speakerModelID: String
    var speakerOptions: SpeakerAnalysisOptions
    var matchSpeakersAcrossSources: Bool
    var speakerMatchThreshold: Double
    var speakerMatchMargin: Double
    /// The transcription language, a BCP-47 code ("de"); nil for Automatic (`TranscriptionRouting`).
    var transcriptionLanguage: String?
    /// The model for languages the transcription model doesn't cover; nil picks one
    /// (`TranscriptionRouting.otherLanguagesModel`).
    var otherLanguagesModelID: String?

    /// The first-launch speaker model, from the catalog's initial selection.
    static var defaultSpeakerModelID: String { ModelRecommendations.initialSelections()[.diarization] ?? "community-1/offline" }

    init(speakerModelID: String = ProcessingPreferences.defaultSpeakerModelID,
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

    var normalized: Self {
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

    init(from decoder: Decoder) throws {
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

extension ProcessingRequest.Mode {
    /// The Mac's menu titles.
    var title: String {
        switch self {
        case .newAudio: return "Process New Audio"
        case .summaryOnly: return "Refresh Summary"
        case .speakerRefresh: return "Re-label Speakers"
        case .fullRetranscription: return "Re-transcribe Audio"
        }
    }
}

/// One entry in this Mac's processing queue: a value snapshot, so preferences changed while it
/// waits cannot alter it. (A synced `ProcessingRequest` is what another device asked for; the
/// queue runs jobs, and a job that carries one out names it in `requestID`.)
struct ProcessingJob: Codable, Equatable, Identifiable, Sendable {
    typealias Mode = ProcessingRequest.Mode

    let id: UUID
    let meetingID: UUID
    let createdAt: Date
    let mode: Mode
    let transcriptionModelID: String
    let summaryModelID: String
    let detectSpeakers: Bool
    let preferences: ProcessingPreferences
    /// The synced request this job carries out, which this Mac holds a claim on while it runs.
    let requestID: UUID?
    /// The template the request asked for (Summarize Again with another template); nil uses the conversation's.
    let templateID: String?
    /// The exact revision each model resolved to when the job was queued (variant key → revision),
    /// so an update installed meanwhile never changes what this job runs. Nil or missing entries
    /// run the newest installed revision.
    let revisions: [String: String]?
    /// Computes voice profiles when the speaker model doesn't (`ModelRouting.voiceEmbedder`).
    let voiceEmbeddingModelID: String?
    /// Automatic language only: transcribes instead when the first transcript is in a language
    /// `transcriptionModelID` doesn't cover (`TranscriptionRoute.fallback`). Optional: a job runs
    /// without it, keeping the first transcript.
    let languageFallbackModelID: String?
    /// Chooses the title, kind, and vocabulary suggestions (Apple Foundation Models) when it was
    /// selected and available as the job was queued; nil leaves them to the summary model.
    let smallTasksModelID: String?
    /// Optional photo captions; nil uses built-in Apple Vision.
    let photoModelID: String?

    init(id: UUID = UUID(), meetingID: UUID, createdAt: Date = Date(), mode: Mode = .newAudio,
         transcriptionModelID: String, summaryModelID: String, detectSpeakers: Bool = true,
         preferences: ProcessingPreferences = .init(), requestID: UUID? = nil, templateID: String? = nil,
         revisions: [String: String]? = nil, voiceEmbeddingModelID: String? = nil, languageFallbackModelID: String? = nil,
         smallTasksModelID: String? = nil, photoModelID: String? = nil) {
        self.id = id; self.meetingID = meetingID; self.createdAt = createdAt; self.mode = mode
        self.transcriptionModelID = transcriptionModelID; self.summaryModelID = summaryModelID
        self.detectSpeakers = detectSpeakers; self.preferences = preferences.normalized
        self.requestID = requestID; self.templateID = templateID
        self.revisions = revisions?.isEmpty == true ? nil : revisions
        self.voiceEmbeddingModelID = voiceEmbeddingModelID
        self.languageFallbackModelID = languageFallbackModelID
        self.smallTasksModelID = smallTasksModelID
        self.photoModelID = photoModelID
    }

    /// The same job, carrying out `request`.
    func carrying(_ request: ProcessingRequest) -> ProcessingJob {
        ProcessingJob(id: id, meetingID: meetingID, createdAt: createdAt, mode: mode, transcriptionModelID: transcriptionModelID,
                      summaryModelID: summaryModelID, detectSpeakers: detectSpeakers, preferences: preferences,
                      requestID: request.id, templateID: request.templateID ?? templateID, revisions: revisions,
                      voiceEmbeddingModelID: voiceEmbeddingModelID, languageFallbackModelID: languageFallbackModelID,
                      smallTasksModelID: smallTasksModelID, photoModelID: photoModelID)
    }

    /// The models the job runs, each with the revision it froze.
    var modelReferences: [ModelReference] {
        ([transcriptionModelID, summaryModelID] + [languageFallbackModelID, photoModelID].compactMap { $0 }
            + (detectSpeakers ? [preferences.speakerModelID] + [voiceEmbeddingModelID].compactMap { $0 } : []))
            .map(reference)
    }

    func reference(_ id: String) -> ModelReference { ModelReference(id, revision: revisions?[id]) }

    /// Summary refresh works with saved transcripts even after the ASR model is removed.
    func requiredModelIDs(hasUntranscribedAudio: Bool) -> Set<String> {
        var models: Set<String> = [summaryModelID]
        let transcribe = mode == .fullRetranscription || (mode != .summaryOnly && hasUntranscribedAudio)
        if transcribe { models.insert(transcriptionModelID) }
        if detectSpeakers && (transcribe || mode == .speakerRefresh) {
            models.insert(preferences.speakerModelID)
            if let embedder = voiceEmbeddingModelID { models.insert(embedder) }
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
            let revisions: [String: String]?
            let voiceEmbeddingModelID: String?
            let languageFallbackModelID: String?
            let smallTasksModelID: String?
            let photoModelID: String?
        }
        // Nil optional models (fallback, small tasks) are left out of the encoding, so earlier jobs keep their fingerprints.
        let value = Configuration(transcriptionModelID: transcriptionModelID, summaryModelID: summaryModelID,
                                  detectSpeakers: detectSpeakers, preferences: preferences.normalized,
                                  revisions: revisions, voiceEmbeddingModelID: voiceEmbeddingModelID,
                                  languageFallbackModelID: languageFallbackModelID,
                                  smallTasksModelID: smallTasksModelID, photoModelID: photoModelID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // All fields are finite normalized primitives; this encoding cannot fail.
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ProcessingJob {
    /// What the job hands the processing engine.
    var engineConfiguration: InferenceProcessingEngine.Configuration {
        InferenceProcessingEngine.Configuration(
            transcriptionModel: reference(transcriptionModelID), summaryModel: reference(summaryModelID), detectSpeakers: detectSpeakers,
            speakerModel: reference(preferences.speakerModelID), voiceEmbeddingModel: voiceEmbeddingModelID.map(reference),
            smallTasksModel: smallTasksModelID.map(reference),
            speakerOptions: preferences.speakerOptions, fingerprint: configurationFingerprint,
            speakerMatchThreshold: preferences.speakerMatchThreshold, speakerMatchMargin: preferences.speakerMatchMargin,
            transcriptionLanguage: preferences.transcriptionLanguage, languageFallbackModel: languageFallbackModelID.map(reference),
            photoModel: photoModelID.map(reference))
    }
}
