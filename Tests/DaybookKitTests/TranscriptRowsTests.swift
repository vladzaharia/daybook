import DaybookCore
import XCTest
@testable import DaybookKit

/// The transcript's rows as both apps lay them out, the passages the person corrected, and what Find in Conversation
/// steps through.
final class TranscriptRowsTests: XCTestCase {
    private let track = UUID()

    private func meeting() -> Meeting {
        let lines: [(String, String, Double)] = [
            ("S0", "The release date holds.", 0),
            ("S0", "Notes for the release are drafted.", 4),
            ("S1", "Export isn't in the beta.", 9),
            ("S0", "Then the Release notes say so.", 14),
        ]
        let segments = lines.map { speaker, text, start in
            TranscriptSegment(trackID: track, start: start, end: start + 3, text: text, speakerID: speaker)
        }
        var meeting = Meeting(title: "Weekly", unifiedTranscript: segments)
        meeting.speakers = [Speaker(id: "S0", name: "Maya"), Speaker(id: "S1", name: "Daniel")]
        meeting.timedNotes = [TimedNote(time: 10, text: "Ask about the release notes")]
        return meeting
    }

    func testBehaviorRowsAreTurnsThenTheirPassagesWithNotesAtTheirTimes() {
        let meeting = meeting()
        let rows = TranscriptRow.rows(in: meeting)
        let kinds = rows.map { row -> String in
            switch row {
            case .turn: return "turn"
            case .passage: return "passage"
            case .note: return "note"
            case .photo: return "photo"
            }
        }
        XCTAssertEqual(kinds, ["turn", "passage", "passage", "turn", "passage", "note", "turn", "passage"])
        XCTAssertEqual(rows[1].id, meeting.unifiedTranscript[0].id.uuidString, "a passage is named by its own ID, as search hits name it")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "every row is its own scroll target")
        XCTAssertNil(rows[0].findableText, "a turn's header has no words of its own to find")
    }

    func testBehaviorCorrectedPassagesComeFromVersionHistory() {
        var meeting = meeting()
        let corrected = meeting.unifiedTranscript[2].id
        meeting.correctSegment(id: corrected, text: "Export is in the beta.")
        meeting.renameSpeaker(id: "S1", name: "Dan")
        XCTAssertEqual(TranscriptCorrections.segmentIDs(in: meeting), [corrected])
    }

    func testBehaviorFindCountsMatchingRowsAndStepsRoundBothWays() {
        let rows = TranscriptRow.rows(in: meeting())
        var matches = TranscriptFindMatches(query: "RELEASE", in: rows)
        XCTAssertEqual(matches.count, 4, "case doesn't matter, and your note counts")
        XCTAssertEqual(matches.label(query: "RELEASE"), "1 of 4")
        matches.step(-1)
        XCTAssertEqual(matches.label(query: "RELEASE"), "4 of 4", "Find Previous from the first goes round to the last")
        matches.step(1)
        XCTAssertEqual(matches.currentID, matches.ids.first)

        let none = TranscriptFindMatches(query: "pricing", in: rows)
        XCTAssertEqual(none.label(query: "pricing"), "No matches")
        XCTAssertNil(none.currentID)
        XCTAssertNil(TranscriptFindMatches(query: "  ", in: rows).label(query: "  "), "nothing typed says nothing")
    }

    func testBehaviorFindStaysOnItsRowWhenTheTranscriptChanges() {
        var meeting = meeting()
        var matches = TranscriptFindMatches(query: "release", in: TranscriptRow.rows(in: meeting))
        matches.step(1)
        let current = matches.currentID

        // A correction elsewhere: the same row still matches, so Find stays on it.
        meeting.correctSegment(id: meeting.unifiedTranscript[2].id, text: "Export misses the release.")
        let refreshed = matches.refreshed(query: "release", in: TranscriptRow.rows(in: meeting))
        XCTAssertEqual(refreshed.count, 5)
        XCTAssertEqual(refreshed.currentID, current)

        // Its own row stops matching: the next match after where it was.
        meeting.correctSegment(id: meeting.unifiedTranscript[1].id, text: "Notes are drafted.")
        let moved = matches.refreshed(query: "release", in: TranscriptRow.rows(in: meeting))
        XCTAssertEqual(moved.currentID, meeting.unifiedTranscript[2].id.uuidString)
    }
}
