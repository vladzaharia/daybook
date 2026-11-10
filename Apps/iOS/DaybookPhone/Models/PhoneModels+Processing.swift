import CryptoKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// What this iPhone's processing models can do, and the engine and summarizer a job runs with
/// (docs/iphone.md, "Processing on this iPhone").
extension PhoneModels {
    /// A processing role's model, when it's downloaded here (or the system's own) and can run.
    func installedChoice(for role: ModelRole) -> CatalogModel? {
        guard let model = choice(for: role), status(of: model).isReady else { return nil }
        return model
    }

    /// The model that gives speakers their voice profiles when the speaker model doesn't (Community-1 for
    /// Nemotron's turns, `ModelRouting.voiceEmbedder`); nil when the speaker model makes them itself.
    var voiceEmbedder: CatalogModel? {
        guard let diarizer = choice(for: .diarization) else { return nil }
        var routed = selections
        routed[.speakerEmbedding] = choice(for: .speakerEmbedding)?.key
        return ModelRouting.voiceEmbedder(diarizer: diarizer.key, selections: routed, catalog: catalog, engines: engines)
            .flatMap { catalog.model($0) }
    }

    /// The speaker model, when it and the voice-profile model it needs are downloaded.
    private var installedSpeakers: CatalogModel? {
        guard let speakers = installedChoice(for: .diarization) else { return nil }
        if let embedder = voiceEmbedder, status(of: embedder) != .downloaded { return nil }
        return speakers
    }

    /// The system's speech model, standing in while the chosen transcription model isn't on this iPhone yet
    /// (`TranscriptionRouting.interim`, docs/models.md, "Apple Speech"): built in, available here, and covering this
    /// iPhone's language. Nil while the chosen model is here, or nothing can stand in, so transcribing waits for the
    /// download as before.
    var transcriptionStandIn: CatalogModel? {
        guard installedChoice(for: .transcription) == nil, let chosen = choice(for: .transcription) else { return nil }
        let ready = Set(catalog.models(for: .transcription).filter { status(of: $0).isReady }.map(\.key))
        return TranscriptionRouting.interim(for: TranscriptionRoute(model: chosen.key), catalog: catalog, engines: engines, installed: ready)
            .flatMap { catalog.model($0.model) }
    }

    /// What this iPhone can do with its models now: transcribe (with speakers and voice profiles, as the
    /// Mac does, or with the system's speech model while the chosen one downloads, with speakers once
    /// they're here), find speakers, and summarize (a summary model that fits, where language models run).
    /// `models` names the model it would use for each role it can run, the stand-in among them while it
    /// stands in, for other devices and for Upgrade offers. Nothing while processing here is off.
    func capabilities(enabled: Bool) -> ProcessingCapabilities {
        guard enabled else { return ProcessingCapabilities(transcribes: false, findsSpeakers: false, summarizes: false) }
        let chosen = installedChoice(for: .transcription), standIn = chosen == nil ? transcriptionStandIn : nil
        let transcription = chosen ?? standIn, speakers = installedSpeakers
        let summary = installedChoice(for: .summarization)
        var models: [String: String] = [:]
        if let transcription { models[ModelRole.transcription.rawValue] = transcription.key }
        if let speakers {
            models[ModelRole.diarization.rawValue] = speakers.key
            if let embedder = voiceEmbedder { models[ModelRole.speakerEmbedding.rawValue] = embedder.key }
        }
        if let summary { models[ModelRole.summarization.rawValue] = summary.key }
        return ProcessingCapabilities(transcribes: transcription != nil && (speakers != nil || standIn != nil), findsSpeakers: speakers != nil,
                                      summarizes: summary != nil, models: models.isEmpty ? nil : models)
    }

    /// The engine a processing job runs: the Mac's `InferenceProcessingEngine` on this iPhone's runtime
    /// and models, which records exactly which model made each result. Nil until the transcription and
    /// speaker models are downloaded, unless the system's speech model stands in for the first, which then
    /// runs with no speakers until theirs are here (the Upgrade offer redoes its transcripts later).
    func processingEngine() -> InferenceProcessingEngine? {
        if let transcription = installedChoice(for: .transcription) {
            guard let speakers = installedSpeakers else { return nil }
            return InferenceProcessingEngine(inference: runtime, configuration: configuration(transcription: transcription.key, speakers: speakers.key))
        }
        guard let standIn = transcriptionStandIn else { return nil }
        return InferenceProcessingEngine(inference: runtime, configuration: configuration(transcription: standIn.key, speakers: installedSpeakers?.key))
    }

    /// The summarizer, when this iPhone can summarize now: a summary model that fits in memory is
    /// downloaded, and language models run here.
    func summarizer() -> LocalSummarizer? {
        guard let summary = installedChoice(for: .summarization) else { return nil }
        let speakers = choice(for: .diarization)?.key ?? summary.key
        let engine = InferenceProcessingEngine(inference: runtime, configuration: configuration(
            transcription: choice(for: .transcription)?.key ?? summary.key, speakers: speakers))
        return LocalSummarizer(engine: engine)
    }

    /// One job's models and options: the iPhone's choices, the speaker settings' defaults, and Apple's
    /// on-device model for titles and vocabulary where it's available. No `speakers`: it finds none.
    private func configuration(transcription: String, speakers: String?) -> InferenceProcessingEngine.Configuration {
        let summary = installedChoice(for: .summarization)
        let embedder = speakers == nil ? nil : voiceEmbedder
        let smallTasks = catalog.model("apple-foundation-models/system").flatMap {
            $0.availability(engines: engines, platform: .iOS).isAvailable ? $0.key : nil
        }
        let keys = [transcription, speakers ?? "", embedder?.key ?? "", summary?.key ?? "", smallTasks ?? ""]
        let fingerprint = SHA256.hash(data: Data(("iphone|" + keys.joined(separator: "|")).utf8)).map { String(format: "%02x", $0) }.joined()
        let matching = SpeakerMatchingConfiguration()
        return InferenceProcessingEngine.Configuration(
            transcriptionModel: ModelReference(transcription),
            // Without a summary model the engine is never asked for a summary: it waits for a Mac.
            summaryModel: ModelReference(summary?.key ?? transcription),
            detectSpeakers: speakers != nil, speakerModel: ModelReference(speakers ?? transcription),
            voiceEmbeddingModel: embedder.map { ModelReference($0.key) },
            smallTasksModel: smallTasks.map { ModelReference($0) },
            speakerOptions: SpeakerAnalysisOptions(), fingerprint: fingerprint,
            speakerMatchThreshold: matching.minimumSimilarity, speakerMatchMargin: matching.minimumMargin)
    }

    /// Lets every processing model go: after a job, and before a recording.
    func releaseProcessingModels() async {
        try? await runtime.unload()
    }
}
