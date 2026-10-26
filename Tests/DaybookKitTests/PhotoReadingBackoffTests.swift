import Foundation
import XCTest
@testable import DaybookKit

/// A photo that can't be read waits longer after each failure, and reading it clears the wait.
final class PhotoReadingBackoffTests: XCTestCase {
    func testWaitsGrowAndAReadClearsThem() {
        var backoff = PhotoReadingBackoff()
        let photo = UUID(), other = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(backoff.mayRead(photo, at: start))
        backoff.failed(photo, reason: "Unreadable", at: start)
        XCTAssertFalse(backoff.mayRead(photo, at: start.addingTimeInterval(30)))
        XCTAssertTrue(backoff.mayRead(photo, at: start.addingTimeInterval(60)))
        XCTAssertTrue(backoff.mayRead(other, at: start), "Another photo isn't held back")
        backoff.failed(photo, reason: "Unreadable", at: start.addingTimeInterval(60))
        XCTAssertEqual(backoff.failure(photo)?.attempts, 2)
        XCTAssertEqual(backoff.nextRetry(among: [photo, other]), start.addingTimeInterval(660))
        for attempt in 3...9 { backoff.failed(photo, reason: "Unreadable \(attempt)", at: start) }
        XCTAssertEqual(backoff.failure(photo)?.retryAt, start.addingTimeInterval(86_400), "At most once a day")
        backoff.read(photo)
        XCTAssertTrue(backoff.mayRead(photo, at: start))
        XCTAssertNil(backoff.nextRetry(among: [photo]))
    }
}
