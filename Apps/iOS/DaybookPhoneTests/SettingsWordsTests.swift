import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookPhone

/// What Settings and the recorder and Mac pages say: each thing once, in plain words.
@MainActor
final class SettingsWordsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Macs

    func testTheMacsFooterSaysOnlyWhatTheRowsDont() {
        let paired = ["Studio Mac"]
        XCTAssertNil(MacsSection.footer(.connected(name: "Studio Mac"), pairedNames: paired), "its row says it's connected")
        XCTAssertNil(MacsSection.footer(.seen(name: "Studio Mac", lastSeen: now), pairedNames: paired, now: now),
                     "a paired Mac is its row")
        XCTAssertNil(MacsSection.footer(.checking, pairedNames: paired), "no filler while checking")
        XCTAssertNil(MacsSection.footer(.unavailable("Sign in to iCloud to sync your library."), pairedNames: paired),
                     "iCloud's row says why")

        // A Mac that syncs the library but isn't paired here has no row, so the footer names it.
        XCTAssertEqual(MacsSection.footer(.seen(name: "Office iMac", lastSeen: now.addingTimeInterval(-7_200)),
                                          pairedNames: paired, now: now),
                       "Office iMac last synced 2 h ago.")
        // Something to do is always said.
        XCTAssertEqual(MacsSection.footer(.noMac, pairedNames: []), "No Mac has synced this library yet. Open Daybook on your Mac.")
        XCTAssertEqual(MacsSection.footer(.notProcessing(name: "Studio Mac", lastSeen: now), pairedNames: paired, now: now),
                       "Studio Mac isn’t set up to transcribe. Finish in Daybook › Settings on Studio Mac.")
    }

    // MARK: Storage

    func testStorageSaysWhatTheAudioIsWithoutRepeatingTheTotal() {
        XCTAssertNil(StorageScreen.breakdown(bytes: 0, downloaded: 0), "nothing to say")
        XCTAssertEqual(StorageScreen.breakdown(bytes: 400_000, downloaded: 0), "Recorded on this iPhone")
        XCTAssertEqual(StorageScreen.breakdown(bytes: 400_000, downloaded: 400_000), "Downloaded for playback")
        let both = StorageScreen.breakdown(bytes: 3_000_000, downloaded: 1_000_000)
        XCTAssertEqual(both, "\(StorageScreen.bytes(1_000_000)) downloaded · \(StorageScreen.bytes(2_000_000)) recorded on this iPhone")
        // A count that's briefly ahead of the total never goes negative.
        XCTAssertEqual(StorageScreen.breakdown(bytes: 100, downloaded: 200), "Downloaded for playback")
    }
}
