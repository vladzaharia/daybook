import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// The sandboxed app's launch check: where the library is, and moving it into the container when macOS didn't.
@MainActor
final class SandboxMigrationTests: XCTestCase {
    private var root: URL!
    private var legacy: URL { root.appendingPathComponent("Home/Library/Application Support/Daybook", isDirectory: true) }
    private var container: URL {
        root.appendingPathComponent("Home/Library/Containers/local.daybook.app/Data/Library/Application Support/Daybook", isDirectory: true)
    }
    private var keychain = ReplicaIdentityTests.KeychainItems()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSandboxMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testWhereTheLibraryIs() {
        func outcome(legacy: Bool, container: Bool, priorUse: Bool = false, identity: Bool = true) -> SandboxMigration.Outcome {
            SandboxMigration.classify(.init(legacyExists: legacy, containerHasContent: container, preferencesShowPriorUse: priorUse, identityKnown: identity))
        }
        XCTAssertEqual(outcome(legacy: false, container: false), .fresh)
        XCTAssertEqual(outcome(legacy: false, container: true), .moved, "the manifest moved it")
        XCTAssertEqual(outcome(legacy: true, container: false), .stillAtOldLocation, "the container existed before the manifest could run")
        XCTAssertEqual(outcome(legacy: false, container: false, priorUse: true), .stillAtOldLocation, "preferences say there was a library")
        XCTAssertEqual(outcome(legacy: true, container: true), .bothPresent)
        XCTAssertEqual(outcome(legacy: false, container: true, identity: false), .identityMissing)
    }

    func testOnlyTheAppAndTheRehearsalHaveAnOldPlace() {
        XCTAssertEqual(SandboxMigration.legacyFolderName(bundleIdentifier: "local.daybook.app"), "Daybook")
        XCTAssertEqual(SandboxMigration.legacyFolderName(bundleIdentifier: "local.daybook.app.rehearsal2"), "Daybook Rehearsal")
        XCTAssertNil(SandboxMigration.legacyFolderName(bundleIdentifier: "local.daybook.app.adhoc"), "ad hoc builds never look at the real library")
        XCTAssertNil(SandboxMigration.legacyFolderName(bundleIdentifier: nil))
        let home = URL(fileURLWithPath: "/Users/dana", isDirectory: true)
        XCTAssertEqual(SandboxMigration.legacyLibrary(bundleIdentifier: "local.daybook.app", home: home)?.path,
                       "/Users/dana/Library/Application Support/Daybook")
    }

    func testEarlierUseShowsInPreferences() {
        let defaults = makeTestDefaults()
        XCTAssertFalse(SandboxMigration.preferencesShowPriorUse(defaults))
        defaults.set(true, forKey: "onboardingCompleted")
        XCTAssertTrue(SandboxMigration.preferencesShowPriorUse(defaults))
    }

    /// The manifest moved the library, but sync's keychain item is still named after the old place: the Mac keeps its
    /// identity.
    func testAMovedLibraryKeepsTheIdentityFromTheOldPlacesKeychainItem() throws {
        try writeLibrary(at: container)
        let identity = StoredSyncIdentity(deviceID: UUID().uuidString, installation: UUID().uuidString)
        _ = keychain.store(for: legacy).write(identity)
        let defaults = makeTestDefaults()
        defaults.set(identity.deviceID, forKey: ReplicaIdentity.Key.deviceID)
        defaults.set(true, forKey: ReplicaIdentity.Key.identityStored)

        XCTAssertEqual(check(defaults: defaults, priorUse: true), .moved)

        let sync = LibrarySyncController(localRoot: container, defaults: defaults, identityStore: keychain.store(for: container))
        XCTAssertEqual(sync.deviceID, identity.deviceID)
        XCTAssertEqual(defaults.dictionary(forKey: SandboxMigration.outcomeKey)?["outcome"] as? String, "moved")
    }

    func testEachPlaceIsRecognized() throws {
        let defaults = makeTestDefaults()
        XCTAssertEqual(check(defaults: defaults, priorUse: false), .fresh)
        try writeLibrary(at: legacy)
        XCTAssertEqual(check(defaults: defaults, priorUse: true), .stillAtOldLocation)
        try writeLibrary(at: container)
        XCTAssertEqual(check(defaults: defaults, priorUse: true), .bothPresent)
        try FileManager.default.removeItem(at: legacy)
        XCTAssertEqual(check(defaults: makeTestDefaults(), priorUse: false), .identityMissing, "no preferences, keychain item, or replica")
    }

    func testMovingCopiesEverythingAndLeavesTheOldLibraryAlone() throws {
        try writeLibrary(at: legacy)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Models/.partial"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: legacy.appendingPathComponent("Models/weights.bin"))
        let before = try SandboxMigration.inventory(legacy)
        // A held launch may have left an empty library folder in the container.
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Sync"), withIntermediateDirectories: true)

        try SandboxMigration.copyLibrary(from: legacy, to: container)

        XCTAssertEqual(try SandboxMigration.inventory(container), before)
        XCTAssertEqual(try SandboxMigration.inventory(legacy), before, "the old library is only read")
        XCTAssertEqual(try Data(contentsOf: container.appendingPathComponent("Models/weights.bin")), Data(repeating: 7, count: 4096))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: container.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["Daybook"], "no staging folder left behind")
    }

    func testMovingNeverReplacesALibraryOrTakesSomethingElse() throws {
        try writeLibrary(at: legacy)
        try writeLibrary(at: container, meeting: "already here")
        let existing = try SandboxMigration.inventory(container)
        XCTAssertThrowsError(try SandboxMigration.copyLibrary(from: legacy, to: container)) {
            XCTAssertEqual($0 as? SandboxMigration.MoveError, .libraryNotEmpty)
        }
        XCTAssertEqual(try SandboxMigration.inventory(container), existing)

        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SandboxMigration.copyLibrary(from: documents, to: root.appendingPathComponent("Elsewhere/Daybook"))) {
            XCTAssertEqual($0 as? SandboxMigration.MoveError, .notALibrary("Documents"))
        }
    }

    func testWhatTheSandboxedAppOffersAtLaunch() throws {
        let home = root.appendingPathComponent("Home", isDirectory: true)
        func launch(_ defaults: UserDefaults = makeTestDefaults(), bundle: String = "local.daybook.app", priorUse: Bool = true) -> AppState.LaunchCheck {
            AppState.launchCheck(library: container, bundleIdentifier: bundle, defaults: defaults, sandboxed: true, priorUse: priorUse,
                                 home: home, store: keychain.store(for:))
        }
        XCTAssertEqual(launch(priorUse: false), .init(), "a new library")
        try writeLibrary(at: legacy)
        XCTAssertEqual(launch().offer, .moveIntoContainer(.init(legacy: legacy, library: container, legacyExists: true)))
        XCTAssertEqual(launch().offer?.holdsLibrary, true)
        XCTAssertEqual(launch(bundle: "local.daybook.app.adhoc"), .init(), "ad hoc builds never look at the real library")

        try writeLibrary(at: container)
        XCTAssertEqual(launch().offer, .oldCopyRemains(legacy))
        XCTAssertEqual(launch().offer?.holdsLibrary, false, "only a warning: the library opens")
        let kept = makeTestDefaults()
        kept.set(legacy.path, forKey: SandboxMigration.keptOldCopyKey)
        XCTAssertEqual(launch(kept), .init(), "not asked again once kept")

        try FileManager.default.removeItem(at: legacy)
        XCTAssertNotNil(launch(priorUse: false).notice, "no identity: a word about pairing the iPhone again")
    }

    func testStartingFreshWhenNoOldLibraryCanBeFound() async throws {
        let defaults = makeTestDefaults()
        XCTAssertEqual(check(defaults: defaults, priorUse: true), .stillAtOldLocation)
        let state = AppState(libraryURL: container, defaults: defaults)
        state.libraryMoveOffer = .moveIntoContainer(.init(legacy: legacy, library: container, legacyExists: false))
        await state.initialize()
        XCTAssertFalse(state.isReady, "held until the person answers")
        await state.declineLibraryMove()
        XCTAssertTrue(state.isReady)
        XCTAssertTrue(defaults.bool(forKey: SandboxMigration.startedFreshKey))
        XCTAssertEqual(check(defaults: defaults, priorUse: true), .fresh, "not asked again")
    }

    func testAnOldCopyLeftBehindDoesNotHoldTheLibrary() async throws {
        let defaults = makeTestDefaults()
        let state = AppState(libraryURL: container, defaults: defaults)
        state.libraryMoveOffer = .oldCopyRemains(legacy)
        await state.initialize()
        XCTAssertTrue(state.isReady)
        await state.declineLibraryMove()
        XCTAssertNil(state.libraryMoveOffer)
        XCTAssertEqual(defaults.string(forKey: SandboxMigration.keptOldCopyKey), legacy.path)
    }

    // MARK: Helpers

    private func check(defaults: UserDefaults, priorUse: Bool) -> SandboxMigration.Outcome {
        SandboxMigration.check(library: container, legacy: legacy, defaults: defaults, priorUse: priorUse, store: keychain.store(for:))
    }

    private func writeLibrary(at url: URL, meeting: String = "conversation") throws {
        let folder = url.appendingPathComponent("Meetings/\(meeting)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("meeting.json"))
        try Data("{}".utf8).write(to: url.appendingPathComponent("library.json"))
    }
}
