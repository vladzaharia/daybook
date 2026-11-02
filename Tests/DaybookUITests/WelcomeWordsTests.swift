import XCTest
@testable import DaybookUI

/// Welcome says the same thing on the Mac and the iPhone wherever the step is the same, and each device's own
/// words where it isn't.
final class WelcomeWordsTests: XCTestCase {
    func testBehaviorBothDevicesShareTheTaglineAndEveryPointButWhatTheyRecord() {
        XCTAssertEqual(WelcomeWords.tagline, "Your conversations, on your devices.")
        let mac = WelcomeWords.points(.mac), phone = WelcomeWords.points(.iPhone)
        XCTAssertEqual(mac.count, phone.count)
        XCTAssertEqual(Array(mac.dropFirst()), Array(phone.dropFirst()))
        XCTAssertEqual(mac[0].text, "Record calls, and conversations in the room.")
        XCTAssertEqual(phone[0].text, "Record conversations in the room, or with a recorder.")
        XCTAssertEqual(mac.map(\.symbol), phone.map(\.symbol))
    }

    func testBehaviorTheAllowStepUsesEachDevicesButtonWords() {
        XCTAssertEqual(WelcomeWords.allow(.mac), "Allow…", "Settings › General › Permissions' words")
        XCTAssertEqual(WelcomeWords.allow(.iPhone), "Allow")
        XCTAssertEqual(WelcomeWords.openSettings(.mac), "Open System Settings…")
        XCTAssertEqual(WelcomeWords.openSettings(.iPhone), "Open Settings")
        XCTAssertTrue(WelcomeWords.allowMessage(.mac).contains("Computer audio"))
        XCTAssertFalse(WelcomeWords.allowMessage(.iPhone).contains("Computer audio"), "The iPhone records no computer audio")
    }

    func testBehaviorTheReadyLineSaysWhatHappensToARecordingMadeNow() {
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: true, canTranscribe: false),
                       "Start a conversation now. It’s transcribed once the models download.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: false, canTranscribe: true), "Start a conversation now.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: false, canTranscribe: false, transcribesElsewhere: true),
                       "Start a conversation now. Your Mac transcribes it.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: false, canTranscribe: false),
                       "Start a conversation now. Download models in Settings to transcribe it.")
        XCTAssertEqual(WelcomeWords.downloading("Balanced"), "Downloading Balanced models")
        XCTAssertEqual(WelcomeWords.downloading(nil), "Downloading models")
        XCTAssertEqual(WelcomeWords.needsSpace("1.2 GB", free: "800 MB"), "Needs 1.2 GB · 800 MB free")
        XCTAssertEqual(WelcomeWords.page(2, of: 4), "Page 2 of 4")
    }

    /// Welcome may explain, but never in "not X, but Y" or with a dash aside.
    func testBehaviorNoWelcomeSentenceUsesADashAside() {
        let sentences = WelcomeWords.points(.mac).map(\.text) + WelcomeWords.points(.iPhone).map(\.text) + [
            WelcomeWords.tagline, WelcomeWords.qualityMessage, WelcomeWords.phoneModelsMessage, WelcomeWords.allowMessage(.mac),
            WelcomeWords.allowMessage(.iPhone), WelcomeWords.pairMessage, WelcomeWords.changeLater
        ]
        for sentence in sentences {
            XCTAssertFalse(sentence.contains("—"), sentence)
            XCTAssertFalse(sentence.contains(" -- "), sentence)
        }
    }
}
