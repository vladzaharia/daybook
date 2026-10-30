import XCTest
@testable import DaybookCore

/// Two devices on a brand-new iCloud container, launched at once: each starts an encrypted library before it can see the
/// other's, and iCloud keeps both markers (the second as `daybook-sync 2.json`). Every device settles on the same one and
/// publishes what it holds into it once; the other's files and key go once every device has moved on.
final class LibrarySyncNewContainerTests: XCTestCase {
    private var root: URL!
    private var keychain: MemoryLibraryKeyStore!
    private var shared: URL { root.appendingPathComponent("iCloud") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookNewContainerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        keychain = MemoryLibraryKeyStore()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A device whose view of the container is `remote` (iCloud hasn't brought the other's files yet).
    private func engine(_ name: String, remote: URL, phone: Bool = false) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: phone ? .onDemand : .eager,
            device: SyncDeviceIdentity(deviceClass: phone ? .phone : .mac, displayName: name, canProcess: !phone),
            keyStore: keychain, sealsNewLibrary: true))
    }
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ extra: [Meeting] = []) async throws -> SyncResult {
        let store = try MeetingStore(rootURL: local(name))
        let held = try await store.list()
        let supplied = held.filter { meeting in !extra.contains { $0.id == meeting.id } } + extra
        let result = try await engine.synchronize(meetings: supplied)
        for meeting in result.meetings { try await store.save(meeting) }
        try await engine.acknowledge(result.checkpointID)
        return result
    }
    private func manifest(_ folder: URL, _ name: String = "daybook-sync.json") throws -> SyncManifest {
        try SyncManifest.decode(Data(contentsOf: folder.appendingPathComponent(name)))
    }
    /// What iCloud does when the two meet: one folder holding both journals, the marker that arrived second renamed.
    private func meet(_ second: URL, into first: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: second, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        let base = second.standardizedFileURL.path
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            var path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if path == "daybook-sync.json" { path = "daybook-sync 2.json" }
            let target = first.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: url, to: target) }
        }
    }
    /// The library each sealed file in `folder` says it belongs to.
    private func sealedLibraries(_ folder: URL, in directories: [String] = ["Sealed/Events", "Sealed/Metadata", "Sealed/Blobs"]) throws -> Set<UUID> {
        var libraries = Set<UUID>()
        for directory in directories {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(directory).path)) ?? []).filter { !$0.hasPrefix(".") }
            for name in names {
                let bytes = try Data(contentsOf: folder.appendingPathComponent("\(directory)/\(name)"))
                libraries.insert(try XCTUnwrap(SealedObject.header(of: bytes)?.libraryID))
            }
        }
        return libraries
    }

    func testTwoDevicesStartingAtOnceOnANewContainerEndInOneLibrary() async throws {
        // Each device starts its own encrypted library in the container as it sees it.
        let macView = root.appendingPathComponent("Mac view"), phoneView = root.appendingPathComponent("Phone view")
        let fromMac = Meeting(title: "From the Mac"), fromPhone = Meeting(title: "From the phone")
        try await pass(try engine("Mac", remote: macView), "Mac", [fromMac])
        try await pass(try engine("Phone", remote: phoneView, phone: true), "Phone", [fromPhone])
        let macLibrary = try manifest(macView).libraryID, phoneLibrary = try manifest(phoneView).libraryID
        // The first one started wins; started the same moment (the manifest keeps whole seconds), the smallest ID.
        let started = [macLibrary: try XCTUnwrap(try manifest(macView).created), phoneLibrary: try XCTUnwrap(try manifest(phoneView).created)]
        let winner = [macLibrary, phoneLibrary].min { (started[$0]!, $0.uuidString) < (started[$1]!, $1.uuidString) }!
        let loser = winner == macLibrary ? phoneLibrary : macLibrary

        // iCloud brings them together. From now on both devices see the same folder.
        try meet(phoneView, into: macView)
        let mac = try engine("Mac", remote: macView), phone = try engine("Phone", remote: macView, phone: true)
        for _ in 0..<2 {
            try await pass(mac, "Mac")
            try await pass(phone, "Phone")
        }
        // One library, the smallest ID, on both, and one marker.
        let onMac = await mac.libraryID, onPhone = await phone.libraryID
        XCTAssertEqual(onMac, winner); XCTAssertEqual(onPhone, winner)
        XCTAssertEqual(try manifest(macView).libraryID, winner)
        XCTAssertEqual(try manifest(macView).sealing?.replaces, [loser])
        let markers = try FileManager.default.contentsOfDirectory(atPath: macView.path).filter { $0.hasPrefix("daybook-sync") }
        XCTAssertEqual(markers, ["daybook-sync.json"])
        // The loser's files and key are gone.
        XCTAssertEqual(try sealedLibraries(macView), [winner])
        XCTAssertEqual(try keychain.keys(for: loser), [])
        // Both hold both conversations, and it has settled: nothing more is published, nothing waits.
        let settledMac = try await pass(mac, "Mac"), settledPhone = try await pass(phone, "Phone")
        XCTAssertEqual(Set(settledMac.meetings.map(\.id)), [fromMac.id, fromPhone.id])
        XCTAssertEqual(Set(settledPhone.meetings.map(\.id)), [fromMac.id, fromPhone.id])
        for result in [settledMac, settledPhone] {
            XCTAssertEqual(result.publishedEvents, 0); XCTAssertEqual(result.warnings, []); XCTAssertEqual(result.pendingDownloads, 0)
        }
    }

    /// The library that lost may hold what only a device that hasn't moved on yet has: its files and key stay until every
    /// device has. Then its entries go, and its objects once the winner holds what they hold; one nothing republished
    /// stays, and so does its key, until it's gone.
    func testTheLosersFilesAndKeyStayUntilEveryDeviceHasMovedOn() async throws {
        let macView = root.appendingPathComponent("Mac view"), phoneView = root.appendingPathComponent("Phone view")
        let fromMac = Meeting(title: "From the Mac"), fromPhone = Meeting(title: "From the phone")
        try await pass(try engine("Mac", remote: macView), "Mac", [fromMac])
        try await pass(try engine("Phone", remote: phoneView, phone: true), "Phone", [fromPhone])
        let macLibrary = try manifest(macView).libraryID, phoneLibrary = try manifest(phoneView).libraryID
        let started = [macLibrary: try XCTUnwrap(try manifest(macView).created), phoneLibrary: try XCTUnwrap(try manifest(phoneView).created)]
        let winner = [macLibrary, phoneLibrary].min { (started[$0]!, $0.uuidString) < (started[$1]!, $1.uuidString) }!
        let loser = winner == macLibrary ? phoneLibrary : macLibrary
        let loserView = loser == macLibrary ? macView : phoneView
        let loserKey = try XCTUnwrap(try keychain.keys(for: loser).first)
        // A Mac that joined the losing library, with a recording only it holds; and an object of the loser's that nothing
        // holds or names.
        let file = root.appendingPathComponent("pad.wav")
        try Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: file)
        let fromPad = try await MeetingStore(rootURL: local("Pad")).importAudio(from: file, into: Meeting(title: "From the Pad"), source: .microphone)
        let sha = try XCTUnwrap(fromPad.tracks.first?.sha256)
        try await pass(try engine("Pad", remote: loserView), "Pad", [fromPad])
        let padObject = "Sealed/Blobs/\(try XCTUnwrap(loserKey.objectName(.blob, plaintextSHA256: sha)))"
        XCTAssertTrue(FileManager.default.fileExists(atPath: loserView.appendingPathComponent(padObject).path))
        let stray = SealedObject.seal(Data("only the loser had this".utf8), kind: .blob, key: loserKey)
        try stray.bytes.write(to: loserView.appendingPathComponent("Sealed/Blobs/\(stray.name)"))

        try meet(phoneView, into: macView)
        let mac = try engine("Mac", remote: macView), phone = try engine("Phone", remote: macView, phone: true)
        for _ in 0..<2 {
            for result in [try await pass(mac, "Mac"), try await pass(phone, "Phone")] {
                XCTAssertEqual(result.warnings, []); XCTAssertEqual(result.pendingDownloads, 0)
            }
        }
        XCTAssertEqual(try manifest(macView).libraryID, winner)
        // The Pad is still on the loser's key: nothing of the loser's goes.
        XCTAssertEqual(try sealedLibraries(macView, in: ["Sealed/Events"]), [winner, loser])
        XCTAssertTrue(FileManager.default.fileExists(atPath: macView.appendingPathComponent(padObject).path))
        XCTAssertFalse(try keychain.keys(for: loser).isEmpty)

        // It moves on, publishing what it holds into the winner; then the loser's entries go, and its recording once the
        // winner holds it too.
        let pad = try engine("Pad", remote: macView)
        for _ in 0..<2 {
            try await pass(pad, "Pad"); try await pass(mac, "Mac"); try await pass(phone, "Phone")
        }
        XCTAssertEqual(try sealedLibraries(macView, in: ["Sealed/Events", "Sealed/Metadata"]), [winner])
        XCTAssertFalse(FileManager.default.fileExists(atPath: macView.appendingPathComponent(padObject).path))
        let winnerKey = try XCTUnwrap(try keychain.keys(for: winner).first)
        let republished = try XCTUnwrap(winnerKey.objectName(.blob, plaintextSHA256: sha))
        XCTAssertTrue(FileManager.default.fileExists(atPath: macView.appendingPathComponent("Sealed/Blobs/\(republished)").path))
        // What nothing republished stays, and with it the loser's key.
        XCTAssertTrue(FileManager.default.fileExists(atPath: macView.appendingPathComponent("Sealed/Blobs/\(stray.name)").path))
        XCTAssertFalse(try keychain.keys(for: loser).isEmpty)
        try FileManager.default.removeItem(at: macView.appendingPathComponent("Sealed/Blobs/\(stray.name)"))
        try await pass(mac, "Mac")
        XCTAssertEqual(try keychain.keys(for: loser), [])
        XCTAssertEqual(try sealedLibraries(macView), [winner])
        for (engine, name) in [(mac, "Mac"), (phone, "Phone"), (pad, "Pad")] {
            let settled = try await pass(engine, name)
            XCTAssertEqual(Set(settled.meetings.map(\.id)), [fromMac.id, fromPhone.id, fromPad.id], name)
            XCTAssertEqual(settled.warnings, [], name); XCTAssertEqual(settled.pendingDownloads, 0, name)
        }
    }

    /// Whichever marker iCloud kept as the file and which it renamed, every device picks the same winner: the library
    /// started first (here, an hour before the other, by a device that was offline when the other started), whatever
    /// the IDs.
    func testTheWinnerIsTheSameWhicheverMarkerIsTheCopy() async throws {
        var resolved: [UUID] = []
        let first = LibraryKey.generate(libraryID: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!, createdBy: "A",
                                        now: Date().addingTimeInterval(-3_600))
        let second = LibraryKey.generate(libraryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, createdBy: "B")
        for key in [first, second] { try keychain.store(key) }
        func marker(_ key: LibraryKey) -> SyncManifest {
            var manifest = SyncManifest(libraryID: key.libraryID)
            manifest.schemaVersion = SyncManifest.sealedSchemaVersion
            manifest.sealing = .init(current: key.idHex, sealedSince: key.createdAt, migrator: key.createdBy, keys: [.init(id: key.idHex, created: key.createdAt)])
            manifest.created = key.createdAt
            return manifest
        }
        for (index, order) in [[first, second], [second, first]].enumerated() {
            let folder = root.appendingPathComponent("Container \(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try marker(order[0]).encoded().write(to: folder.appendingPathComponent("daybook-sync.json"))
            try marker(order[1]).encoded().write(to: folder.appendingPathComponent("daybook-sync 2.json"))
            _ = try await engine("Device \(index)", remote: folder).synchronize(meetings: [])
            resolved.append(try manifest(folder).libraryID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("daybook-sync 2.json").path))
        }
        XCTAssertEqual(resolved[0], resolved[1])
        XCTAssertEqual(resolved[0], first.libraryID, "the first started, though its ID is the larger")
    }

    /// Two encrypted libraries started a long time apart aren't a race: they can't be merged, and sync pauses.
    func testLibrariesStartedLongApartStillPause() async throws {
        let folder = root.appendingPathComponent("Container")
        let mac = try engine("Mac", remote: folder)
        try await pass(mac, "Mac", [Meeting(title: "Mine")])
        let other = LibraryKey.generate(libraryID: UUID(), createdBy: "Other", now: Date().addingTimeInterval(-30 * 86_400))
        var marker = SyncManifest(libraryID: other.libraryID)
        marker.schemaVersion = SyncManifest.sealedSchemaVersion
        marker.sealing = .init(current: other.idHex, sealedSince: other.createdAt, migrator: "Other", keys: [.init(id: other.idHex, created: other.createdAt)])
        marker.created = other.createdAt
        try marker.encoded().write(to: folder.appendingPathComponent("daybook-sync 2.json"))
        do { _ = try await mac.synchronize(meetings: []); XCTFail() } catch LibrarySyncError.manifestConflict {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("daybook-sync 2.json").path), "nothing is deleted")
    }
}
