import DaybookKit
import XCTest

@testable import DaybookPhone

@MainActor
final class HandwritingNotesTests: XCTestCase {
    func testAppendingUsesExistingParagraphBoundariesWithoutChangingNotes() throws {
        let cases: [(notes: String, reviewed: String, expected: String)] = [
            ("", "  First\nSecond  \n", "First\nSecond"),
            ("Existing", "First\nSecond", "Existing\nFirst\nSecond"),
            ("Existing\n", "\nFirst\nSecond\n", "Existing\nFirst\nSecond"),
            ("Existing\n\n", "First", "Existing\n\nFirst"),
            ("Existing\r\n", "First", "Existing\r\nFirst"),
            ("Existing\u{2028}  ", "First", "Existing\u{2028}  First"),
            ("Existing  ", "First", "Existing  \nFirst"),
            ("  ", "First", "  First"),
        ]
        for example in cases {
            XCTAssertEqual(
                HandwritingNotes.appending(example.reviewed, to: example.notes), example.expected)
        }
    }

    func testEmptyReviewIsNeverInserted() {
        for draft in ["", "  ", "\n\t\r\n"] {
            XCTAssertNil(HandwritingNotes.appending(draft, to: "Existing"))
            XCTAssertNil(HandwritingNotes.appending(draft, to: ""))
        }
    }

    func testFiledNotesKeepExistingTimesAndGiveReviewedParagraphsNoRecordingTime() async throws {
        let library = LibraryController(rootURL: try temporaryDirectory(), sync: nil)
        try await library.load()
        let id = library.newMeeting(title: "Notes")
        library.editNotes(id, text: "Earlier", captureTime: 2)
        let old = try XCTUnwrap(library.meeting(id)?.timedNotes?.first)

        // Another note arrives while the review is open; append to the current value, not the one at opening.
        library.editNotes(id, text: "Earlier\nArrived later")
        await library.flush()
        let current = try XCTUnwrap(library.meeting(id)?.notes)
        let updated = try XCTUnwrap(HandwritingNotes.appending("One\nTwo", to: current))
        library.editNotes(id, text: updated)

        let meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(meeting.notes, "Earlier\nArrived later\nOne\nTwo")
        XCTAssertEqual(meeting.timedNotes?.map(\.text), ["Earlier", "Arrived later", "One", "Two"])
        XCTAssertEqual(meeting.timedNotes?.map(\.time), [2, nil, nil, nil])
        XCTAssertEqual(meeting.timedNotes?.first?.id, old.id)
        await library.flush()
        let revision = try XCTUnwrap(library.meeting(id)?.revisions.last)
        XCTAssertEqual(revision.field, "notes")
        XCTAssertEqual(revision.oldValue, current)
        XCTAssertEqual(revision.newValue, updated)
        let reopened = LibraryController(rootURL: library.rootURL, sync: nil)
        try await reopened.load()
        XCTAssertEqual(reopened.meeting(id)?.notes, updated)
    }

    func testReviewedParagraphsUseTheRecordingTimeAndAreJournaled() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Notes")
        rig.pump(2)
        rig.recorder.editNotes("Earlier")
        let old = try XCTUnwrap(rig.recorder.timedNotes.first)
        rig.pump(3)

        let updated = try XCTUnwrap(HandwritingNotes.appending("One\nTwo", to: rig.recorder.notes))
        rig.recorder.editNotes(updated)
        XCTAssertEqual(rig.recorder.notes, "Earlier\nOne\nTwo")
        XCTAssertEqual(rig.recorder.timedNotes.map(\.text), ["Earlier", "One", "Two"])
        XCTAssertEqual(rig.recorder.timedNotes.map(\.time), [2, 5, 5])
        XCTAssertEqual(rig.recorder.timedNotes.first?.id, old.id)

        await rig.recorder.flush()
        let journal = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(journal.notes, rig.recorder.notes)
        XCTAssertEqual(journal.timedNotes.map(\.time), [2, 5, 5])
        _ = try await rig.stop()
    }

    func testPostStopHandwritingSuspendsAndRestartsTheTenSecondLinger() async throws {
        let linger = AfterStopLinger()
        var didDismiss = false
        linger.update(stay: AfterStop.lingers, writing: false) { didDismiss = true }
        try await Task.sleep(for: .milliseconds(100))

        linger.update(stay: AfterStop.lingers, writing: true) { didDismiss = true }
        try await Task.sleep(for: AfterStop.lingers + .milliseconds(100))
        XCTAssertFalse(
            didDismiss, "the handwriting draft must outlive the normal ten-second linger")

        linger.update(stay: .milliseconds(20), writing: false) { didDismiss = true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(didDismiss, "closing the sheet restarts the linger")
    }

}
