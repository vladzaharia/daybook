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

    /// A conversation transcribed twice: the second run reads "Friday" where the first read "Thursday".
    private func transcribedTwice(_ meeting: inout Meeting) {
        meeting.tracks = [RecordingTrack(id: track, source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", duration: 60, offset: 0)]
        func run(_ text: String, at time: Double) -> TrackTranscript {
            let pieces = text.split(separator: " ")
            let words = pieces.enumerated().map { TranscriptWord(text: " " + $0.element, start: 2 + Double($0.offset) * 0.4,
                                                                  end: 2.35 + Double($0.offset) * 0.4, confidence: 0.97) }
            return TrackTranscript(trackID: track, segments: [TranscriptSegment(trackID: track, start: 2, end: words.last!.end, text: text)],
                                   modelID: "parakeet/ultra", createdAt: Date(timeIntervalSince1970: time), words: words)
        }
        meeting.transcripts = [run("We ship the calendar on Thursday.", at: 1), run("We ship the calendar on Friday.", at: 2)]
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
    }

    func testBehaviorUnsureWordsGetADottedLineAndNothingElseDoes() throws {
        var meeting = Meeting(title: "Weekly")
        transcribedTwice(&meeting)
        let passage = try XCTUnwrap(meeting.unifiedTranscript.first)
        let marks = try XCTUnwrap(TranscriptLayout(meeting).unsure[passage.id])
        XCTAssertEqual(marks.map { $0.words(in: passage.text) }, ["Friday"], "The words, not the full stop after them")
        let text = UnsureWords.marked(passage.text, marks)
        let underlined = text.runs.compactMap { run -> String? in
            run[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] == nil ? nil : String(text[run.range].characters)
        }
        XCTAssertEqual(underlined, ["Friday"])
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

        XCTAssertTrue(TranscriptEdits.keep(flag.id, in: id, library: library, undoManager: undo))
        XCTAssertEqual(shown(), 0)
        XCTAssertEqual(undo.undoActionName, "Keep Words")
        undo.undo()
        XCTAssertEqual(shown(), 1, "Undo brings the mark back")
        XCTAssertNil(library.meeting(id)?.transcriptFlagDismissals)

        XCTAssertTrue(TranscriptEdits.useAlternative(flag.id, in: id, library: library, undoManager: undo))
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "We ship the calendar on Thursday.")
        XCTAssertEqual(shown(), 0)
        XCTAssertEqual(undo.undoActionName, "Correct Passage")
        XCTAssertTrue(library.meeting(id)?.revisions.contains { $0.kind == .segment(passage.id) } == true)
        undo.undo()
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "We ship the calendar on Friday.")
        XCTAssertNil(library.meeting(id)?.transcriptFlagDismissals)
        // Version History holds the correction and its undoing; the passage reads as it did, so its mark is back.
        XCTAssertEqual(shown(), 1)
    }
}
