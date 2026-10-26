import DaybookCore
import DaybookDevices
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// A recorder's recording is in the library once, however many devices import it: the Mac's
/// importer checks the library's device identity right before it ingests, because another device's
/// import can arrive through sync while this one transfers. Temporary library, synthetic audio.
@MainActor
final class DeviceImportIdentityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    func testARecordingTheLibraryAlreadyHoldsIsNotImportedAgain() async throws {
        let rig = try await MultiSourceRig.make(in: self, models: false)
        addTeardownBlock { await rig.tearDown() }
        let identity = MultiSourceRig.soundcore(start)
        let first = try await rig.state.importFromDevice(try rig.audio("phone-decoded.wav", frequency: 523), identity: identity,
                                                         attachTo: nil, source: .soundcore)
        // The same recording, decoded on this Mac (other bytes), even asked to join another conversation.
        let other = rig.state.newMeeting(title: "Design review", date: start)
        let again = try await rig.state.importFromDevice(try rig.audio("mac-decoded.wav", frequency: 524), identity: identity,
                                                         attachTo: other, source: .soundcore)
        XCTAssertEqual(again, first, "the conversation that already holds it")
        let holding = rig.state.meetings.filter { $0.tracks.contains { $0.deviceRecordingID == identity.recordingID } }
        XCTAssertEqual(holding.map(\.id), [first])
        XCTAssertEqual(rig.meeting(first)?.tracks.count, 1)
        XCTAssertEqual(rig.meeting(other)?.tracks.count, 0)

        // A recorder with another serial is another recording; a Listen Live portion is its own audio.
        var elsewhere = identity
        elsewhere.serial = "OTHER"
        XCTAssertNil(DeviceLibraryLinks.meeting(holding: elsewhere, in: rig.state.meetings))
        var portion = identity
        portion.recordingID = DeviceLibraryLinks.partialID(identity.recordingID)
        XCTAssertNil(DeviceLibraryLinks.meeting(holding: portion, in: rig.state.meetings))
        var unnamed = identity
        unnamed.serial = nil
        XCTAssertEqual(DeviceLibraryLinks.meeting(holding: unnamed, in: rig.state.meetings), first)
    }

    /// A recorder whose clock runs five minutes fast: Daybook measures it when it starts a recording
    /// there, dates that recording by this Mac's clock, and keeps the measured offset (and that it was
    /// applied) in the imported track's capture details.
    func testARecordingFromASkewedRecorderKeepsItsMeasuredClock() async throws {
        let rig = try await MultiSourceRig.make(in: self, models: false)
        addTeardownBlock { await rig.tearDown() }
        let recorder = SimulatedSoundcore(recordings: [])
        recorder.serial = "D3200SKEWMAC0001"
        recorder.clockOffset = 300
        let transport = SimulatedSoundcoreTransport(device: recorder)
        var environment = DeviceEnvironment(defaults: rig.defaults, stagingDirectory: rig.root.appendingPathComponent("DeviceImports"))
        environment.soundcoreTransport = { transport }
        environment.soundcoreTiming = SoundcoreTiming(request: .seconds(3), stall: .seconds(2), settle: .milliseconds(20),
                                                      recordConfirm: .milliseconds(1_500), backoff: [.milliseconds(40)])
        var device = ConfiguredDevice(id: "skewed", kind: SoundcoreWorkIntegration().kind)
        device.importsAutomatically = false
        environment.storage(for: device, method: .direct).encode(SoundcoreSnapshot(deviceID: transport.peripheralID, name: recorder.name,
                                                                                   serial: recorder.serial), "recorder")
        let connection = SoundcoreConnection(device: device, environment: environment)
        let session = DeviceSession(device: device, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: rig.defaults)
        addTeardownBlock { session.shutDown() }
        session.importer = { url, identity, attachTo, source in
            try await rig.state.importFromDevice(url, identity: identity, attachTo: attachTo, source: source)
        }
        session.activate()
        session.libraryChanged(rig.state.meetings, ready: true)

        connection.connect()
        try await waitUntil("connected and listed") { connection.isInventoryCurrent }
        let sent = Date()
        connection.startRecording()
        try await waitUntil("recording") { !connection.recordCommandPending && connection.status?.isRecording == true }
        let measured = try XCTUnwrap(connection.clock)
        connection.pauseRecording()
        try await waitUntil("its recording, listed") { session.split.inProgress == nil && session.newRecordings.count == 1 }
        session.importRecordings(session.newRecordings)
        let id = try await waitFor("the import") {
            rig.state.meetings.first { $0.tracks.contains { $0.deviceSerial == recorder.serial } }?.id
        }
        await rig.state.flush()

        let meeting = try XCTUnwrap(rig.meeting(id))
        let track = try XCTUnwrap(meeting.tracks.first)
        let clock = try XCTUnwrap(track.capture?.recorderClock)
        XCTAssertEqual(clock.offset, 300, accuracy: SoundcoreClock.resolution)
        XCTAssertEqual(clock, CaptureRecorderClock(offset: measured.offset, applied: true, measuredAt: measured.measuredAt))
        XCTAssertNil(track.capture?.method, "this Mac didn't capture it: the clock is all it records")
        XCTAssertEqual(meeting.date.timeIntervalSince(sent), 0, accuracy: 3, "dated by this Mac's clock, not five minutes ahead")
    }
}
