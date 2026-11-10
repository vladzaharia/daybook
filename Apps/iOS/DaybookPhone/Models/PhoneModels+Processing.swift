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

    /// The route a job here takes: both apps' routing (`TranscriptionRouting.route`) of this iPhone's transcription model
    /// in the library's language (`transcriptionLanguage`, nil for Automatic), over the models that run here. No model for
    /// other languages runs on an iPhone, so a language the chosen model doesn't cover goes to it as a hint, as on a Mac
    /// without one. Nil while no transcription model can run here.
    var transcriptionRoute: TranscriptionRoute? {
        guard let chosen = choice(for: .transcription) else { return nil }
        return TranscriptionRouting.route(selected: chosen.key, language: transcriptionLanguage(), otherLanguagesChoice: nil,
                                          catalog: catalog, engines: engines, installed: readyTranscription)
    }

    /// What a job here transcribes with now, and the route it takes: the routed model once it's downloaded, else the
    /// system's speech model standing in for it. Nil while neither can run.
    private var transcriber: (model: CatalogModel, route: TranscriptionRoute, standsIn: Bool)? {
        guard let route = transcriptionRoute else { return nil }
        if let model = catalog.model(route.model), status(of: model).isReady { return (model, route, false) }
        guard let standIn = TranscriptionRouting.interim(for: route, catalog: catalog, engines: engines, installed: readyTranscription),
              let model = catalog.model(standIn.model) else { return nil }
        return (model, standIn, true)
    }

    /// The transcription models downloaded here, and the system's own where it's available.
    private var readyTranscription: Set<String> {
        Set(catalog.models(for: .transcription).filter { status(of: $0).isReady }.map(\.key))
    }

    /// The system's speech model, standing in while the chosen transcription model isn't on this iPhone yet
    /// (`TranscriptionRouting.interim`, docs/models.md, "Apple Speech"): built in, available here, and covering the
    /// library's language, or this iPhone's for Automatic. Nil while the chosen model is here, or nothing can stand in, so
    /// transcribing waits for the download as before.
    var transcriptionStandIn: CatalogModel? {
        guard let transcriber, transcriber.standsIn else { return nil }
        return transcriber.model
    }

    /// What this iPhone can do with its models now: transcribe (with speakers and voice profiles, as the
    /// Mac does, or with the system's speech model while the chosen one downloads, with speakers once
    /// they're here), find speakers, and summarize (a summary model that fits, where language models run).
    /// `models` names the model it would use for each role it can run, the stand-in among them while it
    /// stands in, for other devices and for Upgrade offers. Nothing while processing here is off.
    func capabilities(enabled: Bool) -> ProcessingCapabilities {
        guard enabled else { return ProcessingCapabilities(transcribes: false, findsSpeakers: false, summarizes: false) }
        let transcriber = self.transcriber, speakers = installedSpeakers
        let summary = installedChoice(for: .summarization)
        var models: [String: String] = [:]
        if let transcriber { models[ModelRole.transcription.rawValue] = transcriber.model.key }
        if let speakers {
            models[ModelRole.diarization.rawValue] = speakers.key
            if let embedder = voiceEmbedder { models[ModelRole.speakerEmbedding.rawValue] = embedder.key }
        }
        if let summary { models[ModelRole.summarization.rawValue] = summary.key }
        return ProcessingCapabilities(transcribes: transcriber.map { speakers != nil || $0.standsIn } ?? false, findsSpeakers: speakers != nil,
                                      summarizes: summary != nil, models: models.isEmpty ? nil : models)
    }

    /// The engine a processing job runs: the Mac's `InferenceProcessingEngine` on this iPhone's runtime
    /// and models, which records exactly which model made each result. Nil until the transcription and
    /// speaker models are downloaded, unless the system's speech model stands in for the first, which then
    /// runs with no speakers until theirs are here (the Upgrade offer redoes its transcripts later). It
    /// transcribes in the library's language as it is when the job starts, and keeps it.
    func processingEngine() -> InferenceProcessingEngine? {
        guard let transcriber else { return nil }
        let speakers = installedSpeakers
        // The chosen model runs with speakers or not at all; the stand-in runs without them until they're here.
        guard speakers != nil || transcriber.standsIn else { return nil }
        return InferenceProcessingEngine(inference: runtime, configuration: configuration(route: transcriber.route, speakers: speakers?.key))
    }

    /// The summarizer, when this iPhone can summarize now: a summary model that fits in memory is
    /// downloaded, and language models run here.
    func summarizer() -> LocalSummarizer? {
        guard let summary = installedChoice(for: .summarization) else { return nil }
        let speakers = choice(for: .diarization)?.key ?? summary.key
        let engine = InferenceProcessingEngine(inference: runtime, configuration: configuration(
            route: TranscriptionRoute(model: choice(for: .transcription)?.key ?? summary.key), speakers: speakers))
        return LocalSummarizer(engine: engine)
    }

    /// One job's models and options: the iPhone's choices routed in the library's language, the speaker settings'
    /// defaults (DaybookKit's `ProcessingPreferences`, which a Mac changes in its Settings and the iPhone doesn't), and
    /// Apple's on-device model for titles and vocabulary where it's available. No `speakers`: it finds none.
    private func configuration(route: TranscriptionRoute, speakers: String?) -> InferenceProcessingEngine.Configuration {
        let transcription = route.model
        let summary = installedChoice(for: .summarization)
        let embedder = speakers == nil ? nil : voiceEmbedder
        let smallTasks = catalog.model("apple-foundation-models/system").flatMap {
            $0.availability(engines: engines, platform: .iOS).isAvailable ? $0.key : nil
        }
        var keys = [transcription, speakers ?? "", embedder?.key ?? "", summary?.key ?? "", smallTasks ?? ""]
        // A chosen language and a language check join the fingerprint, so Automatic's stays as it was.
        if let language = route.language { keys.append("language=\(language)") }
        if let fallback = route.fallback { keys.append("fallback=\(fallback)") }
        let fingerprint = SHA256.hash(data: Data(("iphone|" + keys.joined(separator: "|")).utf8)).map { String(format: "%02x", $0) }.joined()
        let defaults = ProcessingPreferences()
        return InferenceProcessingEngine.Configuration(
            transcriptionModel: ModelReference(transcription),
            // Without a summary model the engine is never asked for a summary: it waits for a Mac.
            summaryModel: ModelReference(summary?.key ?? transcription),
            detectSpeakers: speakers != nil, speakerModel: ModelReference(speakers ?? transcription),
            voiceEmbeddingModel: embedder.map { ModelReference($0.key) },
            smallTasksModel: smallTasks.map { ModelReference($0) },
            speakerOptions: defaults.speakerOptions, fingerprint: fingerprint,
            speakerMatchThreshold: defaults.speakerMatchThreshold, speakerMatchMargin: defaults.speakerMatchMargin,
            transcriptionLanguage: route.language, languageFallbackModel: route.fallback.map { ModelReference($0) })
    }

    /// Lets every processing model go: after a job, and before a recording.
    func releaseProcessingModels() async {
        try? await runtime.unload()
    }

    // MARK: Summaries here, and the set's downloads

    /// The summary model this iPhone could run once it's here: the chosen one, where one fits in the memory iOS gives
    /// Daybook and language models run here. Nil where summaries are a Mac's, never a model the iPhone can't run.
    var summaryModel: CatalogModel? {
        guard let model = choice(for: .summarization), status(of: model).isAvailable else { return nil }
        return model
    }

    /// What downloading `summaryModel` takes, while it isn't here and no one has asked for it (or it stopped, and
    /// asking again downloads it); 0 otherwise.
    var summaryModelBytes: Int64 {
        guard let model = summaryModel, status(of: model).canDownload else { return 0 }
        return downloadBytes(model)
    }

    /// `summaryModel` is asked for: arriving, waiting its turn or for Wi‑Fi, or stopped.
    var summaryModelAsked: Bool {
        guard let model = summaryModel else { return false }
        let status = status(of: model)
        return status.isTransferring || status.isFailed
    }

    /// The chosen processing models that can run here, each once: what transcribing needs, then the summary model.
    private var processingModels: [CatalogModel] {
        var seen = Set<String>()
        return processingRoles.compactMap(choice(for:)).filter { status(of: $0).isAvailable && seen.insert($0.key).inserted }
    }

    /// This iPhone's processing downloads as one fact, in the words every surface says them with (DaybookKit's
    /// `ModelDownloadState`, as a Mac's queue gives it): the whole set asked for arriving, with a model that finished
    /// counted whole ("Downloading models · 40%", "1.8 of 4.4 GB"), waiting for Wi‑Fi, or a download that stopped. Nil
    /// when none is on its way or stopped.
    var processingDownloadState: ModelDownloadState? {
        let models = processingModels
        let coming = models.filter { status(of: $0).isTransferring }
        if !coming.isEmpty {
            let arriving = coming.contains { if case .downloading = status(of: $0) { return true } else { return false } }
            if !arriving, coming.contains(where: { status(of: $0) == .waitingForWiFi }) {
                return .waitingForWiFi(bytes: coming.reduce(0) { $0 + downloadBytes($1) })
            }
            let set = models.filter { processingBatch.contains($0.key) || status(of: $0).isTransferring }
            let done = set.reduce(Int64(0)) { sum, model in
                switch status(of: model) {
                case .downloading(let fraction):
                    return sum + Int64(Double(model.approximateBytes) * (fraction.isFinite ? min(max(fraction, 0), 1) : 0))
                case let status where status.isReady: return sum + model.approximateBytes
                default: return sum
                }
            }
            return .downloading(done: done, total: set.reduce(0) { $0 + $1.approximateBytes })
        }
        let stopped = models.filter { status(of: $0).isFailed }
        guard let failed = stopped.first else { return nil }
        // Trying again downloads everything the set still misses.
        let missing = models.filter { status(of: $0).canDownload && (processingBatch.contains($0.key) || Self.transcribingRoles.contains(where: $0.serves)) }
        return .failed(model: failed.name, bytes: missing.reduce(0) { $0 + downloadBytes($1) })
    }

    /// A model transcribing here needs, on its way (downloading, or waiting its turn or for Wi‑Fi), with the whole set's
    /// figure: what a recording of this iPhone's own waits for.
    var transcribingDownload: ConversationStatusPresentation.LocalCapabilities.Download? {
        guard let model = Self.transcribingRoles.compactMap(choice(for:)).first(where: { status(of: $0).isTransferring }) else { return nil }
        return .init(name: model.name, fraction: processingDownloadState?.fraction ?? 0)
    }

    /// Downloads what the set still misses: what transcribing here needs and, once it's been asked for, the summary
    /// model ("Try Again" on the page).
    func downloadProcessingSet() {
        for model in processingMissing { download(model) }
        if let summary = summaryModel, summaryModelAsked, status(of: summary).canDownload { download(summary) }
    }

    /// Cancels every processing download, the summary model's included: the one set's Cancel.
    func cancelProcessingDownloads() {
        // What waits its turn goes first, so cancelling what's ahead of it doesn't start it.
        if let summary = summaryModel, status(of: summary).isTransferring { cancel(summary) }
        cancelDownloads(in: processingRoles)
    }
}
