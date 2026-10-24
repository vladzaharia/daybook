import Accelerate
import Foundation

public struct EchoDelayEstimate: Codable, Equatable, Sendable {
    /// Seconds by which the echo in the microphone trails the call track. Negative means the call
    /// track's time stamps are later than the sound reaching the microphone.
    public var delaySeconds: Double
    /// Peak height over the correlation's background, in standard deviations. Echo-free pairs
    /// stay near 4–5; audible echo is far above `EchoDelayEstimator.echoThreshold`.
    public var confidence: Double
    /// One-second analysis frames that contributed.
    public var frames: Int
    public var isEcho: Bool { confidence >= EchoDelayEstimator.echoThreshold }

    public init(delaySeconds: Double, confidence: Double, frames: Int) {
        self.delaySeconds = delaySeconds; self.confidence = confidence; self.frames = frames
    }
}

/// Generalised cross-correlation with phase transform (GCC-PHAT) between the call track and the
/// microphone, accumulated over many frames where the call is audible. Phase weighting makes the
/// peak sharp despite room reverberation, speaker colouration, and level differences.
public final class EchoDelayEstimator {
    public static let echoThreshold = 9.0
    public let sampleRate: Double
    public let frameSize: Int
    public let maximumLead: Double
    public let maximumLag: Double
    public private(set) var frames = 0
    private let fft: RealFFT
    private let padded: FloatBuffer
    private let referenceSpectrum: Spectrum
    private let micSpectrum: Spectrum
    private let cross: Spectrum
    private let magnitude: FloatBuffer
    private let accumulated: Spectrum
    private let lowBin: Int, highBin: Int

    /// `frameSize` samples per call; the search covers −`maximumLead`…+`maximumLag` seconds.
    public init(sampleRate: Double, frameSize: Int = 16_384, maximumLead: Double = 0.25, maximumLag: Double = 0.8,
                band: ClosedRange<Double> = 200...4_000) {
        precondition(frameSize & (frameSize - 1) == 0)
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.maximumLead = maximumLead
        self.maximumLag = maximumLag
        fft = RealFFT(size: 2 * frameSize)
        padded = FloatBuffer(2 * frameSize)
        referenceSpectrum = Spectrum(bins: frameSize + 1)
        micSpectrum = Spectrum(bins: frameSize + 1)
        cross = Spectrum(bins: frameSize + 1)
        magnitude = FloatBuffer(frameSize + 1)
        accumulated = Spectrum(bins: frameSize + 1)
        let binWidth = sampleRate / Double(2 * frameSize)
        lowBin = max(1, Int(band.lowerBound / binWidth))
        highBin = min(frameSize, Int(band.upperBound / binWidth))
    }

    /// Adds one frame pair covering the same session time.
    public func add(reference: UnsafePointer<Float>, microphone: UnsafePointer<Float>) {
        padded.zero()
        memcpy(padded.pointer, reference, frameSize * MemoryLayout<Float>.size)
        fft.forward(padded.pointer, into: referenceSpectrum)
        padded.zero()
        memcpy(padded.pointer, microphone, frameSize * MemoryLayout<Float>.size)
        fft.forward(padded.pointer, into: micSpectrum)
        SpectralMath.conjugateMultiply(referenceSpectrum, micSpectrum, into: cross)
        let count = vDSP_Length(cross.bins)
        var split = cross.split
        vDSP_zvabs(&split, 1, magnitude.pointer, 1, count)
        var peak: Float = 0
        vDSP_maxv(magnitude.pointer, 1, &peak, count)
        guard peak > 0 else { return }
        // Phase transform (unit magnitude per bin) with a small floor relative to the strongest bin,
        // restricted to the speech band.
        var floor = peak * 1e-6, one: Float = 1
        vDSP_vsadd(magnitude.pointer, 1, &floor, magnitude.pointer, 1, count)
        vDSP_svdiv(&one, magnitude.pointer, 1, magnitude.pointer, 1, count)
        vDSP_vclr(magnitude.pointer, 1, vDSP_Length(lowBin))
        if highBin + 1 < cross.bins { vDSP_vclr(magnitude.pointer + highBin + 1, 1, vDSP_Length(cross.bins - highBin - 1)) }
        vDSP_vma(cross.real.pointer, 1, magnitude.pointer, 1, accumulated.real.pointer, 1, accumulated.real.pointer, 1, count)
        vDSP_vma(cross.imag.pointer, 1, magnitude.pointer, 1, accumulated.imag.pointer, 1, accumulated.imag.pointer, 1, count)
        frames += 1
    }

    public func add(reference: [Float], microphone: [Float]) {
        precondition(reference.count >= frameSize && microphone.count >= frameSize)
        reference.withUnsafeBufferPointer { r in
            microphone.withUnsafeBufferPointer { m in add(reference: r.baseAddress!, microphone: m.baseAddress!) }
        }
    }

    /// Adds another estimator's accumulated frames (same configuration).
    public func merge(_ other: EchoDelayEstimator) {
        precondition(other.frameSize == frameSize)
        SpectralMath.add(other.accumulated, into: accumulated)
        frames += other.frames
    }

    public func estimate() -> EchoDelayEstimate? {
        guard frames > 0 else { return nil }
        let size = 2 * frameSize
        let correlation = FloatBuffer(size)
        fft.inverse(accumulated, into: correlation.pointer)
        let lead = min(frameSize - 1, Int(maximumLead * sampleRate))
        let lag = min(frameSize - 1, Int(maximumLag * sampleRate))
        // Lags −lead…+lag in order; negative lags wrap to the end of the circular correlation.
        var values = [Float](repeating: 0, count: lead + lag + 1)
        for index in 0..<values.count {
            let tau = index - lead
            values[index] = correlation[tau >= 0 ? tau : size + tau]
        }
        guard let peakIndex = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
        let peak = Double(values[peakIndex])
        // Background statistics away from the peak and its immediate reflections (±5 ms).
        let guardBand = Int(0.005 * sampleRate)
        let background = values.indices.filter { abs($0 - peakIndex) > guardBand }.map { Double(values[$0]) }
        guard background.count > 10 else { return nil }
        let mean = background.reduce(0, +) / Double(background.count)
        let deviation = (background.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(background.count)).squareRoot()
        let confidence = deviation > 0 ? (peak - mean) / deviation : 0
        // Parabolic interpolation for a sub-sample peak.
        var refined = Double(peakIndex)
        if peakIndex > 0 && peakIndex < values.count - 1 {
            let left = Double(values[peakIndex - 1]), right = Double(values[peakIndex + 1])
            let curvature = left - 2 * peak + right
            if curvature < 0 { refined += 0.5 * (left - right) / curvature }
        }
        return EchoDelayEstimate(delaySeconds: (refined - Double(lead)) / sampleRate, confidence: confidence, frames: frames)
    }
}
