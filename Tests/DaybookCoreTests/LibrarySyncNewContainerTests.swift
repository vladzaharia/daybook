import XCTest
@testable import DaybookCore

/// Two devices on a brand-new iCloud container, launched at once: each starts an encrypted library before it can see the
/// other's, and iCloud keeps both markers (the second as `daybook-sync 2.json`). Every device settles on the same one, the
/// smallest library ID, deletes the other's marker, files, and key, and publishes what it holds into the winner once.
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
    private func sealedLibraries(_ folder: URL) throws -> Set<UUID> {
        var libraries = Set<UUID>()
        for directory in ["Sealed/Events", "Sealed/Metadata", "Sealed/Blobs"] {
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
        XCTAssertNotNil(try manifest(macView).created)
        let winner = [macLibrary, phoneLibrary].min { $0.uuidString < $1.uuidString }!
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

    /// Whichever marker iCloud kept as the file and which it renamed, every device picks the same winner.
    func testTheWinnerIsTheSameWhicheverMarkerIsTheCopy() async throws {
        var resolved: [UUID] = []
        let first = LibraryKey.generate(libraryID: UUID(), createdBy: "A"), second = LibraryKey.generate(libraryID: UUID(), createdBy: "B")
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
        XCTAssertEqual(resolved[0], [first.libraryID, second.libraryID].min { $0.uuidString < $1.uuidString })
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
