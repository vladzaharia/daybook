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
        XCTAssertEqual(line(Queue(awaitingModels: 1))?.tone, .attention)
        let download = line(Queue(awaitingModels: 1, download: .init(name: "Parakeet Ultra", fraction: 0.4)))
        XCTAssertEqual(download?.text, "Downloading Parakeet Ultra · 40%")
        XCTAssertEqual(download?.progress, 0.4)
    }
}
