import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest

/// What Compress Older Recordings asks of the sync engine: every device in use says it knows compressed recordings
/// before a Mac compresses, and an object counts as uploaded only once iCloud has it.
final class RecordingCompressionSyncTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("Cloud") }

    override func setUpWithError() throws {
        root = makeTemporaryFolder("DaybookCompressionSync")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    }

    private func engine(_ name: String, _ deviceClass: SyncDeviceClass = .mac) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: root.appendingPathComponent(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: deviceClass == .mac ? .eager : .onDemand,
            device: SyncDeviceIdentity(deviceClass: deviceClass, displayName: name, canProcess: deviceClass == .mac)))
    }

    private func pass(_ engine: LibrarySyncEngine) async throws {
        let result = try await engine.synchronize(meetings: [])
        try await engine.acknowledge(result.checkpointID)
    }

    func testBehaviorEveryDeviceInUseMustKnowCompressedRecordings() async throws {
        let mac = try engine("Mac"), phone = try engine("Phone", .phone)
        try await pass(mac); try await pass(phone); try await pass(mac)
        let compresses = await mac.everyRecentDeviceCompresses()
        XCTAssertTrue(compresses)
        // The iPhone's presence as a version before compression wrote it: no `compress-1`.
        let devices = remote.appendingPathComponent("Devices")
        var edited = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: devices.path) {
            let url = devices.appendingPathComponent(name)
            guard var record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  record["deviceID"] as? String == "Phone" else { continue }
            record["features"] = (record["features"] as? [String] ?? []).filter { $0 != LibrarySyncEngine.compressionFeature }
            try JSONSerialization.data(withJSONObject: record).write(to: url)
            edited += 1
        }
        XCTAssertEqual(edited, 1)
        let afterOlder = await mac.everyRecentDeviceCompresses()
        XCTAssertFalse(afterOlder, "an older device in use holds compression back")
        // Seen more than 30 days ago, it doesn't.
        let later = await mac.everyRecentDeviceCompresses(now: Date().addingTimeInterval(31 * 86_400))
        XCTAssertTrue(later)
    }

    func testBehaviorObjectIsUploadedOnlyOnceItIsThere() async throws {
        let mac = try engine("Mac")
        let digest = String(repeating: "e", count: 64)
        var uploaded = await mac.isObjectUploaded(digest)
        XCTAssertFalse(uploaded)
        try FileManager.default.createDirectory(at: remote.appendingPathComponent("Blobs"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: remote.appendingPathComponent("Blobs/\(digest)"))
        uploaded = await mac.isObjectUploaded(digest)
        XCTAssertTrue(uploaded)
        uploaded = await mac.isObjectUploaded("not-a-hash")
        XCTAssertFalse(uploaded)
    }
}
