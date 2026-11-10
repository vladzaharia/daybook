#if DEBUG
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// What a conversation's status offers is carried out once for both apps (`ConversationStatusActionHandler`): the
/// library's half here (Transcribe, Summarize, and Try Again through the app's own processing; Cancel on this device's
/// request, Don’t Wait and Wait Again with Edit › Undo, and Dismiss), and every other action handed to the app as it came.
@MainActor
final class ConversationStatusActionHandlerTests: XCTestCase {
    /// An app that notes what it was asked to do.
    private final class App: ConversationStatusActionHandler {
        let library: LibraryController
        let undoManager: UndoManager?
        var processed: [ProcessingRequest.Mode] = []
        var here: [ConversationStatusPresentation.Action] = []

        init(library: LibraryController, undoManager: UndoManager?) {
            self.library = library
            self.undoManager = undoManager
        }

        func process(_ id: UUID, _ mode: ProcessingRequest.Mode) { processed.append(mode) }
        func performHere(_ action: ConversationStatusPresentation.Action, on id: UUID) { here.append(action) }
    }

    private func demo() async throws -> LibraryController {
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookStatusActions"), sync: nil)
        try await library.load()
        await ReadingDemo.seed(library, as: .iPhone) { _, _, _, _ in }?.value
        return library
    }

    private func id(_ title: String, in library: LibraryController) throws -> UUID {
        try XCTUnwrap(library.meetings.first { $0.title == title }?.id, title)
    }

    func testBehaviorWorkGoesThroughTheAppsProcessingAndItsOwnActionsToTheApp() async throws {
        let library = try await demo()
        let app = App(library: library, undoManager: nil)
        let id = try id(ReadingDemo.Title.recorded, in: library)
        app.perform(.transcribe(newAudio: false), on: id)
        app.perform(.transcribe(newAudio: true), on: id)
        app.perform(.summarize, on: id)
        app.perform(.tryAgain(.summaryOnly), on: id)
        app.perform(.tryAgain(.newAudio), on: id)
        XCTAssertEqual(app.processed, [.newAudio, .newAudio, .summaryOnly, .summaryOnly, .newAudio])
        XCTAssertTrue(app.here.isEmpty)

        let own: [ConversationStatusPresentation.Action] = [
            .details("The model stopped."), .pause, .resume, .cancel, .cancelDownload, .downloadModels(bytes: 1),
            .downloadSummaryModel(bytes: 2), .chooseModels, .cloudSettings, .summarizeHere("This Mac"), .useYourMac,
            .placement(.useCloud), .stopSummary,
        ]
        for action in own { app.perform(action, on: id) }
        XCTAssertEqual(app.here, own, "each app's own, as they came")
        XCTAssertEqual(app.processed.count, 5, "Use Your Mac is each app's own")
    }

    func testBehaviorCancelTakesBackThisDevicesRequest() async throws {
        let library = try await demo()
        let app = App(library: library, undoManager: nil)
        let id = try id(ReadingDemo.Title.queued, in: library)
        guard case .requested(.device(let request)) = ProcessingStatus(try XCTUnwrap(library.meeting(id))) else {
            return XCTFail("this iPhone's request, waiting for a Mac")
        }
        app.perform(.cancelRequest(request.id), on: id)
        XCTAssertEqual(ProcessingStatus(try XCTUnwrap(library.meeting(id))), .recorded, "taken back: Transcribe again")
        XCTAssertTrue(app.here.isEmpty)
    }

    func testBehaviorDontWaitIsUndoneAndDismissClearsTheNote() async throws {
        let library = try await demo()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let app = App(library: library, undoManager: undo)
        let awaiting = try id(ReadingDemo.Title.awaiting, in: library)
        func status() throws -> ProcessingStatus { ProcessingStatus(try XCTUnwrap(library.meeting(awaiting))) }
        guard case .awaitingRecordings = try status() else { return XCTFail("waiting for Soundcore Work's audio") }
        undo.beginUndoGrouping()
        app.perform(.dontWait, on: awaiting)
        undo.endUndoGrouping()
        XCTAssertEqual(try status(), .done, "finished with what's here")
        undo.undo()
        guard case .awaitingRecordings = try status() else { return XCTFail("Edit › Undo waits again") }

        var noted = try XCTUnwrap(library.meeting(try id(ReadingDemo.Title.ready, in: library)))
        library.update(noted.id) { $0.errorMessage = "Speakers were left as they were." }
        noted = try XCTUnwrap(library.meeting(noted.id))
        XCTAssertEqual(ConversationStatusPresentation.page(ProcessingStatus(noted), meeting: noted,
                                                           inputs: .init(words: .iPhone(id: library.thisDevice.id), local: .iPhone()))?.actions,
                       [.dismiss])
        app.perform(.dismiss, on: noted.id)
        XCTAssertNil(library.meeting(noted.id)?.errorMessage)
        XCTAssertTrue(app.here.isEmpty)
    }
}
#endif
