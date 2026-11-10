import SwiftUI
import XCTest
@testable import DaybookDesign

/// VM-16: every view counting down to one moment ticks on that moment's own second, whenever it began, so the Mac
/// list's subtitle and the row beside it never say different numbers ("Summarizing in 7 s" beside "6 s").
final class CountdownScheduleTests: XCTestCase {
    private let deadline = Date(timeIntervalSinceReferenceDate: 800_000_012.4)

    /// Whole seconds left, rounded up, as every countdown says them.
    private func secondsLeft(at date: Date) -> Int { max(1, Int(deadline.timeIntervalSince(date).rounded(.up))) }

    func testBehaviorACountdownTicksWhereItsSecondsChange() {
        let now = deadline.addingTimeInterval(-12.4)
        let tick = CountdownPhase.tick(before: deadline, at: now)
        XCTAssertEqual(tick.timeIntervalSince(deadline), -13, "the whole seconds left, rounded up, before the deadline")
        XCTAssertLessThanOrEqual(tick, now)
        XCTAssertEqual(secondsLeft(at: tick), 13)
        XCTAssertEqual(secondsLeft(at: tick.addingTimeInterval(0.999)), 13, "the number holds until the next tick")
        XCTAssertEqual(secondsLeft(at: tick.addingTimeInterval(1)), 12, "and changes on it")
    }

    func testBehaviorViewsThatBeganAtDifferentMomentsShareThePhase() {
        let first = CountdownPhase.tick(before: deadline, at: deadline.addingTimeInterval(-12.4))
        let later = CountdownPhase.tick(before: deadline, at: deadline.addingTimeInterval(-6.85))
        let offset = later.timeIntervalSince(first)
        XCTAssertEqual(offset, offset.rounded(), "a whole number of seconds apart: the same ticks")
        XCTAssertEqual(CountdownPhase.tick(before: deadline, at: deadline.addingTimeInterval(3)), deadline, "once it has passed, the deadline itself")
    }

    func testBehaviorTheScheduleStartsOnThePhase() {
        let now = deadline.addingTimeInterval(-7.3)
        let schedule: PeriodicTimelineSchedule = .countdown(to: deadline, now: now)
        var entries = schedule.entries(from: now, mode: .normal).makeIterator()
        let dates = (0..<3).compactMap { _ in entries.next() }
        XCTAssertEqual(dates.count, 3)
        for date in dates {
            let before = deadline.timeIntervalSince(date)
            XCTAssertEqual(before, before.rounded(), "every tick a whole number of seconds before the deadline")
        }
        XCTAssertEqual(dates.map(secondsLeft), [8, 7, 6])
    }
}
