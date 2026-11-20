import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Notebook pages in summaries: handwriting as notes (H), sketches as picture evidence (S) on the device only, pictures and
/// handwriting placed in the parts of a long conversation by time, and a conversation with no speech. No weights are loaded.
final class NotebookSummaryTests: XCTestCase {
    private typealias Pages = NotebookTestPages

    private final class WordModel: SynthesisModel, @unchecked Sendable {
        let supportsStructuredOutput = false
        var checksNotes = false
        private let lock = NSLock()
        private var vocabulary: [String] = [], index: [String: Int] = [:]
        private var _prompts: [String] = []
        var prompts: [String] { lock.withLock { _prompts } }
        var reply: (String) -> String = { _ in "{}" }
        func encode(_ text: String) async -> [Int] {
            lock.withLock {
                text.split(whereSeparator: \.isWhitespace).map { word in
                    let key = String(word)
                    if let found = index[key] { return found }
                    vocabulary.append(key); index[key] = vocabulary.count - 1
                    return vocabulary.count - 1
                }
            }
        }
        func decode(_ tokens: [Int]) async -> String { lock.withLock { tokens.map { vocabulary[$0] }.joined(separator: " ") } }
        func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
            lock.withLock { _prompts.append(prompt) }
            return reply(prompt)
        }
        func respond(instructions: String, prompt: String, schema: String, maxTokens: Int) async throws -> String {
            struct Unsupported: Error {}
            throw Unsupported()
        }
    }

    private let track = UUID()
    private let summary = #"{"kind":"general","title":"Launch","overview":"Venue and pricing.","sections":[{"heading":"Layout","body":"The hall layout.","photos":["S1","P1"]}],"actionItems":[],"terms":[]}"#

    private func flat(_ prompt: String) -> String { prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Speech, one handwriting passage at 30 s, one sketch at 40 s with a reading, one sketch with no time.
    private func meeting(speech: Bool = true) -> Meeting {
        let id = UUID()
        let sketch = Pages.passage(id, key: "s", words: "words inside the drawing", kind: .sketch, time: 40, y: 100)
        let loose = Pages.passage(id, key: "u", words: nil, kind: .sketch, y: 200)
        var page = Pages.page(id, [Pages.passage(id, key: "w", words: "venue holds 120 people", time: 30), sketch, loose])
        page.sketches = [Pages.analysis(of: sketch, caption: "Floor plan of hall B", text: "Stage"), Pages.analysis(of: loose, caption: "Loading dock diagram")]
        var meeting = Meeting(title: "Launch", speakers: [Speaker(id: "alex", name: "Alex")])
        if speech {
            meeting.unifiedTranscript = [TranscriptSegment(trackID: track, start: 0, end: 8, text: "Let's plan the venue layout.", speakerID: "alex"),
                                         TranscriptSegment(trackID: track, start: 60, end: 68, text: "The stage goes by the entrance.", speakerID: "alex")]
        }
        meeting.pages = [page]
        return meeting
    }

    // MARK: The prompt

    func testBehaviorPromptCarriesHandwritingAndSketchEvidence() async throws {
        let model = WordModel()
        let reply = summary
        model.reply = { prompt in prompt.contains("Extract ALL explicit agreed tasks") ? #"{"actions":[]}"# : reply }
        let photo = PhotoEvidence(id: UUID(), label: "P1", time: 20, caption: "Whiteboard")
        let notebook = meeting()
        let pictures = NotebookPlacement.candidates(in: notebook)
        let generated = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: MeetingEvidence.summarySource(notebook),
                                                            template: .auto, glossary: [], photos: [photo] + pictures, progress: { _ in })
        let final = flat(try XCTUnwrap(model.prompts.first { $0.contains("Write a concise summary") }))
        XCTAssertTrue(final.contains("NOTE H1, handwritten on page 1 by the user (not spoken; read from handwriting, so a word may be misread): venue holds 120 people"))
        XCTAssertTrue(final.contains("[S1]; drawn at 00:40 on page 1; shows: Floor plan of hall B; text in the drawing: Stage"))
        XCTAssertTrue(final.contains("[S2]; drawn outside the recording on page 1; shows: Loading dock diagram"))
        XCTAssertTrue(final.contains("Labels starting with S are sketches the user drew in their notebook"))
        XCTAssertFalse(final.contains("words inside the drawing"), "A sketch's own words are its drawing's, not the user's notes")
        let section = try XCTUnwrap(generated.summary.sections.first)
        XCTAssertEqual(section.sketchIDs, [pictures[0].id], "S1 goes to sketchIDs, P1 to photoIDs")
        XCTAssertEqual(section.photoIDs, [photo.id])
        // Without sketches the final prompt says nothing about them.
        let bare = WordModel()
        bare.reply = { prompt in prompt.contains("Extract ALL explicit agreed tasks") ? #"{"actions":[]}"# : reply }
        _ = try await MeetingSynthesis.generate(model: bare, modelID: "gemma", source: MeetingEvidence.summarySource(meeting()), template: .auto,
                                                glossary: [], photos: [photo], progress: { _ in })
        XCTAssertFalse(try XCTUnwrap(bare.prompts.first { $0.contains("Write a concise summary") }).contains("Labels starting with S"))
    }

    func testBehaviorTheNotePayloadTheModelReceivesMarksHandwritingAndItsPage() throws {
        let source = MeetingEvidence.summarySource(meeting())
        let json = SynthesisJSON.string(NotePayload.all(source))
        XCTAssertTrue(json.contains(#""label":"H1""#))
        XCTAssertTrue(json.contains(#""page":1,"placement""#) || json.contains(#""page":1"#))
        XCTAssertTrue(json.contains(#""source":"handwriting""#))
        let reference = try JSONSerialization.data(withJSONObject: source.notesPayload, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(json, String(decoding: reference, as: UTF8.self), "The same as the source's own payload")
        let typed = MeetingEvidence.summarySource(Meeting(title: "T", notes: "A note"))
        XCTAssertFalse(SynthesisJSON.string(NotePayload.all(typed)).contains("handwriting"))
        let whole = SynthesisJSON.string(SourcePayload(source))
        XCTAssertTrue(whole.contains(#""source":"handwriting""#))
    }

    // MARK: Parts of a long conversation

    func testBehaviorEachPartReadsTheHandwritingSketchesAndPhotosWhoseTimeFallsInIt() async throws {
        var long = meeting()
        long.unifiedTranscript += (0..<2_000).map { index in
            TranscriptSegment(trackID: track, start: 300 + Double(index) * 6, end: 305 + Double(index) * 6,
                              text: "We went over routine item number \(index) for the quarterly review.", speakerID: "alex")
        }
        // Written, photographed and drawn late in the conversation, in the second hour.
        let id = long.pages![0].id
        let late = Pages.passage(id, key: "late", words: "late handwriting about item 1500", time: 9_300)
        let lateSketch = Pages.passage(id, key: "lateSketch", words: nil, kind: .sketch, time: 9_400, y: 300)
        long.pages![0].reading!.passages += [late, lateSketch]
        long.pages![0].sketches! += [Pages.analysis(of: lateSketch, caption: "Late whiteboard diagram")]
        let photo = PhotoEvidence(id: UUID(), label: "P1", time: 9_310, caption: "Late photo of the budget")
        let all = [photo] + NotebookPlacement.candidates(in: long)
        let sketches = all.filter(\.isSketch)
        XCTAssertEqual(sketches.map(\.label), ["S1", "S2", "S3"], "Timeline order: 40 s, 9,400 s, untimed")

        let model = WordModel()
        let reply = summary
        model.reply = { prompt in
            if prompt.contains("Extract ALL explicit agreed tasks") { return #"{"actions":[]}"# }
            if prompt.contains("Extract concise factual evidence") || prompt.contains("Compress these evidence notes") { return "Routine review." }
            return reply
        }
        _ = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: MeetingEvidence.summarySource(long), template: .auto,
                                                glossary: [], photos: all, progress: { _ in })
        let parts = model.prompts.filter { $0.contains("Extract concise factual evidence") }
        XCTAssertGreaterThan(parts.count, 1)
        func holding(_ text: String) -> [Int] { parts.indices.filter { parts[$0].contains(text) } }
        XCTAssertEqual(holding("PICTURE [S1]; drawn at 00:40"), [0], "The early sketch is in the first part")
        XCTAssertFalse(holding("PICTURE [S2]; drawn at").isEmpty)
        XCTAssertEqual(holding("PICTURE [S2]; drawn at"), holding("PICTURE [P1]; taken at"), "The late sketch and the late photo, together")
        XCTAssertTrue(holding("PICTURE [S2]; drawn at").allSatisfy { $0 > 0 }, "…and not in the first part")
        XCTAssertEqual(holding("NOTE H2, handwritten"), holding("PICTURE [P1]"), "Handwriting by its time too")
        XCTAssertEqual(holding("NOTE H1, handwritten"), [0])
        XCTAssertTrue(holding("[S3]").isEmpty, "A sketch with no time is only for the final write-up")
        XCTAssertTrue(holding("Loading dock diagram").isEmpty)
        let final = try XCTUnwrap(model.prompts.first { $0.contains("Write a concise summary") })
        XCTAssertTrue(final.contains("[S3]; drawn outside the recording"), "Every picture reaches the final write-up")
        XCTAssertTrue(final.contains("[P1]; taken at") && final.contains("[S1]") && final.contains("[S2]"))
        XCTAssertTrue(parts.allSatisfy { flat($0).contains("PICTURE lines are photos and sketches (P1, S1)") })
    }

    // MARK: No speech

    private final class Capturing: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _sources: [(SummarySource, [PhotoEvidence])] = []
        var sources: [(SummarySource, [PhotoEvidence])] { lock.withLock { _sources } }
        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            RecognitionResult(segments: [], language: nil, duration: 0)
        }
        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            SpeakerAnalysis(turns: [], embeddings: [:])
        }
        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            GeneratedMeetingNotes(summary: MeetingSummary(overview: "x"), suggestedTerms: [], rawResponse: "", warnings: [])
        }
        func summarize(_ source: SummarySource, template: MeetingKind, glossary: [String], model: ModelReference, templateInstructions: String?,
                       photos: [PhotoEvidence], progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            lock.withLock { _sources.append((source, photos)) }
            var summary = MeetingSummary(overview: "From the pages", sections: [SummarySection(heading: "Layout", body: "The hall layout and the stage.")])
            summary.sections[0].sketchIDs = photos.filter(\.isSketch).prefix(1).map(\.id)
            return GeneratedMeetingNotes(summary: summary, suggestedTerms: [], rawResponse: "", warnings: [])
        }
        func describeImages(_ requests: [ImageDescriptionRequest], model: ModelReference,
                            progress: @escaping IntelligenceProgressHandler) async throws -> [ImageDescription] {
            requests.map { $0.url.lastPathComponent.hasPrefix("bad") ? ImageDescription(failure: "unreadable")
                : ImageDescription(caption: "A floor plan", recognizedText: "Stage", labels: ["diagram"], provenance: nil) }
        }
    }

    private let configuration = InferenceProcessingEngine.Configuration(
        transcriptionModel: "parakeet/ultra", summaryModel: "gemma-4/12b-4bit", detectSpeakers: false, speakerModel: "community-1/offline",
        speakerOptions: SpeakerAnalysisOptions(), fingerprint: "f", speakerMatchThreshold: 0.82, speakerMatchMargin: 0.06)

    func testBehaviorAConversationWithPagesAndNoSpeechIsSummarizedFromThemAndNothingElseRefuses() async throws {
        let inference = Capturing()
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration)
        let output = try await engine.summarize(meeting(speech: false), template: nil, vocabulary: [], progress: { _ in })
        let (source, photos) = try XCTUnwrap(inference.sources.first)
        XCTAssertTrue(source.annotatedTranscript.hasPrefix(SummarySource.noSpeech))
        XCTAssertEqual(source.anchors.map(\.label), ["H1"])
        XCTAssertEqual(photos.map(\.label), ["S1", "S2"])
        XCTAssertEqual(output.summary.sections[0].sketchIDs, [photos[0].id], "The sketch the model placed is kept")
        XCTAssertEqual(output.summary.processingSettings?.parameters["sketches"], "2")
        XCTAssertNil(output.summary.processingSettings?.parameters["photos"])
        do {
            _ = try await engine.summarize(Meeting(title: "Empty"), template: nil, vocabulary: [], progress: { _ in })
            XCTFail("Nothing said and nothing written")
        } catch DaybookError.noSpeech {}
        // And the writing alone reaches the prompt, with the no-speech line.
        let model = WordModel()
        let reply = summary.replacingOccurrences(of: #""actionItems":[]"#, with: #""actionItems":[{"text":"Book the hall"}]"#)
        model.reply = { prompt in prompt.contains("Extract ALL explicit agreed tasks") ? #"{"actions":[]}"# : reply }
        let generated = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: source, template: .auto, glossary: [],
                                                            photos: photos, progress: { _ in })
        let final = flat(try XCTUnwrap(model.prompts.first { $0.contains("Write a concise summary") }))
        XCTAssertTrue(final.contains("No speech was recorded in this conversation"))
        XCTAssertTrue(final.contains("venue holds 120 people"))
        XCTAssertEqual(generated.summary.sections.first?.heading, "Layout")
        XCTAssertEqual(generated.summary.actionItems.map(\.text), [], "The reply's invented task, with nothing said to show it, is dropped")
    }

    // MARK: Reading sketches

    func testBehaviorDescribeSketchesRecordsTheStrokesDigestAndTheModelAndLeavesUnreadableOnes() async throws {
        let engine = InferenceProcessingEngine(inference: Capturing(), configuration: configuration)
        let directory = FileManager.default.temporaryDirectory
        let good = UUID(), bad = UUID()
        let result = try await engine.describeSketches([
            SketchProcessingInput(passageID: good, strokeDigest: "digest-1", url: directory.appendingPathComponent("\(good).png")),
            SketchProcessingInput(passageID: bad, strokeDigest: "digest-2", url: directory.appendingPathComponent("bad-\(bad).png"))], progress: { _ in })
        XCTAssertEqual(Array(result.keys), [good], "An unreadable sketch has no result, so it is tried again")
        let read = try XCTUnwrap(result[good])
        XCTAssertEqual(read.strokeDigest, "digest-1")
        XCTAssertEqual(read.analysis.recognizedText, "Stage")
        XCTAssertEqual(read.analysis.caption, "A floor plan")
        XCTAssertTrue(read.analysis.isInformative)
        XCTAssertEqual(read.analysis.settings?.modelID, PhotoReading.visionModel.id)
        let empty = try await engine.describeSketches([], progress: { _ in })
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: Long handwriting

    func testBehaviorHandwritingTooLongForTheFinalPassIsTrimmedLikeNotesAndWarned() async throws {
        var long = meeting()
        long.unifiedTranscript += (0..<2_000).map { index in
            TranscriptSegment(trackID: track, start: 300 + Double(index) * 6, end: 305 + Double(index) * 6,
                              text: "We went over routine item number \(index) for the quarterly review.", speakerID: "alex")
        }
        let id = long.pages![0].id
        let many = (0..<40).map { index in
            Pages.passage(id, key: "k\(index)", words: "Handwritten follow up \(index): " + Array(repeating: "context", count: 60).joined(separator: " "),
                          time: 300 + Double(index) * 300, y: 400 + Double(index))
        }
        long.pages![0].reading!.passages += many
        let model = WordModel()
        let reply = summary
        model.reply = { prompt in
            if prompt.contains("Extract ALL explicit agreed tasks") { return #"{"actions":[]}"# }
            if prompt.contains("Extract concise factual evidence") || prompt.contains("Compress these evidence notes") { return "Routine review." }
            return reply
        }
        let generated = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: MeetingEvidence.summarySource(long), template: .auto,
                                                            glossary: [], progress: { _ in })
        let final = try XCTUnwrap(model.prompts.first { $0.contains("Write a concise summary") })
        XCTAssertFalse(final.contains("Handwritten follow up 39"), "The last ones didn't fit beside the evidence")
        XCTAssertTrue(generated.warnings.contains { $0.contains("didn’t fit in the final pass") })
    }
}
