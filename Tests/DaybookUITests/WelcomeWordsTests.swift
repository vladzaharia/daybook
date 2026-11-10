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
        // Asked for and waiting for Wi‑Fi on cellular: the transcript waits for it too (uxf-17).
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: true, canTranscribe: false, waitsForWiFi: true),
                       "Start a conversation now. It’s transcribed once the models download on Wi‑Fi.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: false, canTranscribe: true), "Start a conversation now.")
        // The Mac transcribes as soon as what transcribes is here, and summarizes once the rest arrives (uxf-01).
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: true, canTranscribe: false, transcriptFirst: true),
                       "Start a conversation now. It’s transcribed in minutes.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: true, canTranscribe: false, waitsForWiFi: true, transcriptFirst: true),
                       "Start a conversation now. It’s transcribed once the models download on Wi‑Fi.")
        // It transcribes now (its models are here, or the system's speech model stands in while they download): nothing
        // more to say, on either device.
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: true, canTranscribe: true, transcriptFirst: true), "Start a conversation now.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: true, canTranscribe: true), "Start a conversation now.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: true, canTranscribe: true, waitsForWiFi: true), "Start a conversation now.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: false, canTranscribe: false, transcribesElsewhere: true),
                       "Start a conversation now. Your Mac transcribes it.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: false, canTranscribe: false),
                       "Start a conversation now. Download models in Settings to transcribe it.")
        XCTAssertEqual(WelcomeWords.downloading("Balanced"), "Downloading Balanced models")
        XCTAssertEqual(WelcomeWords.downloading(nil), "Downloading models")
        XCTAssertEqual(WelcomeWords.needsSpace("1.2 GB", free: "800 MB"), "Needs 1.2 GB · 800 MB free")
        XCTAssertEqual(WelcomeWords.page(2, of: 4), "Page 2 of 4")
    }

    /// Welcome promises a summary only where one will be made (P3, uxf-09): with neither a summary model this iPhone
    /// can run nor a Mac known to the library, the reading line is for transcripts and search, and nothing else changes.
    func testBehaviorTheIntroPromisesASummaryOnlyWhereOneWillBeMade() {
        let promised = WelcomeWords.points(.iPhone), bare = WelcomeWords.points(.iPhone, summaries: false)
        XCTAssertEqual(promised[1].text, "Read a short summary. Search every word.")
        XCTAssertEqual(bare[1].text, "Read the transcript. Search every word.")
        XCTAssertEqual(bare.map(\.symbol), promised.map(\.symbol))
        XCTAssertEqual(bare.enumerated().filter { $0.offset != 1 }.map(\.element), promised.enumerated().filter { $0.offset != 1 }.map(\.element))
        XCTAssertEqual(WelcomeWords.points(.mac), WelcomeWords.points(.mac, summaries: true), "a Mac summarizes")
    }

    /// Where this iPhone won't summarize, the Ready line says what will: a Mac known to the library, or nothing.
    func testBehaviorTheReadyLineSaysWhatSummarizesWhenThisIPhoneWont() {
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: true, canTranscribe: false, summarizesElsewhere: true),
                       "Start a conversation now. It’s transcribed once the models download. Your Mac summarizes it.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: true, canTranscribe: false, waitsForWiFi: true, summarizesElsewhere: true),
                       "Start a conversation now. It’s transcribed once the models download on Wi‑Fi. Your Mac summarizes it.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: false, canTranscribe: true, summarizesElsewhere: true),
                       "Start a conversation now. Your Mac summarizes it.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: false, canTranscribe: false, transcribesElsewhere: true, summarizesElsewhere: true),
                       "Start a conversation now. Your Mac transcribes and summarizes it.")
        XCTAssertEqual(WelcomeWords.readyMessage(downloading: false, canTranscribe: true), "Start a conversation now.",
                       "no Mac, and this iPhone won't: nothing about a summary")
    }

    func testBehaviorTheIPhonesModelsPageNamesEachRowAndTheTotal() {
        XCTAssertEqual(WelcomeWords.phoneModelsRow, "Transcription and speakers")
        XCTAssertEqual(WelcomeWords.phoneSummariesRow, "Summaries")
        XCTAssertEqual(WelcomeWords.downloadAndContinue("4.4 GB"), "Download 4.4 GB and Continue")
        XCTAssertEqual(WelcomeWords.downloadAndContinue, "Download and Continue", "one row: its size is on the row")
    }

    /// The iPhone's pages say what its own models and pairing do. A Mac transcribes this iPhone's recordings through
    /// the library they sync, paired or not, so neither page promises it.
    func testBehaviorTheIPhonesModelsAndPairPagesSayOnlyWhatTheyDo() {
        XCTAssertEqual(WelcomeWords.phoneModelsMessage, "Download models so this iPhone transcribes what it records.")
        XCTAssertEqual(WelcomeWords.pairMessage, "Start and stop recording on both at once.")
        for sentence in [WelcomeWords.phoneModelsMessage, WelcomeWords.pairMessage] {
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("your Mac transcribe"), sentence)
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("your Mac does"), sentence)
        }
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
