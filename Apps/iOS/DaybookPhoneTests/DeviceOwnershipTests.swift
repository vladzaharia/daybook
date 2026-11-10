import DaybookKit
import DaybookLink
import XCTest
@testable import DaybookPhone

/// Soundcore on iPhone against DaybookDevices' simulated recorder (no Bluetooth): setup claims the
/// recorder for this iPhone in the synced library, a Mac's later claim makes the phone let go and
/// say who manages it, and the phone's imports file into the library with a Transcribe request.
@MainActor
final class DeviceOwnershipTests: XCTestCase {
    /// The simulated recorder these tests reach for, and every transport made for it.
    @MainActor
    final class Recorder {
        let device: SimulatedSoundcore
        var transports: [SimulatedSoundcoreTransport] = []
        /// Connections and searches tried so far, on every transport.
        var attempts: Int { transports.reduce(0) { $0 + $1.connectAttempts + $1.scans } }

        init() {
            // Two one-second recordings, sent as fast as the link takes them: the `--device-simulator`
            // demo's six- and nine-second recordings paced at 60 ms made one import take about 6 s.
            let now = UInt32(Date().timeIntervalSince1970)
            device = SimulatedSoundcore(recordings: [
                .init(id: now - 3 * 3_600, frames: SimulatedSoundcore.frames(seconds: 1, frequency: 330)),
                .init(id: now - 26 * 3_600, frames: SimulatedSoundcore.frames(seconds: 1, frequency: 440))
            ])
        }
    }

    /// The app's devices against `recorder` (a new transport for each connection, never Bluetooth),
    /// with preferences in a throwaway suite.
    private func makeDevices(_ library: PhoneLibrary, _ recorder: Recorder, settings: PhoneSettings) throws -> PhoneDevices {
        let defaults = makeTestDefaults("DeviceOwnershipTests-devices")
        let devices = PhoneDevices(library: library, settings: settings, mode: .inert, defaults: defaults, timing: Self.timing) { [recorder] in
            let transport = SimulatedSoundcoreTransport(device: recorder.device)
            recorder.transports.append(transport)
            return transport
        }
        addTeardownBlock { devices.shutDown() }
        return devices
    }

    /// Production timing, except: a request the simulated recorder never answers fails in seconds,
    /// waits after a stopped transfer or a dropped link are short, and a recorder connected for an
    /// automatic import isn't let go partway through a slow run (30 s in the app).
    private static var timing: PhoneDevices.Timing {
        var timing = PhoneDevices.Timing()
        timing.soundcore.request = .seconds(3)
        timing.soundcore.settle = .milliseconds(20)
        timing.soundcore.backoff = [.milliseconds(40), .milliseconds(80)]
        timing.soundcore.idleRelease = .seconds(600)
        timing.soundcore.automaticIdleRelease = .seconds(600)
        return timing
    }

    /// Runs everything already queued on the main queue.
    private func drainMainQueue() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
    }

    func testSetupClaimsTheRecorderAndAMacTakingItOverIsHonoured() async throws {
        let container = try temporaryDirectory("container")
        let phone = try await makePhone(container)
        let settings = PhoneSettings(defaults: makeTestDefaults("DeviceOwnershipTests"))
        let recorder = Recorder()
        let devices = try makeDevices(phone.library, recorder, settings: settings)
        var imported: [PhoneLibrary.Filed] = []
        devices.onImported = { imported.append($0) }
        devices.start()

        // Add Recorder › Soundcore Work › Search, then choose it.
        let kind = try XCTUnwrap(DeviceCatalog.kind(SoundcoreWorkIntegration.id))
        let session = try XCTUnwrap(devices.beginSetup(kind))
        let soundcore = try XCTUnwrap(session.direct as? SoundcoreConnection)
        soundcore.search()
        try await waitUntil("the recorder is found") { !soundcore.discovered.isEmpty }
        soundcore.connect(to: soundcore.discovered[0])
        try await waitUntil("connected") { session.isLinked }
        devices.commitSetup()
        XCTAssertEqual(devices.sessions.map(\.id), [session.id])
        let serial = try XCTUnwrap(session.recorderSerial)
        let owner = try XCTUnwrap(phone.library.controller.recorderOwner(kind: kind.id, serial: serial))
        XCTAssertEqual(owner.ownerID, phone.library.controller.thisDevice.id)
        XCTAssertEqual(owner.ownerClass, .phone)
        XCTAssertNil(session.managedElsewhere, "this iPhone manages it")

        // Importing what's on it files a conversation with a recorder track and a Transcribe request.
        try await waitUntil("its recordings are listed") { !session.newRecordings.isEmpty }
        // As automatic import does, so the test host never asks for notification permission.
        session.importRecordings([session.newRecordings[0]], automatic: true)
        try await waitUntil("imported") { !imported.isEmpty }
        let filed = try XCTUnwrap(imported.first)
        XCTAssertEqual(filed.meeting.tracks.first?.deviceKind, kind.id)
        XCTAssertEqual(filed.meeting.tracks.first?.deviceSerial, serial)
        XCTAssertEqual(filed.request?.mode, .newAudio)
        XCTAssertTrue(filed.meeting.title.hasPrefix("Soundcore Work at "))

        // The ownership travels with the library: a Mac sees it, then takes the recorder over.
        await phone.sync.synchronize(.edit)
        let mac = try await makeMac(container)
        _ = await mac.synchronize()
        XCTAssertEqual(mac.recorderOwner(kind: kind.id, serial: serial)?.ownerClass, .phone)
        mac.claimRecorder(kind: kind.id, serial: serial, deviceClass: .mac, by: ProcessingRequest.Device(id: "studio-mac", name: "Studio Mac"))
        await mac.flush()
        _ = await mac.synchronize()
        await phone.sync.synchronize(.remote)
        try await waitUntil("the phone lets go") { session.managedElsewhere?.ownerName == "Studio Mac" && !session.isLinked }
        XCTAssertEqual(RecorderStatusWords.byline(RecorderFacts(session: session)), "Managed by Studio Mac")
        let attempts = recorder.attempts
        session.connect()
        await drainMainQueue()
        XCTAssertFalse(session.isLinked, "this iPhone doesn't connect to a recorder the Mac manages")
        XCTAssertEqual(recorder.attempts, attempts, "it doesn't even search for it")
        XCTAssertFalse(recorder.device.isOccupied)

        // Manage on This iPhone takes it back; with automatic import on, it reconnects by itself.
        devices.claim(session)
        XCTAssertNil(session.managedElsewhere)
        try await waitUntil("connected again") { session.isLinked }

        // Removing it here lets another device manage it.
        devices.remove(session)
        XCTAssertNil(phone.library.controller.recorderOwner(kind: kind.id, serial: serial))
        XCTAssertTrue(devices.sessions.isEmpty)
    }

    /// "Use on This iPhone" through the app's own wiring: the phone's link asks the Mac (a real
    /// `LinkService` on 127.0.0.1, played by the test), the Mac answers and releases, and the phone
    /// claims the recorder and connects to the simulated Soundcore.
    func testUseOnThisIPhoneAsksTheMacOverTheLinkAndTakesOver() async throws {
        let container = try temporaryDirectory("container")
        let phone = try await makePhone(container)
        let settings = PhoneSettings(defaults: makeTestDefaults("DeviceOwnershipTests"))
        let devices = try makeDevices(phone.library, Recorder(), settings: settings)
        let link = PhoneLink(identity: PhoneLink.identity(installation: UUID().uuidString, name: "Test iPhone", libraryID: nil,
                                                           syncDeviceID: phone.library.controller.thisDevice.id),
                             keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        addTeardownBlock { await link.setActivity(.background) }
        let model = PhoneAppModel(recorder: RecorderRig().recorder, library: phone.library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  settings: settings, link: link, devices: devices)
        devices.start()

        // The phone sets the recorder up, then the Mac manages it (it synced the Mac's claim).
        let kind = try XCTUnwrap(DeviceCatalog.kind(SoundcoreWorkIntegration.id))
        let session = try XCTUnwrap(devices.beginSetup(kind))
        let soundcore = try XCTUnwrap(session.direct as? SoundcoreConnection)
        soundcore.search()
        try await waitUntil("the recorder is found") { !soundcore.discovered.isEmpty }
        soundcore.connect(to: soundcore.discovered[0])
        try await waitUntil("connected") { session.isLinked }
        devices.commitSetup()
        let serial = try XCTUnwrap(session.recorderSerial)
        let macSyncID = "studio-mac-sync"
        phone.library.controller.claimRecorder(kind: kind.id, serial: serial, deviceClass: .mac,
                                               by: ProcessingRequest.Device(id: macSyncID, name: "Studio Mac"))
        devices.applyOwnership()
        try await waitUntil("the phone lets go") { !session.isLinked && session.managedElsewhere?.ownerName == "Studio Mac" }

        // A Mac on the link that hands recorders over.
        let macID = UUID()
        let service = LinkService(identity: LinkIdentity(deviceID: macID, name: "Studio Mac", deviceClass: .mac, appVersion: "1.0",
                                                         canProcess: true, features: [LinkCapabilities.recorderHandoffFeature],
                                                         syncDeviceID: macSyncID),
                                  keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        try await service.start()
        addTeardownBlock { await service.stop() }
        let heard = HandoffInbox(service.events())
        let listening = await service.port
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: try XCTUnwrap(listening))
        await link.start()
        let code = await service.beginPairing()
        _ = try await link.pair(with: endpoint, code: code.digits)
        try await waitUntil("connected") { link.macs.first?.isConnected == true && link.macs.first?.handsOffRecorders == true }
        XCTAssertEqual(link.macs.first?.syncDeviceID, macSyncID)

        devices.useHere(session)
        XCTAssertEqual(devices.handoffState(session), .asking(owner: "Studio Mac"))
        try await waitUntil("the Mac hears the request") { heard.request != nil }
        let (request, phoneLinkID) = try XCTUnwrap(heard.request)
        XCTAssertEqual(request.intent, .take)
        XCTAssertEqual(request.addressedTo, macSyncID)
        XCTAssertEqual(request.serial, serial)
        XCTAssertEqual(request.requester.syncID, phone.library.controller.thisDevice.id)

        let me = LinkHandoffDevice(syncID: macSyncID, name: "Studio Mac", deviceClass: .mac)
        try await service.send(.recorderHandoffReply(LinkRecorderHandoffReply(
            requestID: request.id, outcome: .accepted(LinkRecorderHandoffAck(finishing: .import, finishingTitle: "Today, 10:02 AM", secondsLeft: 30)),
            from: me)), to: phoneLinkID)
        try await waitUntil("the phone says the Mac is finishing") {
            if case .ownerFinishing("Studio Mac", .importing?) = devices.handoffState(session) { return true }; return false
        }
        try await service.send(.recorderRelease(LinkRecorderRelease(requestID: request.id, kind: request.kind, serial: serial,
                                                                    newOwner: request.requester)), to: phoneLinkID)
        try await waitUntil("on this iPhone") { session.isLinked }
        XCTAssertNil(session.managedElsewhere)
        XCTAssertEqual(phone.library.controller.recorderOwner(kind: kind.id, serial: serial)?.ownerID, phone.library.controller.thisDevice.id)
        XCTAssertEqual(RecorderStatusWords.byline(RecorderFacts(session: session)).hasPrefix("Connected"), true)
        _ = model
    }

    /// A remembered recorder, as an earlier run left it in `defaults`, with the transport tests reach it through.
    private func rememberedRecorder(_ recorder: Recorder, defaults: UserDefaults) throws -> SimulatedSoundcoreTransport {
        var configured = ConfiguredDevice(id: "soundcore", kind: SoundcoreWorkIntegration().kind)
        configured.importsAutomatically = true
        let transport = SimulatedSoundcoreTransport(device: recorder.device)
        recorder.transports.append(transport)
        let environment = DeviceEnvironment(defaults: defaults, stagingDirectory: try temporaryDirectory("staging"))
        var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: recorder.device.name, serial: recorder.device.serial)
        snapshot.lastConnectedAt = Date()
        environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
        defaults.set(try JSONEncoder().encode([configured]), forKey: DeviceHub.storageKey)
        return transport
    }

    /// A library that hasn't loaded: what a background relaunch (Bluetooth restoration) starts with.
    private func unloadedLibrary(_ defaults: UserDefaults) throws -> PhoneLibrary {
        let root = try temporaryDirectory("unloaded")
        return PhoneLibrary(rootURL: root, sync: LibrarySyncController(localRoot: root, defaults: defaults), installation: UUID().uuidString)
    }

    /// Relaunched for a recorder before the library has loaded, the iPhone keeps to who managed it as it last knew, from
    /// before anything connects: a recorder a Mac manages is never reached for, and the last-known records stand until the
    /// library's own are read.
    func testBehaviorARelaunchBeforeTheLibraryLoadsKeepsToTheOwnershipItLastKnew() async throws {
        let recorder = Recorder()
        let defaults = makeTestDefaults("DeviceOwnershipTests-relaunch")
        let transport = try rememberedRecorder(recorder, defaults: defaults)
        let lastRun = DeviceHub(environment: DeviceEnvironment(defaults: defaults, stagingDirectory: try temporaryDirectory("last-run")))
        lastRun.recorderOwnersChanged([RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: recorder.device.serial, ownerID: "studio-mac",
                                                         ownerName: "Studio Mac", ownerClass: .mac)], thisDevice: "this-iphone")
        lastRun.shutDown()

        let library = try unloadedLibrary(defaults)
        let settings = PhoneSettings(defaults: makeTestDefaults("DeviceOwnershipTests-relaunch-settings"))
        let devices = PhoneDevices(library: library, settings: settings, mode: .inert, defaults: defaults, timing: Self.timing) { transport }
        devices.holdsInTests = true
        addTeardownBlock { devices.shutDown() }
        devices.start()
        XCTAssertFalse(library.controller.isLoaded)
        let session = try XCTUnwrap(devices.sessions.first)
        XCTAssertEqual(session.managedElsewhere?.ownerName, "Studio Mac", "applied before the devices started")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.connectAttempts, 0, "never reached for")
        XCTAssertFalse(recorder.device.isOccupied)
    }

    /// Relaunched for a recorder it manages, the iPhone loads the library once the recorder connects (the scene's launch,
    /// which loads it, doesn't run in the background), under background time, so what the recorder brings in imports.
    func testBehaviorARecorderConnectingBeforeTheLibraryLoadsLoadsIt() async throws {
        let recorder = Recorder()
        let defaults = makeTestDefaults("DeviceOwnershipTests-background")
        let transport = try rememberedRecorder(recorder, defaults: defaults)
        let library = try unloadedLibrary(defaults)
        let settings = PhoneSettings(defaults: makeTestDefaults("DeviceOwnershipTests-background-settings"))
        let devices = PhoneDevices(library: library, settings: settings, mode: .inert, defaults: defaults, timing: Self.timing) { transport }
        devices.holdsInTests = true
        addTeardownBlock { devices.shutDown() }
        devices.start()
        let session = try XCTUnwrap(devices.sessions.first)
        try await waitUntil("the recorder connects") { session.isLinked }
        try await waitUntil("the library loads for it") { library.controller.isLoaded }
    }

    /// The device page's Details copies what the owner can send: the app's version, the recorder's
    /// technical facts, and every recording on it with why it is or isn't new. A list that doesn't
    /// come says so in the iPhone's words.
    func testDetailsCopyTheAppVersionAndWhyEachRecordingIsOrIsNotNew() async throws {
        let container = try temporaryDirectory("container")
        let phone = try await makePhone(container)
        let settings = PhoneSettings(defaults: makeTestDefaults("DeviceOwnershipTests"))
        let recorder = Recorder()
        let devices = try makeDevices(phone.library, recorder, settings: settings)
        devices.start()
        let kind = try XCTUnwrap(DeviceCatalog.kind(SoundcoreWorkIntegration.id))
        let session = try XCTUnwrap(devices.beginSetup(kind))
        let soundcore = try XCTUnwrap(session.direct as? SoundcoreConnection)
        soundcore.search()
        try await waitUntil("the recorder is found") { !soundcore.discovered.isEmpty }
        soundcore.connect(to: soundcore.discovered[0])
        try await waitUntil("listed") { session.isLinked && soundcore.isInventoryCurrent }
        devices.commitSetup()

        let text = DeviceDetailsScreen.text(session)
        XCTAssertTrue(text.hasPrefix("Daybook "), text)
        XCTAssertTrue(text.contains(" on iPhone\n"), text)
        for line in ["Recording list: 2, in 1 page, ", "On the device: 2", " · New · "] {
            XCTAssertTrue(text.contains(line), "lacks \(line):\n\(text)")
        }
        let copy = RecorderStatusWords.problem(SoundcoreIssue.listFailed.problem, on: .iPhone)
        XCTAssertEqual(copy.title, "Soundcore didn’t list its recordings")
        XCTAssertFalse(copy.message.contains("phone"), "on the iPhone, the Soundcore app is on this phone")
    }
}

/// What the test's Mac hears on the link.
final class HandoffInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: (LinkRecorderHandoffRequest, UUID)?
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<LinkEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                if case .received(.recorderHandoffRequest(let request), let from) = event { self?.lock.withLock { self?.heard = (request, from) } }
            }
        }
    }

    deinit { task?.cancel() }

    var request: (LinkRecorderHandoffRequest, UUID)? { lock.withLock { heard } }
}
