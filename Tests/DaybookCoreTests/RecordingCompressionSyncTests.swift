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
            device: SyncDeviceIdentity(deviceClass: deviceClass, displayName: name, canProcess: deviceClass == .mac),
            audioCache: deviceClass == .phone ? AudioCachePolicy(budgetBytes: 1 << 30) : nil))
    }

    private func pass(_ engine: LibrarySyncEngine, _ name: String? = nil, _ meetings: [Meeting] = []) async throws {
        let result = try await engine.synchronize(meetings: meetings)
        if let name {
            let store = try MeetingStore(rootURL: root.appendingPathComponent(name))
            for meeting in result.meetings { try await store.save(meeting) }
        }
        try await engine.acknowledge(result.checkpointID)
    }

    /// The iPhone fetched a recording a Mac later compressed: the original it cached goes once the copy is in iCloud,
    /// whatever the budget, and not before.
    func testBehaviorIPhoneLetsGoOfAnOriginalAMacReplaced() async throws {
        let mac = try engine("Mac"), phone = try engine("Phone", .phone)
        let source = root.appendingPathComponent("original.wav")
        try Data(repeating: 7, count: 4_096).write(to: source)
        var meeting = try await MeetingStore(rootURL: root.appendingPathComponent("Mac")).importAudio(from: source, into: Meeting(title: "Call"), source: .microphone)
        try await pass(mac, "Mac", [meeting]); try await pass(phone, "Phone")
        let original = meeting.tracks[0]
        _ = try await phone.fetchAudio(for: original, in: meeting.id, options: AudioFetchOptions(pollInterval: .milliseconds(5), timeout: .seconds(10)))
        let cached = root.appendingPathComponent("Phone/Meetings/\(meeting.id.uuidString)/\(original.relativePath)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        // The Mac replaces it with a copy (bytes stand in for AAC: sync never decodes audio).
        let copyBytes = Data(repeating: 9, count: 512)
        let digest = AudioDigest.sha256(data: copyBytes)
        let relativePath = RecordingCompression.relativePath(trackID: original.id, sha256: digest)
        try copyBytes.write(to: root.appendingPathComponent("Mac/Meetings/\(meeting.id.uuidString)/\(relativePath)"))
        RecordingCompression.File(relativePath: relativePath, fileName: "original.m4a", sha256: digest, encoding: TrackEncoding(
            method: "aac-lc-64", sourceFormat: "PCM", previousSHA256: original.sha256, previousRelativePath: original.relativePath,
            previousFileName: original.fileName, encodedAt: Date())).apply(to: &meeting.tracks[0])
        try await MeetingStore(rootURL: root.appendingPathComponent("Mac")).save(meeting)
        // Applied on the iPhone before the copy is in iCloud: the original stays.
        let blob = remote.appendingPathComponent("Blobs/\(digest)")
        try await pass(phone, "Phone")
        try await MeetingStore(rootURL: root.appendingPathComponent("Phone")).save(meeting)
        var report = try await phone.evictAudio()
        XCTAssertTrue(report.evicted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path), "the copy isn't in iCloud yet")
        try await pass(mac, "Mac", [meeting])
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        try await pass(phone, "Phone")
        report = try await phone.evictAudio()
        XCTAssertEqual(report.evicted.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
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
