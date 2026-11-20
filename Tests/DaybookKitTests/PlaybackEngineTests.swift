import AVFoundation
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// One player core for both apps: the end-of-file rule, seeks held inside the recording, the position read on its own
/// clock, skips counted for the buttons, and how playback ended. Silent synthetic files, played muted.
@MainActor
final class PlaybackEngineTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
        super.tearDown()
    }

    /// A silent mono file `seconds` long.
    private func silence(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackEngine-\(UUID().uuidString).wav")
        files.append(url)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    func testBehaviorPlayAtTheVeryEndStartsOverOnBothApps() {
        XCTAssertTrue(PlaybackEngine.startsOver(at: 60, duration: 60))
        XCTAssertTrue(PlaybackEngine.startsOver(at: 59.97, duration: 60), "the last moment would play nothing")
        XCTAssertFalse(PlaybackEngine.startsOver(at: 59.9, duration: 60))
        XCTAssertFalse(PlaybackEngine.startsOver(at: 0, duration: 0), "nothing loaded")
    }

    /// Whichever notices first, the clock or the player's delegate, a recording that played out is told apart from
    /// one that was interrupted, so it's said once and the same way (a slow runner's clock saw the end first).
    func testBehaviorAStopAtTheEndIsTheEndWhicheverSideSeesItFirst() {
        XCTAssertTrue(PlaybackEngine.playedOut(previous: 59.9, current: 60, duration: 60, rate: 1), "at the end")
        XCTAssertTrue(PlaybackEngine.playedOut(previous: 59.92, current: 0, duration: 60, rate: 1), "back at the start after finishing")
        XCTAssertTrue(PlaybackEngine.playedOut(previous: 59.8, current: 0, duration: 60, rate: 2), "a tick covers more at double speed")
        XCTAssertFalse(PlaybackEngine.playedOut(previous: 59.8, current: 0, duration: 60, rate: 1), "the same place is short of the end at normal speed")
        XCTAssertFalse(PlaybackEngine.playedOut(previous: 30, current: 30, duration: 60, rate: 1), "stopped in the middle: interrupted")
        XCTAssertFalse(PlaybackEngine.playedOut(previous: 12, current: 0, duration: 60, rate: 1), "reset from the middle isn't the end")
        XCTAssertFalse(PlaybackEngine.playedOut(previous: 0, current: 0, duration: 0, rate: 1), "nothing loaded")
    }

    func testBehaviorASeekStaysInsideTheRecording() {
        XCTAssertEqual(PlaybackEngine.clamped(-15, duration: 60), 0)
        XCTAssertEqual(PlaybackEngine.clamped(75, duration: 60), 60)
        XCTAssertEqual(PlaybackEngine.clamped(30, duration: 60), 30)
        XCTAssertEqual(PlaybackEngine.clamped(.nan, duration: 60), 0)
        XCTAssertEqual(PlaybackEngine.clamped(.infinity, duration: 60), 0)
    }

    func testBehaviorNothingLoadedDoesNothing() {
        let engine = PlaybackEngine()
        XCTAssertFalse(engine.play())
        engine.skip(15)
        engine.seek(to: 10)
        XCTAssertEqual(engine.forwardSkips, 0, "a skip with nothing to skip isn't one")
        XCTAssertEqual(engine.position, 0)
        XCTAssertFalse(engine.isPlaying)
    }

    func testBehaviorPlaysReadsItsPositionAndCountsSkips() async throws {
        let engine = PlaybackEngine()
        engine.volume = 0
        try engine.load(try silence(seconds: 2))
        XCTAssertEqual(engine.duration, 2, accuracy: 0.05)
        engine.rate = 1.5
        guard engine.play() else { throw XCTSkip("No audio output to play to") }
        defer { engine.unload() }
        XCTAssertTrue(engine.isPlaying)
        // Until the clock has read it moving, rather than for a fixed while: a loaded runner ticks late.
        try await waitUntil("the clock reads the position while it plays") { engine.position > 0.2 }

        engine.skip(-15)
        XCTAssertEqual(engine.position, 0, "back past the start is the start")
        engine.skip(15)
        XCTAssertEqual(engine.position, engine.duration, "forward past the end is the end")
        XCTAssertEqual(engine.backSkips, 1)
        XCTAssertEqual(engine.forwardSkips, 1)

        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        let paused = engine.position
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(engine.position, paused, "a paused clock stops")

        engine.unload()
        XCTAssertNil(engine.url)
        XCTAssertEqual(engine.duration, 0)
        XCTAssertFalse(engine.isLoaded)
    }

    func testBehaviorPlayingToTheEndSaysSoAndStartsOverNextTime() async throws {
        let engine = PlaybackEngine()
        engine.volume = 0
        try engine.load(try silence(seconds: 0.3))
        let ended = expectation(description: "reached the end")
        var endings: [PlaybackEnding] = []
        engine.onEnding = { ending in
            endings.append(ending)
            ended.fulfill()
        }
        guard engine.play() else { throw XCTSkip("No audio output to play to") }
        defer { engine.unload() }
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(endings, [.reachedEnd])
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.position, engine.duration)

        XCTAssertTrue(engine.play())
        XCTAssertLessThan(engine.position, 0.1, "Play at the end plays it again from the start")
    }

    func testBehaviorTheSameFileKeepsItsPlaceAndAnUnreadableOneSaysWhy() throws {
        let engine = PlaybackEngine()
        let url = try silence(seconds: 2)
        try engine.load(url)
        engine.seek(to: 1.2)
        try engine.load(url)
        XCTAssertEqual(engine.position, 1.2, accuracy: 0.01, "loading what's loaded doesn't go back to the start")

        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackEngine-\(UUID().uuidString).wav")
        files.append(junk)
        try Data("not audio".utf8).write(to: junk)
        XCTAssertThrowsError(try engine.load(junk))
        XCTAssertFalse(engine.isLoaded, "a failed load lets the old recording go")
    }
}

/// Playback levels: each recording plays at one constant gain that matches its speech to the others'.
@MainActor
final class PlaybackEngineLevelTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
        super.tearDown()
    }

    private func recording(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackLevel-\(UUID().uuidString).wav")
        files.append(url)
        try SyntheticAudio.write(samples, to: url)
        return url
    }

    /// Counts what an engine asked to measure, and how it ended.
    private final class Measurer: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [URL] = []
        private var cancelled = 0
        var measurements: [URL] { lock.withLock { asked } }
        var cancellations: Int { lock.withLock { cancelled } }
        /// Answers with `result`, or waits for the task to be cancelled when it's nil.
        func callAsFunction(_ url: URL, _ result: SpeechLevel.Measurement?) async throws -> SpeechLevel.Measurement {
            lock.withLock { asked.append(url) }
            if let result { return result }
            do { try await Task.sleep(for: .seconds(60)) } catch { lock.withLock { cancelled += 1 }; throw error }
            throw CancellationError()
        }
    }

    private let loud = SpeechLevel.Measurement(speech: -20, peak: -5, quiet: -50)   // 12 dB over -32: lowered 12
    private let quiet = SpeechLevel.Measurement(speech: -50, peak: -30, quiet: -80)

    func testBehaviorARecordedLevelIsUsedWithoutMeasuring() throws {
        let measurer = Measurer()
        let engine = PlaybackEngine { try await measurer($0, nil) }
        let url = try recording(SyntheticAudio.syllables(level: -20, seconds: 2))
        try engine.load(url, recordedLevel: loud)
        XCTAssertEqual(engine.levelGain, Float(pow(10, -12.0 / 20)), accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(engine.playerVolume), engine.levelGain, accuracy: 1e-6)
        XCTAssertTrue(measurer.measurements.isEmpty)
    }

    func testBehaviorAnUnrecordedFileIsMeasuredOnceAndTheGainArrivesAfterPlaybackStarted() async throws {
        let measurer = Measurer()
        let engine = PlaybackEngine { try await measurer($0, self.loud) }
        let url = try recording(SyntheticAudio.syllables(level: -20, seconds: 2))
        try engine.load(url)
        XCTAssertEqual(engine.levelGain, 1, "plays at unity until the measurement arrives")
        try await waitUntil("the measurement is applied") { engine.levelGain < 1 }
        XCTAssertEqual(engine.levelGain, Float(pow(10, -12.0 / 20)), accuracy: 1e-6)

        // The same file again, here and after another recording, comes from the session's memory.
        try engine.load(url)
        let other = try recording(SyntheticAudio.syllables(level: -50, seconds: 2))
        try engine.load(other, recordedLevel: quiet)
        try engine.load(url)
        XCTAssertEqual(engine.levelGain, Float(pow(10, -12.0 / 20)), accuracy: 1e-6, "applied at once")
        XCTAssertEqual(measurer.measurements, [url])
    }

    func testBehaviorMeasuringStopsWhenAnotherRecordingLoadsAndItsLevelIsNotApplied() async throws {
        let measurer = Measurer()
        let engine = PlaybackEngine { try await measurer($0, nil) }
        let first = try recording(SyntheticAudio.syllables(level: -20, seconds: 2))
        let second = try recording(SyntheticAudio.syllables(level: -50, seconds: 2))
        try engine.load(first)
        try await waitUntil("the first is being measured") { measurer.measurements.count == 1 }
        try engine.load(second, recordedLevel: quiet)
        try await waitUntil("the first measurement is cancelled") { measurer.cancellations == 1 }
        XCTAssertEqual(engine.levelGain, 1, "the quiet one isn't lowered")
        engine.unload()
    }

    func testBehaviorTheRealMeasureLowersALoudSyntheticRecording() async throws {
        let engine = PlaybackEngine()
        let url = try recording(SyntheticAudio.syllables(level: -20, seconds: 3))
        try engine.load(url)
        try await waitUntil("the file is measured") { engine.levelGain < 1 }
        XCTAssertEqual(20 * log10(Double(engine.levelGain)), -12, accuracy: 0.1)
        engine.unload()
        XCTAssertEqual(engine.levelGain, 1)
    }

    func testBehaviorMutedStaysSilentWhateverTheGain() throws {
        let engine = PlaybackEngine()
        let url = try recording(SyntheticAudio.syllables(level: -20, seconds: 2))
        engine.volume = 0
        try engine.load(url, recordedLevel: loud)
        XCTAssertEqual(engine.playerVolume, 0)
        engine.volume = 1
        XCTAssertEqual(try XCTUnwrap(engine.playerVolume), engine.levelGain, accuracy: 1e-6, "the gain is a factor on the volume")
        engine.volume = 0
        XCTAssertEqual(engine.playerVolume, 0)
    }
}
