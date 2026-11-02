import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Undo for one item of a conversation (a bookmark, its label, a next step's tick, Don't Wait) takes back that item
/// alone: a bookmark added since, a summary written since, or a link's recording that arrived since stays, on every
/// device, because the undo writes only the item.
@MainActor
final class LibraryItemUndoTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func open() async throws -> (LibraryController, UndoManager) {
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookItemUndo"), sync: nil)
        try await library.load()
        let undo = UndoManager()
        undo.groupsByEvent = false
        return (library, undo)
    }

    /// One undoable step, as a menu command or a click is.
    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    func testBehaviorUndoingADeleteKeepsABookmarkAddedSince() async throws {
        let (library, undo) = try await open()
        let id = library.newMeeting(title: "Standup")
        let a = UUID(), b = UUID()
        library.addBookmark(id: a, in: id, at: 12)
        library.setBookmarkText(a, text: "Pricing", in: id)
        let kept = try XCTUnwrap(library.meeting(id)?.highlights.first)

        step(undo) { library.removeBookmark(a, in: id, undoManager: undo) }
        XCTAssertEqual(undo.undoActionName, "Delete Bookmark")
        XCTAssertEqual(library.meeting(id)?.highlights.map(\.id), [])
        // Bookmark while recording, or one synced from the iPhone.
        library.addBookmark(id: b, in: id, at: 40)
        let deleted = try XCTUnwrap(library.meeting(id))

        undo.undo()
        let undone = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(Set(undone.highlights.map(\.id)), [a, b], "both remain")
        XCTAssertEqual(undone.highlights.first(where: { $0.id == a }), kept, "put back as it was")
        XCTAssertGreaterThan(undone.updatedAt, deleted.updatedAt, "the undo is a newer change, so it syncs")
        XCTAssertEqual(undo.redoActionName, "Delete Bookmark")

        undo.redo()
        XCTAssertEqual(library.meeting(id)?.highlights.map(\.id), [b])
        undo.undo()
        XCTAssertEqual(Set(library.meeting(id)?.highlights.map(\.id) ?? []), [a, b])
    }

    func testBehaviorUndoingADeleteWritesTheReverseOfItsHistory() async throws {
        let (library, undo) = try await open()
        let id = library.newMeeting(title: "Standup")
        let a = UUID()
        library.addBookmark(id: a, in: id, at: 12)
        let before = try XCTUnwrap(library.meeting(id)).revisions
        step(undo) { library.removeBookmark(a, in: id, undoManager: undo) }
        let written = Array(try XCTUnwrap(library.meeting(id)).revisions.dropFirst(before.count))
        undo.undo()
        let history = try XCTUnwrap(library.meeting(id)).revisions
        XCTAssertEqual(Array(history.prefix(before.count + written.count)), before + written, "nothing is lost from Version History")
        XCTAssertEqual(history.dropFirst(before.count + written.count).map { "\($0.field): \($0.oldValue) → \($0.newValue)" },
                       written.reversed().map { "\($0.field): \($0.newValue) → \($0.oldValue)" }, "the undo is written beside it")
    }

    func testBehaviorAnUndoneDeleteOfABookmarkAlreadyBackDoesNothing() async throws {
        let (library, undo) = try await open()
        let id = library.newMeeting(title: "Standup")
        let a = UUID()
        library.addBookmark(id: a, in: id, at: 12)
        step(undo) { library.removeBookmark(a, in: id, undoManager: undo) }
        // The same bookmark came back from another device first.
        library.addBookmark(id: a, in: id, at: 12)
        let back = try XCTUnwrap(library.meeting(id))
        undo.undo()
        XCTAssertEqual(library.meeting(id), back)
        XCTAssertFalse(undo.canRedo)
    }

    func testBehaviorUndoingALabelSetsThatLabelBackAlone() async throws {
        let (library, undo) = try await open()
        let id = library.newMeeting(title: "Standup")
        let a = UUID(), b = UUID()
        library.addBookmark(id: a, in: id, at: 12)
        step(undo) { library.setBookmarkText(a, text: "Pricing", in: id, undoManager: undo) }
        XCTAssertEqual(undo.undoActionName, "Bookmark Label")
        library.addBookmark(id: b, in: id, at: 40)
        library.setBookmarkText(b, text: "Budget", in: id)

        undo.undo()
        XCTAssertEqual(library.meeting(id)?.highlights.map(\.text), ["", "Budget"])
        undo.redo()
        XCTAssertEqual(library.meeting(id)?.highlights.map(\.text), ["Pricing", "Budget"])

        // A label typed again elsewhere since stays.
        step(undo) { library.setBookmarkText(a, text: "Pricing, final", in: id, undoManager: undo) }
        library.setBookmarkText(a, text: "Pricing, from the iPhone", in: id)
        undo.undo()
        XCTAssertEqual(library.meeting(id)?.highlights.first?.text, "Pricing, from the iPhone")
    }

    func testBehaviorUndoingATickKeepsASummaryWrittenSince() async throws {
        let (library, undo) = try await open()
        let id = library.newMeeting(title: "Planning")
        let step1 = ActionItem(text: "Send the deck"), step2 = ActionItem(text: "Book the room")
        library.update(id) { $0.summary = MeetingSummary(overview: "Old", actionItems: [step1, step2], createdAt: self.now) }

        step(undo) { library.setNextStep(step1.id, done: true, in: id, undoManager: undo) }
        XCTAssertEqual(undo.undoActionName, "Mark as Done")
        library.update(id) { $0.summary?.actionItems[1].completed = true }
        undo.undo()
        XCTAssertEqual(library.meeting(id)?.summary?.actionItems.map(\.completed), [false, true], "the other tick stays")
        XCTAssertEqual(undo.redoActionName, "Mark as Done")
        undo.redo()
        XCTAssertEqual(library.meeting(id)?.summary?.actionItems.map(\.completed), [true, true])

        // Summarize Again finishes, or a newer summary syncs in, before the undo.
        step(undo) { library.setNextStep(step2.id, done: false, in: id, undoManager: undo) }
        XCTAssertEqual(undo.undoActionName, "Mark as Not Done")
        let newer = MeetingSummary(overview: "New summary", actionItems: [ActionItem(text: "Send the deck")], createdAt: now.addingTimeInterval(60))
        library.update(id) { $0.summary = newer }
        let summarized = try XCTUnwrap(library.meeting(id))
        undo.undo()
        XCTAssertEqual(library.meeting(id)?.summary, newer, "the newer summary stays as it came")
        XCTAssertEqual(library.meeting(id), summarized)
    }

    func testBehaviorUndoingDontWaitKeepsWhatTheLinksSaidSince() async throws {
        let (library, undo) = try await open()
        let id = library.newMeeting(title: "Design review")
        let started = Date().addingTimeInterval(-600)
        func link(_ name: String, recordingID: String) -> CompanionRecording {
            var link = CompanionRecording(deviceID: name, deviceKind: DaybookPhoneIntegration.id, deviceSerial: name, deviceName: name,
                                          macStartedAt: started, state: .stopped, startedByDaybook: true)
            link.macEndedAt = started.addingTimeInterval(540)
            link.recordingID = recordingID
            return link
        }
        let phone = link("Alex's iPhone", recordingID: "rec-1"), other = link("Sam's iPhone", recordingID: "rec-2")
        library.update(id) { $0.companions = [phone, other] }
        XCTAssertEqual(library.meeting(id)?.awaitedLinks(), [phone.id, other.id])

        step(undo) { library.stopWaitingForRecordings(in: id, undoManager: undo) }
        XCTAssertEqual(undo.undoActionName, "Don’t Wait")
        XCTAssertEqual(library.meeting(id)?.awaitedRecordings(), [])
        // Sam's recording arrived and was added meanwhile: its link names its track.
        let track = UUID()
        library.update(id) { meeting in
            meeting.companions?[1].state = .attached
            meeting.companions?[1].trackID = track
        }

        undo.undo()
        let undone = try XCTUnwrap(library.meeting(id)?.companions)
        XCTAssertEqual(undone.map(\.stoppedWaitingAt), [nil, nil], "waited for again")
        XCTAssertEqual(undone[1].trackID, track, "the link that arrived keeps its recording")
        XCTAssertEqual(undone[1].state, .attached)
        XCTAssertEqual(library.meeting(id)?.awaitedRecordings().map(\.deviceName), ["Alex's iPhone"])

        undo.redo()
        XCTAssertEqual(library.meeting(id)?.awaitedRecordings(), [])
        XCTAssertEqual(library.meeting(id)?.companions?[1].trackID, track)
    }

    func testBehaviorNothingToUndoRegistersNothing() async throws {
        let (library, undo) = try await open()
        let id = library.newMeeting(title: "Standup")
        library.removeBookmark(UUID(), in: id, undoManager: undo)
        library.setNextStep(UUID(), done: true, in: id, undoManager: undo)
        library.stopWaitingForRecordings(in: id, undoManager: undo)
        let a = UUID()
        library.addBookmark(id: a, in: id, at: 3)
        library.setBookmarkText(a, text: "", in: id, undoManager: undo)
        XCTAssertFalse(undo.canUndo)
        // Without an undo manager each is an ordinary edit.
        library.removeBookmark(a, in: id, undoManager: nil)
        XCTAssertEqual(library.meeting(id)?.highlights, [])
    }
}
