import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// One Bluetooth owner per recorder: claims and releases save as library settings and sync to the
/// other devices like folders and templates do (docs/devices.md).
@MainActor
final class RecorderOwnershipTests: XCTestCase {
    private var root: URL!
    private let serial = "D3200SIM0000001"

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookOwnership")
    }

    /// A library with its own sync identity, connected to the shared folder when given.
    private func library(_ name: String, cloud: URL? = nil) async throws -> LibraryController {
        let local = root.appendingPathComponent(name, isDirectory: true)
        let sync = LibrarySyncController(localRoot: local, defaults: makeTestDefaults("daybook.ownership.\(name)"))
        if let cloud { try sync.connect(to: cloud, monitorChanges: false) }
        let library = LibraryController(rootURL: local, sync: sync)
        try await library.load()
        return library
    }

    /// One sync pass that must run and be acknowledged, so a check after it isn't vacuous.
    private func pass(_ library: LibraryController, file: StaticString = #filePath, line: UInt = #line) async {
        await library.flush()
        let applied = await library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true, "the sync pass ran and was acknowledged", file: file, line: line)
    }

    func testClaimAndReleaseSaveAsLibrarySettings() async throws {
        let library = try await library("Phone")
        XCTAssertNil(library.recorderOwner(kind: "soundcore.work", serial: serial))

        let claimed = library.claimRecorder(kind: "soundcore.work", serial: serial, deviceClass: .phone)
        XCTAssertEqual(claimed.ownerID, library.thisDevice.id)
        XCTAssertEqual(claimed.ownerName, library.thisDevice.name)
        XCTAssertEqual(claimed.ownerClass, .phone)
        XCTAssertEqual(library.recorderOwners, [claimed])
        await library.flush()

        // It's in library.json, so it survives reopening.
        let reopened = LibraryController(rootURL: library.rootURL, sync: nil)
        try await reopened.load()
        XCTAssertEqual(reopened.recorderOwner(kind: "soundcore.work", serial: serial), claimed)

        // Releasing on behalf of another device does nothing; releasing its own claim clears it.
        library.releaseRecorder(kind: "soundcore.work", serial: serial, onlyIfOwnedBy: "someone-else")
        XCTAssertEqual(library.recorderOwners, [claimed])
        library.releaseRecorder(kind: "soundcore.work", serial: serial, onlyIfOwnedBy: library.thisDevice.id)
        XCTAssertNil(library.recorderOwner(kind: "soundcore.work", serial: serial))
        XCTAssertEqual(library.metadata.recorders?.count, 1, "a deletion marker, so the release syncs")
    }

    func testOwnershipSyncsAndTheLaterClaimWins() async throws {
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let phone = try await library("Phone", cloud: cloud)
        let mac = try await library("Mac", cloud: cloud)
        defer { phone.sync?.disconnect(); mac.sync?.disconnect() }
        XCTAssertNotEqual(phone.thisDevice.id, mac.thisDevice.id)

        let t1 = Date(timeIntervalSince1970: 1_800_000_000)
        phone.claimRecorder(kind: "soundcore.work", serial: serial, deviceClass: .phone, at: t1)
        await pass(phone)
        await pass(mac)
        let seenOnMac = try XCTUnwrap(mac.recorderOwner(kind: "soundcore.work", serial: serial))
        XCTAssertEqual(seenOnMac.ownerID, phone.thisDevice.id, "the Mac learns that the phone manages it")

        // The Mac takes it back ("Use on This Mac"), later: that claim wins on both.
        mac.claimRecorder(kind: "soundcore.work", serial: serial, deviceClass: .mac, at: t1.addingTimeInterval(60))
        await pass(mac)
        await pass(phone)
        XCTAssertEqual(phone.recorderOwner(kind: "soundcore.work", serial: serial)?.ownerID, mac.thisDevice.id)
        XCTAssertEqual(phone.recorderOwner(kind: "soundcore.work", serial: serial)?.ownerClass, .mac)

        // Removing the recorder on the phone doesn't undo the Mac's claim, on either device.
        phone.releaseRecorder(kind: "soundcore.work", serial: serial, onlyIfOwnedBy: phone.thisDevice.id)
        XCTAssertEqual(phone.recorderOwner(kind: "soundcore.work", serial: serial)?.ownerID, mac.thisDevice.id)
        await pass(phone)
        await pass(mac)
        XCTAssertEqual(mac.recorderOwner(kind: "soundcore.work", serial: serial)?.ownerID, mac.thisDevice.id)
        await pass(phone)
        XCTAssertEqual(phone.recorderOwner(kind: "soundcore.work", serial: serial)?.ownerID, mac.thisDevice.id)
    }
}
