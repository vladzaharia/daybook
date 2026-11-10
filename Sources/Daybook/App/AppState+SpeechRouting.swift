import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// The models a job queued now runs, after routing (docs/models.md, "Routing"): the transcription
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
        var installed: Set<String>
        var detectSpeakers: Bool
        var standsIn: Bool
    }
}

extension AppState {
    var speechRoute: SpeechRoute {
        let catalog = modelCatalog, engines = runtime.engines, preferences = processingPreferences, installed = installedModels
        let other = TranscriptionRouting.otherLanguagesModel(selected: transcriptionModel, chosen: preferences.otherLanguagesModelID,
                                                             catalog: catalog, engines: engines, installed: installed)
        let chosen = TranscriptionRouting.route(selected: transcriptionModel, language: preferences.transcriptionLanguage,
                                                otherLanguages: other, catalog: catalog)
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
                                        installed: installedModels, detectSpeakers: detectSpeakers, standsIn: transcriptionStandsIn)
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

    /// A job for `meetingID`, frozen with the routed models, these preferences, and their revisions.
    func makeJob(meetingID: UUID, mode: ProcessingRequest.Mode, templateID: String? = nil, upgrade: ProcessingRequest.Upgrade? = nil,
                 summarizesHere: Bool = false, summarizesInCloud: Bool = false) -> ProcessingJob {
        let route = speechRoute
        var preferences = processingPreferences
        preferences.speakerModelID = route.speakerModel
        return ProcessingJob(meetingID: meetingID, mode: mode, transcriptionModelID: route.transcription.model, summaryModelID: summaryModel,
                             detectSpeakers: route.findsSpeakers, preferences: preferences, templateID: templateID,
                             revisions: frozenModelRevisions, voiceEmbeddingModelID: route.voiceEmbedder,
                             languageFallbackModelID: route.transcription.fallback, smallTasksModelID: smallTasksModel, photoModelID: photoModel?.id,
                             upgrade: upgrade, summarizesHere: summarizesHere, summarizesInCloud: summarizesInCloud)
    }
}
