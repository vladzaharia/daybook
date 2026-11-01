import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// One set of words for what processing is doing, so the list, the page, Floating Notes, and a phone never
/// disagree about the same moment.
final class ProcessingWordsTests: XCTestCase {
    func testBehaviorEachStepHasOneVerb() {
        XCTAssertEqual(ProcessingWords.verb(.transcribing), "Transcribing")
        XCTAssertEqual(ProcessingWords.verb(.identifyingSpeakers), "Identifying speakers")
        XCTAssertEqual(ProcessingWords.verb(.summarizing), "Summarizing")
    }

    func testBehaviorPercentsRoundDownSoOnlyDoneReadsAHundred() {
        XCTAssertEqual(ProcessingWords.percent(0.399), 39)
        XCTAssertEqual(ProcessingWords.percent(0.4), 40)
        XCTAssertEqual(ProcessingWords.percent(0.999), 99)
        XCTAssertEqual(ProcessingWords.percent(1), 100)
        XCTAssertEqual(ProcessingWords.percent(-0.2), 0)
        XCTAssertEqual(ProcessingWords.percent(1.7), 100)
        XCTAssertEqual(ProcessingWords.percent(.nan), 0)
    }

    func testBehaviorAProgressLineSaysTheStepAndItsFigure() {
        XCTAssertEqual(ProcessingWords.progressLine(.transcribing, fraction: 0.4), "Transcribing · 40%")
        XCTAssertEqual(ProcessingWords.progressLine(.identifyingSpeakers, fraction: 0.63), "Identifying speakers · 63%")
        XCTAssertEqual(ProcessingWords.progressLine(.summarizing, fraction: nil), "Summarizing…")
        XCTAssertEqual(ProcessingWords.elsewhere(.identifyingSpeakers, device: "Studio Mac", fraction: 0.4),
                       "Identifying speakers on Studio Mac · 40%")
        XCTAssertEqual(ProcessingWords.elsewhere(.summarizing, device: "this iPhone"), "Summarizing on this iPhone")
        XCTAssertEqual(ProcessingWords.phrase("Transcribing on Studio Mac · 40%"), "Transcribing on Studio Mac")
        XCTAssertEqual(ProcessingWords.phrase("Summarizing…"), "Summarizing")
    }

    func testBehaviorWaitingHereSaysWhatItWaitsFor() {
        XCTAssertEqual(ProcessingWords.waitingHere(behind: .conversation("Roadmap review")), "Waiting to transcribe after “Roadmap review”")
        XCTAssertEqual(ProcessingWords.waitingHere(behind: .download), "Waiting to transcribe after the download")
        XCTAssertEqual(ProcessingWords.waitingHere(.summaryOnly, behind: .position(ahead: 3)), "Waiting to summarize · 3 ahead")
        XCTAssertEqual(ProcessingWords.waitingHere(.speakerRefresh, behind: .nothing), "Waiting to identify speakers again")
        XCTAssertEqual(ProcessingWords.waitingHereShort(), "Waiting to transcribe")
    }

    func testBehaviorARequestWaitingForAMacSaysWhatItAsked() {
        XCTAssertEqual(ProcessingWords.waitingForMac(.newAudio), "Waiting for your Mac")
        XCTAssertEqual(ProcessingWords.waitingForMac(.newAudio, device: "Studio Mac"), "Waiting for Studio Mac")
        XCTAssertEqual(ProcessingWords.waitingForMac(.summaryOnly), "Waiting for your Mac to summarize")
        XCTAssertEqual(ProcessingWords.waitingForMac(.summaryOnly, summarized: true), "Waiting for your Mac to summarize again")
        XCTAssertEqual(ProcessingWords.waitingForMac(.speakerRefresh), "Waiting for your Mac to identify speakers again")
        XCTAssertEqual(ProcessingWords.waitingForMac(.fullRetranscription), "Waiting for your Mac to transcribe everything again")
        XCTAssertEqual(ProcessingWords.title(.fullRetranscription), "Transcribe Everything Again")
    }

    func testBehaviorAPauseSaysWhenItGoesOn() {
        XCTAssertEqual(ProcessingWords.pausedLine(.recording), "Continues after the recording")
        XCTAssertEqual(ProcessingWords.pausedLine(.background), "Continues when Daybook is open")
        XCTAssertEqual(ProcessingWords.pausedLine(.heat), "Continues when iPhone cools down")
        XCTAssertEqual(ProcessingWords.pausedLine(.lowPowerMode), "Continues when Low Power Mode is off")
        XCTAssertEqual(ProcessingWords.pausedLine(.lowBattery, device: "iPhone"), "Continues when iPhone is charging")
        XCTAssertNil(ProcessingWords.pausedLine(.person), "Resume says it")
    }

    func testBehaviorDeviceWordsTellThisDeviceFromAnother() {
        let mac = DeviceWords.mac(id: "m"), phone = DeviceWords.iPhone(id: "p")
        let studio = ProcessingRequest.Device(id: "s", name: "Studio Mac")
        XCTAssertEqual(mac.name(of: ProcessingRequest.Device(id: "m", name: "Vlad’s MacBook Pro")), "this Mac")
        XCTAssertEqual(mac.name(of: studio), "Studio Mac")
        XCTAssertEqual(mac.name(of: nil), "this Mac")
        XCTAssertEqual(phone.name(of: nil), "your Mac")
        XCTAssertTrue(mac.isHere(nil), "a Mac's own work has no device named")
        XCTAssertFalse(phone.isHere(nil))
        XCTAssertEqual(phone.hereTitle, "This iPhone")
        let upgrade = ProcessingRequest.Upgrade(role: "transcription", model: "parakeet/ultra", quality: 90, device: studio)
        XCTAssertEqual(upgrade.shortLine, "Waiting for Studio Mac")
    }
}
