import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// This device's sync identity: kept on this device, moved there unchanged from preferences, never shared by a Mac
/// whose preferences and library were copied from another, and given up by one of two devices found sharing it.
/// The keychain is replaced by in-memory stores; nothing touches the real one.
@MainActor
final class SyncDeviceIdentityTests: XCTestCase {
    private var root: URL!
    private var controllers: [LibrarySyncController] = []
    private var container: URL { root.appendingPathComponent("Container", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
        try? FileManager.default.removeItem(at: root)
    }

    private func defaults() throws -> UserDefaults {
        makeTestDefaults("daybook.sync.identity")
    }

    private func controller(_ library: URL, _ defaults: UserDefaults, _ store: SyncDeviceIdentityStore) -> LibrarySyncController {
        let controller = LibrarySyncController(localRoot: library, defaults: defaults, identityStore: store)
        controller.replica = .mac(displayName: "Mac", canProcess: true)
        controller.syncDebounce = nil
        controllers.append(controller)
        return controller
    }

    func testTheIdentityInPreferencesMovesToThisDeviceUnchanged() throws {
        let preferences = try defaults()
        preferences.set("existing-mac", forKey: "syncDeviceID")
        let store = SyncDeviceIdentityStore.memory()
        let sync = controller(root.appendingPathComponent("Library"), preferences, store)
        XCTAssertEqual(sync.deviceID, "existing-mac")
        XCTAssertEqual(store.read()?.deviceID, "existing-mac")
        // Relaunched: the same identity, installation included.
        let again = controller(root.appendingPathComponent("Library"), preferences, store)
        XCTAssertEqual(again.deviceID, "existing-mac")
        XCTAssertEqual(again.installation, sync.installation)
        // Without a keychain (unsigned builds, tests), preferences keep it as before.
        let unsigned = try defaults()
        unsigned.set("dev-mac", forKey: "syncDeviceID")
        XCTAssertEqual(controller(root.appendingPathComponent("Dev"), unsigned, .unavailable).deviceID, "dev-mac")
    }

    func testAMacWhosePreferencesWereCopiedTakesANewIdentityAndKeepsItsPlace() async throws {
        let library = root.appendingPathComponent("Library")
        let original = try defaults()
        let originalStore = SyncDeviceIdentityStore.memory()
        let first = controller(library, original, originalStore)
        try first.connect(to: container, monitorChanges: false)
        let model = LibraryController(rootURL: library, sync: first)
        try await model.load()
        model.newMeeting(title: "Before the move")
        await model.flush()
        let applied = await model.synchronize()
        XCTAssertEqual(applied?.acknowledged, true)
        first.disconnect()

        // Migration Assistant copies the preferences and the library, but not this device's keychain item.
        let copied = try defaults()
        for (key, value) in original.dictionaryRepresentation() where key.hasPrefix("sync") { copied.set(value, forKey: key) }
        let moved = controller(library, copied, .memory())
        XCTAssertNotEqual(moved.deviceID, first.deviceID, "two Macs never share an identity")
        XCTAssertNotEqual(moved.installation, first.installation)
        try moved.connect(to: container, monitorChanges: false)
        let movedModel = LibraryController(rootURL: library, sync: moved)
        try await movedModel.load()
        let after = await movedModel.synchronize()
        XCTAssertEqual(after?.acknowledged, true)
        XCTAssertEqual(after?.published, 0, "it continues from the same place instead of publishing everything again")
    }

    func testOfTwoDevicesSharingAnIdentityOneTakesANewOne() async throws {
        // Both were cloned before identities moved to the keychain: same device ID, different installations.
        let sharedA = SyncDeviceIdentityStore.memory(StoredSyncIdentity(deviceID: "cloned", installation: "a-installation"))
        let sharedB = SyncDeviceIdentityStore.memory(StoredSyncIdentity(deviceID: "cloned", installation: "b-installation"))
        let a = controller(root.appendingPathComponent("A"), try defaults(), sharedA)
        let b = controller(root.appendingPathComponent("B"), try defaults(), sharedB)
        let libraryA = LibraryController(rootURL: root.appendingPathComponent("A"), sync: a)
        let libraryB = LibraryController(rootURL: root.appendingPathComponent("B"), sync: b)
        try await libraryA.load(); try await libraryB.load()
        try a.connect(to: container, monitorChanges: false); try b.connect(to: container, monitorChanges: false)
        for library in [libraryA, libraryB, libraryA] {
            let applied = await library.synchronize()
            XCTAssertEqual(applied?.acknowledged, true)
        }
        XCTAssertEqual(a.deviceID, "cloned", "the smaller installation keeps the identity")
        XCTAssertNotEqual(b.deviceID, "cloned", "the other takes a new one")
        XCTAssertEqual(sharedB.read()?.deviceID, b.deviceID)
        XCTAssertNotNil(b.folder, "and syncs on with it")
        let applied = await libraryB.synchronize()
        XCTAssertEqual(applied?.acknowledged, true)
        let devices = await a.knownDevices()
        XCTAssertTrue(devices.contains { $0.id == b.deviceID })
    }
}
