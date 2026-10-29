import DaybookCaptions
import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookDevices

/// Soundcore Work in a shared recording (docs/multipoint.md, "Starting anywhere"), against the
/// simulated recorder: its button heard and its own commands not, the link held while it's in range,
/// its audio saved into the shared conversation as it records, the recorder's own file becoming the same
/// track, and what live audio costs the link. No Bluetooth, no microphone, no downloads.
@MainActor
final class SoundcoreSharedRecordingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var staging: URL!
    private var root: URL!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: makeTestSuite("local.daybook.tests.soundcore-shared"))
        staging = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookShared-\(UUID().uuidString)", isDirectory: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSharedLibrary-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(at: root)
    }

    /// A library on disk: imports go through `MeetingStore.importAudio`, as the apps' do.
    private final class Library {
        let store: MeetingStore
        var meetings: [UUID: Meeting] = [:]
        var imports: [(identity: DeviceRecordingIdentity, attachTo: UUID?)] = []
        init(root: URL) throws { store = try MeetingStore(rootURL: root) }
    }

    private struct Rig {
        let session: DeviceSession
        let connection: SoundcoreConnection
        let transport: SimulatedSoundcoreTransport
        let device: SimulatedSoundcore
        let library: Library
    }

    private func rig(_ device: SimulatedSoundcore, holds: Bool = false, known: Bool = true,
                     configure: ((inout SoundcoreTiming) -> Void)? = nil) -> Rig {
        let transport = SimulatedSoundcoreTransport(device: device)
        transport.isKnown = known
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
        timing.recordConfirm = .milliseconds(1_500)
        timing.backoff = [.milliseconds(40), .milliseconds(80)]
        timing.automaticIdleRelease = .milliseconds(200)
        timing.idleRelease = .milliseconds(200)
        timing.automaticCooldown = .seconds(60)
        timing.holdRetry = .milliseconds(150)
        timing.liveTail = .milliseconds(400)
        configure?(&timing)
        environment.soundcoreTiming = timing
        let configured = ConfiguredDevice(id: "sim", kind: SoundcoreWorkIntegration().kind)
        var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: device.name, serial: device.serial)
        snapshot.lastConnectedAt = Date().addingTimeInterval(-3_600)
        environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
        let connection = SoundcoreConnection(device: configured, environment: environment)
        connection.importsAutomatically = false
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        let library = try! Library(root: root)
        session.importer = { [weak session] url, identity, attachTo, source in
            library.imports.append((identity, attachTo))
            let meeting = attachTo.flatMap { library.meetings[$0] } ?? Meeting(id: attachTo ?? UUID(), title: "Shared")
            let stored = try await library.store.importAudio(from: url, into: meeting, source: source, device: identity)
            library.meetings[stored.id] = stored
            session?.libraryChanged(Array(library.meetings.values), ready: true)
            return stored.id
        }
        connection.staysConnected = holds
        session.activate()
        session.libraryChanged([], ready: true)
        return Rig(session: session, connection: connection, transport: transport, device: device, library: library)
    }

    private func connected(_ rig: Rig) async throws {
        if !rig.connection.state.isConnected { rig.connection.connect() }
        try await waitUntil("the connection") { rig.connection.state == .connected }
        try await waitUntil("the recording list") { rig.connection.isInventoryCurrent }
    }

    // MARK: The button

    func testTheRecordersButtonIsHeardAndItsOwnCommandsArent() async throws {
        let device = SimulatedSoundcore(recordings: [])
        let rig = rig(device)
        var presses: [Bool] = []
        rig.session.onRecorderButton = { _, on in presses.append(on) }
        try await connected(rig)

        device.pressButton()
        try await waitUntil("the press is heard") { presses == [true] }
        XCTAssertEqual(rig.connection.status?.isRecording, true)
        device.pressButton()
        try await waitUntil("and the second") { presses == [true, false] }

        // Daybook's own Start and Pause aren't the button.
        rig.connection.startRecording()
        try await waitUntil("its own start") { rig.connection.status?.isRecording == true && !rig.connection.recordCommandPending }
        rig.connection.pauseRecording()
        try await waitUntil("its own pause") { rig.connection.status?.isRecording == false && !rig.connection.recordCommandPending }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(presses, [true, false], "only the button")
    }

    // MARK: Holding the link

    func testHoldingTheLinkConnectsKeepsItAndComesBackWithoutACooldown() async throws {
        let device = SimulatedSoundcore(recordings: [])
        let rig = rig(device, holds: true)
        try await waitUntil("it connects on its own, holding the link") { rig.connection.state == .connected }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(rig.connection.state, .connected, "never let go when idle (automatic and personal releases are 200 ms here)")

        rig.transport.dropLink()
        try await waitUntil("it comes back on its own, without the 60 s cooldown") { rig.connection.state == .connected }

        // The person disconnects: holding waits like automatic import does.
        rig.connection.disconnect()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotEqual(rig.connection.state, .connected, "a person's Disconnect stands")
        XCTAssertEqual(rig.transport.scans, 0, "holding the link never scans")
    }

    func testHoldingARecorderTheSystemDoesntKnowNeverScansAndTriesAgain() async throws {
        let device = SimulatedSoundcore(recordings: [])
        let rig = rig(device, holds: true, known: false)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(rig.transport.scans, 0, "no scan, in the background or not")
        XCTAssertNotEqual(rig.connection.state, .connected)
        rig.transport.isKnown = true
        try await waitUntil("the system's record of it, tried again shortly") { rig.connection.state == .connected }
        XCTAssertEqual(rig.transport.scans, 0)
    }

    /// iOS relaunching Daybook for the recorder can bring the press before the link is ready: a held
    /// link that comes back to find a recording started moments ago, which it didn't know of, hears it
    /// as the press. One started long before isn't one.
    func testAPressMissedWhileTheHeldLinkCameBackIsStillHeard() async throws {
        let device = SimulatedSoundcore(recordings: [])
        let rig = rig(device, holds: true)
        var presses: [Bool] = []
        rig.session.onRecorderButton = { _, on in presses.append(on) }
        try await waitUntil("held") { rig.connection.isInventoryCurrent }

        device.advertises = false
        rig.transport.dropLink()
        try await waitUntil("away") { rig.connection.state != .connected }
        device.pressButton()
        rig.transport.comeIntoRange()
        try await waitUntil("back, and the press heard") { presses == [true] }

        // Away again; the person stops it and, ten minutes on the recorder's clock later, starts another.
        device.advertises = false
        rig.transport.dropLink()
        try await waitUntil("away again") { rig.connection.state != .connected }
        device.pressButton()
        device.clockOffset = -600
        device.pressButton()
        rig.transport.comeIntoRange()
        try await waitUntil("back") { rig.connection.isInventoryCurrent }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(presses, [true], "a recording it didn't see start just now isn't a press")
    }

    // MARK: Live audio into the shared recording

    func testLiveAudioIsSavedIntoTheSharedRecordingAndTheRecordersFileBecomesTheSameTrack() async throws {
        let device = SimulatedSoundcore(recordings: [])
        device.recordsInRealTime = true
        device.pace = .milliseconds(15)
        let rig = rig(device)
        try await connected(rig)
        let conversation = UUID()

        rig.connection.startRecording()
        try await waitUntil("it records") { rig.connection.status?.isRecording == true && !rig.connection.recordCommandPending }
        XCTAssertTrue(rig.session.captureLive(into: conversation))
        XCTAssertEqual(rig.session.liveCaptureConversation, conversation)
        XCTAssertFalse(rig.session.captureLive(into: UUID()), "one shared recording at a time")
        try await Task.sleep(for: .milliseconds(600))

        // The person presses the button: the stream ends with the recording, every frame received.
        device.pressButton()
        try await waitUntil("the live audio is saved", timeout: 5) { rig.session.lastLiveSave != nil && rig.session.liveCaptureConversation == nil }
        let ended = await rig.session.endLiveCapture()
        let saved = try XCTUnwrap(ended)
        XCTAssertEqual(saved.meetingID, conversation, "into the shared recording's conversation")
        XCTAssertGreaterThan(saved.seconds, 0.5)
        let live = try XCTUnwrap(rig.library.imports.first)
        XCTAssertEqual(live.identity.recordingID, DeviceLibraryLinks.partialID(String(device.recordings[0].id)))
        XCTAssertEqual(live.attachTo, conversation)

        // Its own file, imported into the same conversation once listed: the same bytes, so the same
        // track, now named for the whole recording.
        let recordingID = String(device.recordings[0].id)
        rig.session.importWhenFinished(recordingID, into: conversation)
        try await waitUntil("the recorder's file is in", timeout: 5) { rig.library.imports.count == 2 && !rig.session.queue.isActive }
        try await waitUntil("its link") { rig.session.links.imported[recordingID] == conversation }
        let meeting = try XCTUnwrap(rig.library.meetings[conversation])
        XCTAssertEqual(meeting.tracks.count, 1, "no duplicate track")
        XCTAssertEqual(meeting.tracks[0].deviceRecordingID, recordingID)
        XCTAssertEqual(meeting.transcribableTracks.map(\.id), [meeting.tracks[0].id])
    }

    func testARecordersFileThatDiffersFromItsLiveAudioReplacesIt() async throws {
        let device = SimulatedSoundcore(recordings: [])
        device.recordsInRealTime = true
        device.pace = .milliseconds(15)
        let rig = rig(device)
        try await connected(rig)
        let conversation = UUID()
        rig.connection.startRecording()
        try await waitUntil("it records") { rig.connection.status?.isRecording == true && !rig.connection.recordCommandPending }
        rig.session.captureLive(into: conversation)
        try await Task.sleep(for: .milliseconds(400))

        // A device stopping it ends the live audio first (its list can't be read while it streams), so
        // the recorder records a little more than the live audio has.
        await rig.session.endLiveCapture()
        rig.connection.pauseRecording()
        try await waitUntil("it stops") { rig.connection.status?.isRecording == false && !rig.connection.recordCommandPending }
        let recordingID = String(try XCTUnwrap(device.recordings.first).id)
        rig.session.importWhenFinished(recordingID, into: conversation)
        try await waitUntil("the recorder's file is in", timeout: 5) { rig.library.imports.count == 2 && !rig.session.queue.isActive }

        let meeting = try XCTUnwrap(rig.library.meetings[conversation])
        XCTAssertEqual(meeting.tracks.count, 2, "the live audio stays (provenance, playback)")
        let whole = try XCTUnwrap(meeting.tracks.first { $0.deviceRecordingID == recordingID })
        let portion = try XCTUnwrap(meeting.tracks.first { $0.isLivePortion })
        XCTAssertEqual(meeting.supersededLivePortions, [portion.id: whole.id], "the recorder's file is authoritative")
        XCTAssertEqual(meeting.transcribableTracks.map(\.id), [whole.id], "only it is transcribed")
    }

    func testLiveAudioThatGoesQuietKeepsWhatArrived() async throws {
        let device = SimulatedSoundcore(recordings: [])
        let rig = rig(device)
        try await connected(rig)
        rig.connection.startRecording()
        try await waitUntil("it records") { rig.connection.status?.isRecording == true && !rig.connection.recordCommandPending }
        device.fault = .stall(afterSlices: 60)
        let conversation = UUID()
        rig.session.captureLive(into: conversation)
        try await waitUntil("what arrived is kept after the stream goes quiet", timeout: 5) { rig.session.lastLiveSave != nil }
        XCTAssertEqual(rig.session.lastLiveSave?.meetingID, conversation)
        XCTAssertEqual(rig.session.lastLiveSave?.seconds ?? 0, 1.2, accuracy: 0.05, "60 slices of 20 ms")
    }

    // MARK: What it costs

    /// Live audio at the recorder's own pace (20 ms Opus frames, three to a notification): what the link
    /// carries a second, how far behind the recording it runs, and how soon the audio is in the library
    /// after the recording stops, against what importing the file afterwards would take. The numbers go
    /// to docs/direct-soundcore.md, "Live audio for a shared recording".
    func testWhatLiveAudioCostsTheLinkAndHowSoonItsThere() async throws {
        let device = SimulatedSoundcore(recordings: [])
        device.recordsInRealTime = true
        device.pace = .milliseconds(60)
        device.slicesPerPacket = 3
        let rig = rig(device)
        try await connected(rig)
        rig.connection.startRecording()
        try await waitUntil("it records") { rig.connection.status?.isRecording == true && !rig.connection.recordCommandPending }
        let conversation = UUID()
        let before = (bytes: device.bytesSent, notifications: device.notificationsSent)
        let started = ContinuousClock.now
        rig.session.captureLive(into: conversation)
        try await Task.sleep(for: .seconds(3))
        let recorded = Double(device.activeRecording?.frames.count ?? 0) * 0.02
        let received = rig.connection.live.receivedSeconds
        let elapsed = Double((ContinuousClock.now - started).components.attoseconds) / 1e18 + Double((ContinuousClock.now - started).components.seconds)
        let bytes = Double(device.bytesSent - before.bytes), notifications = Double(device.notificationsSent - before.notifications)
        device.pressButton()
        let stopped = ContinuousClock.now
        try await waitUntil("saved", timeout: 5) { rig.session.lastLiveSave != nil }
        let ready = ContinuousClock.now - stopped
        let audioSeconds = try XCTUnwrap(rig.session.lastLiveSave?.seconds)

        let perSecond = bytes / elapsed
        print(String(format: "Live audio: %.0f B/s on the link (%.1f kbit/s), %.1f notifications/s; %.2f s recorded, %.2f s received after %.2f s; in the library %.0f ms after the stop; %.2f s saved",
                     perSecond, perSecond * 8 / 1000, notifications / elapsed, recorded, received, elapsed,
                     Double(ready.components.attoseconds) / 1e15 + Double(ready.components.seconds) * 1000, audioSeconds))
        // 166 bytes a slice (160 of Opus), 10 of framing a notification of three: 508 bytes every 60 ms.
        XCTAssertEqual(perSecond, 8_467, accuracy: 1_500, "about 68 kbit/s")
        // Progress is published once a second, so what it shows trails by up to a second.
        XCTAssertGreaterThan(received, recorded - 1.2, "it keeps up with the recording")
        XCTAssertLessThan(ready, .seconds(2), "in the library within moments of the stop")
        XCTAssertEqual(audioSeconds, Double(device.recordings[0].frames.count) * 0.02, accuracy: 0.05, "all of it")
    }
}
