import Foundation
import XCTest
@testable import Daybook

/// One copy of Daybook at a time: which processes count as a copy, and which of several stays.
final class SingleInstanceTests: XCTestCase {
    private func copy(_ pid: pid_t, _ bundleID: String?, executable: String? = "Daybook", launched: TimeInterval? = 0) -> SingleInstance.Copy {
        SingleInstance.Copy(pid: pid, bundleID: bundleID, executableName: executable, launched: launched.map(Date.init(timeIntervalSince1970:)))
    }

    func testEveryBuildOfDaybookCountsAndOtherAppsDont() {
        XCTAssertTrue(SingleInstance.isDaybook(bundleID: "local.daybook.app", executableName: "Daybook"))
        XCTAssertTrue(SingleInstance.isDaybook(bundleID: "local.daybook.app.adhoc", executableName: "Daybook"))
        XCTAssertTrue(SingleInstance.isDaybook(bundleID: "local.daybook.app.rehearsal2", executableName: "Daybook"))
        XCTAssertTrue(SingleInstance.isDaybook(bundleID: nil, executableName: "Daybook"), "swift run")
        XCTAssertTrue(SingleInstance.isDaybook(bundleID: "local.daybook.phone", executableName: "Daybook"), "the App Store build")
        XCTAssertFalse(SingleInstance.isDaybook(bundleID: "local.daybook.phone", executableName: "DaybookPhone"), "the iPhone app on a Mac")
        XCTAssertFalse(SingleInstance.isDaybook(bundleID: "local.daybook.sandboxprobe", executableName: "Daybook"))
        XCTAssertFalse(SingleInstance.isDaybook(bundleID: "local.daybook.application", executableName: "Daybook"))
        XCTAssertFalse(SingleInstance.isDaybook(bundleID: "com.apple.Notes", executableName: "Notes"))
        XCTAssertFalse(SingleInstance.isDaybook(bundleID: nil, executableName: "daybook-helper"))
    }

    func testALaterCopyGivesWayToTheEarliestAndTheFirstGoesOn() {
        let release = copy(100, "local.daybook.app", launched: 10)
        let adhoc = copy(200, "local.daybook.app.adhoc", launched: 20)
        let unbundled = copy(300, nil, launched: 30)
        let notes = copy(50, "com.apple.Notes", executable: "Notes", launched: 1)
        let running = [notes, release, adhoc, unbundled]
        XCTAssertNil(SingleInstance.earlierCopy(than: release, among: running), "The first copy stays")
        XCTAssertEqual(SingleInstance.earlierCopy(than: adhoc, among: running)?.pid, 100)
        XCTAssertEqual(SingleInstance.earlierCopy(than: unbundled, among: running)?.pid, 100, "The earliest, not just any earlier one")
        XCTAssertNil(SingleInstance.earlierCopy(than: release, among: [release]), "Alone, it never sees itself")
    }

    func testTheKernelSaysWhenAProcessStarted() throws {
        let started = try XCTUnwrap(SingleInstance.startTime(of: ProcessInfo.processInfo.processIdentifier))
        XCTAssertLessThanOrEqual(started, Date())
        XCTAssertGreaterThan(started, Date().addingTimeInterval(-24 * 3600), "This test process started today")
        XCTAssertNil(SingleInstance.startTime(of: 999_999), "No such process")
    }

    func testCopiesStartingAtOnceAgreeOnOne() {
        let first = copy(100, "local.daybook.app", launched: 10)
        let second = copy(200, "local.daybook.app.adhoc", launched: 10)
        let running = [second, first]
        XCTAssertNil(SingleInstance.earlierCopy(than: first, among: running), "The lower process ID stays")
        XCTAssertEqual(SingleInstance.earlierCopy(than: second, among: running)?.pid, 100)
        // A copy with no launch date (not yet finished launching) counts as later than one that has it.
        let undated = copy(50, nil, launched: nil)
        XCTAssertEqual(SingleInstance.earlierCopy(than: undated, among: [undated, first])?.pid, 100)
        XCTAssertNil(SingleInstance.earlierCopy(than: first, among: [undated, first]))
    }
}
