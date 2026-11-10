import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// This device's queue in one line, the same on a Mac and an iPhone: what runs, how far, what waits, and why it's
/// paused.
final class QueueStatusWordsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    typealias Queue = QueueStatusWords.Queue

    private func line(_ queue: Queue, _ words: DeviceWords = .mac()) -> StatusLineWords? {
        QueueStatusWords.line(queue, words: words, now: now)
    }

    func testBehaviorNoWorkSaysNothing() {
        XCTAssertNil(line(Queue()))
    }

    func testBehaviorTheRunningStepWithItsFigureAndWhatWaits() {
        let running = line(Queue(running: .transcribing, fraction: 0.4, waiting: 1))
        XCTAssertEqual(running?.title, "This Mac")
        XCTAssertEqual(running?.text, "Transcribing · 40% · 1 waiting")
        XCTAssertEqual(running?.shortText, "Transcribing · 40%")
        XCTAssertEqual(running?.progress, 0.4)
        XCTAssertEqual(running?.tone, .working)
        XCTAssertEqual(line(Queue(running: .identifyingSpeakers, fraction: 0.63), .iPhone())?.text, "Identifying speakers · 63%")
        XCTAssertEqual(line(Queue(running: .identifyingSpeakers, fraction: 0.63), .iPhone())?.title, "This iPhone")
        XCTAssertEqual(line(Queue(running: .identifyingSpeakers, fraction: 0.63), .iPhone())?.symbol, "iphone")
        XCTAssertEqual(line(Queue(running: .summarizing))?.text, "Summarizing…")
    }

    func testBehaviorASummarysCountdownAndTheCloud() {
        let countdown = line(Queue(running: .summarizing, countdown: now.addingTimeInterval(12), waiting: 2))
        XCTAssertEqual(countdown?.text, "Summarizing in 12 s · 2 waiting")
        XCTAssertEqual(countdown?.text(at: now.addingTimeInterval(3)), "Summarizing in 9 s · 2 waiting")
        XCTAssertEqual(countdown?.tone, .calm)
        XCTAssertEqual(line(Queue(running: .summarizing, cloudModel: "Claude Sonnet 5.5"))?.text, "Summarizing with Claude Sonnet 5.5")
    }

    func testBehaviorAPausedQueueSaysWhenItGoesOn() {
        let paused = line(Queue(waiting: 2, pause: .lowBattery), .iPhone())
        XCTAssertEqual(paused?.text, "Paused · Continues when iPhone is charging")
        XCTAssertEqual(paused?.shortText, "Continues when iPhone is charging", "narrow, the reason stays")
        XCTAssertEqual(line(Queue(waiting: 1, pause: .heat), .iPhone())?.text, "Paused · Continues when iPhone cools down")
        XCTAssertEqual(line(Queue(waiting: 1, pause: .person))?.text, "Paused")
        XCTAssertNil(line(Queue(waiting: 1, pause: .person))?.shortText, "nothing to drop")
    }

    func testBehaviorWaitingWorkAndModels() {
        XCTAssertEqual(line(Queue(waiting: 3))?.text, "3 waiting to transcribe")
        XCTAssertEqual(line(Queue(waiting: 3))?.shortText, "3 waiting")
        XCTAssertEqual(line(Queue(awaitingModels: 1))?.text, "Waiting for models")
        XCTAssertEqual(line(Queue(awaitingModels: 1))?.tone, .calm, "a wait, not a problem (uxf-06)")
    }

    /// The downloads a queue waits for, in the one phrase over the whole set; only one that stopped needs the person.
    func testBehaviorModelDownloadsInTheQueuesLine() {
        let download = line(Queue(awaitingModels: 1, models: .downloading(done: 3_800_000_000, total: 7_600_000_000)))
        XCTAssertEqual(download?.text, "Downloading models · 50%")
        XCTAssertEqual(download?.progress, 0.5)
        XCTAssertEqual(download?.tone, .working)
        XCTAssertEqual(line(Queue(waiting: 2, models: .downloading(done: 1, total: 2)))?.text, "Downloading models · 50% · 2 waiting")
        XCTAssertEqual(line(Queue(models: .downloading(done: 1, total: 4)))?.text, "Downloading models · 25%",
                       "a download with nothing waiting for it still says so")

        let wifi = line(Queue(awaitingModels: 1, models: .waitingForWiFi(bytes: 852_000_000)))
        XCTAssertEqual(wifi?.text, "Downloading models · Waiting for Wi‑Fi")
        XCTAssertEqual(wifi?.tone, .calm)
        XCTAssertNil(wifi?.progress)

        let failed = line(Queue(awaitingModels: 1, models: .failed(model: "Gemma 4 12B 4-bit", bytes: 7_600_000_000)))
        XCTAssertEqual(failed?.text, "Couldn’t download Gemma 4 12B 4-bit")
        XCTAssertEqual(failed?.tone, .attention)
    }

    /// VM-06: the Mac list's subtitle says the queue in the fewest words: the step that runs, by its name, and what
    /// waits, never the figure the row's line shows; a countdown's seconds; a download's percent; else nothing.
    func testBehaviorTheListSubtitleNamesTheRunningStepAndWhatWaits() {
        func subtitle(_ queue: Queue, at offset: TimeInterval = 0) -> String? {
            QueueStatusWords.subtitle(queue, now: now.addingTimeInterval(offset))
        }
        XCTAssertEqual(subtitle(Queue(running: .transcribing, fraction: 0.4, waiting: 1)), "Transcribing · 1 waiting")
        XCTAssertEqual(subtitle(Queue(running: .summarizing, waiting: 1)), "Summarizing · 1 waiting", "the step that runs, not always Transcribing")
        XCTAssertEqual(subtitle(Queue(running: .identifyingSpeakers, fraction: 0.63)), "Identifying speakers")
        XCTAssertEqual(subtitle(Queue(running: .summarizing, cloudModel: "Claude Sonnet 5.5", waiting: 2)), "Summarizing · 2 waiting")
        let countdown = Queue(running: .summarizing, countdown: now.addingTimeInterval(12), waiting: 1)
        XCTAssertEqual(subtitle(countdown), "Summarizing in 12 s · 1 waiting")
        XCTAssertEqual(subtitle(countdown, at: 3.5), "Summarizing in 9 s · 1 waiting", "rounded up, as the row says it")
        XCTAssertEqual(subtitle(Queue(running: .summarizing, countdown: now.addingTimeInterval(7))),
                       ConversationRowStatus(kind: .waiting, text: nil, countdownUntil: now.addingTimeInterval(7)).text(at: now),
                       "the row's words for the same moment")
        XCTAssertEqual(subtitle(Queue(waiting: 1, download: .init(name: "Parakeet Ultra", fraction: 0.4))), "Downloading Parakeet Ultra · 40%")
        XCTAssertNil(subtitle(Queue(waiting: 3)), "nothing works: nothing to say")
        XCTAssertNil(subtitle(Queue(awaitingModels: 1)))
        XCTAssertNil(subtitle(Queue()))
    }
}
