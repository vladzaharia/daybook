import DaybookKit
import XCTest
@testable import DaybookPhone

/// The recorder's Live Activity (Soundcore Work): only Listen Live or a recording this iPhone
/// started gets one; it's live while connected, "as of 10:07" after the iPhone lets the recorder go,
/// and goes stale when nobody can vouch for it. Against DaybookDevices' simulated recorder, never
/// Bluetooth; it checks what the activity would show, not ActivityKit.
@MainActor
final class RecorderActivityTests: XCTestCase {
    private typealias Content = RecorderActivityAttributes.ContentState
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testOnlyListeningOrARecordingThisIPhoneStartedGetsAnActivity() throws {
        let start = now.addingTimeInterval(-600)
        XCTAssertNil(Content.make(isListening: false, isRecording: true, startedHere: false, startedAt: start, isLive: true, asOf: now),
                     "started on the recorder's own button: not this iPhone's to show")
        XCTAssertNil(Content.make(isListening: false, isRecording: false, startedHere: true, startedAt: start, isLive: true, asOf: now))

        let live = try XCTUnwrap(Content.make(isListening: false, isRecording: true, startedHere: true, startedAt: start, isLive: true, asOf: now))
        XCTAssertEqual(live.phase, .recording)
        XCTAssertNil(live.asOf)
        XCTAssertEqual(live.title(isStale: false), "Recording")
        XCTAssertEqual(live.staleDate(from: now), now.addingTimeInterval(1_200))

        let earlier = now.addingTimeInterval(-300)
        let remembered = try XCTUnwrap(Content.make(isListening: false, isRecording: true, startedHere: true, startedAt: start,
                                                    isLive: false, asOf: earlier))
        XCTAssertEqual(remembered.asOf, earlier)
        XCTAssertEqual(remembered.title(isStale: false), "Recording · as of \(earlier.formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(remembered.staleDate(from: now), earlier.addingTimeInterval(1_200), "stale when the device page stops saying so")
        XCTAssertEqual(remembered.title(isStale: true), "Not confirmed")

        let listening = try XCTUnwrap(Content.make(isListening: true, isRecording: true, startedHere: false, startedAt: start, isLive: true, asOf: now))
        XCTAssertEqual(listening.phase, .listening)
        XCTAssertEqual(listening.title(isStale: false), "Listening live")
        XCTAssertEqual(listening.staleDate(from: now), now.addingTimeInterval(90))
        XCTAssertEqual(Content(phase: .ended).title(isStale: true), "Stopped")
        XCTAssertNil(Content(phase: .ended).staleDate(from: now))
    }

    func testTheActivityFollowsTheRecorder() async throws {
        let defaults = makeTestDefaults("RecorderActivityTests")
        let staging = try temporaryDirectory()
        let base = UInt32(Date().timeIntervalSince1970) - 50_000
        let device = SimulatedSoundcore(recordings: [.init(id: base, frames: SimulatedSoundcore.frames(seconds: 1))])
        device.pace = .milliseconds(10)
        let transport = SimulatedSoundcoreTransport(device: device)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        environment.liveCaptions.makeCaptioner = { nil }
        environment.soundcoreTiming.recordConfirm = .milliseconds(1_500)
        environment.soundcoreTiming.request = .seconds(3)
        let configured = ConfiguredDevice(id: "sim", kind: SoundcoreWorkIntegration().kind)
        let connection = SoundcoreConnection(device: configured, environment: environment)
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        addTeardownBlock { connection.shutDown() }
        session.activate()
        connection.search()
        try await waitUntil("a recorder to be found") { !connection.discovered.isEmpty }
        connection.connect(to: connection.discovered[0])
        try await waitUntil("the listing") { connection.isInventoryCurrent }
        XCTAssertNil(RecorderActivityController.target([session]))

        // Started on the recorder's button: not this iPhone's.
        device.pressButton()
        try await waitUntil("recording from its button") { connection.recordingState?.isRecording == true && !connection.isRefreshing }
        XCTAssertNil(RecorderActivityController.target([session]))
        device.pressButton()
        try await waitUntil("stopped from its button") { connection.recordingState?.isRecording == false && !connection.isRefreshing }

        // Started here: live while connected.
        connection.startRecording()
        try await waitUntil("recording from here") { !connection.recordCommandPending && connection.recordingState?.isRecording == true }
        let id = try XCTUnwrap(device.activeRecording?.id)
        let live = try XCTUnwrap(RecorderActivityController.target([session]))
        XCTAssertEqual(live.recordingID, String(id))
        XCTAssertEqual(live.recorderName, "Soundcore Work")
        XCTAssertEqual(live.content.phase, .recording)
        XCTAssertNil(live.content.asOf)
        XCTAssertEqual(live.content.startedAt, SoundcoreRecording(id: id, size: 0).date)

        // Listen Live takes the activity over.
        connection.startListening()
        try await waitUntil("listening") { connection.live.isListening }
        XCTAssertEqual(RecorderActivityController.target([session])?.content.phase, .listening)
        connection.stopListening()
        try await waitUntil("listening to end") { !connection.live.isListening }

        // Let go: it's shown as of its time, until that's too old to vouch for.
        connection.disconnect()
        let remembered = try XCTUnwrap(RecorderActivityController.target([session]))
        XCTAssertEqual(remembered.content.phase, .recording)
        XCTAssertNotNil(remembered.content.asOf)
        XCTAssertNil(RecorderActivityController.target([session], now: Date().addingTimeInterval(1_300)))
    }
}
