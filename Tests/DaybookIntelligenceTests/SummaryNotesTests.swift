import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Notes and bookmarks in summaries: placed in the transcript at their times, the passages around
/// them marked and kept first when a long conversation is compressed, and folded into the summary
/// rather than listed after it. A deterministic model records every prompt; no weights are loaded.
final class SummaryNotesTests: XCTestCase {
    /// One token per whitespace-separated word, decoded back to the same words; replies from a script.
    private final class WordModel: SynthesisModel, @unchecked Sendable {
        let supportsStructuredOutput = false
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

    /// Seven passages over three and a half minutes, three notes (two timed, one written before the
    /// recording), a bare bookmark, and a bookmark with words.
    private func meeting() -> Meeting {
        let lines: [(Double, String, String)] = [
            (0, "alex", "Thanks for joining, let's start with the launch."),
            (20, "sam", "The venue still hasn't confirmed the date."),
            (45, "alex", "Then we hold the press release until they do."),
            (70, "sam", "Finance says we can't go over forty thousand."),
            (100, "alex", "Pricing next: twelve dollars a seat feels right."),
            (130, "sam", "Agreed, twelve dollars, and annual plans at ten."),
            (200, "alex", "I will email the venue tomorrow morning."),
        ]
        var meeting = Meeting(title: "Launch", notes: "Prep: bring last quarter's numbers\nBudget cap is firm at 40k\nCall the venue",
                              speakers: [Speaker(id: "alex", name: "Alex"), Speaker(id: "sam", name: "Sam")])
        meeting.unifiedTranscript = lines.map { TranscriptSegment(trackID: track, start: $0.0, end: $0.0 + 8, text: $0.2, speakerID: $0.1) }
        meeting.timedNotes = [TimedNote(text: "Prep: bring last quarter's numbers"), TimedNote(time: 78, text: "Budget cap is firm at 40k"),
                              TimedNote(time: 206, text: "Call the venue")]
        meeting.highlights = [Highlight(time: 22, text: "Marked moment"), Highlight(time: 131, text: "Pricing decision")]
        return meeting
    }

    // MARK: The source

    func testNotesAndBookmarksArePlacedInTheTranscriptWithTheirWindows() {
        let source = MeetingEvidence.summarySource(meeting())
        XCTAssertEqual(source.anchors.map(\.label), ["N1", "N2", "N3", "B1", "B2"])
        XCTAssertNil(source.anchors[0].time, "Written before the recording: no place on the timeline")
        XCTAssertEqual(source.anchors[1].window, 18...93, "A note looks back a minute and ahead 15 s")
        XCTAssertEqual(source.anchors[4].window, 101...191, "A bookmark keeps its 30 s before and 60 s after")
        XCTAssertEqual(source.anchors[3].text, "", "An automatic bookmark label reads as no words")

        // Which passages carry more weight.
        XCTAssertEqual(source.lines.map(\.near), [["B1"], ["N2", "B1"], ["N2", "B1"], ["N2", "B1"], ["B2"], ["B2"], ["N3"]])

        let annotated = source.annotatedTranscript.components(separatedBy: "\n")
        XCTAssertEqual(annotated, [
            "[00:00] (near B1) Alex: Thanks for joining, let's start with the launch.",
            "[00:20] (near N2, B1) Sam: The venue still hasn't confirmed the date.",
            "[00:22] BOOKMARK B1, marked by the user",
            "[00:45] (near N2, B1) Alex: Then we hold the press release until they do.",
            "[01:10] (near N2, B1) Sam: Finance says we can't go over forty thousand.",
            "[01:18] NOTE N2, written by the user (not spoken): Budget cap is firm at 40k",
            "[01:40] (near B2) Alex: Pricing next: twelve dollars a seat feels right.",
            "[02:10] (near B2) Sam: Agreed, twelve dollars, and annual plans at ten.",
            "[02:11] BOOKMARK B2, marked by the user: Pricing decision",
            "[03:20] (near N3) Alex: I will email the venue tomorrow morning.",
            "[03:26] NOTE N3, written by the user (not spoken): Call the venue",
        ])
        XCTAssertFalse(source.transcript.contains("NOTE"), "The plain transcript, for checking quotes, has no notes in it")

        let untimed = source.notesPayload[0]
        XCTAssertEqual(untimed["label"] as? String, "N1")
        XCTAssertTrue(untimed["time"] is NSNull)
        XCTAssertEqual(untimed["placement"] as? String, "written outside the recording")
        XCTAssertEqual(source.notesText, MeetingEvidence.notes(meeting()), "Strings for older inference are unchanged")
    }

    func testABookmarkOnARecordingThatIsntLinedUpCarriesItsOwnPassages() {
        var meeting = meeting()
        let recorder = UUID()
        meeting.tracks = [RecordingTrack(id: recorder, source: .soundcore, relativePath: "r.m4a", fileName: "r.m4a")]
        meeting.transcripts = [TrackTranscript(trackID: recorder, segments: [
            TranscriptSegment(trackID: recorder, start: 50, end: 55, text: "Only the recorder heard this.")])]
        meeting.alignmentReports = [TrackAlignment(trackID: recorder, method: .unaligned)]
        meeting.highlights.append(Highlight(trackID: recorder, time: 52, text: "Side chat"))
        let source = MeetingEvidence.summarySource(meeting)
        let side = try? XCTUnwrap(source.anchors.first { $0.text == "Side chat" })
        XCTAssertEqual(side?.label, "B3")
        XCTAssertNil(side?.time)
        XCTAssertEqual(side?.recording, "Soundcore Work")
        XCTAssertEqual(side?.context, ["[00:50] Only the recorder heard this."])
        XCTAssertFalse(source.annotatedTranscript.contains("Side chat"), "It has no place on this timeline")
        XCTAssertEqual(source.notesPayload.last?["context"] as? [String], ["[00:50] Only the recorder heard this."])
    }

    func testTrimmingKeepsEveryNotesNearestPassagesFirst() async {
        let source = MeetingEvidence.summarySource(meeting())
        let words: (String) async -> Int = { $0.split(whereSeparator: \.isWhitespace).count }
        let everything = await source.focusPassages(fitting: 10_000, cost: words)
        XCTAssertEqual(everything.components(separatedBy: "\n").filter { $0.hasPrefix("[0") }.count, 7, "With room, every marked passage")

        // Room for three passages: N2, B2, and N3 (notes and bookmarks with words) get their nearest one
        // each (a note's from before it), before the bare bookmark or anyone's second.
        let three = await source.focusPassages(fitting: 39, cost: words)
        XCTAssertEqual(three.components(separatedBy: "\n"), [
            "[01:10] (near N2, B1) Sam: Finance says we can't go over forty thousand.",
            "[…]",
            "[02:10] (near B2) Sam: Agreed, twelve dollars, and annual plans at ten.",
            "[03:20] (near N3) Alex: I will email the venue tomorrow morning.",
        ])
        let none = await source.focusPassages(fitting: 0, cost: words)
        XCTAssertEqual(none, "")
    }

    // MARK: Prompts

    private let summary = #"{"kind":"planning","title":"Launch","overview":"Venue and pricing.","sections":[{"heading":"Budget","body":"Capped at 40k."}],"actionItems":[],"terms":[]}"#

    func testAShortConversationReadsNotesInPlaceAndFoldsThemIn() async throws {
        let model = WordModel()
        let summary = self.summary
        model.reply = { prompt in
            prompt.contains("Extract ALL explicit agreed tasks")
                ? #"{"actions":[{"text":"Email the venue","owner":"Alex","evidence":"Alex: I will email the venue tomorrow morning."},{"text":"Keep the cap","owner":null,"evidence":"Budget cap is firm at 40k"}]}"#
                : summary
        }
        let notes = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: MeetingEvidence.summarySource(meeting()),
                                                        template: .auto, glossary: [], progress: { _ in })
        XCTAssertEqual(model.prompts.count, 2, "Short: one summary pass and the commitments pass")
        let final = model.prompts[0]
        XCTAssertTrue(final.contains("NOTE N2, written by the user (not spoken): Budget cap is firm at 40k"), "The note sits in the transcript")
        XCTAssertTrue(final.contains("(near N2, B1) Sam: Finance says we can't go over forty thousand."))
        XCTAssertTrue(final.contains("Fold each note into the section it belongs to"))
        XCTAssertTrue(final.contains("Do not list the notes separately, under a heading of their own, or at the end"))
        XCTAssertTrue(final.contains("attributed to the user's notes"), "A note the recording doesn't support still goes in")
        XCTAssertTrue(final.contains(#""placement":"written outside the recording""#))
        XCTAssertFalse(final.contains("passages_near_notes_and_bookmarks"), "Nothing was compressed, so nothing is repeated")

        let actions = model.prompts[1]
        XCTAssertFalse(actions.contains("NOTE N2"), "Commitments are checked against what was said only")
        XCTAssertEqual(notes.summary.actionItems.map(\.text), ["Email the venue"], "A quote from a note isn't evidence of a commitment")
        XCTAssertEqual(notes.summary.actionItems.first?.owner, "Alex")
    }

    func testALongConversationKeepsTheMarkedPassagesThroughCompression() async throws {
        var meeting = meeting()
        // 700 passages of filler between the marked moments: far past one pass.
        let filler = (0..<700).map { index in
            TranscriptSegment(trackID: track, start: 300 + Double(index) * 6, end: 305 + Double(index) * 6,
                              text: "We went over routine item number \(index) for the quarterly review.", speakerID: "sam")
        }
        meeting.unifiedTranscript += filler
        meeting.timedNotes?.append(TimedNote(time: 3_000, text: "Ask legal about item 450"))
        meeting.notes += "\nAsk legal about item 450"
        let model = WordModel()
        let summary = self.summary
        model.reply = { prompt in
            if prompt.contains("Extract ALL explicit agreed tasks") { return #"{"actions":[]}"# }
            if prompt.contains("Extract concise factual evidence") { return "Routine items were reviewed." }
            if prompt.contains("Compress these evidence notes") { return "Routine review." }
            return summary
        }
        let notes = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: MeetingEvidence.summarySource(meeting),
                                                        template: .auto, glossary: [], progress: { _ in })
        let parts = model.prompts.filter { $0.contains("Extract concise factual evidence") }
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.contains("THE USER'S NOTES AND BOOKMARKS, for reference") }, "Every part knows the notes")
        let withNote = parts.filter { $0.contains("NOTE N4, written by the user (not spoken): Ask legal about item 450") }
        XCTAssertTrue((1...2).contains(withNote.count), "A timed note travels in the part of the transcript it was written in")
        XCTAssertTrue(withNote[0].contains("(near N4) Sam: We went over routine item number 449"))

        let final = try XCTUnwrap(model.prompts.first { $0.contains("Write a concise summary") })
        XCTAssertTrue(final.contains("passages_near_notes_and_bookmarks"))
        XCTAssertTrue(final.contains("Finance says we can't go over forty thousand."), "The passage before the budget note, word for word")
        XCTAssertTrue(final.contains("We went over routine item number 449"), "And the one before the legal note")
        XCTAssertFalse(final.contains("routine item number 100 for"), "Unmarked filler only reaches the summary compressed")
        XCTAssertTrue(final.contains(#""label":"N4""#), "The notes themselves travel to the final pass")
        XCTAssertTrue(notes.warnings.contains { $0.contains("several local passes") })
    }

    func testTemplatesStillShapeTheSummary() async throws {
        let model = WordModel()
        let summary = self.summary
        model.reply = { $0.contains("Extract ALL explicit agreed tasks") ? #"{"actions":[]}"# : summary }
        _ = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: MeetingEvidence.summarySource(meeting()),
                                                template: .oneOnOne, glossary: [], templateInstructions: "Sections: Wins, Worries, Next",
                                                progress: { _ in })
        let final = model.prompts[0]
        XCTAssertTrue(final.contains("Use the user's selected kind: oneOnOne"))
        XCTAssertTrue(final.contains("Sections: Wins, Worries, Next"))
        XCTAssertTrue(final.contains("Preserve those names"))
        XCTAssertFalse(final.contains("Kinds and section guidance:"))
        XCTAssertTrue(final.contains("Fold each note into the section it belongs to"), "Notes are folded into the template's sections too")
    }

    // MARK: The engine

    private final class Structured: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _sources: [SummarySource] = []
        var sources: [SummarySource] { lock.withLock { _sources } }

        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            RecognitionResult(segments: [], language: nil, duration: 0)
        }
        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            SpeakerAnalysis(turns: [], embeddings: [:])
        }
        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            XCTFail("The structured source is used")
            return GeneratedMeetingNotes(summary: MeetingSummary(overview: "x"), suggestedTerms: [], rawResponse: "", warnings: [])
        }
        func summarize(_ source: SummarySource, template: MeetingKind, glossary: [String], model: ModelReference, templateInstructions: String?,
                       photos: [PhotoEvidence], progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            lock.withLock { _sources.append(source) }
            return GeneratedMeetingNotes(summary: MeetingSummary(overview: "x"), suggestedTerms: [], rawResponse: "", warnings: [])
        }
    }

    /// Inference from before notes were placed: it takes strings only.
    private final class StringsOnly: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _strings: [(String, String, String?)] = []
        var strings: [(String, String, String?)] { lock.withLock { _strings } }

        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            RecognitionResult(segments: [], language: nil, duration: 0)
        }
        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            SpeakerAnalysis(turns: [], embeddings: [:])
        }
        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            lock.withLock { _strings.append((transcript, notes, highlightEvidence)) }
            return GeneratedMeetingNotes(summary: MeetingSummary(overview: "x"), suggestedTerms: [], rawResponse: "", warnings: [])
        }
    }

    private let configuration = InferenceProcessingEngine.Configuration(
        transcriptionModel: "parakeet/ultra", summaryModel: "gemma-4/12b-4bit", detectSpeakers: false, speakerModel: "community-1/offline",
        speakerOptions: SpeakerAnalysisOptions(), fingerprint: "f", speakerMatchThreshold: 0.82, speakerMatchMargin: 0.06)

    func testTheEngineHandsTheSummarizerNotesInPlace() async throws {
        let inference = Structured()
        _ = try await InferenceProcessingEngine(inference: inference, configuration: configuration)
            .summarize(meeting(), template: nil, vocabulary: [], progress: { _ in })
        let source = try XCTUnwrap(inference.sources.first)
        XCTAssertTrue(source.annotatedTranscript.contains("NOTE N2"))
        XCTAssertEqual(source.anchors.count, 5)

        // Inference that only takes strings gets exactly what it always did.
        let older = StringsOnly()
        _ = try await InferenceProcessingEngine(inference: older, configuration: configuration)
            .summarize(meeting(), template: nil, vocabulary: [], progress: { _ in })
        let strings = try XCTUnwrap(older.strings.first)
        XCTAssertEqual(strings.0, MeetingEvidence.transcript(meeting()))
        XCTAssertEqual(strings.1, MeetingEvidence.notes(meeting()))
        XCTAssertEqual(strings.2, MeetingEvidence.highlights(meeting()))
    }
}
