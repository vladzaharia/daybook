import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Going back from a sandboxed Daybook to an unsandboxed one: the library comes back out of the container with its
/// preferences, and nothing is ever deleted.
@MainActor
final class LibraryMoveTests: XCTestCase {
    private var home: URL!
    private let bundleID = "local.daybook"
    private var library: URL { home.appendingPathComponent("Library/Application Support/Daybook", isDirectory: true) }
    private var container: URL {
        home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/Daybook", isDirectory: true)
    }
    private var containerPreferences: URL {
        home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookLibraryMoveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testWhichLibraryMovesBack() {
        let earlier = Date(timeIntervalSince1970: 1_000), later = Date(timeIntervalSince1970: 2_000)
        func kind(container: Bool, library: Bool, containerChanged: Date? = later, libraryChanged: Date? = earlier,
                  declined: Date? = nil) -> LegacyLibraryReturn.Kind {
            LegacyLibraryReturn.classify(.init(containerHasContent: container, libraryHasContent: library, containerChanged: containerChanged,
                                               libraryChanged: libraryChanged, declinedAt: declined))
        }
        XCTAssertEqual(kind(container: false, library: false), .none, "no sandboxed Daybook ran, or it never held a library")
        XCTAssertEqual(kind(container: false, library: true), .none)
        XCTAssertEqual(kind(container: true, library: false), .moveBack)
        XCTAssertEqual(kind(container: true, library: true), .replaceOlder, "the container's copy changed more recently")
        XCTAssertEqual(kind(container: true, library: true, containerChanged: earlier, libraryChanged: later), .none)
        XCTAssertEqual(kind(container: true, library: false, declined: later), .none, "Not Now, and nothing changed since")
        XCTAssertEqual(kind(container: true, library: false, containerChanged: later, declined: earlier), .moveBack)
    }

    func testTheLibraryAndItsPreferencesComeBackOutOfTheContainer() throws {
        try writeLibrary(at: container, meeting: "sandboxed")
        try FileManager.default.createDirectory(at: containerPreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved: NSDictionary = ["syncDeviceID": "6F1C1B9E-3C0A-4E44-9E3E-0123456789AB", "automaticRecording": true,
                                   "NSWindow Frame main": "0 0 100 100", "AppleLanguages": ["fr"]]
        XCTAssertTrue(saved.write(to: containerPreferences, atomically: true))
        let defaults = makeTestDefaults()

        let plan = try XCTUnwrap(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: defaults))
        XCTAssertFalse(plan.replacesOlder)
        XCTAssertNil(try LegacyLibraryReturn.perform(plan, defaults: defaults))

        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("Meetings/sandboxed/meeting.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
        XCTAssertEqual(defaults.string(forKey: "syncDeviceID"), "6F1C1B9E-3C0A-4E44-9E3E-0123456789AB")
        XCTAssertTrue(defaults.bool(forKey: "automaticRecording"))
        XCTAssertNil(defaults.object(forKey: "NSWindow Frame main"), "the system's window state stays behind")
        XCTAssertNil(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: defaults), "done")
    }

    /// A sandboxed build from before the one bundle ID kept the library in `local.daybook.app`'s container, with its
    /// preferences named after that ID: the release (`local.daybook`) brings both back.
    func testTheLibraryComesBackFromAnEarlierSandboxedBuild() throws {
        let store = home.appendingPathComponent("Library/Containers/local.daybook.app/Data", isDirectory: true)
        let storeLibrary = store.appendingPathComponent("Library/Application Support/Daybook", isDirectory: true)
        let storePreferences = store.appendingPathComponent("Library/Preferences/local.daybook.app.plist")
        try writeLibrary(at: storeLibrary, meeting: "from the earlier build")
        try FileManager.default.createDirectory(at: storePreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue((["onboardingCompleted": true, "syncDeviceID": "store"] as NSDictionary).write(to: storePreferences, atomically: true))
        let defaults = makeTestDefaults()

        let plan = try XCTUnwrap(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: defaults))
        XCTAssertEqual(plan.container, storeLibrary)
        XCTAssertEqual(plan.containerPreferences, storePreferences)
        try LegacyLibraryReturn.perform(plan, defaults: defaults)

        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("Meetings/from the earlier build/meeting.json").path))
        XCTAssertTrue(defaults.bool(forKey: "onboardingCompleted"))
        XCTAssertEqual(defaults.string(forKey: "syncDeviceID"), "store")
        XCTAssertNil(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: defaults), "done")
    }

    /// A library in both containers (a sandboxed build under each bundle ID ran): the one that changed last comes back,
    /// and the other stays where it is.
    func testWithTwoContainersTheNewerLibraryComesBack() throws {
        let earlierLibrary = home.appendingPathComponent("Library/Containers/local.daybook.app/Data/Library/Application Support/Daybook",
                                                       isDirectory: true)
        try writeLibrary(at: container, meeting: "older", date: Date(timeIntervalSinceNow: -86_400))
        try writeLibrary(at: earlierLibrary, meeting: "newer")
        var plan = try XCTUnwrap(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: makeTestDefaults()))
        XCTAssertEqual(plan.container, earlierLibrary)

        try writeLibrary(at: container, meeting: "newest", date: Date(timeIntervalSinceNow: 60))
        plan = try XCTUnwrap(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: makeTestDefaults()))
        XCTAssertEqual(plan.container, container)
        XCTAssertEqual(plan.containerPreferences, containerPreferences)
    }

    func testAnOlderLibraryHereIsSetAsideNeverDeleted() throws {
        try writeLibrary(at: library, meeting: "older", date: Date(timeIntervalSinceNow: -86_400))
        try writeLibrary(at: container, meeting: "newer")
        let defaults = makeTestDefaults()

        let plan = try XCTUnwrap(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: defaults))
        XCTAssertTrue(plan.replacesOlder)
        let aside = try XCTUnwrap(try LegacyLibraryReturn.perform(plan, defaults: defaults, now: Date(timeIntervalSince1970: 1_800_000_000)))

        XCTAssertTrue(aside.lastPathComponent.hasPrefix("Daybook (Older Copy "), aside.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.appendingPathComponent("Meetings/older/meeting.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("Meetings/newer/meeting.json").path))
    }

    func testAFailedMovePutsEverythingBack() throws {
        try writeLibrary(at: library, meeting: "here")
        let plan = LegacyLibraryReturn.Plan(container: container, library: library, containerPreferences: containerPreferences,
                                            replacesOlder: true, containerChanged: Date())
        XCTAssertThrowsError(try LegacyLibraryReturn.perform(plan, defaults: makeTestDefaults()), "the container's library is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("Meetings/here/meeting.json").path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: library.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["Daybook"])
    }

    func testNotNowIsRememberedUntilTheContainersLibraryChanges() throws {
        try writeLibrary(at: container, meeting: "sandboxed", date: Date(timeIntervalSinceNow: -60))
        let defaults = makeTestDefaults()
        let plan = try XCTUnwrap(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: defaults))
        LegacyLibraryReturn.decline(plan, defaults: defaults)
        XCTAssertNil(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: defaults))
        try writeLibrary(at: container, meeting: "another", date: Date())
        XCTAssertNotNil(LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleID, home: home, defaults: defaults))
    }

    /// Only the app's own library is ever moved: never a `--library`, `swift run`, or a test's.
    func testOnlyTheAppsOwnLibraryIsOffered() throws {
        try writeLibrary(at: container, meeting: "sandboxed")
        XCTAssertEqual(AppState.launchCheck(library: AppState.libraryURL, defaults: makeTestDefaults(), sandboxed: false), .init())
        XCTAssertEqual(AppState.launchCheck(library: library, defaults: makeTestDefaults(), sandboxed: false), .init(), "a test isn't the app")
        let check = AppState.launchCheck(library: library, bundleIdentifier: bundleID, defaults: makeTestDefaults(), sandboxed: false,
                                         priorUse: true, home: home)
        guard case .returnFromContainer(let plan)? = check.offer else { return XCTFail("\(check)") }
        XCTAssertEqual(plan.container, container)
        // A build under another bundle ID never takes a library into the app's place.
        let rehearsal = home.appendingPathComponent("Library/Containers/local.daybook.rehearsal/Data/Library/Application Support/Daybook")
        try writeLibrary(at: rehearsal, meeting: "rehearsal")
        XCTAssertEqual(AppState.launchCheck(library: library, bundleIdentifier: "local.daybook.rehearsal", defaults: makeTestDefaults(),
                                            sandboxed: false, priorUse: true, home: home), .init())
    }

    /// With a move offered, the library stays closed until the person answers; Not Now opens it where it is.
    func testTheLibraryWaitsForAnAnswer() async throws {
        let root = home.appendingPathComponent("Library under test", isDirectory: true)
        let state = AppState(libraryURL: root, defaults: makeTestDefaults())
        state.libraryMoveOffer = .returnFromContainer(.init(container: container, library: root, containerPreferences: containerPreferences,
                                                            replacesOlder: false, containerChanged: Date()))
        await state.initialize()
        XCTAssertFalse(state.isReady)
        XCTAssertFalse(state.library.isLoaded)
        await state.declineLibraryMove()
        XCTAssertNil(state.libraryMoveOffer)
        XCTAssertTrue(state.isReady)
    }

    // MARK: Helpers

    private func writeLibrary(at url: URL, meeting: String, date: Date = Date()) throws {
        let folder = url.appendingPathComponent("Meetings/\(meeting)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("meeting.json"))
        try Data("{}".utf8).write(to: url.appendingPathComponent("library.json"))
        for entry in [url.appendingPathComponent("Meetings"), url.appendingPathComponent("library.json")] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: entry.path)
        }
    }
}
