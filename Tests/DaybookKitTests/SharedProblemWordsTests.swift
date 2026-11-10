import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The words both apps show for something that couldn't be done (`ProblemWords`): Daybook's own sentences
/// (`PlainSentenceError`) as they are, the system's behind Details with a sentence of Daybook's in front.
final class SharedProblemWordsTests: XCTestCase {
    private struct StepFailed: PlainSentenceError, LocalizedError {
        var errorDescription: String? { "Recording couldn’t continue. Everything up to then is saved." }
        var plainDetails: String? { "The audio encoder stopped (convert)." }
    }

    func testBehaviorDaybooksOwnSentencesAreTheMessage() {
        let refused = ProblemWords(title: "Couldn’t Start Over", fallback: "Try again.", error: LibrarySyncError.keyAvailable)
        XCTAssertEqual(refused.title, "Couldn’t Start Over")
        XCTAssertEqual(refused.message, "One of your devices has this library’s key. Get the key from it instead.")
        XCTAssertNil(refused.details)
        XCTAssertEqual(ProblemWords(fallback: "Try again.", error: AudioFetchError.keyUnavailable).message,
                       "This recording plays once this device has the library’s key.")
        XCTAssertEqual(ProblemWords(fallback: "Try again.", error: DaybookError.libraryUnavailable).message, "Your library is not available yet.")
        XCTAssertEqual(ProblemWords(fallback: "Try again.", error: LibraryError.trashedMeeting(UUID())).message,
                       "This conversation is in the Trash. Restore it to edit it.")
        XCTAssertEqual(ProblemWords(fallback: "Try again.", error: PhotoStoreError.unsupportedImage("a.tiff")).message,
                       "a.tiff isn’t a HEIC, JPEG, or PNG image.")
        let stopped = ProblemWords(fallback: "Try again.", error: StepFailed())
        XCTAssertEqual(stopped.message, "Recording couldn’t continue. Everything up to then is saved.")
        XCTAssertEqual(stopped.details, "The audio encoder stopped (convert).", "an app's own error keeps its step for Details")
    }

    func testBehaviorTheSystemsWordsGoBehindDetails() {
        let system = ProblemWords(title: "Couldn’t Import Audio", fallback: "Choose an audio or video file and try again.",
                                  error: CocoaError(.fileReadCorruptFile))
        XCTAssertEqual(system.message, "Choose an audio or video file and try again.")
        XCTAssertEqual(system.details, CocoaError(.fileReadCorruptFile).localizedDescription)

        // A kind that sometimes carries them says so: a file's name, a download's reason, a save's.
        let damaged = ProblemWords(fallback: "Try again.", error: LibrarySyncError.invalidEvent("abc.json"))
        XCTAssertEqual(damaged.message, "Try again.")
        XCTAssertEqual(damaged.details, LibrarySyncError.invalidEvent("abc.json").localizedDescription)
        XCTAssertEqual(ProblemWords(fallback: "Try again.", error: AudioFetchError.downloadFailed("The network connection was lost.")).message,
                       "Try again.")
        let save = ProblemWords(fallback: "Try again.", error: DaybookError.saveFailed("disk full (28)"))
        XCTAssertEqual(save.message, "Try again.")
        XCTAssertEqual(save.details, "disk full (28)", "a save's own reason, not the sentence around it")
    }

    func testBehaviorDetailsThatSayNothingNewAreLeftOut() {
        XCTAssertEqual(ProblemWords(fallback: "Try again.", error: nil), ProblemWords(title: "", message: "Try again."))
        XCTAssertNil(ProblemWords(title: "", message: "No audio was recorded.", details: "No audio was recorded.").details)
        XCTAssertNil(ProblemWords(title: "", message: "Recording stopped.", details: "").details)
    }
}
