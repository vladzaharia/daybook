import AVFoundation
import DaybookCore
@testable import DaybookKit
import DaybookLink
import DaybookTestSupport
import XCTest
@testable import Daybook

// The person's own pause on the Mac (docs/capture.md, "Pausing"): the sources keep running and both tracks keep their
// length, and what they capture until Resume is silence in the kept files and in what captions hear. Fake sources and a
// fake clock with a synthetic tone: nothing records the room.

/// What a caption handler was given: when, and how loud it was at its loudest.
final class CaptionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [(time: TimeInterval, peak: Float)] = []

    var entries: [(time: TimeInterval, peak: Float)] { lock.withLock { heard } }

    func handler() -> CaptureBufferHandler {
        { @Sendable [self] buffer, time in
            let peak = CapturePauseTests.peak(buffer, frames: 0..<Int(buffer.frameLength))
            lock.withLock { heard.append((time, peak)) }
        }
    }
}

@MainActor
final class CapturePauseTests: XCTestCase {
    private func directory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookPause-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func recorder(_ clock: FakeHostClock, microphone: FakeCaptureSource, system: FakeSystemAudio = FakeSystemAudio()) -> RecordingController {
        RecordingController(environment: CaptureEnvironment(
            microphoneAuthorization: { true }, makeMicrophone: { microphone }, systemAudio: system,
            currentRoute: { AudioOutputRoute(kind: .speakers, deviceName: "Speakers", transport: nil) },
            observeRoutes: { _ in nil }, hostTime: { clock.now }))
    }

    /// `seconds` of a 440 Hz tone from each source in 0.1 s buffers, the clock following; the microphone mono, the call stereo.
    private func feed(_ sources: [FakeCaptureSource], from start: TimeInterval, seconds: Double, clock: FakeHostClock) {
        for index in 0..<Int((seconds / 0.1).rounded()) {
            let time = start + Double(index) * 0.1
            clock.now = time
            for source in sources {
                source.emit(CallSignals.tone(channels: source.method == "microphone" ? 1 : 2, level: 0.2, frames: 4_800), at: time)
            }
        }
        clock.now = start + seconds
    }

    nonisolated static func peak(_ buffer: AVAudioPCMBuffer, frames: Range<Int>) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in frames where frame >= 0 && frame < Int(buffer.frameLength) { peak = max(peak, abs(data[channel][frame])) }
        }
        return peak
    }

    /// The loudest sample of a file between two times.
    private func peak(_ url: URL, from start: TimeInterval, to end: TimeInterval) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let rate = file.processingFormat.sampleRate
        return Self.peak(buffer, frames: Int(start * rate)..<Int(end * rate))
    }

    // MARK: What's kept

    /// A tone through a three-second pause: both tracks keep all seven seconds on the timeline, silent from the moment
    /// of Pause (after a 5 ms ramp) until Resume, and the tone either side; each says it was paused, and the result keeps
    /// the pause.
    func testBehaviorWhatIsCapturedWhilePausedIsSilentInBothTracksWhichKeepTheirLength() async throws {
        let clock = FakeHostClock(), system = FakeSystemAudio(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic, system: system)
        try await recorder.start(in: directory(), includeSystemAudio: true, callApp: nil)
        let screen = system.screens[0]
        feed([mic, screen], from: 100, seconds: 2, clock: clock)
        XCTAssertTrue(recorder.pause())
        XCTAssertEqual(try XCTUnwrap(recorder.pausedAt), 2, accuracy: 1e-6)
        XCTAssertTrue(recorder.isRecording, "a pause doesn't end the recording")
        feed([mic, screen], from: 102, seconds: 3, clock: clock)
        XCTAssertTrue(recorder.resume())
        feed([mic, screen], from: 105, seconds: 2, clock: clock)

        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertEqual(result.pauses, [CapturePause(start: 2, end: 5)])
        XCTAssertEqual(result.tracks.count, 2)
        for track in result.tracks {
            XCTAssertEqual(track.duration, 7, accuracy: 0.01, "\(track.role) keeps its place on the timeline")
            XCTAssertEqual(track.offsetSeconds, 0, accuracy: 1e-6)
            XCTAssertNil(track.gaps, "nothing was padded or skipped: the source kept delivering")
            XCTAssertGreaterThan(try peak(track.url, from: 0.5, to: 1.99), 0.15, "\(track.role) before the pause")
            XCTAssertEqual(try peak(track.url, from: 2.006, to: 5), 0, "\(track.role) keeps nothing of the pause")
            XCTAssertLessThanOrEqual(try peak(track.url, from: 5, to: 5.005), 0.2, "it fades in")
            XCTAssertGreaterThan(try peak(track.url, from: 5.1, to: 6.9), 0.15, "\(track.role) after Resume")
            XCTAssertTrue(track.notes?.contains("Paused 0:02–0:05; the gap is silent.") == true, "\(track.notes ?? [])")
        }
        let saved = try CaptureJSON.decoder().decode(CaptureResult.self, from: Data(contentsOf: result.directory.appendingPathComponent("capture-result.json")))
        XCTAssertEqual(saved.pauses, result.pauses)
    }

    /// Captions keep being given audio through a pause, so their timeline holds, but only silence: never the tone.
    func testBehaviorCaptionsAreGivenSilenceWhilePaused() async throws {
        let clock = FakeHostClock(), system = FakeSystemAudio(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic, system: system)
        let you = CaptionLog(), call = CaptionLog()
        recorder.captionTap = CaptureCaptionTap(microphone: you.handler(), call: call.handler())
        try await recorder.start(in: directory(), includeSystemAudio: true, callApp: nil)
        let screen = system.screens[0]
        feed([mic, screen], from: 100, seconds: 1, clock: clock)
        // Pause partway through a buffer's time: what it holds from the pause on is silence, before it isn't.
        clock.now = 101.05
        recorder.pause()
        feed([mic, screen], from: 101, seconds: 2, clock: clock)
        recorder.resume()
        feed([mic, screen], from: 103, seconds: 1, clock: clock)
        _ = await recorder.stop()

        for log in [you, call] {
            let entries = log.entries
            XCTAssertEqual(entries.count, 40, "every buffer reaches captions, on the session's timeline")
            XCTAssertTrue(entries.filter { $0.time < 1 || $0.time >= 3 }.allSatisfy { $0.peak > 0.15 })
            XCTAssertTrue(entries.filter { $0.time >= 1.1 && $0.time < 3 }.allSatisfy { $0.peak == 0 }, "nothing of the pause")
            XCTAssertGreaterThan(try XCTUnwrap(entries.first { abs($0.time - 1) < 1e-6 }).peak, 0.15, "its start came before Pause")
        }
    }

    // MARK: Order

    /// Pause and Resume each work once in turn; neither does anything before the recording or after it. Stop while
    /// paused ends the pause where the recording ends, and the next recording starts unpaused.
    func testBehaviorPauseResumeAndStopInEveryOrder() async throws {
        let clock = FakeHostClock(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic)
        XCTAssertFalse(recorder.pause(), "nothing to pause")
        XCTAssertFalse(recorder.resume())
        try await recorder.start(in: directory(), includeSystemAudio: false)
        XCTAssertFalse(recorder.resume(), "not paused")
        feed([mic], from: 100, seconds: 1, clock: clock)
        XCTAssertTrue(recorder.pause())
        XCTAssertFalse(recorder.pause(), "paused already")
        feed([mic], from: 101, seconds: 1, clock: clock)
        XCTAssertTrue(recorder.resume())
        XCTAssertFalse(recorder.resume())
        feed([mic], from: 102, seconds: 1, clock: clock)
        XCTAssertTrue(recorder.pause())
        feed([mic], from: 103, seconds: 1, clock: clock)

        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertEqual(result.pauses, [CapturePause(start: 1, end: 2), CapturePause(start: 3, end: 4)])
        XCTAssertFalse(recorder.isPaused)
        XCTAssertNil(recorder.pausedAt)
        let track = try XCTUnwrap(result.tracks.first)
        XCTAssertEqual(track.duration, 4, accuracy: 0.01)
        XCTAssertEqual(try peak(track.url, from: 3.006, to: 4), 0, "paused to the end")
        XCTAssertFalse(recorder.pause(), "stopped")

        try await recorder.start(in: directory(), includeSystemAudio: false)
        XCTAssertFalse(recorder.isPaused, "the next recording starts afresh")
        feed([mic], from: 200, seconds: 1, clock: clock)
        let next = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertNil(next.pauses)
        XCTAssertFalse(next.tracks.first?.notes?.contains { $0.hasPrefix("Paused") } == true)
    }

    /// While paused the meters rest and nothing is said about hearing, however long it lasts; the sources, which keep
    /// delivering, are never restarted for it; after Resume the hearing check counts from Resume.
    func testBehaviorAPauseRestsTheMetersWithoutRestartingAnythingOrSayingTheMicrophoneIsSilent() async throws {
        let clock = FakeHostClock(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic)
        try await recorder.start(in: directory(), includeSystemAudio: false)
        feed([mic], from: 100, seconds: 2, clock: clock)
        recorder.updateLevels()
        XCTAssertGreaterThan(recorder.levels.microphone.meterValue, 0)
        recorder.pause()
        recorder.updateLevels()
        XCTAssertEqual(recorder.levels.microphone, .silent, "the meter rests at once")
        feed([mic], from: 102, seconds: 30, clock: clock)
        recorder.updateLevels()
        XCTAssertEqual(recorder.levels.microphone, .silent)
        XCTAssertFalse(recorder.levels.isMicrophoneSilent, "a pause isn't a microphone that stopped hearing")
        XCTAssertTrue(mic.restarts.isEmpty, "a source that delivers through a pause is never restarted")
        recorder.resume()
        clock.now = 132.05
        recorder.updateLevels()
        XCTAssertFalse(recorder.levels.isMicrophoneSilent, "the hearing check counts from Resume")
        feed([mic], from: 132.1, seconds: 1, clock: clock)
        recorder.updateLevels()
        XCTAssertGreaterThan(recorder.levels.microphone.meterValue, 0)
        _ = await recorder.stop()
    }

    // MARK: A crash while paused

    /// Daybook dies while paused: the files as they are on disk come back with the pause, ended where the audio ends,
    /// and nothing of it was ever written.
    func testBehaviorACrashWhilePausedRecoversWithThePauseAndNothingOfIt() async throws {
        let clock = FakeHostClock(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic)
        let live = directory(), crashed = directory()
        try await recorder.start(in: live, includeSystemAudio: false)
        feed([mic], from: 100, seconds: 2, clock: clock)
        recorder.pause()
        feed([mic], from: 102, seconds: 3, clock: clock)
        let audio = live.appendingPathComponent("microphone.caf")
        // Mono Float32 at 48 kHz: five seconds is 960,000 bytes of audio.
        try await waitUntil("five seconds on disk, and the track's timing beside them") {
            ((try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int) ?? 0) >= 960_000
                && FileManager.default.fileExists(atPath: live.appendingPathComponent("microphone.json").path)
        }
        // The process dies here: the files as they are, the writer never finished.
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        for name in ["capture-session.json", "microphone.caf", "microphone.json"] {
            try FileManager.default.copyItem(at: live.appendingPathComponent(name), to: crashed.appendingPathComponent(name))
        }
        _ = await recorder.stop()

        let recovered = try XCTUnwrap(CaptureRecovery.recover(in: crashed))
        let track = try XCTUnwrap(recovered.tracks.first)
        XCTAssertEqual(track.duration, 5, accuracy: 0.01)
        let pause = try XCTUnwrap(recovered.pauses?.first)
        XCTAssertEqual(pause.start, 2, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(pause.end), 5, accuracy: 0.01, "an open pause ends where the audio does")
        XCTAssertGreaterThan(try peak(track.url, from: 0.5, to: 1.99), 0.15)
        XCTAssertEqual(try peak(track.url, from: 2.006, to: 5), 0, "nothing of the pause reached the disk")
        XCTAssertTrue(track.notes?.contains("Paused 0:02–0:05; the gap is silent.") == true, "\(track.notes ?? [])")
    }

    // MARK: The pieces

    func testBehaviorPausedFramesFollowTheHostTimeEachFrameWasCapturedAt() {
        let pauses = CapturePauses(origin: 100)
        pauses.begin(at: 101.5)
        XCTAssertTrue(pauses.isPaused)
        // A buffer from 101.4, 0.2 s at 10 Hz (frames 0...1 are before the pause).
        XCTAssertEqual(pauses.pausedFrames(from: 101.4, frames: 2, rate: 10), [1..<2])
        XCTAssertEqual(pauses.pausedFrames(from: 101.0, frames: 4, rate: 10), [], "captured before Pause")
        pauses.end(at: 102)
        XCTAssertFalse(pauses.isPaused)
        XCTAssertEqual(pauses.pausedFrames(from: 101.0, frames: 20, rate: 10), [5..<10])
        XCTAssertEqual(pauses.pausedFrames(from: 102.0, frames: 10, rate: 10), [], "captured after Resume")
        XCTAssertTrue(pauses.overlaps(from: 101.9, seconds: 0.2))
        XCTAssertFalse(pauses.overlaps(from: 102, seconds: 0.2))
        XCTAssertFalse(pauses.end(at: 103), "none open")
        XCTAssertTrue(pauses.begin(at: 103))
        XCTAssertFalse(pauses.begin(at: 104), "one open already")
        XCTAssertEqual(pauses.record, [CapturePause(start: 1.5, end: 2), CapturePause(start: 3, end: nil)])
        XCTAssertEqual(CapturePause.closed(pauses.record, at: 6), [CapturePause(start: 1.5, end: 2), CapturePause(start: 3, end: 6)])
        XCTAssertEqual(CapturePause(start: 3, end: nil).note, "Paused from 0:03; the gap is silent.")
    }
}

// MARK: - The Mac's Pause in the app

/// Pause is offered only while nothing records along with this Mac (a recorder, an iPhone): none of them would pause
/// with it. Paused, phones are told so.
@MainActor
final class MacPauseTests: XCTestCase {
    private func rig(recorder: FakeRecorder? = nil, recordsAlong: Bool = true) async throws -> MultiSourceRig {
        try await rigAndSession(recorder: recorder, recordsAlong: recordsAlong).rig
    }

    private func rigAndSession(recorder: FakeRecorder? = nil, recordsAlong: Bool = true) async throws -> (rig: MultiSourceRig, session: DeviceSession?) {
        let rig = try await MultiSourceRig.make(in: self, models: false)
        addTeardownBlock { await rig.tearDown() }
        var made: DeviceSession?
        if let recorder {
            var device = ConfiguredDevice(id: "recorder", kind: SoundcoreWorkIntegration().kind)
            device.alsoRecordsWithMac = recordsAlong
            let session = DeviceSession(device: device, kind: SoundcoreWorkIntegration().kind, connections: [recorder], defaults: rig.defaults)
            session.importer = { url, identity, attachTo, source in
                try await rig.state.importFromDevice(url, identity: identity, attachTo: attachTo, source: source)
            }
            recorder.audio = try rig.audio("soundcore.wav", frequency: 523)
            session.libraryChanged(rig.state.meetings, ready: true)
            rig.state.sources.recorders.sessions = { [session] }
            addTeardownBlock { session.shutDown() }
            made = session
        }
        return (rig, made)
    }

    func testBehaviorARecordingAloneOffersPauseAndPhonesHearItIsPaused() async throws {
        let rig = try await rig()
        XCTAssertFalse(rig.state.canPauseRecording, "not recording")
        let id = try await rig.startRecording()
        await rig.state.sources.recorders.settle()
        XCTAssertTrue(rig.state.canPauseRecording)
        XCTAssertFalse(rig.state.canResumeRecording)
        XCTAssertEqual(rig.state.macRecordingState().phase, .recording)

        rig.state.togglePauseRecording()
        XCTAssertTrue(rig.state.isRecordingPaused)
        XCTAssertFalse(rig.state.canPauseRecording)
        XCTAssertTrue(rig.state.canResumeRecording)
        let meeting = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(StatusOverviewInputs.make(rig.state, meeting: meeting, afterStop: false, inputDevice: nil).recording.phase, .paused,
                       "Floating Notes says Paused")
        guard case .elapsed(let live, let frozen, _) = FloatingRecording.clock(start: Date(), pausedAt: rig.state.recordingPausedAt) else {
            return XCTFail("a paused clock is frozen")
        }
        XCTAssertFalse(live)
        XCTAssertEqual(frozen, rig.state.recordingPausedAt)
        let paused = rig.state.macRecordingState()
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.conversationID, id)
        XCTAssertEqual(paused.elapsed, try XCTUnwrap(rig.state.recordingPausedAt))

        rig.state.togglePauseRecording()
        XCTAssertFalse(rig.state.isRecordingPaused)
        XCTAssertEqual(rig.state.macRecordingState().phase, .recording)
        rig.state.pauseRecording()
        await rig.state.stopRecording()
        XCTAssertFalse(rig.state.isRecordingPaused, "Stop ends the pause with the recording")
        XCTAssertFalse(rig.state.canResumeRecording)
    }

    func testBehaviorARecorderRecordingAlongTakesPauseAway() async throws {
        let recorder = FakeRecorder()
        let rig = try await rig(recorder: recorder)
        _ = try await rig.startRecording()
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, ["connect", "start"])
        XCTAssertFalse(rig.state.canPauseRecording, "the recorder wouldn't pause with this Mac")
        rig.state.pauseRecording()
        XCTAssertFalse(rig.state.isRecordingPaused, "nothing to pause with it recording along")
        await rig.state.stopRecording()
        await rig.state.sources.recorders.settle()
    }

    /// A recorder whose own button joins during a pause (the person's own act there) takes Pause away, but the pause
    /// stays until the person resumes it.
    func testBehaviorARecorderJoiningDuringAPauseLeavesItPaused() async throws {
        let recorder = FakeRecorder()
        let (rig, session) = try await rigAndSession(recorder: recorder, recordsAlong: false)
        let id = try await rig.startRecording()
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, [], "not set to record along")
        XCTAssertTrue(rig.state.canPauseRecording)
        rig.state.pauseRecording()
        rig.state.sources.recorders.recorderJoined(try XCTUnwrap(session), meetingID: id)
        XCTAssertTrue(rig.state.sources.recorders.hasCompany(id))
        XCTAssertTrue(rig.state.isRecordingPaused, "joining never resumes it")
        XCTAssertTrue(rig.state.canResumeRecording)
        rig.state.resumeRecording()
        XCTAssertFalse(rig.state.canPauseRecording, "it wouldn't pause with this Mac")
        await rig.state.stopRecording()
        await rig.state.sources.recorders.settle()
    }

    func testBehaviorAPauseWhileARecorderIsBeingAskedIsNotOffered() async throws {
        let recorder = FakeRecorder()
        recorder.listingDelay = .milliseconds(300)
        let rig = try await rig(recorder: recorder)
        _ = try await rig.startRecording()
        XCTAssertFalse(rig.state.canPauseRecording, "a recorder being asked may record")
        await rig.state.sources.recorders.settle()
        XCTAssertFalse(rig.state.canPauseRecording)
        await rig.state.stopRecording()
        await rig.state.sources.recorders.settle()
    }

    func testBehaviorARecorderThatCouldntRecordLeavesPauseOffered() async throws {
        let recorder = FakeRecorder()
        recorder.reachable = false
        let rig = try await rig(recorder: recorder)
        let id = try await rig.startRecording()
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .unavailable)
        XCTAssertTrue(rig.state.canPauseRecording, "it isn't recording along")
        await rig.state.stopRecording()
        await rig.state.sources.recorders.settle()
    }
}
