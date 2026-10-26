import XCTest
@testable import DaybookCore

/// Journals written by other versions of Daybook: entries from a newer one (unknown values, extra fields,
/// a newer schema) and local state left by an older one. Temporary folders and synthetic data only.
final class LibrarySyncCompatibilityTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("Remote") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private func engine(_ name: String, policy: SyncAudioPolicy = .eager) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(audioPolicy: policy))
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSyncCompatibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ meetings: [Meeting] = [], metadata: Data? = nil) async throws -> SyncResult {
        let result = try await engine.synchronize(meetings: meetings, libraryMetadata: metadata)
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs { _ = try? await store.moveToTrash(id) }
        try await engine.acknowledge(result.checkpointID)
        return result
    }
    private func eventNames(_ directory: String = "Events") throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent(directory).path).filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) })
    }
    /// Writes a journal entry as another Daybook would, named by its SHA-256. Returns its name.
    @discardableResult
    private func write(_ object: [String: Any], to directory: String = "Events") throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let name = SyncDigest.sha256(data: bytes)
        try bytes.write(to: remote.appendingPathComponent("\(directory)/\(name).json"))
        return name
    }
    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: SyncEncoding.data(value)) as? [String: Any])
    }

    func testAnEventFromANewerSchemaHoldsItsConversationWithoutWaitingOrRereading() async throws {
        let a = try engine("A"), phone = try engine("Phone", policy: .onDemand)
        let meeting = Meeting(title: "Roadmap", notes: "v1 notes")
        try await pass(a, "A", [meeting])
        let head = try XCTUnwrap(try eventNames().first)
        // A newer Daybook edited it with a format this one can't read, then edited again on top.
        let newer = try write(["schemaVersion": 2, "meetingID": meeting.id.uuidString, "deviceID": "Future", "sequence": 1,
                               "parents": [head], "deleted": false, "assets": [], "payload": ["notes": "v2 notes"]])
        var child = try object(meeting); child["notes"] = "after v2"
        try write(["schemaVersion": 1, "meetingID": meeting.id.uuidString, "deviceID": "Future", "sequence": 2,
                   "parents": [newer], "snapshot": child, "deleted": false, "assets": []])
        let first = try await pass(phone, "Phone")
        XCTAssertEqual(first.meetings.first?.notes, "v1 notes", "the conversation stays at what this version can read")
        XCTAssertEqual(first.pendingDownloads, 0, "an entry that can't be read isn't a download to wait for")
        XCTAssertTrue(first.warnings.contains { $0.contains("newer version of Daybook") })
        let hasRemoteChanges = await phone.hasRemoteChanges()
        XCTAssertFalse(hasRemoteChanges, "a settled pass doesn't keep a phone running full passes")
        let second = try await phone.synchronize(meetings: first.meetings)
        XCTAssertEqual(second.pendingDownloads, 0)
        XCTAssertEqual(second.publishedEvents, 0)
        XCTAssertTrue(second.warnings.contains { $0.contains("newer version of Daybook") }, "the warning stays while the entry is there")
    }

    func testUnknownValuesAndExtraFieldsApplyAndSurviveAnOlderDevicesEdit() async throws {
        let a = try engine("A"), b = try engine("B")
        let meeting = Meeting(title: "Workshop")
        try await pass(a, "A", [meeting])
        let head = try XCTUnwrap(try eventNames().first)
        var snapshot = try object(meeting)
        snapshot["kind"] = "workshop"; snapshot["status"] = "queued"; snapshot["mood"] = "focused"
        try write(["schemaVersion": 1, "meetingID": meeting.id.uuidString, "deviceID": "Future", "sequence": 1,
                   "parents": [head], "snapshot": snapshot, "deleted": false, "assets": [], "signature": "extra"])
        let pulled = try await pass(b, "B")
        var onB = try XCTUnwrap(pulled.meetings.first)
        XCTAssertEqual(onB.kind, .auto)
        XCTAssertEqual(onB.$kind.rawValue, "workshop")
        XCTAssertEqual(pulled.pendingDownloads, 0)
        onB.setNotes("B's notes")
        try await pass(b, "B", [onB])
        let backOnA = try await pass(a, "A", [meeting])
        let onA = try XCTUnwrap(backOnA.meetings.first)
        XCTAssertEqual(onA.notes, "B's notes")
        XCTAssertEqual(onA.$kind.rawValue, "workshop", "an older device's edit keeps the newer value")
        XCTAssertEqual(onA.$status.rawValue, "queued")
    }

    func testLibrarySettingsInANewerFormatDoNotFreezeTheRest() async throws {
        let a = try engine("A"), b = try engine("B")
        func settings(_ folder: String) throws -> Data {
            var metadata = LibraryMetadata()
            metadata.folders = [.init(id: folder, value: LibraryFolder(name: folder))]
            return try JSONEncoder().encode(metadata)
        }
        try await pass(a, "A", metadata: try settings("Base"))
        let base = try XCTUnwrap(try eventNames("Metadata").first)
        // A newer Daybook's settings in a format this one can't merge, and a version written on top of it.
        let newer = try write(["schemaVersion": 1, "deviceID": "Future", "sequence": 1, "parents": [base],
                               "data": Data(#"{"schemaVersion":2,"spaces":[]}"#.utf8).base64EncodedString()], to: "Metadata")
        let child = try write(["schemaVersion": 1, "deviceID": "Future", "sequence": 2, "parents": [newer],
                               "data": try settings("After").base64EncodedString()], to: "Metadata")
        // Meanwhile A edits too.
        try await pass(a, "A", metadata: try settings("From A"))
        let result = try await pass(b, "B")
        XCTAssertEqual(result.pendingDownloads, 0)
        let folders = Set(try result.metadataVersions.flatMap { try JSONDecoder().decode(LibraryMetadata.self, from: $0).folders.map(\.id) })
        XCTAssertEqual(folders, ["After", "From A"], "readable heads merge without the unreadable parent")
        XCTAssertFalse(result.warnings.contains { $0.contains("Folders and templates are waiting") })
        XCTAssertTrue(try eventNames("Metadata").contains(child))
    }
}
