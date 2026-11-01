import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// `LibrarySyncController.status` is typed (`SyncStatus`): both apps read whether sync needs the person from its
/// `problem`, never from its words. Every way the controller can go wrong lands on a problem, so rewording a sentence
/// can't hide one.
@MainActor
final class SyncStatusTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var account: Account!
    private var controllers: [LibrarySyncController] = []
    private let fm = FileManager.default
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    private var folder: URL { root.appendingPathComponent("Previous Folder", isDirectory: true) }
    private var container: URL { root.appendingPathComponent("Container", isDirectory: true) }

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookSyncStatus")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        defaults = makeTestDefaults("daybook.sync.status")
        defaults.set("Mac", forKey: "syncDeviceID")
        account = Account(identity: Data("account-a".utf8), container: container)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    // MARK: Words

    /// Every case: a new one has to be added here, and say whether it needs the person.
    private static let everyStatus: [SyncStatus] = {
        var progress = SyncMigrationProgress()
        progress.total = 12; progress.completed = 5; progress.waitingForDownload = 1
        return [.off, .unavailableInThisBuild, .signedOut, .iCloudDriveOff, .connecting, .preparing, .deferred, .syncing, .applying,
                .waitingForICloud, .waitingForKey, .keyStoreUnreadable, .exchanged(uploads: 2, downloads: 1), .upToDate(at: Date()),
                .migrating(SyncMigrationProgress()), .migrating(progress), .migrationPaused(details: "No space left on device."),
                .storageFull, .accountChanged, .folderAccountChanged, .libraryRemoved, .newLibrary, .previousFolderMissing,
                .previousFolderAccessLost, .iCloudUnavailable(details: nil), .iCloudUnavailable(details: "CKErrorDomain 4"),
                .reconnectFolder(details: "The file couldn’t be opened."), .couldNotUseFolder(details: "Choose another folder."),
                .failure(details: "The operation couldn’t be completed.")]
    }()

    func testEveryStatusThatReadsAsTroubleIsAProblemWithASentence() {
        for status in Self.everyStatus {
            XCTAssertFalse(status.text.isEmpty)
            XCTAssertFalse(status.shortText.isEmpty)
            let text = status.text
            let readsAsTrouble = text.hasPrefix("Sync paused") || text.hasPrefix("Couldn") || text.hasPrefix("Reconnect")
                || text.hasPrefix("Apple Account") || text.contains("paused") || text.contains("isn’t available for")
            XCTAssertEqual(status.problem != nil, readsAsTrouble, "\(status): \(text)")
            if let problem = status.problem {
                XCTAssertTrue(problem.text.hasSuffix(".") || problem.text.contains("·"), problem.text)
                XCTAssertNotEqual(problem.details, "", "No empty Details")
            }
        }
    }

    func testWorkingAndWaitingAreNeverProblems() {
        for status in [SyncStatus.syncing, .applying, .connecting, .preparing, .deferred, .waitingForICloud, .waitingForKey,
                       .keyStoreUnreadable, .migrating(SyncMigrationProgress()), .exchanged(uploads: 1, downloads: 0)] {
            XCTAssertNil(status.problem, status.text)
        }
        XCTAssertTrue(SyncStatus.syncing.isPassRunning)
        XCTAssertTrue(SyncStatus.applying.isPassRunning)
        XCTAssertFalse(SyncStatus.upToDate(at: Date()).isPassRunning)
        XCTAssertEqual(SyncStatus.exchanged(uploads: 1, downloads: 3).shortText, "Uploading 1 item to iCloud")
        XCTAssertEqual(SyncStatus.exchanged(uploads: 0, downloads: 3).shortText, "Waiting for iCloud to download 3 items…")
    }

    func testAProblemKeepsTheSystemsWordsForDetails() {
        XCTAssertEqual(SyncStatus.failure(details: "No space left on device.").problem?.details, "No space left on device.")
        XCTAssertEqual(SyncStatus.migrationPaused(details: "Disk full").problem, .migrationPaused(details: "Disk full"))
        XCTAssertNil(SyncStatus.accountChanged.problem?.details, "Daybook's own reason needs no Details")
        XCTAssertEqual(SyncStatus.iCloudUnavailable(details: nil).problem?.text, "Couldn’t connect to iCloud.")
    }

    // MARK: Every error path the controller has

    func testAFailedPassIsAProblem() async throws {
        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("not a manifest".utf8).write(to: journal.appendingPathComponent("daybook-sync.json"))
        let sync = controller(environment(entitled: false))
        sync.syncDebounce = nil
        try sync.connect(to: journal, monitorChanges: false)
        XCTAssertEqual(sync.status, .preparing)
        do {
            _ = try await sync.synchronize(meetings: [], deletedMeetingIDs: [], metadata: Data())
            XCTFail("A damaged manifest fails the pass")
        } catch {}
        guard case .failure(let details)? = sync.status.problem else { return XCTFail(sync.statusText) }
        XCTAssertFalse(details.isEmpty)

        sync.reportFailure("The library couldn’t be saved.")
        XCTAssertEqual(sync.status.problem, .failure(details: "The library couldn’t be saved."))
    }

    func testICloudThatCantBeReachedIsAProblem() async throws {
        account.container = nil
        let sync = controller(environment())
        sync.restore()
        await sync.waitForContainer()
        XCTAssertEqual(sync.status.problem, .iCloudUnavailable(details: nil), sync.statusText)
    }

    func testAnotherAccountIsAProblem() async throws {
        let sync = controller(environment())
        sync.restore()
        await sync.waitForContainer()
        XCTAssertEqual(sync.iCloud, .connected)
        XCTAssertNil(sync.status.problem, sync.statusText)
        account.identity = Data("account-b".utf8)
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        try await waitUntil("the pause", state: { sync.statusText }) { sync.iCloud == .accountChanged }
        XCTAssertEqual(sync.status.problem, .accountChanged)
    }

    func testAPreviousFolderThatsGoneOrClosedIsAProblem() async throws {
        try rememberPreviousFolder()
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        let closed = controller(environment())
        closed.restore()
        await closed.waitForContainer()
        XCTAssertEqual(closed.status.problem, .previousFolderAccessLost, closed.statusText)

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try fm.removeItem(at: folder)
        let gone = controller(environment())
        gone.restore()
        await gone.waitForContainer()
        XCTAssertEqual(gone.status.problem, .previousFolderMissing, gone.statusText)
    }

    func testAMoveToICloudThatStopsIsAProblemUntilItMovesAgain() async throws {
        try rememberPreviousFolder()
        try Data("not a manifest".utf8).write(to: folder.appendingPathComponent("daybook-sync.json"))
        let sync = controller(environment())
        sync.restore()
        let details = try await waitFor("the paused move", state: { sync.statusText }) { () -> String? in
            if case .migrationPaused(let details)? = sync.status.problem { return details } else { return nil }
        }
        XCTAssertFalse(details.isEmpty)
        guard case .migrating = sync.iCloud else { return XCTFail("Still moving: it tries again on its own") }

        // The folder is readable again: the next try moves sync, and the pause goes.
        try fm.removeItem(at: folder.appendingPathComponent("daybook-sync.json"))
        try await waitUntil("the switch", state: { sync.statusText }) { sync.iCloud == .connected }
        XCTAssertNil(sync.status.problem, sync.statusText)
    }

    func testAFolderThatCantBeUsedIsAProblem() async throws {
        defaults.set(true, forKey: LibrarySyncController.developmentFolderSyncKey)
        defaults.set(Data("not a bookmark".utf8), forKey: "syncFolderBookmark")
        let restored = controller(environment(entitled: false))
        restored.restore()
        guard case .reconnectFolder? = restored.status.problem else { return XCTFail(restored.statusText) }

        let chosen = controller(environment(entitled: false))
        chosen.connectChosenFolder(library)
        guard case .couldNotUseFolder? = chosen.status.problem else { return XCTFail(chosen.statusText) }
    }

    func testAnAccountChangeUnderAChosenFolderIsAProblem() async throws {
        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        let sync = controller(environment(entitled: false))
        sync.syncDebounce = nil
        try sync.connect(to: journal, monitorChanges: true)
        account.identity = Data("account-b".utf8)
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        try await waitUntil("the pause", state: { sync.statusText }) { sync.folder == nil }
        XCTAssertEqual(sync.status.problem, .folderAccountChanged)
    }

    // MARK: Helpers

    private func environment(entitled: Bool = true) -> SyncContainerEnvironment {
        let account = account!
        return SyncContainerEnvironment(containerIdentifier: "iCloud.test.daybook", hasEntitlement: { _ in entitled },
                                        accountIdentity: { account.identity }, accountSignedIn: { true },
                                        resolveContainer: { _ in account.container }, retryInterval: .milliseconds(20))
    }

    private func controller(_ environment: SyncContainerEnvironment) -> LibrarySyncController {
        let controller = LibrarySyncController(localRoot: library, defaults: defaults, environment: environment, identityStore: .unavailable)
        controllers.append(controller)
        return controller
    }

    /// A folder this Mac synced through before the container, remembered with a bookmark as earlier builds did.
    private func rememberPreviousFolder() throws {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "syncFolderBookmark")
    }
}

/// The test's iCloud account and container.
private final class Account: @unchecked Sendable {
    private let lock = NSLock()
    private var _identity: Data?, _container: URL?
    init(identity: Data?, container: URL?) { _identity = identity; _container = container }
    var identity: Data? { get { lock.withLock { _identity } } set { lock.withLock { _identity = newValue } } }
    var container: URL? { get { lock.withLock { _container } } set { lock.withLock { _container = newValue } } }
}
