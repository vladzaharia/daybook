import AVFoundation
import DaybookCaptions
import DaybookCore
import DaybookIntelligence
import Foundation
import XCTest
@testable import DaybookDevices

/// Soundcore Work end to end against a simulated recorder: setup, listing, imports, integrity
/// failures, disconnects and reconnects, Bluetooth changes, automatic import, record control, and
/// Listen Live with its live captions. No Bluetooth, no microphone, no downloads, no speech recognition.
@MainActor
final class SoundcoreSimulatorTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var staging: URL!
    private var transportsMade = 0

    override func setUp() async throws {
        suite = "local.daybook.tests.soundcore-sim.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        staging = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSim-\(UUID().uuidString)", isDirectory: true)
        transportsMade = 0
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: Harness

    private var timing: SoundcoreTiming {
        var timing = SoundcoreTiming()
        timing.request = .seconds(3)
        timing.stall = .milliseconds(400)
        timing.settle = .milliseconds(20)
        timing.scan = .milliseconds(300)
        timing.connect = .milliseconds(600)
        timing.reconnect = .milliseconds(300)
        timing.recordConfirm = .milliseconds(1_500)
        timing.backoff = [.milliseconds(40), .milliseconds(80), .milliseconds(120)]
        timing.idleRelease = .seconds(60)
        timing.automaticIdleRelease = .milliseconds(300)
        timing.automaticCooldown = .seconds(60)
        return timing
    }

    private static let frames = SimulatedSoundcore.frames(seconds: 1)
    private let base = UInt32(Date().timeIntervalSince1970) - 50_000

    private func recorder(count: Int = 2) -> SimulatedSoundcore {
        SimulatedSoundcore(recordings: (0..<count).map { .init(id: base - UInt32($0) * 3_600, frames: Self.frames) })
    }

    /// What the importer received, and the library it built from it.
    private final class Library {
        var imports: [(identity: DeviceRecordingIdentity, attachTo: UUID?, seconds: Double)] = []
        var meetings: [Meeting] = []
    }

    private struct Rig {
        let session: DeviceSession
        let connection: SoundcoreConnection
        let transport: SimulatedSoundcoreTransport
        let device: SimulatedSoundcore
        let library: Library
        let configured: ConfiguredDevice
    }

    private func rig(_ device: SimulatedSoundcore, automatic: Bool = false, since: Date = .distantFuture,
                     configure: ((inout SoundcoreTiming) -> Void)? = nil, remembered: Bool = false,
                     rememberedSerial: String = "", owners: [RecorderOwnership]? = nil, captions: LiveCaptionHooks? = nil,
                     transportSetup: ((SimulatedSoundcoreTransport) -> Void)? = nil) -> Rig {
        let transport = SimulatedSoundcoreTransport(device: device)
        transportSetup?(transport)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { [weak self] in self?.transportsMade += 1; return transport }
        // Never the Speech framework in tests: no captions unless a test scripts them.
        environment.liveCaptions = captions ?? Self.noCaptions()
        var timing = self.timing
        configure?(&timing)
        environment.soundcoreTiming = timing
        var configured = ConfiguredDevice(id: "sim", kind: SoundcoreWorkIntegration().kind)
        configured.importsAutomatically = automatic
        configured.automaticImportsSince = since
        if remembered {
            var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: device.name, serial: rememberedSerial)
            snapshot.lastConnectedAt = Date().addingTimeInterval(-3_600)
            environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
        }
        let connection = SoundcoreConnection(device: configured, environment: environment)
        let files = ImportFolderWatcher(storage: environment.storage(for: configured, method: .files))
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind,
                                    connections: [connection, files], defaults: defaults)
        let library = Library()
        session.importer = { [weak session] url, identity, attachTo, source in
            // Only audio that decodes reaches the library.
            let samples = try AudioSlabReader.samples(url: url, from: 0, to: 0.5)
            guard !samples.isEmpty else { throw DaybookError.invalidAudio(url.lastPathComponent) }
            let duration = Double(try AudioSlabReader.samples(url: url, from: 0, to: 3_600).count) / 16_000
            library.imports.append((identity, attachTo, duration))
            let meeting = Meeting(title: "Imported", tracks: [RecordingTrack(source: source, relativePath: "Originals/x.wav",
                                                                             fileName: url.lastPathComponent, device: identity)])
            library.meetings.append(meeting)
            session?.libraryChanged(library.meetings, ready: true)
            return meeting.id
        }
        if let owners { session.applyOwnership(owners, thisDevice: Self.thisMac) }
        session.activate()
        session.libraryChanged([], ready: true)
        return Rig(session: session, connection: connection, transport: transport, device: device, library: library, configured: configured)
    }

    private static func noCaptions() -> LiveCaptionHooks {
        let hooks = LiveCaptionHooks()
        hooks.makeCaptioner = { nil }
        return hooks
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Setup's search, then connect, as the Add Device sheet does.
    private func connectThroughSetup(_ rig: Rig) async throws {
        rig.connection.search()
        try await waitUntil("a recorder to be found") { !rig.connection.discovered.isEmpty }
        rig.connection.connect(to: rig.connection.discovered[0])
        try await waitUntil("the connection") { rig.connection.state == .connected }
        try await waitUntil("the recording list") { !rig.connection.isRefreshing && rig.connection.inventoryUpdatedAt != nil }
    }

    private var stagedFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    }

    // MARK: Setup and connection

    func testNothingTouchesBluetoothUntilThePersonAsks() async throws {
        let rig = rig(recorder())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transportsMade, 0, "No Bluetooth manager until setup")
        XCTAssertEqual(rig.connection.state, .notSetUp)
        XCTAssertEqual(rig.transport.activations, 0)
    }

    func testSetupFindsConnectsListsAndRemembersTheRecorder() async throws {
        let rig = rig(recorder(count: 3))
        try await connectThroughSetup(rig)
        XCTAssertEqual(rig.connection.discovered.first?.signal, .nearby)
        XCTAssertNotNil(rig.connection.remembered)
        XCTAssertEqual(rig.connection.status?.battery?.level, 80)
        XCTAssertEqual(rig.connection.status?.serial, rig.device.serial)
        XCTAssertEqual(rig.connection.recordings.count, 3)
        XCTAssertEqual(rig.session.newRecordings.count, 3)
        XCTAssertTrue(rig.session.isLinked)

        // A new launch remembers the recorder and its last status, without connecting.
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { XCTFail("No Bluetooth on launch without automatic import"); return InertSoundcoreTransport() }
        var configured = rig.configured
        configured.importsAutomatically = false
        let relaunched = SoundcoreConnection(device: configured, environment: environment)
        relaunched.activate()
        XCTAssertEqual(relaunched.remembered?.deviceID, rig.transport.peripheralID)
        XCTAssertEqual(relaunched.state, .notConnected)
        XCTAssertEqual(relaunched.recordings.count, 3, "The last list is shown as of its time")
        XCTAssertEqual(relaunched.status?.battery?.level, 80)
        XCTAssertNil(relaunched.status?.isRecording, "Recording state isn't known while not connected")
    }

    func testListingPagesAndFallsBackToTheEightByteLayout() async throws {
        let device = recorder(count: 23)
        device.supportsExtendedListing = false
        device.pageSize = 10
        let rig = rig(device)
        try await connectThroughSetup(rig)
        XCTAssertEqual(rig.connection.recordings.count, 23)
        XCTAssertTrue(rig.connection.recordings.allSatisfy { $0.length?.isEstimate == true }, "No end times in the short layout")
        XCTAssertTrue(device.received.contains { $0 == (0x1b, 0x0e) })
        XCTAssertTrue(device.received.contains { $0 == (0x1a, 0x0e) })
    }

    func testReconnectUsesTheRememberedRecorderThenFallsBackToAScan() async throws {
        let rig = rig(recorder())
        try await connectThroughSetup(rig)
        rig.connection.disconnect()
        XCTAssertEqual(rig.connection.state, .notConnected)
        XCTAssertNotNil(rig.connection.lastConnectedAt)

        let scans = rig.transport.scans
        rig.connection.connect()
        try await waitUntil("reconnecting directly") { rig.connection.state == .connected }
        XCTAssertEqual(rig.transport.scans, scans, "The system still knew it: no scan")

        rig.connection.disconnect()
        rig.transport.isKnown = false
        rig.connection.connect()
        try await waitUntil("reconnecting after a scan") { rig.connection.state == .connected }
        XCTAssertGreaterThan(rig.transport.scans, scans)
    }

    func testRememberedRecorderOutOfReachSaysSo() async throws {
        let rig = rig(recorder())
        try await connectThroughSetup(rig)
        rig.connection.disconnect()
        rig.transport.isKnown = false
        rig.device.advertises = false
        rig.connection.connect()
        try await waitUntil("giving up") { rig.connection.problem != nil }
        XCTAssertEqual(rig.connection.problem?.id, SoundcoreIssue.notFound.rawValue)
        XCTAssertEqual(rig.connection.state, .notConnected)
    }

    func testBluetoothOffAndDeniedAreReportedAndRecoverWhenItComesBack() async throws {
        let rig = rig(recorder(), transportSetup: { $0.radioOnActivate = .poweredOff })
        rig.connection.search()
        try await waitUntil("the radio report") { rig.connection.state == .unavailable }
        XCTAssertEqual(rig.connection.problem?.id, SoundcoreIssue.bluetoothOff.rawValue)
        XCTAssertEqual(rig.connection.problem?.actions, [.openBluetoothSettings])
        rig.transport.setRadio(.poweredOn)
        try await waitUntil("searching once Bluetooth is on") { !rig.connection.discovered.isEmpty }
        XCTAssertNil(rig.connection.problem)

        let denied = self.rig(recorder(), transportSetup: { $0.radioOnActivate = .unauthorized })
        denied.connection.search()
        try await waitUntil("the permission report") { denied.connection.problem != nil }
        XCTAssertEqual(denied.connection.problem?.id, SoundcoreIssue.bluetoothDenied.rawValue)
    }

    func testAnIdleConnectionIsLetGoForThePhone() async throws {
        let rig = rig(recorder(), configure: { $0.idleRelease = .milliseconds(300) })
        try await connectThroughSetup(rig)
        try await waitUntil("letting go") { rig.connection.state == .notConnected }
        XCTAssertFalse(rig.transport.connected)
    }

    // MARK: Importing

    func testImportDecryptsDecodesAndRecordsTheRecordingsIdentity() async throws {
        let rig = rig(recorder())
        try await connectThroughSetup(rig)
        let target = rig.session.newRecordings[0]
        rig.session.importRecordings([target])
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        let imported = rig.library.imports[0]
        XCTAssertEqual(imported.identity.kind, SoundcoreWorkIntegration.id)
        XCTAssertEqual(imported.identity.serial, rig.device.serial)
        XCTAssertEqual(imported.identity.recordingID, target.id)
        XCTAssertEqual(imported.seconds, 1, accuracy: 0.1)
        XCTAssertTrue(stagedFiles.isEmpty, "The staged copy is removed once the library has it")
        XCTAssertEqual(rig.session.links.imported[target.id], rig.library.meetings[0].id)
        XCTAssertEqual(rig.session.split.imported.map(\.id), [target.id], "It moves to Already in Daybook")
        XCTAssertNil(rig.session.phase)
        XCTAssertTrue(rig.connection.keyExchangeComplete)
    }

    func testImportsRunOneAtATimeAndAttachWhereAsked() async throws {
        let rig = rig(recorder(count: 3))
        try await connectThroughSetup(rig)
        let conversation = UUID()
        rig.session.importRecordings(Array(rig.session.newRecordings.prefix(2)), attachTo: conversation)
        XCTAssertEqual(rig.session.queue.total, 2)
        try await waitUntil("both imports") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        XCTAssertTrue(rig.library.imports.allSatisfy { $0.attachTo == conversation })
        XCTAssertEqual(rig.device.received.filter { $0 == (0x1a, 0x07) }.count, 2)
    }

    func testIntegrityFailuresSaveNothingAfterOneQuietRetry() async throws {
        for fault in [SimulatedSoundcore.Fault.skipSlice(at: 10), .skipSlice(at: 48), .wrongSize] {
            let device = recorder()
            device.fault = fault
            let rig = rig(device)
            try await connectThroughSetup(rig)
            rig.session.importRecordings([rig.session.newRecordings[0]])
            try await waitUntil("the failure for \(fault)") { !rig.session.queue.isActive }
            XCTAssertTrue(rig.library.imports.isEmpty, "\(fault): nothing partial reaches the library")
            XCTAssertEqual(rig.session.failures.count, 1)
            XCTAssertEqual(rig.session.transferProblem?.id, SoundcoreIssue.integrity.rawValue)
            XCTAssertEqual(device.received.filter { $0 == (0x1a, 0x07) }.count, 2, "\(fault): one retry, then it stops")
            XCTAssertTrue(stagedFiles.isEmpty, "\(fault): partial files are removed")
            XCTAssertEqual(rig.connection.state, .connected, "The recorder stays connected")
            rig.connection.disconnect()
        }
    }

    func testAStalledTransferEndsWithNothingSaved() async throws {
        let device = recorder()
        device.fault = .stall(afterSlices: 6)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the stall") { !rig.session.queue.isActive }
        XCTAssertEqual(rig.session.transferProblem?.id, SoundcoreIssue.stalled.rawValue)
        XCTAssertTrue(rig.library.imports.isEmpty)
        XCTAssertTrue(device.received.contains { $0 == (0x1a, 0x11) }, "The recorder is asked to stop sending")
    }

    func testTryAgainAfterAFailureImportsTheRecording() async throws {
        let device = recorder()
        device.fault = .skipSlice(at: 3)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the failure") { !rig.session.failures.isEmpty && !rig.session.queue.isActive }
        device.fault = nil
        rig.session.tryAgain()
        try await waitUntil("the second try") { rig.library.imports.count == 1 }
        XCTAssertTrue(rig.session.failures.isEmpty)
        XCTAssertNil(rig.session.transferProblem)
    }

    func testStoppingKeepsNothingAndLeavesTheRecordingOnTheRecorder() async throws {
        let device = recorder()
        device.pace = .milliseconds(20)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("audio arriving") { if case .receiving = rig.session.phase { return true } else { return false } }
        rig.session.stopCurrent()
        XCTAssertFalse(rig.session.queue.isActive)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(rig.library.imports.isEmpty)
        XCTAssertTrue(stagedFiles.isEmpty)
        XCTAssertEqual(device.recordings.count, 2, "Nothing is deleted from the recorder")
        XCTAssertTrue(device.received.contains { $0 == (0x1a, 0x11) })
        XCTAssertNil(rig.session.transferProblem, "Stopping isn't a problem")
    }

    func testDisconnectMidTransferWaitsReconnectsAndResumes() async throws {
        let device = recorder()
        device.fault = .disconnect(afterSlices: 12)
        let rig = rig(device, configure: { $0.backoff = [.milliseconds(400), .milliseconds(400)] })
        try await connectThroughSetup(rig)
        let target = rig.session.newRecordings[0]
        rig.session.importRecordings([target])
        try await waitUntil("the drop") { rig.session.queue.isSuspended }
        XCTAssertEqual(rig.session.transferProblem?.id, SoundcoreIssue.disconnectedDuringImport.rawValue)
        XCTAssertEqual(rig.session.queue.waiting.first?.id, target.id, "The recording waits at the front")
        XCTAssertTrue(rig.library.imports.isEmpty, "Nothing partial is saved")
        XCTAssertTrue(stagedFiles.isEmpty)
        device.fault = nil
        try await waitUntil("the reconnect and resumed import", timeout: 10) { rig.library.imports.count == 1 }
        XCTAssertEqual(rig.library.imports[0].identity.recordingID, target.id)
        XCTAssertNil(rig.session.transferProblem, "Resolved once it imported")
        XCTAssertFalse(rig.session.queue.isActive)
    }

    func testBluetoothTurningOffMidImportResumesWhenItReturns() async throws {
        let device = recorder()
        device.pace = .milliseconds(15)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("audio arriving") { if case .receiving = rig.session.phase { return true } else { return false } }
        rig.transport.setRadio(.poweredOff)
        try await waitUntil("the queue waiting") { rig.session.queue.isSuspended }
        XCTAssertEqual(rig.connection.problem?.id, SoundcoreIssue.bluetoothOff.rawValue)
        device.pace = nil
        rig.transport.setRadio(.poweredOn)
        try await waitUntil("the import after Bluetooth returns", timeout: 10) { rig.library.imports.count == 1 }
    }

    // MARK: Automatic import

    func testAutomaticImportBringsInRecordingsSinceSetupThenLetsTheRecorderGo() async throws {
        let device = recorder(count: 3)
        let since = Date(timeIntervalSince1970: TimeInterval(base - 3_600 - 60))
        device.advertises = false
        let rig = rig(device, automatic: true, since: since, remembered: true)
        try await waitUntil("a quiet pending connection") { rig.transport.connectAttempts > 0 }
        XCTAssertEqual(rig.connection.state, .notConnected, "Waiting in range isn't connecting")
        rig.transport.comeIntoRange()
        try await waitUntil("the automatic imports") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        XCTAssertEqual(Set(rig.library.imports.map(\.identity.recordingID)), [String(base), String(base - 3_600)],
                       "Only recordings made since the recorder was added")
        XCTAssertEqual(rig.session.newRecordings.map(\.id), [String(base - 7_200)], "Older ones wait for the person")
        try await waitUntil("letting the recorder go") { rig.connection.state == .notConnected && !rig.transport.connected }
    }

    func testTurningAutomaticImportOffStopsWaitingForTheRecorder() async throws {
        let device = recorder()
        device.advertises = false
        let rig = rig(device, automatic: true, since: .distantPast, remembered: true)
        try await waitUntil("a quiet pending connection") { rig.transport.connectAttempts == 1 }
        rig.session.update { $0.importsAutomatically = false }
        if case .idle = rig.connection.phase {} else { XCTFail("Stops waiting: \(rig.connection.phase)") }
        rig.transport.comeIntoRange()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotEqual(rig.connection.state, .connected, "No connection once the person turned it off")
        XCTAssertTrue(rig.library.imports.isEmpty)
        rig.session.update { $0.importsAutomatically = true }
        try await waitUntil("connecting again once it's back on") { rig.connection.state == .connected }
        try await waitUntil("the imports") { rig.library.imports.count == 2 }
    }

    func testAutomaticImportNeverRunsBeforeTheLibraryLoads() async throws {
        let device = recorder()
        let transport = SimulatedSoundcoreTransport(device: device)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        // Connected on its own, the recorder is let go after `automaticIdleRelease`; keep it long enough
        // that a slow machine still has it connected when the library loads.
        var timing = self.timing
        timing.automaticIdleRelease = .seconds(10)
        environment.soundcoreTiming = timing
        var configured = ConfiguredDevice(id: "early", kind: SoundcoreWorkIntegration().kind)
        configured.automaticImportsSince = .distantPast
        var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: device.name)
        snapshot.lastConnectedAt = Date()
        environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
        let connection = SoundcoreConnection(device: configured, environment: environment)
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        var imported = 0
        session.importer = { _, _, _, _ in imported += 1; return UUID() }
        session.activate()
        try await waitUntil("connecting on its own") { connection.state == .connected && connection.inventoryUpdatedAt != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(imported, 0, "Without the library every recording would look new")
        XCTAssertFalse(session.queue.isActive)
        session.libraryChanged([], ready: true)
        try await waitUntil("importing once the library is loaded") { imported == 2 }
        connection.shutDown()
    }

    // MARK: Record control and Listen Live

    func testRecordControlWaitsForTheRecorderToConfirm() async throws {
        let rig = rig(recorder())
        try await connectThroughSetup(rig)
        rig.connection.startRecording()
        XCTAssertTrue(rig.connection.recordCommandPending, "Never optimistic")
        try await waitUntil("the confirmation") { !rig.connection.recordCommandPending }
        XCTAssertEqual(rig.connection.status?.isRecording, true)
        XCTAssertEqual(rig.session.split.inProgress?.isInProgress, true, "Recording now, never offered for import")
        rig.connection.pauseRecording()
        try await waitUntil("pausing") { !rig.connection.recordCommandPending }
        XCTAssertEqual(rig.connection.status?.isRecording, false)

        rig.device.ignoresRecordCommands = true
        rig.connection.startRecording()
        try await waitUntil("giving up on confirmation") { !rig.connection.recordCommandPending }
        XCTAssertEqual(rig.connection.problem?.id, SoundcoreIssue.didNotConfirm.rawValue)
    }

    func testListenLiveSavesWhatArrivedAsAPartOfTheRecording() async throws {
        let device = recorder()
        device.isRecording = true
        device.activeRecording = .init(id: base + 600, frames: Self.frames)
        device.pace = .milliseconds(10)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        XCTAssertEqual(rig.session.split.inProgress?.id, String(base + 600))
        rig.connection.startListening()
        try await waitUntil("listening") { rig.connection.live.isListening }
        try await Task.sleep(for: .milliseconds(400))
        rig.connection.stopListening()
        try await waitUntil("the saved portion") { rig.library.imports.count == 1 && !rig.connection.live.isListening }
        let saved = rig.library.imports[0]
        XCTAssertEqual(saved.identity.recordingID, DeviceLibraryLinks.partialID(String(base + 600)))
        XCTAssertGreaterThan(saved.seconds, 0.1)
        XCTAssertNotNil(rig.connection.live.saved)
        XCTAssertEqual(rig.session.links.partial[String(base + 600)], rig.library.meetings[0].id)
        XCTAssertNil(rig.session.links.imported[String(base + 600)], "A portion isn't the whole recording")
        XCTAssertTrue(device.isRecording, "Stopping listening doesn't stop the recorder")
        XCTAssertTrue(rig.session.liveCaptions.isEmpty, "captions off: none, and nothing failed")
        XCTAssertEqual(rig.connection.live.captionState, .off)
    }

    func testListenLiveCaptionsTheRecordersBurstsAndGapsOnItsOwnTimeline() async throws {
        let device = recorder()
        device.isRecording = true
        device.activeRecording = .init(id: base + 600, frames: Self.frames)
        // Ten 20 ms packets per notification, faster than real time, then a quiet spell.
        device.slicesPerPacket = 10
        device.pace = .milliseconds(15)
        device.fault = .pause(afterSlices: 60, for: .milliseconds(250))
        let captioner = FeedRecordingCaptioner()
        let hooks = LiveCaptionHooks()
        var made = 0
        hooks.makeCaptioner = { made += 1; return captioner }
        hooks.locale = { Locale(identifier: "en_GB") }
        let rig = rig(device, captions: hooks)
        try await connectThroughSetup(rig)
        XCTAssertFalse(rig.session.isListeningLive)

        rig.connection.startListening()
        try await waitUntil("listening") { rig.session.isListeningLive }
        try await waitUntil("audio from before and after the pause") { captioner.fed.count >= 120 }
        XCTAssertEqual(made, 1)
        XCTAssertEqual(captioner.startedLocale?.identifier, "en_GB")
        XCTAssertEqual(captioner.sourceFormat?.sampleRate, 16_000)
        XCTAssertEqual(rig.connection.live.captionState, .listening)

        // The engine posts captions; the session publishes them for the device page and the iPhone.
        captioner.post([LiveCaptionSegment(start: 0.4, end: 1.6, text: "So the launch", isTentative: true)])
        try await waitUntil("the session's captions") { rig.session.liveCaptions.map(\.text) == ["So the launch"] }
        captioner.post([LiveCaptionSegment(start: 0.4, end: 2.1, text: "So the launch moves to the 14th.", isTentative: false)])
        try await waitUntil("the revision") { rig.session.liveCaptions.first?.isTentative == false }

        rig.connection.stopListening()
        try await waitUntil("the saved portion") { rig.library.imports.count == 1 && !rig.session.isListeningLive }
        try await waitUntil("the captioner to finish") { captioner.finished }
        XCTAssertTrue(rig.session.liveCaptions.isEmpty, "captions go with listening; they're never saved")
        XCTAssertEqual(rig.connection.live.captionState, .off)

        // Every decoded packet went in as it arrived, at the recorder's own rate, stamped by its
        // place in the live audio: back to back through the bursts and the pause.
        let fed = captioner.fed
        XCTAssertTrue(fed.allSatisfy { $0.rate == 16_000 && $0.frames > 0 })
        XCTAssertEqual(fed.first?.time, 0)
        for (previous, next) in zip(fed, fed.dropFirst()) {
            XCTAssertEqual(next.time, previous.time + Double(previous.frames) / 16_000, accuracy: 1e-9)
        }
        // If the recognizer drops the opening while it starts, the engine's time map still places
        // what it hears where it was recorded.
        let map = CaptionTimeMap(origin: 0)
        let kept = fed.dropFirst(50)
        for buffer in kept { map.feed(sourceTime: buffer.time, duration: Double(buffer.frames) / 16_000) }
        let firstKept = try XCTUnwrap(kept.first)
        XCTAssertEqual(map.sourceTime(0), firstKept.time, accuracy: 1e-6)
        XCTAssertGreaterThan(firstKept.time, 0.9)
    }

    func testTheSessionMirrorsListenLiveForEveryScreen() async throws {
        // An inert link never connects: Listen Live can't start, so no captioner is made.
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { InertSoundcoreTransport() }
        var made = 0
        environment.liveCaptions.makeCaptioner = { made += 1; return nil }
        let configured = ConfiguredDevice(id: "inert", kind: SoundcoreWorkIntegration().kind)
        let connection = SoundcoreConnection(device: configured, environment: environment)
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        connection.startListening()
        XCTAssertEqual(made, 0)
        XCTAssertFalse(session.isListeningLive)
        XCTAssertEqual(session.liveCaptions, [])

        var changes = 0
        let watching = session.objectWillChange.sink { changes += 1 }
        let line = LiveCaptionSegment(start: 3, end: 4.5, text: "We still need legal", isTentative: true)
        connection.live.isListening = true
        connection.live.captions = [line]
        XCTAssertTrue(session.isListeningLive)
        XCTAssertEqual(session.liveCaptions, [line])
        XCTAssertGreaterThanOrEqual(changes, 2, "observable: screens redraw as captions arrive")
        connection.live.captions = []
        connection.live.isListening = false
        XCTAssertFalse(session.isListeningLive)
        XCTAssertEqual(session.liveCaptions, [])
        watching.cancel()
    }

    // MARK: The read-only promise

    func testOnlyReadOnlyCommandsAreEverSent() async throws {
        let device = recorder()
        device.isRecording = true
        device.activeRecording = .init(id: base + 600, frames: Self.frames)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.session.importRecordings(rig.session.newRecordings)
        try await waitUntil("imports") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        rig.connection.refresh()
        try await waitUntil("refresh") { !rig.connection.isRefreshing }
        let allowed: Set<[UInt8]> = [[0x01, 0x01], [0x1b, 0x0e], [0x1a, 0x0e], [0x2e, 0x01], [0x1a, 0x07], [0x1a, 0x11], [0x18, 0x82]]
        for command in device.received {
            XCTAssertTrue(allowed.contains([command.type, command.command]), "Unexpected command \(command)")
        }
        XCTAssertFalse(device.received.contains { $0.type == 0x18 }, "Recording control only when asked")
        XCTAssertEqual(device.recordings.count, 2)
    }
    // MARK: One owner per recorder

    private static let thisMac = "this-mac"

    private func owner(_ id: String, serial: String = "D3200SIM0000001") -> RecorderOwnership {
        RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: serial, ownerID: id,
                          ownerName: id == Self.thisMac ? "Studio Mac" : "Alex’s iPhone", ownerClass: id == Self.thisMac ? .mac : .phone)
    }

    func testARecorderAnotherDeviceManagesIsNeverReachedForUntilItsReleased() async throws {
        let device = recorder()
        let rig = rig(device, automatic: true, since: .distantPast, remembered: true, rememberedSerial: device.serial,
                      owners: [owner("phone-1")])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(rig.transport.connectAttempts, 0, "No automatic connection to a recorder the phone manages")
        XCTAssertEqual(rig.connection.state, .notConnected)
        XCTAssertEqual(rig.session.managedElsewhere?.ownerName, "Alex’s iPhone")
        XCTAssertEqual(rig.connection.summary, "Managed by Alex’s iPhone")
        XCTAssertTrue(rig.connection.automaticImports(links: rig.session.links, since: .distantPast, excluding: []).isEmpty)

        rig.connection.connect()
        rig.session.connect()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.transport.connectAttempts, 0, "Connect does nothing while another device manages it")
        XCTAssertTrue(rig.library.imports.isEmpty)

        // Owned by this Mac (or by nobody): automatic import works as before.
        rig.session.applyOwnership([owner(Self.thisMac)], thisDevice: Self.thisMac)
        XCTAssertNil(rig.session.managedElsewhere)
        try await waitUntil("connecting once this Mac manages it") { rig.connection.state == .connected }
        try await waitUntil("the imports") { rig.library.imports.count == 2 }
        rig.session.applyOwnership([], thisDevice: Self.thisMac)
        XCTAssertNil(rig.session.managedElsewhere)
    }

    func testALinkIsLetGoWhenAnotherDeviceTakesOverButNotMidTransfer() async throws {
        let device = recorder(count: 1)
        device.pace = .milliseconds(15)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        XCTAssertEqual(rig.session.recorderSerial, device.serial, "the serial arrives with the first connection")
        rig.session.applyOwnership([], thisDevice: Self.thisMac)
        XCTAssertNil(rig.session.managedElsewhere)

        rig.session.importRecordings(rig.session.newRecordings)
        try await waitUntil("the transfer to start") {
            if case .receiving? = rig.session.phase { return true }
            return false
        }
        // The phone takes it over in the middle of the transfer.
        rig.session.applyOwnership([owner("phone-1")], thisDevice: Self.thisMac)
        XCTAssertEqual(rig.session.managedElsewhere?.ownerID, "phone-1")
        XCTAssertEqual(rig.connection.state, .connected, "a transfer in progress finishes")
        try await waitUntil("the import") { rig.library.imports.count == 1 }
        try await waitUntil("letting the recorder go") { rig.connection.state == .notConnected && !rig.transport.connected }
        XCTAssertEqual(rig.connection.summary, "Managed by Alex’s iPhone")

        let attempts = rig.transport.connectAttempts
        rig.connection.connect()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.transport.connectAttempts, attempts)
        XCTAssertNotEqual(rig.connection.state, .connected)
    }

    func testTheHubAppliesOwnershipToDevicesAddedLater() async throws {
        let device = recorder()
        let transport = SimulatedSoundcoreTransport(device: device)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        environment.soundcoreTiming = timing
        let hub = DeviceHub(environment: environment)
        hub.recorderOwnersChanged([owner("phone-1")], thisDevice: Self.thisMac)
        let session = try XCTUnwrap(hub.beginSetup(SoundcoreWorkIntegration().kind))
        let connection = try XCTUnwrap(session.direct as? SoundcoreConnection)
        connection.search()
        try await waitUntil("a recorder to be found") { !connection.discovered.isEmpty }
        connection.connect(to: connection.discovered[0])
        try await waitUntil("the connection") { connection.state == .connected }
        XCTAssertNil(session.managedElsewhere, "setup isn't interrupted")
        hub.commitSetup()
        XCTAssertEqual(session.managedElsewhere?.ownerName, "Alex’s iPhone")
        try await waitUntil("letting the recorder go") { connection.state == .notConnected }
        hub.recorderOwnersChanged([], thisDevice: Self.thisMac)
        XCTAssertNil(session.managedElsewhere)
        hub.remove(session.id)
    }
}

/// A captioner that keeps what Listen Live feeds it (each buffer's time on the live audio's
/// timeline, rate, and length) and posts captions when told. No speech recognition.
final class FeedRecordingCaptioner: LiveCaptioning, @unchecked Sendable {
    struct Fed: Equatable { var time: TimeInterval; var rate: Double; var frames: Int }
    let updates: AsyncStream<[LiveCaptionSegment]>
    let states: AsyncStream<LiveCaptionState>
    private let updatesContinuation: AsyncStream<[LiveCaptionSegment]>.Continuation
    private let statesContinuation: AsyncStream<LiveCaptionState>.Continuation
    private let lock = NSLock()
    private var buffers: [Fed] = []
    private var locale: Locale?
    private var format: AVAudioFormat?
    private var done = false

    init() {
        (updates, updatesContinuation) = AsyncStream.makeStream()
        (states, statesContinuation) = AsyncStream.makeStream()
    }

    var fed: [Fed] { lock.withLock { buffers } }
    var startedLocale: Locale? { lock.withLock { locale } }
    var sourceFormat: AVAudioFormat? { lock.withLock { format } }
    var finished: Bool { lock.withLock { done } }

    func start(locale: Locale, sourceFormat: AVAudioFormat?) async {
        lock.withLock { self.locale = locale; format = sourceFormat }
        statesContinuation.yield(.listening)
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        let seconds = time.map { Double($0.sampleTime) / $0.sampleRate } ?? -1
        lock.withLock { buffers.append(Fed(time: seconds, rate: buffer.format.sampleRate, frames: Int(buffer.frameLength))) }
    }

    func post(_ segments: [LiveCaptionSegment]) { updatesContinuation.yield(segments) }

    func finish() async {
        lock.withLock { done = true }
        statesContinuation.yield(.finished)
        updatesContinuation.finish()
        statesContinuation.finish()
    }
}
