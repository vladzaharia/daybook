import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// The models a job queued now runs, after routing (docs/models.md, "Routing"): the library's transcription
/// language picks the transcription model (or, for Automatic, a model to check the language with);
/// while that model isn't on this Mac yet, the system's speech model stands in where it can; an
/// expected speaker count above the speaker model's limit picks one without it; a speaker model
/// without voice profiles gets an embedding model. Decided here, frozen into the job.
struct SpeechRoute: Equatable {
    var transcription: TranscriptionRoute
    var speakerModel: String
    var voiceEmbedder: String?
    /// The transcription model the choices route to, which `transcription` stands in for while it downloads
    /// (`TranscriptionRouting.interim`); the same model otherwise.
    var chosenTranscription: String
    /// The job finds speakers: the person asked for them, and the speaker models are here or nothing stands in. A
    /// stand-in transcript has none until its speaker models arrive (the Upgrade offer redoes it then).
    var findsSpeakers: Bool

    /// The system's speech model transcribes while the chosen one downloads.
    var standsIn: Bool { transcription.model != chosenTranscription }

    /// The speaker model and the voice-profile model it needs.
    var speakerModels: [String] { [speakerModel] + [voiceEmbedder].compactMap { $0 } }

    /// What routing reads, besides the engines this build has.
    struct Inputs: Equatable {
        var catalogRevision: Int
        var selections: ModelSelections
        var preferences: ProcessingPreferences
        /// The library's transcription language.
        var language: String?
        var installed: Set<String>
        var detectSpeakers: Bool
        var standsIn: Bool
    }
}

extension AppState {
    /// The language the library's conversations are transcribed in, nil for Automatic (Settings › Models › Transcription,
    /// the iPhone's too). A synced library setting: a change on another device changes what this Mac transcribes with
    /// once it syncs. The model for other languages and the speaker settings stay this Mac's (`processingPreferences`).
    var transcriptionLanguage: String? {
        get { library.transcriptionLanguage }
        set { library.setTranscriptionLanguage(newValue) }
    }

    /// Once the library is open at launch: a Mac that chose its transcription language before the language was the
    /// library's writes it into the library once, when the library has none, and from then on follows the library
    /// (docs/release.md, "Migrations"). What this Mac offers other devices then follows the language as it changes, here
    /// or from another device.
    func followLibraryLanguage() {
        if let stored = processingPreferences.transcriptionLanguage {
            library.adoptTranscriptionLanguage(stored)
            processingPreferences.transcriptionLanguage = nil
        }
        watches.append(ObservationWatch.distinctValues(of: { [weak self] in self?.transcriptionLanguage }, initial: false) { [weak self] _ in
            self?.presenceChanged()
        })
    }

    /// The speaker model a job runs takes a number of speakers (Settings › Models › Speakers offers one), so Identify
    /// Speakers Again can ask how many people spoke.
    var speakerCountsOffered: Bool {
        ModelRouting.supportsExpectedSpeakerCount(routedSpeech.speakerModel, catalog: modelCatalog)
    }

    /// Whether `job` runs as it was asked: a number of people it was given goes to a speaker model that takes one. A job
    /// that can't is never run as if it had (`pickUpRequests`, `mayRun`, `MacProcessor.enqueue`).
    func takesSpeakerAsk(_ job: ProcessingJob) -> Bool {
        job.speakers?.count == nil || ModelRouting.supportsExpectedSpeakerCount(job.preferences.speakerModelID, catalog: modelCatalog)
    }

    var speechRoute: SpeechRoute {
        let catalog = modelCatalog, engines = runtime.engines, preferences = processingPreferences, installed = installedModels
        let chosen = TranscriptionRouting.route(selected: transcriptionModel, language: transcriptionLanguage,
                                                otherLanguagesChoice: preferences.otherLanguagesModelID, catalog: catalog,
                                                engines: engines, installed: installed)
        // Transcripts without a download: while the chosen model isn't here, the system's speech model stands in where
        // it can (docs/models.md, "Apple Speech"); otherwise the job waits for the download.
        let standIn = transcriptionStandsIn ? TranscriptionRouting.interim(for: chosen, catalog: catalog, engines: engines, installed: installed) : nil
        let transcription = standIn ?? chosen
        let speakerModel = ModelRouting.diarizer(selected: preferences.speakerModelID, expectedSpeakers: preferences.speakerOptions.expectedSpeakerCount,
                                                 catalog: catalog, engines: engines, installed: installed)
        let selections = ModelRouting.withDefaultVoiceEmbedder(modelSelections, catalog: catalog, engines: engines)
        let embedder = ModelRouting.voiceEmbedder(diarizer: speakerModel, selections: selections, catalog: catalog, engines: engines)
        let speakersHere = ([speakerModel] + [embedder].compactMap { $0 }).allSatisfy(installed.contains)
        return SpeechRoute(transcription: transcription, speakerModel: speakerModel, voiceEmbedder: embedder, chosenTranscription: chosen.model,
                           findsSpeakers: detectSpeakers && (speakersHere || transcription == chosen))
    }

    /// `speechRoute`, worked out once per change of what routes it: each list row and status line asks, through
    /// `canProcess`, at every redraw, and routing reads the whole catalog.
    var routedSpeech: SpeechRoute {
        let inputs = SpeechRoute.Inputs(catalogRevision: catalogRevision, selections: modelSelections, preferences: processingPreferences,
                                        language: transcriptionLanguage, installed: installedModels, detectSpeakers: detectSpeakers,
                                        standsIn: transcriptionStandsIn)
        if let memo = routeMemo, memo.key == inputs { return memo.route }
        let route = speechRoute
        routeMemo = (inputs, route)
        return route
    }

    /// The models a job queued now needs on this Mac to transcribe: transcription (the system's speech model while the
    /// chosen one downloads), then speakers and their voice profiles (the language check's model is optional). The
    /// summary model isn't one: a transcript never waits for it.
    var routedTranscribingModelIDs: [String] {
        let route = routedSpeech
        return [route.transcription.model] + (route.findsSpeakers ? route.speakerModels : [])
    }

    /// Everything the current choices run here once downloaded, in the order their downloads go: the chosen
    /// transcription model and the speaker models first, then the summary model, so a transcript waits only for the
    /// first (and for none of them while the system's speech model stands in).
    var routedRequiredModelIDs: [String] {
        let route = routedSpeech
        return [route.chosenTranscription] + (detectSpeakers ? route.speakerModels : []) + [summaryModel]
    }

    /// A summary model installed here that this Mac has the memory for.
    func isUsableSummaryModel(_ id: String) -> Bool {
        installedModels.contains(id) && modelCatalog.model(id).map { LiveModelChoices.fitsMemory($0, physicalMemory: physicalMemory) } == true
    }

    /// A Summarize Again job queued with another model than Settings' (it runs here, `summarizesHere`) whose model went while
    /// it waited (uninstalled, or no longer fits) runs the Settings model instead, still on this Mac: never the cloud,
    /// and not waiting for a model that isn't coming.
    func jobWithUsableSummaryModel(_ job: ProcessingJob) -> ProcessingJob {
        guard job.mode == .summaryOnly, job.summarizesHere, job.summaryModelID != summaryModel, !isUsableSummaryModel(job.summaryModelID) else { return job }
        return job.withSummaryModel(summaryModel, revision: installedRevisions[summaryModel])
    }

    /// A job for `meetingID`, frozen with the routed models, these preferences with the library's language, and their
    /// revisions.
    func makeJob(meetingID: UUID, mode: ProcessingRequest.Mode, templateID: String? = nil, upgrade: ProcessingRequest.Upgrade? = nil,
                 summarizesHere: Bool = false, summarizesInCloud: Bool = false, summaryModelID: String? = nil,
                 speakers: ProcessingRequest.SpeakerAsk? = nil) -> ProcessingJob {
        let route = speechRoute
        var preferences = processingPreferences
        var (speakerModel, embedder, detects) = (route.speakerModel, route.voiceEmbedder, route.findsSpeakers)
        // Identify Speakers for this conversation alone (`SpeakerAsk`): the number of people the person said, whatever
        // Settings says, and speakers found even where Tell speakers apart is off, so the speaker models are what it waits
        // for. The routed model, routed again for that number as `speechRoute` routes Settings' (with its voice-profile
        // model); one that can't take the number isn't run (`takesSpeakerAsk`). Settings stays as it is.
        if let speakers {
            let catalog = modelCatalog, engines = runtime.engines
            preferences.speakerOptions.expectedSpeakerCount = speakers.count
            speakerModel = ModelRouting.diarizer(selected: route.speakerModel, expectedSpeakers: speakers.count, catalog: catalog,
                                                 engines: engines, installed: installedModels)
            if speakerModel != route.speakerModel {
                embedder = ModelRouting.voiceEmbedder(diarizer: speakerModel, selections: ModelRouting.withDefaultVoiceEmbedder(modelSelections, catalog: catalog, engines: engines),
                                                      catalog: catalog, engines: engines)
            }
            detects = true
        }
        preferences.speakerModelID = speakerModel
        preferences.transcriptionLanguage = route.transcription.language
        // A summary the person asked to make with another installed model: that job only (its revision frozen too). One
        // that went (uninstalled, or no longer fits) since the menu was drawn runs the chosen model, never a download.
        var revisions = frozenModelRevisions
        let usable = summaryModelID.flatMap { isUsableSummaryModel($0) ? $0 : nil }
        if let usable, let revision = installedRevisions[usable] { revisions[usable] = revision }
        return ProcessingJob(meetingID: meetingID, mode: mode, transcriptionModelID: route.transcription.model, summaryModelID: usable ?? summaryModel,
                             detectSpeakers: detects, preferences: preferences, templateID: templateID,
                             revisions: revisions, voiceEmbeddingModelID: embedder,
                             languageFallbackModelID: route.transcription.fallback, smallTasksModelID: smallTasksModel, photoModelID: photoModel?.id,
                             upgrade: upgrade, speakers: speakers, summarizesHere: summarizesHere, summarizesInCloud: summarizesInCloud)
    }
}
