import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// The Mac's engine over a scripted `MeetingInference`: what it asks the models for, what each run
/// records about how it was made, and how it reuses a saved transcript to identify speakers again.
final class InferenceProcessingEngineTests: XCTestCase {
    private final class Scripted: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var failsDiarization = false
        /// What the small-tasks model answers; nil throws, as Apple Intelligence turned off would.
        var smallTasks: SmallTaskResult?
        var calls: [String] { lock.withLock { _calls } }

        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            lock.withLock { _calls.append("transcribe \(model) \(glossary.joined(separator: ","))") }
            progress(IntelligenceProgress(0.5, "Transcribing"))
            let words = [RecognizedWord(text: " Ship", start: 0, end: 0.4, confidence: 0.9), RecognizedWord(text: " Friday", start: 0.5, end: 1, confidence: 0.8)]
            return RecognitionResult(segments: [RecognizedSegment(start: 0, end: 1, text: " Ship Friday", confidence: 0.9, words: words)],
                                     language: "en", duration: 12)
        }

        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            lock.withLock { _calls.append("diarize \(model)") }
            struct Failure: LocalizedError { var errorDescription: String? { "the model wasn't found" } }
            if failsDiarization { throw Failure() }
            return SpeakerAnalysis(turns: [SpeakerTurn(speakerID: "0", start: 0, end: 10, confidence: 1)], embeddings: ["0": [1, 0]],
                                   embeddingModelID: "community-1", warnings: [])
        }

        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            lock.withLock { _calls.append("summarize \(model) \(template.rawValue)") }
            return GeneratedMeetingNotes(summary: MeetingSummary(kind: template == .auto ? .general : template, title: "Summarizer title",
                                                                 overview: "Shipping Friday"),
                                         suggestedTerms: ["Friday"], rawResponse: "{}", warnings: ["Check the owner."])
        }

        func performSmallTasks(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                               progress: @escaping IntelligenceProgressHandler) async throws -> SmallTaskResult {
            lock.withLock { _calls.append("smallTasks \(model) \(template.rawValue)") }
            guard let smallTasks else { throw LocalIntelligenceError.unavailable(model: model.id, reason: "Turn on Apple Intelligence") }
            return smallTasks
        }
    }

    private let configuration = InferenceProcessingEngine.Configuration(
        transcriptionModel: "whisper-base", summaryModel: "qwen-1.5b", detectSpeakers: true,
        speakerModel: "community-1/offline", speakerOptions: SpeakerAnalysisOptions(), fingerprint: "abc123",
        speakerMatchThreshold: 0.82, speakerMatchMargin: 0.06)

    private func input(_ mode: ProcessingRequest.Mode, previous: TrackTranscript? = nil) -> TrackProcessingInput {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.caf", fileName: "a.caf", duration: 12, offset: 1.5, sha256: "a")
        return TrackProcessingInput(meetingID: UUID(), track: track, audioURL: URL(fileURLWithPath: "/tmp/a.caf"), mode: mode,
                                    previousTranscript: previous, vocabulary: ["Daybook"])
    }

    func testARunRecordsItsModelsSettingsSpeakersAndWords() async throws {
        let inference = Scripted()
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration)
        let reported = Reported()
        let output = try await engine.transcribe(input(.newAudio), progress: { reported.add($0) })

        XCTAssertEqual(inference.calls, ["transcribe whisper-base Daybook", "diarize community-1/offline"])
        XCTAssertEqual(reported.values.first, ProcessingProgress(fraction: 0.5, message: "Transcribing"))
        let run = output.transcript
        XCTAssertEqual(run.modelID, "whisper-base")
        XCTAssertEqual(run.knownOffset, 1.5)
        XCTAssertEqual(run.language, "en")
        XCTAssertEqual(run.words?.map(\.text), [" Ship", " Friday"])
        XCTAssertEqual(run.processingSettings?.parameters["mode"], "newAudio")
        XCTAssertEqual(run.processingSettings?.parameters["configuration"], "abc123")
        XCTAssertEqual(run.processingSettings?.parameters["speakerModel"], "community-1/offline")
        XCTAssertEqual(run.segments.map(\.text), ["Ship Friday"])
        XCTAssertEqual(run.segments.first?.speakerID, "\(run.id.uuidString):0", "Speaker labels are namespaced to the run")
        XCTAssertEqual(output.speakers.map(\.id), ["\(run.id.uuidString):0"])
        XCTAssertEqual(output.speakers.first?.embedding, [1, 0])
        XCTAssertEqual(output.speakerEmbeddingModelID, "community-1")
        XCTAssertEqual(output.duration, 12)
        XCTAssertTrue(output.notices.isEmpty)
    }

    func testIdentifyingSpeakersAgainReusesTheSavedWords() async throws {
        let inference = Scripted()
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration)
        let earlier = TrackTranscript(trackID: UUID(), segments: [], language: "en", modelID: "whisper-small",
                                      words: [TranscriptWord(text: " Hello", start: 0, end: 0.5, confidence: 0.9)])
        let output = try await engine.transcribe(input(.speakerRefresh, previous: earlier), progress: { _ in })
        XCTAssertEqual(inference.calls, ["diarize community-1/offline"], "No transcription, only speakers")
        XCTAssertEqual(output.transcript.modelID, "whisper-small", "The run keeps the model that heard the words")
        XCTAssertEqual(output.transcript.segments.map(\.text), ["Hello"])

        let older = TrackTranscript(trackID: UUID(), segments: [TranscriptSegment(trackID: UUID(), start: 0, end: 2, text: "Hello")], modelID: "whisper-base")
        let fallback = try await engine.transcribe(input(.speakerRefresh, previous: older), progress: { _ in })
        XCTAssertEqual(fallback.notices.count, 1, "An older transcript without word timings says so")
    }

    func testSpeakerDetectionFailingKeepsTheTranscriptUnlessThatWasTheJob() async throws {
        let inference = Scripted()
        inference.failsDiarization = true
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration)
        let output = try await engine.transcribe(input(.newAudio), progress: { _ in })
        XCTAssertEqual(output.notices, ["Transcription succeeded, but speaker detection failed for a.caf: the model wasn't found"])
        XCTAssertNil(output.transcript.segments.first?.speakerID)
        do {
            _ = try await engine.transcribe(input(.speakerRefresh, previous: output.transcript), progress: { _ in })
            XCTFail("Identify Speakers Again fails when speaker detection does")
        } catch {}
    }

    func testSummariesRecordTheirTemplateAndRefuseSilence() async throws {
        let inference = Scripted()
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration)
        var meeting = Meeting(title: "Standup", unifiedTranscript: [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "Ship Friday")])
        let template = SummaryTemplate.builtIns.first { $0.id == "scrum" }
        let output = try await engine.summarize(meeting, template: template, vocabulary: ["Daybook"], progress: { _ in })
        XCTAssertEqual(inference.calls, ["summarize qwen-1.5b scrum"])
        XCTAssertEqual(output.summary.processingSettings?.modelID, "qwen-1.5b")
        XCTAssertEqual(output.summary.processingSettings?.parameters["templateID"], "scrum")
        XCTAssertEqual(output.summary.processingSettings?.parameters["configuration"], "abc123")
        XCTAssertEqual(output.suggestedTerms, ["Friday"])
        XCTAssertEqual(output.warnings, ["Check the owner."])

        meeting.unifiedTranscript = []
        do {
            _ = try await engine.summarize(meeting, template: nil, vocabulary: [], progress: { _ in })
            XCTFail("Nothing to summarize")
        } catch DaybookError.noSpeech {}
    }

    /// The iPhone's local summarizer (`LocalSummarizing`) is this engine's summary step: the same
    /// pipeline, provenance, and suggested terms, with progress as a fraction.
    func testBehaviorTheLocalSummarizerIsTheEnginesSummaryStep() async throws {
        let inference = Scripted()
        let summarizer: any LocalSummarizing = LocalSummarizer(engine: InferenceProcessingEngine(inference: inference, configuration: configuration))
        XCTAssertEqual(summarizer.model, "qwen-1.5b")
        XCTAssertTrue(summarizer.canSummarize)
        let fractions = Fractions()
        let output = try await summarizer.summarize(meeting(), template: nil, vocabulary: ["Daybook"]) { fractions.add($0) }
        XCTAssertEqual(inference.calls, ["summarize qwen-1.5b auto"])
        XCTAssertEqual(output.summary.processingSettings?.modelID, "qwen-1.5b")
        XCTAssertEqual(output.summary.processingSettings?.parameters["configuration"], "abc123")
        XCTAssertEqual(output.suggestedTerms, ["Friday"])
        XCTAssertEqual(output.warnings, ["Check the owner."])
        XCTAssertTrue(fractions.values.allSatisfy { (0...1).contains($0) })
    }

    private final class Fractions: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Double] = []
        var values: [Double] { lock.withLock { _values } }
        func add(_ value: Double) { lock.withLock { _values.append(value) } }
    }

    func testWithoutASmallTasksModelTheSummarizerNamesTheConversationAsBefore() async throws {
        let inference = Scripted()
        inference.smallTasks = SmallTaskResult(title: "Never used")
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration)
        let output = try await engine.summarize(meeting(), template: nil, vocabulary: [], progress: { _ in })
        XCTAssertEqual(inference.calls, ["summarize qwen-1.5b auto"])
        XCTAssertEqual(output.summary.title, "Summarizer title")
        XCTAssertEqual(output.summary.kind, .general)
        XCTAssertEqual(output.suggestedTerms, ["Friday"])
        XCTAssertNil(output.summary.processingSettings?.parameters["smallTasksModel"])
        XCTAssertEqual(output.summary.processingSettings?.parameters.count, 3, "The summary records exactly what it did before")
    }

    func testTheSmallTasksModelChoosesTitleKindAndTermsBeforeTheSummary() async throws {
        let inference = Scripted()
        let provenance = ModelProvenance(family: "apple-foundation-models", variant: "system", revision: "system",
                                         engine: "appleFoundationModels", engineVersion: "1 (Foundation Models, macOS 27.0)")
        inference.smallTasks = SmallTaskResult(title: "Friday launch", kind: .scrum, suggestedTerms: ["Daybook", "friday"], provenance: provenance)
        var withSmallTasks = configuration
        withSmallTasks.smallTasksModel = "apple-foundation-models/system"
        let engine = InferenceProcessingEngine(inference: inference, configuration: withSmallTasks)
        let output = try await engine.summarize(meeting(), template: nil, vocabulary: ["Ship"], progress: { _ in })
        XCTAssertEqual(inference.calls, ["smallTasks apple-foundation-models/system auto", "summarize qwen-1.5b scrum"],
                       "The kind it chose shapes the summary's sections")
        XCTAssertEqual(output.summary.title, "Friday launch")
        XCTAssertEqual(output.summary.kind, .scrum)
        XCTAssertEqual(output.suggestedTerms, ["Daybook", "friday"], "Merged without duplicates, the small-tasks model's first")
        XCTAssertEqual(output.summary.processingSettings?.modelID, "qwen-1.5b", "The summary's model is still the summarizer")
        XCTAssertEqual(output.summary.processingSettings?.parameters["smallTasksModel"], "apple-foundation-models/system")
        XCTAssertEqual(output.summary.processingSettings?.parameters["smallTasksEngine"], "appleFoundationModels 1 (Foundation Models, macOS 27.0)")
    }

    func testAChosenTemplateKeepsItsKind() async throws {
        let inference = Scripted()
        inference.smallTasks = SmallTaskResult(title: "Check-in", kind: nil)
        var withSmallTasks = configuration
        withSmallTasks.smallTasksModel = "apple-foundation-models/system"
        let engine = InferenceProcessingEngine(inference: inference, configuration: withSmallTasks)
        let template = SummaryTemplate.builtIns.first { $0.kind == .therapy }
        XCTAssertNotNil(template)
        let output = try await engine.summarize(meeting(), template: template, vocabulary: [], progress: { _ in })
        XCTAssertEqual(inference.calls, ["smallTasks apple-foundation-models/system therapy", "summarize qwen-1.5b therapy"])
        XCTAssertEqual(output.summary.kind, .therapy)
        XCTAssertEqual(output.summary.title, "Check-in")
    }

    func testWhenTheSmallTasksModelCantRunTheSummarizersAnswersStand() async throws {
        let inference = Scripted()
        inference.smallTasks = nil
        var withSmallTasks = configuration
        withSmallTasks.smallTasksModel = "apple-foundation-models/system"
        let engine = InferenceProcessingEngine(inference: inference, configuration: withSmallTasks)
        let output = try await engine.summarize(meeting(), template: nil, vocabulary: [], progress: { _ in })
        XCTAssertEqual(inference.calls, ["smallTasks apple-foundation-models/system auto", "summarize qwen-1.5b auto"])
        XCTAssertEqual(output.summary.title, "Summarizer title")
        XCTAssertEqual(output.summary.kind, .general)
        XCTAssertEqual(output.suggestedTerms, ["Friday"])
        XCTAssertEqual(output.warnings, ["Check the owner."], "No notice: nothing the person needs to do")
        XCTAssertNil(output.summary.processingSettings?.parameters["smallTasksModel"])
    }

    func testAnInferenceWithoutSmallTasksSupportFallsBackToo() async throws {
        struct Minimal: MeetingInference {
            func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
                RecognitionResult(segments: [], language: nil, duration: 0)
            }
            func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
                SpeakerAnalysis(turns: [], embeddings: [:])
            }
            func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                           templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
                GeneratedMeetingNotes(summary: MeetingSummary(title: "Own title", overview: "x"), suggestedTerms: [], rawResponse: "", warnings: [])
            }
        }
        var withSmallTasks = configuration
        withSmallTasks.smallTasksModel = "apple-foundation-models/system"
        let output = try await InferenceProcessingEngine(inference: Minimal(), configuration: withSmallTasks)
            .summarize(meeting(), template: nil, vocabulary: [], progress: { _ in })
        XCTAssertEqual(output.summary.title, "Own title")
    }

    private func meeting() -> Meeting {
        Meeting(title: "Untitled", unifiedTranscript: [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "Ship Friday")])
    }

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [ProcessingProgress] = []
        var values: [ProcessingProgress] { lock.withLock { _values } }
        func add(_ value: ProcessingProgress) { lock.withLock { _values.append(value) } }
    }
}
