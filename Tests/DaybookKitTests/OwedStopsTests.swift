import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Stops one device owes another it couldn't reach, kept across relaunches (docs/multipoint.md):
/// in preferences or in a file of the library's, each for a day from when it was first owed.
final class OwedStopsTests: XCTestCase {
    private struct Stop: OwedStop {
        var device: String
        var conversation: UUID
        var owedAt: Date
    }

    func testStopsAreKeptUntilTheyAreSentOrADayHasPassed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OwedStops-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let defaults = makeTestDefaults("daybook.owedStops")
        let now = Date()
        let fresh = Stop(device: "Alex's iPhone", conversation: UUID(), owedAt: now.addingTimeInterval(-3_600))
        let older = Stop(device: "Studio Mac", conversation: UUID(), owedAt: now.addingTimeInterval(-7_200))
        let stale = Stop(device: "Office iMac", conversation: UUID(), owedAt: now.addingTimeInterval(-90_000))

        for store in [OwedStopsStore<Stop>(defaults: defaults, key: "owed"), OwedStopsStore<Stop>(file: folder.appendingPathComponent("owed-stops.json"))] {
            XCTAssertTrue(store.load().isEmpty, "nothing owed yet")
            store.save([fresh, stale, older])
            XCTAssertEqual(store.load(now: now), [older, fresh], "oldest first, and none owed for more than a day")
            XCTAssertEqual(store.load(now: now.addingTimeInterval(86_400)), [], "a day later, none")
            store.save([])
            XCTAssertTrue(store.load(now: now).isEmpty, "sent, so none left")
        }
        XCTAssertNil(defaults.data(forKey: "owed"), "nothing left in preferences")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("owed-stops.json").path), "nor a file")
    }

    func testWhatCantBeReadIsNoStopsAtAll() {
        let defaults = makeTestDefaults("daybook.owedStops")
        defaults.set(Data("not stops".utf8), forKey: "owed")
        XCTAssertTrue(OwedStopsStore<Stop>(defaults: defaults, key: "owed").load().isEmpty)
    }
}
