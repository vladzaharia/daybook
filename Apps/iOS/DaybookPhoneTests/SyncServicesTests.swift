import DaybookKit
import XCTest
@testable import DaybookPhone

/// A phone and a Mac sharing one library through a temporary folder standing in for the iCloud
/// container: the phone replica's wiring (on-demand audio, presence, bounded passes, status), live
/// library updates, Mac presence, and the sync-backed audio provider.
@MainActor
final class SyncServicesTests: XCTestCase {
    func testARecordingUploadsAtOnceAndAMacsChangesArriveLive() async throws {
        let container = try temporaryDirectory("container")
        let phone = try await makePhone(container)
        XCTAssertEqual(phone.sync.statusLine, "Waiting to sync")
        await phone.sync.synchronize(.launch)
        XCTAssertEqual(phone.sync.statusLine, "Up to date")
        let presenceBefore = MacPresence.resolve(connectedMac: nil, devices: phone.sync.devices, syncAvailable: true,
                                                 syncReason: nil, devicesListed: phone.sync.devicesListed)
        XCTAssertEqual(presenceBefore, .noMac)
        XCTAssertEqual(presenceBefore.waitingLine(), "No Mac has synced this library yet")

        let filed = try await record(into: phone)
        XCTAssertEqual(filed.request?.mode, .newAudio)
        try await waitUntil("the change is counted") { phone.sync.localChanges > 0 }
        XCTAssertEqual(phone.sync.statusLine, "1 change waiting to sync")
        await phone.sync.synchronize(.filed)
        XCTAssertEqual(phone.sync.statusLine, "Up to date")
        XCTAssertEqual(phone.sync.localChanges, 0)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent("Blobs").path)
        XCTAssertEqual(blobs, [filed.meeting.tracks[0].sha256], "the recording's audio is in the container after one pass")
        let me = try XCTUnwrap(phone.sync.devices.first(where: \.isCurrentDevice))
        XCTAssertEqual(me.deviceClass, .phone)
        XCTAssertEqual(me.audioPolicy, .onDemand)

        // A Mac syncs: it gets the conversation with its audio and the request, and announces itself.
        let mac = try await makeMac(container)
        let applied = await mac.synchronize()
        XCTAssertEqual(applied?.acknowledged, true)
        let onMac = try XCTUnwrap(mac.meeting(filed.meeting.id))
        XCTAssertEqual(onMac.openProcessingRequests.map(\.mode), [.newAudio])
        let macAudio = try await mac.audioURL(for: onMac.tracks[0], in: onMac.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: macAudio.path))

        // The Mac renames it; the phone's next pass applies it, and views reading the library follow.
        mac.rename(onMac.id, to: "Design review, agreed")
        await mac.flush()
        await assertPass(mac)
        let revision = phone.library.revision
        await phone.sync.synchronize(.remote)
        XCTAssertEqual(phone.library.conversations.first?.title, "Design review, agreed")
        try await waitUntil("observers are told") { phone.library.revision != revision }
        XCTAssertTrue(phone.sync.lastReceived.contains(onMac.id))

        let presence = MacPresence.resolve(connectedMac: nil, devices: phone.sync.devices, syncAvailable: true,
                                           syncReason: nil, devicesListed: phone.sync.devicesListed)
        guard case .seen(let name, let seen) = presence else { return XCTFail("expected the Mac's presence, got \(presence)") }
        XCTAssertEqual(name, "Studio Mac")
        XCTAssertEqual(presence.waitingLine(now: seen.addingTimeInterval(60)), "Waiting for Studio Mac")
        XCTAssertEqual(presence.waitingLine(now: seen.addingTimeInterval(2 * 3_600 + 5)), "Waiting for your Mac · last seen 2 h ago")

        // Nothing changed on either side: the timer's check lists the journal and runs no pass.
        let passes = phone.sync.passes
        await phone.sync.synchronize(.timer)
        XCTAssertEqual(phone.sync.passes, passes)
        // A change on the Mac is noticed by the same check.
        mac.setTags(onMac.id, text: "design")
        await mac.flush()
        await assertPass(mac)
        await phone.sync.synchronize(.timer)
        XCTAssertEqual(phone.sync.passes, passes + 1)
        XCTAssertEqual(phone.library.controller.meeting(onMac.id)?.tags, ["design"])
    }

    func testStatusSaysWhySyncCantRun() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        let sync = PhoneSync(library: library.controller)
        XCTAssertFalse(sync.isConnected)
        XCTAssertEqual(sync.statusLine, "Sync isn't set up for this library.")
        await sync.synchronize(.manual)
        XCTAssertEqual(sync.passes, 0)
        let presence = MacPresence.resolve(connectedMac: nil, devices: [], syncAvailable: false,
                                           syncReason: CloudAvailability.signedOutMessage,
                                           devicesListed: false)
        XCTAssertEqual(presence.summary(), "Sign in to iCloud to sync your library.")
        XCTAssertEqual(MacPresence.resolve(connectedMac: "Studio Mac", devices: [], syncAvailable: false, syncReason: "x", devicesListed: false),
                       .connected(name: "Studio Mac"), "a Mac on the link is present whatever iCloud says")
    }

    func testAMacThatChecksInWithoutProcessingIsNamedNotCalledEarlier() {
        let now = Date()
        let mac = KnownSyncDevice(id: "mac", deviceClass: .mac, displayName: "Studio Mac", canProcess: false, lastSeen: now)
        let phone = KnownSyncDevice(id: "phone", deviceClass: .phone, displayName: "iPhone", lastSeen: now, isCurrentDevice: true)
        // A device known only from the journal: an old identity, or one that hasn't checked in yet.
        let journalOnly = KnownSyncDevice(id: "old")
        let presence = MacPresence.resolve(connectedMac: nil, devices: [mac, phone, journalOnly], syncAvailable: true,
                                           syncReason: nil, devicesListed: true)
        XCTAssertEqual(presence, .notProcessing(name: "Studio Mac", lastSeen: now))
        XCTAssertEqual(presence.macName, "Studio Mac")
        XCTAssertFalse(presence.isMacAround, "It won't transcribe, so nothing waits on it")
        XCTAssertEqual(presence.summary(now: now), "Studio Mac isn’t set up to transcribe. Finish in Daybook › Settings on Studio Mac.")
        // Without any Mac presence, a journal-only device is still read as an earlier Daybook.
        XCTAssertEqual(MacPresence.resolve(connectedMac: nil, devices: [phone, journalOnly], syncAvailable: true,
                                           syncReason: nil, devicesListed: true), .olderMac)
        // A Mac that processes wins over one that doesn't.
        let processor = KnownSyncDevice(id: "studio", deviceClass: .mac, displayName: "Mini", canProcess: true, lastSeen: now.addingTimeInterval(-60))
        XCTAssertEqual(MacPresence.resolve(connectedMac: nil, devices: [mac, processor, phone], syncAvailable: true,
                                           syncReason: nil, devicesListed: true), .seen(name: "Mini", lastSeen: now.addingTimeInterval(-60)))
    }

    func testAMacWhosePresenceSaysItsRecordingIsNamedAsRecording() {
        let now = Date()
        let activity = SyncDeviceActivity(recordingConversationID: UUID(), since: now.addingTimeInterval(-300), expiresAt: now.addingTimeInterval(60))
        let studio = KnownSyncDevice(id: "studio", deviceClass: .mac, displayName: "Studio Mac", canProcess: true, lastSeen: now, activity: activity)
        let presence = MacPresence.resolve(connectedMac: nil, devices: [studio], syncAvailable: true, syncReason: nil, devicesListed: true, now: now)
        XCTAssertEqual(presence, .recording(name: "Studio Mac", lastSeen: now))
        XCTAssertEqual(presence.summary(now: now), "Studio Mac is recording.")
        XCTAssertEqual(presence.waitingLine(now: now), "Waiting for Studio Mac, which is recording")
        XCTAssertTrue(presence.isMacAround)
        // Once the activity expires it's an ordinary sighting again; the link, when it's there, wins.
        XCTAssertEqual(MacPresence.resolve(connectedMac: nil, devices: [studio], syncAvailable: true, syncReason: nil, devicesListed: true,
                                           now: now.addingTimeInterval(120)), .seen(name: "Studio Mac", lastSeen: now))
        XCTAssertEqual(MacPresence.resolve(connectedMac: "Studio Mac", devices: [studio], syncAvailable: true, syncReason: nil, devicesListed: true,
                                           now: now), .connected(name: "Studio Mac"))
    }

    func testBoundedPassesContinueUntilTheJournalIsRead() async throws {
        let container = try temporaryDirectory("container")
        let mac = try await makeMac(container)
        for index in 0..<5 { mac.newMeeting(title: "Meeting \(index)") }
        await mac.flush()
        await assertPass(mac)
        let phone = try await makePhone(container)
        phone.sync.isForeground = false   // no automatic continuation; drive it here
        // A pass that may read only two journal entries at a time leaves work for the next.
        let applied = await phone.library.controller.synchronize(limits: SyncPassLimits(maxJournalReads: 2))
        XCTAssertEqual(applied?.hasMoreWork, true)
        XCTAssertLessThan(phone.library.conversations.count, 5)
        for _ in 0..<5 where phone.library.conversations.count < 5 { await phone.sync.synchronize(.manual) }
        XCTAssertEqual(phone.library.conversations.count, 5)
        XCTAssertFalse(phone.sync.hasMoreWork)
    }

    func testAnEditDuringAPassIsSyncedRightAfterAndAPullJoinsThePass() async throws {
        let container = try temporaryDirectory("container")
        let gate = PassGate()
        let phone = try await makePhone(container, cloud: SyncCloudFiles(requestDownload: { _ in gate.hold() }, isUploaded: { _ in true }))
        await phone.sync.synchronize(.launch)
        let id = phone.library.controller.newMeeting(title: "Before")
        await phone.library.controller.flush()
        await phone.sync.synchronize(.edit)
        let passes = phone.sync.passes
        // An entry still in iCloud makes the next pass wait on its download, which the test holds.
        try Data().write(to: container.appendingPathComponent("Events/.\(String(repeating: "c", count: 64)).json.icloud"))
        let running = Task { await phone.sync.synchronize(.edit) }
        try await waitUntil("the pass to reach iCloud") { gate.entered }
        phone.library.controller.rename(id, to: "Renamed during the pass")
        // Pull to refresh meanwhile joins the pass rather than finding it busy.
        let refresh = Task { await phone.sync.synchronize(.manual) }
        gate.release()
        await running.value
        await refresh.value
        XCTAssertGreaterThanOrEqual(phone.sync.passes, passes + 2, "the pass, then one more for the edit made during it")
        XCTAssertEqual(phone.sync.localChanges, 0)
        let events = try FileManager.default.contentsOfDirectory(at: container.appendingPathComponent("Events"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let titles = try events.compactMap { url -> String? in
            ((try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["snapshot"] as? [String: Any])?["title"] as? String
        }
        XCTAssertTrue(titles.contains("Renamed during the pass"), "the edit made during the pass was published")
    }

    // MARK: Audio provider

    func testACancelledBackgroundPassDoesNotStartOrPublish() async throws {
        let container = try temporaryDirectory("container")
        let phone = try await makePhone(container, name: "Cancelled background sync")
        phone.library.controller.newMeeting(title: "Still local")
        try await phone.library.controller.flushDurably()
        let pass = Task { await phone.sync.synchronize(.backgroundRefresh) }
        pass.cancel()
        await pass.value
        XCTAssertEqual(phone.sync.passes, 0)
        XCTAssertFalse(phone.sync.isSyncing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("Events").path))
        await phone.sync.synchronize(.manual)
        XCTAssertEqual(phone.sync.passes, 1)
    }

    func testAudioDownloadsOnDemandWithProgressAndCanBeCancelled() async throws {
        let container = try temporaryDirectory("container")
        let recorder = try await makePhone(container, name: "Recording iPhone")
        let filed = try await record(into: recorder)
        await recorder.sync.synchronize(.filed)
        let track = filed.meeting.tracks[0]
        do { let availability = await recorder.audio.availability(of: track, in: filed.meeting.id); XCTAssertEqual(availability, .local, "recorded here") }

        // Another iPhone has the conversation at once, but not its audio.
        let reader = try await makePhone(container, name: "Reading iPhone")
        await reader.sync.synchronize(.launch)
        XCTAssertNotNil(reader.library.controller.meeting(filed.meeting.id))
        do { let availability = await reader.audio.availability(of: track, in: filed.meeting.id); XCTAssertEqual(availability, .downloadable(bytes: nil)) }

        // Cancelled while the recording isn't in the container: nothing is installed.
        let blob = container.appendingPathComponent("Blobs/\(track.sha256)")
        let aside = container.appendingPathComponent("aside")
        try FileManager.default.moveItem(at: blob, to: aside)
        var phases: [AudioFetchProgress.Phase] = []
        let waiting = Task { try await reader.audio.localAudio(for: track, in: filed.meeting.id) { phases.append($0.phase) } }
        try await waitUntil("waiting for the upload") { phases.contains(.waitingForUpload) }
        XCTAssertNotNil(reader.audio.downloads[track.id])
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("a cancelled download returns nothing")
        } catch is CancellationError {}
        do { let availability = await reader.audio.availability(of: track, in: filed.meeting.id); XCTAssertEqual(availability, .downloadable(bytes: nil)) }
        XCTAssertNil(reader.audio.downloads[track.id])

        // Back in the container: it downloads with progress, verified, and plays from the library.
        try FileManager.default.moveItem(at: aside, to: blob)
        var fractions: [Double] = []
        let url = try await reader.audio.localAudio(for: track, in: filed.meeting.id) { fractions.append($0) }
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted(), "progress only moves forward")
        XCTAssertEqual(try AudioDigest.sha256(fileURL: url), track.sha256)
        do { let availability = await reader.audio.availability(of: track, in: filed.meeting.id); XCTAssertEqual(availability, .local) }
        XCTAssertEqual(reader.audio.usage.downloadedBytes, UInt64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0))
    }

    func testDownloadedAudioStaysWithinTheBudgetAndCanBeCleared() async throws {
        let container = try temporaryDirectory("container")
        let recorder = try await makePhone(container, name: "Recording iPhone")
        let first = try await record(into: recorder, title: "First", seconds: 3)
        let second = try await record(into: recorder, title: "Second", seconds: 3)
        await recorder.sync.synchronize(.filed)

        // Room for about one recording.
        let size = UInt64((try FileManager.default.attributesOfItem(atPath: container.appendingPathComponent("Blobs/\(first.meeting.tracks[0].sha256)").path)[.size] as? NSNumber)?.int64Value ?? 0)
        let reader = try await makePhone(container, name: "Reading iPhone", budget: size + size / 2)
        reader.audio.keepWindow = 0
        reader.audio.playingWindow = 0
        await reader.sync.synchronize(.launch)
        _ = try await reader.audio.localAudio(for: first.meeting.tracks[0], in: first.meeting.id) { _ in }
        _ = try await reader.audio.localAudio(for: second.meeting.tracks[0], in: second.meeting.id) { _ in }
        // The least recently played went back to iCloud to make room for the one just played.
        do { let availability = await reader.audio.availability(of: first.meeting.tracks[0], in: first.meeting.id); XCTAssertEqual(availability, .downloadable(bytes: nil)) }
        do { let availability = await reader.audio.availability(of: second.meeting.tracks[0], in: second.meeting.id); XCTAssertEqual(availability, .local) }
        XCTAssertLessThanOrEqual(reader.audio.usage.bytes, size + size / 2)

        // Clear Downloaded Audio removes downloads only; the recording phone keeps what it recorded.
        let freed = await reader.audio.clearDownloaded()
        XCTAssertGreaterThan(freed, 0)
        do { let availability = await reader.audio.availability(of: second.meeting.tracks[0], in: second.meeting.id); XCTAssertEqual(availability, .downloadable(bytes: nil)) }
        XCTAssertEqual(reader.audio.usage.bytes, 0)
        _ = await recorder.audio.clearDownloaded()
        do { let availability = await recorder.audio.availability(of: first.meeting.tracks[0], in: first.meeting.id); XCTAssertEqual(availability, .local) }
    }

    func testAFiledRecordingGoesToTheCourierAndAStuckSendIsShown() async throws {
        let container = try temporaryDirectory("container")
        let service = InMemoryCourierService()
        service.failure = .network
        // The courier's clock runs 20 minutes behind, so what it takes has been waiting that long.
        let phone = try await makePhone(container) { directory in
            InMemoryCourier(service: service, directory: directory, deviceID: "Test iPhone", clock: { Date().addingTimeInterval(-20 * 60) })
        }
        try await waitUntil("the courier to start") { phone.sync.courier.availability == .available }
        await phone.sync.synchronize(.launch)
        let filed = try await record(into: phone)
        await phone.sync.synchronize(.filed)
        await phone.sync.controller?.finishCourierSends()
        try await waitUntil("the files to wait") { phone.sync.courier.waitingToSend > 0 }
        let waiting = phone.sync.courier.waitingToSend
        XCTAssertEqual(phone.sync.statusLine, "Waiting to send \(waiting) items to your Mac")
        XCTAssertFalse(phone.sync.isUpToDate)

        // The network returns: the recording's audio goes, and the line says what's true again.
        service.failure = nil
        let courier = try XCTUnwrap(phone.sync.controller?.courier)
        await courier.flush()
        try await waitUntil("the send") { phone.sync.courier.waitingToSend == 0 }
        XCTAssertEqual(phone.sync.statusLine, "Up to date")
        XCTAssertTrue(service.fileIDs.contains { $0.hasSuffix(".Blobs.\(filed.meeting.tracks[0].sha256)") })
    }
}

/// An iPhone library connected to a folder standing in for the container, as the app wires it.
@MainActor
struct PhoneRig {
    let library: PhoneLibrary
    let sync: PhoneSync
    let audio: SyncAudioProvider
}

@MainActor
extension XCTestCase {
    /// `courier` makes it send what its passes write, as the app does with CloudKit (tests use `InMemoryCourier`).
    func makePhone(_ container: URL, name: String = "Test iPhone", budget: UInt64 = 1_000_000_000, cloud: SyncCloudFiles = .system,
                   courier: ((URL) -> any SyncCourier)? = nil) async throws -> PhoneRig {
        let root = try temporaryDirectory("phone-\(name)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhoneTests-\(UUID().uuidString)"))
        let controller = LibrarySyncController(localRoot: root, defaults: defaults)
        controller.replica = PhoneSync.replica(displayName: name, budget: budget, cloud: cloud)
        // Tests run every pass themselves; an edit's automatic pass would race them.
        controller.syncDebounce = nil
        if let courier {
            controller.courier = courier(root.appendingPathComponent("Sync/Courier", isDirectory: true))
            controller.courierRole = .send
        }
        let library = PhoneLibrary(rootURL: root, sync: controller, installation: UUID().uuidString)
        try await library.reload()
        let sync = PhoneSync(library: library.controller)
        try sync.connect(toFolder: container, monitor: false)
        let audio = SyncAudioProvider(library: library, sync: sync, budget: budget,
                                      options: AudioFetchOptions(pollInterval: .milliseconds(20), timeout: .seconds(10)))
        return PhoneRig(library: library, sync: sync, audio: audio)
    }

    /// One pass on a test Mac's library, which must apply and acknowledge.
    func assertPass(_ library: LibraryController, file: StaticString = #filePath, line: UInt = #line) async {
        let applied = await library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true, library.sync?.status ?? "", file: file, line: line)
    }

    /// A Mac with models: an eager replica that writes presence.
    func makeMac(_ container: URL, name: String = "Studio Mac") async throws -> LibraryController {
        let root = try temporaryDirectory("mac-\(name)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhoneTests-\(UUID().uuidString)"))
        let controller = LibrarySyncController(localRoot: root, defaults: defaults)
        controller.replica = .mac(displayName: name, canProcess: true)
        controller.syncDebounce = nil
        let library = LibraryController(rootURL: root, sync: controller)
        try await library.load()
        try controller.connect(to: container, monitorChanges: false)
        return library
    }

    /// Records `seconds` of tone and files it, as Stop does.
    func record(into phone: PhoneRig, title: String = "Design review", seconds: TimeInterval = 4) async throws -> PhoneLibrary.Filed {
        let rig = RecorderRig()
        let id = UUID()
        try await rig.recorder.start(in: phone.library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: title)
        rig.pump(1)
        rig.recorder.editNotes("Decisions")
        rig.pump(seconds - 1)
        rig.recorder.addBookmark()
        return try await phone.library.fileRecording(try await rig.stop())
    }
}

/// Holds the first cloud-provider call until released; later ones pass straight through.
private final class PassGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var held = false, _entered = false
    var entered: Bool { lock.withLock { _entered } }
    func hold() {
        let first = lock.withLock { () -> Bool in defer { held = true; _entered = true }; return !held }
        if first { _ = semaphore.wait(timeout: .now() + 10) }
    }
    func release() { semaphore.signal() }
}
