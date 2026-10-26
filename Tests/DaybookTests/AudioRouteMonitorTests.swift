import Foundation
import XCTest
@testable import Daybook

/// The route monitor's listeners and callback are touched only on its own queue, whichever thread
/// starts or stops it, including its own callback.
final class AudioRouteMonitorTests: XCTestCase {
    func testStartingAndStoppingFromManyThreadsAndFromItsOwnCallback() {
        let monitor = AudioRouteMonitor()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 2) { monitor.start { _ in } } else { monitor.stop() }
        }
        monitor.stop()
        XCTAssertFalse(monitor.isListening)

        let reported = expectation(description: "the callback ran and stopped the monitor")
        monitor.start { route in
            XCTAssertFalse(route.deviceName.isEmpty)
            monitor.stop()
            reported.fulfill()
        }
        XCTAssertTrue(monitor.isListening)
        monitor.refresh()
        wait(for: [reported], timeout: 5)
        XCTAssertFalse(monitor.isListening)
    }
}
