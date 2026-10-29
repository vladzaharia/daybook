import AVFoundation
import Combine
import Foundation
import XCTest
@testable import Daybook

/// The Controls menu says Play or Pause as playback is, following only whether it's playing: the
/// position, which moves ten times a second, doesn't reach it. A silent file, played muted.
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
        var playing = 0, everything = 0
        let following = playback.activity.objectWillChange.sink { playing += 1 }
        let all = playback.objectWillChange.sink { everything += 1 }
        defer { following.cancel(); all.cancel(); playback.unload() }

        playback.play(url: url, at: 0)
        playback.mute()
        if playback.errorMessage != nil { throw XCTSkip("No audio output to play to") }
        XCTAssertTrue(playback.activity.isPlaying)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(playing, 1, "Once, when it started")
        XCTAssertGreaterThan(everything, playing + 2, "The position moved meanwhile")

        playback.pause()
        XCTAssertFalse(playback.activity.isPlaying)
        XCTAssertEqual(playing, 2)
    }
}
