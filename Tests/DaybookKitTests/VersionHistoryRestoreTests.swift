import DaybookCore
import XCTest
@testable import DaybookKit

final class VersionHistoryRestoreTests: XCTestCase {
    func testRestoringAPassageKeepsTheReplacedTextInHistory() {
        var meeting = Meeting(title: "Sync", unifiedTranscript: [TranscriptSegment(trackID: UUID(), start: 0, end: 2, text: "The sink fix")])
        let segment = meeting.unifiedTranscript[0].id
        meeting.correctSegment(id: segment, text: "The sync fix")
        let change = meeting.revisions[0]

        XCTAssertTrue(RevisionRestore.canRestore(change, in: meeting))
        RevisionRestore.apply(change, to: &meeting)

        XCTAssertEqual(meeting.unifiedTranscript[0].text, "The sink fix")
        XCTAssertEqual(meeting.revisions.count, 2)
        XCTAssertEqual(meeting.revisions.last?.oldValue, "The sync fix")
        XCTAssertFalse(RevisionRestore.canRestore(change, in: meeting), "Nothing left to restore once the text matches")
    }

    func testRestoringNotesKeepsTheirTimesForUnchangedParagraphs() {
        var meeting = Meeting(title: "Sync", notes: "Beta date\nExport", timedNotes: [TimedNote(time: 2, text: "Beta date"), TimedNote(time: 24, text: "Export")])
        meeting.setNotes("Beta date\nExport\nKenji joining?")
        let change = meeting.revisions[0]

        RevisionRestore.apply(change, to: &meeting)

        XCTAssertEqual(meeting.notes, "Beta date\nExport")
        XCTAssertEqual(meeting.timedNotes?.map(\.time), [2, 24])
        XCTAssertEqual(meeting.revisions.last?.oldValue, "Beta date\nExport\nKenji joining?")
    }

    func testAFirstSummaryReadsAsWrittenWithNothingBefore() {
        var meeting = Meeting(title: "Sync")
        meeting.setSummary(MeetingSummary(overview: "First", modelID: "m"))
        let first = meeting.revisions[0]
        XCTAssertEqual(RevisionText.title(first, in: meeting), "Summary written")
        XCTAssertFalse(RevisionText.hasBefore(first))
        XCTAssertFalse(RevisionRestore.canRestore(first, in: meeting))

        meeting.setSummary(MeetingSummary(overview: "Second", modelID: "m"))
        let second = meeting.revisions[1]
        XCTAssertEqual(RevisionText.title(second, in: meeting), "Summary replaced")
        XCTAssertTrue(RevisionText.hasBefore(second))
        XCTAssertTrue(RevisionText.hasBefore(MeetingRevision(field: "notes", oldValue: "", newValue: "Agenda")), "Only a summary is written from nothing")
    }

    func testRestoringASpeakerNameAndASummary() throws {
        var meeting = Meeting(title: "Sync", speakers: [Speaker(id: "s1", name: "Speaker 1")])
        meeting.renameSpeaker(id: "s1", name: "Priya")
        RevisionRestore.apply(meeting.revisions[0], to: &meeting)
        XCTAssertEqual(meeting.speakers[0].name, "Speaker 1")

        meeting.setSummary(MeetingSummary(overview: "First", modelID: "m"))
        meeting.setSummary(MeetingSummary(overview: "Second", modelID: "m"))
        let replaced = try XCTUnwrap(meeting.revisions.last)
        XCTAssertTrue(RevisionRestore.canRestore(replaced, in: meeting))
        RevisionRestore.apply(replaced, to: &meeting)
        XCTAssertEqual(meeting.summary?.overview, "First")
    }

    func testChangesThatCantBeUndoneOfferNoRestore() {
        var meeting = Meeting(title: "Sync")
        meeting.setSummary(MeetingSummary(overview: "First", modelID: "m"))
        XCTAssertFalse(RevisionRestore.canRestore(meeting.revisions[0], in: meeting), "There was no summary before the first one")
        XCTAssertFalse(RevisionRestore.canRestore(MeetingRevision(field: "sync", oldValue: "a", newValue: "b"), in: meeting))
        XCTAssertFalse(RevisionRestore.canRestore(MeetingRevision(field: "segment:\(UUID().uuidString)", oldValue: "a", newValue: "b"), in: meeting))
    }

    func testRowPreviewSkipsANoteThatRepeatsTheTitle() {
        let meeting = Meeting(title: "Offsite ideas", notes: "offsite  Ideas\n- Half day on the roadmap")
        XCTAssertEqual(RowPreview.text(for: meeting), "Half day on the roadmap")
        XCTAssertEqual(RowPreview.text(for: Meeting(title: "Offsite ideas", notes: "Offsite ideas")), "Notes only")
        XCTAssertEqual(RowPreview.text(for: Meeting(title: "Offsite ideas")), "No notes")
    }
}
