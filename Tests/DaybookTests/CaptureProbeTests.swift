import AVFoundation
import Foundation
import XCTest
@testable import Daybook

/// The process-tap probe's measurements (`--capture-probe`, docs/sandbox.md). The tap itself needs a permission and a
/// playing app, so only the owner runs it.
final class CaptureProbeTests: XCTestCase {
    func testEachSecondKeepsItsLoudestPeak() {
        var levels = ProbeLevels()
        levels.add(buffer(peak: 0.25), at: 100.0)
        levels.add(buffer(peak: 0.1), at: 100.4)
        levels.add(buffer(peak: 0.5), at: 101.5)
        levels.add(buffer(peak: 0.05), at: 103.2)
        XCTAssertEqual(levels.peaks, [0.25, 0.5, 0, 0.05])
        XCTAssertEqual(levels.buffers, 4)
        XCTAssertEqual(levels.frames, 4 * 480)
    }

    func testSilenceMeasuresZero() {
        var levels = ProbeLevels()
        levels.add(buffer(peak: 0), at: 5)
        XCTAssertEqual(levels.peaks, [0])
        XCTAssertEqual(ProbeLevels.peak(buffer(peak: 0, channels: 2)), 0)
        XCTAssertEqual(ProbeLevels.peak(buffer(peak: 0.75, channels: 2)), 0.75)
    }

    func testTheReportRoundTrips() throws {
        var report = CaptureProbeReport(bundleID: "com.apple.Music", sandboxed: true, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                        requestedSeconds: 10)
        report.peaks = [0.1, 0.2]; report.maxPeak = 0.2; report.heardSignal = true
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CaptureProbeReport.self, from: encoder.encode(report))
        XCTAssertEqual(decoded.peaks, [0.1, 0.2])
        XCTAssertTrue(decoded.heardSignal)
        XCTAssertTrue(decoded.sandboxed)
    }

    /// A buffer whose loudest sample, in the last channel, is `peak` (negative, to check magnitudes).
    private func buffer(peak: Float, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for channel in 0..<Int(channels) {
            for index in 0..<480 { buffer.floatChannelData![channel][index] = peak / 4 }
        }
        buffer.floatChannelData![Int(channels) - 1][17] = -peak
        return buffer
    }
}
