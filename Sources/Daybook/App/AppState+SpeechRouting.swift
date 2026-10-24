import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// The models a job queued now runs, after routing (docs/models.md, "Routing"): the transcription
/// language picks the transcription model (or, for Automatic, a model to check the language with);
/// an expected speaker count above the speaker model's limit picks one without it; a speaker model
/// without voice profiles gets an embedding model. Decided here, frozen into the job.
struct SpeechRoute: Equatable {
    var transcription: TranscriptionRoute
    var speakerModel: String
    var voiceEmbedder: String?
}

extension AppState {
    var speechRoute: SpeechRoute {
        let catalog = modelCatalog, engines = runtime.engines, preferences = processingPreferences
        let other = TranscriptionRouting.otherLanguagesModel(selected: transcriptionModel, chosen: preferences.otherLanguagesModelID,
                                                             catalog: catalog, engines: engines, installed: installedModels)
        let transcription = TranscriptionRouting.route(selected: transcriptionModel, language: preferences.transcriptionLanguage,
                                                       otherLanguages: other, catalog: catalog)
        let speakerModel = ModelRouting.diarizer(selected: preferences.speakerModelID, expectedSpeakers: preferences.speakerOptions.expectedSpeakerCount,
                                                 catalog: catalog, engines: engines, installed: installedModels)
        let selections = ModelRouting.withDefaultVoiceEmbedder(modelSelections, catalog: catalog, engines: engines)
        let embedder = ModelRouting.voiceEmbedder(diarizer: speakerModel, selections: selections, catalog: catalog, engines: engines)
        return SpeechRoute(transcription: transcription, speakerModel: speakerModel, voiceEmbedder: embedder)
    }

    /// The models a job queued now needs on this Mac (the language check's model is optional).
    var routedRequiredModelIDs: [String] {
        let route = speechRoute
        return [route.transcription.model, summaryModel] + (detectSpeakers ? [route.speakerModel] + [route.voiceEmbedder].compactMap { $0 } : [])
    }

    /// A job for `meetingID`, frozen with the routed models, these preferences, and their revisions.
    func makeJob(meetingID: UUID, mode: ProcessingRequest.Mode, templateID: String? = nil) -> ProcessingJob {
        let route = speechRoute
        var preferences = processingPreferences
        preferences.speakerModelID = route.speakerModel
        return ProcessingJob(meetingID: meetingID, mode: mode, transcriptionModelID: route.transcription.model, summaryModelID: summaryModel,
                             detectSpeakers: detectSpeakers, preferences: preferences, templateID: templateID,
                             revisions: frozenModelRevisions, voiceEmbeddingModelID: route.voiceEmbedder,
                             languageFallbackModelID: route.transcription.fallback, smallTasksModelID: smallTasksModel)
    }
}
