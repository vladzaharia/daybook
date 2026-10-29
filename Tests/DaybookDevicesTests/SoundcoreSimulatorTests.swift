import AVFoundation
import DaybookCaptions
import DaybookCore
import DaybookIntelligence
import DaybookTestSupport
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
        suite = makeTestSuite("local.daybook.tests.soundcore-sim")
        defaults = UserDefaults(suiteName: suite)
        staging = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSim-\(UUID().uuidString)", isDirectory: true)
        transportsMade = 0
    }

    override func tearDown() async throws {
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
        timing.otherAppQuiet = .milliseconds(300)
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

    // MARK: A list that doesn't come

    private func connectWithoutWaitingForTheList(_ rig: Rig) async throws {
        rig.connection.search()
        try await waitUntil("a recorder to be found") { !rig.connection.discovered.isEmpty }
        rig.connection.connect(to: rig.connection.discovered[0])
    }

    /// The recorder connects but doesn't answer the request for its list (on an iPhone, the Soundcore
    /// app may be transferring over the same link). That isn't "nothing new": the session says it
    /// hasn't been listed, the page says why, and it's tried again quietly until it lists.
    func testARecorderThatDoesNotListSaysSoAndIsListedAgainOnItsOwn() async throws {
        let device = recorder(count: 2)
        device.unansweredListings = 1
        let rig = rig(device, configure: { $0.request = .milliseconds(250); $0.relist = [.milliseconds(150), .milliseconds(300)] })
        try await connectWithoutWaitingForTheList(rig)
        try await waitUntil("the list request to go unanswered") { rig.connection.lastListing?.failed == true && !rig.connection.isRefreshing }

        XCTAssertEqual(rig.connection.state, .connected)
        XCTAssertFalse(rig.connection.isInventoryCurrent)
        XCTAssertEqual(rig.session.listingState, .notListed, "not \"nothing new\"")
        XCTAssertTrue(rig.session.newRecordings.isEmpty, "a first connection has no remembered list")
        XCTAssertEqual(rig.connection.problem?.id, SoundcoreIssue.listFailed.rawValue)
        XCTAssertEqual(rig.connection.problem?.actions, [.refreshStatus, .technicalDetails])
        let row = try XCTUnwrap(rig.connection.technicalDetails.first { $0.label == "Recording list" })
        XCTAssertEqual(row.value, "Not listed: " + (SoundcoreError.timedOut.errorDescription ?? ""))

        try await waitUntil("listed on a quiet try again") { rig.connection.isInventoryCurrent }
        XCTAssertEqual(rig.session.listingState, .current)
        XCTAssertNil(rig.connection.problem, "the problem goes once it lists")
        XCTAssertEqual(rig.session.newRecordings.count, 2)
        let listed = try XCTUnwrap(rig.connection.technicalDetails.first { $0.label == "Recording list" })
        XCTAssertTrue(listed.value.hasPrefix("2, in 1 page, "), listed.value)
    }

    /// Automatic import waits for a list from this connection; when the first request goes
    /// unanswered, the quiet try again lists it and the recordings import.
    func testAutomaticImportCarriesOnOnceAnUnansweredListIsTriedAgain() async throws {
        let device = recorder(count: 2)
        device.unansweredListings = 1
        let rig = rig(device, automatic: true, since: .distantPast,
                      configure: { $0.request = .milliseconds(250); $0.relist = [.milliseconds(150)]; $0.automaticIdleRelease = .seconds(30) },
                      remembered: true)
        try await waitUntil("the list request to go unanswered") { rig.connection.lastListing?.failed == true }
        XCTAssertTrue(rig.library.imports.isEmpty, "nothing imports from a list that isn't current")
        try await waitUntil("the automatic imports") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        XCTAssertNil(rig.connection.problem)
        rig.connection.shutDown()
    }

    /// A recorder refusing both list layouts (busy, not old firmware) is asked for the 12-byte one
    /// again next time, so recordings keep their exact lengths.
    func testARefusedListIsTriedAgainInTheLayoutWithEndTimes() async throws {
        let device = recorder(count: 2)
        device.refusedListings = 1
        let rig = rig(device, configure: { $0.relist = [.milliseconds(100)] })
        try await connectWithoutWaitingForTheList(rig)
        try await waitUntil("the refusal") { rig.connection.lastListing?.failed == true }
        XCTAssertEqual(rig.connection.problem?.id, SoundcoreIssue.listFailed.rawValue)
        try await waitUntil("listed on a try again") { rig.connection.isInventoryCurrent }
        XCTAssertEqual(rig.connection.recordings.count, 2)
        XCTAssertTrue(rig.connection.recordings.allSatisfy { $0.length?.isEstimate == false }, "end times, from the 12-byte layout")
        XCTAssertEqual(device.received.filter { $0 == (0x1b, 0x0e) }.count, 3, "refused, then the list and its empty second page")
    }

    /// Every attempt fails: it stops trying after the schedule, says so, and Refresh still works.
    func testTryingAgainStopsAfterItsScheduleAndRefreshStillLists() async throws {
        let device = recorder(count: 1)
        device.unansweredListings = 3
        let rig = rig(device, configure: { $0.request = .milliseconds(150); $0.relist = [.milliseconds(50)] })
        try await connectWithoutWaitingForTheList(rig)
        try await waitUntil("both attempts to go unanswered") {
            device.unansweredListings == 1 && rig.connection.lastListing?.failed == true && !rig.connection.isRefreshing
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(device.unansweredListings, 1, "no third attempt on its own")
        XCTAssertEqual(rig.session.listingState, .notListed)
        XCTAssertEqual(rig.connection.problem?.id, SoundcoreIssue.listFailed.rawValue)

        rig.connection.refresh()
        try await waitUntil("the person's refresh to go unanswered") { device.unansweredListings == 0 && !rig.connection.isRefreshing }
        rig.connection.refresh()
        try await waitUntil("listed") { rig.connection.isInventoryCurrent }
        XCTAssertNil(rig.connection.problem)
        XCTAssertEqual(rig.session.newRecordings.count, 1)
    }

    /// On iPhone, iOS shares the recorder's link between apps: the Soundcore app's list replies and
    /// transfer reach Daybook unasked. They're counted for Device Details and change nothing here.
    func testAnotherAppsRepliesAndAudioAreCountedAndChangeNothing() async throws {
        let rig = rig(recorder(count: 2))
        try await connectThroughSetup(rig)
        let before = rig.connection.recordings
        rig.device.serveAnotherApp(recordingID: base)
        try await waitUntil("the other app's audio") {
            rig.connection.technicalDetails.contains { $0.label == "Audio packets not requested here" && $0.value == "8" }
        }
        XCTAssertTrue(rig.connection.technicalDetails.contains { $0.label == "Replies not requested here" && $0.value == "1" })
        XCTAssertEqual(rig.connection.recordings, before)
        XCTAssertTrue(rig.library.imports.isEmpty)
        XCTAssertNil(rig.connection.problem)

        // An import of Daybook's own still works.
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
    }

    // MARK: Two apps on one link

    private func requests(_ rig: Rig) -> Int { rig.device.received.filter { $0 == (0x1a, 0x07) }.count }

    /// The Soundcore app transfers over the link iOS shares: Daybook's import waits, says so, never asks
    /// the recorder for anything that would cut the other transfer off, and starts once it has been quiet.
    func testAnImportWaitsForAnotherAppsTransferAndNeverCutsItOff() async throws {
        let rig = rig(recorder(count: 2))
        try await connectThroughSetup(rig)
        rig.device.beginAnotherAppsTransfer(recordingID: base + 1, slices: 60)
        try await waitUntil("the other app's audio") { rig.connection.technicalDetails.contains { $0.label == "Another app" } }
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the import to wait") { rig.session.isWaitingForOtherApp }
        XCTAssertEqual(rig.session.otherAppWait, "Waiting for the Soundcore app to finish")
        XCTAssertTrue(rig.session.diagnostics.contains("Waiting for the Soundcore app to finish"))
        XCTAssertEqual(rig.session.phase, .preparing)

        try await waitUntil("the other app's transfer to finish") { rig.device.anotherAppsTransfersFinished == 1 }
        XCTAssertEqual(requests(rig), 0, "nothing was requested over it")
        XCTAssertTrue(rig.session.isWaitingForOtherApp, "a few quiet seconds first")
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertFalse(rig.session.isWaitingForOtherApp)
        XCTAssertNil(rig.session.otherAppWait)
        XCTAssertTrue(rig.device.commandsDuringAnotherAppsTransfer.isEmpty)
        XCTAssertNil(rig.session.transferProblem)
        XCTAssertTrue(rig.session.failures.isEmpty)
    }

    /// Start waits too: sent over another app's transfer, it could end it.
    func testStartWaitsForAnotherAppsTransfer() async throws {
        let rig = rig(recorder(count: 1))
        try await connectThroughSetup(rig)
        rig.device.beginAnotherAppsTransfer(recordingID: base + 1, slices: 45)
        try await waitUntil("the other app's audio") { rig.connection.technicalDetails.contains { $0.label == "Another app" } }
        rig.connection.startRecording()
        XCTAssertTrue(rig.connection.recordCommandPending)
        try await waitUntil("Start to wait") { rig.session.isWaitingForOtherApp }
        XCTAssertFalse(rig.device.received.contains { $0.type == 0x18 })
        try await waitUntil("the other app's transfer to finish") { rig.device.anotherAppsTransfersFinished == 1 }
        try await waitUntil("recording") { !rig.connection.recordCommandPending && rig.connection.status?.isRecording == true }
        XCTAssertTrue(rig.device.commandsDuringAnotherAppsTransfer.isEmpty)
        XCTAssertNil(rig.connection.problem)
    }

    /// A transfer of Daybook's under way when the other app starts one gives way: it keeps nothing,
    /// doesn't ask the recorder to stop sending (that would stop the other app's), and starts again from
    /// the beginning once the other transfer has finished. It isn't a failure.
    func testATransferUnderWayGivesWayToAnotherAppsWithoutStoppingIt() async throws {
        let device = recorder(count: 1)
        device.pace = .milliseconds(20)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("audio arriving") { if case .receiving = rig.session.phase { return true } else { return false } }
        device.beginAnotherAppsTransfer(recordingID: base + 1, slices: 30)
        try await waitUntil("the import to wait") { rig.session.isWaitingForOtherApp }
        XCTAssertTrue(rig.session.queue.isActive)
        try await waitUntil("the other app's transfer to finish") { device.anotherAppsTransfersFinished == 1 }
        XCTAssertFalse(device.received.contains { $0 == (0x1a, 0x11) }, "the recorder was never asked to stop sending")
        try await waitUntil("the import, from the start") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertEqual(requests(rig), 2, "cut off once, then asked for again")
        XCTAssertEqual(rig.library.imports[0].seconds, 1, accuracy: 0.1, "the whole recording")
        XCTAssertTrue(device.commandsDuringAnotherAppsTransfer.isEmpty)
        XCTAssertTrue(rig.session.failures.isEmpty)
        XCTAssertNil(rig.session.transferProblem)
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    /// The recorder keeps one audio key: when another app exchanges keys, Daybook's next transfer
    /// exchanges its own again rather than failing to unwrap the file's key.
    func testAnotherAppsKeyExchangeIsFollowedByOneOfDaybooksOwn() async throws {
        let rig = rig(recorder(count: 2))
        try await connectThroughSetup(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the first import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        rig.device.anotherAppExchangesKeys()
        try await waitUntil("the other app's reply") { rig.connection.technicalDetails.contains { $0.label == "Replies not requested here" } }
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the second import") { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        XCTAssertEqual(rig.device.received.filter { $0 == (0x2e, 0x01) }.count, 2)
        XCTAssertTrue(rig.session.failures.isEmpty)
    }

    /// Details says why each recording on the recorder is or isn't new, matching what's offered.
    func testDetailsSayWhyEachRecordingIsOrIsNotNew() async throws {
        let device = recorder(count: 3)
        device.isRecording = true
        device.activeRecording = .init(id: base + 600, frames: Self.frames)
        device.listsActiveRecording = true
        let rig = rig(device)
        try await connectThroughSetup(rig)
        let newest = String(base), middle = String(base - 3_600), oldest = String(base - 7_200)
        rig.session.importRecordings(rig.session.newRecordings.filter { $0.id == newest })
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        rig.session.adoptHandedOffImports([], alreadyImported: [middle])

        let standings = rig.session.standings
        XCTAssertEqual(standings.map(\.id), [String(base + 600), newest, middle, oldest], "newest first")
        XCTAssertEqual(standings.map(\.reason), [.recordingNow, .inDaybook(rig.library.meetings[0].id), .arrivingThroughSync, .new])
        XCTAssertEqual(standings.filter { $0.reason == .new }.map(\.recording), rig.session.newRecordings)

        let text = rig.session.diagnostics
        for line in ["list: current", "Recording list: 4, in 1 page, ", "Named in progress: ", "(recording)", "On the device: 4",
                     "Recording now · \(base + 600)", "In Daybook · \(newest)", "Arriving from another device · \(middle)", "New · \(oldest)"] {
            XCTAssertTrue(text.contains(line), "Details text lacks \(line):\n\(text)")
        }
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

    func testBluetoothResetReopensTheSessionAndCommandsWorkAgain() async throws {
        let rig = rig(recorder())
        try await connectThroughSetup(rig)
        rig.transport.setRadio(.resetting)
        try await waitUntil("Bluetooth resetting") { rig.connection.state != .connected }
        rig.transport.setRadio(.poweredOn)
        try await waitUntil("reconnected after a Bluetooth reset") { rig.connection.state == .connected && rig.connection.info != nil && !rig.connection.isRefreshing }
        rig.connection.startRecording()
        try await waitUntil("record control on the replacement session") { rig.connection.status?.isRecording == true }
    }

    func testStoppingListenBeforeItsTaskRunsDoesNotStartATransfer() async throws {
        let device = recorder()
        device.isRecording = true
        device.activeRecording = .init(id: base + 600, frames: Self.frames)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        let commandsBefore = device.received.count
        rig.connection.startListening()
        rig.connection.stopListening()
        try await waitUntil("listening setup cancelled") { !rig.connection.live.isListening }
        XCTAssertEqual(device.received.count, commandsBefore)
        XCTAssertTrue(rig.library.imports.isEmpty)
        XCTAssertTrue(device.isRecording)
    }

    func testStoppingAQueuedListenerDoesNotWaitForOrCancelADownload() async throws {
        let device = recorder()
        device.isRecording = true
        device.activeRecording = .init(id: base + 600, frames: Self.frames)
        device.fault = .stall(afterSlices: 3)
        let rig = rig(device, configure: { $0.stall = .seconds(10) })
        try await connectThroughSetup(rig)
        let recording = try XCTUnwrap(rig.session.split.new.first)
        rig.session.importRecordings([recording])
        try await waitUntil("download has started") { device.received.contains { $0.type == 0x1a && $0.command == 0x07 } }
        rig.connection.startListening()
        // Let the listener enter the exclusive-operation queue behind the stalled download.
        for _ in 0..<10 { await Task.yield() }
        rig.connection.stopListening()
        try await waitUntil("queued listener cancelled", timeout: 2) { !rig.connection.live.isListening }
        XCTAssertEqual(device.received.filter { $0.type == 0x1a && $0.command == 0x07 }.count, 1)
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

    func testARecordingThatArrivesThroughSyncWhileItTransfersIsNotImportedAgain() async throws {
        let device = recorder(count: 1)
        device.pace = .milliseconds(15)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        let target = try XCTUnwrap(rig.session.newRecordings.first)
        rig.session.importRecordings([target])
        try await waitUntil("the transfer") { if case .receiving = rig.session.phase { return true } else { return false } }
        // Meanwhile another device's import of it reaches this library.
        let identity = DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: device.serial, recordingID: target.id)
        let synced = Meeting(title: "From Alex’s iPhone", tracks: [RecordingTrack(source: .soundcore, relativePath: "Originals/p.wav",
                                                                                   fileName: "p.wav", device: identity)])
        rig.library.meetings.append(synced)
        rig.session.libraryChanged(rig.library.meetings, ready: true)
        try await waitUntil("the transfer to end") { !rig.session.queue.isActive }
        XCTAssertTrue(rig.library.imports.isEmpty, "the importer isn't asked for a second copy")
        XCTAssertTrue(rig.session.failures.isEmpty)
        XCTAssertNil(rig.session.transferProblem)
        XCTAssertEqual(rig.session.links.imported[target.id], synced.id)
        XCTAssertTrue(stagedFiles.isEmpty)
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
        XCTAssertFalse(rig.connection.technicalDetails.contains { $0.label == "Another app" }, "its own stragglers aren't another app's")
    }

    func testDisconnectMidTransferWaitsReconnectsAndResumes() async throws {
        let device = recorder()
        // One drop only: the transfer after the reconnect runs clean, however soon it starts.
        device.fault = .once(.disconnect(afterSlices: 12))
        let rig = rig(device, configure: { $0.backoff = [.milliseconds(400), .milliseconds(400)] })
        try await connectThroughSetup(rig)
        let target = rig.session.newRecordings[0]
        rig.session.importRecordings([target])
        try await waitUntil("the drop") { rig.session.queue.isSuspended }
        XCTAssertNil(device.fault, "the first transfer took it")
        XCTAssertEqual(rig.session.transferProblem?.id, SoundcoreIssue.disconnectedDuringImport.rawValue)
        XCTAssertEqual(rig.session.queue.waiting.first?.id, target.id, "The recording waits at the front")
        XCTAssertTrue(rig.library.imports.isEmpty, "Nothing partial is saved")
        XCTAssertTrue(stagedFiles.isEmpty)
        try await waitUntil("the reconnect and resumed import") { rig.library.imports.count == 1 }
        XCTAssertEqual(device.received.filter { $0 == (0x1a, 0x07) }.count, 2, "one transfer dropped, one resumed")
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

    // MARK: Staged audio

    // A transfer stages its audio in the staging folder until the library has a copy. Whatever
    // happens to it, nothing stays there, and nothing removes the file of a transfer still running.

    func testStoppingDuringTheKeyExchangeStagesNothingAndTheNextImportWorks() async throws {
        let device = recorder()
        device.answersKeyExchange = false
        let rig = rig(device)
        try await connectThroughSetup(rig)
        let target = rig.session.newRecordings[0]
        rig.session.importRecordings([target])
        try await waitUntil("the key exchange") { device.received.contains { $0 == (0x2e, 0x01) } }
        rig.session.stopCurrent()
        XCTAssertFalse(rig.session.queue.isActive)
        XCTAssertTrue(stagedFiles.isEmpty)

        // The recorder answers this time: the import waits for the stopped one to let go, exchanges
        // keys again, and is the only transfer the recorder was asked for.
        device.answersKeyExchange = true
        rig.session.importRecordings([target])
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertEqual(device.received.filter { $0 == (0x2e, 0x01) }.count, 2)
        XCTAssertEqual(device.received.filter { $0 == (0x1a, 0x07) }.count, 1, "nothing was requested during the exchange")
        XCTAssertTrue(rig.session.failures.isEmpty)
        XCTAssertNil(rig.session.transferProblem, "stopping isn't a problem")
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    func testAnImportTheLibraryRefusesLeavesNothingStaged() async throws {
        let rig = rig(recorder())
        try await connectThroughSetup(rig)
        var stagedWhileImporting: [String] = []
        rig.session.importer = { [self] url, _, _, _ in
            stagedWhileImporting = stagedFiles
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            throw DaybookError.invalidAudio(url.lastPathComponent)
        }
        rig.session.importRecordings([rig.session.newRecordings[0]])
        try await waitUntil("the failure") { !rig.session.failures.isEmpty && !rig.session.queue.isActive }
        XCTAssertEqual(stagedWhileImporting.count, 1, "the transfer finished and staged its audio")
        XCTAssertTrue(stagedFiles.isEmpty, "removed although the library didn't take it")
        XCTAssertTrue(rig.library.imports.isEmpty)
        XCTAssertNil(rig.session.links.imported[rig.session.failures[0].id], "it stays new on the recorder")
    }

    func testAWrongSizeRemovesEachAttemptsAudioAndOnlyItsOwn() async throws {
        let device = recorder()
        device.fault = .wrongSize
        device.pace = .milliseconds(20)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        let first = try await waitFor("the first attempt's audio") { stagedFiles.first }
        // The quiet retry stages its own file; the first attempt's cleanup took only its own.
        let second = try await waitFor("the retry's audio") {
            device.received.filter { $0 == (0x1a, 0x07) }.count == 2 ? stagedFiles.first : nil
        }
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(stagedFiles, [second])
        try await waitUntil("the failure") { !rig.session.queue.isActive }
        XCTAssertEqual(rig.session.transferProblem?.id, SoundcoreIssue.integrity.rawValue)
        XCTAssertTrue(rig.library.imports.isEmpty)
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    /// What a killed or crashed run left goes when the devices start (`DeviceHub.start()`), by its
    /// age: a transfer of this run, writing as it goes, keeps its file and imports.
    func testLeftoversOfAnEarlierRunGoAndATransferUnderWayKeepsItsFile() async throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let leftover = staging.appendingPathComponent("Soundcore-\(base - 7_200)-0badf00d.wav")
        try Data(repeating: 1, count: 4_096).write(to: leftover)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: leftover.path)
        let launched = Date()
        let device = recorder()
        device.pace = .milliseconds(20)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.session.importRecordings([rig.session.newRecordings[0]])
        let current = try await waitFor("this run's transfer to stage its audio") {
            stagedFiles.first { $0 != leftover.lastPathComponent }
        }
        XCTAssertEqual(DeviceHub.removeLeftoverStaging(in: staging, olderThan: launched).map(\.lastPathComponent), [leftover.lastPathComponent])
        XCTAssertEqual(stagedFiles, [current], "the transfer under way keeps its file")
        try await waitUntil("the import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertTrue(rig.session.failures.isEmpty)
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    func testListenLiveWithNowhereToSaveLeavesNothingStaged() async throws {
        let device = recorder()
        device.isRecording = true
        device.activeRecording = .init(id: base + 600, frames: Self.frames)
        device.pace = .milliseconds(10)
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.session.importer = nil
        rig.connection.startListening()
        try await waitUntil("audio arriving") { !stagedFiles.isEmpty }
        rig.connection.stopListening()
        try await waitUntil("the portion, kept") { rig.connection.live.saved != nil && !rig.connection.live.isListening }
        try await waitUntil("its staged audio removed") { stagedFiles.isEmpty }
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

    func testABackgroundWakeReachesForTheRecorderOnceTheWaitHasRunOut() async throws {
        // On iPhone the wait between automatic imports is a timer, and a suspended app runs none.
        let rig = rig(recorder(count: 1), automatic: true, since: .distantPast, remembered: true)
        try await waitUntil("the import, then letting go") {
            rig.library.imports.count == 1 && rig.connection.state == .notConnected && !rig.transport.connected
        }
        let due = try XCTUnwrap(rig.connection.automaticDueAt)
        XCTAssertEqual(due.timeIntervalSinceNow, 60, accuracy: 5, "the cooldown, on the wall clock")
        let attempts = rig.transport.connectAttempts

        rig.connection.resumeAutomaticImportIfDue()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.transport.connectAttempts, attempts, "not before the wait is over")

        // App refresh wakes the app after the wait ran out: it reaches for the recorder at once.
        rig.connection.resumeAutomaticImportIfDue(now: due.addingTimeInterval(1))
        XCTAssertNil(rig.connection.automaticDueAt)
        try await waitUntil("connecting again") { rig.transport.connectAttempts > attempts && rig.connection.state == .connected }

        // Turned off, a wake does nothing.
        rig.session.update { $0.importsAutomatically = false }
        rig.connection.disconnect()
        let after = rig.transport.connectAttempts
        rig.connection.resumeAutomaticImportIfDue(now: .distantFuture)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.transport.connectAttempts, after)
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

    func testAReconnectNeverImportsFromTheRememberedListBeforeListingAgain() async throws {
        // A remembered list from an earlier run (as v0.3.0 saved it, with no active recording): the
        // newest entry was being recorded then, and still is. Firmware that lists the active file
        // names it among the entries too.
        let device = recorder(count: 1)
        let active = SimulatedSoundcore.Recording(id: base + 600, frames: Self.frames)
        device.isRecording = true
        device.activeRecording = active
        device.listsActiveRecording = true
        device.advertises = false
        let transport = SimulatedSoundcoreTransport(device: device)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        environment.liveCaptions = Self.noCaptions()
        var timing = self.timing
        timing.automaticIdleRelease = .seconds(30)
        environment.soundcoreTiming = timing
        var configured = ConfiguredDevice(id: "stale", kind: SoundcoreWorkIntegration().kind)
        configured.importsAutomatically = true
        configured.automaticImportsSince = .distantPast
        let snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: device.name, serial: device.serial,
                                         lastConnectedAt: Date().addingTimeInterval(-600),
                                         recordings: [SoundcoreRecording(id: active.id, size: 8_000), SoundcoreRecording(id: base, size: 8_000)],
                                         recordingsUpdatedAt: Date().addingTimeInterval(-600))
        environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
        let connection = SoundcoreConnection(device: configured, environment: environment)
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        var imported: [String] = []
        var meetings: [Meeting] = []
        session.importer = { [weak session] url, identity, _, source in
            imported.append(identity.recordingID)
            meetings.append(Meeting(title: "Imported", tracks: [RecordingTrack(source: source, relativePath: "Originals/x.wav",
                                                                                fileName: url.lastPathComponent, device: identity)]))
            session?.libraryChanged(meetings, ready: true)
            return meetings.last!.id
        }
        session.activate()
        session.libraryChanged([], ready: true)
        XCTAssertFalse(connection.isInventoryCurrent)
        XCTAssertTrue(connection.automaticImports(links: session.links, since: .distantPast, excluding: []).isEmpty)

        transport.comeIntoRange()
        try await waitUntil("the import of the finished recording") { imported == [String(base)] && !session.queue.isActive }
        XCTAssertTrue(connection.isInventoryCurrent)
        XCTAssertEqual(session.split.inProgress?.id, String(active.id), "the active file is Recording now")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(imported, [String(base)], "the recording in progress is never imported early")
        XCTAssertEqual(device.received.filter { $0 == (0x1a, 0x07) }.count, 1, "and never even requested")
        XCTAssertEqual(connection.remembered?.activeRecordingID, active.id, "remembered for the next launch")

        // Once it's finished, it imports.
        device.finishRecording()
        connection.refresh()
        try await waitUntil("the finished recording's import") { imported.count == 2 }
        XCTAssertEqual(imported.last, String(active.id))
        connection.shutDown()
    }

    func testARecordingKeptOpenWhilePausedIsNeitherImportedNorQueued() async throws {
        let device = recorder(count: 1)
        device.keepsActiveWhilePaused = true
        device.listsActiveRecording = true
        let rig = rig(device, automatic: true, since: .distantPast, configure: { $0.automaticIdleRelease = .seconds(30) }, remembered: true)
        try await waitUntil("the first import") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        rig.connection.startRecording()
        try await waitUntil("recording") { !rig.connection.recordCommandPending && rig.connection.status?.isRecording == true }
        let open = try XCTUnwrap(device.activeRecording?.id)
        rig.connection.pauseRecording()
        try await waitUntil("paused") { !rig.connection.recordCommandPending && rig.connection.status?.isRecording == false }
        rig.connection.refresh()
        try await waitUntil("listed") { rig.connection.isInventoryCurrent }
        XCTAssertEqual(rig.session.split.inProgress?.id, String(open), "paused but open: still in progress")
        XCTAssertFalse(rig.session.newRecordings.contains { $0.id == String(open) })

        // Queued by hand from an older list, it leaves the queue instead of importing part of it.
        let stale = DeviceRecording(id: String(open), startedAt: Date(), length: .estimated(1), byteCount: 8_000)
        rig.session.importRecordings([stale])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(rig.session.queue.contains(String(open)))
        XCTAssertEqual(rig.library.imports.count, 1)
        XCTAssertEqual(device.received.filter { $0 == (0x1a, 0x07) }.count, 1, "no transfer of the open recording")

        device.finishRecording()
        rig.connection.refresh()
        try await waitUntil("imported once it's closed") { rig.library.imports.count == 2 }
        XCTAssertEqual(rig.library.imports.last?.identity.recordingID, String(open))
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

    func testARecordingSeenBeforeTheLinkWentShowsWithItsTimeUntilItExpires() async throws {
        let device = recorder(count: 1)
        let rig = rig(device, configure: { $0.lastKnownRecording = .milliseconds(1_500) })
        try await connectThroughSetup(rig)
        rig.connection.startRecording()
        try await waitUntil("recording") { !rig.connection.recordCommandPending && rig.connection.status?.isRecording == true }
        let id = try XCTUnwrap(device.activeRecording?.id)
        XCTAssertEqual(rig.connection.recordingState?.isLive, true)
        XCTAssertEqual(rig.connection.recordingState?.startedHere, true, "Daybook started it")

        // Let go (as the idle release does): the recorder keeps recording, and the page says so with its time.
        rig.connection.disconnect()
        let status = try XCTUnwrap(rig.connection.status)
        XCTAssertEqual(status.isRecording, true)
        XCTAssertEqual(status.recordingStartedAt, SoundcoreRecording(id: id, size: 0).date)
        let known = try XCTUnwrap(rig.connection.recordingState)
        XCTAssertFalse(known.isLive)
        XCTAssertEqual(known.activeRecordingID, id)
        XCTAssertTrue(known.startedHere)
        XCTAssertEqual(DeviceDateFormat.recordingAsOf(status.updatedAt),
                       "Recording · as of \(status.updatedAt.formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(rig.session.split.inProgress?.id, String(id), "still Recording now, never offered")
        XCTAssertTrue(rig.connection.details.contains { $0.label == "Recording" && $0.value.hasPrefix("Recording, as of") })

        // A relaunch remembers it too.
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { InertSoundcoreTransport() }
        environment.soundcoreTiming.lastKnownRecording = .milliseconds(1_500)
        var configured = rig.configured
        configured.importsAutomatically = false
        let relaunched = SoundcoreConnection(device: configured, environment: environment)
        relaunched.activate()
        XCTAssertEqual(relaunched.status?.isRecording, true)
        XCTAssertEqual(relaunched.recordingState?.activeRecordingID, id)
        XCTAssertEqual(relaunched.recordings.first { $0.id == String(id) }?.isInProgress, true)

        // Nobody can see it stop: after a while it's unknown again, and the page redraws.
        var redrawn = false
        let watching = rig.connection.objectWillChange.sink { redrawn = true }
        try await waitUntil("the remembered recording to expire", timeout: 4) { rig.connection.recordingState == nil }
        try await waitUntil("the page to redraw") { redrawn && rig.session.split.inProgress == nil }
        XCTAssertNil(rig.connection.status?.isRecording)
        XCTAssertNil(relaunched.status?.isRecording)
        watching.cancel()
    }

    func testAStartDaybookSendsMeasuresTheRecordersClockAndDatesItsRecordingsByIt() async throws {
        // A recorder whose clock runs five minutes fast (or was set in another time zone).
        let device = recorder(count: 1)
        device.serial = "D3200SKEW0000005"
        device.clockOffset = 300
        let rig = rig(device)
        try await connectThroughSetup(rig)
        XCTAssertNil(rig.connection.clock, "nothing measured until Daybook starts a recording")
        let sent = Date()
        rig.connection.startRecording()
        try await waitUntil("recording") { !rig.connection.recordCommandPending && rig.connection.status?.isRecording == true }
        let clock = try XCTUnwrap(rig.connection.clock)
        XCTAssertEqual(clock.offset, 300, accuracy: SoundcoreClock.resolution)
        XCTAssertTrue(clock.isFlagged)
        XCTAssertEqual(clock.serial, device.serial)
        XCTAssertTrue(rig.connection.technicalDetails.contains { $0.label == "Recorder clock" && $0.value.hasSuffix("ahead") })
        // Its recording in progress is dated on this device's clock, not five minutes ahead.
        let started = try XCTUnwrap(rig.connection.status?.recordingStartedAt)
        XCTAssertEqual(started.timeIntervalSince(sent), 0, accuracy: 3)
        XCTAssertEqual(rig.connection.recordingState?.startedAt, started)

        rig.connection.pauseRecording()
        try await waitUntil("its recording, listed") { rig.session.split.inProgress == nil && rig.session.newRecordings.count == 2 }
        let finished = try XCTUnwrap(rig.session.newRecordings.first)
        XCTAssertEqual(try XCTUnwrap(finished.startedAt).timeIntervalSince(sent), 0, accuracy: 3)
        // What dates an import from its identity alone uses the same clock, and its provenance says so.
        let identity = DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: device.serial, recordingID: finished.id)
        XCTAssertEqual(DeviceRecordingStart.date(of: identity), finished.startedAt)
        XCTAssertEqual(DeviceRecordingStart.clock(of: identity), CaptureRecorderClock(offset: clock.offset, applied: true, measuredAt: clock.measuredAt))
        var elsewhere = identity
        elsewhere.serial = "D3200OTHER000005"
        XCTAssertNil(DeviceRecordingStart.clock(of: elsewhere), "another recorder's clock was never measured")

        // It's remembered with the recorder.
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { InertSoundcoreTransport() }
        let relaunched = SoundcoreConnection(device: rig.configured, environment: environment)
        relaunched.activate()
        XCTAssertEqual(relaunched.clock, clock)
        relaunched.shutDown()
    }

    func testARecorderInStepIsNotCorrected() async throws {
        let device = recorder(count: 1)
        device.serial = "D3200INSTEP00001"
        let rig = rig(device)
        try await connectThroughSetup(rig)
        rig.connection.startRecording()
        try await waitUntil("recording") { !rig.connection.recordCommandPending && rig.connection.status?.isRecording == true }
        let clock = try XCTUnwrap(rig.connection.clock)
        XCTAssertFalse(clock.isFlagged)
        XCTAssertEqual(clock.correction, 0, "within the measurement's resolution")
        XCTAssertEqual(clock.summary, "In step")
        let id = try XCTUnwrap(device.activeRecording?.id)
        XCTAssertEqual(rig.connection.status?.recordingStartedAt, SoundcoreRecording(id: id, size: 0).date)
        let identity = DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: device.serial, recordingID: String(id))
        XCTAssertEqual(DeviceRecordingStart.clock(of: identity)?.applied, false, "measured and kept, not applied")
        XCTAssertEqual(DeviceRecordingStart.clock(of: identity)?.offset, clock.offset)
    }

    func testTheRecordersButtonListsItAgainOnStartAndOnStop() async throws {
        let rig = rig(recorder(count: 1))
        try await connectThroughSetup(rig)
        let listings = { rig.device.received.filter { $0 == (0x1b, 0x0e) }.count }
        let before = listings()

        rig.device.pressButton()
        try await waitUntil("recording now") { rig.connection.status?.isRecording == true && rig.session.split.inProgress != nil }
        XCTAssertGreaterThan(listings(), before)
        let id = try XCTUnwrap(rig.session.split.inProgress?.id)

        let afterStart = listings()
        rig.device.pressButton()
        try await waitUntil("the finished recording, listed") {
            !rig.connection.isRefreshing && rig.session.split.inProgress == nil && rig.session.newRecordings.contains { $0.id == id }
        }
        XCTAssertGreaterThan(listings(), afterStart, "a stop lists it again too")
        XCTAssertEqual(rig.connection.status?.isRecording, false)
        XCTAssertEqual(rig.session.newRecordings.first { $0.id == id }?.byteCount, UInt64(rig.device.recordings[0].size), "with its final size")
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
        try await waitUntil("its staged audio removed once the library has it") { stagedFiles.isEmpty }
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
