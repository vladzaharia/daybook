import XCTest

@testable import DaybookCore

final class NoteInkTests: XCTestCase {
    private func block(_ id: UUID = UUID(), recognized: String? = nil, strokes: String = "a", at date: Date = Date(timeIntervalSince1970: 100)) -> NoteInk {
        NoteInk(id: id, drawing: Data(strokes.utf8), width: 320, height: 120, recognized: recognized, updatedAt: date)
    }

    // MARK: A paragraph of the notes

    func testBehaviorInkIsAParagraphOfWordsOnOneLine() {
        XCTAssertEqual(block(recognized: "first line\n  second line ").paragraphText, "first line second line")
        XCTAssertEqual(block(recognized: nil).paragraphText, NoteInk.placeholder, "not read yet")
        XCTAssertEqual(block(recognized: " \n").paragraphText, NoteInk.placeholder, "a sketch has no words")
    }

    func testBehaviorInsertingAddsAParagraphAnchoredByTheBlocksIDAndLeavesTheRest() {
        let id = UUID()
        let cases: [(text: String, after: Int?, expected: String)] = [
            ("", nil, "Ink"),
            ("  \n", nil, "Ink"),
            ("One", nil, "One\nInk"),
            ("One\n", nil, "One\nInk"),
            ("One\nTwo", 0, "One\nInk\nTwo"),
            ("One\n\nTwo", 0, "One\nInk\n\nTwo"),
            ("One\nTwo", 1, "One\nTwo\nInk"),
            ("One\nTwo", 7, "One\nTwo\nInk"),
        ]
        for example in cases {
            let applied = NoteTimeline.inserting("Ink", id: id, time: 4, after: example.after, in: example.text, anchors: nil)
            XCTAssertEqual(applied.text, example.expected)
            XCTAssertEqual(applied.anchors.first { $0.id == id }?.text, "Ink")
            XCTAssertEqual(applied.anchors.first { $0.id == id }?.time, 4)
            XCTAssertEqual(applied.anchors.map(\.text), example.expected.split(separator: "\n").map(String.init))
        }
    }

    func testBehaviorInkKeepsItsPlaceAsTheNotesAroundItAreTyped() {
        var meeting = Meeting(title: "Notes", notes: "Before\nAfter")
        let ink = block(recognized: "ship it")
        meeting.addInk(ink, after: 0, time: 12)
        XCTAssertEqual(meeting.notes, "Before\nship it\nAfter")
        XCTAssertEqual(meeting.timedNotes?[1].id, ink.id)
        XCTAssertEqual(meeting.timedNotes?[1].time, 12)

        // Typing above, below, and adding a paragraph: the block stays with its paragraph.
        let edited = "Before, edited\nA new thought\nship it\nAfter, edited"
        meeting.timedNotes = NoteTimeline.reconcile(previous: meeting.timedNotes ?? [], text: edited, captureTime: nil)
        meeting.notes = edited
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [nil, nil, ink.id, nil])
        XCTAssertEqual(meeting.paragraphTimes()[2], 12, "the time it was written stays with it")
    }

    func testBehaviorTwoBlocksThatReadTheSameStayApart() {
        var meeting = Meeting(title: "Notes")
        let first = block(), second = block()
        meeting.addInk(first, after: nil)
        meeting.addInk(second, after: nil)
        XCTAssertEqual(meeting.notes, "Handwriting\nHandwriting")
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [first.id, second.id])
    }

    func testBehaviorRecognitionRewritesOnlyItsOwnParagraph() {
        var meeting = Meeting(title: "Notes", notes: "Typed")
        var ink = block()
        meeting.addInk(ink, after: nil, time: 3)
        ink.recognized = "call Sam\nabout pricing"
        meeting.updateInk(ink)
        XCTAssertEqual(meeting.notes, "Typed\ncall Sam about pricing")
        XCTAssertEqual(meeting.timedNotes?.last?.id, ink.id, "the same paragraph")
        XCTAssertEqual(meeting.timedNotes?.last?.time, 3, "written at the same moment")
    }

    func testBehaviorMoreStrokesThatReadTheSameLeaveACorrectionAlone() {
        var meeting = Meeting(title: "Notes")
        var ink = block(recognized: "call Sam")
        meeting.addInk(ink, after: nil)
        // Corrected on the Mac, which only sees a paragraph of words.
        let corrected = "Call Sam Ortiz"
        meeting.timedNotes = NoteTimeline.reconcile(previous: meeting.timedNotes ?? [], text: corrected, captureTime: nil)
        meeting.notes = corrected

        ink.drawing = Data("more strokes".utf8)
        meeting.updateInk(ink)
        XCTAssertEqual(meeting.notes, corrected)
        XCTAssertEqual(meeting.ink?.first?.drawing, Data("more strokes".utf8))
        XCTAssertEqual(meeting.inkPlacements().first??.id, ink.id, "still drawn in that paragraph")
    }

    func testBehaviorAVersionRestoreGivesAParagraphBackToItsInk() {
        var meeting = Meeting(title: "Notes", notes: "Typed")
        let ink = block(recognized: "ship it")
        meeting.addInk(ink, after: nil)
        meeting.timedNotes = [TimedNote(text: "Typed"), TimedNote(text: "ship it")]  // new anchors: nothing matches by ID
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [nil, nil], "words alone don't make a paragraph ink")
        meeting.reanchorInk()
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [nil, ink.id])
        XCTAssertEqual(meeting.timedNotes?.last?.id, ink.id, "it has its anchor again, so new words find its paragraph")
    }

    func testBehaviorTypingAnUnplacedBlocksWordsDoesNotTurnThemIntoInk() {
        var meeting = Meeting(title: "Notes")
        meeting.ink = [block(recognized: "ship it")]
        meeting.notes = "ship it"
        meeting.timedNotes = NoteTimeline.reconcile(previous: [], text: "ship it", captureTime: nil)
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [nil])
    }

    func testBehaviorThePlaceholderNeverClaimsATypedParagraph() {
        var meeting = Meeting(title: "Notes", notes: "Handwriting")
        meeting.timedNotes = [TimedNote(text: "Handwriting")]
        meeting.ink = [block()]  // not read yet, and its own paragraph is gone
        meeting.reanchorInk()
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [nil])
    }

    func testBehaviorADeletedParagraphTakesItsInkOutOfTheNotes() {
        var meeting = Meeting(title: "Notes", notes: "Typed")
        let ink = block(recognized: "ship it")
        meeting.addInk(ink, after: nil)
        meeting.timedNotes = NoteTimeline.reconcile(previous: meeting.timedNotes ?? [], text: "Typed", captureTime: nil)
        meeting.notes = "Typed"
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [nil])
        XCTAssertEqual(meeting.ink?.map(\.id), [ink.id], "kept, as a restored version can bring it back")
    }

    func testBehaviorConvertingLeavesItsParagraphAsTypedWords() {
        var meeting = Meeting(title: "Notes", notes: "Before")
        let ink = block(recognized: "first line\nsecond line")
        meeting.addInk(ink, after: nil, time: 8)
        meeting.removeInk(ink.id, keepingWords: true)
        XCTAssertEqual(meeting.notes, "Before\nfirst line second line")
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [nil, nil], "no ink drawn any more")
        XCTAssertEqual(meeting.ink?.first?.drawing, Data(), "the strokes go")
        XCTAssertEqual(meeting.paragraphTimes()[1], 8, "written at the same moment")
    }

    func testBehaviorConvertingKeepsACorrectionFromAnotherDevice() {
        var meeting = Meeting(title: "Notes")
        let ink = block(recognized: "call Sam")
        meeting.addInk(ink, after: nil)
        let corrected = "Call Sam Ortiz"
        meeting.timedNotes = NoteTimeline.reconcile(previous: meeting.timedNotes ?? [], text: corrected, captureTime: nil)
        meeting.notes = corrected
        meeting.removeInk(ink.id, keepingWords: true)
        XCTAssertEqual(meeting.notes, corrected)
    }

    func testBehaviorConvertingASketchRemovesItsPlaceholder() {
        var meeting = Meeting(title: "Notes", notes: "Before")
        let ink = block()
        meeting.addInk(ink, after: nil)
        meeting.removeInk(ink.id, keepingWords: true)
        XCTAssertEqual(meeting.notes, "Before")
    }

    func testBehaviorUndoingADeletePutsItsParagraphBackAndLeavesTheRest() throws {
        var meeting = Meeting(title: "Notes", notes: "Before\nAfter")
        let ink = block(recognized: "ship it")
        meeting.addInk(ink, after: 0, time: 5)
        let removal = try XCTUnwrap(meeting.removeInk(ink.id, keepingWords: false))
        XCTAssertEqual(meeting.notes, "Before\nAfter")

        // A paragraph from a Mac arrives before the Undo.
        meeting.applySharedNote(SharedNote(id: UUID(), text: "From the Mac", time: 9))
        meeting.restoreInk(removal)
        XCTAssertEqual(meeting.notes, "Before\nship it\nAfter\nFrom the Mac", "the Mac's paragraph stays")
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [nil, ink.id, nil, nil])
        XCTAssertEqual(meeting.ink?.first?.drawing, ink.drawing)
        XCTAssertEqual(meeting.paragraphTimes()[1], 5)
    }

    func testBehaviorUndoingADeleteOfTheFirstParagraphPutsItFirst() throws {
        var meeting = Meeting(title: "Notes", notes: "After")
        let ink = block(recognized: "ship it")
        meeting.addInk(ink, after: -1)
        XCTAssertEqual(meeting.notes, "ship it\nAfter")
        let removal = try XCTUnwrap(meeting.removeInk(ink.id, keepingWords: false))
        meeting.restoreInk(removal)
        XCTAssertEqual(meeting.notes, "ship it\nAfter")
    }

    func testBehaviorUndoingAConversionKeepsItsParagraph() throws {
        var meeting = Meeting(title: "Notes", notes: "Before")
        let ink = block(recognized: "ship it")
        meeting.addInk(ink, after: nil)
        let removal = try XCTUnwrap(meeting.removeInk(ink.id, keepingWords: true))
        meeting.restoreInk(removal)
        XCTAssertEqual(meeting.notes, "Before\nship it")
        XCTAssertEqual(meeting.inkPlacements().map { $0?.id }, [nil, ink.id])
    }

    func testBehaviorAResultLandingAfterADeleteDoesNotBringItBack() {
        var meeting = Meeting(title: "Notes")
        var ink = block()
        meeting.addInk(ink, after: nil)
        meeting.removeInk(ink.id, keepingWords: false)
        ink.recognized = "late words"
        meeting.updateInk(ink)
        XCTAssertNotNil(meeting.ink?.first?.removedAt)
        XCTAssertEqual(meeting.notes, "")
    }

    func testBehaviorAnUpdateKeepsWhatANewerDaybookAdded() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","drawing":"YQ==","width":320,"height":120,"updatedAt":10,"future":{"a":1}}"#
        let stored = try JSONDecoder().decode(NoteInk.self, from: Data(json.utf8))
        var meeting = Meeting(title: "Notes")
        meeting.addInk(stored, after: nil)
        meeting.updateInk(NoteInk(id: stored.id, drawing: Data("more".utf8), width: 320, height: 120, recognized: "words"))
        XCTAssertEqual(meeting.ink?.first?.unknownFields, stored.unknownFields)
    }

    func testBehaviorANotesConflictDoesNotStrandAnotherCopysInk() {
        var base = Meeting(title: "Notes", notes: "Start")
        base.timedNotes = NoteTimeline.reconcile(previous: [], text: "Start", captureTime: nil)
        for edited in ["Start, edited on the Mac", "A: edited on the Mac", "Z: edited on the Mac"] {
            var phone = base
            let ink = block(recognized: "ship it")
            phone.addInk(ink, after: nil, time: 7)
            var mac = base
            mac.notes = edited
            mac.timedNotes = NoteTimeline.reconcile(previous: base.timedNotes ?? [], text: edited, captureTime: nil)

            let merged = MeetingMerge.merge(base: base, local: phone, remote: mac).meeting
            let flipped = MeetingMerge.merge(base: base, local: mac, remote: phone).meeting
            XCTAssertEqual(merged.notes, flipped.notes, "either order, the same notes")
            XCTAssertTrue(merged.inkPlacements().contains { $0?.id == ink.id }, "the strokes are still reachable (\(edited))")
            XCTAssertEqual(merged.paragraphTimes().compactMap { $0 }, [7], "at the moment it was written")
        }
    }

    func testBehaviorADeletedBlockStaysOutThroughANotesConflict() {
        var base = Meeting(title: "Notes", notes: "Start")
        let ink = block(recognized: "ship it")
        base.addInk(ink, after: nil)
        var deleted = base
        deleted.removeInk(ink.id, keepingWords: false)
        var edited = base
        edited.notes = "Start\nship it\nmore"
        edited.timedNotes = NoteTimeline.reconcile(previous: base.timedNotes ?? [], text: edited.notes, captureTime: nil)
        let merged = MeetingMerge.merge(base: base, local: deleted, remote: edited).meeting
        XCTAssertFalse(merged.inkPlacements().contains { $0?.id == ink.id })
    }

    func testBehaviorARestoreToBeforeTheInkStaysThatWayThroughAMerge() {
        var meeting = Meeting(title: "Notes", notes: "Start")
        meeting.timedNotes = NoteTimeline.reconcile(previous: [], text: "Start", captureTime: nil)
        meeting.ink = [block(recognized: "ship it")]  // live, but no copy has a paragraph for it
        var other = meeting
        other.title = "Renamed"
        let merged = MeetingMerge.merge(base: meeting, local: meeting, remote: other).meeting
        XCTAssertEqual(merged.notes, "Start")
    }

    func testBehaviorAnOlderCopyCannotBringDeletedInkBack() {
        var base = Meeting(title: "Notes")
        let ink = block(at: Date(timeIntervalSince1970: 100))
        base.addInk(ink, after: nil)
        var deleted = base
        deleted.removeInk(ink.id, keepingWords: false, at: Date(timeIntervalSince1970: 200))
        let merged = MeetingMerge.merge(base: base, local: deleted, remote: base).meeting
        XCTAssertNotNil(merged.ink?.first?.removedAt)
        XCTAssertEqual(MeetingMerge.merge(base: base, local: base, remote: deleted).meeting.ink, merged.ink)
    }

    // MARK: Storage

    func testBehaviorInkRoundTrips() throws {
        var meeting = Meeting(title: "Notes")
        meeting.addInk(block(recognized: "ship it"), after: nil)
        let decoded = try JSONDecoder().decode(Meeting.self, from: SyncEncoding.data(meeting))
        XCTAssertEqual(decoded.ink, meeting.ink)
    }

    func testBehaviorALibraryFromBeforeInkDecodes() throws {
        let meeting = Meeting(title: "Notes")
        XCTAssertFalse(String(decoding: try SyncEncoding.data(meeting), as: UTF8.self).contains("\"ink\""))
        XCTAssertNil(try JSONDecoder().decode(Meeting.self, from: SyncEncoding.data(meeting)).ink)
    }

    func testBehaviorWhatANewerDaybookAddedToABlockIsKept() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","drawing":"YQ==","width":320,"height":120,"updatedAt":10,"future":{"a":1}}"#
        let decoded = try JSONDecoder().decode(NoteInk.self, from: Data(json.utf8))
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertEqual(again?["future"] as? [String: Int], ["a": 1])
    }

    // MARK: Merging

    func testBehaviorEveryCopysHandwritingSurvives() {
        let base = Meeting(title: "Notes")
        var local = base, remote = base
        let left = block(recognized: "left"), right = block(recognized: "right")
        local.addInk(left, after: nil)
        remote.addInk(right, after: nil)
        let merged = MeetingMerge.merge(base: base, local: local, remote: remote).meeting
        XCTAssertEqual(Set(merged.ink?.map(\.id) ?? []), [left.id, right.id])
        XCTAssertEqual(merged.ink, MeetingMerge.merge(base: base, local: remote, remote: local).meeting.ink, "either order, the same result")
    }

    func testBehaviorTheNewerStrokesOfABlockWin() {
        let id = UUID()
        var base = Meeting(title: "Notes")
        base.addInk(block(id, at: Date(timeIntervalSince1970: 100)), after: nil)
        var local = base, remote = base
        local.ink = [block(id, strokes: "older", at: Date(timeIntervalSince1970: 200))]
        remote.ink = [block(id, strokes: "newer", at: Date(timeIntervalSince1970: 300))]
        XCTAssertEqual(MeetingMerge.merge(base: base, local: local, remote: remote).meeting.ink?.first?.drawing, Data("newer".utf8))
        XCTAssertEqual(MeetingMerge.merge(base: base, local: remote, remote: local).meeting.ink?.first?.drawing, Data("newer".utf8))
    }

    func testBehaviorNotesMergedBeforeInkExistedStayNil() {
        let base = Meeting(title: "Notes")
        var local = base
        local.notes = "Typed"
        XCTAssertNil(MeetingMerge.merge(base: base, local: local, remote: base).meeting.ink)
    }
}
