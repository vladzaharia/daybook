import AVFoundation
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
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertGreaterThan(engine.position, 0.2, "the clock reads the position while it plays")

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
