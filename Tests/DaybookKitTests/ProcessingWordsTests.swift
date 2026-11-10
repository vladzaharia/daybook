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

    /// Model downloads in one phrase over the whole set, everywhere (uxf-06, uxf-12): its figure and total, waiting for
    /// Wi‑Fi in the words a model's row uses, and a download that stopped, by the model's name.
    func testBehaviorModelDownloadsReadAsOneSet() {
        let arriving = ModelDownloadState.downloading(done: 3_800_000_000, total: 7_600_000_000)
        XCTAssertEqual(ProcessingWords.modelDownloadLine(arriving), "Downloading models · 50%")
        XCTAssertEqual(ProcessingWords.modelDownloadDetail(arriving), "3.8 of 7.6 GB")
        XCTAssertEqual(ProcessingWords.modelDownloadShort(arriving), "50%")
        XCTAssertEqual(arriving.fraction, 0.5)
        XCTAssertEqual(arriving.bytes, 3_800_000_000, "what's left")
        XCTAssertFalse(arriving.needsAttention)
        XCTAssertEqual(ProcessingWords.downloadingModels(0.999), "Downloading models · 99%", "100% only when it's done")
        XCTAssertEqual(ModelDownloadState.downloading(done: 0, total: 0).fraction, 0)

        let waiting = ModelDownloadState.waitingForWiFi(bytes: 852_000_000)
        XCTAssertEqual(ProcessingWords.modelDownloadLine(waiting), "Downloading models · \(ModelStatus.waitingForWiFi.label)")
        XCTAssertEqual(ProcessingWords.modelDownloadLine(waiting), "Downloading models · Waiting for Wi‑Fi")
        XCTAssertEqual(ProcessingWords.modelDownloadDetail(waiting), "852 MB")
        XCTAssertNil(waiting.fraction)

        let failed = ModelDownloadState.failed(model: "Gemma 4 12B 4-bit", bytes: 7_600_000_000)
        XCTAssertEqual(ProcessingWords.modelDownloadLine(failed), "Couldn’t download Gemma 4 12B 4-bit")
        XCTAssertTrue(failed.needsAttention)
        XCTAssertEqual(ProcessingWords.downloadStopped, "Couldn’t download")

        XCTAssertEqual(ProcessingWords.download(900_000_000), "Download · 900 MB")
        XCTAssertEqual(ProcessingWords.download(0), "Download")
    }

    /// Transcript first (uxf-01): a summary waiting for the summary model, in the queue's words for a wait behind the
    /// download, with the whole set's figure while it arrives, else the download's own line.
    func testBehaviorASummaryWaitingForTheSummaryModelSaysTheDownload() {
        XCTAssertEqual(ProcessingWords.summaryWaitsForDownload(), ProcessingWords.waitingHere(.summaryOnly, behind: .download))
        XCTAssertEqual(ProcessingWords.summaryWaitsForDownload(fraction: 0.385), "Waiting to summarize after the download · 38%")
        XCTAssertEqual(ProcessingWords.summaryWaitsForDownload(summarized: true), "Waiting to summarize again after the download")
        XCTAssertEqual(ProcessingWords.phrase(ProcessingWords.summaryWaitsForDownload(fraction: 0.4)), "Waiting to summarize after the download")
        XCTAssertEqual(ProcessingWords.summaryWaitsLine(.downloading(done: 385, total: 1_000)), "Waiting to summarize after the download · 38%")
        XCTAssertEqual(ProcessingWords.summaryWaitsLine(.waitingForWiFi(bytes: 6_770_000_000)), "Downloading models · Waiting for Wi‑Fi")
        XCTAssertEqual(ProcessingWords.summaryWaitsLine(.failed(model: "Gemma 4 12B 4-bit", bytes: 1)), "Couldn’t download Gemma 4 12B 4-bit")
        XCTAssertEqual(ProcessingWords.waitingHereShort(.summaryOnly), "Waiting to summarize")
        XCTAssertEqual(ProcessingWords.waitingHereShort(.summaryOnly, summarized: true), "Waiting to summarize again")
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
