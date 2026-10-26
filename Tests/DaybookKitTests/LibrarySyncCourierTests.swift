import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// The courier between an iPhone and a Mac (docs/icloud-sync.md, "Courier (CloudKit)") with `InMemoryCourier` in
/// place of CloudKit: a temporary folder stands in for the iCloud container both share, and files are held back from
/// it to play iCloud Drive lagging behind. No CloudKit, account, or network is involved.
@MainActor
final class LibrarySyncCourierTests: XCTestCase {
    private var root: URL!
    private var service: InMemoryCourierService!
    private var controllers: [LibrarySyncController] = []
    private let fm = FileManager.default
    private var container: URL { root.appendingPathComponent("Container", isDirectory: true) }
    private var held: URL { root.appendingPathComponent("Held", isDirectory: true) }

    private struct Device {
        let library: LibraryController
        let sync: LibrarySyncController
        let courier: InMemoryCourier
        let root: URL
    }

    /// A clock tests move forward.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0
        func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
        var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }
    }

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("DaybookCourier-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        service = InMemoryCourierService()
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
        try? fm.removeItem(at: root)
    }

    private func device(_ name: String, phone: Bool, role: CourierRole, clock: Clock = Clock(),
                        policy: CourierPolicy = CourierPolicy()) async throws -> Device {
        let libraryRoot = root.appendingPathComponent(name, isDirectory: true)
        let defaults = makeTestDefaults("daybook.sync.courier.\(name)")
        defaults.set(name, forKey: "syncDeviceID")
        let sync = LibrarySyncController(localRoot: libraryRoot, defaults: defaults)
        controllers.append(sync)
        sync.replica = phone ? .phone(displayName: name) : .mac(displayName: name, canProcess: true)
        let courier = InMemoryCourier(service: service, directory: libraryRoot.appendingPathComponent("Sync/Courier"), deviceID: name,
                                      policy: policy, clock: { clock.now })
        sync.courier = courier
        sync.courierRole = role
        let library = LibraryController(rootURL: libraryRoot, sync: sync)
        try await library.load()
        sync.onSyncRequested = { _ = await library.synchronize() }
        try sync.connect(to: container, monitorChanges: false)
        let expected: CourierAvailability = service.isAvailable ? .available : .unavailable("No iCloud account")
        try await waitUntil("the courier to start", state: syncState) { sync.courierStatus.availability == expected }
        return Device(library: library, sync: sync, courier: courier, root: libraryRoot)
    }

    /// Waits for `condition`, scaled by `DAYBOOK_TEST_TIMEOUT_SCALE`; throws on timeout with the controllers' state.
    /// What every controller says, for a wait that times out.
    private func syncState() -> String {
        controllers.map { "\($0.deviceID): \($0.status), courier \($0.courierStatus.availability)" }.joined(separator: "; ")
    }

    /// Waits out a pass the courier asked for (its debounce and the pass itself), so the next `synchronize()`
    /// runs one of its own rather than finding a pass already applying.
    private func settle(_ device: Device) async throws {
        await device.sync.awaitIdle()
    }

    /// One pass on `library`, which must apply and acknowledge.
    @discardableResult
    private func pass(_ library: LibraryController, file: StaticString = #filePath, line: UInt = #line) async -> SyncApplied? {
        let applied = await library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true, library.sync?.status ?? "", file: file, line: line)
        return applied
    }

    /// A recording filed on `device`, then one pass, and the courier given what it wrote.
    private func recordAndSync(on device: Device, bytes: Data, title: String = "Design review") async throws -> Meeting {
        // Synthetic bytes; sync never decodes audio.
        let file = root.appendingPathComponent("Incoming-\(UUID().uuidString).wav")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: file)
        let id = device.library.newMeeting(title: title)
        await device.library.acquireLock()
        _ = try await device.library.ingest(file, into: id, provenance: .file(source: .microphone))
        device.library.releaseLock()
        await device.library.flush()
        let applied = await device.library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true)
        await device.sync.finishCourierSends()
        return try XCTUnwrap(device.library.meeting(id))
    }

    private func audioBytes(_ count: Int, seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ Int(seed)) }) }

    private func containerFiles() -> Set<String> {
        var paths = Set<String>()
        for directory in ["Events", "Metadata", "Blobs"] {
            for name in (try? fm.contentsOfDirectory(atPath: container.appendingPathComponent(directory).path)) ?? [] where !name.hasPrefix(".") {
                paths.insert("\(directory)/\(name)")
            }
        }
        return paths
    }

    /// Takes files out of the shared container, as if iCloud Drive hadn't brought them to the Mac yet.
    private func holdBack(_ paths: Set<String>) throws {
        for path in paths {
            let destination = held.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: container.appendingPathComponent(path), to: destination)
        }
    }

    private func release(_ paths: Set<String>) throws {
        for path in paths { try fm.moveItem(at: held.appendingPathComponent(path), to: container.appendingPathComponent(path)) }
    }

    private func id(of path: String, in libraryID: UUID) -> String { CourierFile.id(libraryID: libraryID, path: path) }

    // MARK: Sending

    func testThePhoneSendsEachFileAPassWroteOnceThroughFailuresRetriesAndRelaunches() async throws {
        service.failure = .network
        let phone = try await device("Phone", phone: true, role: .send)
        let before = containerFiles()
        let meeting = try await recordAndSync(on: phone, bytes: audioBytes(8_000, seed: 1))
        let written = containerFiles().subtracting(before)
        XCTAssertTrue(written.contains("Blobs/\(meeting.tracks[0].sha256)"))
        XCTAssertTrue(written.contains { $0.hasPrefix("Events/") })
        XCTAssertTrue(service.fileIDs.isEmpty, "The network is down")
        try await waitUntil("the waiting count", state: syncState) { phone.sync.courierStatus.waitingToSend == written.count }
        XCTAssertNotNil(phone.sync.courierStatus.lastError)
        XCTAssertFalse(phone.sync.courierStatus.isStuck(), "Not stuck after a moment")
        let staged = try fm.contentsOfDirectory(atPath: phone.root.appendingPathComponent("Sync/Courier/Outbox").path)
        XCTAssertEqual(staged.count, written.count, "Each file is staged, so iCloud evicting the original can't change what's sent")

        // A pass with nothing new hands nothing more over.
        await pass(phone.library)
        await phone.sync.finishCourierSends()
        let waiting = await phone.courier.status().waitingToSend
        XCTAssertEqual(waiting, written.count)

        // The network returns: everything goes, once, named by library and path.
        service.failure = nil
        await phone.courier.flush()
        let engine = try XCTUnwrap(phone.sync.engine)
        let known = await engine.libraryID
        let libraryID = try XCTUnwrap(known)
        XCTAssertEqual(Set(service.fileIDs), Set(written.map { id(of: $0, in: libraryID) }))
        XCTAssertEqual(service.saveCount, written.count)
        let blobID = id(of: "Blobs/\(meeting.tracks[0].sha256)", in: libraryID)
        XCTAssertEqual(service.file(blobID)?.deviceID, "Phone")
        XCTAssertEqual(service.file(blobID)?.journal.size, 8_000)
        await phone.courier.flush()
        await pass(phone.library)
        await phone.sync.finishCourierSends()
        XCTAssertEqual(service.saveCount, written.count, "Nothing is sent twice")
        try await waitUntil("the status", state: syncState) { phone.sync.courierStatus.waitingToSend == 0 }
        XCTAssertTrue(((try? fm.contentsOfDirectory(atPath: phone.root.appendingPathComponent("Sync/Courier/Outbox").path)) ?? []).isEmpty)

        // A relaunched courier remembers what it sent, so a pass that reports the same file again sends nothing.
        let relaunched = InMemoryCourier(service: service, directory: phone.root.appendingPathComponent("Sync/Courier"), deviceID: "Phone")
        _ = await relaunched.start(role: .send, receiver: nil) { _ in }
        let blob = SyncJournalFile(path: "Blobs/\(meeting.tracks[0].sha256)", sha256: meeting.tracks[0].sha256, size: 8_000)
        await relaunched.send([CourierOutgoingFile(libraryID: libraryID, journal: blob, deviceID: "Phone") { try engine.copyJournalFile(blob, to: $0) }])
        XCTAssertEqual(service.saveCount, written.count)
    }

    func testFilesTooLargeForTheCourierAreLeftToICloudDrive() async throws {
        let phone = try await device("Phone", phone: true, role: .send, policy: CourierPolicy(maxFileBytes: 10_000))
        let before = containerFiles()
        let meeting = try await recordAndSync(on: phone, bytes: audioBytes(20_000, seed: 2))
        let written = containerFiles().subtracting(before)
        let known = await phone.sync.engine?.libraryID
        let libraryID = try XCTUnwrap(known)
        let blob = "Blobs/\(meeting.tracks[0].sha256)"
        XCTAssertTrue(written.contains(blob), "iCloud Drive carries it")
        XCTAssertEqual(Set(service.fileIDs), Set(written.subtracting([blob]).map { id(of: $0, in: libraryID) }))
        try await waitUntil("the status", state: syncState) { phone.sync.courierStatus.waitingToSend == 0 }
    }

    func testStorageFullWaitsLongerEachTimeThenSends() async throws {
        let clock = Clock()
        service.failure = .storageFull
        let phone = try await device("Phone", phone: true, role: .send, clock: clock)
        _ = try await recordAndSync(on: phone, bytes: audioBytes(3_000, seed: 3))
        try await waitUntil("storage full", state: syncState) { phone.sync.courierStatus.storageFull }
        let attempts = service.saveCount
        service.failure = nil
        await phone.courier.flush()
        XCTAssertEqual(service.saveCount, attempts, "Waiting out the refusal, not retrying at once")
        clock.advance(61)
        await phone.courier.flush()
        XCTAssertGreaterThan(service.saveCount, attempts)
        try await waitUntil("the status", state: syncState) { phone.sync.courierStatus.waitingToSend == 0 && !phone.sync.courierStatus.storageFull }
    }

    // MARK: Receiving

    func testTheMacStoresVerifiedFilesAppliesThemBeforeICloudDriveThenDeletesThemFromTheCourier() async throws {
        let phone = try await device("Phone", phone: true, role: .send)
        let mac = try await device("Mac", phone: false, role: .receive)
        await pass(phone.library)
        await phone.sync.finishCourierSends()
        await pass(mac.library)
        let known = await phone.sync.engine?.libraryID
        let libraryID = try XCTUnwrap(known)
        // What the phone's first pass sent (its library settings) is in the Mac's container already: nothing to keep.
        await mac.courier.fetch()
        XCTAssertTrue(service.fileIDs.isEmpty)
        let nothingKept = await mac.sync.engine?.courierInboxCount()
        XCTAssertEqual(nothingKept, 0)

        let bytes = audioBytes(12_000, seed: 4)
        let before = containerFiles()
        let meeting = try await recordAndSync(on: phone, bytes: bytes)
        let written = containerFiles().subtracting(before)
        XCTAssertEqual(service.fileIDs.count, written.count)
        try holdBack(written)

        // A push: the Mac fetches, verifies, keeps the files in its inbox, and asks for a pass, which applies them.
        await mac.courier.fetch()
        try await waitUntil("the conversation on the Mac", state: syncState) { mac.library.meeting(meeting.id) != nil }
        try await settle(mac)
        let onMac = try XCTUnwrap(mac.library.meeting(meeting.id))
        XCTAssertEqual(onMac.tracks, meeting.tracks)
        let audio = try await mac.library.audioURL(for: onMac.tracks[0], in: onMac.id)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        XCTAssertTrue(service.fileIDs.isEmpty, "Stored files are deleted from the courier")
        let delivered = await mac.courier.delivered
        XCTAssertTrue(Set(written.map { id(of: $0, in: libraryID) }).isSubset(of: Set(delivered)))
        XCTAssertTrue(containerFiles().isDisjoint(with: written), "The Mac never writes the courier's files into the container")
        let inbox = await mac.sync.engine?.courierInboxCount()
        XCTAssertEqual(inbox, written.count)

        // iCloud Drive brings the same files: the inbox empties, and the conversation stays as it is.
        try release(written)
        let caughtUp = await mac.library.synchronize()
        XCTAssertEqual(caughtUp?.acknowledged, true)
        XCTAssertEqual(caughtUp?.changed, [])
        let pruned = await mac.sync.engine?.courierInboxCount()
        XCTAssertEqual(pruned, 0)
        XCTAssertEqual(mac.library.meeting(meeting.id)?.tracks, meeting.tracks)
    }

    func testADamagedCourierFileIsDiscardedAndICloudDriveStillDeliversIt() async throws {
        let phone = try await device("Phone", phone: true, role: .send)
        let mac = try await device("Mac", phone: false, role: .receive)
        await pass(phone.library)
        await pass(mac.library)
        let known = await phone.sync.engine?.libraryID
        let libraryID = try XCTUnwrap(known)
        let bytes = audioBytes(5_000, seed: 5)
        let before = containerFiles()
        let meeting = try await recordAndSync(on: phone, bytes: bytes)
        let written = containerFiles().subtracting(before)
        try holdBack(written)
        let blobID = id(of: "Blobs/\(meeting.tracks[0].sha256)", in: libraryID)
        var damaged = bytes; damaged[42] ^= 0x5A
        service.corrupt(blobID, with: damaged)

        await mac.courier.fetch()
        try await waitUntil("the courier to be cleared", state: syncState) { self.service.fileIDs.isEmpty }
        try await settle(mac)
        let inbox = await mac.sync.engine?.courierInboxCount()
        XCTAssertEqual(inbox, written.count - 1, "Everything but the damaged audio")
        await pass(mac.library)
        XCTAssertNil(mac.library.meeting(meeting.id), "A conversation waits for audio that matches")

        try release(written)
        await pass(mac.library)
        let onMac = try XCTUnwrap(mac.library.meeting(meeting.id))
        let audio = try await mac.library.audioURL(for: onMac.tracks[0], in: onMac.id)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
    }

    // MARK: Off, and expiry

    func testWithTheCourierUnavailableSyncRunsExactlyAsBefore() async throws {
        service.isAvailable = false
        let phone = try await device("Phone", phone: true, role: .send)
        let mac = try await device("Mac", phone: false, role: .receive)
        XCTAssertEqual(phone.sync.courierStatus.availability, .unavailable("No iCloud account"))
        XCTAssertFalse(phone.sync.courierStatus.isStuck())
        let bytes = audioBytes(4_000, seed: 6)
        let meeting = try await recordAndSync(on: phone, bytes: bytes)
        XCTAssertTrue(service.fileIDs.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: phone.root.appendingPathComponent("Sync/Courier/Outbox").path), "Nothing staged")
        let applied = await mac.library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true)
        let onMac = try XCTUnwrap(mac.library.meeting(meeting.id))
        let audio = try await mac.library.audioURL(for: onMac.tracks[0], in: onMac.id)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        XCTAssertFalse(fm.fileExists(atPath: mac.root.appendingPathComponent("Sync/Inbox").path))

        // This process isn't signed for CloudKit, so the real courier is never created (nothing touches CloudKit).
        XCTAssertNil(CloudKitCourier.ifEntitled(containerIdentifier: "iCloud.test.daybook", directory: root, deviceID: "Mac"))
        XCTAssertNil(CloudKitCourier.ifEntitled(containerIdentifier: nil, directory: root, deviceID: "Mac"))
    }

    func testCourierFilesOlderThanSevenDaysAreDeletedByAnyDevice() async throws {
        let phoneClock = Clock()
        let phone = try await device("Phone", phone: true, role: .send, clock: phoneClock)
        let before = containerFiles()
        _ = try await recordAndSync(on: phone, bytes: audioBytes(2_000, seed: 7))
        let sent = containerFiles().subtracting(before).count
        XCTAssertEqual(service.fileIDs.count, sent)
        phoneClock.advance(6 * 86_400)
        await phone.courier.removeExpired()
        XCTAssertEqual(service.fileIDs.count, sent, "Six days: kept")
        phoneClock.advance(86_400)
        await phone.courier.removeExpired()
        XCTAssertTrue(service.fileIDs.isEmpty, "The sender deletes its own files after seven days")

        // A Mac that sees a file older than that deletes it rather than delivering it.
        let newer = try await recordAndSync(on: phone, bytes: audioBytes(2_500, seed: 8), title: "Later")
        let ids = service.fileIDs
        XCTAssertFalse(ids.isEmpty)
        for id in ids { service.backdate(id, by: 8 * 86_400) }
        let mac = try await device("Mac", phone: false, role: .receive, clock: phoneClock)
        await mac.courier.fetch()
        XCTAssertTrue(service.fileIDs.isEmpty)
        let delivered = await mac.courier.delivered
        XCTAssertTrue(delivered.isEmpty)
        try await settle(mac)
        // iCloud Drive carries it regardless.
        await pass(mac.library)
        XCTAssertNotNil(mac.library.meeting(newer.id))
    }
}
