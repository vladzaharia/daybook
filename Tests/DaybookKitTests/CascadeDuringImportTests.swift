import DaybookCaptions
import DaybookCore
@testable import DaybookDevices
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest

/// A shared recording started while the recorder imports (docs/devices.md, "Record commands come first"): the recorder
/// starts within the cascade's deadline, ahead of the import, or never. The Start doesn't wait behind an import of 12 to
/// 24 minutes and fire after Daybook said it didn't start. Against the simulated recorder with a paced transfer: no
/// Bluetooth.
@MainActor
final class CascadeDuringImportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var staging: URL!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: makeTestSuite("local.daybook.tests.cascade-import"))
        staging = makeTemporaryFolder("DaybookCascadeImport")
    }

    private struct Rig {
        let session: DeviceSession
        let connection: SoundcoreConnection
        let device: SimulatedSoundcore
        let cascade: RecorderCascade
        let imports: Imports
    }

    private final class Imports {
        var all: [(identity: DeviceRecordingIdentity, attachTo: UUID?)] = []
        var meetings: [Meeting] = []
    }

    /// A recorder holding a six-second recording, sent at three times real time (about two seconds), with a
    /// Start's exemption shortened so a transfer under way is stopped for it.
    private func rig(_ configure: (SimulatedSoundcore) -> Void = { _ in }) async throws -> Rig {
        let base = UInt32(Date().timeIntervalSince1970) - 50_000
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: SimulatedSoundcore.frames(seconds: 6))])
        device.pace = .milliseconds(20)
        configure(device)
        let transport = SimulatedSoundcoreTransport(device: device)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        let hooks = LiveCaptionHooks()
        hooks.makeCaptioner = { nil }
        environment.liveCaptions = hooks
        var timing = SoundcoreTiming()
        timing.request = .seconds(3)
        timing.stall = .milliseconds(800)
        timing.settle = .milliseconds(20)
        timing.recordConfirm = .milliseconds(1_500)
        timing.idleRelease = .seconds(600)
        timing.otherAppQuiet = .milliseconds(300)
        timing.otherAppYields = 3
        timing.preemptExemption = .milliseconds(100)
        environment.soundcoreTiming = timing
        let configured = ConfiguredDevice(id: "sim", kind: SoundcoreWorkIntegration().kind)
        var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: device.name, serial: device.serial)
        snapshot.lastConnectedAt = Date()
        environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
        let connection = SoundcoreConnection(device: configured, environment: environment)
        connection.importsAutomatically = false
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        let imports = Imports()
        session.importer = { [weak session] _, identity, attachTo, source in
            imports.all.append((identity, attachTo))
            let meeting = Meeting(id: attachTo ?? UUID(), title: "Imported",
                                  tracks: [RecordingTrack(source: source, relativePath: "x", fileName: "x", device: identity)])
            imports.meetings.append(meeting)
            session?.libraryChanged(imports.meetings, ready: true)
            return meeting.id
        }
        session.activate()
        session.libraryChanged([], ready: true)
        let cascade = RecorderCascade(sessions: { [session] })
        cascade.timing.connect = .seconds(3)
        cascade.timing.confirm = .seconds(3)
        cascade.timing.inventory = .seconds(2)
        cascade.timing.poll = .milliseconds(20)
        addTeardownBlock { session.shutDown() }
        connection.connect()
        try await waitUntil("connected and listed") { connection.isInventoryCurrent }
        return Rig(session: session, connection: connection, device: device, cascade: cascade, imports: imports)
    }

    private func starts(_ device: SimulatedSoundcore) -> Int {
        device.received.filter { $0.type == 0x18 && $0.command == 0x82 }.count
    }

    /// Started mid-import: the import stops, the recorder starts within the deadline, and the import starts again after
    /// it, finishing with nothing lost or counted against it.
    func testACascadeStartedMidImportStartsTheRecorderWithinItsDeadline() async throws {
        let rig = try await rig()
        rig.session.importRecordings(rig.session.newRecordings)
        try await waitUntil("audio arriving") { rig.session.receivedBytes >= 4_000 }

        let conversation = UUID()
        rig.cascade.begin(conversation, title: "Design review", date: Date())
        let asked = ContinuousClock.now
        await rig.cascade.startRecorders()
        XCTAssertLessThan(asked.duration(to: .now), rig.cascade.timing.confirm + .seconds(1))
        let member = try XCTUnwrap(rig.cascade.member("sim"))
        XCTAssertEqual(member.state, .recording, "started, ahead of the import")
        XCTAssertEqual(member.role, .started)
        XCTAssertTrue(rig.device.isRecording)
        XCTAssertEqual(starts(rig.device), 1)

        try await waitUntil("the import, again from its start", timeout: 15) {
            rig.imports.all.contains { !$0.identity.recordingID.hasSuffix("~live") } && rig.session.queue.current == nil
        }
        XCTAssertTrue(rig.session.failures.isEmpty)
        await rig.cascade.stop()
        XCTAssertFalse(rig.device.isRecording, "it stops with the shared recording")
    }

    /// The Start can't go out in time (the recorder is busy with another app's transfer, which nothing cuts off): the
    /// cascade says it didn't start, and it never does, not even once that transfer ends.
    func testACascadeThatCantReachTheRecorderInTimeNeverStartsItLater() async throws {
        let rig = try await rig()
        rig.cascade.timing.confirm = .milliseconds(300)
        rig.device.beginAnotherAppsTransfer(recordingID: 4_242, slices: 120)
        try await waitUntil("the other app's audio") { rig.connection.technicalDetails.contains { $0.label == "Another app" } }

        let conversation = UUID()
        rig.cascade.begin(conversation)
        await rig.cascade.startRecorders()
        XCTAssertEqual(rig.cascade.member("sim")?.state, .unavailable("\(rig.session.device.name) didn’t start recording."))
        try await waitUntil("the other app's transfer to finish") { rig.device.anotherAppsTransfersFinished == 1 }
        try await waitUntil("nothing pending") { !rig.connection.recordCommandPending }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(starts(rig.device), 0, "the Start was dropped: never sent")
        XCTAssertFalse(rig.device.isRecording)
    }

    /// A Start that the recorder confirms only after the cascade gave up is paused again: what the cascade said stays true.
    func testAStartConfirmedAfterTheCascadeGaveUpIsUndone() async throws {
        let rig = try await rig { $0.startsLate = .milliseconds(700) }
        rig.cascade.timing.confirm = .milliseconds(300)
        let conversation = UUID()
        rig.cascade.begin(conversation)
        await rig.cascade.startRecorders()
        XCTAssertEqual(rig.cascade.member("sim")?.state, .unavailable("\(rig.session.device.name) didn’t start recording."))
        try await waitUntil("the late start, undone") { !rig.connection.recordCommandPending }
        XCTAssertFalse(rig.device.isRecording)
        XCTAssertEqual(starts(rig.device), 2, "Start, then Pause")
    }
}
