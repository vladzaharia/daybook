import XCTest
@testable import DaybookCore

/// Encrypted libraries (LibrarySyncSealing.swift, LibrarySyncSealer.swift): the manifest gate, sealed events, settings,
/// and objects between replicas, a replica without the key, the sealer, and retirement. iCloud is a temporary folder
/// (`SimulatedICloud`), iCloud Keychain a `MemoryLibraryKeyStore`: one shared between replicas plays iCloud Keychain
/// carrying the key, separate ones a device it hasn't reached.
final class LibrarySyncSealingTests: XCTestCase {
    private var root: URL!
    private var cloud: SimulatedICloud!
    private var keychain: MemoryLibraryKeyStore!
    private var remote: URL { root.appendingPathComponent("iCloud") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private let fast = AudioFetchOptions(pollInterval: .milliseconds(5), timeout: .seconds(10))
    /// Words that must never appear in the sync folder of an encrypted library.
    private let markers = ["Zanzibar", "Quokka", "Marmalade", "Thistlewood", "Pemberton", "Studio Mac"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSealingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cloud = SimulatedICloud()
        keychain = MemoryLibraryKeyStore()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mac(_ name: String = "Mac", keys: MemoryLibraryKeyStore? = nil) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: "Studio Mac", canProcess: true),
            cloud: cloud.files, keyStore: keys ?? keychain))
    }
    private func phone(_ name: String = "Phone", keys: MemoryLibraryKeyStore? = nil, budget: UInt64? = nil) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: "Pocket", canProcess: false),
            audioCache: budget.map { AudioCachePolicy(budgetBytes: $0) }, cloud: cloud.files, keyStore: keys ?? keychain))
    }
    private func apply(_ result: SyncResult, to name: String, using engine: LibrarySyncEngine) async throws {
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs where FileManager.default.fileExists(atPath: local(name).appendingPathComponent("Meetings/\(id)").path) {
            _ = try await store.moveToTrash(id)
        }
        try await engine.acknowledge(result.checkpointID)
    }
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ meetings: [Meeting] = [], deleted: Set<UUID> = [],
                      metadata: Data? = nil) async throws -> SyncResult {
        let result = try await engine.synchronize(meetings: meetings, deletedMeetingIDs: deleted, libraryMetadata: metadata)
        try await apply(result, to: name, using: engine)
        return result
    }
    private func record(_ bytes: Data, on name: String, into meeting: Meeting) async throws -> Meeting {
        let file = root.appendingPathComponent("\(UUID().uuidString).wav")
        try bytes.write(to: file)
        return try await MeetingStore(rootURL: local(name)).importAudio(from: file, into: meeting, source: .microphone)
    }
    private func audioBytes(_ count: Int, seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }
    /// A conversation full of words that must stay private.
    private func privateMeeting(_ audio: Data? = nil, on name: String) async throws -> Meeting {
        var meeting = Meeting(title: "Zanzibar offsite")
        if let audio { meeting = try await record(audio, on: name, into: meeting) }
        meeting.setNotes("Quokka budget is approved")
        meeting.speakers = [Speaker(id: "S1", name: "Thistlewood")]
        if let track = meeting.tracks.first {
            meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [.init(trackID: track.id, start: 0, end: 3, text: "Marmalade forecast")])]
        }
        meeting.setSummary(MeetingSummary(overview: "Pemberton signs off"))
        return meeting
    }
    /// Every file under the sync folder, by path relative to it, and its bytes.
    private func remoteTree() throws -> [String: Data] {
        var tree: [String: Data] = [:]
        let base = remote.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: remote, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            tree[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return tree
    }
    private func assertNoPlaintext(file: StaticString = #filePath, line: UInt = #line) throws {
        for (path, bytes) in try remoteTree() {
            let text = String(decoding: bytes, as: UTF8.self)
            for marker in markers { XCTAssertFalse(text.contains(marker), "\(marker) in \(path)", file: file, line: line) }
        }
    }
    private func manifest() throws -> SyncManifest { try SyncManifest.decode(Data(contentsOf: remote.appendingPathComponent("daybook-sync.json"))) }
    private func files(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent(directory).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: The manifest gate

    func testTheVersionOneEngineRefusesAnEncryptedLibraryAndChangesNothing() async throws {
        let mac = try mac()
        let meeting = try await privateMeeting(audioBytes(3000, seed: 1), on: "Mac")
        try await pass(mac, "Mac", [meeting])
        try await mac.enableSealing()
        try await pass(mac, "Mac", [meeting])
        XCTAssertEqual(try manifest().schemaVersion, 2)
        let before = try remoteTree()

        let legacy = try LegacyLibrarySyncEngine(localRoot: local("Old"), remoteRoot: remote, deviceID: "Old")
        do {
            _ = try await legacy.synchronize(meetings: [Meeting(title: "Made on an old Mac")])
            XCTFail("The version 1 engine synced an encrypted library")
        } catch LegacyLibrarySyncError.unsupportedVersion(let version) {
            XCTAssertEqual(version, 2)
        }
        XCTAssertEqual(try remoteTree(), before, "The version 1 engine changed the sync folder")

        // A newer format than this one reads as newer, and changes nothing either.
        var newer = try JSONSerialization.jsonObject(with: Data(contentsOf: remote.appendingPathComponent("daybook-sync.json"))) as! [String: Any]
        newer["schemaVersion"] = 3
        try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys]).write(to: remote.appendingPathComponent("daybook-sync.json"))
        let frozen = try remoteTree()
        do { _ = try await mac.synchronize(meetings: [meeting]); XCTFail() } catch LibrarySyncError.unsupportedVersion(let version) { XCTAssertEqual(version, 3) }
        XCTAssertEqual(try remoteTree(), frozen)
    }

    func testAnUnknownSealingSchemeReadsAsANewerDaybook() throws {
        let key = LibraryKey.generate(libraryID: UUID(), createdBy: "x")
        var manifest = SyncManifest(libraryID: key.libraryID)
        manifest.schemaVersion = 2
        manifest.sealing = .init(scheme: "DBSEAL-9", current: key.idHex, sealedSince: Date(), migrator: "x", keys: [.init(id: key.idHex, created: Date())])
        XCTAssertThrowsError(try SyncManifest.checked(manifest)) { XCTAssertEqual($0 as? LibrarySyncError, .unsupportedVersion(2)) }
        manifest.sealing?.scheme = SyncManifest.Sealing.currentScheme
        manifest.sealing?.current = String(repeating: "0", count: 32)
        XCTAssertThrowsError(try SyncManifest.checked(manifest)) { XCTAssertEqual($0 as? LibrarySyncError, .invalidManifest) }
        manifest.sealing = nil
        XCTAssertThrowsError(try SyncManifest.checked(manifest)) { XCTAssertEqual($0 as? LibrarySyncError, .unsupportedVersion(2)) }
        // A newer scheme reads as newer whatever shape its description has.
        let newer = Data(#"{"format":"DaybookSync","schemaVersion":2,"libraryID":"\#(key.libraryID.uuidString)","sealing":{"scheme":"DBSEAL-9","current":5}}"#.utf8)
        XCTAssertThrowsError(try SyncManifest.decode(newer)) { XCTAssertEqual($0 as? LibrarySyncError, .unsupportedVersion(2)) }
        let odd = Data(#"{"format":"DaybookSync","schemaVersion":2,"libraryID":"\#(key.libraryID.uuidString)","sealing":"elsewhere"}"#.utf8)
        XCTAssertThrowsError(try SyncManifest.decode(odd)) { XCTAssertEqual($0 as? LibrarySyncError, .unsupportedVersion(2)) }
    }

    func testMergingManifestVersionsIsTheSameInEitherOrder() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let a = SyncManifest.Sealing(current: String(repeating: "a", count: 32), sealedSince: start, migrator: "Mac",
                                     keys: [.init(id: String(repeating: "a", count: 32), created: start, recovery: "wrap-a")])
        let b = SyncManifest.Sealing(current: String(repeating: "b", count: 32), sealedSince: start.addingTimeInterval(1), migrator: "Phone",
                                     keys: [.init(id: String(repeating: "a", count: 32), created: start, recovery: "wrap-b"),
                                            .init(id: String(repeating: "b", count: 32), created: start.addingTimeInterval(1))])
        XCTAssertEqual(a.merged(with: b), b.merged(with: a))
        XCTAssertEqual(a.merged(with: b).current, String(repeating: "b", count: 32))
        XCTAssertEqual(a.merged(with: b).migrator, "Phone")
        XCTAssertEqual(a.merged(with: b).keys.first?.recovery, "wrap-a")
        var c = b; c.migrator = "Other"
        XCTAssertEqual(b.merged(with: c), c.merged(with: b))
    }

    func testAPlaintextLibraryIsWrittenExactlyAsBefore() async throws {
        let mac = try mac()
        try await pass(mac, "Mac", [try await privateMeeting(audioBytes(1000, seed: 2), on: "Mac")])
        let manifestBytes = try Data(contentsOf: remote.appendingPathComponent("daybook-sync.json"))
        let decoded = try JSONSerialization.jsonObject(with: manifestBytes) as! [String: Any]
        XCTAssertEqual(Set(decoded.keys), ["format", "schemaVersion", "libraryID"])
        XCTAssertEqual(decoded["schemaVersion"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("Sealed").path))
        XCTAssertEqual(files("Events").count, 1)
        XCTAssertEqual(files("Blobs").count, 1)
        XCTAssertFalse(LibrarySyncEngine.sealsNewLibraries, "New libraries stay plaintext until the owner's device checks pass")
    }

    func testADeviceRemembersSyncingAnEncryptedLibraryBeforeAnyPass() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac")
        try await pass(phone, "Phone")
        XCTAssertFalse(LibrarySyncEngine.hasSyncedEncryptedLibrary(localRoot: local("Phone")))
        try await mac.enableSealing()
        try await pass(phone, "Phone")
        XCTAssertTrue(LibrarySyncEngine.hasSyncedEncryptedLibrary(localRoot: local("Phone")), "the iPhone keeps it out of backups at launch")
        // Waiting for the key counts too: the library is encrypted.
        let waiting = try self.phone("Waiting", keys: MemoryLibraryKeyStore())
        do { _ = try await waiting.synchronize(meetings: []); XCTFail() } catch LibrarySyncError.keyUnavailable {}
        XCTAssertTrue(LibrarySyncEngine.hasSyncedEncryptedLibrary(localRoot: local("Waiting")))
        // Another iCloud account's library may well be plaintext.
        LibrarySyncEngine.forgetSealedLibrary(localRoot: local("Phone"), remoteRoot: remote)
        XCTAssertFalse(LibrarySyncEngine.hasSyncedEncryptedLibrary(localRoot: local("Phone")))
    }

    func testADowngradedManifestPausesSync() async throws {
        let mac = try mac()
        try await pass(mac, "Mac", [Meeting(title: "Before")])
        try await mac.enableSealing()
        try await pass(mac, "Mac")
        let url = remote.appendingPathComponent("daybook-sync.json")
        let sealed = try Data(contentsOf: url)
        let eventsBefore = files("Events")

        // Replaced by a plaintext manifest of the same library, or of another one, or removed.
        let id = try manifest().libraryID
        for replacement in [try SyncManifest(libraryID: id).encoded(), try SyncManifest(libraryID: UUID()).encoded(), nil] {
            if let replacement { try replacement.write(to: url) } else { try FileManager.default.removeItem(at: url) }
            let restarted = try self.mac()
            do { _ = try await restarted.synchronize(meetings: [Meeting(title: "After")]); XCTFail("Published into a downgraded library") }
            catch LibrarySyncError.sealingRemoved {}
            XCTAssertEqual(files("Events"), eventsBefore)
        }
        // Another device that never synced it encrypted follows what's there.
        try SyncManifest(libraryID: id).encoded().write(to: url)
        let other = try self.mac("Other")
        try await pass(other, "Other", [Meeting(title: "Plain")])
        // Choosing another iCloud account forgets it.
        LibrarySyncEngine.forgetSealedLibrary(localRoot: local("Mac"), remoteRoot: remote)
        try await pass(try self.mac(), "Mac")
        try sealed.write(to: url)
    }

    func testVersionsOfOneEncryptedLibraryMergeTheirKeys() async throws {
        let mac = try mac()
        try await pass(mac, "Mac")
        let first = try await mac.enableSealing()
        let url = remote.appendingPathComponent("daybook-sync.json")
        // Another device enabled it at the same moment with a key of its own: iCloud kept its version as a copy.
        let second = LibraryKey.generate(libraryID: first.libraryID, createdBy: "Other", now: first.createdAt.addingTimeInterval(5))
        try keychain.store(second)
        var theirs = try manifest()
        theirs.sealing = .init(current: second.idHex, sealedSince: second.createdAt, migrator: "Other", keys: [.init(id: second.idHex, created: second.createdAt)])
        try theirs.encoded().write(to: remote.appendingPathComponent("daybook-sync 2.json"))
        try await pass(mac, "Mac", [Meeting(title: "Either way")])
        let merged = try XCTUnwrap(try manifest().sealing)
        XCTAssertEqual(Set(merged.keys.map(\.id)), [first.idHex, second.idHex])
        XCTAssertEqual(merged.current, second.idHex, "The newer key is current on every device")
        XCTAssertEqual(merged.migrator, "Other")
        XCTAssertNotNil(try Data(contentsOf: url))

        // A different library's encrypted manifest beside it can't be merged: sync pauses.
        var foreign = theirs
        foreign.libraryID = UUID()
        try foreign.encoded().write(to: remote.appendingPathComponent("daybook-sync 3.json"))
        do { _ = try await mac.synchronize(meetings: []); XCTFail() } catch LibrarySyncError.manifestConflict {}
    }

    // MARK: Sealed journal

    func testEncryptedReplicasConvergeAndTheSyncFolderHoldsNoPlaintext() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac")
        try await mac.enableSealing()
        let meeting = try await privateMeeting(audioBytes(5000, seed: 3), on: "Mac")
        let metadata = Data(#"{"folders":[{"name":"Marmalade"}]}"#.utf8)
        let published = try await pass(mac, "Mac", [meeting], metadata: metadata).meetings[0]
        let pulled = try await pass(phone, "Phone")
        XCTAssertEqual(pulled.meetings, [published])
        XCTAssertEqual(pulled.metadataVersions, [metadata])
        XCTAssertEqual(pulled.warnings, [])
        // An edit on the phone, and a concurrent one on the Mac, converge.
        var onPhone = published, onMac = published
        onPhone.setNotes("Quokka budget is approved\nAnd Zanzibar is booked")
        onMac.title = "Zanzibar offsite (moved)"
        try await pass(phone, "Phone", [onPhone])
        let merged = try await pass(mac, "Mac", [onMac]).meetings[0]
        XCTAssertEqual(merged.title, onMac.title); XCTAssertEqual(merged.notes, onPhone.notes)
        let back = try await pass(phone, "Phone", [onPhone]).meetings[0]
        XCTAssertEqual(back, merged)
        // Audio on the phone, fetched and opened.
        let audio = try await phone.fetchAudio(for: published.tracks[0], in: published.id, options: fast)
        XCTAssertEqual(try Data(contentsOf: audio), try Data(contentsOf: local("Mac").appendingPathComponent("Meetings/\(published.id)/\(published.tracks[0].relativePath)")))
        // A second Mac installs it as an eager replica.
        let other = try self.mac("Other")
        let eager = try await pass(other, "Other")
        XCTAssertEqual(eager.meetings, [merged]); XCTAssertEqual(eager.pendingDownloads, 0)
        _ = try await phone.knownDevices()

        XCTAssertTrue(files("Events").isEmpty); XCTAssertTrue(files("Metadata").isEmpty); XCTAssertTrue(files("Blobs").isEmpty)
        XCTAssertFalse(files("Sealed/Events").isEmpty); XCTAssertEqual(files("Sealed/Blobs").count, 1)
        try assertNoPlaintext()
        // Names are keyed: the audio object isn't findable by its SHA-256.
        XCTAssertFalse(try remoteTree().keys.contains { $0.contains(published.tracks[0].sha256) })
    }

    func testAReplicaWithoutTheKeyWaitsWritesNothingAndPublishesOnceItArrives() async throws {
        let mac = try mac()
        try await pass(mac, "Mac")
        let key = try await mac.enableSealing()
        let published = try await pass(mac, "Mac", [Meeting(title: "From the Mac")]).meetings[0]
        // iCloud Keychain hasn't brought the key to the phone (or is off there).
        let phoneKeys = MemoryLibraryKeyStore()
        let phone = try phone(keys: phoneKeys)
        let local = Meeting(title: "Recorded offline")
        let before = try remoteTree().filter { !$0.key.hasPrefix("Devices/") }
        do { _ = try await phone.synchronize(meetings: [local]); XCTFail("Synced without the key") }
        catch LibrarySyncError.keyUnavailable(let id) { XCTAssertEqual(id, key.idHex) }
        XCTAssertEqual(try remoteTree().filter { !$0.key.hasPrefix("Devices/") }, before, "Nothing but presence is written without the key")
        let waiting = await phone.waitingForKey
        XCTAssertEqual(waiting, key.idHex)
        // Its presence says it's waiting, without a name.
        let devices = try await mac.knownDevices()
        let seen = try XCTUnwrap(devices.first { $0.id == "Phone" })
        XCTAssertEqual(seen.keyState, SyncDeviceKeyState(state: .waiting, id: key.idHex))
        XCTAssertNil(seen.displayName)
        XCTAssertTrue(seen.readsEncryptedLibraries)

        // The key arrives: the next pass reads and publishes.
        try phoneKeys.store(key)
        let result = try await pass(self.phone(keys: phoneKeys), "Phone", [local])
        XCTAssertEqual(Set(result.meetings.map(\.id)), [published.id, local.id])
        XCTAssertEqual(result.publishedEvents, 1)
        let onMac = try await pass(mac, "Mac", [published])
        XCTAssertEqual(Set(onMac.meetings.map(\.id)), [published.id, local.id])
        let ready = try await mac.knownDevices().first { $0.id == "Phone" }
        XCTAssertEqual(ready?.keyState, SyncDeviceKeyState(state: .ready, id: key.idHex))
        XCTAssertEqual(ready?.displayName, "Pocket")
    }

    func testARecoveryKeyOpensTheLibraryOnADeviceWithoutIt() async throws {
        let mac = try mac()
        try await pass(mac, "Mac", [Meeting(title: "Kept")])
        let recovery = RecoveryKey.generate()
        let key = try await mac.enableSealing(recovery: recovery)
        try await pass(mac, "Mac")
        XCTAssertNotNil(try manifest().sealing?.keys.first?.recovery)
        let alone = MemoryLibraryKeyStore()
        let phone = try phone(keys: alone)
        do { _ = try await phone.synchronize(meetings: []); XCTFail() } catch LibrarySyncError.keyUnavailable {}
        let wrong = try await phone.recoverKeys(with: RecoveryKey.generate())
        XCTAssertEqual(wrong, 0)
        let right = try await phone.recoverKeys(with: recovery)
        XCTAssertEqual(right, 1)
        XCTAssertEqual(try alone.keys(for: key.libraryID).map(\.id), [key.id])
        let result = try await pass(phone, "Phone")
        XCTAssertEqual(result.meetings.map(\.title), ["Kept"])
        // Saved later instead, it wraps the current key.
        let later = RecoveryKey.generate()
        try await mac.saveRecoveryKey(later)
        let fresh = MemoryLibraryKeyStore()
        let recovered = try await self.phone("Third", keys: fresh).recoverKeys(with: later)
        XCTAssertEqual(recovered, 1)
    }

    // MARK: Sealed objects

    func testDamagedSealedAudioIsRefusedAndNothingIsInstalled() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac")
        try await mac.enableSealing()
        let published = try await pass(mac, "Mac", [try await record(audioBytes(200_000, seed: 4), on: "Mac", into: Meeting(title: "Audio"))]).meetings[0]
        try await pass(phone, "Phone")
        let object = remote.appendingPathComponent("Sealed/Blobs").appendingPathComponent(files("Sealed/Blobs")[0])
        var bytes = try Data(contentsOf: object)
        bytes[bytes.count / 2] ^= 0xff
        try bytes.write(to: object)
        do { _ = try await phone.fetchAudio(for: published.tracks[0], in: published.id, options: fast); XCTFail() }
        catch AudioFetchError.integrityMismatch {}
        let folder = local("Phone").appendingPathComponent("Meetings/\(published.id)/Originals")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(published.tracks[0].fileName).path))
        XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".") }, [])
        // An eager Mac doesn't apply the conversation with damaged audio.
        let other = try await self.mac("Other").synchronize(meetings: [])
        XCTAssertTrue(other.meetings.isEmpty)
        XCTAssertTrue(other.warnings.contains { $0.contains("damaged") })
    }

    func testAPhoneRecordingArrivesOnAnEagerMacAndIsPublishedByReference() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac")
        try await mac.enableSealing()
        try await pass(phone, "Phone")
        let recorded = try await record(audioBytes(70_000, seed: 5), on: "Phone", into: Meeting(title: "On the go"))
        let sent = try await pass(phone, "Phone", [recorded]).meetings[0]
        XCTAssertEqual(files("Sealed/Blobs").count, 1)
        let onMac = try await pass(mac, "Mac")
        XCTAssertEqual(onMac.meetings, [sent])
        let installed = local("Mac").appendingPathComponent("Meetings/\(sent.id)/\(sent.tracks[0].relativePath)")
        XCTAssertEqual(SyncDigest.sha256(data: try Data(contentsOf: installed)), sent.tracks[0].sha256)
        // A second phone that never fetched the audio edits the conversation: it publishes the track by reference.
        let second = try self.phone("Second")
        var edited = try await pass(second, "Second").meetings[0]
        edited.setNotes("Edited without the audio")
        let published = try await pass(second, "Second", [edited])
        XCTAssertEqual(published.publishedEvents, 1); XCTAssertEqual(published.warnings, [])
        let onMacAgain = try await pass(mac, "Mac", [sent])
        XCTAssertEqual(onMacAgain.meetings[0].notes, edited.notes)
    }

    func testOriginalsRecordedHereStayUntilAnotherDeviceHoldsTheKey() async throws {
        let phone = try phone(budget: 1)
        try await pass(phone, "Phone")
        try await phone.enableSealing()
        let recorded = try await record(audioBytes(50_000, seed: 6), on: "Phone", into: Meeting(title: "Only here"))
        try await pass(phone, "Phone", [recorded])
        let kept = try await phone.evictAudio()
        XCTAssertTrue(kept.evicted.isEmpty, "Evicted the only copy this device could open")
        // A Mac with the key appears.
        let mac = try mac()
        try await pass(mac, "Mac")
        let evicted = try await phone.evictAudio()
        XCTAssertEqual(evicted.evicted.count, 1)
    }

    // MARK: The sealer

    func testHistoryFromBeforeIsSealedAndRetiredWithoutRepublishing() async throws {
        let mac = try mac(), phone = try phone()
        // A plaintext library with history: an edit, a deleted conversation, settings, audio.
        let kept = try await pass(mac, "Mac", [try await privateMeeting(audioBytes(9000, seed: 7), on: "Mac")]).meetings[0]
        var edited = kept; edited.setNotes("Quokka budget is approved\nSecond paragraph")
        let gone = try await record(audioBytes(4000, seed: 8), on: "Mac", into: Meeting(title: "Thistlewood interview"))
        try await pass(mac, "Mac", [edited, gone], metadata: Data(#"{"folders":["Marmalade"]}"#.utf8))
        try await pass(phone, "Phone")
        try await pass(mac, "Mac", [edited], deleted: [gone.id])
        try await pass(phone, "Phone")
        XCTAssertFalse(files("Events").isEmpty)

        let start = Date()
        await mac.setSealerClock { start }
        let recovery = RecoveryKey.generate()
        try await mac.enableSealing(recovery: recovery)
        let sealing = try await pass(mac, "Mac", [edited])
        XCTAssertEqual(sealing.publishedEvents, 0, "Sealing history republishes nothing")
        let progressValue = await mac.sealerProgress
        let progress = try XCTUnwrap(progressValue)
        XCTAssertEqual(progress.remaining, 0)
        XCTAssertGreaterThan(progress.sealed, 0)
        XCTAssertTrue(progress.waitingFor.contains(.gracePeriod))
        // Every live event, the deletion (not the deleted conversation's history), the settings, and the live audio.
        XCTAssertEqual(files("Sealed/Events").count, files("Events").count - 1)
        XCTAssertEqual(files("Sealed/Metadata").count, files("Metadata").count)
        XCTAssertEqual(files("Sealed/Blobs").count, 1)
        // The other device follows without publishing anything again.
        let follow = try await pass(phone, "Phone", try await MeetingStore(rootURL: local("Phone")).list())
        XCTAssertEqual(follow.publishedEvents, 0); XCTAssertEqual(follow.warnings, [])
        XCTAssertEqual(follow.meetings.map(\.id), [kept.id])

        // A week later: the plaintext goes.
        await mac.setSealerClock { start.addingTimeInterval(LibrarySyncEngine.retirementGrace + 60) }
        try await pass(mac, "Mac", [edited])
        let retiredValue = await mac.sealerProgress
        let retired = try XCTUnwrap(retiredValue)
        XCTAssertTrue(retired.legacyRetired, "\(retired)")
        XCTAssertNotNil(try manifest().sealing?.legacyRetired)
        XCTAssertTrue(files("Events").isEmpty); XCTAssertTrue(files("Metadata").isEmpty); XCTAssertTrue(files("Blobs").isEmpty)
        try assertNoPlaintext()
        // Everything still syncs: a new device gets the live conversation and its audio.
        let fresh = try await pass(try self.mac("Fresh"), "Fresh")
        XCTAssertEqual(fresh.meetings.map(\.notes), [edited.notes]); XCTAssertEqual(fresh.pendingDownloads, 0); XCTAssertEqual(fresh.warnings, [])
        XCTAssertEqual(fresh.deletedMeetingIDs, [gone.id])
        let phoneAgain = try await pass(phone, "Phone", try await MeetingStore(rootURL: local("Phone")).list())
        XCTAssertEqual(phoneAgain.publishedEvents, 0); XCTAssertEqual(phoneAgain.pendingDownloads, 0); XCTAssertEqual(phoneAgain.warnings, [])
    }

    func testRetirementWaitsForAnotherDeviceOrARecoveryKey() async throws {
        let mac = try mac()
        try await pass(mac, "Mac", [Meeting(title: "Alone")])
        let start = Date()
        await mac.setSealerClock { start.addingTimeInterval(LibrarySyncEngine.retirementGrace * 2) }
        try await mac.enableSealing()
        try await pass(mac, "Mac")
        try await pass(mac, "Mac")
        let progressValue = await mac.sealerProgress
        let progress = try XCTUnwrap(progressValue)
        XCTAssertFalse(progress.legacyRetired)
        XCTAssertTrue(progress.waitingFor.contains(.anotherDeviceOrRecoveryKey), "\(progress)")
        XCTAssertFalse(files("Events").isEmpty)
        try await mac.saveRecoveryKey(RecoveryKey.generate())
        try await pass(mac, "Mac")
        let retiredValue = await mac.sealerProgress
        let retired = try XCTUnwrap(retiredValue)
        XCTAssertTrue(retired.legacyRetired, "\(retired)")
        XCTAssertTrue(files("Events").isEmpty)
    }

    func testStaleLegacyWritesAndRestoredFilesAreSealed() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac")
        try await pass(phone, "Phone")
        let start = Date()
        await mac.setSealerClock { start.addingTimeInterval(LibrarySyncEngine.retirementGrace * 2) }
        try await mac.enableSealing(recovery: RecoveryKey.generate())
        try await pass(mac, "Mac")
        try await pass(mac, "Mac")
        XCTAssertNotNil(try manifest().sealing?.legacyRetired)
        // A plaintext entry appears afterwards (a pass that began before the manifest changed, or one restored from
        // iCloud.com's Data Recovery): it's read, sealed, and deleted.
        let late = Meeting(title: "Zanzibar after the switch")
        let legacy = try LegacyLibrarySyncEngine(localRoot: local("Late"), remoteRoot: root.appendingPathComponent("Scratch"), deviceID: "Mac")
        _ = try await legacy.synchronize(meetings: [late])
        for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Scratch/Events").path) {
            try FileManager.default.copyItem(at: root.appendingPathComponent("Scratch/Events/\(name)"), to: remote.appendingPathComponent("Events/\(name)"))
        }
        let seen = try await pass(phone, "Phone")
        XCTAssertEqual(seen.meetings.map(\.title), [late.title])
        try await pass(mac, "Mac")
        XCTAssertTrue(files("Events").isEmpty)
        let after = try await pass(try self.phone("Fresh"), "Fresh")
        XCTAssertEqual(after.meetings.map(\.title), [late.title])
        try assertNoPlaintext()
    }

    func testRotationReSealsLiveContentAndErasesDeletedConversations() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac")
        let first = try await mac.enableSealing(recovery: RecoveryKey.generate())
        let kept = try await pass(mac, "Mac", [try await record(audioBytes(8000, seed: 9), on: "Mac", into: Meeting(title: "Kept"))]).meetings[0]
        let gone = try await pass(mac, "Mac", [kept, try await record(audioBytes(6000, seed: 10), on: "Mac", into: Meeting(title: "Gone"))]).meetings
            .first { $0.title == "Gone" }!
        try await pass(mac, "Mac", [kept], deleted: [gone.id])
        try await pass(phone, "Phone")
        let goneObject = try XCTUnwrap(first.objectName(.blob, plaintextSHA256: gone.tracks[0].sha256))
        XCTAssertTrue(files("Sealed/Blobs").contains(goneObject))

        let start = Date()
        await mac.setSealerClock { start }
        let second = try await mac.rotateKey(now: start)
        XCTAssertNotEqual(second.id, first.id)
        try await pass(mac, "Mac", [kept])
        let waitingValue = await mac.sealerProgress
        let waiting = try XCTUnwrap(waitingValue)
        XCTAssertFalse(waiting.oldKeysRetired)
        // The phone still reads everything, and now holds the new key too (one keychain).
        let follow = try await pass(phone, "Phone", try await MeetingStore(rootURL: local("Phone")).list())
        XCTAssertEqual(follow.publishedEvents, 0); XCTAssertEqual(follow.warnings, [])
        await mac.setSealerClock { start.addingTimeInterval(LibrarySyncEngine.retirementGrace + 60) }
        try await pass(mac, "Mac", [kept])
        let doneValue = await mac.sealerProgress
        let done = try XCTUnwrap(doneValue)
        XCTAssertTrue(done.oldKeysRetired, "\(done)")
        XCTAssertEqual(try manifest().sealing?.keys.map(\.id), [second.idHex])
        // The old key stays in the keychain (a file sealed with it later stays readable); its files are gone.
        XCTAssertEqual(Set(try keychain.keys(for: first.libraryID).map(\.id)), [first.id, second.id])
        for directory in ["Sealed/Events", "Sealed/Metadata", "Sealed/Blobs"] {
            for name in files(directory) {
                let header = try XCTUnwrap(SealedObject.header(of: Data(contentsOf: remote.appendingPathComponent("\(directory)/\(name)"))))
                XCTAssertEqual(header.keyID, second.id, "\(directory)/\(name) is still under the old key")
            }
        }
        XCTAssertFalse(files("Sealed/Blobs").contains(goneObject), "A deleted conversation's audio is erased")
        XCTAssertEqual(files("Sealed/Blobs").count, 1)
        // Everything live still syncs, under the new key only.
        let fresh = try await pass(try self.mac("Fresh"), "Fresh")
        XCTAssertEqual(fresh.meetings.map(\.id), [kept.id]); XCTAssertEqual(fresh.pendingDownloads, 0); XCTAssertEqual(fresh.warnings, [])
        XCTAssertEqual(fresh.deletedMeetingIDs, [gone.id])
        // Concurrent edits after the old key's files are gone merge against a base read again under the new key.
        var onMac = try await MeetingStore(rootURL: local("Mac")).load(kept.id)
        var onPhone = try await MeetingStore(rootURL: local("Phone")).load(kept.id)
        onMac.title = "Kept, renamed"; onPhone.setNotes("Added on the phone")
        try await pass(mac, "Mac", [onMac])
        try await pass(phone, "Phone", [onPhone])
        let merged = try await pass(mac, "Mac", [onMac])
        XCTAssertEqual(merged.meetings.first?.title, "Kept, renamed"); XCTAssertEqual(merged.meetings.first?.notes, "Added on the phone")
        XCTAssertEqual(merged.warnings, [])
    }

    // MARK: The courier

    func testSealedFilesTravelByCourierAndArePrunedByTheirBytes() async throws {
        let mac = try mac(), phone = try phone()
        try await pass(mac, "Mac")
        try await mac.enableSealing()
        try await pass(phone, "Phone")
        let known = await phone.libraryID
        let libraryID = try XCTUnwrap(known)
        let bytes = audioBytes(30_000, seed: 11)
        let recorded = try await record(bytes, on: "Phone", into: Meeting(title: "Zanzibar call"))
        let filed = try await pass(phone, "Phone", [recorded])
        XCTAssertEqual(filed.writtenFiles.count, 2)
        XCTAssertTrue(filed.writtenFiles.allSatisfy { $0.path.hasPrefix("Sealed/") && $0.isContentAddressed && $0.isSealed })
        for file in filed.writtenFiles {
            XCTAssertEqual(SyncDigest.sha256(data: try Data(contentsOf: remote.appendingPathComponent(file.path))), file.sha256)
            XCTAssertNotEqual(file.path.split(separator: "/").last.map(String.init), file.sha256, "A sealed file isn't named by its bytes")
        }
        // Staged as the courier would, then iCloud Drive lags behind.
        var staged: [SyncJournalFile: URL] = [:]
        for file in filed.writtenFiles {
            let url = root.appendingPathComponent("Courier/\(UUID().uuidString)")
            try phone.copyJournalFile(file, to: url)
            staged[file] = url
            try cloud.withhold(remote.appendingPathComponent(file.path))
        }
        for (file, url) in staged {
            let delivery = try await mac.receiveCourierFile(file, libraryID: libraryID, contents: url)
            XCTAssertEqual(delivery, .stored)
        }
        let delivered = try await pass(mac, "Mac")
        XCTAssertEqual(delivered.meetings.map(\.id), [recorded.id])
        let installed = local("Mac").appendingPathComponent("Meetings/\(recorded.id)/\(recorded.tracks[0].relativePath)")
        XCTAssertEqual(try Data(contentsOf: installed), bytes)
        let waiting = await mac.courierInboxCount()
        XCTAssertEqual(waiting, 2)
        // iCloud Drive brings the same bytes: the inbox copies go.
        for file in filed.writtenFiles { try cloud.deliver(remote.appendingPathComponent(file.path)) }
        try await pass(mac, "Mac", delivered.meetings)
        let left = await mac.courierInboxCount()
        XCTAssertEqual(left, 0)
        try assertNoPlaintext()
    }

    func testForeignDamagedAndMislabelledSealedDeliveriesAreRejected() async throws {
        let mac = try mac()
        try await pass(mac, "Mac")
        let key = try await mac.enableSealing()
        try await pass(mac, "Mac")
        let libraryID = key.libraryID
        func deliver(_ bytes: Data, as path: String) async throws -> CourierDelivery {
            let url = root.appendingPathComponent("Courier/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            return try await mac.receiveCourierFile(SyncJournalFile(path: path, sha256: SyncDigest.sha256(data: bytes), size: Int64(bytes.count)),
                                                    libraryID: libraryID, contents: url)
        }
        let foreignKey = LibraryKey.generate(libraryID: UUID(), createdBy: "x")
        let foreign = SealedObject.seal(Data("{}".utf8), kind: .event, key: foreignKey)
        if case .rejected = try await deliver(foreign.bytes, as: "Sealed/Events/\(foreign.name)") {} else { XCTFail("Accepted another library's file") }
        let blob = SealedObject.seal(Data("audio".utf8), kind: .blob, key: key)
        if case .rejected = try await deliver(blob.bytes, as: "Sealed/Events/\(blob.name)") {} else { XCTFail("Accepted an object in the wrong folder") }
        if case .rejected = try await deliver(Data("plain".utf8), as: "Sealed/Events/\(String(repeating: "a", count: 64))") {} else { XCTFail("Accepted plaintext") }
        // A sealed file that claims to be one thing but holds another is found out when it's read, and skipped.
        let real = SealedObject.seal(Data(#"{"x":1}"#.utf8), kind: .event, key: key)
        let wrongName = String(repeating: "b", count: 64)
        let mislabelled = try await deliver(real.bytes, as: "Sealed/Events/\(wrongName)")
        XCTAssertEqual(mislabelled, .stored)
        let result = try await pass(mac, "Mac")
        XCTAssertTrue(result.meetings.isEmpty)
    }

    func testAPlaintextDeliveryIsNeverWrittenIntoAnEncryptedLibrary() async throws {
        let mac = try mac(), other = try self.mac("Other")
        try await pass(mac, "Mac")
        try await pass(other, "Other")
        let key = try await mac.enableSealing()
        try await pass(other, "Other")
        // A phone still on a plaintext pass sent an entry by courier before it saw the manifest.
        let staging = root.appendingPathComponent("StaleFolder")
        let legacy = try LegacyLibrarySyncEngine(localRoot: local("Stale"), remoteRoot: staging, deviceID: "Stale")
        _ = try await legacy.synchronize(meetings: [Meeting(title: "Zanzibar, late")])
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("Events").path).first)
        let bytes = try Data(contentsOf: staging.appendingPathComponent("Events/\(name)"))
        let file = SyncJournalFile(path: "Events/\(name)", sha256: SyncDigest.sha256(data: bytes), size: Int64(bytes.count))
        for engine in [mac, other] {
            let url = root.appendingPathComponent("Courier/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            let delivery = try await engine.receiveCourierFile(file, libraryID: key.libraryID, contents: url)
            XCTAssertEqual(delivery, .stored)
        }
        // A device that isn't the migrator reads it, and a day later still doesn't write it into the sync folder.
        let seen = try await pass(other, "Other")
        XCTAssertEqual(seen.meetings.map(\.title), ["Zanzibar, late"])
        await other.pruneCourierInbox(now: Date().addingTimeInterval(LibrarySyncEngine.courierPromotionDelay * 2))
        XCTAssertTrue(files("Events").isEmpty)
        // The migrator seals it; then both inbox copies go, and nothing plaintext ever reached the sync folder.
        try await pass(mac, "Mac")
        let sealedName = try XCTUnwrap(key.objectName(.event, plaintextSHA256: String(name.dropLast(5))))
        XCTAssertTrue(files("Sealed/Events").contains(sealedName))
        await other.pruneCourierInbox(now: Date().addingTimeInterval(LibrarySyncEngine.courierPromotionDelay * 2))
        let left = await mac.courierInboxCount(), otherLeft = await other.courierInboxCount()
        XCTAssertEqual(left, 0); XCTAssertEqual(otherLeft, 0)
        XCTAssertTrue(files("Events").isEmpty)
        try assertNoPlaintext()
    }

    func testAnOldKeysFilesStayUntilEveryRecentDeviceHoldsTheNewKey() async throws {
        let macKeys = MemoryLibraryKeyStore(), phoneKeys = MemoryLibraryKeyStore()
        let mac = try mac(keys: macKeys), phone = try phone(keys: phoneKeys)
        try await pass(mac, "Mac", [Meeting(title: "Kept")])
        let first = try await mac.enableSealing(recovery: RecoveryKey.generate())
        try phoneKeys.store(first)
        try await pass(mac, "Mac")
        try await pass(phone, "Phone")
        let start = Date()
        await mac.setSealerClock { start.addingTimeInterval(LibrarySyncEngine.retirementGrace * 3) }
        let second = try await mac.rotateKey(now: start)
        try await pass(mac, "Mac")
        // The phone hasn't got the new key: it waits, and says so.
        do { _ = try await phone.synchronize(meetings: []); XCTFail() } catch LibrarySyncError.keyUnavailable {}
        try await pass(mac, "Mac")
        let waitingValue = await mac.sealerProgress
        let waiting = try XCTUnwrap(waitingValue)
        XCTAssertFalse(waiting.oldKeysRetired)
        XCTAssertTrue(waiting.waitingFor.contains(.devicesWithCurrentKey), "\(waiting)")
        XCTAssertEqual(try manifest().sealing?.keys.count, 2)
        // It arrives.
        try phoneKeys.store(second)
        try await pass(phone, "Phone")
        try await pass(mac, "Mac")
        let doneValue = await mac.sealerProgress
        let done = try XCTUnwrap(doneValue)
        XCTAssertTrue(done.oldKeysRetired, "\(done)")
        XCTAssertEqual(try manifest().sealing?.keys.map(\.id), [second.idHex])
    }

    // MARK: Review fixes

    func testPresenceWrittenBeforeAnyPassSaysNothingPrivate() async throws {
        let mac = try mac()
        try await pass(mac, "Mac")
        try await mac.enableSealing()
        try await pass(mac, "Mac")
        // Another Mac connects: sync writes its presence at once, before its first pass reads the manifest.
        let other = try self.mac("Other")
        try await other.publishActivity(SyncDeviceActivity(recordingConversationID: UUID()))
        try assertNoPlaintext()
        // Without the key, nor the manifest downloaded, it still says nothing private.
        let manifestURL = remote.appendingPathComponent("daybook-sync.json")
        try cloud.evict(manifestURL)
        let third = try self.mac("Third", keys: MemoryLibraryKeyStore())
        try await third.publishPresence()
        try assertNoPlaintext()
        try cloud.deliver(manifestURL)
    }

    func testANewerFormatInsideASealedEntryIsSetAsideNotWaitedFor() async throws {
        let mac = try mac()
        try await pass(mac, "Mac")
        let key = try await mac.enableSealing()
        let meeting = Meeting(title: "Partly newer")
        var newer = SyncEventRecord(meetingID: meeting.id, deviceID: "Future", sequence: 1, parents: [], snapshot: meeting, deleted: false, assets: [])
        newer.schemaVersion = 2
        let newerBytes = try SyncEncoding.data(newer)
        let sealedNewer = SealedObject.seal(newerBytes, kind: .event, key: key)
        try sealedNewer.bytes.write(to: remote.appendingPathComponent("Sealed/Events/\(sealedNewer.name)"))
        var edited = meeting; edited.title = "Partly newer, edited"
        let child = SyncEventRecord(meetingID: meeting.id, deviceID: "Future", sequence: 2, parents: [SyncDigest.sha256(data: newerBytes)],
                                    snapshot: edited, deleted: false, assets: [])
        let sealedChild = SealedObject.seal(try SyncEncoding.data(child), kind: .event, key: key)
        try sealedChild.bytes.write(to: remote.appendingPathComponent("Sealed/Events/\(sealedChild.name)"))
        let result = try await mac.synchronize(meetings: [])
        XCTAssertEqual(result.pendingDownloads, 0, "A descendant of a newer entry isn't a download to wait for")
        XCTAssertTrue(result.warnings.contains { $0.contains("newer version") }, "\(result.warnings)")
        try await mac.acknowledge(result.checkpointID)
    }

    func testADeletionThatArrivesAfterRetirementStillApplies() async throws {
        let mac = try mac(), phone = try phone()
        let unchanged = try await pass(mac, "Mac", [Meeting(title: "Delete me")]).meetings[0]
        let edited = try await pass(mac, "Mac", [unchanged, Meeting(title: "Keep my notes")]).meetings.first { $0.title == "Keep my notes" }!
        try await pass(phone, "Phone")
        // The Mac deletes both while the phone is away; the phone edits one of them meanwhile.
        try await pass(mac, "Mac", [], deleted: [unchanged.id, edited.id])
        let start = Date()
        await mac.setSealerClock { start.addingTimeInterval(LibrarySyncEngine.retirementGrace * 2) }
        try await mac.enableSealing(recovery: RecoveryKey.generate())
        try await pass(mac, "Mac")
        try await pass(mac, "Mac")
        XCTAssertNotNil(try manifest().sealing?.legacyRetired)
        XCTAssertTrue(files("Events").isEmpty)
        var notes = try await MeetingStore(rootURL: local("Phone")).load(edited.id)
        notes.setNotes("Written on the phone while it was away")
        let back = try await pass(phone, "Phone", [try await MeetingStore(rootURL: local("Phone")).load(unchanged.id), notes])
        XCTAssertEqual(back.pendingDownloads, 0, "\(back.warnings)")
        XCTAssertTrue(back.deletedMeetingIDs.isSuperset(of: [unchanged.id, edited.id]))
        XCTAssertEqual(back.meetings.map(\.notes), ["Written on the phone while it was away"], "What it added is kept as a new conversation")
    }
}

