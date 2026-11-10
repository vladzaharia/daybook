import AVFoundation
import XCTest
import DaybookCore

/// The level meter and the rolling hearing check both apps' recorders use (`AudioLevelMeter.swift`). Synthetic tones
/// only; nothing records the room.
final class AudioLevelMeterTests: XCTestCase {
    private func tone(_ amplitude: Float, frames: Int, rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / rate)) * amplitude }
        return buffer
    }

    /// RMS over 300 ms and a peak held for a second: a Mac tap's 10 ms buffers and a microphone's 85 ms ones read alike.
    func testBehaviorMetersMoveAlikeWhateverTheBufferSize() {
        let small = AudioLevelMeter(), large = AudioLevelMeter()
        for index in 0..<100 { small.record(tone(0.2, frames: 480), hostTime: 100 + Double(index) * 0.01) }
        for index in 0..<12 { large.record(tone(0.2, frames: 4_096), hostTime: 100 + Double(index) * 4_096 / 48_000) }
        XCTAssertEqual(small.read().rms, large.read().rms, accuracy: 0.5)
        XCTAssertEqual(small.read().rms, -17, accuracy: 0.5, "a 0.2 sine is −17 dBFS once settled")
        XCTAssertGreaterThan(small.read().level.meterValue, 0.7)

        // Silence: the level falls over a few hundred milliseconds, the peak holds for a second.
        for index in 0..<30 { small.record(tone(0, frames: 480), hostTime: 101 + Double(index) * 0.01) }
        let falling = small.read()
        XCTAssertLessThan(falling.rms, -18)
        XCTAssertGreaterThan(falling.rms, -40, "not dropped at once")
        XCTAssertEqual(falling.peak, 20 * log10(0.2), accuracy: 0.2, "the peak holds")
        for index in 0..<100 { small.record(tone(0, frames: 480), hostTime: 101.3 + Double(index) * 0.01) }
        XCTAssertEqual(small.read().peak, -160, accuracy: 1, "and lets go after a second")
    }

    /// When it last heard anything, anything above the floor, and anything as loud as speech, each by the buffer's own
    /// level, never the smoothed one.
    func testBehaviorTheMeterKeepsWhenItLastHeard() {
        let meter = AudioLevelMeter()
        XCTAssertEqual(meter.read(), .silent)
        meter.record(tone(0.3, frames: 480), hostTime: 10)
        meter.record(tone(0.000_01, frames: 480), hostTime: 11)
        meter.record(tone(0, frames: 480), hostTime: 12)
        let reading = meter.read()
        XCTAssertEqual(reading.lastAudibleHostTime, 10, "a 0.3 sine is speech-loud; −103 dBFS isn't")
        XCTAssertEqual(reading.lastHeardHostTime, 10, "−103 dBFS is under the floor")
        XCTAssertEqual(reading.lastSignalHostTime, 11, "but isn't zeros")
        meter.reset()
        XCTAssertEqual(meter.read(), .silent)
    }

    /// The rolling check: no non-zero sample for 5 s, or nothing above −90 dBFS for 20 s, never counted from before it
    /// started listening.
    func testBehaviorTheHearingRule() {
        func notHearing(_ signal: TimeInterval?, _ heard: TimeInterval?, now: TimeInterval = 100, since: TimeInterval = 40) -> Bool {
            HearingCheck.isNotHearing(AudioLevelMeter.Reading(rms: -40, peak: -30, lastSignalHostTime: signal, lastHeardHostTime: heard),
                                      listeningSince: since, now: now)
        }
        XCTAssertFalse(notHearing(nil, nil, since: 96), "nothing yet, but too soon to say")
        XCTAssertTrue(notHearing(nil, nil, since: 94), "nothing in the first 5 s")
        XCTAssertTrue(HearingCheck.isNotHearing(nil, listeningSince: 94, now: 100), "nor without a meter")
        XCTAssertFalse(notHearing(99, 99))
        XCTAssertTrue(notHearing(94.9, 94.9), "no non-zero sample for over 5 s")
        XCTAssertFalse(notHearing(99.9, 81), "quiet but not under −90 dBFS for 20 s")
        XCTAssertTrue(notHearing(99.9, 79.9), "under −90 dBFS for over 20 s")
        XCTAssertFalse(notHearing(30, 30, since: 98), "a pause doesn't count against it: listening again since 98")
    }
}
