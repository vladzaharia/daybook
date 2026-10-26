import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// This Mac's sync and link identity follows its library when the library moves (into the App Sandbox's container, or
/// back out), and never follows a library to another Mac.
@MainActor
final class ReplicaIdentityTests: XCTestCase {
    private var root: URL!
    /// One keychain item per library folder, as `SyncDeviceIdentityStore.keychain(for:)` keeps them.
    private var keychain = KeychainItems()
    private let machine = ReplicaIdentity.machineDigest("A3B4C5D6-0000-4000-8000-000000000001")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookReplicaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAMovedLibraryKeepsItsIdentityWhenPreferencesStayedBehind() throws {
        let (identity, old) = try establishedLibrary()
        let moved = try move(old, to: "Container/Daybook")

        let defaults = makeTestDefaults()      // the container's preferences: empty
        XCTAssertEqual(restore(moved, defaults: defaults), .restored(deviceID: identity.deviceID))

        let sync = LibrarySyncController(localRoot: moved, defaults: defaults, identityStore: keychain.store(for: moved))
        XCTAssertEqual(sync.deviceID, identity.deviceID)
        XCTAssertEqual(sync.installation, identity.installation)
        XCTAssertEqual(AppState.linkIdentity(sync: sync, defaults: defaults).deviceID.uuidString, identity.deviceID)
    }

    /// Preferences that moved say the identity is in the keychain, but the keychain item is under the old folder's
    /// name: without the replica, that reads as preferences copied from another Mac, and a new ID.
    func testAMovedLibraryKeepsItsIdentityWhenPreferencesCameAlong() throws {
        let (identity, old) = try establishedLibrary()
        let moved = try move(old, to: "Container/Daybook")
        let defaults = makeTestDefaults()
        defaults.set(identity.deviceID, forKey: ReplicaIdentity.Key.deviceID)
        defaults.set(true, forKey: ReplicaIdentity.Key.identityStored)

        restore(moved, defaults: defaults)

        let sync = LibrarySyncController(localRoot: moved, defaults: defaults, identityStore: keychain.store(for: moved))
        XCTAssertEqual(sync.deviceID, identity.deviceID)
    }

    func testWithoutAKeychainThePreferencesHoldTheRestoredIdentity() throws {
        let (identity, old) = try establishedLibrary()
        let moved = try move(old, to: "Container/Daybook")
        let defaults = makeTestDefaults()
        defaults.set(true, forKey: ReplicaIdentity.Key.identityStored)

        ReplicaIdentity.restore(library: moved, defaults: defaults, machine: machine, store: { _ in .unavailable })

        XCTAssertFalse(defaults.bool(forKey: ReplicaIdentity.Key.identityStored))
        let sync = LibrarySyncController(localRoot: moved, defaults: defaults, identityStore: .unavailable)
        XCTAssertEqual(sync.deviceID, identity.deviceID)
        XCTAssertEqual(sync.installation, identity.installation)
    }

    func testALibraryCopiedToAnotherMacDoesNotBringThisMacsIdentity() throws {
        let (identity, old) = try establishedLibrary()
        let copied = try move(old, to: "Other Mac/Daybook")
        let defaults = makeTestDefaults()

        let result = ReplicaIdentity.restore(library: copied, defaults: defaults, machine: ReplicaIdentity.machineDigest("ANOTHER-MAC"),
                                             store: keychain.store(for:))
        XCTAssertEqual(result, .unchanged)
        let sync = LibrarySyncController(localRoot: copied, defaults: defaults, identityStore: keychain.store(for: copied))
        XCTAssertNotEqual(sync.deviceID, identity.deviceID)
        XCTAssertEqual(ReplicaIdentity.restore(library: copied, defaults: defaults, machine: nil, store: keychain.store(for:)), .unchanged)
    }

    /// Where the library hasn't moved, the keychain and preferences are the live state: an older file changes nothing.
    func testALibraryThatHasNotMovedKeepsItsLiveIdentity() throws {
        let (_, library) = try establishedLibrary()
        let defaults = makeTestDefaults()
        let live = StoredSyncIdentity(deviceID: UUID().uuidString, installation: UUID().uuidString)
        _ = keychain.store(for: library).write(live)
        defaults.set(live.deviceID, forKey: ReplicaIdentity.Key.deviceID)

        XCTAssertEqual(restore(library, defaults: defaults), .unchanged)
        let sync = LibrarySyncController(localRoot: library, defaults: defaults, identityStore: keychain.store(for: library))
        XCTAssertEqual(sync.deviceID, live.deviceID)
    }

    /// Moving back out of the container (`LegacyLibraryReturn`) brings the identity the sandboxed app last used.
    func testMovingBackRestoresTheIdentityLastUsedInTheContainer() throws {
        let (original, old) = try establishedLibrary()
        let container = try move(old, to: "Container/Daybook")
        let sandboxed = makeTestDefaults()
        restore(container, defaults: sandboxed)
        // In the container the Mac had to take a new ID (another device shared it), and recorded it.
        let renamed = StoredSyncIdentity(deviceID: UUID().uuidString, installation: original.installation)
        _ = keychain.store(for: container).write(renamed)
        save(renamed, library: container)

        let back = try move(container, to: "Daybook")
        let unsandboxed = makeTestDefaults()
        unsandboxed.set(original.deviceID, forKey: ReplicaIdentity.Key.deviceID)
        unsandboxed.set(true, forKey: ReplicaIdentity.Key.identityStored)
        XCTAssertEqual(restore(back, defaults: unsandboxed), .restored(deviceID: renamed.deviceID))
        let sync = LibrarySyncController(localRoot: back, defaults: unsandboxed, identityStore: keychain.store(for: back))
        XCTAssertEqual(sync.deviceID, renamed.deviceID)
    }

    func testTheAppRecordsItsIdentityWithTheLibrary() async throws {
        let library = root.appendingPathComponent("App/Daybook", isDirectory: true)
        let state = AppState(libraryURL: library, defaults: makeTestDefaults())
        await state.initialize()
        let saved = try XCTUnwrap(ReplicaIdentity.read(in: library))
        XCTAssertEqual(saved.syncDeviceID, state.sync.deviceID)
        XCTAssertEqual(saved.installation, state.sync.installation)
        XCTAssertEqual(saved.linkDeviceID, state.phoneLink.identity.deviceID.uuidString)
        XCTAssertEqual(saved.libraryPath, library.standardizedFileURL.path)
        XCTAssertEqual(saved.machine, ReplicaIdentity.currentMachine)
        XCTAssertNotNil(ReplicaIdentity.currentMachine, "the hardware UUID is readable on a Mac")
    }

    // MARK: Helpers

    /// A library whose app resolved an identity and recorded it, as release N does.
    private func establishedLibrary() throws -> (StoredSyncIdentity, URL) {
        let library = root.appendingPathComponent("Daybook", isDirectory: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Meetings"), withIntermediateDirectories: true)
        let identity = StoredSyncIdentity(deviceID: UUID().uuidString, installation: UUID().uuidString)
        _ = keychain.store(for: library).write(identity)
        save(identity, library: library)
        return (identity, library)
    }

    private func save(_ identity: StoredSyncIdentity, library: URL) {
        ReplicaIdentity.save(ReplicaIdentity(syncDeviceID: identity.deviceID, installation: identity.installation, linkDeviceID: identity.deviceID,
                                             libraryPath: library.standardizedFileURL.path, machine: machine, savedAt: Date()), in: library)
    }

    @discardableResult
    private func restore(_ library: URL, defaults: UserDefaults) -> ReplicaIdentity.Restored {
        ReplicaIdentity.restore(library: library, defaults: defaults, machine: machine, store: keychain.store(for:))
    }

    private func move(_ library: URL, to path: String) throws -> URL {
        let destination = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: library, to: destination)
        return destination
    }

    final class KeychainItems: @unchecked Sendable {
        private var stores: [String: SyncDeviceIdentityStore] = [:]
        func store(for library: URL) -> SyncDeviceIdentityStore {
            let key = library.standardizedFileURL.path
            if let store = stores[key] { return store }
            let store = SyncDeviceIdentityStore.memory()
            stores[key] = store
            return store
        }
    }
}
