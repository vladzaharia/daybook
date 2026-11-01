import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// The source data a summary's passes give the model encodes byte for byte as the dictionaries it
/// replaced did (JSONSerialization, keys sorted, slashes left alone): the prompts are calibrated against
/// specific models (docs/validation.md), so a typed payload must not move a key or escape a character
/// differently. Synthetic sources; no model runs.
final class SynthesisPayloadTests: XCTestCase {
    /// What the dictionaries were written with.
    private func serialized(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Every ASCII character, the line separators, accents, CJK, emoji, and the quotes and slashes a transcript holds.
    private let awkward: String = {
        var text = ""
        for scalar in 0...0x7F { text.unicodeScalars.append(Unicode.Scalar(scalar)!) }
        return text + "\u{2028}\u{2029}é漢字🙂👩‍👩‍👧 \\ / \" ’ “ ” … a/b"
    }()

    private func source() -> SummarySource {
        let track = UUID()
        var meeting = Meeting(title: "Launch", notes: "", speakers: [Speaker(id: "alex", name: "Alex")])
        meeting.unifiedTranscript = [
            TranscriptSegment(trackID: track, start: 0, end: 5, text: "Opening: \(awkward)", speakerID: "alex"),
            TranscriptSegment(trackID: track, start: 70, end: 75, text: "The cap is forty thousand.", speakerID: "alex"),
        ]
        let notes = [TimedNote(text: "Before: bring the numbers / Q3"), TimedNote(time: 72, text: "Cap \"40k\"")]
        meeting.timedNotes = notes
        meeting.notes = notes.map(\.text).joined(separator: "\n")
        meeting.highlights = [Highlight(time: 3, text: ""), Highlight(time: 71, text: "Budget")]
        // A bookmark on a recorder's recording that isn't lined up carries that recording's passages.
        let recorder = UUID()
        meeting.tracks = [RecordingTrack(id: recorder, source: .soundcore, relativePath: "r.m4a", fileName: "r.m4a")]
        meeting.transcripts = [TrackTranscript(trackID: recorder, segments: [
            TranscriptSegment(trackID: recorder, start: 50, end: 55, text: "Only the recorder heard this / that.")])]
        meeting.alignmentReports = [TrackAlignment(trackID: recorder, method: .unaligned)]
        meeting.highlights.append(Highlight(trackID: recorder, time: 52, text: "Side chat"))
        return MeetingEvidence.summarySource(meeting)
    }

    func testBehaviorTheConversationEncodesAsItsDictionaryDid() throws {
        var source = source()
        source.anchors[1].repeatsWhatWasSaid = true
        XCTAssertTrue(source.anchors.contains { $0.recording != nil && !$0.context.isEmpty }, "a bookmark with its own passages")
        // The notes as DaybookKit lists them, the dictionary the passes used to send.
        XCTAssertEqual(SynthesisJSON.string(NotePayload.all(source)), try serialized(source.notesPayload))
        let whole: [String: Any] = ["recorded_transcript": source.annotatedTranscript, "user_notes_and_bookmarks": source.notesPayload]
        XCTAssertEqual(SynthesisJSON.string(SourcePayload(source)), try serialized(whole))
        XCTAssertTrue(SynthesisJSON.string(SourcePayload(source)).contains(#""time":null"#), "a note off the timeline says so")

        // From strings: the written notes and the highlights, never the notes list.
        let legacy = SummarySource.legacy(transcript: "[00:01] A: \(awkward)", notes: "n/1", highlights: nil)
        XCTAssertEqual(SynthesisJSON.string(SourcePayload(legacy)), try serialized([
            "recorded_transcript": legacy.annotatedTranscript, "written_user_context": "n/1", "highlighted_evidence": ""]))
        // Without notes, a structured source sends the transcript alone.
        var bare = self.source()
        bare.anchors = []
        XCTAssertEqual(SynthesisJSON.string(SourcePayload(bare)), try serialized(["recorded_transcript": bare.annotatedTranscript]))
    }

    func testBehaviorEachPassesSourceDataEncodesAsItsDictionaryDid() throws {
        let source = source()
        let notes = NotePayload.all(source)
        XCTAssertEqual(SynthesisJSON.string(NotesPayload(userNotesAndBookmarks: notes)), try serialized(["user_notes_and_bookmarks": source.notesPayload]))
        XCTAssertEqual(SynthesisJSON.string(SourcePart(kind: .highlightedEvidence, content: awkward)),
                       try serialized(["source_type": "highlighted_evidence", "content": awkward]))
        XCTAssertEqual(SynthesisJSON.string(EvidenceNotes(evidenceNotes: awkward)), try serialized(["evidence_notes": awkward]))
        XCTAssertEqual(SynthesisJSON.string(TranscriptPart(recordedTranscript: awkward)), try serialized(["recorded_transcript": awkward]))
        XCTAssertEqual(SynthesisJSON.string(TemplatePreferences(templatePreferences: awkward)), try serialized(["template_preferences": awkward]))
        let item = NoteCheckItem(label: "N2", note: "Cap \"40k\"", passagesAroundIt: awkward)
        XCTAssertEqual(SynthesisJSON.string(NoteCheckRequest(notes: [item])),
                       try serialized(["notes": [["label": "N2", "note": "Cap \"40k\"", "passages_around_it": awkward]]]))
        XCTAssertEqual(SynthesisJSON.string(QuotedActions(actions: [.init(text: "Send it", owner: nil, evidence: "I'll / send"),
                                                                    .init(text: "Call", owner: "Mina", evidence: "")])),
                       try serialized(["actions": [["text": "Send it", "owner": NSNull(), "evidence": "I'll / send"],
                                                   ["text": "Call", "owner": "Mina", "evidence": ""]]]))
        XCTAssertEqual(MeetingSynthesis.prose, try serialized(["type": "string", "pattern": MeetingSynthesis.prosePattern]))
    }

    func testBehaviorTheFinalPassReadsTheConversationAsAnObjectAndExtractedEvidenceAsText() throws {
        let source = source()
        let payload = SourcePayload(source)
        let whole: [String: Any] = ["recorded_transcript": source.annotatedTranscript, "user_notes_and_bookmarks": source.notesPayload]
        let final = FinalSource(evidence: .conversation(payload), glossarySpellings: ["Ä", "b/c", "_x"], userNotesAndBookmarks: NotePayload.all(source),
                                passagesNearNotesAndBookmarks: "[01:10] near", photos: "P1 / board")
        XCTAssertEqual(SynthesisJSON.string(final), try serialized([
            "evidence": whole, "glossary_spellings": ["Ä", "b/c", "_x"], "user_notes_and_bookmarks": source.notesPayload,
            "passages_near_notes_and_bookmarks": "[01:10] near", "photos": "P1 / board"]))
        let extracted = FinalSource(evidence: .extracted("Topic\n- \(awkward)"), glossarySpellings: [])
        XCTAssertEqual(SynthesisJSON.string(extracted), try serialized(["evidence": "Topic\n- \(awkward)", "glossary_spellings": [String]()]))

        let prompt = MeetingSynthesis.finalPrompt(evidence: .conversation(payload), template: .auto, glossary: ["Daybook"])
        XCTAssertTrue(prompt.hasSuffix(SynthesisJSON.string(FinalSource(evidence: .conversation(payload), glossarySpellings: ["Daybook"]))))
    }

    func testBehaviorLimitsAndProgressKeepTheirValues() {
        typealias Limits = MeetingSynthesis.Limits
        XCTAssertEqual(Limits.glossary((0..<100).map { "t\($0)" + String(repeating: "x", count: $0 == 2 ? 300 : 0) }).count, 80)
        XCTAssertEqual(Limits.glossary(["t" + String(repeating: "x", count: 300)])[0].count, 200)
        XCTAssertEqual(CloudSynthesis.templateTokens, 700, "the cloud bounds a template as the local passes do")
        typealias Marks = MeetingSynthesis.ProgressMarks
        XCTAssertEqual(Marks.checkingNotes, 0.04)
        XCTAssertEqual(Marks.reading(0, of: 3), 0.08)
        XCTAssertEqual(Marks.reading(2, of: 3), 0.08 + 2.0 / 3.0 * 0.62)
        XCTAssertEqual(Marks.combining, 0.72)
        XCTAssertEqual(Marks.writing, 0.82)
        XCTAssertEqual(Marks.commitments(0, of: 4), 0.93)
        XCTAssertEqual(Marks.commitments(3, of: 4), 0.93 + 0.06 * 3.0 / 4.0)
        XCTAssertLessThan(Marks.reading(9, of: 10), Marks.combining)
        XCTAssertLessThan(Marks.commitments(9, of: 10), Marks.ready)
    }

    func testBehaviorMarkersAreRemovedWithTheCompiledPattern() {
        let body = "[01:18] NOTE N2, written by the user (not spoken): Cap\n- (near N2, B1) Exports\nKept line (near B1)\nN2 adds: 40k"
        XCTAssertEqual(MeetingSynthesis.withoutMarkers(body), "Kept line\nYour notes add: 40k")
    }
}
