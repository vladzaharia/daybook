import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// Container-first sync in `LibrarySyncController`: the container is resolved through a test environment
/// (no entitlement, account, or iCloud involved), a temporary folder stands in for it, and another one for
/// the folder a Mac synced through before.
@MainActor
final class LibrarySyncContainerTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var account: FakeAccount!
    private var controllers: [LibrarySyncController] = []
    private let fm = FileManager.default
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    private var folder: URL { root.appendingPathComponent("iCloud Drive/Daybook Sync", isDirectory: true) }
    private var containerURL: URL { root.appendingPathComponent("Container", isDirectory: true) }
    private var journal: URL { containerURL.appendingPathComponent("Documents/Daybook", isDirectory: true) }

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("DaybookContainer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: containerURL, withIntermediateDirectories: true)
        suite = "daybook.sync.container.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        defaults.set("Mac", forKey: "syncDeviceID")
        account = FakeAccount(identity: Data("account-a".utf8), container: containerURL)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
        try? fm.removeItem(at: root)
    }

    private func environment(identifier: String? = "iCloud.test.daybook", entitled: Bool = true, cloud: SyncCloudFiles = .system) -> SyncContainerEnvironment {
        let account = account!
        return SyncContainerEnvironment(containerIdentifier: identifier, hasEntitlement: { _ in entitled },
                                        accountIdentity: { account.identity }, accountSignedIn: { account.signedIn },
                                        resolveContainer: { _ in account.container }, cloud: cloud, retryInterval: .milliseconds(20))
    }

    private func controller(_ environment: SyncContainerEnvironment) -> LibrarySyncController {
        let controller = LibrarySyncController(localRoot: library, defaults: defaults, environment: environment)
        controllers.append(controller)
        return controller
    }

    private func wait(_ what: String, timeout: Duration = .seconds(10), until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A library that synced through `folder` as device "Mac", remembered with a bookmark as before.
    @discardableResult
    private func librarySyncedThroughFolder(cloud: SyncCloudFiles = .system) async throws -> Meeting {
        let file = root.appendingPathComponent("memo.wav")
        try Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: file)
        let meeting = try await MeetingStore(rootURL: library).importAudio(from: file, into: Meeting(title: "Kickoff"))
        let engine = try LibrarySyncEngine(localRoot: library, remoteRoot: folder, deviceID: "Mac", replica: SyncReplicaConfiguration(cloud: cloud))
        let result = try await engine.synchronize(meetings: [meeting])
        for item in result.meetings { try await MeetingStore(rootURL: library).save(item) }
        try await engine.acknowledge(result.checkpointID)
        defaults.set(try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "syncFolderBookmark")
        return try XCTUnwrap(result.meetings.first)
    }

    private func files(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in try XCTUnwrap(fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }

    func testBuildWithoutTheEntitlementKeepsSyncOffAndTheFolderTransportBehindTheDevelopmentDefault() async throws {
        try await librarySyncedThroughFolder()
        for environment in [environment(entitled: false), environment(identifier: nil), environment(identifier: "$(DAYBOOK_ICLOUD_CONTAINER)")] {
            let sync = controller(environment)
            XCTAssertEqual(sync.iCloud, .unavailableInThisBuild)
            sync.restore()
            XCTAssertEqual(sync.iCloud, .unavailableInThisBuild)
            XCTAssertEqual(sync.transport, .none); XCTAssertNil(sync.folder); XCTAssertFalse(sync.allowsFolderSync)
            XCTAssertEqual(sync.status, "iCloud sync isn’t available in this build")
        }
        XCTAssertNil(account.resolved, "No container is resolved without the entitlement")

        // The hidden development default brings back the chosen folder, and nothing moves to a container.
        defaults.set(true, forKey: LibrarySyncController.developmentFolderSyncKey)
        let development = controller(environment(entitled: false))
        XCTAssertTrue(development.allowsFolderSync)
        development.restore()
        XCTAssertEqual(development.transport, .folder)
        XCTAssertEqual(development.folder?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertNil(development.migrationRecord)
        XCTAssertFalse(fm.fileExists(atPath: journal.path))

        // A build signed for iCloud ignores the default.
        let signed = controller(environment())
        XCTAssertFalse(signed.allowsFolderSync)
    }

    func testEntitledBuildSyncsThroughTheContainerWithoutChoosingAFolder() async throws {
        let sync = controller(environment())
        XCTAssertEqual(sync.iCloud, .checking)
        sync.restore()
        try await wait("the container") { sync.iCloud == .connected }
        XCTAssertEqual(sync.transport, .iCloudContainer)
        XCTAssertEqual(sync.folder?.standardizedFileURL, journal.standardizedFileURL)
        XCTAssertNil(sync.migrationRecord, "Nothing to migrate without a previous folder")
        XCTAssertNil(defaults.data(forKey: "syncFolderBookmark"))
        // A new library starts only once iCloud has listed the container.
        try await wait("iCloud's listing") { sync.containerListed }
        let result = try await sync.synchronize(meetings: [], deletedMeetingIDs: [], metadata: JSONEncoder().encode(LibraryMetadata()))
        let receipt = try XCTUnwrap(result)
        try await sync.acknowledge(receipt)
        XCTAssertTrue(fm.fileExists(atPath: journal.appendingPathComponent("daybook-sync.json").path))

        // Turning sync off sticks across launches; turning it on reconnects.
        sync.disconnect()
        XCTAssertEqual(sync.iCloud, .turnedOff); XCTAssertNil(sync.folder)
        let relaunched = controller(environment())
        relaunched.restore()
        try await wait("the off state") { relaunched.iCloud == .turnedOff }
        relaunched.turnOnICloudSync()
        try await wait("reconnection") { relaunched.iCloud == .connected }
    }

    func testWaitForContainerReturnsOnceTheBackgroundLookupHasConnected() async throws {
        // A slow container lookup, as on a phone's first launch.
        let account = account!
        let slow = SyncContainerEnvironment(containerIdentifier: "iCloud.test.daybook", hasEntitlement: { _ in true },
                                            accountIdentity: { account.identity }, accountSignedIn: { account.signedIn },
                                            resolveContainer: { _ in Thread.sleep(forTimeInterval: 0.3); return account.container },
                                            retryInterval: .milliseconds(20))
        let sync = controller(slow)
        sync.replica = .phone(displayName: "Test iPhone")
        sync.restore()
        XCTAssertNil(sync.folder, "The lookup runs in the background, so the folder isn't known yet")
        await sync.waitForContainer()
        XCTAssertEqual(sync.iCloud, .connected)
        XCTAssertEqual(sync.folder?.standardizedFileURL, journal.standardizedFileURL)
        // Presence is written on attach, before any full pass, so other devices see this one at once.
        try await wait("the presence record") {
            ((try? fm.contentsOfDirectory(atPath: journal.appendingPathComponent("Devices").path)) ?? []).contains { $0.hasSuffix(".json") }
        }
    }

    func testSignedOutAndICloudDriveOffAreReportedPlainly() async throws {
        account.identity = nil
        account.signedIn = false
        let signedOut = controller(environment())
        signedOut.restore()
        try await wait("signed out") { signedOut.iCloud == .signedOut }
        XCTAssertEqual(signedOut.status, "Signed out of iCloud"); XCTAssertNil(signedOut.folder)

        account.signedIn = true
        let driveOff = controller(environment())
        driveOff.restore()
        try await wait("iCloud Drive off") { driveOff.iCloud == .iCloudDriveOff }
        XCTAssertEqual(driveOff.status, "iCloud is off in System Settings")

        account.identity = Data("account-a".utf8)
        account.container = nil
        let unavailable = controller(environment())
        unavailable.restore()
        try await wait("unavailable") { if case .containerUnavailable = unavailable.iCloud { return true } else { return false } }
        XCTAssertNil(unavailable.folder)
    }

    func testChosenFolderMovesToTheContainerOnceAndIsNeverConnectedAgain() async throws {
        try await librarySyncedThroughFolder()
        let before = try files(folder)
        let sync = controller(environment())
        sync.restore()
        try await wait("the move to iCloud") { sync.iCloud == .connected }
        XCTAssertEqual(sync.folder?.standardizedFileURL, journal.standardizedFileURL)
        let record = try XCTUnwrap(sync.migrationRecord)
        XCTAssertNotNil(record.switchedAt); XCTAssertNotNil(record.completedAt)
        XCTAssertEqual(record.copiedFiles, record.totalFiles); XCTAssertEqual(record.remainingFiles, 0)
        XCTAssertEqual(record.sourceLibraryID, record.containerLibraryID)
        XCTAssertEqual(try files(journal), before, "The journal arrives byte for byte")
        XCTAssertEqual(try files(folder), before, "The chosen folder is never modified")
        XCTAssertNil(defaults.data(forKey: "syncFolderBookmark"), "The old folder is never reconnected")
        XCTAssertNotNil(defaults.data(forKey: "syncMigratedFolderBookmark"))

        // Same checkpoint: the first pass in the container publishes nothing new.
        let stored = try await MeetingStore(rootURL: library).list()
        let synchronized = try await sync.synchronize(meetings: stored, deletedMeetingIDs: [], metadata: Data())
        let pass = try XCTUnwrap(synchronized)
        XCTAssertEqual(pass.publishedEvents, 1, "Only the library metadata, which the folder never had")
        XCTAssertEqual(pass.changedMeetingIDs, [])
        try await sync.acknowledge(pass)

        // The next launch goes straight to the container.
        sync.disconnect(); defaults.removeObject(forKey: "syncICloudTurnedOff")
        let relaunched = controller(environment())
        relaunched.restore()
        try await wait("reconnection") { relaunched.iCloud == .connected }
        XCTAssertEqual(relaunched.migrationRecord, record)
    }

    func testMigrationWaitsForICloudDownloadsThenSwitches() async throws {
        let cloud = PlaceholderCloud()
        try await librarySyncedThroughFolder()
        let event = try XCTUnwrap(try fm.contentsOfDirectory(at: folder.appendingPathComponent("Events"), includingPropertiesForKeys: nil).first)
        try cloud.evict(event)
        let sync = controller(environment(cloud: cloud.files))
        sync.restore()
        try await wait("a migration waiting for iCloud") {
            if case .migrating(let progress) = sync.iCloud { return progress.waitingJournal == 1 } else { return false }
        }
        XCTAssertTrue(sync.status.hasPrefix("Migrating "), sync.status)
        XCTAssertTrue(sync.status.contains("Waiting for iCloud to download 1."), sync.status)
        XCTAssertNil(sync.folder, "Sync waits for the journal before switching")
        try await wait("a download request") { !cloud.requests.isEmpty }
        try cloud.deliver(event)
        try await wait("the switch") { sync.iCloud == .connected }
        XCTAssertNotNil(sync.migrationRecord?.completedAt)
        XCTAssertTrue(fm.fileExists(atPath: journal.appendingPathComponent("Events/\(event.lastPathComponent)").path))
    }

    func testAccountChangePausesUntilThePersonChoosesTheNewAccount() async throws {
        let sync = controller(environment())
        sync.restore()
        try await wait("the container") { sync.iCloud == .connected }
        account.identity = Data("account-b".utf8)
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        try await wait("the pause") { sync.iCloud == .accountChanged }
        XCTAssertNil(sync.folder); XCTAssertEqual(sync.transport, .none)
        XCTAssertEqual(sync.status, "Sync paused: the iCloud account changed")
        // A relaunch stays paused too.
        let relaunched = controller(environment())
        relaunched.restore()
        try await wait("the pause after relaunch") { relaunched.iCloud == .accountChanged }
        relaunched.disconnect(); defaults.removeObject(forKey: "syncICloudTurnedOff")

        sync.useCurrentICloudAccount()
        try await wait("the new account") { sync.iCloud == .connected }
        // Signing out pauses as well.
        account.identity = nil; account.signedIn = false
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        try await wait("signed out") { sync.iCloud == .signedOut }
        XCTAssertNil(sync.folder)
    }

    func testAnAccountChangeDuringALongPassReconnectsOnceThePassUnwinds() async throws {
        let gate = SyncReadGate()
        defer { gate.release() }
        let sync = controller(environment())
        sync.replica.cloud = SyncCloudFiles(requestDownload: { _ in gate.waitForCancellation() }, isUploaded: { _ in true })
        sync.syncDebounce = nil
        sync.restore()
        try await wait("the container") { sync.iCloud == .connected && sync.containerListed }
        // A journal entry still in iCloud: the pass waits on its download, as it would copying a long recording.
        try fm.createDirectory(at: journal.appendingPathComponent("Events"), withIntermediateDirectories: true)
        try Data().write(to: journal.appendingPathComponent("Events/.\(String(repeating: "b", count: 64)).json.icloud"))
        let pass = Task { try? await sync.synchronize(meetings: [], deletedMeetingIDs: [], metadata: Data()) }
        try await wait("the pass to reach iCloud") { gate.entered }
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        // The same account comes back while the cancelled pass is still unwinding.
        try await Task.sleep(for: .milliseconds(200))
        gate.release()
        _ = await pass.value
        try await wait("sync to reconnect") { sync.iCloud == .connected && sync.folder != nil }
        XCTAssertFalse(sync.isSyncing)
    }

    func testCancellingAnActivePassReachesTheEngineAndLeavesItReadyToRetry() async throws {
        let meeting = try await librarySyncedThroughFolder()
        let event = try XCTUnwrap(try fm.contentsOfDirectory(at: folder.appendingPathComponent("Events"), includingPropertiesForKeys: nil).first)
        let cloud = PlaceholderCloud()
        try cloud.evict(event)
        let gate = SyncReadGate()
        defer { gate.release() }
        let sync = controller(environment())
        sync.replica.cloud = SyncCloudFiles(requestDownload: { _ in gate.waitForCancellation() }, isUploaded: { _ in true })
        try sync.connect(to: folder, monitorChanges: false)
        let pass = Task { try await sync.synchronize(meetings: [meeting], deletedMeetingIDs: [], metadata: Data()) }
        try await wait("an active cloud read") { gate.entered }
        pass.cancel()
        gate.release()
        do { _ = try await pass.value; XCTFail("The cancelled pass must not return a receipt") }
        catch is CancellationError { }
        XCTAssertTrue(gate.sawCancellation, "The engine task must receive its caller's cancellation")
        XCTAssertFalse(sync.isSyncing)
        try cloud.deliver(event)
        let next = try await sync.synchronize(meetings: [meeting], deletedMeetingIDs: [], metadata: Data())
        try await sync.acknowledge(XCTUnwrap(next))
        XCTAssertNotNil(sync.lastSync)
    }
}

/// Holds one synchronous cloud-provider read so the caller can cancel an already running pass.
private final class SyncReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var _entered = false
    private var _sawCancellation = false
    var entered: Bool { lock.withLock { _entered } }
    var sawCancellation: Bool { lock.withLock { _sawCancellation } }
    func release() { semaphore.signal() }
    func waitForCancellation() {
        lock.withLock { _entered = true }
        _ = semaphore.wait(timeout: .now() + 10)
        lock.withLock { _sawCancellation = Task.isCancelled }
    }
}

/// The test's iCloud account and container.
private final class FakeAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var _identity: Data?, _signedIn: Bool?, _container: URL?, _resolved: String?
    init(identity: Data?, container: URL?) { _identity = identity; _container = container }
    var identity: Data? { get { lock.withLock { _identity } } set { lock.withLock { _identity = newValue } } }
    var signedIn: Bool? { get { lock.withLock { _signedIn } } set { lock.withLock { _signedIn = newValue } } }
    var container: URL? {
        get { lock.withLock { _resolved = "yes"; return _container } }
        set { lock.withLock { _container = newValue } }
    }
    var resolved: String? { lock.withLock { _resolved } }
}

/// Evicts a file to an iCloud-style `.name.icloud` placeholder and delivers it when the test says so.
private final class PlaceholderCloud: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var _requests: [String] = []
    var requests: [String] { lock.withLock { _requests } }
    private static func placeholder(_ url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud") }
    func evict(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try Data().write(to: Self.placeholder(url))
        lock.withLock { stored[url.lastPathComponent] = data }
    }
    func deliver(_ url: URL) throws {
        guard let data = lock.withLock({ stored.removeValue(forKey: url.lastPathComponent) }) else { return }
        try data.write(to: url)
        try FileManager.default.removeItem(at: Self.placeholder(url))
    }
    var files: SyncCloudFiles {
        SyncCloudFiles(requestDownload: { [self] url in lock.withLock { _requests.append(url.path) } },
                       isUploaded: { FileManager.default.fileExists(atPath: $0.path) })
    }
}
