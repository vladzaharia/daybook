import XCTest
@testable import DaybookCore

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

    func testWaitingForADownloadOrTheKeyIsTheWholeWarning() {
        XCTAssertEqual(SyncWarningWords.compose(SyncWarningWords.unreadHistory, SyncPendingDownload()), "Waiting for iCloud to download a change.")
        XCTAssertEqual(SyncWarningWords.compose(SyncWarningWords.unreadHistory, SyncKeyPending(keyID: "ab")), "Some changes are waiting for this library’s key.")
    }

    /// A pass that meets damaged entries and a changed recording says so in plain sentences; the entries' names and where
    /// the recording went are behind Details.
    func testAPassWithDamagedEntriesWarnsInPlainSentences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookWarningWords-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("iCloud")
        let a = try LibrarySyncEngine(localRoot: root.appendingPathComponent("A"), remoteRoot: remote, deviceID: "A")
        _ = try await a.synchronize(meetings: [Meeting(title: "Fine")])
        // An entry whose snapshot is of another conversation than it says.
        let other = Meeting(title: "Elsewhere")
        let event: [String: Any] = ["schemaVersion": 1, "meetingID": UUID().uuidString, "deviceID": "X", "sequence": 1, "parents": [String](),
                                    "snapshot": try JSONSerialization.jsonObject(with: SyncEncoding.data(other)), "deleted": false, "assets": [Any]()]
        let bytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        try bytes.write(to: remote.appendingPathComponent("Events/\(SyncDigest.sha256(data: bytes)).json"))
        let result = try await a.synchronize(meetings: [])
        XCTAssertFalse(result.warnings.isEmpty)
        for warning in result.warnings {
            let words = SyncWarningWords.split(warning)
            XCTAssertFalse(words.text.contains(SyncDigest.sha256(data: bytes)), "a file name in the sentence: \(words.text)")
            XCTAssertTrue(words.text.hasSuffix("."), words.text)
        }
        XCTAssertTrue(result.warnings.map(SyncWarningWords.split).contains { $0.text == SyncWarningWords.damagedHistory + "." && $0.details != nil })
    }

    func testOtherWarningsAreNeverCutAtAColon() {
        let warning = "“Q4: launch” was deleted on another device after it changed here, so it’s kept as a new conversation."
        let words = SyncWarningWords.split(warning)
        XCTAssertEqual(words.text, warning)
        XCTAssertNil(words.details)
    }
}
