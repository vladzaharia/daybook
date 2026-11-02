import DaybookCaptions
import DaybookCore
import DaybookIntelligence
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookDevices

/// Wi‑Fi Fast Transfer end to end on loopback: the real connection, session, and queue against the
/// simulated recorder, whose access point is a TLS WebSocket server with a self-signed certificate and
/// a header-case-sensitive parser, and whose network a simulated hotspot joins. No Bluetooth, Wi‑Fi,
/// or downloads.
@MainActor
final class SoundcoreFastTransferTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var staging: URL!

    override func setUp() async throws {
        suite = makeTestSuite("local.daybook.tests.soundcore-wifi")
        defaults = UserDefaults(suiteName: suite)
        staging = makeTemporaryFolder("DaybookWiFi")
    }

    // MARK: Harness

    private static let frames = SimulatedSoundcore.frames(seconds: 1)
    private let base = UInt32(Date().timeIntervalSince1970) - 50_000

    private func recorder(count: Int = 2) -> SimulatedSoundcore {
        SimulatedSoundcore(recordings: (0..<count).map { .init(id: base - UInt32($0) * 3_600, frames: Self.frames) })
    }

    private final class Library {
        var imports: [(identity: DeviceRecordingIdentity, seconds: Double)] = []
        var meetings: [Meeting] = []
    }

    /// The app's background time as iOS hands it out: how often it was held and let go, and the system ending it.
    @MainActor
    private final class BackgroundTime {
        private(set) var held = 0
        private(set) var released = 0
        private var expired: (@MainActor () -> Void)?

        func hold(_ expired: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            held += 1
            self.expired = expired
            return { [weak self] in
                self?.released += 1
                self?.expired = nil
            }
        }

        /// The system ends the background time before Fast Transfer let it go.
        func expire() { expired?() }
    }

    private struct Rig {
        let session: DeviceSession
        let connection: SoundcoreConnection
        let device: SimulatedSoundcore
        let hotspot: SimulatedSoundcoreHotspot
        let hooks: SoundcoreWiFiHooks
        let background: BackgroundTime
        let library: Library
        let configured: ConfiguredDevice
    }

    /// `importDelay`: how long the library takes to copy each recording.
    private func rig(_ device: SimulatedSoundcore, importDelay: Duration = .zero, configure: ((inout SoundcoreTiming) -> Void)? = nil) -> Rig {
        let transport = SimulatedSoundcoreTransport(device: device)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        let hooks = LiveCaptionHooks()
        hooks.makeCaptioner = { nil }
        environment.liveCaptions = hooks
        var timing = SoundcoreTiming()
        timing.request = .seconds(3)
        timing.stall = .milliseconds(600)
        timing.settle = .milliseconds(20)
        timing.scan = .milliseconds(300)
        timing.connect = .milliseconds(600)
        timing.reconnect = .milliseconds(300)
        timing.backoff = [.milliseconds(40), .milliseconds(80)]
        timing.idleRelease = .seconds(60)
        timing.automaticIdleRelease = .seconds(60)
        timing.otherAppQuiet = .milliseconds(300)
        // Recordings of a second count as long here.
        timing.fastTransferMinimum = .milliseconds(500)
        timing.accessPointStartup = .milliseconds(50)
        timing.webSocketConnect = .seconds(3)
        timing.webSocketRetry = .milliseconds(100)
        timing.keepAlive = .milliseconds(40)
        timing.fastTransferLinger = .seconds(2)
        timing.fastTransferBackgroundGrace = .milliseconds(50)
        configure?(&timing)
        environment.soundcoreTiming = timing
        let hotspot = SimulatedSoundcoreHotspot(recorder: device)
        let background = BackgroundTime()
        let wifi = environment.soundcoreWiFi
        wifi.hotspot = hotspot
        wifi.holdInBackground = { background.hold($0) }
        wifi.requiresWiFi = false
        wifi.keepAlivePort = { [weak device] _ in device?.accessPoint?.keepAlivePort ?? 9 }
        wifi.build = "test"
        let configured = ConfiguredDevice(id: "wifi", kind: SoundcoreWorkIntegration().kind)
        let connection = SoundcoreConnection(device: configured, environment: environment)
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        let library = Library()
        session.importer = { [weak session] url, identity, _, source in
            if importDelay > .zero { try await Task.sleep(for: importDelay) }
            let duration = Double(try AudioSlabReader.samples(url: url, from: 0, to: 3_600).count) / 16_000
            guard duration > 0 else { throw DaybookError.invalidAudio(url.lastPathComponent) }
            library.imports.append((identity, duration))
            let meeting = Meeting(title: "Imported", tracks: [RecordingTrack(source: source, relativePath: "Originals/x.wav",
                                                                             fileName: url.lastPathComponent, device: identity)])
            library.meetings.append(meeting)
            session?.libraryChanged(library.meetings, ready: true)
            return meeting.id
        }
        session.activate()
        session.libraryChanged([], ready: true)
        return Rig(session: session, connection: connection, device: device, hotspot: hotspot, hooks: wifi, background: background,
                   library: library, configured: configured)
    }

    private func connect(_ rig: Rig) async throws {
        rig.connection.search()
        try await waitUntil("a recorder to be found") { !rig.connection.discovered.isEmpty }
        rig.connection.connect(to: rig.connection.discovered[0])
        try await waitUntil("the connection") { rig.connection.state == .connected }
        try await waitUntil("the recording list") { !rig.connection.isRefreshing && rig.connection.inventoryUpdatedAt != nil }
    }

    private func count(_ rig: Rig, _ type: UInt8, _ command: UInt8) -> Int {
        rig.device.received.filter { $0 == (type, command) }.count
    }

    /// Back on Bluetooth, with the recorder's access point closed and nothing left to close.
    private func waitForBluetooth(_ rig: Rig, closed: Int = 1) async throws {
        try await waitUntil("Bluetooth back and the access point closed") {
            rig.device.accessPointsClosed == closed && rig.connection.fastTransferStage == nil && rig.connection.state == .connected
                && rig.connection.remembered?.accessPointSSID == nil && !rig.connection.isRefreshing
        }
    }

    private var stagedFiles: [String] { (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] }

    // MARK: Over Wi‑Fi

    func testALongRecordingComesOverTheRecordersWiFiAndItsAccessPointIsClosed() async throws {
        let device = recorder(count: 1)
        device.pace = .milliseconds(20)
        let rig = rig(device)
        // What the page says as iOS asks to join a network called "WiFi-1730…".
        var saidAtThePrompt: [String?] = []
        rig.hotspot.onJoin = { [weak session = rig.session] in saidAtThePrompt.append(session?.fastTransferStage?.label) }
        try await connect(rig)
        XCTAssertTrue(rig.session.offersFastTransfer)
        let target = rig.session.newRecordings[0]
        rig.session.importRecordings([target])
        try await waitUntil("Fast Transfer to start") { rig.session.fastTransferStage != nil }
        try await waitUntil("the file over Wi‑Fi") { rig.session.fastTransferStage == .transferring && !device.wifiRequests.isEmpty }
        XCTAssertEqual(FastTransferStage.transferring.label, "Over Wi‑Fi")
        XCTAssertEqual(saidAtThePrompt, ["Joining Soundcore Work’s Wi‑Fi…"], "the recorder's own name, before iOS asks")
        XCTAssertEqual(rig.connection.state, .connected, "the page still reads as connected")
        XCTAssertTrue(rig.connection.fastTransferHoldsBackgroundTime, "a short background task while it runs")
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        XCTAssertEqual(rig.background.held, 1)
        XCTAssertEqual(rig.background.released, 1, "let go once Fast Transfer ended")
        XCTAssertFalse(rig.connection.fastTransferHoldsBackgroundTime)

        // Over Bluetooth: the key exchange the Wi‑Fi transfer reuses, 1A 05, and after Bluetooth came
        // back, 1A 02. The file itself came over Wi‑Fi, asked for from the start.
        XCTAssertEqual(count(rig, 0x2e, 0x01), 1, "the Wi‑Fi transfer used the key exchanged over Bluetooth")
        XCTAssertEqual(count(rig, 0x1a, 0x05), 1)
        XCTAssertEqual(count(rig, 0x1a, 0x02), 1)
        XCTAssertEqual(count(rig, 0x1a, 0x07), 0)
        XCTAssertEqual(device.wifiRequests.map(\.recordingID), [UInt32(target.id)])
        XCTAssertEqual(device.wifiRequests.map(\.offset), [0])
        XCTAssertEqual(device.wifiTexts, [SoundcoreWiFi.finish])
        for command in device.received {
            XCTAssertTrue(SoundcoreSimulatorTests.readOnlyCommands.contains([command.type, command.command]), "Unexpected command \(command)")
        }
        XCTAssertFalse(device.received.contains { $0 == (0x1a, 0x11) }, "nothing asked the recorder to stop sending")

        // The opening handshake as the official client writes it; the picky parser took it. Keep-alives
        // reached the recorder's port while the WebSocket was open.
        let accessPoint = try XCTUnwrap(device.lastAccessPoint)
        let handshake = try XCTUnwrap(accessPoint.handshakes.first)
        XCTAssertTrue(handshake.hasPrefix("GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: "))
        XCTAssertTrue(handshake.contains("\r\nSec-WebSocket-Version: 13\r\nHost: 127.0.0.1:\(accessPoint.port)\r\n"))
        XCTAssertGreaterThan(accessPoint.keepAlives, 0)
        XCTAssertNil(device.accessPoint, "closed")
        XCTAssertEqual(rig.hotspot.joins, [accessPoint.ssid])
        XCTAssertEqual(rig.hotspot.leaves, [accessPoint.ssid], "the iPhone left its network")
        XCTAssertTrue(accessPoint.ssid.hasPrefix("WiFi-"))

        // Accepted as a Bluetooth transfer is: the identity, the whole recording, nothing left staged.
        XCTAssertEqual(rig.library.imports[0].identity.recordingID, target.id)
        XCTAssertEqual(rig.library.imports[0].identity.serial, device.serial)
        XCTAssertEqual(rig.library.imports[0].seconds, 1, accuracy: 0.1)
        XCTAssertTrue(stagedFiles.isEmpty)
        XCTAssertTrue(rig.session.failures.isEmpty)
        XCTAssertNil(rig.session.problem)
        let row = try XCTUnwrap(rig.connection.technicalDetails.first { $0.label == "Fast Transfer" })
        XCTAssertTrue(row.value.hasPrefix("Over Wi‑Fi, "), row.value)
    }

    func testABatchSharesOneAccessPoint() async throws {
        let rig = rig(recorder(count: 3))
        try await connect(rig)
        rig.session.importRecordings(rig.session.newRecordings)
        try await waitUntil("three imports") { rig.library.imports.count == 3 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        XCTAssertEqual(count(rig, 0x1a, 0x05), 1)
        XCTAssertEqual(rig.device.wifiRequests.count, 3)
        XCTAssertEqual(count(rig, 0x1a, 0x02), 1)
        XCTAssertEqual(rig.hotspot.joins.count, 1)
        XCTAssertEqual(rig.device.wifiTexts, [SoundcoreWiFi.finish])
    }

    /// The Wi‑Fi link stops waiting before the next recording's transfer starts (the library took a while
    /// over the first): that one waits for Bluetooth to come back, then opens the access point again. Not
    /// a failure.
    func testARecordingAfterTheWiFiLinkEndedOpensItAgain() async throws {
        let rig = rig(recorder(count: 2), importDelay: .milliseconds(150), configure: { $0.fastTransferLinger = .milliseconds(50) })
        try await connect(rig)
        rig.session.importRecordings(rig.session.newRecordings)
        try await waitUntil("both imports") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig, closed: 2)
        XCTAssertEqual(rig.device.accessPointsOpened, 2)
        XCTAssertEqual(rig.device.wifiRequests.count, 2)
        XCTAssertEqual(count(rig, 0x1a, 0x07), 0)
        XCTAssertEqual(rig.hotspot.joins.count, 2)
        XCTAssertNil(rig.connection.lastTechnicalProblem)
    }

    func testShortRecordingsStayOnBluetoothUnlessThePersonChoosesWiFi() async throws {
        let rig = rig(recorder(count: 2), configure: { $0.fastTransferMinimum = .seconds(600) })
        try await connect(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the first import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertEqual(count(rig, 0x1a, 0x07), 1, "over Bluetooth")
        XCTAssertEqual(count(rig, 0x1a, 0x05), 0)

        rig.session.importRecordings([rig.session.newRecordings[0]], overWiFi: true)
        try await waitUntil("the second import") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        XCTAssertEqual(count(rig, 0x1a, 0x05), 1)
        XCTAssertEqual(rig.device.wifiRequests.count, 1)

        // With the preference off, a long one stays on Bluetooth too.
        rig.session.update { $0.fastTransferForLongRecordings = false }
        XCTAssertFalse(rig.connection.usesFastTransfer)
    }

    func testFastTransferRunsOnlyInTheForeground() async throws {
        let device = recorder(count: 2)
        device.pace = .milliseconds(20)
        let rig = rig(device)
        try await connect(rig)
        rig.hooks.isForeground = false
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertEqual(count(rig, 0x1a, 0x05), 0, "in the background it's Bluetooth")

        // Leaving the foreground mid-transfer, for longer than the moment iOS keeps the network, ends Fast
        // Transfer; the import carries on over Bluetooth.
        rig.hooks.isForeground = true
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the file over Wi‑Fi") { !device.wifiRequests.isEmpty }
        rig.hooks.isForeground = false
        try await waitUntil("the second import") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        XCTAssertEqual(count(rig, 0x1a, 0x07), 2, "the second finished over Bluetooth")
        XCTAssertEqual(rig.library.imports[1].seconds, 1, accuracy: 0.1, "the whole recording, from the start")
        XCTAssertTrue(rig.session.failures.isEmpty)
        XCTAssertNil(rig.session.transferProblem)
        XCTAssertTrue(stagedFiles.isEmpty)
        XCTAssertEqual(rig.background.released, rig.background.held, "the background time let go")
        XCTAssertTrue(rig.connection.usesFastTransfer, "leaving isn't a No")
    }

    /// A glance at another app while the recording comes over Wi‑Fi: Daybook keeps running for a short
    /// while, iOS keeps the recorder's network, and the transfer finishes over Wi‑Fi.
    func testBehaviorAMomentOutOfDaybookKeepsTheTransferOnWiFi() async throws {
        let device = recorder(count: 1)
        device.pace = .milliseconds(30)
        let rig = rig(device, configure: { $0.fastTransferBackgroundGrace = .seconds(30) })
        try await connect(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the file over Wi‑Fi") { !device.wifiRequests.isEmpty }
        rig.hooks.isForeground = false
        try await Task.sleep(for: .milliseconds(60))
        rig.hooks.isForeground = true
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        XCTAssertEqual(device.wifiRequests.count, 1)
        XCTAssertEqual(count(rig, 0x1a, 0x07), 0, "never over Bluetooth")
        XCTAssertEqual(rig.library.imports[0].seconds, 1, accuracy: 0.1)
        let row = try XCTUnwrap(rig.connection.technicalDetails.first { $0.label == "Fast Transfer" })
        XCTAssertTrue(row.value.hasPrefix("Over Wi‑Fi, "), row.value)
        XCTAssertEqual(rig.background.held, 1)
        XCTAssertEqual(rig.background.released, 1)
    }

    /// The system ends Daybook's background time before the transfer is done: Fast Transfer ends at once, and
    /// the recording comes over Bluetooth from the start.
    func testBehaviorFastTransferEndsWhenItsBackgroundTimeRunsOut() async throws {
        let device = recorder(count: 1)
        device.pace = .milliseconds(30)
        let rig = rig(device, configure: { $0.fastTransferBackgroundGrace = .seconds(30) })
        try await connect(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the file over Wi‑Fi") { !device.wifiRequests.isEmpty }
        rig.hooks.isForeground = false
        rig.background.expire()
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        XCTAssertEqual(count(rig, 0x1a, 0x07), 1, "over Bluetooth")
        XCTAssertEqual(rig.library.imports[0].seconds, 1, accuracy: 0.1, "the whole recording")
        XCTAssertEqual(rig.background.released, 1)
        XCTAssertTrue(rig.session.failures.isEmpty)
        XCTAssertNil(rig.session.transferProblem)
    }

    /// iOS goes back to another network after the join, one whose addresses may be the recorder's: nothing is
    /// opened there, and the recording comes over Bluetooth.
    func testBehaviorTheSocketOpensOnlyOnTheRecordersOwnNetwork() async throws {
        let device = recorder(count: 1)
        let rig = rig(device)
        rig.hotspot.dropsAfterJoining = true
        try await connect(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        let accessPoint = try XCTUnwrap(device.lastAccessPoint)
        XCTAssertTrue(accessPoint.handshakes.isEmpty, "no WebSocket was opened")
        XCTAssertTrue(device.wifiRequests.isEmpty)
        XCTAssertEqual(count(rig, 0x1a, 0x07), 1, "over Bluetooth")
        XCTAssertEqual(rig.library.imports[0].seconds, 1, accuracy: 0.1)
        let row = try XCTUnwrap(rig.connection.technicalDetails.first { $0.label == "Fast Transfer" })
        XCTAssertTrue(row.value.hasSuffix(SoundcoreHotspotError.notJoined.localizedDescription), row.value)
        XCTAssertTrue(rig.connection.usesFastTransfer, "a failure, not the person's No")
    }

    // MARK: Falling back to Bluetooth

    /// A build without the Hotspot Configuration entitlement: iOS fails the join at once. The transfer
    /// carries on over Bluetooth, the access point is closed, and this build doesn't try again until
    /// the preference is turned off and on.
    func testWithoutTheHotspotEntitlementTransfersFallBackToBluetoothAndItIsntTriedAgain() async throws {
        let rig = rig(recorder(count: 2))
        rig.hotspot.failure = .unavailable
        try await connect(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        XCTAssertEqual(count(rig, 0x1a, 0x05), 1)
        XCTAssertEqual(count(rig, 0x1a, 0x07), 1, "over Bluetooth")
        XCTAssertEqual(rig.library.imports[0].seconds, 1, accuracy: 0.1)
        XCTAssertFalse(rig.session.offersFastTransfer)
        XCTAssertTrue(rig.connection.technicalDetails.contains { $0.label == "Fast Transfer" && $0.value == "Unavailable in this build" })
        XCTAssertNil(rig.session.problem, "not a problem: it imported")

        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the second import") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        XCTAssertEqual(count(rig, 0x1a, 0x05), 1, "not tried again")

        rig.session.update { $0.fastTransferForLongRecordings = false }
        rig.session.update { $0.fastTransferForLongRecordings = true }
        XCTAssertTrue(rig.session.offersFastTransfer, "turning it on again tries afresh")
    }

    /// The person declines iOS's prompt: that's their choice. Fast Transfer turns off for this recorder (its
    /// switch reads off, and is the way back), the recording comes over Bluetooth at once, and nothing asks again.
    func testBehaviorADeclinedJoinTurnsFastTransferOffForThatRecorder() async throws {
        let rig = rig(recorder(count: 3))
        rig.hotspot.failure = .declined
        var kept: [ConfiguredDevice] = []
        rig.session.onDeviceChange = { kept.append($0) }
        try await connect(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        XCTAssertEqual(count(rig, 0x1a, 0x07), 1, "over Bluetooth")
        XCTAssertEqual(rig.session.device.fastTransferForLongRecordings, false, "the recorder's Fast Transfer reads off")
        XCTAssertFalse(rig.connection.usesFastTransfer)
        XCTAssertEqual(kept.last?.usesFastTransfer, false, "kept with the device")
        XCTAssertTrue(rig.session.offersFastTransfer, "Import over Wi‑Fi and the switch stay")
        XCTAssertNil(rig.session.problem, "not a problem: it imported")
        XCTAssertTrue(rig.connection.lastTechnicalProblem?.hasPrefix("Fast Transfer: ") == true)

        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the second import") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        XCTAssertEqual(rig.hotspot.joins.count, 1, "asked once")
        XCTAssertEqual(count(rig, 0x1a, 0x07), 2)

        // Turning it on again is the undo, with no pause to wait out.
        rig.hotspot.failure = nil
        rig.session.update { $0.fastTransferForLongRecordings = true }
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the third import") { rig.library.imports.count == 3 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig, closed: 2)
        XCTAssertEqual(rig.hotspot.joins.count, 2, "asked again once it was turned back on")
        XCTAssertEqual(rig.device.wifiRequests.count, 1, "over Wi‑Fi")
    }

    func testTheWiFiDroppingMidFileFallsBackToBluetoothAndSavesNothingPartial() async throws {
        let device = recorder(count: 1)
        device.pace = .milliseconds(15)
        device.fault = .once(.disconnect(afterSlices: 12))
        let rig = rig(device)
        try await connect(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        try await waitForBluetooth(rig)
        XCTAssertEqual(device.wifiRequests.count, 1)
        XCTAssertEqual(count(rig, 0x1a, 0x07), 1, "started again over Bluetooth")
        XCTAssertEqual(rig.library.imports.count, 1)
        XCTAssertEqual(rig.library.imports[0].seconds, 1, accuracy: 0.1)
        XCTAssertTrue(rig.session.failures.isEmpty)
        XCTAssertNil(rig.session.transferProblem)
        XCTAssertTrue(stagedFiles.isEmpty)
        let row = try XCTUnwrap(rig.connection.technicalDetails.first { $0.label == "Fast Transfer" })
        XCTAssertTrue(row.value.hasPrefix("Back to Bluetooth, "), row.value)
    }

    func testAnAccessPointRefusedOrUnansweredLeavesTheTransferOnBluetooth() async throws {
        let refusing = recorder(count: 1)
        refusing.accessPointBehaviour = .refuses
        let first = rig(refusing)
        try await connect(first)
        first.session.importRecordings([first.session.newRecordings[0]])
        try await waitUntil("the import") { first.library.imports.count == 1 && !first.session.queue.isActive }
        XCTAssertEqual(refusing.accessPointsOpened, 0)
        XCTAssertEqual(count(first, 0x1a, 0x02), 0, "nothing was opened")
        XCTAssertTrue(first.hotspot.joins.isEmpty)
        first.connection.shutDown()

        // No answer: it may have opened, so it's closed before carrying on, over the link still up.
        defaults.removePersistentDomain(forName: suite)
        let silent = recorder(count: 1)
        silent.accessPointBehaviour = .ignores
        let second = rig(silent, configure: { $0.request = .milliseconds(300) })
        try await connect(second)
        second.session.importRecordings([second.session.newRecordings[0]])
        try await waitUntil("the import") { second.library.imports.count == 1 && !second.session.queue.isActive }
        XCTAssertEqual(count(second, 0x1a, 0x02), 1)
        XCTAssertEqual(count(second, 0x1a, 0x07), 1)
        XCTAssertTrue(second.hotspot.joins.isEmpty)
    }

    // MARK: Recovery

    /// Disconnecting (or quitting) while the recorder is on its own Wi‑Fi: the page says so, a relaunch
    /// remembers it, and the next connection closes the access point.
    func testARecorderLeftOnItsWiFiIsClosedOnTheNextConnection() async throws {
        let device = recorder(count: 1)
        device.pace = .milliseconds(40)
        let rig = rig(device)
        try await connect(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the file over Wi‑Fi") { !device.wifiRequests.isEmpty && rig.session.phase?.fraction ?? 0 > 0 }
        rig.session.disconnect(.direct)
        XCTAssertNil(rig.connection.fastTransferStage)
        XCTAssertEqual(rig.session.problem?.id, SoundcoreIssue.fastTransferInterrupted.rawValue)
        XCTAssertEqual(rig.session.problem?.actions, [.connect])
        XCTAssertNotNil(rig.connection.remembered?.accessPointSSID)
        XCTAssertNotNil(device.accessPoint, "still open")
        XCTAssertTrue(rig.library.imports.isEmpty)
        try await waitUntil("nothing left staged") { self.stagedFiles.isEmpty }

        // A relaunch remembers it.
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { InertSoundcoreTransport() }
        let relaunched = SoundcoreConnection(device: rig.configured, environment: environment)
        relaunched.activate()
        XCTAssertEqual(relaunched.problem?.id, SoundcoreIssue.fastTransferInterrupted.rawValue)
        relaunched.shutDown()

        rig.session.connect()
        try await waitUntil("the access point closed") { device.accessPointsClosed == 1 && rig.connection.remembered?.accessPointSSID == nil }
        XCTAssertNil(device.accessPoint)
        XCTAssertNil(rig.session.problem)
        XCTAssertEqual(rig.connection.state, .connected)
    }
}
