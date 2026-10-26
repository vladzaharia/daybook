import DaybookCore
import XCTest

/// A sync pass's warnings: one plain sentence, the system's words for Details.
final class SyncWarningWordsTests: XCTestCase {
    func testASystemErrorBecomesAPlainSentenceWithItsWordsForDetails() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [NSLocalizedDescriptionKey: "The file “x” couldn’t be opened."])
        let warning = SyncWarningWords.compose(SyncWarningWords.unreadHistory, error)
        let words = SyncWarningWords.split(warning)
        XCTAssertEqual(words.text, "Part of the library’s history couldn’t be read yet.")
        XCTAssertEqual(words.details, "The file “x” couldn’t be opened.")
    }

    func testDaybooksOwnSentencesAreTheWholeWarning() {
        let error = LibrarySyncError.keyUnavailable("abc")
        XCTAssertTrue(error.isPlainSentence)
        XCTAssertEqual(SyncWarningWords.compose(SyncWarningWords.unsavedChange, error), error.localizedDescription)
    }

    func testOtherWarningsAreNeverCutAtAColon() {
        let warning = "“Q4: launch” was deleted on another device after it changed here, so it’s kept as a new conversation."
        let words = SyncWarningWords.split(warning)
        XCTAssertEqual(words.text, warning)
        XCTAssertNil(words.details)
    }
}
