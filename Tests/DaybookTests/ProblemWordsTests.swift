import DaybookCore
import DaybookKit
import XCTest
@testable import Daybook

/// The Mac's alerts and sync warnings: a title naming what couldn't be done, one plain sentence, and
/// the system's own words only behind Details.
@MainActor
final class ProblemWordsTests: XCTestCase {
    func testDaybooksOwnErrorsAreTheMessageAndTheSystemsGoBehindDetails() {
        let own = AppProblem(title: "Couldn’t Start Recording", fallback: "Try again.", error: RecordingError.microphoneDenied)
        XCTAssertEqual(own.message, "Allow Daybook to use the microphone in System Settings › Privacy & Security › Microphone.")
        XCTAssertNil(own.details)

        let system = AppProblem(title: "Couldn’t Import Audio", fallback: "Choose an audio or video file and try again.",
                                error: CocoaError(.fileReadCorruptFile))
        XCTAssertEqual(system.title, "Couldn’t Import Audio")
        XCTAssertEqual(system.message, "Choose an audio or video file and try again.")
        XCTAssertEqual(system.details, CocoaError(.fileReadCorruptFile).localizedDescription)

        let save = AppProblem(title: "Couldn’t Add the Recording", fallback: "Try again.", error: DaybookError.saveFailed("disk full (28)"))
        XCTAssertEqual(save.message, "Try again.")
        XCTAssertEqual(save.details, "disk full (28)")
    }

    func testReportedProblemsAndLibrarySaveFailuresShareTheWindowsAlert() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookProblemTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(libraryURL: root, defaults: makeTestDefaults())
        XCTAssertNil(state.shownProblem)
        state.report("Couldn’t Export", "Try again, or choose another folder.", CocoaError(.fileWriteNoPermission))
        XCTAssertEqual(state.shownProblem?.title, "Couldn’t Export")
        XCTAssertEqual(state.errorMessage, "Try again, or choose another folder.", "tests and callers still read the sentence")
        state.dismissProblem()
        XCTAssertNil(state.shownProblem)

        state.library.errorMessage = "Changes to “Standup” couldn’t be saved. Daybook tries again with your next change."
        state.library.errorDetails = "The file couldn’t be saved."
        XCTAssertEqual(state.shownProblem?.title, "Couldn’t Save Changes")
        XCTAssertEqual(state.shownProblem?.details, "The file couldn’t be saved.")
        state.dismissProblem()
        XCTAssertNil(state.library.errorMessage)
        XCTAssertNil(state.library.errorDetails)
    }

    func testASyncProblemIsASentenceWithItsReasonForDetails() {
        let paused = SyncProblemWords.split("Sync paused: The operation couldn’t be completed. (NSPOSIXErrorDomain error 28.)")
        XCTAssertEqual(paused.text, "Sync is paused.")
        XCTAssertEqual(paused.details, "The operation couldn’t be completed. (NSPOSIXErrorDomain error 28.)")
        let open = SyncProblemWords.split("Couldn’t open iCloud: not signed in")
        XCTAssertEqual(open.text, "Couldn’t open iCloud.")
        XCTAssertEqual(open.details, "not signed in")
        XCTAssertEqual(SyncProblemWords.split("Apple Account needs attention").text, "Apple Account needs attention")
        XCTAssertNil(SyncProblemWords.split("Apple Account needs attention").details)
    }
}
