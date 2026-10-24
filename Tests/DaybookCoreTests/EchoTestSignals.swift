import Accelerate
import AVFoundation
import Foundation
@testable import DaybookCore

/// Deterministic pseudo-random numbers for repeatable synthetic audio.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1) straight from the bits (much cheaper than `Double.random` in debug builds).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }
    mutating func uniform(_ range: ClosedRange<Double>) -> Double { range.lowerBound + unit() * (range.upperBound - range.lowerBound) }
    mutating func gaussian() -> Double {
        let u = max(unit(), 1e-12), v = unit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// Synthetic signals for echo tests. Nothing here records or downloads anything.
enum EchoTestSignals {
    /// Speech-like audio: syllables of voiced (pulse train) or unvoiced (noise) excitation through
    /// three formant resonators, with syllable envelopes, phrases, and pauses. `active` limits the
    /// talker to the given time ranges.
    static func speech(seconds: Double, rate: Double, seed: UInt64, level: Float = 0.1,
                       active: [ClosedRange<Double>]? = nil) -> [Float] {
        var random = SplitMix64(seed: seed)
        let count = Int(seconds * rate)
        var output = [Float](repeating: 0, count: count)
        var time = random.uniform(0...0.2)
        while time < seconds {
            let phraseEnd = time + random.uniform(1.5...3.5)
            while time < min(phraseEnd, seconds) {
                let duration = random.uniform(0.12...0.28)
                let start = Int(time * rate), length = min(Int(duration * rate), count - start)
                guard length > 0 else { break }
                let voiced = random.uniform(0...1) < 0.8
                let f0 = random.uniform(95...220)
                let formants = [random.uniform(300...850), random.uniform(900...2_300), random.uniform(2_400...3_300)]
                var filters = formants.map { Resonator(frequency: $0, bandwidth: random.uniform(70...160), rate: rate) }
                var syllable = [Float](repeating: 0, count: length)
                var phase = 0.0
                for index in 0..<length {
                    var excitation: Double
                    if voiced {
                        phase += (f0 * (1 + 0.1 * Double(index) / Double(length))) / rate
                        excitation = phase >= 1 ? 1 : 0
                        if phase >= 1 { phase -= 1 }
                        excitation += 0.05 * random.gaussian()
                    } else {
                        excitation = 0.4 * random.gaussian()
                    }
                    var sum = 0.0
                    for filter in filters.indices { sum += filters[filter].process(excitation) }
                    let envelope = sin(.pi * Double(index) / Double(length))
                    syllable[index] = Float(sum * envelope * envelope)
                }
                let rms = (syllable.map { Double($0 * $0) }.reduce(0, +) / Double(length)).squareRoot()
                let gain = rms > 0 ? Double(level) * random.uniform(0.6...1.0) / rms : 0
                for index in 0..<length { output[start + index] += Float(Double(syllable[index]) * gain) }
                time += duration + random.uniform(0.02...0.06)
            }
            time += random.uniform(0.25...0.6)
        }
        if let active {
            let fade = Int(0.02 * rate)
            for index in 0..<count {
                let t = Double(index) / rate
                guard let range = active.first(where: { $0.contains(t) }) else { output[index] = 0; continue }
                let edge = min(t - range.lowerBound, range.upperBound - t) * rate
                if edge < Double(fade) { output[index] *= Float(edge / Double(fade)) }
            }
        }
        return output
    }

    /// Direct path after `delay`, a few early reflections, and an exponentially decaying diffuse tail.
    static func roomResponse(rate: Double, delay: Double, gain: Float, reverb: Double = 0.25,
                             length: Double = 0.18, seed: UInt64 = 99) -> [Float] {
        var random = SplitMix64(seed: seed)
        let first = Int(delay * rate)
        var response = [Float](repeating: 0, count: first + Int(length * rate) + 1)
        response[first] = gain
        for _ in 0..<6 {
            let tap = first + Int(random.uniform(0.002...0.015) * rate)
            response[tap] += gain * Float(random.uniform(0.15...0.45)) * (random.uniform(0...1) < 0.5 ? -1 : 1)
        }
        let tailStart = first + Int(0.005 * rate)
        for index in tailStart..<response.count {
            let t = Double(index - tailStart) / rate
            response[index] += gain * 0.12 * Float(random.gaussian() * exp(-6.9 * t / reverb))
        }
        return response
    }

    /// Linear convolution truncated to the input length (FFT overlap-add).
    static func convolve(_ signal: [Float], _ response: [Float]) -> [Float] {
        let block = 4_096
        var size = 1
        while size < block + response.count - 1 { size <<= 1 }
        let fft = RealFFT(size: size)
        let frame = FloatBuffer(size)
        let responseSpectrum = Spectrum(bins: size / 2 + 1), blockSpectrum = Spectrum(bins: size / 2 + 1)
        let product = Spectrum(bins: size / 2 + 1)
        for index in 0..<response.count { frame[index] = response[index] }
        fft.forward(frame.pointer, into: responseSpectrum)
        var output = [Float](repeating: 0, count: signal.count + size)
        var start = 0
        while start < signal.count {
            frame.zero()
            for index in 0..<min(block, signal.count - start) { frame[index] = signal[start + index] }
            fft.forward(frame.pointer, into: blockSpectrum)
            product.zero()
            SpectralMath.multiplyAccumulate(blockSpectrum, responseSpectrum, into: product)
            fft.inverse(product, into: frame.pointer)
            for index in 0..<size { output[start + index] += frame[index] }
            start += block
        }
        return Array(output.prefix(signal.count))
    }

    static func noise(count: Int, level: Float, seed: UInt64) -> [Float] {
        var random = SplitMix64(seed: seed)
        return (0..<count).map { _ in Float(random.gaussian()) * level }
    }

    static func add(_ signals: [Float]...) -> [Float] {
        let count = signals.map(\.count).max() ?? 0
        var result = [Float](repeating: 0, count: count)
        for signal in signals { vDSP_vadd(signal, 1, result, 1, &result, 1, vDSP_Length(signal.count)) }
        return result
    }

    /// x delayed by `samples` (negative advances), keeping the length.
    static func shifted(_ signal: [Float], by samples: Int) -> [Float] {
        (0..<signal.count).map { index in
            let source = index - samples
            return source >= 0 && source < signal.count ? signal[source] : 0
        }
    }

    static func energy(_ signal: ArraySlice<Float>) -> Double {
        signal.withUnsafeBufferPointer { buffer in
            var sum: Double = 0
            let doubles = buffer.map(Double.init)
            vDSP_svesqD(doubles, 1, &sum, vDSP_Length(doubles.count))
            return sum
        }
    }

    static func decibels(_ ratio: Double) -> Double { 10 * log10(max(ratio, 1e-12)) }

    static func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Double {
        let x = a.map(Double.init), y = b.map(Double.init)
        let count = vDSP_Length(min(x.count, y.count))
        var ab = 0.0, aa = 0.0, bb = 0.0
        vDSP_dotprD(x, 1, y, 1, &ab, count); vDSP_svesqD(x, 1, &aa, count); vDSP_svesqD(y, 1, &bb, count)
        return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
    }

    static func range(_ seconds: Range<Double>, rate: Double) -> Range<Int> { Int(seconds.lowerBound * rate)..<Int(seconds.upperBound * rate) }
}

/// RBJ band-pass biquad (constant peak gain), used as a formant.
private struct Resonator {
    var b0: Double, b2: Double, a1: Double, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    init(frequency: Double, bandwidth: Double, rate: Double) {
        let omega = 2 * Double.pi * frequency / rate
        let q = frequency / bandwidth
        let alpha = sin(omega) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0; b2 = -alpha / a0
        a1 = -2 * cos(omega) / a0; a2 = (1 - alpha) / a0
    }
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

extension EchoTestSignals {
    /// Resamples with Apple's converter, independent of Daybook's resampler. A fractional output rate
    /// simulates a device clock that runs fast or slow.
    static func convert(_ signal: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: input, to: output)!
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(signal.count))!
        source.frameLength = AVAudioFrameCount(signal.count)
        signal.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: signal.count) }
        let capacity = AVAudioFrameCount(Double(signal.count) * outputRate / inputRate) + 4_096
        let destination = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)!
        var supplied = false
        var result: [Float] = []
        while true {
            destination.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: destination, error: &error) { _, outStatus in
                if supplied { outStatus.pointee = .endOfStream; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return source
            }
            result += Array(UnsafeBufferPointer(start: destination.floatChannelData![0], count: Int(destination.frameLength)))
            if status != .haveData || destination.frameLength == 0 { break }
        }
        let expected = Int((Double(signal.count) * outputRate / inputRate).rounded())
        return Array((result + [Float](repeating: 0, count: max(0, expected - result.count))).prefix(expected))
    }
}
