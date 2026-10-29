import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookPhone

/// What Settings and the recorder and Mac pages say: each thing once, in plain words.
@MainActor
final class SettingsWordsTests: XCTestCase {
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
