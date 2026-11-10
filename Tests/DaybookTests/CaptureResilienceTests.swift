import AVFoundation
import DaybookCore
import DaybookKit
import DaybookTestSupport
import XCTest
@testable import Daybook

// A recording ends only when someone stops it, and says when it can't hear (docs/capture.md, "When the world
// misbehaves"). Fake sources, a fake disk, a fake clock, and a fake free-space reading: nothing records the room.

/// A disk that stops answering: a writer's next write waits here while its track is closed.
final class DiskGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var closed: Set<CapturedTrackRole> = []
    private var count: [CapturedTrackRole: Int] = [:]

    func close(_ roles: CapturedTrackRole...) { condition.lock(); closed.formUnion(roles); condition.unlock() }
    func open() { condition.lock(); closed.removeAll(); condition.broadcast(); condition.unlock() }
    /// Buffers that reached the disk, by track.
    func passed(_ role: CapturedTrackRole) -> Int { condition.lock(); defer { condition.unlock() }; return count[role, default: 0] }

    func pass(_ role: CapturedTrackRole) {
        condition.lock()
        while closed.contains(role) { condition.wait() }
        count[role, default: 0] += 1
        condition.unlock()
    }
}

/// What a test reads back from the capture environment's hooks.
@MainActor
final class CaptureLog {
    var awake: [Bool] = []
    var free: Int64?
    var serviceRestarted: (@Sendable () -> Void)?
}

@MainActor
final class CaptureResilienceTests: XCTestCase {
    private func directory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookResilience-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func recorder(_ clock: FakeHostClock, microphone: FakeCaptureSource, system: FakeSystemAudio = FakeSystemAudio(),
                          log: CaptureLog? = nil, writing: CaptureWriting = CaptureWriting()) -> RecordingController {
        let log = log ?? CaptureLog()
        var environment = CaptureEnvironment(
            microphoneAuthorization: { true }, makeMicrophone: { microphone }, systemAudio: system,
            currentRoute: { AudioOutputRoute(kind: .speakers, deviceName: "Speakers", transport: nil) },
            observeRoutes: { _ in nil }, hostTime: { clock.now })
        environment.writing = writing
        environment.freeSpace = { [log] _ in MainActor.assumeIsolated { log.free } }
        environment.keepAwake = { [log] in log.awake.append($0) }
        environment.observeAudioServiceRestarts = { [log] handler in
            MainActor.assumeIsolated { log.serviceRestarted = handler }
            return NSObject()
        }
        return RecordingController(environment: environment)
    }

    /// `seconds` of audio from each source in `step`-second buffers, the clock following; the microphone is mono, the
    /// call stereo.
    private func feed(_ sources: [FakeCaptureSource], from start: TimeInterval, seconds: Double, step: Double = 0.1,
                      level: Float = 0.2, clock: FakeHostClock) {
        let frames = Int(step * 48_000)
        for index in 0..<Int((seconds / step).rounded()) {
            let time = start + Double(index) * step
            clock.now = time
            for source in sources {
                source.emit(CallSignals.tone(channels: source.method == "microphone" ? 1 : 2, level: level, frames: frames), at: time)
            }
        }
        clock.now = start + seconds
    }

    private func yield() async { for _ in 0..<50 { await Task.yield() } }

    // MARK: A busy disk

    /// The disk stops answering for 5 s: both tracks keep recording, the hole is padded so the timeline holds, and each
    /// track says what it lost. The recording never stopped.
    func testBehaviorAFiveSecondDiskStallKeepsBothTracksPadsAndSaysWhatWasLost() async throws {
        let clock = FakeHostClock(), system = FakeSystemAudio(), mic = FakeCaptureSource(method: "microphone")
        let gate = DiskGate()
        let recorder = recorder(clock, microphone: mic, system: system,
                                writing: CaptureWriting(maximumBacklog: 1, beforeWrite: { gate.pass($0) }))
        var stopped: String?
        recorder.onUnexpectedStop = { _, why in stopped = why }
        try await recorder.start(in: directory(), includeSystemAudio: true, callApp: nil)
        let screen = system.screens[0]
        feed([mic, screen], from: 100, seconds: 2, clock: clock)
        try await waitUntil("the first two seconds to be written") { gate.passed(.microphone) == 20 && gate.passed(.systemAudio) == 20 }

        gate.close(.microphone, .systemAudio)
        feed([mic, screen], from: 102, seconds: 5, clock: clock)
        recorder.updateLevels()
        XCTAssertEqual(recorder.state, .recording, "a busy disk doesn't end the recording")
        gate.open()
        feed([mic, screen], from: 107, seconds: 1, clock: clock)

        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertNil(stopped)
        for role in [CapturedTrackRole.microphone, .systemAudio] {
            let track = try XCTUnwrap(result.tracks.first { $0.role == role })
            XCTAssertEqual(track.duration, 8, accuracy: 0.01, "the lost stretch is padded, so the timeline holds")
            XCTAssertEqual(track.lostSeconds, 4, accuracy: 0.15, "a second waited in the backlog; the rest was dropped")
            XCTAssertEqual(track.gaps?.map(\.kind), [.lost])
            XCTAssertEqual(try AVAudioFile(forReading: track.url).length, track.frameCount)
            XCTAssertTrue(track.notes?.contains { $0.hasSuffix("of \(role.audioName) were lost while the disk was busy.") } == true,
                          "\(track.notes ?? [])")
        }
        XCTAssertTrue(result.warnings.contains { $0.hasSuffix("of call audio were lost while the disk was busy.") }, "\(result.warnings)")
        XCTAssertTrue(result.warnings.contains { $0.hasSuffix("of microphone audio were lost while the disk was busy.") })
        XCTAssertEqual(RecordingWords.lostAudio(2.4, of: "call audio"), "2.4 s of call audio were lost while the disk was busy.")
        XCTAssertEqual(RecordingWords.lostAudio(1, of: "call audio"), "1 s of call audio was lost while the disk was busy.")
    }

    /// A call writer that hasn't finished anything for a minute stops the call track only; the microphone goes on.
    func testBehaviorACallWriterStuckForAMinuteStopsOnlyTheCall() async throws {
        let clock = FakeHostClock(), system = FakeSystemAudio(), mic = FakeCaptureSource(method: "microphone")
        let gate = DiskGate()
        gate.close(.systemAudio)
        let recorder = recorder(clock, microphone: mic, system: system, writing: CaptureWriting(beforeWrite: { gate.pass($0) }))
        try await recorder.start(in: directory(), includeSystemAudio: true, callApp: nil)
        let screen = system.screens[0]
        feed([mic, screen], from: 100, seconds: 59, step: 1, clock: clock)
        recorder.updateLevels()
        XCTAssertFalse(screen.stopped, "under a minute: still waiting for the disk")
        feed([mic, screen], from: 159, seconds: 3, step: 1, clock: clock)
        recorder.updateLevels()
        await yield()
        XCTAssertTrue(screen.stopped)
        XCTAssertEqual(recorder.state, .recording, "the microphone keeps recording")
        gate.open()
        feed([mic], from: 162, seconds: 2, step: 1, clock: clock)
        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertTrue(result.warnings.contains(RecordingController.callWriterStalled))
        XCTAssertEqual(try XCTUnwrap(result.tracks.first { $0.role == .microphone }).duration, 64, accuracy: 0.01)
    }

    /// The microphone's writer stuck for a minute is a disk that stopped answering: the recording ends, and says so.
    func testBehaviorAMicrophoneWriterStuckForAMinuteEndsTheRecording() async throws {
        let clock = FakeHostClock(), mic = FakeCaptureSource(method: "microphone")
        let gate = DiskGate()
        gate.close(.microphone)
        let recorder = recorder(clock, microphone: mic, writing: CaptureWriting(beforeWrite: { gate.pass($0) }))
        var stopped: String?
        recorder.onUnexpectedStop = { _, why in stopped = why }
        try await recorder.start(in: directory(), includeSystemAudio: false)
        feed([mic], from: 100, seconds: 62, step: 1, clock: clock)
        recorder.updateLevels()
        gate.open()
        try await waitUntil("the stop") { stopped != nil }
        XCTAssertEqual(stopped, PCMTrackWriterError.diskBacklog.localizedDescription)
        XCTAssertEqual(recorder.state, .idle)
    }

    // MARK: Sources that stop delivering

    /// A microphone and a tap that stop delivering are restarted after 3 s, and again 3 s later; a tap that stays
    /// silent through three rebuilds falls back to ScreenCaptureKit. Audio arriving starts the count over.
    func testBehaviorSourcesThatStopDeliveringAreRestartedAndATapThatStaysSilentFallsBack() async throws {
        let clock = FakeHostClock(), system = FakeSystemAudio(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic, system: system)
        try await recorder.start(in: directory(), includeSystemAudio: true,
                                 callApp: CallAppTarget(bundleID: "us.zoom.xos", displayName: "Zoom", isBrowser: false))
        let tap = system.taps[0]
        feed([mic, tap], from: 100, seconds: 1, clock: clock)
        clock.now = 102.5
        recorder.updateLevels()
        await yield()
        XCTAssertTrue(mic.restarts.isEmpty && tap.restarts.isEmpty, "2.5 s without audio is still fine")

        clock.now = 104.2
        recorder.updateLevels()
        await yield()
        XCTAssertEqual(mic.restarts, [.stalled])
        XCTAssertEqual(tap.restarts, [.stalled])
        clock.now = 105
        recorder.updateLevels()
        await yield()
        XCTAssertEqual(mic.restarts.count, 1, "a restart has its own 3 s")

        for time in [107.5, 110.8] {
            clock.now = time
            recorder.updateLevels()
            await yield()
        }
        XCTAssertEqual(tap.restarts.count, 3)
        clock.now = 114.1
        recorder.updateLevels()
        try await waitUntil("the fallback") { recorder.systemAudioCapture?.method == .screenCaptureKit }
        XCTAssertTrue(tap.stopped)
        XCTAssertEqual(mic.restarts.count, 4, "the microphone is restarted for as long as it's silent (its own rate limit applies)")
        XCTAssertEqual(recorder.state, .recording)

        // Audio again: the next stall starts the count over.
        let screen = system.screens[0]
        feed([mic, screen], from: 114.2, seconds: 1, clock: clock)
        clock.now = 118.5
        recorder.updateLevels()
        await yield()
        XCTAssertEqual(screen.restarts, [.stalled], "ScreenCaptureKit restarts itself once (on the main display)")
        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertEqual(result.systemAudio?.method, .screenCaptureKit)
    }

    /// coreaudiod restarting makes every device new: both sources are started again, and the Mac is kept awake only
    /// while recording.
    func testBehaviorTheAudioSystemRestartingRebuildsBothSourcesAndSleepIsHeldOffWhileRecording() async throws {
        let clock = FakeHostClock(), system = FakeSystemAudio(), mic = FakeCaptureSource(method: "microphone")
        let log = CaptureLog()
        let recorder = recorder(clock, microphone: mic, system: system, log: log)
        try await recorder.start(in: directory(), includeSystemAudio: true, callApp: nil)
        XCTAssertEqual(log.awake, [true])
        let screen = system.screens[0]
        feed([mic, screen], from: 100, seconds: 1, clock: clock)
        log.serviceRestarted?()
        try await waitUntil("both restarted") { mic.restarts == [.audioSystemRestarted] && screen.restarts == [.audioSystemRestarted] }
        mic.send(.restarted(CaptureRestartReason.audioSystemRestarted.note("microphone")))
        await yield()
        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertEqual(log.awake, [true, false])
        XCTAssertTrue(result.warnings.contains(RecordingController.microphoneRestarted))
        XCTAssertFalse(result.warnings.contains(RecordingController.microphoneChanged), "it's the same microphone")
    }

    // MARK: Hearing

    /// The microphone hears speech, then digital zeros (a lid closed in clamshell, a mute switch): after 5 s it isn't
    /// hearing, and says so until it hears again. Sound below −90 dBFS for 20 s counts too.
    func testBehaviorAMicrophoneThatGoesSilentPartwayIsSaidAndHeardAgain() async throws {
        let clock = FakeHostClock(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic)
        try await recorder.start(in: directory(), includeSystemAudio: false)
        feed([mic], from: 100, seconds: 3, clock: clock)
        recorder.updateLevels()
        XCTAssertFalse(recorder.levels.isMicrophoneSilent)

        feed([mic], from: 103, seconds: 4.5, level: 0, clock: clock)
        recorder.updateLevels()
        XCTAssertFalse(recorder.levels.isMicrophoneSilent, "4.5 s of zeros: not yet")
        feed([mic], from: 107.5, seconds: 1.5, level: 0, clock: clock)
        recorder.updateLevels()
        XCTAssertTrue(recorder.levels.isMicrophoneSilent, "6 s of zeros after speech is said, not hidden by the speech before it")

        feed([mic], from: 109, seconds: 1, clock: clock)
        recorder.updateLevels()
        XCTAssertFalse(recorder.levels.isMicrophoneSilent, "hearing again")

        // Not zeros, but nothing a room makes: −120 dBFS for over 20 s.
        feed([mic], from: 110, seconds: 21, step: 0.5, level: 1e-6, clock: clock)
        recorder.updateLevels()
        XCTAssertTrue(recorder.levels.isMicrophoneSilent)
        _ = await recorder.stop()
    }

    func testTheHearingRuleOnItsOwn() {
        typealias Reading = AudioLevelMeter.Reading
        func notHearing(_ signal: TimeInterval?, _ heard: TimeInterval?, now: TimeInterval = 100, elapsed: TimeInterval = 60) -> Bool {
            CaptureLevelMonitor.isNotHearing(Reading(rms: -40, peak: -30, lastSignalHostTime: signal, lastHeardHostTime: heard),
                                             now: now, elapsed: elapsed)
        }
        XCTAssertFalse(notHearing(nil, nil, elapsed: 4), "nothing yet, but too soon to say")
        XCTAssertTrue(notHearing(nil, nil, elapsed: 6), "nothing in the first 5 s")
        XCTAssertFalse(notHearing(99, 99))
        XCTAssertTrue(notHearing(94.9, 94.9), "no non-zero sample for over 5 s")
        XCTAssertFalse(notHearing(99.9, 81), "quiet but not under −90 dBFS for 20 s")
        XCTAssertTrue(notHearing(99.9, 79.9), "under −90 dBFS for over 20 s")
    }

    /// RMS over 300 ms and a peak held for a second: a tap's 10 ms buffers and the microphone's 85 ms ones read alike.
    func testMetersMoveAlikeWhateverTheBufferSize() {
        let small = AudioLevelMeter(), large = AudioLevelMeter()
        for index in 0..<100 { small.record(CallSignals.tone(level: 0.2, frames: 480), hostTime: 100 + Double(index) * 0.01) }
        for index in 0..<12 { large.record(CallSignals.tone(level: 0.2, frames: 4_096), hostTime: 100 + Double(index) * 4_096 / 48_000) }
        XCTAssertEqual(small.read().rms, large.read().rms, accuracy: 0.5)
        XCTAssertEqual(small.read().rms, -17, accuracy: 0.5, "a 0.2 sine is −17 dBFS once settled")

        // Silence: the level falls over a few hundred milliseconds, the peak holds for a second.
        for index in 0..<30 { small.record(CallSignals.tone(level: 0, frames: 480), hostTime: 101 + Double(index) * 0.01) }
        let falling = small.read()
        XCTAssertLessThan(falling.rms, -18)
        XCTAssertGreaterThan(falling.rms, -40, "not dropped at once")
        XCTAssertEqual(falling.peak, 20 * log10(0.2), accuracy: 0.2, "the peak holds")
        for index in 0..<100 { small.record(CallSignals.tone(level: 0, frames: 480), hostTime: 101.3 + Double(index) * 0.01) }
        XCTAssertEqual(small.read().peak, -160, accuracy: 1, "and lets go after a second")
    }

    // MARK: Space

    /// Every 30 s the free space is divided by the byte rate: under 30 minutes it warns; under 3, call audio stops so
    /// the microphone has what's left.
    func testBehaviorRunningOutOfSpaceWarnsThenStopsTheCallFirst() async throws {
        let clock = FakeHostClock(), system = FakeSystemAudio(), mic = FakeCaptureSource(method: "microphone")
        let log = CaptureLog()
        let recorder = recorder(clock, microphone: mic, system: system, log: log)
        let folder = directory()
        try await recorder.start(in: folder, includeSystemAudio: true, callApp: nil)
        let screen = system.screens[0]
        // 48 kHz Float32: the mono microphone writes 192,000 bytes a second, the stereo call 384,000.
        let rate: Int64 = 192_000 + 384_000
        log.free = rate * 60 * 60
        feed([mic, screen], from: 100, seconds: 1, clock: clock)
        try await waitUntil("both tracks on disk") {
            ["microphone.caf", "systemAudio.caf"].allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
        recorder.updateLevels()
        XCTAssertNil(recorder.spaceLeft, "an hour left: nothing to say")

        log.free = rate * 20 * 60
        feed([mic, screen], from: 101, seconds: 30, step: 1, clock: clock)
        recorder.updateLevels()
        XCTAssertEqual(try XCTUnwrap(recorder.spaceLeft), 20 * 60, accuracy: 1)
        XCTAssertFalse(recorder.callStoppedForSpace)

        log.free = rate * 2 * 60
        feed([mic, screen], from: 131, seconds: 30, step: 1, clock: clock)
        recorder.updateLevels()
        await yield()
        XCTAssertTrue(recorder.callStoppedForSpace)
        XCTAssertTrue(screen.stopped)
        XCTAssertEqual(recorder.state, .recording, "the microphone goes on")
        recorder.updateLevels()
        XCTAssertEqual(try XCTUnwrap(recorder.spaceLeft), Double(rate * 2 * 60) / 192_000, accuracy: 1, "measured again at the microphone's rate")
        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertTrue(result.warnings.contains(RecordingController.callStoppedForSpace))
        XCTAssertNil(recorder.spaceLeft)
    }

    // MARK: Sleep

    /// Put to sleep, the recording stops (what was recorded is kept) and says it was for sleep, so the devices
    /// recording along aren't stopped with it.
    func testBehaviorSleepStopsThisMacsTracksAndSaysItWasForSleep() async throws {
        let clock = FakeHostClock(), mic = FakeCaptureSource(method: "microphone")
        let recorder = recorder(clock, microphone: mic)
        var stopped: String?
        recorder.onUnexpectedStop = { _, why in stopped = why }
        try await recorder.start(in: directory(), includeSystemAudio: false)
        XCTAssertFalse(recorder.stoppedForSleep)
        feed([mic], from: 100, seconds: 1, clock: clock)
        await yield()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitUntil("the stop for sleep") { stopped != nil }
        XCTAssertEqual(stopped, RecordingController.sleepSentence)
        XCTAssertTrue(recorder.stoppedForSleep)
        try await recorder.start(in: directory(), includeSystemAudio: false)
        XCTAssertFalse(recorder.stoppedForSleep, "the next recording starts afresh")
        _ = await recorder.stop()
    }
}

// MARK: - Microphone restarts

/// An engine that fails as told.
final class FakeMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {
    var onConfigurationChange: (() -> Void)?
    /// Starts on the default input that fail before one works.
    var failures = 0
    var builtInWorks = true
    /// Each start, by whether it was the built-in microphone.
    private(set) var starts: [Bool] = []
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    func start(builtIn: Bool, deliver: @escaping CaptureBufferHandler, report: @escaping CaptureEventHandler) throws -> AVAudioFormat {
        starts.append(builtIn)
        if builtIn {
            guard builtInWorks else { throw RecordingError.noMicrophone }
            return format
        }
        if failures > 0 { failures -= 1; throw RecordingError.noMicrophone }
        return format
    }

    func stop() {}
}

/// What the microphone reported.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CaptureSourceEvent] = []
    var events: [CaptureSourceEvent] { lock.withLock { stored } }
    func add(_ event: CaptureSourceEvent) { lock.withLock { stored.append(event) } }

    var changes: [String] { events.compactMap { if case .deviceChanged(let note) = $0 { return note }; return nil } }
    var failures: [String] { events.compactMap { if case .failed(let error) = $0 { return error.localizedDescription }; return nil } }
}

@MainActor
final class MicrophoneRestartTests: XCTestCase {
    private var pauses: [TimeInterval] = []
    private var now: TimeInterval = 0

    private func source(_ engine: FakeMicrophoneEngine) -> MicrophoneSource {
        MicrophoneSource(engine: engine, now: { [unowned self] in MainActor.assumeIsolated { now } },
                         pause: { [unowned self] delay in await MainActor.run { pauses.append(delay) } })
    }

    private func change(_ engine: FakeMicrophoneEngine, until log: EventLog, count: Int) async throws {
        engine.onConfigurationChange?()
        try await waitUntil("the restart") { log.events.count >= count }
    }

    /// AirPods coming and going: thirty device changes over ten minutes never end the recording.
    func testBehaviorThirtyDeviceChangesInTenMinutesAreAllFollowed() async throws {
        let engine = FakeMicrophoneEngine(), log = EventLog()
        let microphone = source(engine)
        try await microphone.start(onBuffer: { _, _ in }, onEvent: { log.add($0) })
        for index in 0..<30 {
            now = Double(index) * 20
            try await change(engine, until: log, count: index + 1)
        }
        XCTAssertEqual(log.changes.count, 30)
        XCTAssertTrue(log.failures.isEmpty)
    }

    /// More than ten restarts within a minute is a microphone that won't settle: that ends it.
    func testBehaviorElevenChangesWithinAMinuteFail() async throws {
        let engine = FakeMicrophoneEngine(), log = EventLog()
        let microphone = source(engine)
        try await microphone.start(onBuffer: { _, _ in }, onEvent: { log.add($0) })
        for index in 0..<11 {
            now = Double(index) * 5
            try await change(engine, until: log, count: index + 1)
        }
        XCTAssertEqual(log.changes.count, 10)
        XCTAssertEqual(log.failures, ["The microphone kept changing, so recording stopped. Everything up to then is saved."])
    }

    /// A new device that reports 0 Hz for a moment: tried again after 0.25 s and 0.5 s, and it continues.
    func testBehaviorARestartThatFailsTwiceThenSucceedsContinues() async throws {
        let engine = FakeMicrophoneEngine(), log = EventLog()
        let microphone = source(engine)
        try await microphone.start(onBuffer: { _, _ in }, onEvent: { log.add($0) })
        engine.failures = 2
        try await change(engine, until: log, count: 1)
        XCTAssertEqual(pauses, [0.25, 0.5])
        XCTAssertEqual(engine.starts, [false, false, false, false])
        XCTAssertEqual(log.changes.count, 1)
        XCTAssertTrue(log.failures.isEmpty)
    }

    /// An input that never starts again moves to the built-in microphone; only when that fails too does it fail.
    func testBehaviorAnInputThatWontStartFallsBackToTheBuiltInMicrophoneThenFails() async throws {
        let engine = FakeMicrophoneEngine(), log = EventLog()
        let microphone = source(engine)
        try await microphone.start(onBuffer: { _, _ in }, onEvent: { log.add($0) })
        engine.failures = 100
        try await change(engine, until: log, count: 1)
        XCTAssertEqual(pauses, [0.25, 0.5, 1, 2])
        XCTAssertEqual(engine.starts, [false, false, false, false, false, false, true])
        XCTAssertTrue(log.changes.first?.contains("built-in microphone") == true, "\(log.changes)")

        engine.builtInWorks = false
        try await change(engine, until: log, count: 2)
        XCTAssertEqual(log.failures.count, 1)
    }

    /// A stall restart says it restarted, not that the microphone changed.
    func testAStallRestartIsSaidAsARestart() async throws {
        let engine = FakeMicrophoneEngine(), log = EventLog()
        let microphone = source(engine)
        try await microphone.start(onBuffer: { _, _ in }, onEvent: { log.add($0) })
        await microphone.restart(.stalled)
        guard case .restarted(let note)? = log.events.first else { return XCTFail("\(log.events)") }
        XCTAssertTrue(note.hasPrefix("The microphone stopped delivering audio, so it was restarted."))
    }
}
