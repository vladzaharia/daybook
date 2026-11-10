import XCTest
@testable import DaybookCore

/// A presence record written into a sync folder by hand reads back as every replica reads one.
final class SyncPresenceRecordTests: XCTestCase {
    func testBehaviorAWrittenPresenceReadsBackAsTheDeviceThatSyncedThere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncPresenceRecordTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lastSeen = Date(timeIntervalSince1970: 1_800_000_000)
        try SyncPresenceRecord.write(deviceID: "demo-mac-studio", displayName: "Studio Mac", deviceClass: .mac, canProcess: true,
                                     audioPolicy: .eager, lastSeen: lastSeen, intoSyncFolder: folder)
        let url = folder.appendingPathComponent(SyncPresenceFiles.directory, isDirectory: true)
            .appendingPathComponent(SyncPresenceFiles.fileName(for: "demo-mac-studio"))
        let record = try XCTUnwrap(SyncPresenceFiles.decode(Data(contentsOf: url)))
        XCTAssertEqual(record.deviceID, "demo-mac-studio")
        XCTAssertEqual(record.displayName, "Studio Mac")
        XCTAssertEqual(record.deviceClass, .mac)
        XCTAssertTrue(record.canProcess)
        XCTAssertEqual(record.audioPolicy, "eager")
        XCTAssertEqual(record.lastSeen, lastSeen)
    }

    /// What a device has left to upload and what stands in its way travel in its record; a problem a newer Daybook names
    /// is kept, and a field this build can't read leaves the record readable.
    func testBehaviorPendingUploadsAndProblemReadBackLeniently() throws {
        var record = SyncDeviceRecord(deviceID: "phone", deviceClass: .phone, displayName: "Alex's iPhone", canProcess: false,
                                      audioPolicy: "onDemand", lastSeen: Date(timeIntervalSince1970: 1_800_000_000))
        record.pendingUploads = 3
        record.problem = .storageFull
        let decoded = try XCTUnwrap(SyncPresenceFiles.decode(SyncPresenceFiles.encode(record)))
        XCTAssertEqual(decoded.pendingUploads, 3)
        XCTAssertEqual(decoded.problem, .storageFull)
        XCTAssertEqual(decoded, record)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncPresenceFiles.encode(record)) as? [String: Any])
        object["problem"] = "accountLocked"
        object["pendingUploads"] = "many"
        let newer = try XCTUnwrap(SyncPresenceFiles.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(newer.problem, SyncPresenceProblem(rawValue: "accountLocked"))
        XCTAssertNil(newer.pendingUploads)
        object["problem"] = 7
        object.removeValue(forKey: "pendingUploads")
        let odd = try XCTUnwrap(SyncPresenceFiles.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertNil(odd.problem)
        XCTAssertEqual(odd.displayName, "Alex's iPhone")
    }
}
