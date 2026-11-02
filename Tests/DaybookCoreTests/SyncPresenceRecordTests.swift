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
}
