import XCTest
@testable import DaybookCore

final class TimedNotesTests: XCTestCase {
    func testExistingNoteRetainsOriginalTimeWhenEdited() {
        let original = TimedNote(time: 12, text: "Discuss budget")
        let notes = NoteTimeline.reconcile(previous: [original], text: "Discuss next year's budget", captureTime: 99)
        XCTAssertEqual(notes.first?.id, original.id)
        XCTAssertEqual(notes.first?.time, 12)
        XCTAssertEqual(notes.first?.text, "Discuss next year's budget")
    }

    func testNewParagraphsHaveCurrentTimeWithoutRestampingNeighbors() {
        let before = [TimedNote(time: 10, text: "First"), TimedNote(time: 20, text: "Last")]
        let after = NoteTimeline.reconcile(previous: before, text: "Inserted above\nFirst\nNew thought\nLast\nAdded below", captureTime: 30)
        XCTAssertEqual(after.map(\.time), [30, 10, 30, 20, 30])
        XCTAssertEqual(after[1].id, before[0].id)
        XCTAssertEqual(after[3].id, before[1].id)
    }

    func testDeletingParagraphDoesNotShiftRemainingTimestamps() {
        let before = [TimedNote(time: 1, text: "Delete"), TimedNote(time: 2, text: "Keep"), TimedNote(time: 3, text: "Also keep")]
        let after = NoteTimeline.reconcile(previous: before, text: "Keep\nAlso keep", captureTime: 50)
        XCTAssertEqual(after, Array(before.suffix(2)))
    }

    func testPreAndPostMeetingNotesHaveNoInventedTimes() {
        let before = NoteTimeline.reconcile(previous: [], text: "Agenda", captureTime: nil)
        let during = NoteTimeline.reconcile(previous: before, text: "Agenda updated\nDecision", captureTime: 35)
        let after = NoteTimeline.reconcile(previous: during, text: "Agenda updated\nDecision refined\nReflection", captureTime: nil)
        XCTAssertEqual(after.map(\.time), [nil, 35, nil])
        XCTAssertEqual(after[0].id, before[0].id)
    }

    func testSplittingExistingParagraphPreservesItsOriginalAnchor() {
        let original = TimedNote(time: 12, text: "Budget and travel")
        let notes = NoteTimeline.reconcile(previous: [original], text: "Budget\nand travel", captureTime: 99)
        XCTAssertEqual(notes.map(\.time), [12, 12])
        XCTAssertEqual(notes[0].id, original.id)
        XCTAssertNotEqual(notes[0].id, notes[1].id)
    }

    func testSplittingPreMeetingParagraphDoesNotCreateRecordedTimestamp() {
        let notes = NoteTimeline.reconcile(previous: [TimedNote(text: "Plan budget")], text: "Plan\nbudget", captureTime: 99)
        XCTAssertTrue(notes.allSatisfy { $0.time == nil })
    }

    func testJoiningParagraphsKeepsFirstOriginalAnchor() {
        let before = [TimedNote(time: 10, text: "One"), TimedNote(time: 20, text: "two")]
        let after = NoteTimeline.reconcile(previous: before, text: "One two", captureTime: 90)
        XCTAssertEqual(after.first?.id, before[0].id)
        XCTAssertEqual(after.first?.time, 10)
    }

    func testDuplicateParagraphsHaveDistinctStableIdentities() {
        let before = NoteTimeline.reconcile(previous: [], text: "Repeat\nRepeat", captureTime: 1)
        let after = NoteTimeline.reconcile(previous: before, text: "Repeat\nRepeat\nRepeat", captureTime: 2)
        XCTAssertEqual(after[0], before[0])
        XCTAssertEqual(after[1], before[1])
        XCTAssertEqual(after[2].time, 2)
        XCTAssertEqual(Set(after.map(\.id)).count, 3)
    }

    func testEditedParagraphIsMatchedPastNewInsertion() {
        let before = [TimedNote(time: 1, text: "Budget discussion"), TimedNote(time: 2, text: "Final decision")]
        let after = NoteTimeline.reconcile(previous: before, text: "New topic\nBudget discussion updated\nFinal decision", captureTime: 9)
        XCTAssertEqual(after.map(\.time), [9, 1, 2])
        XCTAssertEqual(after[1].id, before[0].id)
    }

    func testWhitespaceAndNonfiniteTimesDoNotCreateEmptyOrFalseNotes() {
        XCTAssertTrue(NoteTimeline.reconcile(previous: [], text: " \r\n \t\n", captureTime: 1).isEmpty)
        let notes = NoteTimeline.reconcile(previous: [], text: "Thought", captureTime: .nan)
        XCTAssertNil(notes.first?.time)
        XCTAssertNil(TimedNote(time: -.infinity, text: "Thought").time)
    }

    func testRoundTripPreservesIdentityAndFractionalTimestamp() throws {
        let note = TimedNote(time: 12.345, text: "A detail")
        XCTAssertEqual(try JSONDecoder().decode(TimedNote.self, from: JSONEncoder().encode(note)), note)
    }
}
