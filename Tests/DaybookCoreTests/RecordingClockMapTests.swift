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
        XCTAssertGreaterThanOrEqual(long.count, RecordingClockMap.capacity * 3 / 4, "thinned, not emptied")
        for index in stride(from: 999, to: 6_000, by: 1_000) {
            XCTAssertTrue(long.contains { $0.at == start.addingTimeInterval(Double(index) * 6) && !$0.running }, "the pause at \(index) is kept")
        }
        XCTAssertEqual(long.first?.at, start, "the very first sample is kept")
    }

    func testBehaviorThinningKeepsGapsEvenAcrossAVeryLongRecording() {
        var samples: [RecordingClockSample] = []
        for index in 0..<20_000 { samples = RecordingClockMap.appending(sample(Double(index) * 5, Double(index) * 5), to: samples) }
        let length = 19_999 * 5.0
        XCTAssertLessThanOrEqual(samples.count, RecordingClockMap.capacity)
        XCTAssertEqual(samples.first?.at, start)
        XCTAssertEqual(samples.last?.at, start.addingTimeInterval(length))
        let gaps = zip(samples, samples.dropFirst()).map { $1.at.timeIntervalSince($0.at) }
        let even = length / Double(RecordingClockMap.capacity)
        XCTAssertLessThanOrEqual(gaps.max() ?? 0, even * 4, "no stretch of the recording is left without a sample")
        // A passage written early still gets a time late in the recording.
        XCTAssertNotNil(RecordingClockMap.elapsed(at: start.addingTimeInterval(1_000), samples: samples))
    }

    // MARK: Filed with the recording

    /// What the recorder samples: its clock counts through a pause (the audio holds the pause as silence), a sample is taken as
    /// a stroke begins, and the state change itself is sampled.
    private func recorded(pauses: [(from: Double, to: Double)], length: Double, every: Double = 5) -> [RecordingClockSample] {
        var samples: [RecordingClockSample] = []
        var time = 0.0
        while time <= length {
            let paused = pauses.contains { time >= $0.from && time < $0.to }
            samples = RecordingClockMap.appending(sample(time, time, running: !paused), to: samples)
            time += every
        }
        return samples
    }

    func testBehaviorFiledClockMapsLikeTheFullOneAcrossTwoPauses() {
        let pauses = [(from: 900.0, to: 1_100.0), (from: 2_400.0, to: 2_450.0)]
        let full = recorded(pauses: pauses, length: 3_600)
        let filed = RecordingClockMap.filed(full)
        XCTAssertGreaterThan(full.count, 600)
        XCTAssertLessThan(filed.count, 40)
        XCTAssertEqual(filed.first, full.first)
        XCTAssertEqual(filed.last, full.last)
        XCTAssertEqual(filed.map(\.at), filed.map(\.at).sorted())
        for change in full.indices.dropFirst() where full[change].running != full[change - 1].running {
            XCTAssertTrue(filed.contains(full[change]) && filed.contains(full[change - 1]), "every change of state is kept")
        }
        // A moment while recording, anywhere in the hour, is mapped the same way (the clock is linear between changes).
        for moment in stride(from: 3.0, to: 3_590.0, by: 7.3) where !pauses.contains(where: { moment >= $0.from - 10 && moment < $0.to }) {
            let a = RecordingClockMap.elapsed(at: start.addingTimeInterval(moment), samples: full)
            let b = RecordingClockMap.elapsed(at: start.addingTimeInterval(moment), samples: filed)
            XCTAssertEqual(try XCTUnwrap(a), try XCTUnwrap(b), accuracy: 0.005, "at \(moment)")
        }
        // A moment inside a pause is where the pause began, the start of the silence in the audio.
        XCTAssertEqual(RecordingClockMap.elapsed(at: start.addingTimeInterval(1_000), samples: filed), 900)
        // Filed again, nothing more goes.
        XCTAssertEqual(RecordingClockMap.filed(filed), filed)
    }

    func testBehaviorAnHourOfContinuousWritingFilesUnderFiveKilobytes() throws {
        let full = recorded(pauses: [], length: 3_600)
        XCTAssertEqual(full.count, 721)
        let filed = RecordingClockMap.filed(full)
        XCTAssertLessThanOrEqual(filed.count, 14, "the ends and one anchor every five minutes")
        let bytes = try SyncEncoding.data(filed).count
        XCTAssertLessThan(bytes, 5_000, "\(bytes) bytes")
        XCTAssertEqual(RecordingClockMap.filed([]), [])
        XCTAssertEqual(RecordingClockMap.filed(Array(full.prefix(2))), Array(full.prefix(2)))
        // However often it pauses, a filed clock is bounded.
        let flapping = (0..<2_000).map { sample(Double($0), Double($0), running: $0 % 2 == 0) }
        XCTAssertLessThanOrEqual(RecordingClockMap.filed(flapping).count, RecordingClockMap.filedCapacity)
    }
}

