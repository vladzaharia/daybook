import XCTest
@testable import DaybookCore

/// Starting over (LibrarySyncStartOver.swift): an encrypted library whose key is lost on every device is replaced by a
/// new library with a new key, every device publishes its own library into it, and the old library's files go. Two
/// devices starting over at once end in one library. iCloud is a temporary folder (`SimulatedICloud`), iCloud Keychain a
/// `MemoryLibraryKeyStore` the replicas share.
final class LibrarySyncStartOverTests: XCTestCase {
    private var root: URL!
    private var cloud: SimulatedICloud!
    private var keychain: MemoryLibraryKeyStore!
    private var remote: URL { root.appendingPathComponent("iCloud") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookStartOverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cloud = SimulatedICloud()
        keychain = MemoryLibraryKeyStore()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mac(_ name: String = "Mac") throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: "Studio Mac", canProcess: true),
            cloud: cloud.files, keyStore: keychain))
    }
    private func phone(_ name: String = "Phone") throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: "Pocket", canProcess: false),
            cloud: cloud.files, keyStore: keychain))
    }
    /// A pass supplying everything the device's library holds, applied and acknowledged.
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ extra: [Meeting] = []) async throws -> SyncResult {
        let store = try MeetingStore(rootURL: local(name))
        let held = try await store.list()
        let supplied = held.filter { meeting in !extra.contains { $0.id == meeting.id } } + extra
        let result = try await engine.synchronize(meetings: supplied)
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs where FileManager.default.fileExists(atPath: local(name).appendingPathComponent("Meetings/\(id)").path) {
            _ = try await store.moveToTrash(id)
        }
        try await engine.acknowledge(result.checkpointID)
        return result
    }
    private func record(_ bytes: Data, on name: String, into meeting: Meeting) async throws -> Meeting {
        let file = root.appendingPathComponent("\(UUID().uuidString).wav")
        try bytes.write(to: file)
        return try await MeetingStore(rootURL: local(name)).importAudio(from: file, into: meeting, source: .microphone)
    }
    private func audioBytes(_ count: Int, seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }
    private func manifest() throws -> SyncManifest { try SyncManifest.decode(Data(contentsOf: remote.appendingPathComponent("daybook-sync.json"))) }
    private func files(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent(directory).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
    /// The library each sealed file in the sync folder says it belongs to.
    private func sealedLibraries() throws -> Set<UUID> {
        var libraries = Set<UUID>()
        for directory in ["Sealed/Events", "Sealed/Metadata", "Sealed/Blobs"] {
            for name in files(directory) {
                let bytes = try Data(contentsOf: remote.appendingPathComponent("\(directory)/\(name)"))
                libraries.insert(try XCTUnwrap(SealedObject.header(of: bytes)?.libraryID, "\(directory)/\(name)"))
            }
        }
        return libraries
    }

    /// A Mac and an iPhone sharing an encrypted library, with history from before encryption and after, whose key is
    /// then lost everywhere: iCloud Keychain forgets it and there's no recovery key. Both have tried a pass since.
    private func libraryWithLostKey() async throws -> (mac: LibrarySyncEngine, phone: LibrarySyncEngine, old: UUID, before: Meeting, after: Meeting, onPhone: Meeting) {
        let mac = try mac(), phone = try phone()
        let before = try await pass(mac, "Mac", [try await record(audioBytes(6000, seed: 1), on: "Mac", into: Meeting(title: "Before encryption"))]).meetings[0]
        try await pass(phone, "Phone")
        let key = try await mac.enableSealing()
        let after = try await pass(mac, "Mac", [try await record(audioBytes(5000, seed: 2), on: "Mac", into: Meeting(title: "After encryption"))])
            .meetings.first { $0.title == "After encryption" }!
        let onPhone = try await pass(phone, "Phone", [Meeting(title: "Phone notes")]).meetings.first { $0.title == "Phone notes" }!
        try await pass(mac, "Mac")
        XCTAssertFalse(files("Sealed/Events").isEmpty); XCTAssertFalse(files("Events").isEmpty, "the plaintext from before isn't retired yet")

        try keychain.remove(keyID: key.id, libraryID: key.libraryID)
        for (engine, name) in [(mac, "Mac"), (phone, "Phone")] {
            do { try await pass(engine, name); XCTFail("Synced without the key") } catch LibrarySyncError.keyUnavailable {}
        }
        return (mac, phone, key.libraryID, before, after, onPhone)
    }

    func testStartingOverAfterTheKeyIsLostEverywhereRepublishesEveryDevice() async throws {
        let (mac, phone, old, before, after, onPhone) = try await libraryWithLostKey()
        let offered = await mac.mayStartOver()
        XCTAssertTrue(offered)

        let new = try await mac.startOver()
        XCTAssertNotEqual(new, old)
        let started = try manifest()
        XCTAssertEqual(started.libraryID, new)
        XCTAssertTrue(started.isSealed)
        XCTAssertEqual(started.sealing?.replaces, [old])
        XCTAssertEqual(started.sealing?.migrator, "Mac")
        XCTAssertNil(started.supersedes, "no checkpoint carries over from the old library")
        // The old library's files are gone: its sealed files, and its plaintext history from before encryption. Its
        // plaintext recordings stay for the new library to use.
        XCTAssertTrue(files("Sealed/Events").isEmpty); XCTAssertTrue(files("Sealed/Metadata").isEmpty); XCTAssertTrue(files("Sealed/Blobs").isEmpty)
        XCTAssertTrue(files("Events").isEmpty); XCTAssertTrue(files("Metadata").isEmpty)
        XCTAssertEqual(files("Blobs"), [before.tracks[0].sha256])
        let stillOffered = await mac.mayStartOver()
        XCTAssertFalse(stillOffered)

        // The phone, first: it holds the new key (iCloud Keychain), and publishes what it holds, the recording from before
        // encryption by reference to the plaintext copy that's still there. The one recorded after encryption was only in
        // the old library's files: it waits for the Mac to publish it again.
        let fromPhone = try await pass(phone, "Phone")
        XCTAssertEqual(fromPhone.warnings, [])
        XCTAssertEqual(fromPhone.publishedEvents, 2)
        XCTAssertEqual(fromPhone.pendingDownloads, 1)
        let fromMac = try await pass(mac, "Mac")
        XCTAssertEqual(fromMac.warnings, []); XCTAssertEqual(fromMac.pendingDownloads, 0)
        XCTAssertEqual(Set(fromMac.meetings.map(\.title)), Set([before, after, onPhone].map(\.title)))
        let back = try await pass(phone, "Phone")
        XCTAssertEqual(back.warnings, []); XCTAssertEqual(back.pendingDownloads, 0)
        XCTAssertEqual(Set(back.meetings.map(\.id)), Set([before, after, onPhone].map(\.id)))
        XCTAssertEqual(try sealedLibraries(), [new])
        // A new Mac gets everything, audio included.
        let fresh = try await pass(try self.mac("Fresh"), "Fresh")
        XCTAssertEqual(Set(fresh.meetings.map(\.id)), Set([before, after, onPhone].map(\.id)))
        XCTAssertEqual(fresh.pendingDownloads, 0); XCTAssertEqual(fresh.warnings, [])
    }

    func testStartOverIsRefusedWhileAKeyIsAvailable() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac", [Meeting(title: "Kept")])
        try await mac.enableSealing()
        try await pass(mac, "Mac")
        // This device holds the key.
        let macOffered = await mac.mayStartOver()
        XCTAssertFalse(macOffered)
        do { try await mac.startOver(); XCTFail("Started over with the key here") } catch LibrarySyncError.keyAvailable {}

        // A phone without the key, while the Mac said recently that it holds it: get the key from the Mac.
        let alone = try LibrarySyncEngine(localRoot: local("Alone"), remoteRoot: remote, deviceID: "Alone", replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: "Pocket", canProcess: false),
            cloud: cloud.files, keyStore: MemoryLibraryKeyStore()))
        do { _ = try await alone.synchronize(meetings: []); XCTFail() } catch LibrarySyncError.keyUnavailable {}
        let aloneOffered = await alone.mayStartOver()
        XCTAssertFalse(aloneOffered)
        let before = try manifest()
        do { try await alone.startOver(); XCTFail("Started over while another device holds the key") } catch LibrarySyncError.keyAvailable {}
        XCTAssertEqual(try manifest(), before)
        // Two weeks on, the Mac not seen since, it's offered.
        let later = Date().addingTimeInterval(LibrarySyncEngine.keyHolderAbsence + 60)
        let laterOffered = await alone.mayStartOver(now: later)
        XCTAssertTrue(laterOffered)
        // A plaintext library has nothing to start over, and a build without a key store can't.
        _ = phone
        let plain = try LibrarySyncEngine(localRoot: local("Plain"), remoteRoot: root.appendingPathComponent("Other"), deviceID: "Plain",
                                          replica: SyncReplicaConfiguration(cloud: cloud.files, keyStore: keychain))
        _ = try await plain.synchronize(meetings: [])
        let plainOffered = await plain.mayStartOver()
        XCTAssertFalse(plainOffered)
        let unchanged = try await plain.startOver()
        let plainID = await plain.libraryID
        XCTAssertEqual(unchanged, plainID)
    }

    func testTwoDevicesStartingOverAtOnceEndInOneLibrary() async throws {
        let (mac, phone, old, before, after, onPhone) = try await libraryWithLostKey()
        let stale = try manifest()
        // The Mac starts over and publishes into its library.
        let mine = try await mac.startOver()
        try await pass(mac, "Mac")
        XCTAssertEqual(try sealedLibraries(), [mine])
        // The phone started over from what it read before the Mac's library appeared: writing, it finds the Mac's, and
        // joins it rather than replacing it.
        let joined = try await phone.replaceLibrary(stale, recovery: nil, now: Date())
        XCTAssertEqual(joined, mine)
        XCTAssertEqual(try manifest().libraryID, mine)
        XCTAssertEqual(keychain.allKeys.filter { $0.createdBy == "Phone" }.count, 0, "its own new key is forgotten")
        // Started over from the Mac's library instead, it's refused: the Mac made that key and holds it.
        do { try await phone.startOver(); XCTFail() } catch LibrarySyncError.keyAvailable {}

        // Meanwhile another device started over too, before seeing the Mac's: iCloud kept its manifest as a copy. Its ID
        // is smaller, so it wins on every device, and replaces the Mac's library as well.
        let rivalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let rivalKey = LibraryKey.generate(libraryID: rivalID, createdBy: "Rival")
        try keychain.store(rivalKey)
        var rival = SyncManifest(libraryID: rivalID)
        rival.schemaVersion = SyncManifest.sealedSchemaVersion
        rival.sealing = .init(current: rivalKey.idHex, sealedSince: Date(), migrator: "Rival", keys: [.init(id: rivalKey.idHex, created: rivalKey.createdAt)],
                              replaces: [old])
        try rival.encoded().write(to: remote.appendingPathComponent("daybook-sync 2.json"))

        let onMac = try await pass(mac, "Mac")
        XCTAssertEqual(onMac.warnings, [])
        let resolved = try manifest()
        XCTAssertEqual(resolved.libraryID, rivalID)
        XCTAssertEqual(Set(resolved.sealing?.replaces ?? []), [old, mine])
        XCTAssertNil(resolved.supersedes)
        XCTAssertEqual(resolved.sealing?.current, rivalKey.idHex)
        // The Mac published everything again into the winner, and the loser's files are gone.
        XCTAssertEqual(try sealedLibraries(), [rivalID])
        let onPhoneResult = try await pass(phone, "Phone")
        XCTAssertEqual(onPhoneResult.warnings, [])
        XCTAssertEqual(Set(onPhoneResult.meetings.map(\.id)), Set([before, after, onPhone].map(\.id)))
        let macAgain = try await pass(mac, "Mac")
        XCTAssertEqual(Set(macAgain.meetings.map(\.id)), Set([before, after, onPhone].map(\.id)))
        XCTAssertEqual(try sealedLibraries(), [rivalID])

        // Resolved the same whichever version is the file and which the copy.
        try FileManager.default.removeItem(at: remote.appendingPathComponent("daybook-sync 2.json"))
        var theirs = rival
        theirs.sealing?.replaces = [old]
        var ours = try manifest()
        ours.libraryID = mine
        ours.sealing = .init(current: String(repeating: "a", count: 32), sealedSince: Date(), migrator: "Mac",
                             keys: [.init(id: String(repeating: "a", count: 32), created: Date())], replaces: [old])
        try theirs.encoded().write(to: remote.appendingPathComponent("daybook-sync.json"))
        try ours.encoded().write(to: remote.appendingPathComponent("daybook-sync 3.json"))
        try await pass(mac, "Mac")
        XCTAssertEqual(try manifest().libraryID, rivalID)
        XCTAssertEqual(Set(try manifest().sealing?.replaces ?? []), [old, mine])
    }

    func testUnrelatedEncryptedLibrariesStillPause() async throws {
        let mac = try mac()
        try await pass(mac, "Mac")
        try await mac.enableSealing()
        try await pass(mac, "Mac")
        // An encrypted library that didn't start over from this one can't be merged with it.
        let otherKey = LibraryKey.generate(libraryID: UUID(), createdBy: "Other")
        var other = SyncManifest(libraryID: otherKey.libraryID)
        other.schemaVersion = SyncManifest.sealedSchemaVersion
        other.sealing = .init(current: otherKey.idHex, sealedSince: Date(), migrator: "Other", keys: [.init(id: otherKey.idHex, created: otherKey.createdAt)],
                              replaces: [UUID()])
        try other.encoded().write(to: remote.appendingPathComponent("daybook-sync 2.json"))
        do { _ = try await mac.synchronize(meetings: []); XCTFail() } catch LibrarySyncError.manifestConflict {}
    }
}
