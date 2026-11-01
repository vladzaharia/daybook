import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// What step the work is in comes from the step that reports, never from how a model words its progress: the
/// page, the list, Floating Notes, a phone, and the request's claim all read `ProcessingProgress.stage`.
final class ProcessingStageReportingTests: XCTestCase {
    /// Every step reports in words that would fool a guess from the message.
    private final class Misleading: MeetingInference, @unchecked Sendable {
        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            progress(IntelligenceProgress(0.5, "Detecting speaker turns with Sortformer"))
            return RecognitionResult(segments: [RecognizedSegment(start: 0, end: 4, text: " Ship it Friday", confidence: 0.9,
                                                                  words: [RecognizedWord(text: " Ship", start: 0, end: 1, confidence: 0.9)])],
                                     language: "en", duration: 4)
        }

        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            progress(IntelligenceProgress(0.2, "Transcribed 3 of 9 seconds"))
            // No voice profiles from the diarizer: the embedding model makes them.
            return SpeakerAnalysis(turns: [SpeakerTurn(speakerID: "0", start: 0, end: 4, confidence: 1)], embeddings: [:])
        }

        func classifySound(url: URL, progress: @escaping IntelligenceProgressHandler) async throws -> BackgroundAudioAnalysis? {
            progress(IntelligenceProgress(0.3, "Listening for music and TV"))
            return nil
        }

        func embedVoices(url: URL, analysis: SpeakerAnalysis, model: ModelReference, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            progress(IntelligenceProgress(0.4, "Making voice profiles"))
            return SpeakerAnalysis(turns: analysis.turns, embeddings: ["0": [1, 0]], embeddingModelID: "embedder")
        }

        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            progress(IntelligenceProgress(0.6, "Transcribing the summary's sections"))
            return GeneratedMeetingNotes(summary: MeetingSummary(kind: .general, title: "T", overview: "O"), suggestedTerms: [], rawResponse: "{}", warnings: [])
        }

        func performSmallTasks(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                               progress: @escaping IntelligenceProgressHandler) async throws -> SmallTaskResult {
            progress(IntelligenceProgress(0.1, "Identifying speakers' titles"))
            throw LocalIntelligenceError.unavailable(model: model.id, reason: "Turn on Apple Intelligence")
        }
    }

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [ProcessingProgress] = []
        var values: [ProcessingProgress] { lock.withLock { _values } }
        func add(_ value: ProcessingProgress) { lock.withLock { _values.append(value) } }
    }

    private func engine(detectSpeakers: Bool = true) -> InferenceProcessingEngine {
        InferenceProcessingEngine(inference: Misleading(), configuration: .init(
            transcriptionModel: "parakeet/ultra", summaryModel: "gemma-4/e2b-4bit", detectSpeakers: detectSpeakers,
            speakerModel: "sortformer/2.1", voiceEmbeddingModel: "community-1/embedding", smallTasksModel: "apple/foundation",
            speakerOptions: SpeakerAnalysisOptions(), fingerprint: "f", speakerMatchThreshold: 0.8, speakerMatchMargin: 0.05))
    }

    private func input() -> TrackProcessingInput {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.caf", fileName: "a.caf", duration: 4, offset: 0)
        return TrackProcessingInput(meetingID: UUID(), track: track, audioURL: URL(fileURLWithPath: "/dev/null"), mode: .newAudio)
    }

    func testBehaviorEachStepReportsItsOwnStageWhateverItsWordsSay() async throws {
        let reported = Reported()
        _ = try await engine().transcribe(input(), progress: { reported.add($0) })
        XCTAssertEqual(reported.values.map(\.message), ["Detecting speaker turns with Sortformer", "Transcribed 3 of 9 seconds",
                                                        "Listening for music and TV", "Making voice profiles"])
        XCTAssertEqual(reported.values.map(\.stage), [.transcribing, .identifyingSpeakers, .identifyingSpeakers, .identifyingSpeakers],
                       "voice profiles and the background-audio check are part of identifying speakers")
    }

    func testBehaviorWithoutSpeakersTheBackgroundCheckIsPartOfTranscribing() async throws {
        let reported = Reported()
        _ = try await engine(detectSpeakers: false).transcribe(input(), progress: { reported.add($0) })
        XCTAssertEqual(reported.values.map(\.stage), [.transcribing, .transcribing])
    }

    func testBehaviorTheSummaryAndItsSmallTasksReportSummarizing() async throws {
        let reported = Reported()
        let segment = TranscriptSegment(trackID: UUID(), start: 0, end: 4, text: "Ship it Friday", speakerID: "0")
        let meeting = Meeting(title: "Sync", unifiedTranscript: [segment], speakers: [Speaker(id: "0", name: "Alex")])
        _ = try await engine().summarize(meeting, template: nil, vocabulary: [], progress: { reported.add($0) })
        XCTAssertEqual(reported.values.map(\.stage), [.summarizing, .summarizing])
    }

    func testBehaviorARuntimeThatNamesItsStepIsTakenAtItsWord() {
        let reported = Reported()
        let handler = InferenceProcessingEngine.reporting(.transcribing, to: { reported.add($0) })
        handler(IntelligenceProgress(0.5, "Both at once", stage: .identifyingSpeakers))
        handler(IntelligenceProgress(0.6, "Words"))
        XCTAssertEqual(reported.values.map(\.stage), [.identifyingSpeakers, .transcribing])
        // A report that doesn't say (reading photos) leaves the step to whatever came before.
        let unnamed = Reported()
        InferenceProcessingEngine.reporting(nil, to: { unnamed.add($0) })(IntelligenceProgress(0.1, "Reading photos"))
        XCTAssertEqual(unnamed.values.map(\.stage), [nil])
    }

    func testBehaviorTheEnginesErrorsKnowTheirFailureKind() {
        XCTAssertEqual(ProcessingRequest.FailureKind(LocalIntelligenceError.modelNotInstalled("parakeet/ultra")), .modelsMissing)
        XCTAssertEqual(ProcessingRequest.FailureKind(LocalIntelligenceError.unavailable(model: "apple/foundation", reason: "Turn on Apple Intelligence")),
                       .plainReason, "its sentence says what to do")
        XCTAssertEqual(ProcessingRequest.FailureKind(LocalIntelligenceError.busy), .plainReason)
        XCTAssertEqual(ProcessingRequest.FailureKind(LocalIntelligenceError.unknownModel("x")), .other)
        XCTAssertEqual(ProcessingRequest.FailureKind(DaybookError.noSpeech), .noSpeech)
        struct MemoryError: LocalizedError { var errorDescription: String? { "Metal ran out of memory while loading the model." } }
        XCTAssertEqual(ProcessingRequest.FailureKind(MemoryError()), .modelCouldNotStart, "an engine's own error reads from its words")
    }
}
