import AVFoundation
import XCTest
@testable import DaybookCore

/// The level meter's measure and the format converter both apps' capture uses (`AudioBuffers.swift`).
/// Synthetic tones only.
final class AudioBuffersTests: XCTestCase {
    private func tone(_ amplitude: Float, rate: Double = 48_000, channels: AVAudioChannelCount = 1, frames: AVAudioFrameCount = 4_800,
                      interleaved: Bool = false) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            let value = amplitude * sin(2 * .pi * 1_000 * Float(frame) / Float(rate))
            for channel in 0..<Int(channels) {
                if interleaved { data[0][frame * Int(channels) + channel] = value } else { data[channel][frame] = value }
            }
        }
        return buffer
    }

    func testTheLevelOfAToneSilenceAndInterleavedStereo() throws {
        // A 1 kHz sine at half scale: RMS 0.354 (−9.03 dBFS), peak 0.5 (−6.02 dBFS).
        let half = try XCTUnwrap(AudioBufferLevel.measure(try tone(0.5)))
        XCTAssertEqual(half.rms, -9.03, accuracy: 0.05)
        XCTAssertEqual(half.peak, -6.02, accuracy: 0.05)
        XCTAssertTrue(half.hasSignal)
        let silence = try XCTUnwrap(AudioBufferLevel.measure(try tone(0)))
        XCTAssertEqual(silence.rms, -160, accuracy: 0.01)
        XCTAssertEqual(silence.peak, -160, accuracy: 0.01)
        XCTAssertFalse(silence.hasSignal, "all zeros: a muted or blocked microphone")
        let stereo = try XCTUnwrap(AudioBufferLevel.measure(try tone(0.5, channels: 2, interleaved: true)))
        XCTAssertEqual(stereo.rms, half.rms, accuracy: 0.05, "every sample of every channel counts once")
        let planar = try XCTUnwrap(AudioBufferLevel.measure(try tone(0.5, channels: 2)))
        XCTAssertEqual(planar.rms, half.rms, accuracy: 0.05)
        let empty = try tone(0.5)
        empty.frameLength = 0
        XCTAssertNil(AudioBufferLevel.measure(empty))
    }

    func testConvertingAnotherFormatKeepsItsLengthAndSaysWhenTheFormatIsNew() throws {
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let converter = PCMFormatConverter()
        XCTAssertNil(converter.inputFormat)
        XCTAssertNil(converter.drain(), "nothing to drain")
        var frames: AVAudioFrameCount = 0
        // Ten buffers of AirPods' 16 kHz stereo, a second in all.
        for index in 0..<10 {
            let input = try tone(0.5, rate: 16_000, channels: 2, frames: 1_600)
            XCTAssertEqual(try converter.prepare(from: input.format, to: target), index == 0, "a new converter only for a new format")
            let output = try converter.convert(input)
            XCTAssertEqual(output.format, target)
            frames += output.frameLength
        }
        XCTAssertEqual(converter.inputFormat?.sampleRate, 16_000)
        frames += converter.drain()?.frameLength ?? 0
        XCTAssertNil(converter.inputFormat, "drained, it's retired")
        XCTAssertEqual(Double(frames), 48_000, accuracy: 64, "a second in, a second out, the look-ahead included")

        // Downmixed to mono at the same loudness.
        let input = try tone(0.5, rate: 16_000, channels: 2, frames: 16_000)
        try converter.prepare(from: input.format, to: target)
        let level = try XCTUnwrap(AudioBufferLevel.measure(try converter.convert(input)))
        XCTAssertEqual(level.rms, -9.03, accuracy: 0.5)
        converter.discard()
        XCTAssertNil(converter.inputFormat)
        XCTAssertThrowsError(try converter.convert(input), "nothing readied")
    }
}
