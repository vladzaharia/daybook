import Accelerate
import Foundation

/// A fixed block of floats owned by DSP state. Pointer access keeps the per-block loops inside
/// vDSP even in debug builds, where Swift array indexing is slow.
final class FloatBuffer {
    let count: Int
    let pointer: UnsafeMutablePointer<Float>

    init(_ count: Int) {
        self.count = count
        pointer = .allocate(capacity: max(1, count))
        pointer.initialize(repeating: 0, count: max(1, count))
    }

    deinit { pointer.deallocate() }

    func zero() { vDSP_vclr(pointer, 1, vDSP_Length(count)) }
    func copy(from other: FloatBuffer) { memcpy(pointer, other.pointer, count * MemoryLayout<Float>.size) }
    subscript(index: Int) -> Float {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }
}

/// Split-complex spectrum with `bins` = N/2 + 1 entries. DC and Nyquist are stored as ordinary bins
/// with zero imaginary parts, so element-wise complex arithmetic needs no special cases.
final class Spectrum {
    let bins: Int
    let real: FloatBuffer
    let imag: FloatBuffer

    init(bins: Int) {
        self.bins = bins
        real = FloatBuffer(bins)
        imag = FloatBuffer(bins)
    }

    var split: DSPSplitComplex { DSPSplitComplex(realp: real.pointer, imagp: imag.pointer) }
    func zero() { real.zero(); imag.zero() }
    func copy(from other: Spectrum) { real.copy(from: other.real); imag.copy(from: other.imag) }
}

/// Real FFT of a power-of-two size with mathematical scaling:
/// `forward` returns X[k] = Σ x[n]·e^(−2πikn/N) and `inverse` returns x[n] = (1/N)·Σ X[k]·e^(2πikn/N).
final class RealFFT {
    let size: Int
    let bins: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let packedReal: FloatBuffer
    private let packedImag: FloatBuffer

    init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        bins = size / 2 + 1
        log2n = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP could not allocate an FFT of size \(size)")
        }
        self.setup = setup
        packedReal = FloatBuffer(size / 2)
        packedImag = FloatBuffer(size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func forward(_ input: UnsafePointer<Float>, into output: Spectrum) {
        let half = size / 2
        var split = DSPSplitComplex(realp: packedReal.pointer, imagp: packedImag.pointer)
        input.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        // vDSP's real forward transform is twice the mathematical DFT.
        var scale: Float = 0.5
        vDSP_vsmul(packedReal.pointer, 1, &scale, output.real.pointer, 1, vDSP_Length(half))
        vDSP_vsmul(packedImag.pointer, 1, &scale, output.imag.pointer, 1, vDSP_Length(half))
        output.real[half] = output.imag[0]
        output.imag[0] = 0
        output.imag[half] = 0
    }

    func inverse(_ input: Spectrum, into output: UnsafeMutablePointer<Float>) {
        let half = size / 2
        memcpy(packedReal.pointer, input.real.pointer, half * MemoryLayout<Float>.size)
        memcpy(packedImag.pointer, input.imag.pointer, half * MemoryLayout<Float>.size)
        packedImag[0] = input.real[half]
        var split = DSPSplitComplex(realp: packedReal.pointer, imagp: packedImag.pointer)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        output.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
            vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(half))
        }
        // The inverse of the packed mathematical spectrum is N times the signal.
        var scale = 1 / Float(size)
        vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(size))
    }
}

enum SpectralMath {
    /// accumulator += a · b
    static func multiplyAccumulate(_ a: Spectrum, _ b: Spectrum, into accumulator: Spectrum) {
        var x = a.split, y = b.split, z = accumulator.split
        vDSP_zvma(&x, 1, &y, 1, &z, 1, &z, 1, vDSP_Length(a.bins))
    }

    /// output = conj(a) · b
    static func conjugateMultiply(_ a: Spectrum, _ b: Spectrum, into output: Spectrum) {
        var x = a.split, y = b.split, z = output.split
        vDSP_zvcmul(&x, 1, &y, 1, &z, 1, vDSP_Length(a.bins))
    }

    /// output[k] = |a[k]|²
    static func power(_ a: Spectrum, into output: FloatBuffer) {
        var x = a.split
        vDSP_zvmags(&x, 1, output.pointer, 1, vDSP_Length(a.bins))
    }

    static func scale(_ spectrum: Spectrum, by value: Float) {
        var value = value
        vDSP_vsmul(spectrum.real.pointer, 1, &value, spectrum.real.pointer, 1, vDSP_Length(spectrum.bins))
        vDSP_vsmul(spectrum.imag.pointer, 1, &value, spectrum.imag.pointer, 1, vDSP_Length(spectrum.bins))
    }

    /// spectrum[k] *= weights[k] (real weights)
    static func scale(_ spectrum: Spectrum, by weights: FloatBuffer) {
        vDSP_vmul(spectrum.real.pointer, 1, weights.pointer, 1, spectrum.real.pointer, 1, vDSP_Length(spectrum.bins))
        vDSP_vmul(spectrum.imag.pointer, 1, weights.pointer, 1, spectrum.imag.pointer, 1, vDSP_Length(spectrum.bins))
    }

    static func add(_ a: Spectrum, into accumulator: Spectrum) {
        vDSP_vadd(a.real.pointer, 1, accumulator.real.pointer, 1, accumulator.real.pointer, 1, vDSP_Length(a.bins))
        vDSP_vadd(a.imag.pointer, 1, accumulator.imag.pointer, 1, accumulator.imag.pointer, 1, vDSP_Length(a.bins))
    }

    static func energy(_ pointer: UnsafePointer<Float>, count: Int) -> Float {
        var result: Float = 0
        vDSP_svesq(pointer, 1, &result, vDSP_Length(count))
        return result
    }

    static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(count))
        return result
    }
}

/// Second-order Butterworth high-pass, used to remove DC and rumble before adaptation.
struct HighPassFilter {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(cutoff: Double, sampleRate: Double) {
        let omega = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(omega) / (2 * 0.7071067811865476)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        b0 = Float((1 + cosine) / 2 / a0)
        b1 = Float(-(1 + cosine) / a0)
        b2 = b0
        a1 = Float(-2 * cosine / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for index in 0..<count {
            let input = samples[index]
            let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = input
            y2 = y1; y1 = output
            samples[index] = output
        }
        // Keep denormals out of the recursion during long digital silence.
        if abs(y1) < 1e-20 { y1 = 0 }
        if abs(y2) < 1e-20 { y2 = 0 }
    }
}
