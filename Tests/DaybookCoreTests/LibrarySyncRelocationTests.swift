import XCTest
@testable import DaybookCore

/// A library that moves (into the App Sandbox's container, or back) can briefly run empty under its device ID, or lose
/// its device ID. Neither may read as deleting anything: deletions are only ever explicit.
final class LibrarySyncRelocationTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("Remote", isDirectory: true) }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    private func engine(_ name: String, deviceID: String) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: deviceID)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookRelocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAnEmptyLibraryUnderAKnownDeviceIDPublishesNoDeletions() async throws {
        let (published, phone) = try await macAndPhoneSharingTwoConversations()
        // The library's new place is empty (no conversations, no checkpoint), but the Mac kept its device ID.
        let moved = try engine("Container", deviceID: "mac")
        let pass = try await moved.synchronize(meetings: [])
        XCTAssertTrue(pass.deletedMeetingIDs.isEmpty)
        XCTAssertEqual(Set(pass.meetings.map(\.id)), Set(published.map(\.id)), "everything is offered back")
        try await apply(pass, to: "Container", using: moved)

        XCTAssertEqual(try deletionEvents(), 0)
        let phonePass = try await phone.synchronize(meetings: published)
        XCTAssertTrue(phonePass.deletedMeetingIDs.isEmpty)
        XCTAssertEqual(Set(phonePass.meetings.map(\.id)), Set(published.map(\.id)))
    }

    func testALostDeviceIDRepublishesTheLibraryWithoutDeletingAnything() async throws {
        let (published, phone) = try await macAndPhoneSharingTwoConversations()
        let eventsBefore = try eventCount()
        // The same library, but its device ID is gone (preferences lost): it syncs under a new one, with no checkpoint.
        let renamed = try engine("Mac", deviceID: "mac-new")
        let pass = try await renamed.synchronize(meetings: published)
        XCTAssertTrue(pass.deletedMeetingIDs.isEmpty)
        XCTAssertTrue(pass.warnings.isEmpty, pass.warnings.joined(separator: "\n"))
        XCTAssertEqual(pass.publishedEvents, published.count, "each conversation is published again under the new ID")
        try await apply(pass, to: "Mac", using: renamed)

        XCTAssertEqual(try deletionEvents(), 0)
        XCTAssertEqual(try eventCount(), eventsBefore + published.count)
        let phonePass = try await phone.synchronize(meetings: published)
        XCTAssertTrue(phonePass.deletedMeetingIDs.isEmpty)
        XCTAssertTrue(phonePass.warnings.isEmpty, phonePass.warnings.joined(separator: "\n"))
        for meeting in published {
            let merged = try XCTUnwrap(phonePass.meetings.first { $0.id == meeting.id } ?? published.first { $0.id == meeting.id })
            XCTAssertEqual(merged.title, meeting.title)
            XCTAssertEqual(merged.notes, meeting.notes)
            XCTAssertFalse(merged.revisions.contains { $0.field.hasPrefix("sync:") }, "the same content is no conflict")
        }
    }

    // MARK: Helpers

    /// A Mac that published two conversations and a phone that applied them.
    private func macAndPhoneSharingTwoConversations() async throws -> ([Meeting], LibrarySyncEngine) {
        let mac = try engine("Mac", deviceID: "mac")
        let first = try await mac.synchronize(meetings: [Meeting(title: "Planning", notes: "Ship Friday"), Meeting(title: "Retro", notes: "Fewer meetings")])
        try await apply(first, to: "Mac", using: mac)
        let published = try await MeetingStore(rootURL: local("Mac")).list()
        XCTAssertEqual(published.count, 2)
        let phone = try engine("Phone", deviceID: "phone")
        let pulled = try await phone.synchronize(meetings: [])
        XCTAssertEqual(pulled.meetings.count, 2)
        try await apply(pulled, to: "Phone", using: phone)
        return (published, phone)
    }

    private func apply(_ result: SyncResult, to name: String, using engine: LibrarySyncEngine) async throws {
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        try await engine.acknowledge(result.checkpointID)
    }

    private func events() throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: remote.appendingPathComponent("Events"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any]) }
    }
    private func eventCount() throws -> Int { try events().count }
    private func deletionEvents() throws -> Int { try events().filter { $0["deleted"] as? Bool == true }.count }
}
