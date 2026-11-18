import XCTest
@testable import DaybookCore

/// Mapping a passage's wall-clock start to seconds into the recording, across pauses.
final class RecordingClockMapTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private func sample(_ at: TimeInterval, _ elapsed: TimeInterval, running: Bool = true) -> RecordingClockSample {
        RecordingClockSample(at: start.addingTimeInterval(at), elapsed: elapsed, running: running)
    }

    func testBehaviorMapsAcrossPause() {
        // Recording from 0 to 60 s, paused for two minutes, recording again from 180 s.
        let samples = [sample(0, 0), sample(30, 30), sample(60, 60, running: false), sample(120, 60, running: false), sample(180, 60), sample(200, 80)]
        func elapsed(_ at: TimeInterval) -> TimeInterval? { RecordingClockMap.elapsed(at: start.addingTimeInterval(at), samples: samples) }
        XCTAssertEqual(elapsed(10), 10)
        XCTAssertEqual(elapsed(45), 45)
        XCTAssertEqual(elapsed(90), 60, "paused: the recording's clock stands still")
        XCTAssertEqual(elapsed(150), 60)
        XCTAssertEqual(elapsed(185), 65, "running again from its own sample")
        XCTAssertEqual(try XCTUnwrap(elapsed(230)), 110, accuracy: 0.0001, "past the last sample, still running")
        // Order of the samples doesn't matter.
        XCTAssertEqual(RecordingClockMap.elapsed(at: start.addingTimeInterval(45), samples: samples.reversed()), 45)
    }

    func testBehaviorNoNearbySampleGivesNil() {
        let samples = [sample(100, 10), sample(150, 60)]
        XCTAssertNil(RecordingClockMap.elapsed(at: start.addingTimeInterval(50), samples: samples), "before the first sample")
        XCTAssertNil(RecordingClockMap.elapsed(at: start.addingTimeInterval(150 + 121), samples: samples), "more than 120 s after the last")
        XCTAssertEqual(try XCTUnwrap(RecordingClockMap.elapsed(at: start.addingTimeInterval(150 + 120), samples: samples)), 180, accuracy: 0.0001)
        XCTAssertNil(RecordingClockMap.elapsed(at: start, samples: []))
        XCTAssertNil(RecordingClockMap.elapsed(at: start.addingTimeInterval(400), samples: samples, reach: 60), "a shorter reach")
        // A stroke created just before the first sample (the tool's begin callback trailed it) uses that sample.
        XCTAssertEqual(try XCTUnwrap(RecordingClockMap.elapsed(at: start.addingTimeInterval(99), samples: samples)), 9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(RecordingClockMap.elapsed(at: start.addingTimeInterval(98), samples: samples)), 8, accuracy: 0.0001)
        XCTAssertNil(RecordingClockMap.elapsed(at: start.addingTimeInterval(97.9), samples: samples), "more than 2 s ahead of it")
        // Never before the recording began.
        XCTAssertEqual(RecordingClockMap.elapsed(at: start.addingTimeInterval(99.9), samples: [sample(100, 0)]), 0)
    }

    func testBehaviorAppendingThinsAndKeepsStateChanges() {
        var samples: [RecordingClockSample] = []
        samples = RecordingClockMap.appending(sample(0, 0), to: samples)
        XCTAssertEqual(samples.count, 1)
        samples = RecordingClockMap.appending(sample(2, 2), to: samples)
        XCTAssertEqual(samples.count, 1, "less than 5 s since the last, nothing changed")
        samples = RecordingClockMap.appending(sample(3, 3, running: false), to: samples)
        XCTAssertEqual(samples.map(\.running), [true, false], "a pause is kept at once")
        samples = RecordingClockMap.appending(sample(4, 3), to: samples)
        XCTAssertEqual(samples.count, 3, "and so is running again")
        samples = RecordingClockMap.appending(sample(9, 8), to: samples)
        XCTAssertEqual(samples.count, 4, "5 s later")
        // Thousands of samples stay within the cap, newest kept, in order, with every change between running and paused.
        var long: [RecordingClockSample] = []
        for index in 0..<6_000 {
            let running = !(index % 1_000 == 999)
            long = RecordingClockMap.appending(sample(Double(index) * 6, Double(index) * 6, running: running), to: long)
        }
        XCTAssertLessThanOrEqual(long.count, RecordingClockMap.capacity)
        XCTAssertEqual(long.last?.at, start.addingTimeInterval(5_999 * 6))
        XCTAssertEqual(long.map(\.at), long.map(\.at).sorted())
        XCTAssertGreaterThan(long.count, 3_000, "thinned, not emptied")
        for index in stride(from: 999, to: 6_000, by: 1_000) {
            XCTAssertTrue(long.contains { $0.at == start.addingTimeInterval(Double(index) * 6) && !$0.running }, "the pause at \(index) is kept")
        }
        XCTAssertEqual(long.first?.at, start, "the very first sample is kept")
    }
}
