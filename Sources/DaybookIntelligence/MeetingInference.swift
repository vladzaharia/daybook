import DaybookCore
import DaybookKit
import Foundation

/// Local inference for processing. The app uses `LocalIntelligenceRuntime`; tests inject a fake so
/// the queue, enhancement, and summaries run without models. Models are named by reference
/// (a variant key and, for queued jobs, the revision they froze), never by engine.
public protocol MeetingInference: Sendable {
    func transcribe(url: URL, model: ModelReference, glossary: [String],
                    progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult
    /// The same in a known language (a BCP-47 code); nil detects it (`TranscriptionRouter`).
    func transcribe(url: URL, model: ModelReference, glossary: [String], language: String?,
                    progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult
    /// What `model` can do, from the catalog: language routing reads its `languages`. Nil when unknown.
    func capabilities(of model: ModelReference) async -> ModelCapabilities?
    func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions,
                 progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis
    /// Voice profiles for turns a diarizer found without them (`ModelRouting.voiceEmbedder`).
    func embedVoices(url: URL, analysis: SpeakerAnalysis, model: ModelReference,
                     progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis
    func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                   templateInstructions: String?, highlightEvidence: String?,
                   progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes
    /// A title, the meeting kind, and vocabulary suggestions from the small-tasks model (`SmallTasks`).
    func performSmallTasks(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                           progress: @escaping IntelligenceProgressHandler) async throws -> SmallTaskResult
    /// What photos show (`DescribingImages`): Apple Vision, or a vision-language model's captions.
    func describeImages(_ requests: [ImageDescriptionRequest], model: ModelReference,
                        progress: @escaping IntelligenceProgressHandler) async throws -> [ImageDescription]
    /// A summary that may place `photos` under its sections (`MeetingSynthesis`). The default ignores
    /// the photos, for inference that predates them.
    func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                   templateInstructions: String?, highlightEvidence: String?, photos: [PhotoEvidence],
                   progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes
    /// What the operating system's sound classifier hears in a recording (`SoundClassifier`): speech,
    /// music, an audience, and the level, for leaving background audio out. Nil when it can't run;
    /// the default (inference that predates it, and tests' fakes) hears nothing, so nothing is left out.
    func classifySound(url: URL, progress: @escaping IntelligenceProgressHandler) async throws -> BackgroundAudioAnalysis?
    /// A summary from the transcript with the person's notes and bookmarks in place (`SummarySource`):
    /// passages near them carry more weight, and notes are folded in where they belong. The default
    /// hands inference that takes strings the transcript, notes, and bookmark evidence as before.
    func summarize(_ source: SummarySource, template: MeetingKind, glossary: [String], model: ModelReference,
                   templateInstructions: String?, photos: [PhotoEvidence],
                   progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes
}

extension MeetingInference {
    public func transcribe(url: URL, model: ModelReference, glossary: [String], language: String?,
                           progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        try await transcribe(url: url, model: model, glossary: glossary, progress: progress)
    }

    public func capabilities(of model: ModelReference) async -> ModelCapabilities? { nil }

    public func embedVoices(url: URL, analysis: SpeakerAnalysis, model: ModelReference,
                            progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
        throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "voice profiles")
    }

    public func performSmallTasks(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                                  progress: @escaping IntelligenceProgressHandler) async throws -> SmallTaskResult {
        throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "titles")
    }

    public func describeImages(_ requests: [ImageDescriptionRequest], model: ModelReference,
                               progress: @escaping IntelligenceProgressHandler) async throws -> [ImageDescription] {
        throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "photos")
    }

    public func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                          templateInstructions: String?, highlightEvidence: String?, photos: [PhotoEvidence],
                          progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
        try await summarize(transcript: transcript, notes: notes, template: template, glossary: glossary, model: model,
                            templateInstructions: templateInstructions, highlightEvidence: highlightEvidence, progress: progress)
    }
}

extension MeetingInference {
    public func classifySound(url: URL, progress: @escaping IntelligenceProgressHandler) async throws -> BackgroundAudioAnalysis? { nil }

    public func summarize(_ source: SummarySource, template: MeetingKind, glossary: [String], model: ModelReference,
                          templateInstructions: String?, photos: [PhotoEvidence],
                          progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
        try await summarize(transcript: source.transcript, notes: source.notesText, template: template, glossary: glossary, model: model,
                            templateInstructions: templateInstructions, highlightEvidence: source.highlightText, photos: photos, progress: progress)
    }
}

extension LocalIntelligenceRuntime: MeetingInference {}
