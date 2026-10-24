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
}

extension LocalIntelligenceRuntime: MeetingInference {}
