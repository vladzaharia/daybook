import Foundation
import XCTest
@testable import DaybookCore

/// The recorder handoff record travels in library settings like ownership: the later write wins,
/// clearing is a deletion marker, earlier files decode, and a phase from a later version never reads
/// as a release.
final class RecorderHandoffRecordTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ phase: RecorderHandoffRecord.Phase, at date: Date) -> RecorderHandoffRecord {
        RecorderHandoffRecord(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, kind: "soundcore.work", serial: "S1",
                              ownerID: "mac", ownerName: "Studio Mac", requesterID: "phone", requesterName: "Alex’s iPhone",
                              requesterClass: .phone, phase: phase, requestedAt: t0, updatedAt: date)
    }

    private func metadata(_ record: RecorderHandoffRecord?, id: String = "soundcore.work|S1", at date: Date) -> LibraryMetadata {
        var metadata = LibraryMetadata()
        metadata.handoffs = [LibraryValue(id: id, value: record, modifiedAt: date)]
        return metadata
    }

    func testTheLaterAnswerWinsAndClearingSticks() {
        let requested = metadata(record(.requested, at: t0), at: t0)
        let released = metadata(record(.released, at: t0.addingTimeInterval(5)), at: t0.addingTimeInterval(5))
        XCTAssertEqual(requested.merging(released).recorderHandoff(kind: "soundcore.work", serial: "S1")?.phase, .released)
        XCTAssertEqual(released.merging(requested).recorderHandoff(kind: "soundcore.work", serial: "S1")?.phase, .released)

        let cleared = metadata(nil, at: t0.addingTimeInterval(9))
        let merged = released.merging(cleared)
        XCTAssertNil(merged.recorderHandoff(kind: "soundcore.work", serial: "S1"))
        XCTAssertTrue(merged.recorderHandoffs.isEmpty)
        XCTAssertNil(merged.merging(requested).recorderHandoff(kind: "soundcore.work", serial: "S1"), "an older copy doesn't come back")
    }

    func testEarlierLibrariesAndLaterPhasesDecode() throws {
        // A library file from before handoffs: no field at all, and it stays absent after a merge.
        let old = try JSONDecoder().decode(LibraryMetadata.self, from: Data(#"{"schemaVersion":1,"folders":[],"templates":[],"vocabulary":[]}"#.utf8))
        XCTAssertNil(old.handoffs)
        XCTAssertNil(old.merging(old).handoffs)

        var encoded = try JSONEncoder().encode(record(.releasing, at: t0))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["phase"] = "teleporting"
        encoded = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(RecorderHandoffRecord.self, from: encoded)
        XCTAssertEqual(decoded.phase, .requested, "an unknown phase waits; it's never taken as a release")
        XCTAssertNil(decoded.recordingInProgress, "earlier records have no recording in progress")

        // A release naming the recording in progress round-trips, and its key is all an earlier version skips.
        var released = record(.released, at: t0)
        released.recordingInProgress = .init(recordingID: "1729003600", attachTo: UUID(), isAutomatic: true)
        let data = try JSONEncoder().encode(released)
        XCTAssertEqual(try JSONDecoder().decode(RecorderHandoffRecord.self, from: data), released)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys).subtracting(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record(.released, at: t0))) as? [String: Any]).keys),
                       ["recordingInProgress"])
        XCTAssertEqual(decoded.recorderID, RecorderOwnership.id(kind: "soundcore.work", serial: "S1"))
    }
}
