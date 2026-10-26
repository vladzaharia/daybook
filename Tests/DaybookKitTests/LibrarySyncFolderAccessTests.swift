import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The folder a Mac synced through before the iCloud container, when this build can't open it any more (in the App
/// Sandbox a bookmark made before can stop working): sync says so, and the folder can be chosen again.
@MainActor
final class LibrarySyncFolderAccessTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var controller: LibrarySyncController?
    private let fm = FileManager.default
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    private var folder: URL { root.appendingPathComponent("iCloud Drive/Daybook Sync", isDirectory: true) }
    private var container: URL { root.appendingPathComponent("Container", isDirectory: true) }

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("DaybookFolderAccess-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: root.appendingPathComponent("Preferences").path)
        defaults.set("Mac", forKey: "syncDeviceID")
    }

    override func tearDown() async throws {
        controller?.reportFailure("Test cleanup"); controller?.disconnect()
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? fm.removeItem(at: root)
    }

    func testAFolderThatCantBeOpenedAsksToBeChosenAgain() async throws {
        try await librarySyncedThroughFolder()
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        let sync = makeController()
        sync.restore()
        try await wait("access lost") { if case .previousFolderAccessLost = sync.iCloud { return true }; return false }
        guard case .previousFolderAccessLost(let location) = sync.iCloud else { return XCTFail() }
        XCTAssertEqual(location?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertNil(sync.folder)

        // Chosen again (here, readable again): the move to iCloud goes ahead, and the folder is retired.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        sync.regrantPreviousFolder(folder)
        try await wait("the container") { sync.iCloud == .connected }
        XCTAssertNotNil(sync.migrationRecord?.switchedAt)
        XCTAssertNil(defaults.data(forKey: "syncFolderBookmark"))
    }

    func testAFolderThatIsGoneIsStillMissing() async throws {
        try await librarySyncedThroughFolder()
        try fm.removeItem(at: folder)
        let sync = makeController()
        sync.restore()
        try await wait("missing") { sync.iCloud == .previousFolderMissing }
    }

    // MARK: Helpers

    private func makeController() -> LibrarySyncController {
        let container = self.container
        let environment = SyncContainerEnvironment(containerIdentifier: "iCloud.test.daybook", hasEntitlement: { _ in true },
                                                   accountIdentity: { Data("account-a".utf8) }, accountSignedIn: { true },
                                                   resolveContainer: { _ in container }, retryInterval: .milliseconds(20))
        let sync = LibrarySyncController(localRoot: library, defaults: defaults, environment: environment, identityStore: .unavailable)
        controller = sync
        return sync
    }

    /// A library that synced through `folder` as device "Mac", remembered with a bookmark as earlier builds did.
    private func librarySyncedThroughFolder() async throws {
        let file = root.appendingPathComponent("memo.wav")
        try Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: file)
        let meeting = try await MeetingStore(rootURL: library).importAudio(from: file, into: Meeting(title: "Kickoff"))
        let engine = try LibrarySyncEngine(localRoot: library, remoteRoot: folder, deviceID: "Mac")
        let result = try await engine.synchronize(meetings: [meeting])
        for item in result.meetings { try await MeetingStore(rootURL: library).save(item) }
        try await engine.acknowledge(result.checkpointID)
        defaults.set(try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "syncFolderBookmark")
    }

    private func wait(_ what: String, timeout: Duration = .seconds(10), until condition: () -> Bool) async throws {
        let scale = Double(ProcessInfo.processInfo.environment["DAYBOOK_TEST_TIMEOUT_SCALE"] ?? "") ?? 1
        let deadline = ContinuousClock.now + timeout * scale
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for \(what): \(controller.map { "\($0.iCloud)" } ?? "")") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
