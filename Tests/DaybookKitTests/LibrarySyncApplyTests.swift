import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// `LibraryController.synchronize`: applying a pass to a library, with two libraries sharing a temporary
/// folder that stands in for the iCloud container. No iCloud account, CloudKit, or network.
@MainActor
final class LibrarySyncApplyTests: XCTestCase {
    private var root: URL!
    private var suites: [String] = []
    private var controllers: [LibrarySyncController] = []
    private var container: URL { root.appendingPathComponent("Container", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSyncApply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: root)
    }

    /// A library connected to the shared folder. Passes run only when a test asks.
    private func library(_ name: String, phone: Bool = false) async throws -> LibraryController {
        let libraryRoot = root.appendingPathComponent(name, isDirectory: true)
        let suite = "daybook.apply.\(UUID())"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(name, forKey: "syncDeviceID")
        let sync = LibrarySyncController(localRoot: libraryRoot, defaults: defaults)
        controllers.append(sync)
        sync.replica = phone ? .phone(displayName: name) : .mac(displayName: name, canProcess: true)
        let library = LibraryController(rootURL: libraryRoot, sync: sync)
        try await library.load()
        try sync.connect(to: container, monitorChanges: false)
        return library
    }

    @discardableResult
    private func sync(_ library: LibraryController, protecting: UUID? = nil, file: StaticString = #filePath, line: UInt = #line) async -> SyncApplied? {
        let applied = await library.synchronize(protecting: protecting)
        XCTAssertEqual(applied?.acknowledged, true, library.sync?.status ?? "", file: file, line: line)
        return applied
    }

    func testLibrarySettingsThisVersionCantReadDoNotStopThePass() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        mac.createFolder(named: "Research")
        await mac.flush()
        await sync(mac)
        // A newer Daybook's settings that don't decode as this version's.
        let metadata = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent("Metadata").path).first)
        let record: [String: Any] = ["schemaVersion": 1, "deviceID": "Future", "sequence": 9, "parents": [String(metadata.dropLast(5))],
                                     "data": Data(#"{"schemaVersion":1,"folders":"not a list"}"#.utf8).base64EncodedString()]
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try bytes.write(to: container.appendingPathComponent("Metadata/\(AudioDigest.sha256(data: bytes)).json"))
        mac.createFolder(named: "Later")
        await mac.flush()
        await sync(mac)
        await sync(phone)
        XCTAssertEqual(Set(phone.folders.map(\.name)), ["Research", "Later"])
        XCTAssertTrue(phone.notice?.contains("newer version of Daybook") == true)
        await sync(phone)
    }

    func testARecordingIntoAConversationDeletedOnTheMacIsKeptOnThePhone() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        let id = phone.newMeeting(title: "Walk and talk")
        await phone.flush()
        await sync(phone); await sync(mac)
        XCTAssertNotNil(mac.meeting(id))
        _ = try await mac.moveToTrash(id)
        await sync(mac)
        // The phone records into it meanwhile; the pass during the recording leaves it alone.
        let file = root.appendingPathComponent("phone.m4a")
        try Data("phone recording".utf8).write(to: file)
        await phone.acquireLock()
        _ = try await phone.ingest(file, into: id, provenance: .file(source: .microphone))
        phone.releaseLock()
        await sync(phone, protecting: id)
        XCTAssertNotNil(phone.meeting(id))
        // After it, the recording is kept as a new conversation and the deleted one goes to the Trash.
        await sync(phone)
        XCTAssertNil(phone.meeting(id))
        XCTAssertTrue(phone.trashedMeetingIDs().contains(id))
        let kept = try XCTUnwrap(phone.meetings.first)
        XCTAssertEqual(kept.title, "Walk and talk")
        XCTAssertEqual(kept.tracks.count, 1)
        XCTAssertTrue(phone.notice?.contains("kept as a new conversation") == true)
        await sync(phone)
        await sync(mac)
        XCTAssertEqual(mac.meeting(kept.id)?.tracks.map(\.sha256), kept.tracks.map(\.sha256))
        XCTAssertNil(mac.meeting(id))
    }

    func testRestoringAConversationWhoseDeletionSyncedBringsItBackAsANewOne() async throws {
        let mac = try await library("Mac"), other = try await library("Other Mac")
        let id = mac.newMeeting(title: "Budget")
        mac.editNotes(id, text: "Line items")
        let file = root.appendingPathComponent("budget.wav")
        try Data("budget audio".utf8).write(to: file)
        await mac.acquireLock()
        _ = try await mac.ingest(file, into: id, provenance: .file(source: .imported))
        mac.releaseLock()
        await mac.flush()
        await sync(mac); await sync(other)
        _ = try await mac.moveToTrash(id)
        await sync(mac); await sync(other)
        XCTAssertNil(other.meeting(id))

        // With sync off, as before; turning it back on must not take it away again.
        mac.sync?.disconnect()
        let restored = try await mac.restoreFromTrash(id)
        XCTAssertNotEqual(restored.id, id, "the deleted ID stays deleted; the conversation comes back as a new one")
        XCTAssertEqual(restored.notes, "Line items")
        XCTAssertEqual(restored.tracks.count, 1)
        XCTAssertTrue(restored.revisions.contains { $0.field.hasPrefix("source:restored") })
        XCTAssertFalse(mac.trashedMeetingIDs().contains(id))
        let audio = try await mac.audioURL(for: restored.tracks[0], in: restored.id)
        XCTAssertEqual(try Data(contentsOf: audio), Data("budget audio".utf8))

        try mac.sync?.connect(to: container, monitorChanges: false)
        await sync(mac)
        XCTAssertNotNil(mac.meeting(restored.id), "turning sync on again doesn't move it back to the Trash")
        await sync(other)
        XCTAssertEqual(other.meeting(restored.id)?.notes, "Line items")
        XCTAssertNil(other.meeting(id))

        // Restoring one whose deletion hasn't synced yet keeps its ID.
        let fresh = mac.newMeeting(title: "Never synced")
        await mac.flush()
        _ = try await mac.moveToTrash(fresh)
        let back = try await mac.restoreFromTrash(fresh)
        XCTAssertEqual(back.id, fresh)
    }
}
