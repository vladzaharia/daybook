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

    /// A photo added, deleted, or put back, and a recording removed or moved, keep only a mark of what happened: the title
    /// says it, with no Before and After of stored words ("added", "present", "removed").
    func testAPhotoOrRecordingChangeIsSaidByItsTitleAlone() {
        var meeting = Meeting(title: "Whiteboard")
        let photo = MeetingPhoto(relativePath: "Originals/Photos/a.jpg", fileName: "a.jpg", sha256: "", capturedAt: Date())
        meeting.addPhoto(photo)
        meeting.removePhoto(photo.id)
        meeting.restorePhoto(photo.id)
        XCTAssertEqual(meeting.revisions.map { RevisionText.title($0, in: meeting) }, ["Photo added", "Photo deleted", "Photo put back"])
        for revision in meeting.revisions { XCTAssertFalse(RevisionText.showsComparison(revision), revision.newValue) }
        let removed = MeetingRevision(field: "source:\(UUID().uuidString):removed", oldValue: "", newValue: "Removed the recorder’s recording")
        XCTAssertFalse(RevisionText.showsComparison(removed))
        XCTAssertTrue(RevisionText.showsComparison(MeetingRevision(field: "notes", oldValue: "", newValue: "Agenda")))
        XCTAssertTrue(RevisionText.showsComparison(MeetingRevision(field: "photo-caption:\(photo.id.uuidString)", oldValue: "", newValue: "Board")),
                      "a caption's words are compared")
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

    /// Regression: a merge's entry read "Edited on two Macs", though `MeetingMerge` records one for any two
    /// devices, the iPhone included.
    func testEachChangeReadsByItsKind() {
        let meeting = Meeting(title: "Sync")
        let merged = MeetingRevision(kind: .sync("notes"), oldValue: "Agenda", newValue: "Agenda, beta date")
        XCTAssertEqual(RevisionText.title(merged, in: meeting), "Edited on two devices")
        XCTAssertEqual(RevisionText.symbol(merged), "arrow.triangle.branch")
        XCTAssertFalse(RevisionRestore.canRestore(merged, in: meeting))

        let track = UUID()
        let added = MeetingRevision(kind: .source(track.uuidString), oldValue: "", newValue: "Added iPhone")
        XCTAssertEqual(added.field, "source:\(track.uuidString)", "Stored as earlier versions wrote it")
        XCTAssertEqual(RevisionText.title(added, in: meeting), "Added iPhone")
        XCTAssertEqual(RevisionText.symbol(added), "waveform")

        let caption = MeetingRevision(kind: .photoCaption(UUID()), oldValue: "", newValue: "Whiteboard")
        XCTAssertEqual(RevisionText.title(caption, in: meeting), "Photo caption edited")
        XCTAssertEqual(RevisionText.symbol(caption), "text.below.photo")

        let review = RevisionField.correctionTransfer(UUID()).rawValue
        XCTAssertEqual(RevisionText.readable("dismissed", field: review), "Kept in Version History only")

        let newer = MeetingRevision(field: "chapter:3", oldValue: "", newValue: "Intro")
        XCTAssertEqual(newer.kind, .unknown("chapter:3"), "A newer Daybook's kind is kept as written")
        XCTAssertEqual(RevisionText.title(newer, in: meeting), "Edited")
        XCTAssertEqual(RevisionText.subject(newer, in: meeting), "Edited")
        XCTAssertFalse(RevisionRestore.canRestore(newer, in: meeting))
    }

    func testRowPreviewSkipsANoteThatRepeatsTheTitle() {
        let meeting = Meeting(title: "Offsite ideas", notes: "offsite  Ideas\n- Half day on the roadmap")
        XCTAssertEqual(RowPreview.text(for: meeting), "Half day on the roadmap")
        XCTAssertEqual(RowPreview.text(for: Meeting(title: "Offsite ideas", notes: "Offsite ideas")), "Notes only")
        XCTAssertEqual(RowPreview.text(for: Meeting(title: "Offsite ideas")), "No notes")
    }

    // MARK: Laid out as the page lays it out

    private func summaryRevision(old: MeetingSummary?, new: MeetingSummary) throws -> MeetingRevision {
        func json(_ summary: MeetingSummary?) throws -> String {
            guard let summary else { return "" }
            return try XCTUnwrap(String(data: JSONEncoder().encode(summary), encoding: .utf8))
        }
        return MeetingRevision(field: "summary", oldValue: try json(old), newValue: try json(new))
    }

    func testBehaviorASummaryChangeIsLaidOutInThePagesBlocksWithBulletsInTheirOwnRows() throws {
        let summary = MeetingSummary(overview: "The team kept the **14th**.",
                                     sections: [SummarySection(heading: "Decisions", body: "- Keep the date.\n- The sync fix is the gate, and a long bullet wraps under its words.\n1. Ship it")],
                                     modelID: "m")
        let revision = try summaryRevision(old: nil, new: summary)
        let layout = RevisionLayout(revision.newValue, field: revision.field)
        XCTAssertEqual(layout.blocks.map(\.kind), [.paragraph, .heading, .bullet, .bullet, .numbered("1.")])
        XCTAssertEqual(layout.blocks.map { String($0.text.characters) },
                       ["The team kept the 14th.", "Decisions", "Keep the date.", "The sync fix is the gate, and a long bullet wraps under its words.", "Ship it"],
                       "no Markdown marks and no bullet character left in the words")
        XCTAssertTrue(layout.blocks[1].startsSection)
        XCTAssertEqual(layout.blocks[0].text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(layout.blocks[0].text[$0.range].characters) },
                       "14th", "bold stays bold")
    }

    func testBehaviorMarkingChangedWordsKeepsEachBlockInItsPlace() throws {
        let old = MeetingSummary(overview: "Hold the date.", sections: [SummarySection(heading: "Decisions", body: "- The sink fix gates it.")], modelID: "m")
        let new = MeetingSummary(overview: "Hold the date.", sections: [SummarySection(heading: "Decisions", body: "- The sync fix gates it.")], modelID: "m")
        let revision = try summaryRevision(old: old, new: new)
        // Foundation's own attribute as a marker, so the test needs no UI framework.
        var removed = AttributeContainer(), inserted = AttributeContainer()
        removed.languageIdentifier = "removed"
        inserted.languageIdentifier = "inserted"
        let marked = RevisionLayout.marked(old: RevisionLayout(revision.oldValue, field: revision.field),
                                           new: RevisionLayout(revision.newValue, field: revision.field), removed: removed, inserted: inserted)
        XCTAssertEqual(marked.new.blocks.map(\.kind), [.paragraph, .heading, .bullet])
        let bullet = marked.new.blocks[2].text
        let insertedWords = bullet.runs.filter { $0.languageIdentifier == "inserted" }.map { String(bullet[$0.range].characters) }
        XCTAssertEqual(insertedWords, ["sync"])
        let struck = marked.old.blocks[2].text.runs.filter { $0.languageIdentifier == "removed" }.map { String(marked.old.blocks[2].text[$0.range].characters) }
        XCTAssertEqual(struck, ["sink"])
        XCTAssertTrue(marked.new.blocks[0].text.runs.allSatisfy { $0.languageIdentifier == nil }, "unchanged blocks stay unmarked")
    }

    func testBehaviorAnythingButASummaryIsOneParagraphAsWritten() {
        let layout = RevisionLayout("Beta date\n- not a bullet here", field: "notes")
        XCTAssertEqual(layout.blocks.count, 1)
        XCTAssertEqual(String(layout.blocks[0].text.characters), "Beta date\n- not a bullet here")
        XCTAssertTrue(RevisionLayout("", field: "summary").isEmpty, "an empty Before")
    }
}
