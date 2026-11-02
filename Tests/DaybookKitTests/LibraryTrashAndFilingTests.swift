import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// The Trash both apps list (with Restore), and filing that Edit › Undo takes back.
@MainActor
final class LibraryTrashAndFilingTests: XCTestCase {
    private func open() async throws -> LibraryController {
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookTrashFiling"), sync: nil)
        try await library.load()
        return library
    }

    /// An undo manager that groups by hand, as an event would.
    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    private func inOneEvent(_ undo: UndoManager, _ change: () -> Void) {
        undo.beginUndoGrouping()
        change()
        undo.endUndoGrouping()
    }

    // MARK: The Trash

    func testBehaviorTheTrashListsWhatWasMovedThereNewestFirstAndRestoreTakesItOut() async throws {
        let library = try await open()
        let old = library.newMeeting(title: "Old standup", date: Date(timeIntervalSinceNow: -86_400 * 3))
        let new = library.newMeeting(title: "Roadmap review", date: Date(timeIntervalSinceNow: -60))
        let kept = library.newMeeting(title: "Kept")
        var hasTrash = await library.hasTrashedMeetings()
        XCTAssertFalse(hasTrash)

        _ = try await library.moveToTrash(old)
        _ = try await library.moveToTrash(new)
        hasTrash = await library.hasTrashedMeetings()
        XCTAssertTrue(hasTrash)
        let trashed = await library.trashedMeetings()
        XCTAssertEqual(trashed.map(\.title), ["Roadmap review", "Old standup"], "newest first")
        XCTAssertFalse(trashed.contains { $0.id == kept })
        let one = await library.trashedMeeting(old)
        XCTAssertEqual(one?.title, "Old standup", "its last saved copy, for the page beside the list")

        try await library.restoreFromTrash(old)
        let after = await library.trashedMeetings()
        XCTAssertEqual(after.map(\.id), [new])
        XCTAssertNotNil(library.meeting(old), "back in the library")
        let gone = await library.trashedMeeting(old)
        XCTAssertNil(gone)
    }

    func testBehaviorATrashedConversationWithOnlyItsRecoveryCopyIsStillListed() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Torn")
        _ = try await library.moveToTrash(id)
        let folder = library.rootURL.appendingPathComponent("Trash/\(id.uuidString)", isDirectory: true)
        let main = folder.appendingPathComponent("meeting.json"), recovery = folder.appendingPathComponent("meeting.recovery.json")
        if !FileManager.default.fileExists(atPath: recovery.path) { try FileManager.default.copyItem(at: main, to: recovery) }
        try Data("{".utf8).write(to: main)
        let trashed = await library.trashedMeetings()
        XCTAssertEqual(trashed.map(\.title), ["Torn"])
    }

    func testBehaviorTheTrashPlaceListsNoneOfTheLibrarysConversations() {
        XCTAssertEqual(LibraryPlace.trash.meetings(in: [Meeting(title: "A")]), [])
        XCTAssertTrue(LibraryPlace.trash.isTrash)
        XCTAssertEqual(LibraryWords.emptyPlace(.trash, libraryIsEmpty: false, platform: .mac),
                       LibraryWords.EmptyPlace(title: "No Conversations", symbol: "trash"))
    }

    // MARK: Filing, undone

    func testBehaviorFilingSeveralIsOneUndoAndRedoFilesThemAgain() async throws {
        let library = try await open()
        let undo = undoManager()
        let a = library.newMeeting(title: "A"), b = library.newMeeting(title: "B")
        let clients = library.createFolder(named: "Clients")

        inOneEvent(undo) { library.moveToFolder([a, b], clients, undoManager: undo) }
        XCTAssertEqual(undo.undoActionName, "Move to Folder")
        XCTAssertEqual(library.meetings.filter { $0.folderID == clients }.count, 2)
        undo.undo()
        XCTAssertTrue(library.meetings.allSatisfy { $0.folderID == nil }, "one step takes both back")
        undo.redo()
        XCTAssertEqual(library.meetings.filter { $0.folderID == clients }.count, 2)

        inOneEvent(undo) { library.setPlacement([a], .personal, undoManager: undo) }
        XCTAssertEqual(undo.undoActionName, "Move to Personal")
        undo.undo()
        XCTAssertNil(library.meeting(a)?.placement)

        inOneEvent(undo) { library.setTags(b, text: "launch, Launch, beta", undoManager: undo) }
        XCTAssertEqual(library.meeting(b)?.tags, ["launch", "beta"])
        undo.undo()
        XCTAssertEqual(library.meeting(b)?.tags ?? [], [])
    }

    func testBehaviorUndoingADeletedFolderBringsItBackWithWhatWasInIt() async throws {
        let library = try await open()
        let undo = undoManager()
        let a = library.newMeeting(title: "A"), b = library.newMeeting(title: "B")
        let clients = library.createFolder(named: "Clients", moving: [a, b])
        let archive = library.createFolder(named: "Archive")

        inOneEvent(undo) { library.removeFolder(clients, undoManager: undo) }
        XCTAssertEqual(undo.undoActionName, "Delete Folder")
        XCTAssertFalse(library.folders.contains { $0.id == clients })
        XCTAssertNil(library.meeting(a)?.folderID)
        // Filed somewhere else meanwhile: undo leaves it there.
        library.moveToFolder([b], archive)

        undo.undo()
        XCTAssertEqual(library.folders.first { $0.id == clients }?.name, "Clients")
        XCTAssertEqual(library.meeting(a)?.folderID, clients)
        XCTAssertEqual(library.meeting(b)?.folderID, archive)
        undo.redo()
        XCTAssertFalse(library.folders.contains { $0.id == clients })
        XCTAssertNil(library.meeting(a)?.folderID)
    }

    func testBehaviorUndoingANewFolderPutsItsConversationsBackAndRemovesIt() async throws {
        let library = try await open()
        let undo = undoManager()
        let archive = library.createFolder(named: "Archive")
        let a = library.newMeeting(title: "A"), b = library.newMeeting(title: "B")
        library.moveToFolder([a], archive)

        var made: UUID?
        inOneEvent(undo) { made = library.createFolder(named: "Clients", moving: [a, b], undoManager: undo) }
        let clients = try XCTUnwrap(made)
        XCTAssertEqual(undo.undoActionName, "New Folder")
        XCTAssertEqual(library.meetings.filter { $0.folderID == clients }.count, 2)

        undo.undo()
        XCTAssertFalse(library.folders.contains { $0.id == clients })
        XCTAssertEqual(library.meeting(a)?.folderID, archive, "back where it was")
        XCTAssertNil(library.meeting(b)?.folderID)
        undo.redo()
        XCTAssertTrue(library.folders.contains { $0.id == clients })
        XCTAssertEqual(library.meetings.filter { $0.folderID == clients }.count, 2)
    }

    func testBehaviorUndoingARenameGivesTheFolderItsNameBack() async throws {
        let library = try await open()
        let undo = undoManager()
        let id = library.createFolder(named: "Clients")
        inOneEvent(undo) { library.renameFolder(id, to: "  Customers ", undoManager: undo) }
        XCTAssertEqual(library.folders.first?.name, "Customers")
        XCTAssertEqual(undo.undoActionName, "Rename Folder")
        undo.undo()
        XCTAssertEqual(library.folders.first?.name, "Clients")
        undo.redo()
        XCTAssertEqual(library.folders.first?.name, "Customers")
        inOneEvent(undo) { library.renameFolder(id, to: " ", undoManager: undo) }
        XCTAssertEqual(library.folders.first?.name, "Customers", "an empty name is no rename")
    }
}
