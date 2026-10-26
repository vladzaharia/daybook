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

    /// A Mac updated in place: the current engine opens the local state the version 1 engine left, with a pass it
    /// returned but never acknowledged and part of the journal it hadn't read yet.
    func testUpgradingInPlaceContinuesFromTheOlderEnginesState() async throws {
        let legacy = try LegacyLibrarySyncEngine(localRoot: local("A"), remoteRoot: remote, deviceID: "A")
        let storeA = try MeetingStore(rootURL: local("A"))
        let shared = Meeting(title: "Shared", notes: "v1"), other = Meeting(title: "Other")
        let first = try await legacy.synchronize(meetings: [shared, other])
        for meeting in first.meetings { try await storeA.save(meeting) }
        try await legacy.acknowledge(first.checkpointID)

        // Another Mac edits one conversation and starts a new one.
        let b = try engine("B")
        let pulledByB = try await pass(b, "B")
        var onB = try XCTUnwrap(pulledByB.meetings.first { $0.id == shared.id })
        onB.setNotes("Edited on B")
        let fromB = Meeting(title: "From B")
        let beforeB = try eventNames()
        try await pass(b, "B", [onB, fromB])
        // The older engine's last pass: B's new conversation hadn't downloaded yet, and its result was never
        // acknowledged (the app quit while saving).
        let newConversation = try XCTUnwrap(try eventNames().subtracting(beforeB).first { name in
            let data = try Data(contentsOf: remote.appendingPathComponent("Events/\(name).json"))
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["meetingID"] as? String == fromB.id.uuidString
        })
        let aside = root.appendingPathComponent("aside.json"), withheld = remote.appendingPathComponent("Events/\(newConversation).json")
        try FileManager.default.moveItem(at: withheld, to: aside)
        var renamed = other; renamed.title = "Other, renamed on A"
        let unacknowledged = try await legacy.synchronize(meetings: [shared, renamed])
        XCTAssertEqual(unacknowledged.publishedEvents, 1)
        try await storeA.save(renamed)
        try FileManager.default.moveItem(at: aside, to: withheld)

        // Updated: the current engine continues from that state.
        let current = try engine("A")
        let result = try await pass(current, "A", [shared, renamed])
        XCTAssertEqual(result.publishedEvents, 0, "nothing the older engine published is published again")
        XCTAssertEqual(Set(result.meetings.map(\.title)), ["Shared", "Other, renamed on A", "From B"])
        XCTAssertEqual(result.meetings.first { $0.id == shared.id }?.notes, "Edited on B")
        XCTAssertFalse(result.meetings.contains { $0.revisions.contains { $0.field.hasPrefix("sync:") } })
        let libraryID = await current.libraryID
        let stem = LibrarySyncEngine.checkpointStem(libraryID: try XCTUnwrap(libraryID), deviceID: "A")
        let checkpoint = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: local("A").appendingPathComponent("Sync/\(stem).json"))) as? [String: Any])
        XCTAssertEqual((checkpoint["bases"] as? [String: Any])?.count, 0, "the bases moved into their own files")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local("A").appendingPathComponent("Sync/Bases/\(stem)").path).count, 3)
        let settled = try await current.synchronize(meetings: result.meetings)
        XCTAssertEqual(settled.publishedEvents, 0)
        XCTAssertTrue(settled.changedMeetingIDs.isEmpty)
        let onBAgain = try await pass(b, "B", [onB, fromB])
        XCTAssertEqual(onBAgain.meetings.first { $0.id == other.id }?.title, "Other, renamed on A")
    }

    func testAFreshDeviceWaitsForTheListingBeforeStartingALibrary() async throws {
        let fresh = try LibrarySyncEngine(localRoot: local("New Mac"), remoteRoot: remote, deviceID: "New Mac", waitsForListing: true)
        do { _ = try await fresh.synchronize(meetings: [Meeting(title: "Local")]); XCTFail("started a library before iCloud listed the folder") }
        catch LibrarySyncError.waitingForICloud { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("daybook-sync.json").path))
        XCTAssertTrue(try eventNames().isEmpty, "nothing published into a library that might not be the one")
        // Another device's library becomes visible: it's joined, not replaced.
        let other = try engine("Other")
        try await pass(other, "Other", [Meeting(title: "Shared")])
        let joined = try await fresh.synchronize(meetings: [])
        XCTAssertEqual(joined.meetings.map(\.title), ["Shared"])
        // With nothing there once iCloud has listed the folder, the device starts one.
        let elsewhere = root.appendingPathComponent("Empty")
        let first = try LibrarySyncEngine(localRoot: local("First Mac"), remoteRoot: elsewhere, deviceID: "First Mac", waitsForListing: true)
        await first.listingGathered()
        _ = try await first.synchronize(meetings: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("daybook-sync.json").path))
    }

    /// Two devices each started a library in the folder before seeing the other's, and iCloud kept both manifests
    /// (`daybook-sync 2.json`). Both settle on one identity and carry on from their own checkpoints.
    func testTwoManifestsResolveToOneLibraryWithoutPublishingAgain() async throws {
        let a = try engine("A")
        try await pass(a, "A", [Meeting(title: "From A")])
        let elsewhere = root.appendingPathComponent("B's view")
        let b = try LibrarySyncEngine(localRoot: local("B"), remoteRoot: elsewhere, deviceID: "B")
        let fromB = Meeting(title: "From B")
        let first = try await b.synchronize(meetings: [fromB])
        try await MeetingStore(rootURL: local("B")).save(fromB)
        try await b.acknowledge(first.checkpointID)
        // iCloud brings the two together: one journal, the second manifest renamed.
        let fm = FileManager.default
        for directory in ["Events", "Metadata", "Blobs"] {
            for name in try fm.contentsOfDirectory(atPath: elsewhere.appendingPathComponent(directory).path) {
                let target = remote.appendingPathComponent("\(directory)/\(name)")
                if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: elsewhere.appendingPathComponent("\(directory)/\(name)"), to: target) }
            }
        }
        try fm.copyItem(at: elsewhere.appendingPathComponent("daybook-sync.json"), to: remote.appendingPathComponent("daybook-sync 2.json"))
        let before = try eventNames()
        let onA = try await pass(a, "A")
        let rejoined = try engine("B")
        let onB = try await pass(rejoined, "B", [fromB])
        let idA = await a.libraryID, idB = await rejoined.libraryID
        XCTAssertEqual(idA, idB, "one library")
        XCTAssertEqual(try eventNames(), before, "nobody published again")
        XCTAssertEqual(onB.publishedEvents, 0)
        XCTAssertEqual(Set(onA.meetings.map(\.title)).union(onB.meetings.map(\.title)), ["From A", "From B"])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: remote.appendingPathComponent("daybook-sync.json"))) as? [String: Any])
        XCTAssertEqual((manifest["supersedes"] as? [String])?.count, 1)
    }

    func testAJournalFileStillSettlingIsReadAgainOnTheNextPass() async throws {
        let a = try engine("A"), b = try engine("B")
        try await pass(a, "A", [Meeting(title: "First")])
        try await pass(b, "B")
        // An entry whose bytes don't match its name yet (iCloud still writing it) is retried, not set aside.
        let meeting = Meeting(title: "Arriving")
        let event: [String: Any] = ["schemaVersion": 1, "meetingID": meeting.id.uuidString, "deviceID": "A", "sequence": 9,
                                    "parents": [String](), "snapshot": try object(meeting), "deleted": false, "assets": [Any]()]
        let bytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let name = SyncDigest.sha256(data: bytes)
        let url = remote.appendingPathComponent("Events/\(name).json")
        try Data(bytes.prefix(bytes.count / 2)).write(to: url)
        let partial = try await pass(b, "B")
        XCTAssertGreaterThan(partial.pendingDownloads, 0)
        XCTAssertFalse(partial.meetings.contains { $0.id == meeting.id })
        try bytes.write(to: url)
        let complete = try await pass(b, "B")
        XCTAssertTrue(complete.meetings.contains { $0.id == meeting.id }, "read again without relaunching")
        XCTAssertEqual(complete.pendingDownloads, 0)
    }
}
