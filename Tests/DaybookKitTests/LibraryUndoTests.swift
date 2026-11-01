import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// An edit made with an undo manager can be taken back: what it changed goes back field by field, what changed
/// meanwhile stays, Version History keeps both, and the undo is a newer change of its own.
@MainActor
final class LibraryUndoTests: XCTestCase {
    private func open() async throws -> LibraryController {
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookUndo"), sync: nil)
        try await library.load()
        return library
    }

    func testBehaviorUndoPutsBackWhatTheChangeReplacedAndRedoAppliesItAgain() async throws {
        let library = try await open()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let id = library.newMeeting(title: "Roadmap review")
        let folder = library.createFolder(named: "Clients")
        let before = try XCTUnwrap(library.meeting(id))

        undo.beginUndoGrouping()
        XCTAssertTrue(library.update(id, actionName: "Move to Folder", undoManager: undo) { $0.folderID = folder; $0.placement = .work })
        undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Move to Folder")
        let moved = try XCTUnwrap(library.meeting(id))

        // Something else changed meanwhile: a sync, a summary.
        library.update(id) { $0.tags = ["q3"] }

        undo.undo()
        let undone = try XCTUnwrap(library.meeting(id))
        XCTAssertNil(undone.folderID)
        XCTAssertNil(undone.placement)
        XCTAssertEqual(undone.tags, ["q3"], "what the change didn't touch stays")
        XCTAssertGreaterThan(undone.updatedAt, moved.updatedAt, "the undo is a change of its own")
        XCTAssertGreaterThanOrEqual(undone.updatedAt, before.updatedAt)

        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(library.meeting(id)?.folderID, folder)
        XCTAssertEqual(library.meeting(id)?.placement, .work)
        XCTAssertEqual(library.meeting(id)?.tags, ["q3"])
    }

    func testBehaviorVersionHistoryKeepsTheChangeAndItsUndo() async throws {
        let library = try await open()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let id = library.newMeeting(title: "Standup")
        library.update(id) { $0.setNotes("First draft") }
        undo.beginUndoGrouping()
        library.update(id, actionName: "Typing", undoManager: undo) { $0.setNotes("Second draft") }
        undo.endUndoGrouping()
        undo.undo()
        let meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(meeting.notes, "First draft")
        XCTAssertEqual(meeting.revisions.suffix(2).map { "\($0.oldValue) → \($0.newValue)" }, ["First draft → Second draft", "Second draft → First draft"],
                       "nothing is lost from Version History")
    }

    func testBehaviorNothingChangedRegistersNothing() async throws {
        let library = try await open()
        let undo = UndoManager()
        let id = library.newMeeting(title: "Standup")
        XCTAssertFalse(library.update(id, actionName: "Rename", undoManager: undo) { $0.title = "Standup" })
        XCTAssertFalse(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "")
        XCTAssertFalse(library.update(UUID(), actionName: "Rename", undoManager: undo) { $0.title = "Gone" })
        // Without an undo manager it's an ordinary update.
        XCTAssertTrue(library.update(id, actionName: "Rename", undoManager: nil) { $0.title = "Daily standup" })
        XCTAssertEqual(library.meeting(id)?.title, "Daily standup")
    }
}
