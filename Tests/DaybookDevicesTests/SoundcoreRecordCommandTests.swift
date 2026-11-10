import AVFoundation
import DaybookCaptions
import DaybookCore
import DaybookIntelligence
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookDevices

/// Record commands that come first, and what a recorder's device keeps across a relaunch (docs/devices.md, "Record
/// commands come first"; docs/direct-soundcore.md), against the simulated recorder: a Start that stops an import under
/// way and starts it again after, one dropped when its caller gives up before it's sent, one undone when it confirms too
/// late; the battery's scale, automatic import by what the recorder held at setup, a recording started here, what waits
/// to import, background time around an import, ownership before the devices start, and a decoded length that differs
/// from its packets. No Bluetooth, no microphone, no downloads.
@MainActor
final class SoundcoreRecordCommandTests: XCTestCase {
    private var defaults: UserDefaults!
    private var staging: URL!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: makeTestSuite("local.daybook.tests.soundcore-commands"))
        staging = makeTemporaryFolder("DaybookCommands")
    }

    private static let second = SimulatedSoundcore.frames(seconds: 1)
    private static let six = SimulatedSoundcore.frames(seconds: 6)
    private let base = UInt32(Date().timeIntervalSince1970) - 50_000

    private func timing(_ configure: ((inout SoundcoreTiming) -> Void)?) -> SoundcoreTiming {
        var timing = SoundcoreTiming()
        timing.request = .seconds(3)
        timing.stall = .milliseconds(800)
        timing.settle = .milliseconds(20)
        timing.scan = .milliseconds(300)
        timing.connect = .milliseconds(600)
        timing.reconnect = .milliseconds(300)
        timing.recordConfirm = .milliseconds(1_500)
        timing.backoff = [.milliseconds(40), .milliseconds(80)]
        timing.idleRelease = .seconds(600)
        timing.automaticIdleRelease = .seconds(600)
        timing.automaticCooldown = .seconds(60)
        timing.otherAppQuiet = .milliseconds(300)
        timing.otherAppYields = 3
        configure?(&timing)
        return timing
    }

    private final class Library {
        var imports: [(identity: DeviceRecordingIdentity, attachTo: UUID?, seconds: Double)] = []
        var meetings: [Meeting] = []
        /// Imports already in when background time was taken, and when it was let go.
        var heldWith: [Int] = []
    }

    private struct Rig {
        let session: DeviceSession
        let connection: SoundcoreConnection
        let transport: SimulatedSoundcoreTransport
        let device: SimulatedSoundcore
        let library: Library
        let configured: ConfiguredDevice
        let environment: DeviceEnvironment
    }

    /// A recorder remembered from an earlier connection, not connected yet.
    private func rig(_ device: SimulatedSoundcore, automatic: Bool = false, since: Date = .distantFuture, library: Library = Library(),
                     transport existing: SimulatedSoundcoreTransport? = nil,
                     configure: ((inout SoundcoreTiming) -> Void)? = nil) -> Rig {
        let transport = existing ?? SimulatedSoundcoreTransport(device: device)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        let hooks = LiveCaptionHooks()
        hooks.makeCaptioner = { nil }
        environment.liveCaptions = hooks
        environment.soundcoreTiming = timing(configure)
        var configured = ConfiguredDevice(id: "sim", kind: SoundcoreWorkIntegration().kind)
        configured.importsAutomatically = automatic
        configured.automaticImportsSince = since
        let storage = environment.storage(for: configured, method: .direct)
        if storage.data("recorder") == nil {
            var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: device.name, serial: device.serial)
            snapshot.lastConnectedAt = Date().addingTimeInterval(-3_600)
            storage.encode(snapshot, "recorder")
        }
        let connection = SoundcoreConnection(device: configured, environment: environment)
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        session.importer = { [weak session] url, identity, attachTo, source in
            let duration = Double(try AudioSlabReader.samples(url: url, from: 0, to: 3_600).count) / 16_000
            guard duration > 0 else { throw DaybookError.invalidAudio(url.lastPathComponent) }
            library.imports.append((identity, attachTo, duration))
            let meeting = Meeting(id: attachTo ?? UUID(), title: "Imported",
                                  tracks: [RecordingTrack(source: source, relativePath: "Originals/x.wav", fileName: url.lastPathComponent,
                                                          device: identity)])
            library.meetings.append(meeting)
            session?.libraryChanged(library.meetings, ready: true)
            return meeting.id
        }
        session.activate()
        session.libraryChanged(library.meetings, ready: true)
        addTeardownBlock { session.shutDown() }
        return Rig(session: session, connection: connection, transport: transport, device: device, library: library,
                   configured: configured, environment: environment)
    }

    private func connected(_ rig: Rig) async throws {
        if !rig.connection.state.isConnected { rig.connection.connect() }
        try await waitUntil("the connection") { rig.connection.state == .connected }
        try await waitUntil("the recording list") { rig.connection.isInventoryCurrent }
    }

    private func commands(_ device: SimulatedSoundcore, _ type: UInt8, _ command: UInt8) -> Int {
        device.received.filter { $0.type == type && $0.command == command }.count
    }

    // MARK: Commands come first

    /// A Start while an import runs: the import stops (`1A 11`), the Start goes out and is confirmed well within its
    /// deadline, and the import starts again from its beginning right after, still first in the queue and not counted as
    /// an attempt. The recorder's clock is measured from when the Start went out, not from when it was asked for.
    func testAStartGoesAheadOfAnImportWhichStartsAgainAfterIt() async throws {
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: Self.six)])
        // Three 20 ms frames every 20 ms: six seconds of audio take about two.
        device.pace = .milliseconds(20)
        let rig = rig(device) { $0.preemptExemption = .milliseconds(100) }
        try await connected(rig)
        rig.session.importRecordings(rig.session.newRecordings)
        try await waitUntil("audio arriving") { rig.session.receivedBytes >= 4_000 }

        let asked = ContinuousClock.now
        let outcome = await rig.session.recordCommand(.start, deadline: .seconds(3))
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertLessThan(asked.duration(to: .now), .seconds(3), "within its deadline, not after the import")
        XCTAssertTrue(device.isRecording)
        let order = device.received.map { [$0.type, $0.command] }
        let stop = try XCTUnwrap(order.firstIndex(of: [0x1a, 0x11]), "the import was stopped")
        let start = try XCTUnwrap(order.firstIndex(of: [0x18, 0x82]))
        XCTAssertLessThan(stop, start, "stopped first, then Start")
        XCTAssertLessThan(abs(rig.connection.clock?.correction ?? 99), 2, "measured from when the Start went out")

        try await waitUntil("the import, again from its start", timeout: 15) { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertEqual(commands(device, 0x1a, 0x07), 2, "asked for again")
        XCTAssertEqual(rig.library.imports[0].seconds, 6, accuracy: 0.1, "all of it")
        XCTAssertTrue(rig.session.failures.isEmpty, "not a failure")
        XCTAssertNil(rig.session.transferProblem)
        XCTAssertEqual(rig.connection.technicalDetails.first { $0.label == "Transfers stopped for Start or Pause" }?.value, "1")
    }

    /// A transfer about to finish isn't stopped for a Start: the Start waits for it.
    func testATransferAboutToFinishIsLetFinishFirst() async throws {
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: Self.six)])
        device.pace = .milliseconds(20)
        let rig = rig(device) { $0.preemptExemption = .seconds(30) }
        try await connected(rig)
        rig.session.importRecordings(rig.session.newRecordings)
        try await waitUntil("audio arriving for over a second") { rig.session.receivedBytes >= 30_000 }
        let outcome = await rig.session.recordCommand(.start, deadline: .seconds(10))
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(commands(device, 0x1a, 0x11), 0, "the transfer wasn't stopped")
        XCTAssertEqual(commands(device, 0x1a, 0x07), 1)
        try await waitUntil("imported once") { rig.library.imports.count == 1 }
    }

    /// A Start still waiting for the link when its caller gives up (here behind another app's transfer, which nothing
    /// cuts off) is dropped: it never reaches the recorder, and nothing records later with nobody to stop it.
    func testAStartStillWaitingWhenItsCallerGivesUpIsNeverSent() async throws {
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: Self.second)])
        let rig = rig(device)
        try await connected(rig)
        device.beginAnotherAppsTransfer(recordingID: base + 1, slices: 90)
        try await waitUntil("the other app's audio") { rig.connection.technicalDetails.contains { $0.label == "Another app" } }
        let outcome = await rig.session.recordCommand(.start, deadline: .milliseconds(150))
        XCTAssertEqual(outcome, .notConfirmed)
        try await waitUntil("the other app's transfer to finish") { device.anotherAppsTransfersFinished == 1 }
        try await waitUntil("nothing pending") { !rig.connection.recordCommandPending }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(commands(device, 0x18, 0x82), 0, "dropped: never sent")
        XCTAssertFalse(device.isRecording)
        XCTAssertNil(rig.connection.problem, "its caller says so in its own words")
    }

    /// A Start sent and confirmed only after its caller gave up is paused again: the caller said it didn't start, and so
    /// it doesn't run on.
    func testAStartThatConfirmsAfterItsCallerGaveUpIsPausedAgain() async throws {
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: Self.second)])
        device.startsLate = .milliseconds(700)
        let rig = rig(device)
        try await connected(rig)
        let outcome = await rig.session.recordCommand(.start, deadline: .milliseconds(300))
        XCTAssertEqual(outcome, .notConfirmed)
        try await waitUntil("the late start, undone") { !rig.connection.recordCommandPending }
        XCTAssertFalse(device.isRecording, "nobody waits for it")
        XCTAssertEqual(commands(device, 0x18, 0x82), 2, "Start, then Pause")
        XCTAssertNil(rig.connection.problem)
        XCTAssertNotEqual(rig.connection.recordingState?.startedHere, true)
    }

    /// On the Mac nothing else shares the link: audio nobody asked for is counted, and nothing waits for it or says
    /// "Waiting for the Soundcore app".
    func testOnTheMacAudioNobodyAskedForIsOnlyCounted() async throws {
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: Self.second)])
        let rig = rig(device) { $0.otherAppYields = 0 }
        try await connected(rig)
        device.serveAnotherApp(recordingID: base + 1)
        try await waitUntil("counted") { rig.connection.technicalDetails.contains { $0.label == "Audio packets not requested here" } }
        rig.session.importRecordings(rig.session.newRecordings)
        XCTAssertFalse(rig.session.isWaitingForOtherApp)
        try await waitUntil("imported") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertNil(rig.session.otherAppWait)
        XCTAssertFalse(rig.connection.technicalDetails.contains { $0.label == "Another app" })
    }

    // MARK: The recorder's own facts

    /// A recorder that reports a battery byte above 9 reports percentages: from then on 5 is 5%, not the 60% the
    /// bucket reading gives, and that's remembered. One that never does keeps buckets.
    func testTheBatteryScaleIsSettledPerRecorder() async throws {
        let device = SimulatedSoundcore(recordings: [])
        device.recorderBattery = 50
        let rig = rig(device)
        try await connected(rig)
        XCTAssertEqual(rig.connection.status?.battery?.level, 50)
        device.pushBattery(recorder: 5, case: 4)
        try await waitUntil("the push") { rig.connection.status?.battery?.level == 5 }
        XCTAssertEqual(rig.connection.status?.caseBattery?.level, 4)
        let stored = rig.environment.storage(for: rig.configured, method: .direct).decode(SoundcoreSnapshot.self, "recorder")
        XCTAssertEqual(stored?.batteryInPercent, true, "kept for the next launch")

        XCTAssertEqual(SoundcoreDeviceInfo.battery(5), 60, "buckets until a recorder shows otherwise")
        XCTAssertEqual(SoundcoreDeviceInfo.battery(5, inPercent: true), 5)
        XCTAssertNil(SoundcoreDeviceInfo.battery(101, inPercent: true))
    }

    /// Automatic import takes what wasn't on the recorder when it was set up, whatever its clock says: one two hours
    /// behind dates its new recordings before setup, and they still come in. What was there at setup doesn't.
    func testAutomaticImportTakesWhatWasntOnTheRecorderAtSetupWhateverItsClock() async throws {
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: Self.second)])
        device.clockOffset = -7_200
        let rig = rig(device, automatic: true, since: Date())
        // Automatic import reaches for it on its own.
        try await waitUntil("connected and listed") { rig.connection.isInventoryCurrent }
        let storage = rig.environment.storage(for: rig.configured, method: .direct)
        try await waitUntil("what it held at setup, kept") { storage.decode(SoundcoreSnapshot.self, "recorder")?.setupListing == [self.base] }

        device.pressButton()
        let new = try XCTUnwrap(device.activeRecording).id
        device.pressButton()
        try await waitUntil("the new recording imports", timeout: 15) { rig.library.imports.count == 1 }
        XCTAssertEqual(rig.library.imports[0].identity.recordingID, String(new))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.library.imports.count, 1, "not the one there at setup")
    }

    /// The recording this device started is still its own after a relaunch (the iPhone's recorder Live Activity).
    func testARecordingStartedHereIsStillItsOwnAfterARelaunch() async throws {
        let device = SimulatedSoundcore(recordings: [])
        let rig = rig(device)
        try await connected(rig)
        let outcome = await rig.session.recordCommand(.start, deadline: .seconds(3))
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(rig.connection.recordingState?.startedHere, true)
        rig.connection.disconnect()

        let relaunched = SoundcoreConnection(device: rig.configured, environment: rig.environment)
        relaunched.activate()
        let state = try XCTUnwrap(relaunched.recordingState)
        XCTAssertTrue(state.startedHere, "its Live Activity carries on")
        XCTAssertFalse(state.isLive)
    }

    /// What waits to import is stored with the device: a handoff's imports, a shared recording's file, the person's own
    /// queue, and what's arriving through sync. After a relaunch each imports once the recorder lists it.
    func testWhatWaitsToImportSurvivesARelaunch() async throws {
        let ids = (0..<3).map { base - UInt32($0) * 3_600 }
        let device = SimulatedSoundcore(recordings: ids.map { .init(id: $0, frames: Self.second) })
        device.advertises = false
        let library = Library()
        let rig = rig(device, library: library)
        let handedOver = UUID(), shared = UUID()
        rig.session.adoptHandedOffImports([DeviceHandedOffImport(recordingID: String(ids[0]), attachTo: handedOver)], alreadyImported: ["12345"])
        rig.session.importWhenFinished(String(ids[1]), into: shared)
        rig.session.importRecordings([DeviceRecording(id: String(ids[2]), startedAt: nil, length: nil, byteCount: 8_000, fileName: nil, addedAt: nil)])
        let key = "device.sim.session.pending"
        try await waitUntil("stored") { self.defaults.data(forKey: key) != nil && rig.session.queue.isSuspended }
        rig.session.shutDown()

        // A relaunch: the same device, made again from what's stored.
        let relaunched = self.rig(device, library: library, transport: rig.transport)
        XCTAssertEqual(Set(relaunched.session.adoptedImports.map(\.recordingID)), Set(ids.map(String.init)))
        XCTAssertEqual(relaunched.session.conversationWaiting(for: String(ids[0])), handedOver)
        XCTAssertEqual(relaunched.session.conversationWaiting(for: String(ids[1])), shared)
        XCTAssertNotNil(relaunched.session.arrivingThroughSync["12345"])

        device.advertises = true
        try await connected(relaunched)
        try await waitUntil("each imports once listed", timeout: 15) { library.imports.count == 3 && !relaunched.session.queue.isActive }
        XCTAssertEqual(library.imports.first { $0.identity.recordingID == String(ids[0]) }?.attachTo, handedOver)
        XCTAssertEqual(library.imports.first { $0.identity.recordingID == String(ids[1]) }?.attachTo, shared)
        try await waitUntil("nothing left stored") { self.defaults.data(forKey: key).flatMap { String(data: $0, encoding: .utf8) }?.contains(String(ids[2])) != true }
    }

    /// An import holds background time from the moment its audio is here until it's in the library (on the iPhone,
    /// `UIApplication`'s background task): not while it transfers, and never left held.
    func testAnImportHoldsBackgroundTimeFromItsAudioUntilItsInTheLibrary() async throws {
        let library = Library()
        let previous = DeviceBackgroundTime.hold
        defer { DeviceBackgroundTime.hold = previous }
        var released: [Int] = []
        DeviceBackgroundTime.hold = { _ in
            library.heldWith.append(library.imports.count)
            return { released.append(library.imports.count) }
        }
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: Self.second)])
        let rig = rig(device, library: library)
        try await connected(rig)
        rig.session.importRecordings(rig.session.newRecordings)
        try await waitUntil("imported") { library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertEqual(library.heldWith, [0], "held once its audio was here, before it was in the library")
        XCTAssertEqual(released, [1], "let go once it was")
    }

    /// Who manages each recorder, as this device last knew it, applies before its devices start: a relaunch before the
    /// library has loaded (the iPhone, relaunched in the background for a recorder) never reaches for a recorder another
    /// device manages.
    func testTheOwnershipLastKnownAppliesBeforeTheDevicesStart() async throws {
        let device = SimulatedSoundcore(recordings: [])
        let transport = SimulatedSoundcoreTransport(device: device)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        environment.soundcoreTiming = timing(nil)
        var configured = ConfiguredDevice(id: "owned", kind: SoundcoreWorkIntegration().kind)
        configured.importsAutomatically = true
        var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: device.name, serial: device.serial)
        snapshot.lastConnectedAt = Date()
        environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
        let first = DeviceHub(environment: environment)
        first.add(configured)
        let phone = RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: device.serial, ownerID: "phone-1",
                                      ownerName: "Alex’s iPhone", ownerClass: .phone)
        first.recorderOwnersChanged([phone], thisDevice: "this-device")
        first.shutDown()

        let relaunched = DeviceHub(environment: environment)
        XCTAssertTrue(relaunched.applyLastKnownOwnership())
        relaunched.start()
        defer { relaunched.shutDown() }
        let session = try XCTUnwrap(relaunched.sessions.first)
        XCTAssertEqual(session.managedElsewhere?.ownerID, "phone-1")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.connectAttempts, 0, "never reached for")
        XCTAssertFalse(device.isOccupied)
    }

    // MARK: Live audio's place

    /// Where a live stream starts on this device's clock is when its audio arrived less its place in the stream: a
    /// stream that starts now counts from its first buffer (not the recording's start minutes before, LC-04), and one
    /// that begins with what was recorded before listening settles on that start once it has caught up. Arriving faster
    /// than real time, it's catching up: no meter level meanwhile.
    func testLiveAudioKnowsWhereItsStreamStartsAndWhenItsCatchingUp() {
        let now = Date()
        let live = LiveCapture()
        for second in 0...4 { live.streamed(to: Double(second) + 0.06, at: now.addingTimeInterval(Double(second))) }
        XCTAssertEqual(live.streamStartedAt?.timeIntervalSince(now) ?? 99, -0.06, accuracy: 0.001, "a stream that starts now")
        XCTAssertFalse(live.isCatchingUp)

        let behind = LiveCapture()
        // Three times real time: what was recorded before listening began.
        for step in 0...10 { behind.streamed(to: Double(step) * 0.6, at: now.addingTimeInterval(Double(step) * 0.2)) }
        behind.heard(rms: -10, at: now.addingTimeInterval(2))
        XCTAssertTrue(behind.isCatchingUp)
        XCTAssertNil(behind.level(at: now.addingTimeInterval(2)), "earlier audio never reads as live")
        // Then at the recording's own pace.
        for step in 1...20 { behind.streamed(to: 6 + Double(step) * 0.2, at: now.addingTimeInterval(2 + Double(step) * 0.2)) }
        XCTAssertFalse(behind.isCatchingUp)
        XCTAssertEqual(behind.streamStartedAt?.timeIntervalSince(now) ?? 99, -4, accuracy: 0.01, "the recording's own start")
        behind.clearLevel()
        XCTAssertNil(behind.streamStartedAt)
        XCTAssertFalse(behind.isCatchingUp)
    }

    // MARK: What decoded

    /// What a transfer decodes is checked against its packets (320 samples each): a clean transfer says nothing; one more
    /// than 0.5% off (time vanished in decoding without an error) is kept, since the recorder has the original, and
    /// Device Details says how much decoded of what its packets were worth.
    func testADecodedLengthThatDiffersFromItsPacketsIsSaid() async throws {
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: Self.second)])
        let rig = rig(device)
        try await connected(rig)
        rig.session.importRecordings(rig.session.newRecordings)
        try await waitUntil("imported") { rig.library.imports.count == 1 && !rig.session.queue.isActive }
        XCTAssertNil(rig.connection.technicalDetails.first { $0.label == "Last transfer’s length" }, "decoded in full: nothing to say")

        rig.connection.noteLength(of: SoundcoreSession.Download(url: staging, seconds: 540, bytes: 0, expectedSeconds: 600))
        XCTAssertEqual(rig.connection.technicalDetails.first { $0.label == "Last transfer’s length" }?.value, "9 min 0 sec decoded of 10 min 0 sec")
        XCTAssertTrue(SoundcoreSession.Download(url: staging, seconds: 9.9, bytes: 0, expectedSeconds: 10).lengthDiffers)
        XCTAssertFalse(SoundcoreSession.Download(url: staging, seconds: 9.96, bytes: 0, expectedSeconds: 10).lengthDiffers)
        XCTAssertFalse(SoundcoreSession.Download(url: staging, seconds: 0.97, bytes: 0, expectedSeconds: 1).lengthDiffers,
                       "the codec's own delay isn't a mismatch")
    }

    /// Decrypting, decoding, and writing happen off the main actor in arrival order; what decoded comes back on it. A
    /// lenient (live) writer turns an undecodable packet into 20 ms of silence; a strict one fails.
    func testTheAudioWriterDecodesOffTheMainActorInOrder() async throws {
        let key = SoundcoreFileKey(key: Data(repeating: 1, count: 32), nonce: Data(repeating: 2, count: 16), expectedBytes: 0)
        func slices(_ frames: [Data]) throws -> [SoundcoreAudioSlice] {
            try frames.enumerated().map { index, frame in
                let audio = try SoundcoreFileKey.crypt(frame, sequence: UInt32(index), key: key.key, nonce: key.nonce)
                return SoundcoreAudioSlice(sequence: UInt32(index), flags: 0, audio: audio)
            }
        }
        var delivered = 0
        var failures: [Error] = []
        let url = staging.appendingPathComponent("writer.wav")
        let writer = try SoundcoreAudioWriter(url: url, lenient: false, onPCM: { delivered += Int($0.frameLength) }) { failures.append($0) }
        for slice in try slices(Self.second) { writer.append(slice, key: key) }
        writer.appendSilence(packets: 5)
        let written = try await writer.finish()
        XCTAssertEqual(written.expectedSamples, Int64(Self.second.count + 5) * 320)
        XCTAssertGreaterThan(written.samples, 0)
        try await waitUntil("what decoded reaches the main actor") { delivered > 0 }
        XCTAssertTrue(failures.isEmpty)

        let lenient = try SoundcoreAudioWriter(url: staging.appendingPathComponent("lenient.wav"), lenient: true, onPCM: nil) { failures.append($0) }
        let bad = SoundcoreAudioSlice(sequence: 0, flags: 0, audio: Data(repeating: 0xff, count: 160))
        lenient.append(bad, key: SoundcoreFileKey(key: Data(), nonce: Data(), expectedBytes: 0))
        let kept = try await lenient.finish()
        XCTAssertEqual(kept.concealed, 1, "a packet that can't be read becomes silence")
        XCTAssertEqual(kept.samples, 320)
        XCTAssertTrue(failures.isEmpty)

        let strict = try SoundcoreAudioWriter(url: staging.appendingPathComponent("strict.wav"), lenient: false, onPCM: nil) { failures.append($0) }
        strict.append(bad, key: SoundcoreFileKey(key: Data(), nonce: Data(), expectedBytes: 0))
        do { _ = try await strict.finish(); XCTFail("a transfer fails on it") } catch {}
        try await waitUntil("its failure, on the main actor") { failures.count == 1 }
    }
}
