import XCTest
@testable import DaybookCore

final class EchoCancellerTests: XCTestCase {
    private let rate = 16_000.0
    typealias S = EchoTestSignals

    func testRealFFTRoundTripAndScaling() {
        let fft = RealFFT(size: 64)
        let input = FloatBuffer(64), output = FloatBuffer(64)
        for index in 0..<64 { input[index] = Float(sin(Double(index) * 2 * .pi * 5 / 64)) + 0.5 }
        let spectrum = Spectrum(bins: 33)
        fft.forward(input.pointer, into: spectrum)
        // DC is the sum of samples; a unit sine at bin 5 has magnitude N/2.
        XCTAssertEqual(spectrum.real[0], 32, accuracy: 1e-3)
        XCTAssertEqual(spectrum.imag[5], -32, accuracy: 1e-3)
        fft.inverse(spectrum, into: output.pointer)
        for index in 0..<64 { XCTAssertEqual(output[index], input[index], accuracy: 1e-5) }
    }

    /// Echo through a delayed, reverberant room with noise, then the near end talks over the call.
    func testCancellerRemovesEchoAndPreservesDoubleTalk() {
        let seconds = 30.0
        let far = S.speech(seconds: seconds, rate: rate, seed: 1, level: 0.1)
        let near = S.speech(seconds: seconds, rate: rate, seed: 2, level: 0.08, active: [18...26])
        let delay = 0.12, margin = 0.032
        let echo = S.convolve(far, S.roomResponse(rate: rate, delay: delay, gain: 0.5))
        let mic = S.add(echo, near, S.noise(count: far.count, level: 0.0005, seed: 3))
        let reference = S.shifted(far, by: Int((delay - margin) * rate))
        let canceller = EchoCanceller(configuration: .init(sampleRate: rate))
        let output = canceller.process(microphone: mic, reference: reference)

        let echoOnly = S.range(8..<17.5, rate: rate)
        let erle = S.decibels(S.energy(mic[echoOnly]) / S.energy(output[echoOnly]))
        let doubleTalk = S.range(18.5..<25.5, rate: rate)
        let correlation = S.correlation(output[doubleTalk], near[doubleTalk])
        let retention = S.decibels(S.energy(output[doubleTalk]) / S.energy(near[doubleTalk]))
        let micCorrelation = S.correlation(mic[doubleTalk], near[doubleTalk])
        print("ERLE \(erle) dB; double-talk correlation \(correlation) (mic \(micCorrelation)); retention \(retention) dB; stats \(canceller.statistics)")
        XCTAssertGreaterThanOrEqual(erle, 20)
        XCTAssertGreaterThanOrEqual(correlation, 0.9)
        XCTAssertGreaterThan(retention, -3)
        XCTAssertGreaterThan(canceller.statistics.doubleTalkBlocks, 0)
    }
}
