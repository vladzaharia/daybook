import DaybookTestSupport
import XCTest
@testable import DaybookCore

/// A recording's sidecar or journal keeps every clock anchor for a run's first minute, then one every ten seconds, so a
/// long recording's rewrites stay small without changing the drift its anchors measure.
final class ClockAnchorScheduleTests: XCTestCase {
    /// What a writer offers: an anchor about every second (buffers of 10.7 ms), on a clock `drift` fast, with jitter.
    private func offered(seconds: Int, drift: Double, rate: Double = 48_000, start: TimeInterval = 1_000, seed: UInt64 = 7) -> [ClockAnchor] {
        var random = SeededRandom(seed: seed)
        let buffer = 512.0
        let perSecond = Int((rate / buffer).rounded(.up))
        return stride(from: 0, to: seconds * perSecond, by: perSecond).map { index in
            let frame = Int64(Double(index) * buffer)
            return ClockAnchor(frame: frame, hostTime: start + Double(frame) / (rate * (1 + drift)) + random.uniform(-0.0015...0.0015))
        }
    }

    private func kept(_ anchors: [ClockAnchor]) -> [ClockAnchor] {
        var schedule = ClockAnchorSchedule()
        return anchors.filter { schedule.keeps($0) }
    }

    func testEveryAnchorOfTheFirstMinuteThenOneEveryTenSeconds() {
        let anchors = offered(seconds: 4 * 3_600, drift: 0)
        let stored = kept(anchors)
        let start = anchors[0].hostTime
        XCTAssertEqual(stored.prefix { $0.hostTime - start < 60 }, anchors.prefix { $0.hostTime - start < 60 }, "the first minute is whole")
        let later = stored.drop { $0.hostTime - start < 60 }
        for (previous, next) in zip(later.dropLast(), later.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.hostTime - previous.hostTime, ClockAnchorSchedule.sparseInterval)
            XCTAssertLessThan(next.hostTime - previous.hostTime, ClockAnchorSchedule.sparseInterval + 1.1)
        }
        XCTAssertGreaterThan(anchors.count, 14_000)
        XCTAssertLessThan(stored.count, 1_600, "4 hours: about 1,500 anchors, not 14,000")
    }

    func testAResyncIsAlwaysKeptAndStartsAnotherWholeMinute() {
        var anchors = offered(seconds: 300, drift: 0)
        let resumed = anchors.last!.hostTime + 5
        let after = offered(seconds: 120, drift: 0, start: resumed).map {
            ClockAnchor(frame: anchors.last!.frame + 48_000 * 5 + $0.frame, hostTime: $0.hostTime)
        }
        anchors += [ClockAnchor(frame: after[0].frame, hostTime: after[0].hostTime, resync: true)] + after.dropFirst()
        let stored = kept(anchors)
        guard let resync = stored.firstIndex(where: { $0.resync == true }) else { return XCTFail("the resync is kept") }
        let afterResync = stored[resync...]
        XCTAssertEqual(afterResync.prefix { $0.hostTime - resumed < 60 }.count, 60, "every anchor of the new run's first minute")
        XCTAssertLessThan(afterResync.count, 60 + 8)
    }

    func testTheDriftMeasuredFromTheKeptAnchorsIsTheSame() {
        for drift in [120e-6, -300e-6] {
            let anchors = offered(seconds: 1_800, drift: drift)
            let stored = kept(anchors)
            let all = ClockDriftEstimator.fit(anchors: anchors, nominalRate: 48_000, sessionHostTime: 1_000, fallbackOffset: 0)
            let thinned = ClockDriftEstimator.fit(anchors: stored, nominalRate: 48_000, sessionHostTime: 1_000, fallbackOffset: 0)
            XCTAssertEqual(thinned.clock.driftPPM, drift * 1e6, accuracy: 0.5)
            XCTAssertEqual(thinned.clock.driftPPM, all.clock.driftPPM, accuracy: 0.5)
            XCTAssertEqual(thinned.clock.time(atFrame: 48_000 * 1_000), all.clock.time(atFrame: 48_000 * 1_000), accuracy: 0.001)
        }
    }
}
