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

    /// Regression: Version History showed a summary's Markdown marks ("**14th**") on both apps.
    func testASummaryShowsItsMarkdownDrawnWithNoMarksLeft() throws {
        let summary = MeetingSummary(overview: "Keep the **14th**.", sections: [
            SummarySection(heading: "Decisions", body: "- Keep the **14th** as the beta date.\n  * Gate on the *fix*\n2. Ship it\n## Later\nSee [the notes](https://example.com).")])
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(summary), encoding: .utf8))
        let styled = RevisionText.styled(json, field: "summary")
        let text = "Keep the 14th.\n\nDecisions\n• Keep the 14th as the beta date.\n• Gate on the fix\n2. Ship it\nLater\nSee the notes."
        XCTAssertEqual(String(styled.characters), text)
        XCTAssertEqual(RevisionText.readable(json, field: "summary"), text, "The plain text is the same words")
        XCTAssertEqual(RevisionText.readable(json, field: "sync:summary"), text, "The version two devices left in history reads the same")
        let bold = styled.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }.map { String(styled[$0.range].characters) }
        XCTAssertEqual(bold, ["14th", "Decisions", "14th", "Later"])
        let italic = styled.runs.filter { $0.inlinePresentationIntent?.contains(.emphasized) == true }.map { String(styled[$0.range].characters) }
        XCTAssertEqual(italic, ["fix"])
        XCTAssertFalse(styled.runs.contains { $0.link != nil }, "A model's link is dropped, as on the page")
        XCTAssertEqual(String(RevisionText.styled("Agenda **as typed**", field: "notes").characters), "Agenda **as typed**", "Notes are the person's own text")
    }

    func testMarkingChangedWordsKeepsTheTextsOwnStyle() {
        var marker = AttributeContainer()
        marker.languageIdentifier = "changed"
        let old = ModelText.inlineMarkdown("Keep the **15th** date."), new = ModelText.inlineMarkdown("Keep the **14th** date.")
        let marked = WordChanges.marked(old: old, new: new, removed: marker, inserted: marker)
        XCTAssertEqual(String(marked.new.characters), "Keep the 14th date.")
        let changed = marked.new.runs.filter { $0.languageIdentifier == "changed" }
        XCTAssertEqual(changed.map { String(marked.new[$0.range].characters) }, ["14th"], "Only the word, not the space after it")
        XCTAssertEqual(changed.first?.inlinePresentationIntent, .stronglyEmphasized, "Still bold")
        XCTAssertEqual(marked.old.runs.filter { $0.languageIdentifier == "changed" }.map { String(marked.old[$0.range].characters) }, ["15th"])
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
