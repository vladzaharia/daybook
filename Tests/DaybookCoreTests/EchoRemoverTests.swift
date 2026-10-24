import XCTest
@testable import DaybookCore

/// End-to-end echo removal on synthetic calls: tracks at different rates and channel counts,
/// drifting clocks, silence, and missing echo. No microphone or system audio is used.
final class EchoRemoverTests: XCTestCase {
    typealias S = EchoTestSignals

    func testDelayEstimatorFindsTheDirectPathThroughReverb() {
        let rate = 16_000.0
        let far = S.speech(seconds: 20, rate: rate, seed: 21, level: 0.1)
        let near = S.speech(seconds: 20, rate: rate, seed: 22, level: 0.08, active: [5...9])
        let mic = S.add(S.convolve(far, S.roomResponse(rate: rate, delay: 0.137, gain: 0.4, reverb: 0.4)), near,
                        S.noise(count: far.count, level: 0.001, seed: 23))
        let estimator = EchoDelayEstimator(sampleRate: rate)
        var start = 0
        while start + estimator.frameSize <= far.count {
            estimator.add(reference: Array(far[start..<start + estimator.frameSize]), microphone: Array(mic[start..<start + estimator.frameSize]))
            start += estimator.frameSize
        }
        let estimate = try! XCTUnwrap(estimator.estimate())
        XCTAssertEqual(estimate.delaySeconds, 0.137, accuracy: 0.001)
        XCTAssertTrue(estimate.isEcho, "confidence \(estimate.confidence)")
    }

    func testDelayEstimatorReportsNoEchoWhenTheCallNeverReachesTheMicrophone() {
        let rate = 16_000.0
        let far = S.speech(seconds: 20, rate: rate, seed: 31, level: 0.1)
        let near = S.speech(seconds: 20, rate: rate, seed: 32, level: 0.1)
        let mic = S.add(near, S.noise(count: far.count, level: 0.001, seed: 33))
        let estimator = EchoDelayEstimator(sampleRate: rate)
        var start = 0
        while start + estimator.frameSize <= far.count {
            estimator.add(reference: Array(far[start..<start + estimator.frameSize]), microphone: Array(mic[start..<start + estimator.frameSize]))
            start += estimator.frameSize
        }
        let estimate = try! XCTUnwrap(estimator.estimate())
        XCTAssertFalse(estimate.isEcho, "confidence \(estimate.confidence)")
    }

    /// Microphone at 44.1 kHz mono, call at 48 kHz stereo, both starting at different times.
    func testRemovesEchoAcrossSampleRatesChannelsAndOffsets() throws {
        let rate = 48_000.0
        let seconds = 24.0
        let far = S.speech(seconds: seconds, rate: rate, seed: 41, level: 0.1)
        let near = S.speech(seconds: seconds, rate: rate, seed: 42, level: 0.08, active: [3...6, 16...21])
        let echo = S.convolve(far, S.roomResponse(rate: rate, delay: 0.085, gain: 0.6, reverb: 0.3))
        let mic48 = S.add(echo, near, S.noise(count: far.count, level: 0.0007, seed: 43))
        // The call track starts 0.5 s after the microphone on the session timeline.
        let callOffset = Int(0.5 * rate)
        let callMono = Array(far[callOffset...])
        let call = ArraySampleSource(sampleRate: rate, channels: [callMono.map { $0 * 0.9 }, callMono.map { $0 * 1.1 }])
        let mic44 = S.convert(mic48, from: rate, to: 44_100)
        let mic = ArraySampleSource(sampleRate: 44_100, mono: mic44)
        let sink = ArraySampleSink()
        let report = try EchoRemover.run(microphone: mic, microphoneClock: .nominal(rate: 44_100, offset: 2),
                                         call: call, callClock: .nominal(rate: rate, offset: 2.5), sink: sink)
        XCTAssertEqual(report.outcome, .applied, report.detail ?? "")
        XCTAssertEqual(try XCTUnwrap(report.delay).delaySeconds, 0.085, accuracy: 0.002)
        let output = sink.samples
        let mic16 = S.convert(mic48, from: rate, to: 16_000)
        let near16 = S.convert(near, from: rate, to: 16_000)
        XCTAssertEqual(output.count, mic16.count, accuracy: 2)
        // Echo-only stretches, including the opening seconds thanks to the convergence pre-roll.
        for seconds in [0.8..<2.8, 7.0..<15.5, 21.5..<23.5] {
            let range = S.range(seconds, rate: 16_000)
            let erle = S.decibels(S.energy(mic16[range]) / S.energy(output[range]))
            XCTAssertGreaterThanOrEqual(erle, 20, "ERLE \(erle) dB over \(seconds)")
        }
        let doubleTalk = S.range(16.3..<20.7, rate: 16_000)
        XCTAssertGreaterThanOrEqual(S.correlation(output[doubleTalk], near16[doubleTalk]), 0.9)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(report.echoReturnLossEnhancementDB), 20)
    }

    /// The call device's clock runs 250 ppm fast against the host clock (and the microphone).
    func testMeasuresAndCorrectsSlowClockDrift() throws {
        let rate = 16_000.0
        let seconds = 60.0
        let drift = 250e-6
        let far = S.speech(seconds: seconds, rate: rate, seed: 51, level: 0.1)
        let near = S.speech(seconds: seconds, rate: rate, seed: 52, level: 0.08, active: [30...36])
        let mic = S.add(S.convolve(far, S.roomResponse(rate: rate, delay: 0.06, gain: 0.5)), near,
                        S.noise(count: far.count, level: 0.0005, seed: 53))
        // The call device delivered 16 000 × (1 + drift) frames per host second, labelled 16 kHz.
        let callSamples = S.convert(far, from: rate, to: rate * (1 + drift))
        var random = SplitMix64(seed: 54)
        let anchors = stride(from: 0, to: Int64(callSamples.count), by: 4_096).map { frame in
            ClockAnchor(frame: frame, hostTime: 100 + Double(frame) / (rate * (1 + drift)) + random.uniform(-0.0015...0.0015))
        }
        let fit = ClockDriftEstimator.fit(anchors: anchors, nominalRate: rate, sessionHostTime: 100, fallbackOffset: 0)
        XCTAssertEqual(fit.clock.driftPPM, 250, accuracy: 3)
        XCTAssertEqual(fit.clock.time(atFrame: 0), 0, accuracy: 0.001)

        func run(_ clock: TrackClock) throws -> (EchoRemovalReport, [Float]) {
            let sink = ArraySampleSink()
            let report = try EchoRemover.run(microphone: ArraySampleSource(sampleRate: rate, mono: mic), microphoneClock: .nominal(rate: rate, offset: 0),
                                             call: ArraySampleSource(sampleRate: rate, mono: callSamples), callClock: clock, sink: sink)
            return (report, sink.samples)
        }
        let (corrected, output) = try run(fit.clock)
        XCTAssertEqual(try XCTUnwrap(corrected.relativeDriftPPM), 250, accuracy: 3)
        let late = S.range(50..<59.5, rate: rate)
        let correctedERLE = S.decibels(S.energy(mic[late]) / S.energy(output[late]))
        let (_, uncorrectedOutput) = try run(.nominal(rate: rate, offset: 0))
        let uncorrectedERLE = S.decibels(S.energy(mic[late]) / S.energy(uncorrectedOutput[late]))
        XCTAssertGreaterThanOrEqual(correctedERLE, 20)
        // About 14 ms of accumulated drift defeats an uncorrected canceller (measured: ~51 vs ~8 dB).
        XCTAssertGreaterThan(correctedERLE, uncorrectedERLE + 10, "drift correction should help (\(correctedERLE) vs \(uncorrectedERLE) dB)")
    }

    func testClockFitSplitsAtResyncAndRejectsJitterOutliers() {
        let rate = 48_000.0
        var anchors: [ClockAnchor] = []
        for second in 0..<60 {
            let frame = Int64(Double(second) * rate * (1 + 80e-6))
            anchors.append(ClockAnchor(frame: frame, hostTime: 10 + Double(second) + (second == 20 ? 0.03 : 0)))
        }
        // After a device change at 60 s, a new clock 40 ppm slow, two seconds later on the timeline.
        let base = anchors.last!.frame + Int64(rate)
        for second in 0..<40 {
            anchors.append(ClockAnchor(frame: base + Int64(Double(second) * rate * (1 - 40e-6)), hostTime: 72 + Double(second), resync: second == 0))
        }
        let fit = ClockDriftEstimator.fit(anchors: anchors, nominalRate: rate, sessionHostTime: 10, fallbackOffset: 0)
        XCTAssertEqual(fit.clock.pieces.count, 2)
        XCTAssertEqual((fit.clock.pieces[0].framesPerSecond / rate - 1) * 1e6, 80, accuracy: 0.5)
        XCTAssertEqual((fit.clock.pieces[1].framesPerSecond / rate - 1) * 1e6, -40, accuracy: 0.5)
        XCTAssertEqual(fit.clock.time(atFrame: Double(base)), 62, accuracy: 0.0005)
        XCTAssertEqual(fit.clock.frame(atTime: 30), 20 * rate * (1 + 80e-6) + 10 * rate * (1 + 80e-6), accuracy: 2)
        XCTAssertEqual(fit.clock.driftPPM, 80, accuracy: 0.5)
    }

    func testSkipsWhenTheCallIsSilentOrNeverEchoes() throws {
        let rate = 16_000.0
        let near = S.speech(seconds: 12, rate: rate, seed: 61, level: 0.1)
        let silent = [Float](repeating: 0, count: near.count)
        let quiet = try EchoRemover.run(microphone: ArraySampleSource(sampleRate: rate, mono: near), microphoneClock: .nominal(rate: rate, offset: 0),
                                        call: ArraySampleSource(sampleRate: rate, mono: silent), callClock: .nominal(rate: rate, offset: 0),
                                        sink: ArraySampleSink())
        XCTAssertEqual(quiet.outcome, .skipped)
        XCTAssertEqual(quiet.skipReason, .callSilent)

        let far = S.speech(seconds: 12, rate: rate, seed: 62, level: 0.1)
        let headphones = try EchoRemover.run(microphone: ArraySampleSource(sampleRate: rate, mono: near), microphoneClock: .nominal(rate: rate, offset: 0),
                                             call: ArraySampleSource(sampleRate: rate, mono: far), callClock: .nominal(rate: rate, offset: 0),
                                             sink: ArraySampleSink())
        XCTAssertEqual(headphones.skipReason, .noEchoDetected)
        XCTAssertFalse(try XCTUnwrap(headphones.delay).isEcho)
    }

    /// Speakers for the first half, then a Bluetooth speaker with far more latency.
    func testDelayChangeMidCallStartsANewSegment() throws {
        let rate = 16_000.0
        let seconds = 64.0
        let far = S.speech(seconds: seconds, rate: rate, seed: 71, level: 0.1)
        let half = Int(32 * rate)
        let first = S.convolve(far, S.roomResponse(rate: rate, delay: 0.05, gain: 0.5, seed: 1))
        let second = S.convolve(far, S.roomResponse(rate: rate, delay: 0.23, gain: 0.5, seed: 2))
        let echo = (0..<far.count).map { $0 < half ? first[$0] : second[$0] }
        let mic = S.add(echo, S.noise(count: far.count, level: 0.0005, seed: 72))
        let sink = ArraySampleSink()
        let report = try EchoRemover.run(microphone: ArraySampleSource(sampleRate: rate, mono: mic), microphoneClock: .nominal(rate: rate, offset: 0),
                                         call: ArraySampleSource(sampleRate: rate, mono: far), callClock: .nominal(rate: rate, offset: 0), sink: sink)
        let segments = try XCTUnwrap(report.segments)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first!.delaySeconds, 0.05, accuracy: 0.002)
        XCTAssertEqual(segments.last!.delaySeconds, 0.23, accuracy: 0.002)
        for seconds in [5.0..<29.0, 36.0..<63.0] {
            let range = S.range(seconds, rate: rate)
            let erle = S.decibels(S.energy(mic[range]) / S.energy(sink.samples[range]))
            XCTAssertGreaterThanOrEqual(erle, 20, "ERLE \(erle) dB over \(seconds)")
        }
    }
}
