import DaybookCore
@testable import DaybookKit
import XCTest
@testable import Daybook

@MainActor
final class SyncReviewTests: XCTestCase {
    func testIdleExchangeDoesNotRewriteLibraryOrScheduleAnotherExchange() async throws {
        let root = try makeRoot()
        let suite = "daybook.sync.review.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let local = root.appendingPathComponent("Local")
        let state = AppState(libraryURL: local, defaults: defaults)
        defer {
            state.sync.disconnect()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await state.initialize()
        let id = state.newMeeting(title: "Unchanged conversation")
        state.saveFolder(LibraryFolder(name: "Unchanged folder"))
        await state.flush()
        try state.sync.connect(to: root.appendingPathComponent("Remote"), monitorChanges: false)
        var scheduled = 0
        state.sync.onSyncRequested = { scheduled += 1 }
        await state.synchronizeLibrary()
        XCTAssertFalse(state.sync.status.contains("paused"), state.sync.status)
        let meetingURL = local.appendingPathComponent("Meetings/\(id)/meeting.json")
        let metadataURL = local.appendingPathComponent("library.json")
        let meetingDate = try meetingURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let metadataDate = try metadataURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        await state.synchronizeLibrary()
        XCTAssertEqual(try meetingURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, meetingDate)
        XCTAssertEqual(try metadataURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, metadataDate)
        // Longer than the controller's two-second edit debounce; no microphone or cloud account needed.
        try await Task.sleep(for: .milliseconds(2_250))
        XCTAssertEqual(scheduled, 0, "Applying unchanged remote data must not create a perpetual sync loop")
    }

    func testSyncConfigurationRemainsLockedUntilDurableAcknowledgement() async throws {
        let root = try makeRoot()
        let suite = "daybook.sync.review.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let controller = LibrarySyncController(localRoot: root.appendingPathComponent("Local"), defaults: defaults)
        defer {
            controller.reportFailure("Test cleanup"); controller.disconnect()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let remote = root.appendingPathComponent("Remote")
        try controller.connect(to: remote, monitorChanges: false)
        let result = try await controller.synchronize(meetings: [], deletedMeetingIDs: [], metadata: JSONEncoder().encode(LibraryMetadata()))
        let receipt = try XCTUnwrap(result)
        XCTAssertTrue(controller.isSyncing)
        XCTAssertTrue(controller.canApply(receipt))
        controller.disconnect()
        XCTAssertEqual(controller.folder, remote)
        XCTAssertThrowsError(try controller.connect(to: root.appendingPathComponent("Other"), monitorChanges: false))
        try await controller.acknowledge(receipt)
        XCTAssertFalse(controller.isSyncing)
        XCTAssertFalse(controller.canApply(receipt))
        controller.disconnect()
        XCTAssertNil(controller.folder)
    }

    func testAccountChangeInvalidatesPendingReceiptAndAllowsExplicitReconnect() async throws {
        let root = try makeRoot()
        let suite = "daybook.sync.review.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let controller = LibrarySyncController(localRoot: root.appendingPathComponent("Local"), defaults: defaults)
        defer {
            controller.reportFailure("Test cleanup"); controller.disconnect()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try controller.connect(to: root.appendingPathComponent("Remote"))
        let result = try await controller.synchronize(meetings: [], deletedMeetingIDs: [], metadata: JSONEncoder().encode(LibraryMetadata()))
        let receipt = try XCTUnwrap(result)
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        for _ in 0..<30 where controller.folder != nil { await Task.yield() }
        XCTAssertNil(controller.folder)
        XCTAssertFalse(controller.canApply(receipt))
        XCTAssertFalse(controller.isSyncing)
        XCTAssertNil(defaults.data(forKey: "syncFolderBookmark"))
        let other = root.appendingPathComponent("Other")
        try controller.connect(to: other, monitorChanges: false)
        XCTAssertEqual(controller.folder, other)
        do { try await controller.acknowledge(receipt); XCTFail("An old account's receipt must not acknowledge the new library") }
        catch { }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSyncReview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
