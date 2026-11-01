import AVFoundation
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// The Controls menu says Play or Pause as playback is, reading only whether it's playing: the
/// position, which moves ten times a second, doesn't redraw it. A silent file, played muted.
@MainActor
final class AudioPlaybackTests: XCTestCase {
    func testPlayOrPauseFollowsOnlyWhetherItsPlaying() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookPlayback-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)

        let playback = AudioPlaybackController()
        let playing = ObservationCount { _ = playback.isPlaying }
        let everything = ObservationCount { _ = playback.isPlaying; _ = playback.position }
        defer { playing.cancel(); everything.cancel(); playback.unload() }

        playback.play(url: url, at: 0)
        playback.mute()
        if playback.errorMessage != nil { throw XCTSkip("No audio output to play to") }
        XCTAssertTrue(playback.isPlaying)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(playing.count, 1, "Once, when it started")
        XCTAssertGreaterThan(everything.count, playing.count + 2, "The position moved meanwhile")

        playback.pause()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playing.count, 2)
    }
}
