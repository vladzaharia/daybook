import AVFoundation
import DaybookCore
@testable import DaybookKit
@testable import DaybookLink
import DaybookTestSupport
import XCTest
@testable import Daybook

// The person's own pause on the Mac (docs/capture.md, "Pausing"): the sources keep running and both tracks keep their
// length, and what they capture until Resume is silence in the kept files and in what captions hear. Fake sources and a
// fake clock with a synthetic tone: nothing records the room.

/// What a caption handler was given: when, how loud it was at its loudest, and the buffer itself.
final class CaptionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [(time: TimeInterval, peak: Float, buffer: AVAudioPCMBuffer)] = []

    var entries: [(time: TimeInterval, peak: Float)] { lock.withLock { heard.map { ($0.time, $0.peak) } } }

    /// The buffer given for `time`.
    func buffer(at time: TimeInterval) -> AVAudioPCMBuffer? { lock.withLock { heard.first { abs($0.time - time) < 1e-6 }?.buffer } }

    func handler() -> CaptureBufferHandler {
        { @Sendable [self] buffer, time in
            let peak = CapturePauseTests.peak(buffer, frames: 0..<Int(buffer.frameLength))
            let copy = PCMTrackWriter.copy(buffer) ?? buffer
            lock.withLock { heard.append((time, peak, copy)) }
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
    private func feed(_ sources: [FakeCaptureSource], from start: TimeInterval, seconds: Double, clock: FakeHostClock, rate: Double = 48_000) {
        for index in 0..<Int((seconds / 0.1).rounded()) {
            let time = start + Double(index) * 0.1
            clock.now = time
            for source in sources {
                source.emit(CallSignals.tone(rate: rate, channels: source.method == "microphone" ? 1 : 2, level: 0.2, frames: Int(rate / 10)), at: time)
            }
        }
        clock.now = start + seconds
    }

    /// Where a pause's silence starts and ends for a Pause and a Resume at these session seconds.
    private static func silence(pause: TimeInterval, resume: TimeInterval) -> (start: TimeInterval, end: TimeInterval) {
        (pause - CapturePauses.lead, resume + CapturePauses.margin)
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
        let silence = Self.silence(pause: 2, resume: 5)
        let pause = try XCTUnwrap(result.pauses?.first)
        XCTAssertEqual(result.pauses?.count, 1)
        XCTAssertEqual(pause.start, silence.start, accuracy: 1e-6, "a little before Pause")
        XCTAssertEqual(try XCTUnwrap(pause.end), silence.end, accuracy: 1e-6, "past any input's latency after Resume")
        XCTAssertEqual(result.tracks.count, 2)
        for track in result.tracks {
            XCTAssertEqual(track.duration, 7, accuracy: 0.01, "\(track.role) keeps its place on the timeline")
            XCTAssertEqual(track.offsetSeconds, 0, accuracy: 1e-6)
            XCTAssertNil(track.gaps, "nothing was padded or skipped: the source kept delivering")
            XCTAssertGreaterThan(try peak(track.url, from: 0.5, to: silence.start - 0.01), 0.15, "\(track.role) before the pause")
            // The silence reaches back before Pause only for audio not yet written when it came; from Pause on, always.
            XCTAssertEqual(try peak(track.url, from: 2.006, to: silence.end), 0, "\(track.role) keeps nothing of the pause")
            XCTAssertLessThan(try peak(track.url, from: silence.end, to: silence.end + 0.001), 0.05, "it fades in from silence")
            XCTAssertGreaterThan(try peak(track.url, from: silence.end + 0.006, to: silence.end + 0.05), 0.15, "within 5 ms")
            XCTAssertGreaterThan(try peak(track.url, from: 5.3, to: 6.9), 0.15, "\(track.role) after Resume")
            XCTAssertTrue(track.notes?.contains(pause.note) == true, "\(track.notes ?? [])")
            let kept = try XCTUnwrap(CaptureFinalizer.details(for: track, in: result).pauses, "kept with the library's track")
            XCTAssertEqual(kept.count, 1)
            XCTAssertEqual(kept.first?.start ?? 0, silence.start, accuracy: 1e-6, "in its own seconds")
            XCTAssertEqual(kept.first?.end ?? 0, silence.end, accuracy: 1e-6)
        }
        let saved = try CaptureJSON.decoder().decode(CaptureResult.self, from: Data(contentsOf: result.directory.appendingPathComponent("capture-result.json")))
        XCTAssertEqual(saved.pauses, result.pauses)
    }

    /// Resume partway through a buffer: what it holds until the silence ends is silent, and the rest fades in; the
    /// silence runs on past Resume by more than an input's latency, so what was said just before it, which arrives
    /// stamped later, isn't kept.
    func testBehaviorResumePartwayThroughABufferKeepsOnlyWhatCameSafelyAfter() async throws {
        let clock = FakeHostClock(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic)
        try await recorder.start(in: directory(), includeSystemAudio: false)
        feed([mic], from: 100, seconds: 1, clock: clock)
        recorder.pause()
        feed([mic], from: 101, seconds: 1, clock: clock)
        // Resume at 102.03: the silence ends at 102.18, 3/4 into the buffer from 102.1.
        clock.now = 102.03
        recorder.resume()
        feed([mic], from: 102, seconds: 1, clock: clock)
        let stopped = try await XCTUnwrapAsync(await recorder.stop())
        let track = try XCTUnwrap(stopped.tracks.first)
        let end = 2.03 + CapturePauses.margin
        XCTAssertEqual(try peak(track.url, from: 1.0, to: 2.13), 0, "what was said just before Resume arrives stamped up to a latency after it")
        XCTAssertEqual(try peak(track.url, from: 1.0, to: end), 0, "the buffer Resume fell in is silent until the silence ends")
        XCTAssertLessThan(try peak(track.url, from: end, to: end + 0.001), 0.05)
        XCTAssertGreaterThan(try peak(track.url, from: end + 0.006, to: 2.3), 0.15, "and keeps the rest")
    }

    /// A buffer captured before Pause but delivered after it keeps what came before the silence; one captured after it
    /// keeps nothing, however soon it's delivered.
    func testBehaviorABufferDeliveredAfterPauseIsJudgedByWhenItWasCaptured() async throws {
        let clock = FakeHostClock(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic)
        try await recorder.start(in: directory(), includeSystemAudio: false)
        feed([mic], from: 100, seconds: 1.4, clock: clock)
        // Pause at 101.5; the buffer captured from 101.4 arrives only now.
        clock.now = 101.5
        recorder.pause()
        mic.emit(CallSignals.tone(channels: 1, level: 0.2, frames: 4_800), at: 101.4)
        feed([mic], from: 101.5, seconds: 0.5, clock: clock)
        recorder.resume()
        feed([mic], from: 102, seconds: 1, clock: clock)
        let stopped = try await XCTUnwrapAsync(await recorder.stop())
        let track = try XCTUnwrap(stopped.tracks.first)
        let start = 1.5 - CapturePauses.lead
        XCTAssertGreaterThan(try peak(track.url, from: 1.4, to: start - 0.006), 0.15, "captured before Pause: kept")
        XCTAssertEqual(try peak(track.url, from: start + 0.006, to: 2), 0, "captured after it: never")
    }

    /// The microphone changes (another device, another format) during a pause: the new format is converted as ever, and
    /// none of what it captured until Resume is kept.
    func testBehaviorAMicrophoneThatChangesDuringAPauseKeepsNothingOfIt() async throws {
        let clock = FakeHostClock(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic)
        try await recorder.start(in: directory(), includeSystemAudio: false)
        feed([mic], from: 100, seconds: 1, clock: clock)
        recorder.pause()
        feed([mic], from: 101, seconds: 0.5, clock: clock)
        // It restarts on a 44.1 kHz input a moment later.
        mic.send(.deviceChanged("The microphone changed to Headset (now 44100 Hz, 1 ch)."))
        feed([mic], from: 101.8, seconds: 1.2, clock: clock, rate: 44_100)
        recorder.resume()
        feed([mic], from: 103, seconds: 1, clock: clock, rate: 44_100)
        let stopped = try await XCTUnwrapAsync(await recorder.stop())
        let track = try XCTUnwrap(stopped.tracks.first)
        let silence = Self.silence(pause: 1, resume: 3)
        XCTAssertEqual(track.duration, 4, accuracy: 0.02, "the restart's gap is padded: the timeline holds")
        XCTAssertGreaterThan(try peak(track.url, from: 0.3, to: silence.start - 0.01), 0.15)
        // The resampler's filter rings a little ahead of Resume's fade-in, far below hearing; nothing of what either
        // input heard is there.
        XCTAssertLessThan(try peak(track.url, from: 1.006, to: silence.end), 1e-5, "nothing of either input during the pause")
        XCTAssertGreaterThan(try peak(track.url, from: 3.3, to: 3.9), 0.15, "the new input after Resume")
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
        // Pause partway through a buffer's time (its silence from 101.03): what it holds from there is silence, before
        // it isn't.
        clock.now = 101.08
        recorder.pause()
        feed([mic, screen], from: 101, seconds: 2, clock: clock)
        recorder.resume()
        feed([mic, screen], from: 103, seconds: 1, clock: clock)
        _ = await recorder.stop()

        let edge = Int(((1.08 - CapturePauses.lead) * 48_000).rounded()) - 48_000
        for log in [you, call] {
            let entries = log.entries
            XCTAssertEqual(entries.count, 40, "every buffer reaches captions, on the session's timeline")
            XCTAssertTrue(entries.filter { $0.time < 1 || $0.time >= 3.2 }.allSatisfy { $0.peak > 0.15 })
            XCTAssertTrue(entries.filter { $0.time >= 1.1 && $0.time < 3.05 }.allSatisfy { $0.peak == 0 }, "nothing of the pause")
            let straddling = try XCTUnwrap(log.buffer(at: 1))
            XCTAssertGreaterThan(Self.peak(straddling, frames: 0..<(edge - 10)), 0.15, "its start came before Pause")
            XCTAssertEqual(Self.peak(straddling, frames: (edge + 1)..<Int(straddling.frameLength)), 0, "the rest of it, after, is silent")
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
        let first = Self.silence(pause: 1, resume: 2)
        let pauses = try XCTUnwrap(result.pauses)
        XCTAssertEqual(pauses.count, 2)
        let expected: [(start: TimeInterval, end: TimeInterval)] = [(first.start, first.end), (3 - CapturePauses.lead, 4)]
        for (pause, wanted) in zip(pauses, expected) {
            XCTAssertEqual(pause.start, wanted.start, accuracy: 1e-6)
            XCTAssertEqual(pause.end ?? 0, wanted.end, accuracy: 1e-6)
        }
        XCTAssertFalse(recorder.isPaused)
        XCTAssertNil(recorder.pausedAt)
        let track = try XCTUnwrap(result.tracks.first)
        XCTAssertEqual(track.duration, 4, accuracy: 0.01)
        XCTAssertEqual(try peak(track.url, from: 3.006 - CapturePauses.lead, to: 4), 0, "paused to the end")
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
        feed([mic], from: 132.2, seconds: 1, clock: clock)
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
        XCTAssertEqual(pause.start, 2 - CapturePauses.lead, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(pause.end), 5, accuracy: 0.01, "an open pause ends where the audio does")
        XCTAssertGreaterThan(try peak(track.url, from: 0.5, to: 1.94), 0.15)
        XCTAssertEqual(try peak(track.url, from: 2.006 - CapturePauses.lead, to: 5), 0, "nothing of the pause reached the disk")
        XCTAssertTrue(track.notes?.contains(pause.note) == true, "\(track.notes ?? [])")
    }

    // MARK: The pieces

    func testBehaviorPausedFramesFollowTheHostTimeEachFrameWasCapturedAt() {
        let pauses = CapturePauses(origin: 100)
        let lead = CapturePauses.lead, margin = CapturePauses.margin
        pauses.begin { 101.5 + lead }
        XCTAssertTrue(pauses.isPaused)
        // A buffer from 101.4, 0.2 s at 10 Hz (frame 0 is before the pause's silence, from 101.5).
        XCTAssertEqual(pauses.pausedFrames(from: 101.4, frames: 2, rate: 10), [1..<2])
        XCTAssertEqual(pauses.pausedFrames(from: 101.0, frames: 4, rate: 10), [], "captured before Pause")
        pauses.end { 102 - margin }
        XCTAssertFalse(pauses.isPaused)
        XCTAssertEqual(pauses.pausedFrames(from: 101.0, frames: 20, rate: 10), [5..<10])
        XCTAssertEqual(pauses.pausedFrames(from: 102.0, frames: 10, rate: 10), [], "captured after the silence")
        XCTAssertTrue(pauses.overlaps(from: 101.9, seconds: 0.2))
        XCTAssertFalse(pauses.overlaps(from: 102, seconds: 0.2))
        XCTAssertFalse(pauses.end { 103 }, "none open")
        // Paused again at once: the silence never reaches back into the last one's.
        XCTAssertTrue(pauses.begin { 102 - margin })
        XCTAssertFalse(pauses.begin { 104 }, "one open already")
        XCTAssertEqual(pauses.record, [CapturePause(start: 1.5, end: 2), CapturePause(start: 2, end: nil)])
        XCTAssertEqual(CapturePause.closed(pauses.record, at: 6), [CapturePause(start: 1.5, end: 2), CapturePause(start: 2, end: 6)])
        XCTAssertEqual(CapturePause(start: 3, end: nil).note, "Paused from 0:03; the gap is silent.")
    }

    /// The clock is read under the lock: a capture thread judging a buffer meanwhile waits for the pause it falls in.
    func testBehaviorTheClockIsReadUnderThePausesLock() {
        let pauses = CapturePauses(origin: 100)
        let judged = JudgedFrames()
        pauses.begin {
            // A capture thread judging a buffer while Pause reads the clock waits until the pause is there.
            Thread { judged.set(pauses.pausedFrames(from: 101, frames: 10, rate: 10)) }.start()
            Thread.sleep(forTimeInterval: 0.05)
            XCTAssertNil(judged.value, "it waited")
            return 101.5
        }
        let deadline = Date().addingTimeInterval(2)
        while judged.value == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(judged.value, [5..<10], "judged with the pause")
    }
}

/// What a capture thread judged, read from the test's.
private final class JudgedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [Range<Int>]?
    var value: [Range<Int>]? { lock.withLock { ranges } }
    func set(_ value: [Range<Int>]) { lock.withLock { ranges = value } }
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

    /// A recorder whose own button starts during a pause doesn't join the paused conversation: its recording is its
    /// own, as with this Mac busy, and the pause stays. After Resume its button joins as before.
    func testBehaviorARecordersButtonDuringAPauseDoesntJoinIt() async throws {
        let recorder = FakeRecorder()
        recorder.reachable = false
        let (rig, made) = try await rigAndSession(recorder: recorder)
        let session = try XCTUnwrap(made)
        let id = try await rig.startRecording()
        await rig.state.sources.recorders.settle()
        XCTAssertTrue(rig.state.canPauseRecording, "the recorder wasn't nearby to record along")
        rig.state.pauseRecording()
        let links = rig.meeting(id)?.companions?.count ?? 0

        rig.state.recorderButton(session, true)
        XCTAssertEqual(rig.meeting(id)?.companions?.count ?? 0, links, "not linked into the paused conversation")
        XCTAssertFalse(rig.state.sources.recorders.records(session.id, in: id))
        XCTAssertFalse(rig.state.sources.recorders.hasCompany(id))
        XCTAssertTrue(rig.state.isRecordingPaused, "and the pause stays")

        rig.state.resumeRecording()
        rig.state.recorderButton(session, true)
        XCTAssertTrue(rig.state.sources.recorders.records(session.id, in: id), "after Resume it joins as before")
        XCTAssertFalse(rig.state.canPauseRecording, "it wouldn't pause with this Mac")
        await rig.state.stopRecording()
        await rig.state.sources.recorders.settle()
    }

    /// A phone asking to record the conversation this Mac has paused is refused; after Resume it's told this Mac records it.
    func testBehaviorAPhonesStartForThePausedConversationIsRefused() async throws {
        let rig = try await rig()
        let id = try await rig.startRecording()
        await rig.state.sources.recorders.settle()
        let peer = LinkPeer(deviceID: UUID(), capabilities: LinkCapabilities(deviceClass: .iPhone, name: "Alex’s iPhone", appVersion: "1", features: []),
                            protocolVersion: 1, connectedAt: Date())
        let request = LinkRecordRequest(action: .start, conversationID: id, timing: LinkTiming(startedAt: Date()))
        rig.state.pauseRecording()
        guard case .refused(let refusal) = await rig.state.answerPhone(request, from: peer) else { return XCTFail("a paused recording is joined") }
        XCTAssertEqual(refusal.reason, .busy)
        XCTAssertEqual(refusal.message, AppState.pausedHere)
        rig.state.resumeRecording()
        guard case .accepted(let ack) = await rig.state.answerPhone(request, from: peer) else { return XCTFail("refused after Resume") }
        XCTAssertTrue(ack.wasAlreadyRecording)
        await rig.state.stopRecording()
    }

    /// A recorder whose start didn't confirm may be recording anyway, and Stop would bring its file in: Pause isn't
    /// offered until its own status, read live, says it isn't recording.
    func testBehaviorARecorderWhoseStartLookedFailedIsCompanyUntilItSaysItIsntRecording() async throws {
        let recorder = FakeRecorder()
        recorder.confirms = false
        let rig = try await rig(recorder: recorder)
        let id = try await rig.startRecording()
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .failed)
        XCTAssertTrue(rig.state.canPauseRecording, "connected, and it says it isn't recording")

        recorder.alreadyRecording(since: Date())
        XCTAssertFalse(rig.state.canPauseRecording, "it says it's recording after all")
        recorder.disconnect()
        XCTAssertFalse(rig.state.canPauseRecording, "out of reach, what it last said doesn't count")
        await rig.state.stopRecording()
        await rig.state.sources.recorders.settle()
    }

    /// A recorder's recording that overlaps a span the person paused the conversation is its own conversation, even
    /// when linked to it; one well clear of the pause joins it.
    func testBehaviorARecordingOverlappingAPauseIsFiledOnItsOwn() async throws {
        let rig = try await rig()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try await rig.macConversation("Design review", at: start, seconds: 600, audio: try rig.audio("mac.wav", frequency: 440))
        rig.state.update(id) { meeting in
            meeting.tracks[0].startedAt = start
            meeting.tracks[0].capture = TrackCaptureDetails(method: "microphone", pauses: [PersonPause(start: 120, end: 180)])
        }
        let during = try await rig.state.importFromDevice(try rig.audio("during.wav", frequency: 523), identity: MultiSourceRig.soundcore(start.addingTimeInterval(150)),
                                                          attachTo: id, source: .soundcore)
        XCTAssertNotEqual(during, id, "it would hold what was said during the pause")
        let after = try await rig.state.importFromDevice(try rig.audio("after.wav", frequency: 587), identity: MultiSourceRig.soundcore(start.addingTimeInterval(400)),
                                                         attachTo: id, source: .soundcore)
        XCTAssertEqual(after, id, "well after the pause, it joins")
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
