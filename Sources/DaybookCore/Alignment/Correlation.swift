import Accelerate
import Foundation

/// Normalized cross-correlation of short windows of one feature track against another, using
/// vDSP real FFTs for wide lag ranges and direct dot products for narrow ones.
final class WindowCorrelator {
    private let reference: [Float]
    private let prefix: [Double]
    private let prefixSquares: [Double]
    private var setups: [Int: FFTSetup] = [:]
    private var wholeReference: (log2n: Int, real: [Float], imaginary: [Float])?

    init(reference: [Float]) {
        self.reference = reference
        var sum = [Double](repeating: 0, count: reference.count + 1)
        var squares = [Double](repeating: 0, count: reference.count + 1)
        reference.withUnsafeBufferPointer { values in
            for index in 0..<values.count {
                let value = Double(values[index])
                sum[index + 1] = sum[index] + value
                squares[index + 1] = squares[index] + value * value
            }
        }
        prefix = sum; prefixSquares = squares
    }

    deinit { for setup in setups.values { vDSP_destroy_fftsetup(setup) } }

    var count: Int { reference.count }

    /// Normalized correlation of `window` (any mean) with the reference at positions `range`, where
    /// position p compares window[k] with reference[p + k]. Values lie in -1...1; flat reference
    /// stretches score 0.
    func normalizedCorrelation(window input: ArraySlice<Float>, positions range: ClosedRange<Int>) -> [Float] {
        let length = input.count
        guard length > 1, range.lowerBound >= 0, range.upperBound + length <= reference.count else { return [] }
        var window = Array(input)
        var mean: Float = 0
        vDSP_meanv(window, 1, &mean, vDSP_Length(length))
        var negative = -mean
        vDSP_vsadd(window, 1, &negative, &window, 1, vDSP_Length(length))
        var energy: Float = 0
        vDSP_svesq(window, 1, &energy, vDSP_Length(length))
        let lags = range.count
        guard energy > 1e-12 else { return [Float](repeating: 0, count: lags) }
        var raw: [Float]
        if lags <= 96 {
            raw = [Float](repeating: 0, count: lags)
            reference.withUnsafeBufferPointer { values in
                for lag in 0..<lags {
                    vDSP_dotpr(window, 1, values.baseAddress! + range.lowerBound + lag, 1, &raw[lag], vDSP_Length(length))
                }
            }
        } else if lags > reference.count / 3 {
            raw = correlateWithWholeReference(window, positions: range)
        } else {
            let segment = Array(reference[range.lowerBound..<(range.upperBound + length)])
            raw = Array(correlate(window, segment).prefix(lags))
        }
        // Divide by the window norm and the reference's spread under the window at each position.
        let scales = inverseDeviations(length)
        var output = [Float](repeating: 0, count: lags)
        scales.withUnsafeBufferPointer { inverse in
            vDSP_vmul(raw, 1, inverse.baseAddress! + range.lowerBound, 1, &output, 1, vDSP_Length(lags))
        }
        var norm = 1 / energy.squareRoot()
        vDSP_vsmul(output, 1, &norm, &output, 1, vDSP_Length(lags))
        return output
    }

    private var inverseDeviationCache: [Int: [Float]] = [:]

    /// 1 / sqrt(Σ(x − mean)²) of every `length`-sample stretch of the reference (0 where flat).
    private func inverseDeviations(_ length: Int) -> [Float] {
        if let cached = inverseDeviationCache[length] { return cached }
        let positions = max(0, reference.count - length + 1)
        var sums = [Double](repeating: 0, count: positions), squares = [Double](repeating: 0, count: positions)
        prefix.withUnsafeBufferPointer { p in
            vDSP_vsubD(p.baseAddress!, 1, p.baseAddress! + length, 1, &sums, 1, vDSP_Length(positions))
        }
        prefixSquares.withUnsafeBufferPointer { p in
            vDSP_vsubD(p.baseAddress!, 1, p.baseAddress! + length, 1, &squares, 1, vDSP_Length(positions))
        }
        // variance·n = Σx² − (Σx)²/n
        var scale = -1 / Double(length)
        var meanSquares = [Double](repeating: 0, count: positions)
        vDSP_vsqD(sums, 1, &meanSquares, 1, vDSP_Length(positions))
        vDSP_vsmaD(meanSquares, 1, &scale, squares, 1, &squares, 1, vDSP_Length(positions))
        var result = [Float](repeating: 0, count: positions)
        squares.withUnsafeBufferPointer { values in
            for index in 0..<positions where values[index] > 1e-9 { result[index] = Float(1 / values[index].squareRoot()) }
        }
        inverseDeviationCache[length] = result
        return result
    }

    private func setup(_ log2n: Int) -> FFTSetup {
        if let existing = setups[log2n] { return existing }
        let created = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
        setups[log2n] = created
        return created
    }

    private static func log2Size(_ count: Int) -> Int {
        var log2n = 1
        while (1 << log2n) < count { log2n += 1 }
        return log2n
    }

    /// Real FFT in vDSP's packed split format (DC in real[0], Nyquist in imaginary[0]).
    private func spectrum(_ signal: [Float], log2n: Int) -> (real: [Float], imaginary: [Float]) {
        let n = 1 << log2n, half = n / 2
        var padded = [Float](repeating: 0, count: n)
        padded.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: signal, count: min(signal.count, n)) }
        var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
        let fft = setup(log2n)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            }
        }
        return (real, imaginary)
    }

    /// Circular correlation c[p] = Σ a[k]·b[p + k] from two spectra of the same size.
    private func correlate(spectrumA a: (real: [Float], imaginary: [Float]), spectrumB b: (real: [Float], imaginary: [Float]), log2n: Int) -> [Float] {
        let n = 1 << log2n, half = n / 2
        var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
        var output = [Float](repeating: 0, count: n)
        let fft = setup(log2n)
        a.real.withUnsafeBufferPointer { ar in a.imaginary.withUnsafeBufferPointer { ai in
            b.real.withUnsafeBufferPointer { br in b.imaginary.withUnsafeBufferPointer { bi in
                real.withUnsafeMutableBufferPointer { cr in imaginary.withUnsafeMutableBufferPointer { ci in
                    var sa = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: ar.baseAddress!), imagp: UnsafeMutablePointer(mutating: ai.baseAddress!))
                    var sb = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: br.baseAddress!), imagp: UnsafeMutablePointer(mutating: bi.baseAddress!))
                    var sc = DSPSplitComplex(realp: cr.baseAddress!, imagp: ci.baseAddress!)
                    // conj(A)·B; DC and Nyquist are real and packed into element 0.
                    vDSP_zvcmul(&sa, 1, &sb, 1, &sc, 1, vDSP_Length(half))
                    cr[0] = ar[0] * br[0]; ci[0] = ai[0] * bi[0]
                    vDSP_fft_zrip(fft, &sc, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Inverse))
                    output.withUnsafeMutableBytes { raw in
                        vDSP_ztoc(&sc, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                    }
                } }
            } }
        } }
        // vDSP's forward real FFT doubles each spectrum and the inverse multiplies by n.
        var scale = 1 / Float(4 * n)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(n))
        return output
    }

    private func correlate(_ window: [Float], _ segment: [Float]) -> [Float] {
        let log2n = Self.log2Size(segment.count)
        return correlate(spectrumA: spectrum(window, log2n: log2n), spectrumB: spectrum(segment, log2n: log2n), log2n: log2n)
    }

    private func correlateWithWholeReference(_ window: [Float], positions range: ClosedRange<Int>) -> [Float] {
        if wholeReference == nil {
            let log2n = Self.log2Size(reference.count)
            let transformed = spectrum(reference, log2n: log2n)
            wholeReference = (log2n, transformed.real, transformed.imaginary)
        }
        let whole = wholeReference!
        let full = correlate(spectrumA: spectrum(window, log2n: whole.log2n), spectrumB: (whole.real, whole.imaginary), log2n: whole.log2n)
        return Array(full[range])
    }
}

struct CorrelationPeak {
    var index: Int
    /// Sub-frame position from a parabola through the peak and its neighbours.
    var position: Double
    var value: Float
}

enum PeakPicker {
    /// Up to `count` maxima, each at least `separation` samples from the others.
    static func peaks(in curve: [Float], count: Int, separation: Int) -> [CorrelationPeak] {
        guard !curve.isEmpty else { return [] }
        var working = curve
        var result: [CorrelationPeak] = []
        for _ in 0..<count {
            var value: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(working, 1, &value, &index, vDSP_Length(working.count))
            guard value.isFinite, value > -1 else { break }
            let peak = Int(index)
            result.append(CorrelationPeak(index: peak, position: refine(curve, peak), value: curve[peak]))
            let lo = max(0, peak - separation), hi = min(working.count - 1, peak + separation)
            for position in lo...hi { working[position] = -.infinity }
        }
        return result
    }

    static func refine(_ curve: [Float], _ index: Int) -> Double {
        guard index > 0, index + 1 < curve.count else { return Double(index) }
        let left = Double(curve[index - 1]), center = Double(curve[index]), right = Double(curve[index + 1])
        let denominator = left - 2 * center + right
        guard denominator < -1e-12 else { return Double(index) }
        return Double(index) + max(-0.5, min(0.5, 0.5 * (left - right) / denominator))
    }

    /// How far the peak stands above the rest of the curve, in standard deviations, ignoring
    /// `exclusion` samples on each side of it.
    static func peakToSidelobe(_ curve: [Float], peak: Int, exclusion: Int) -> Double {
        let lo = max(0, peak - exclusion), hi = min(curve.count, peak + exclusion + 1)
        let outside = curve.count - (hi - lo)
        guard outside >= 32 else { return 0 }
        var total: Float = 0, totalSquares: Float = 0, inner: Float = 0, innerSquares: Float = 0
        curve.withUnsafeBufferPointer { values in
            vDSP_sve(values.baseAddress!, 1, &total, vDSP_Length(values.count))
            vDSP_svesq(values.baseAddress!, 1, &totalSquares, vDSP_Length(values.count))
            vDSP_sve(values.baseAddress! + lo, 1, &inner, vDSP_Length(hi - lo))
            vDSP_svesq(values.baseAddress! + lo, 1, &innerSquares, vDSP_Length(hi - lo))
        }
        let sum = Double(total - inner), squares = Double(totalSquares - innerSquares)
        let mean = sum / Double(outside)
        let deviation = max(1e-6, (squares / Double(outside) - mean * mean).squareRoot())
        return (Double(curve[peak]) - mean) / deviation
    }
}
