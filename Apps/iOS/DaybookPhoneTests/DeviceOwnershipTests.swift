import DaybookKit
import DaybookLink
import XCTest
@testable import DaybookPhone

/// Soundcore on iPhone against DaybookDevices' simulated recorder (no Bluetooth): setup claims the
/// recorder for this iPhone in the synced library, a Mac's later claim makes the phone let go and
/// say who manages it, and the phone's imports file into the library with a Transcribe request.
@MainActor
final class DeviceOwnershipTests: XCTestCase {
    override func tearDown() async throws {
        #if DEBUG
        DeviceHub.demo = DeviceHubDemo()
        #endif
    }

    func testSetupClaimsTheRecorderAndAMacTakingItOverIsHonoured() async throws {
        let container = try temporaryDirectory("container")
        let phone = try await makePhone(container)
        let settings = PhoneSettings(defaults: UserDefaults(suiteName: "DeviceOwnershipTests-\(UUID().uuidString)")!)
        let devices = PhoneDevices(library: phone.library, settings: settings, mode: .simulator)
        addTeardownBlock { devices.shutDown() }
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
        try await waitUntil("imported", timeout: 20) { !imported.isEmpty }
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
        XCTAssertEqual(PhoneDeviceCopy.line(for: session), "Managed by Studio Mac")
        session.connect()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(session.isLinked, "this iPhone doesn't connect to a recorder the Mac manages")

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
        let settings = PhoneSettings(defaults: UserDefaults(suiteName: "DeviceOwnershipTests-\(UUID().uuidString)")!)
        let devices = PhoneDevices(library: phone.library, settings: settings, mode: .simulator)
        addTeardownBlock { devices.shutDown() }
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
        XCTAssertEqual(PhoneDeviceCopy.line(for: session).hasPrefix("Connected"), true)
        _ = model
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
