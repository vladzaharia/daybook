import DaybookDesign
import DaybookKit
import Foundation
import SwiftUI
import XCTest
@testable import DaybookUI

/// Unsure words as both apps' transcripts show them: the dotted mark on the words, the menu's and VoiceOver's words,
/// the rotor, and the edits, each undoable.
@MainActor
final class UnsureWordsScreensTests: XCTestCase {
    private let track = UUID()

    private func library() async throws -> LibraryController {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookUIUnsure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryController(rootURL: folder, sync: nil)
        try await library.load()
        return library
    }

    /// A conversation transcribed twice: the second run reads "Friday" where the first read "Thursday" (and, with
    /// `names`, "Maria" for "Priya", a second unsure word in the passage).
    private func transcribedTwice(_ meeting: inout Meeting, names: Bool = false) {
        meeting.tracks = [RecordingTrack(id: track, source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", duration: 60, offset: 0)]
        func run(_ text: String, at time: Double) -> TrackTranscript {
            let pieces = text.split(separator: " ")
            let words = pieces.enumerated().map { TranscriptWord(text: " " + $0.element, start: 2 + Double($0.offset) * 0.4,
                                                                  end: 2.35 + Double($0.offset) * 0.4, confidence: 0.97) }
            return TrackTranscript(trackID: track, segments: [TranscriptSegment(trackID: track, start: 2, end: words.last!.end, text: text)],
                                   modelID: "parakeet/ultra", createdAt: Date(timeIntervalSince1970: time), words: words)
        }
        let tail = names ? " and then PERSON owns it." : "."
        meeting.transcripts = [run("We ship the calendar on Thursday" + tail.replacingOccurrences(of: "PERSON", with: "Priya"), at: 1),
                               run("We ship the calendar on Friday" + tail.replacingOccurrences(of: "PERSON", with: "Maria"), at: 2)]
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
    }

    func testBehaviorUnsureWordsGetADottedLineAndNothingElseDoes() throws {
        var meeting = Meeting(title: "Weekly")
        transcribedTwice(&meeting)
        let passage = try XCTUnwrap(meeting.unifiedTranscript.first)
        let marks = try XCTUnwrap(TranscriptLayout(meeting).unsure[passage.id])
        XCTAssertEqual(marks.map { $0.words(in: passage.text) }, ["Friday"], "The words, not the full stop after them")
        let text = UnsureWords.marked(passage.text, marks)
        let dotted = Text.LineStyle(pattern: .dot, color: DaybookPalette.Ink.meta)
        let underlined = text.runs.compactMap { run -> String? in
            run[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] == nil ? nil : String(text[run.range].characters)
        }
        XCTAssertEqual(underlined, ["Friday"])
        // The pattern is what makes the mark more than a colour, so it's the dotted one, in the quiet ink, and only that.
        let styles = text.runs.compactMap { $0[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] }
        XCTAssertEqual(styles, [dotted], "A dotted line in the meta ink")
        XCTAssertNotEqual(styles.first, Text.LineStyle.single, "Not the plain underline a link has")
        XCTAssertNotEqual(styles.first, Text.LineStyle(pattern: .dot, color: nil), "Not left to the text's colour")
        XCTAssertTrue(text.runs.allSatisfy { $0[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] == nil },
                      "No colour of its own on the words")
        let plain = UnsureWords.marked(passage.text, [])
        XCTAssertTrue(plain.runs.allSatisfy { $0[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] == nil }, "Unmarked words get none")
        XCTAssertEqual(String(text.characters), passage.text, "The words themselves are as heard")
    }

    func testBehaviorTheMenuAndVoiceOverNameTheWords() throws {
        var meeting = Meeting(title: "Weekly")
        transcribedTwice(&meeting)
        let passage = try XCTUnwrap(meeting.unifiedTranscript.first)
        let mark = try XCTUnwrap(TranscriptLayout(meeting).unsure[passage.id]?.first)
        XCTAssertEqual(UnsureWords.earlierReadingTitle(mark, in: passage.text), "Use “Thursday”")
        XCTAssertEqual(mark.replacing(in: passage.text), "We ship the calendar on Thursday.", "The passage keeps its full stop")
        XCTAssertEqual(UnsureWords.keepTitle("Friday"), "Keep “Friday”")
        XCTAssertEqual(UnsureWords.spoken(["Friday", "Maria"]), "Unsure: “Friday”, “Maria”")
        var added = mark
        added.flag.alternative = ""
        XCTAssertEqual(UnsureWords.earlierReadingTitle(added, in: passage.text), "Remove “Friday”")
        var none = mark
        none.flag.alternative = nil
        XCTAssertNil(UnsureWords.earlierReadingTitle(none, in: passage.text), "Nothing to take: only Keep")

        let layout = TranscriptLayout(meeting)
        let rotors = TranscriptRotorEntries(rows: TranscriptRow.rows(from: layout.blocks), marks: layout.marks, meeting: meeting,
                                            unsure: layout.unsure)
        XCTAssertEqual(rotors.unsure.map(\.label), ["0:02, “Friday”"])
        XCTAssertEqual(rotors.unsure.first?.id, passage.id.uuidString)
    }

    func testBehaviorKeepingAndTakingTheEarlierReadingAreUndoable() async throws {
        let library = try await library()
        let id = library.newMeeting(title: "Weekly")
        library.update(id) { self.transcribedTwice(&$0) }
        let undo = UndoManager()
        let meeting = try XCTUnwrap(library.meeting(id))
        let passage = try XCTUnwrap(meeting.unifiedTranscript.first)
        let flag = try XCTUnwrap(meeting.transcriptFlags?.first)
        func shown() -> Int { library.meeting(id).map { TranscriptLayout($0).unsure.values.flatMap { $0 }.count } ?? 0 }
        func answers() -> [Bool] { (library.meeting(id)?.transcriptFlagDismissals ?? []).map(\.isActive) }

        XCTAssertTrue(TranscriptEdits.keep(flag.id, in: id, library: library, undoManager: undo))
        XCTAssertEqual(shown(), 0)
        XCTAssertEqual(undo.undoActionName, "Keep Words")
        undo.undo()
        XCTAssertEqual(shown(), 1, "Undo brings the mark back")
        XCTAssertEqual(answers(), [false], "The answer is taken back, not removed")
        undo.redo()
        XCTAssertEqual(shown(), 0, "Redo keeps the words again")
        XCTAssertEqual(answers(), [true])
        undo.undo()

        XCTAssertTrue(TranscriptEdits.useAlternative(flag.id, in: id, library: library, undoManager: undo))
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "We ship the calendar on Thursday.")
        XCTAssertEqual(shown(), 0)
        XCTAssertEqual(undo.undoActionName, "Correct Passage")
        XCTAssertTrue(library.meeting(id)?.revisions.contains { $0.kind == .segment(passage.id) } == true)
        undo.undo()
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "We ship the calendar on Friday.")
        XCTAssertEqual(answers(), [false])
        // Version History holds the correction and its undoing; the passage reads as it did, so its mark is back.
        XCTAssertEqual(shown(), 1)
        undo.redo()
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "We ship the calendar on Thursday.")
        XCTAssertEqual(answers(), [true])
        XCTAssertEqual(shown(), 0)
    }

    func testBehaviorUndoTakesBackOnlyItsOwnAnswerWhateverArrivedInBetween() async throws {
        let library = try await library()
        let id = library.newMeeting(title: "Weekly")
        library.update(id) { self.transcribedTwice(&$0, names: true) }
        let undo = UndoManager()
        let flags = try XCTUnwrap(library.meeting(id)?.transcriptFlags)
        XCTAssertEqual(flags.map(\.text), ["Friday", "Maria"])
        func shown() -> [String] {
            library.meeting(id).map { meeting in
                TranscriptLayout(meeting).unsure.values.flatMap { $0 }.map(\.flag.text)
            } ?? []
        }
        // Keep "Friday" here; the other device's answer to "Maria" arrives (a sync); Undo here.
        XCTAssertTrue(TranscriptEdits.keep(flags[0].id, in: id, library: library, undoManager: undo))
        library.update(id) { $0.keepFlaggedWords(flags[1].id) }
        XCTAssertEqual(shown(), [])
        undo.undo()
        XCTAssertEqual(shown(), ["Friday"], "The other device's answer is still there")
        undo.redo()
        XCTAssertEqual(shown(), [])
        // The same with Use: its passage text goes back, and nothing else.
        undo.undo()
        XCTAssertTrue(TranscriptEdits.useAlternative(flags[0].id, in: id, library: library, undoManager: undo))
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "We ship the calendar on Thursday and then Maria owns it.")
        library.update(id) { $0.withdrawFlagAnswer(flags[1].id) }
        XCTAssertEqual(shown(), ["Maria"], "The synced answer to Maria was taken back elsewhere")
        undo.undo()
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "We ship the calendar on Friday and then Maria owns it.")
        XCTAssertEqual(shown().sorted(), ["Friday", "Maria"], "Maria's answer stays withdrawn: Undo took back only its own")
        // Text changed meanwhile isn't undone with it.
        undo.redo()
        library.update(id) { $0.correctSegment(id: $0.unifiedTranscript[0].id, text: "We ship the calendar on Thursday and then Mario owns it.") }
        undo.undo()
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "We ship the calendar on Thursday and then Mario owns it.")
        XCTAssertEqual((library.meeting(id)?.transcriptFlagDismissals ?? []).filter(\.isActive).count, 0)
    }
}
