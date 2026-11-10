import CryptoKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

extension ProcessingRequest.Mode {
    /// The Mac's menu titles, in the words the page and the iPhone use (docs/interface.md, "Words").
    var title: String {
        switch self {
        case .newAudio: return "Transcribe New Audio"
        case .summaryOnly: return "Summarize Again"
        case .speakerRefresh: return "Identify Speakers Again"
        case .fullRetranscription: return "Transcribe Everything Again"
        }
    }
}

/// One entry in this Mac's processing queue: a value snapshot, so preferences changed while it
/// waits, the library's transcription language included, cannot alter it. (A synced `ProcessingRequest` is what another device asked for; the
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
    /// Set when the job redoes a step with a better model ("Upgrade", docs/multipoint.md): asked for here, or by the
    /// request it carries. Its summary goes through the placement with its countdown, or straight to the cloud when
    /// the cloud was the better model.
    let upgrade: ProcessingRequest.Upgrade?
    /// Set when the person chose Summarize on This Mac (after the cloud couldn't): stored only then, so earlier jobs
    /// decode and compare as before.
    private let summaryHere: Bool?
    /// Set when the person chose Use the Cloud for a summary waiting for this Mac's summary model: stored only then.
    private let summaryInCloud: Bool?

    /// Its summary runs on this Mac whatever the cloud preferences say. It's placed there as the summary step starts and
    /// ends with it, so a job cancelled, paused, or skipped before then leaves no placement behind.
    var summarizesHere: Bool { summaryHere == true }
    /// Its summary goes to the cloud with no countdown, while the cloud is on offer: the person chose it for a summary
    /// that waited for this Mac's summary model (Use the Cloud).
    var summarizesInCloud: Bool { summaryInCloud == true }

    init(id: UUID = UUID(), meetingID: UUID, createdAt: Date = Date(), mode: Mode = .newAudio,
         transcriptionModelID: String, summaryModelID: String, detectSpeakers: Bool = true,
         preferences: ProcessingPreferences = .init(), requestID: UUID? = nil, templateID: String? = nil,
         revisions: [String: String]? = nil, voiceEmbeddingModelID: String? = nil, languageFallbackModelID: String? = nil,
         smallTasksModelID: String? = nil, photoModelID: String? = nil, upgrade: ProcessingRequest.Upgrade? = nil,
         summarizesHere: Bool = false, summarizesInCloud: Bool = false) {
        self.id = id; self.meetingID = meetingID; self.createdAt = createdAt; self.mode = mode
        self.transcriptionModelID = transcriptionModelID; self.summaryModelID = summaryModelID
        self.detectSpeakers = detectSpeakers; self.preferences = preferences.normalized
        self.requestID = requestID; self.templateID = templateID
        self.revisions = revisions?.isEmpty == true ? nil : revisions
        self.voiceEmbeddingModelID = voiceEmbeddingModelID
        self.languageFallbackModelID = languageFallbackModelID
        self.smallTasksModelID = smallTasksModelID
        self.photoModelID = photoModelID
        self.upgrade = upgrade
        summaryHere = summarizesHere ? true : nil
        summaryInCloud = summarizesInCloud ? true : nil
    }

    /// The same job, carrying out `request`.
    func carrying(_ request: ProcessingRequest) -> ProcessingJob {
        ProcessingJob(id: id, meetingID: meetingID, createdAt: createdAt, mode: mode, transcriptionModelID: transcriptionModelID,
                      summaryModelID: summaryModelID, detectSpeakers: detectSpeakers, preferences: preferences,
                      requestID: request.id, templateID: request.templateID ?? templateID, revisions: revisions,
                      voiceEmbeddingModelID: voiceEmbeddingModelID, languageFallbackModelID: languageFallbackModelID,
                      smallTasksModelID: smallTasksModelID, photoModelID: photoModelID, upgrade: request.upgrade ?? upgrade,
                      summarizesHere: summarizesHere, summarizesInCloud: summarizesInCloud)
    }

    /// The same job, no longer carrying out a request: it gave the request back.
    var withoutRequest: ProcessingJob {
        ProcessingJob(id: id, meetingID: meetingID, createdAt: createdAt, mode: mode, transcriptionModelID: transcriptionModelID,
                      summaryModelID: summaryModelID, detectSpeakers: detectSpeakers, preferences: preferences, templateID: templateID,
                      revisions: revisions, voiceEmbeddingModelID: voiceEmbeddingModelID, languageFallbackModelID: languageFallbackModelID,
                      smallTasksModelID: smallTasksModelID, photoModelID: photoModelID, upgrade: upgrade,
                      summarizesHere: summarizesHere, summarizesInCloud: summarizesInCloud)
    }

    /// The models the job runs, each with the revision it froze.
    var modelReferences: [ModelReference] {
        ([transcriptionModelID, summaryModelID] + [languageFallbackModelID, photoModelID].compactMap { $0 }
            + (detectSpeakers ? [preferences.speakerModelID] + [voiceEmbeddingModelID].compactMap { $0 } : []))
            .map(reference)
    }

    func reference(_ id: String) -> ModelReference { ModelReference(id, revision: revisions?[id]) }

    /// The models the job needs before it can start: what transcribes, finds speakers, and makes their voice profiles, for
    /// the work it does. The summary model isn't one: a transcript never waits for it (docs/models.md, "Routing"), and
    /// the job's summary waits for it at the summary step, unless the cloud takes the summary. Summary refresh works with
    /// saved transcripts even after the ASR model is removed.
    func transcribingModelIDs(hasUntranscribedAudio: Bool) -> Set<String> {
        var models: Set<String> = []
        let transcribe = mode == .fullRetranscription || (mode != .summaryOnly && hasUntranscribedAudio)
        if transcribe { models.insert(transcriptionModelID) }
        if detectSpeakers && (transcribe || mode == .speakerRefresh) {
            models.insert(preferences.speakerModelID)
            if let embedder = voiceEmbeddingModelID { models.insert(embedder) }
        }
        return models
    }

    /// Every model the job runs with here: the transcribing ones and the summary model.
    func requiredModelIDs(hasUntranscribedAudio: Bool) -> Set<String> {
        transcribingModelIDs(hasUntranscribedAudio: hasUntranscribedAudio).union([summaryModelID])
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
