import CryptoKit
import DaybookCore
import DaybookLink
import Foundation
import XCTest
@testable import DaybookKit

/// An encrypted library through `LibrarySyncController` (docs/icloud-sync.md, "Encryption"): turning it on, a device
/// waiting for the key and getting it from a paired device or a recovery key, and the courier carrying sealed files in
/// their own zone, which an earlier Daybook ignores. iCloud Keychain is a `MemoryLibraryKeyStore`, CloudKit an
/// `InMemoryCourierService`, and a temporary folder the iCloud container.
@MainActor
final class LibrarySyncEncryptionTests: XCTestCase {
    private var root: URL!
    private var service: InMemoryCourierService!
    private var suites: [String] = []
    private var controllers: [LibrarySyncController] = []
    private let fm = FileManager.default
    private var container: URL { root.appendingPathComponent("Container", isDirectory: true) }

    private struct Device {
        let library: LibraryController
        let sync: LibrarySyncController
        let courier: InMemoryCourier
        let root: URL
    }

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("DaybookEncryption-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        service = InMemoryCourierService()
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try? fm.removeItem(at: root)
    }

    /// `automatic`: as the apps do, a new library starts encrypted and a plaintext one encrypts itself. Otherwise a
    /// library starts plaintext and is encrypted only when a test turns it on, as from Settings.
    private func device(_ name: String, phone: Bool, role: CourierRole, keys: MemoryLibraryKeyStore?, automatic: Bool = false,
                        zones: Set<String> = [CloudKitCourier.zoneName, CloudKitCourier.sealedZoneName]) async throws -> Device {
        let libraryRoot = root.appendingPathComponent(name, isDirectory: true)
        let suite = root.appendingPathComponent("Preferences-\(name)-\(UUID().uuidString)").path
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(name, forKey: "syncDeviceID")
        let sync = LibrarySyncController(localRoot: libraryRoot, defaults: defaults, identityStore: .unavailable)
        controllers.append(sync)
        sync.replica = phone ? .phone(displayName: name) : .mac(displayName: name, canProcess: true)
        sync.replica.keyStore = keys
        sync.replica.sealsNewLibrary = automatic
        sync.encryptsAutomatically = automatic
        let courier = InMemoryCourier(service: service, directory: libraryRoot.appendingPathComponent("Sync/Courier"), deviceID: name, zones: zones)
        sync.courier = courier
        sync.courierRole = role
        sync.syncDebounce = nil
        let library = LibraryController(rootURL: libraryRoot, sync: sync)
        try await library.load()
        sync.onSyncRequested = { _ = await library.synchronize() }
        try sync.connect(to: container, monitorChanges: false)
        try await wait("the courier to start") { sync.courierStatus.availability == .available }
        return Device(library: library, sync: sync, courier: courier, root: libraryRoot)
    }

    private func wait(_ what: String, timeout: Duration = .seconds(10), until condition: () async -> Bool) async throws {
        let scale = Double(ProcessInfo.processInfo.environment["DAYBOOK_TEST_TIMEOUT_SCALE"] ?? "") ?? 1
        let deadline = ContinuousClock.now + timeout * scale
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw TimedOut(description: "Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct TimedOut: Error, CustomStringConvertible { var description: String }

    @discardableResult
    private func pass(_ device: Device, file: StaticString = #filePath, line: UInt = #line) async -> SyncApplied? {
        let applied = await device.library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true, device.sync.status, file: file, line: line)
        return applied
    }

    private func record(on device: Device, bytes: Data, title: String) async throws -> UUID {
        let file = root.appendingPathComponent("Incoming-\(UUID().uuidString).wav")
        try bytes.write(to: file)
        let id = device.library.newMeeting(title: title)
        await device.library.acquireLock()
        _ = try await device.library.ingest(file, into: id, provenance: .file(source: .microphone))
        device.library.releaseLock()
        await device.library.flush()
        return id
    }

    private func audioBytes(_ count: Int, seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ Int(seed)) }) }

    // MARK: Turning it on

    /// A presence record as Daybook 0.3.0 writes one: no features, so that iPhone can't read an encrypted library.
    private func writeEarlierDaybookPresence(_ name: String, lastSeen: Date, id: String? = nil) throws {
        let deviceID = id ?? name
        let record: [String: Any] = ["format": "DaybookDevice", "schemaVersion": 1, "deviceID": deviceID, "deviceClass": "phone",
                                     "displayName": name, "canProcess": false, "audioPolicy": "onDemand",
                                     "lastSeen": ISO8601DateFormatter().string(from: lastSeen)]
        let directory = container.appendingPathComponent("Devices", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = SHA256.hash(data: Data(deviceID.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent(file))
    }

    func testANewLibraryStartsEncrypted() async throws {
        let keychain = MemoryLibraryKeyStore()
        let mac = try await device("Mac", phone: false, role: .receive, keys: keychain, automatic: true)
        await pass(mac)
        guard case .on(let summary) = mac.sync.encryption else { return XCTFail("\(mac.sync.encryption)") }
        XCTAssertTrue(summary.hasKey); XCTAssertTrue(summary.isMigrator)
        // iCloud Keychain brings the key to the iPhone.
        let phone = try await device("Phone", phone: true, role: .send, keys: keychain, automatic: true)
        await pass(phone)
        XCTAssertTrue(phone.sync.encryption.isOn)
    }

    func testAPlaintextLibraryEncryptsItselfOnceEveryDeviceInUseCanReadIt() async throws {
        let keychain = MemoryLibraryKeyStore()
        // A library from before 0.4.1, which an iPhone on Daybook 0.3.0 synced yesterday.
        let mac = try await device("Mac", phone: false, role: .receive, keys: keychain)
        await pass(mac)
        try writeEarlierDaybookPresence("Old iPhone", lastSeen: Date().addingTimeInterval(-86_400))
        mac.sync.encryptsAutomatically = true
        await pass(mac)
        await mac.sync.encryptOnceEveryDeviceCan()
        XCTAssertEqual(mac.sync.encryption, .off, "That iPhone would stop syncing")
        // Not seen for more than 30 days, it no longer holds the library back; it says to update when it's back.
        try writeEarlierDaybookPresence("Old iPhone", lastSeen: Date().addingTimeInterval(-31 * 86_400))
        await pass(mac)
        try await wait("encryption to turn on") { mac.sync.encryption.isOn }
        guard case .on(let summary) = mac.sync.encryption else { return XCTFail("\(mac.sync.encryption)") }
        XCTAssertTrue(summary.isMigrator); XCTAssertFalse(summary.hasRecoveryKey)
        await pass(mac)
        XCTAssertTrue(mac.sync.encryption.isOn)
    }

    /// An iPhone reinstalled with the same sync folder took a new device ID; its earlier one, last seen on Daybook 0.3.0
    /// yesterday, is the same iPhone. It isn't listed as a device that would stop syncing, and doesn't hold encryption back.
    func testAnEarlierIdentityOfAReinstalledIPhoneDoesntHoldEncryptionBack() async throws {
        let keychain = MemoryLibraryKeyStore()
        let mac = try await device("Mac", phone: false, role: .receive, keys: keychain)
        try writeEarlierDaybookPresence("Phone", lastSeen: Date().addingTimeInterval(-86_400), id: "Phone before reinstall")
        await pass(mac)
        let before = await mac.sync.devicesNotReadyForEncryption()
        XCTAssertEqual(before.map(\.id), ["Phone before reinstall"])
        // The reinstalled iPhone syncs under its new device ID.
        let phone = try await device("Phone", phone: true, role: .send, keys: keychain)
        await pass(phone)
        await pass(mac)
        let notReady = await mac.sync.devicesNotReadyForEncryption()
        XCTAssertTrue(notReady.isEmpty, "\(notReady.map(\.id))")
        let known = await mac.sync.knownDevices()
        XCTAssertEqual(known.first { $0.id == "Phone before reinstall" }?.supersededBy, "Phone", "still known by its ID")
        mac.sync.encryptsAutomatically = true
        await mac.sync.encryptOnceEveryDeviceCan()
        try await wait("encryption to turn on") { mac.sync.encryption.isOn }
    }

    func testAnIPhoneLeavesAutomaticEncryptionToAMacThatsAround() async throws {
        let keychain = MemoryLibraryKeyStore()
        let mac = try await device("Mac", phone: false, role: .receive, keys: keychain)
        await pass(mac)
        let phone = try await device("Phone", phone: true, role: .send, keys: keychain, automatic: true)
        await pass(phone)
        await phone.sync.encryptOnceEveryDeviceCan()
        XCTAssertEqual(phone.sync.encryption, .off, "The Mac seals the history from its own audio")
        mac.sync.encryptsAutomatically = true
        await pass(mac)
        try await wait("the Mac to turn it on") { mac.sync.encryption.isOn }
        await pass(phone)
        XCTAssertTrue(phone.sync.encryption.isOn)
        guard case .on(let summary) = phone.sync.encryption else { return XCTFail("\(phone.sync.encryption)") }
        XCTAssertFalse(summary.isMigrator)
    }

    func testTurningEncryptionOnAndADeviceWaitingForItsKey() async throws {
        let keychain = MemoryLibraryKeyStore()
        let mac = try await device("Mac", phone: false, role: .receive, keys: keychain)
        await pass(mac)
        XCTAssertEqual(mac.sync.encryption, .off)
        let notReady = await mac.sync.devicesNotReadyForEncryption()
        XCTAssertTrue(notReady.isEmpty)
        try await mac.sync.enableEncryption()
        await pass(mac)
        guard case .on(let summary) = mac.sync.encryption else { return XCTFail("\(mac.sync.encryption)") }
        XCTAssertTrue(summary.hasKey); XCTAssertTrue(summary.isMigrator); XCTAssertFalse(summary.hasRecoveryKey)

        // iCloud Keychain hasn't brought the key to the phone: it waits, and says so.
        let phoneKeys = MemoryLibraryKeyStore()
        let phone = try await device("Phone", phone: true, role: .send, keys: phoneKeys)
        let applied = await phone.library.synchronize()
        XCTAssertNil(applied)
        XCTAssertEqual(phone.sync.encryption, .waitingForKey)
        XCTAssertEqual(phone.sync.status, "Waiting for this library’s key.")

        // Over the local link: the phone asks, the Mac sends the key only to a device of its library.
        let asked = await phone.sync.libraryKeyRequest()
        let request = try XCTUnwrap(asked)
        let foreign = await mac.sync.libraryKeyGrants(for: request, peerLibraryID: UUID())
        XCTAssertTrue(foreign.isEmpty, "A paired device of another library gets nothing")
        let unknown = await mac.sync.libraryKeyGrants(for: request, peerLibraryID: nil)
        XCTAssertTrue(unknown.isEmpty)
        let grants = await mac.sync.libraryKeyGrants(for: request, peerLibraryID: request.libraryID)
        XCTAssertEqual(grants.count, 1)
        // The link carries it as a message both ways.
        for grant in grants {
            let kept = await phone.sync.accept(grant)
            XCTAssertTrue(kept)
        }
        await pass(phone)
        XCTAssertTrue(phone.sync.encryption.isOn)
        // A grant that doesn't match its ID, or another library's, isn't kept.
        var forged = grants[0]; forged.key = Data(count: 32)
        let keptForged = await phone.sync.accept(forged)
        XCTAssertFalse(keptForged)
    }

    func testARecoveryKeyFromSettingsOpensTheLibraryElsewhere() async throws {
        let mac = try await device("Mac", phone: false, role: .receive, keys: MemoryLibraryKeyStore())
        await pass(mac)
        try await mac.sync.enableEncryption()
        let recovery = try await mac.sync.createRecoveryKey()
        guard case .on(let summary) = mac.sync.encryption else { return XCTFail() }
        XCTAssertTrue(summary.hasRecoveryKey)
        let phone = try await device("Phone", phone: true, role: .send, keys: MemoryLibraryKeyStore())
        _ = await phone.library.synchronize()
        XCTAssertEqual(phone.sync.encryption, .waitingForKey)
        let wrong = try await phone.sync.enterRecoveryKey(RecoveryKey.generate().text)
        XCTAssertFalse(wrong)
        let mistyped = try await phone.sync.enterRecoveryKey("not a key")
        XCTAssertFalse(mistyped)
        let right = try await phone.sync.enterRecoveryKey(recovery.text.lowercased())
        XCTAssertTrue(right)
        await pass(phone)
        XCTAssertTrue(phone.sync.encryption.isOn)
    }

    func testABuildWithoutAKeyStoreCantTurnItOn() async throws {
        let mac = try await device("Mac", phone: false, role: .receive, keys: nil)
        await pass(mac)
        XCTAssertEqual(mac.sync.encryption, .unavailable)
        do { try await mac.sync.enableEncryption(); XCTFail() } catch LibrarySyncError.keyStoreUnavailable {}
    }

    // MARK: Starting over

    func testStartingOverWhenTheKeyIsLostOnEveryDevice() async throws {
        let keychain = MemoryLibraryKeyStore()
        let mac = try await device("Mac", phone: false, role: .receive, keys: keychain)
        let phone = try await device("Phone", phone: true, role: .send, keys: keychain)
        _ = mac.library.newMeeting(title: "Kept on the Mac")
        await mac.library.flush()
        await pass(mac)
        try await mac.sync.enableEncryption()
        await pass(mac)
        _ = phone.library.newMeeting(title: "Kept on the phone")
        await phone.library.flush()
        await pass(phone)
        XCTAssertFalse(mac.sync.mayStartOverEncryption, "never offered while the key is here")

        // iCloud Keychain loses the key, and there's no recovery key.
        for key in keychain.allKeys { try keychain.remove(keyID: key.id, libraryID: key.libraryID) }
        _ = await phone.library.synchronize()
        _ = await mac.library.synchronize()
        XCTAssertEqual(mac.sync.encryption, .waitingForKey)
        XCTAssertTrue(mac.sync.mayStartOverEncryption)
        let oldLibrary = await mac.sync.libraryID()

        try await mac.sync.startOverEncryption()
        XCTAssertTrue(mac.sync.encryption.isOn)
        XCTAssertFalse(mac.sync.mayStartOverEncryption)
        let newLibrary = await mac.sync.libraryID()
        XCTAssertNotEqual(newLibrary, oldLibrary)
        await pass(mac)
        await pass(phone)
        await pass(mac)
        XCTAssertTrue(phone.sync.encryption.isOn)
        XCTAssertEqual(Set(mac.library.meetings.map(\.title)), ["Kept on the Mac", "Kept on the phone"])
        XCTAssertEqual(Set(phone.library.meetings.map(\.title)), ["Kept on the Mac", "Kept on the phone"])
        XCTAssertEqual(mac.sync.warnings, []); XCTAssertEqual(phone.sync.warnings, [])
    }

    // MARK: The courier

    func testSealedFilesTravelInTheirOwnZoneWhichAnEarlierDaybookIgnores() async throws {
        let keychain = MemoryLibraryKeyStore()
        let phone = try await device("Phone", phone: true, role: .send, keys: keychain)
        await pass(phone)
        try await phone.sync.enableEncryption(recoveryKey: RecoveryKey.generate())
        await pass(phone)
        // An earlier Daybook on a second Mac fetches only the plaintext zone.
        let old = try await device("Old", phone: false, role: .receive, keys: nil, zones: [CloudKitCourier.zoneName])
        let mac = try await device("Mac", phone: false, role: .receive, keys: keychain)
        await pass(mac)

        let id = try await record(on: phone, bytes: audioBytes(9_000, seed: 3), title: "Zanzibar")
        await pass(phone)
        await phone.sync.finishCourierSends()
        let sent = service.fileIDs
        XCTAssertFalse(sent.isEmpty)
        XCTAssertTrue(sent.allSatisfy(CloudKitCourier.isSealed), "\(sent)")
        XCTAssertTrue(sent.allSatisfy { service.file($0)?.journal.isSealed == true })

        await old.courier.fetch()
        let oldDelivered = await old.courier.delivered
        XCTAssertTrue(oldDelivered.isEmpty)
        XCTAssertEqual(Set(service.fileIDs), Set(sent), "An earlier Daybook leaves the zone alone")

        // The Mac stores them, applies before iCloud Drive would, and deletes them from the courier.
        for path in ["Sealed/Events", "Sealed/Blobs"] {
            for name in try fm.contentsOfDirectory(atPath: container.appendingPathComponent(path).path) where !name.hasPrefix(".") {
                let held = root.appendingPathComponent("Held/\(path)/\(name)")
                try fm.createDirectory(at: held.deletingLastPathComponent(), withIntermediateDirectories: true)
                if sent.contains(where: { $0.hasSuffix(name) }) { try fm.moveItem(at: container.appendingPathComponent("\(path)/\(name)"), to: held) }
            }
        }
        await mac.courier.fetch()
        try await wait("the courier's files to be stored") { self.service.fileIDs.isEmpty }
        await pass(mac)
        XCTAssertNotNil(mac.library.meeting(id))
    }

    func testTurningEncryptionOnDropsPlaintextTheCourierHolds() async throws {
        let keychain = MemoryLibraryKeyStore()
        let phone = try await device("Phone", phone: true, role: .send, keys: keychain)
        await pass(phone)
        _ = try await record(on: phone, bytes: audioBytes(4_000, seed: 4), title: "Sent")
        await pass(phone)
        await phone.sync.finishCourierSends()
        let sent = Set(service.fileIDs)
        XCTAssertFalse(sent.isEmpty)
        XCTAssertFalse(sent.contains(where: CloudKitCourier.isSealed))
        service.failure = .network
        _ = try await record(on: phone, bytes: audioBytes(4_000, seed: 5), title: "Waiting")
        await pass(phone)
        await phone.sync.finishCourierSends()
        let waiting = await phone.courier.status().waitingToSend
        XCTAssertGreaterThan(waiting, 0)
        service.failure = nil

        try await phone.sync.enableEncryption()
        try await wait("plaintext to be dropped") {
            let status = await phone.courier.status()
            return status.waitingToSend == 0 && Set(self.service.fileIDs).isDisjoint(with: sent)
        }
    }
}
