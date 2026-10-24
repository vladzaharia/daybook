import Accelerate
import Foundation

public struct EchoCancellerConfiguration: Codable, Equatable, Sendable {
    /// Rate of both inputs. The canceller does not resample.
    public var sampleRate: Double
    /// Samples per block; the FFT is twice this. 256 at 16 kHz is 16 ms.
    public var blockSize: Int
    /// Filter partitions. The modelled echo tail is `blockSize × partitions` samples after the bulk delay.
    public var partitions: Int
    /// High-pass applied to both inputs before adaptation, removing DC and rumble.
    public var highPassCutoff: Double
    /// Runs the residual echo suppressor after the linear filter.
    public var residualSuppression: Bool
    /// Gain floor where only the call is heard.
    public var echoSuppressionDB: Double
    /// Gain floor while the near end is talking over the call, so local speech survives.
    public var doubleTalkSuppressionDB: Double
    /// Reverberation time assumed beyond the filter, which keeps suppressing the room's tail.
    public var tailReverbSeconds: Double

    public init(sampleRate: Double = 16_000, blockSize: Int = 256, partitions: Int = 16,
                highPassCutoff: Double = 80, residualSuppression: Bool = true,
                echoSuppressionDB: Double = -40, doubleTalkSuppressionDB: Double = -12,
                tailReverbSeconds: Double = 0.15) {
        self.sampleRate = sampleRate; self.blockSize = blockSize; self.partitions = partitions
        self.highPassCutoff = highPassCutoff; self.residualSuppression = residualSuppression
        self.echoSuppressionDB = echoSuppressionDB; self.doubleTalkSuppressionDB = doubleTalkSuppressionDB
        self.tailReverbSeconds = tailReverbSeconds
    }

    public var filterSeconds: Double { Double(blockSize * partitions) / sampleRate }
}

/// Running measurements a report can use. Energies are in the canceller's internal scale.
public struct EchoCancellerStatistics: Equatable, Sendable {
    public var blocks = 0
    /// Blocks in which the call was audible.
    public var farEndBlocks = 0
    /// Blocks in which the near end talked over the call.
    public var doubleTalkBlocks = 0
    /// Converged, call-only blocks: microphone energy in, output energy out.
    public var echoOnlyBlocks = 0
    public var echoOnlyInputEnergy: Double = 0
    public var echoOnlyOutputEnergy: Double = 0
    /// Times the protected (foreground) filter took the adapting filter's coefficients.
    public var foregroundUpdates = 0
    /// Times the adapting filter diverged and was reset to the protected one.
    public var backgroundResets = 0
    public var isAdapted = false
    public var leakEstimate: Double = 1

    /// Echo return loss enhancement over converged call-only blocks, in dB.
    public var echoReturnLossEnhancementDB: Double? {
        guard echoOnlyBlocks >= 10, echoOnlyInputEnergy > 0 else { return nil }
        return 10 * log10(echoOnlyInputEnergy / max(echoOnlyOutputEnergy, echoOnlyInputEnergy * 1e-9))
    }
    public var doubleTalkFraction: Double { farEndBlocks == 0 ? 0 : Double(doubleTalkBlocks) / Double(farEndBlocks) }
}

/// Acoustic echo canceller for offline use: a partitioned-block frequency-domain adaptive filter
/// (multidelay filter, after Soo & Pang and Valin's MDF) followed by a residual echo suppressor.
///
/// - Two filters run side by side. The background filter always adapts; the foreground filter,
///   which produces the output, only takes its coefficients when they are measurably better. If the
///   background diverges (for example during double talk) it is reset from the foreground.
/// - The learning rate is set per frequency bin from the estimated residual-echo-to-error ratio
///   (Valin 2007). When near-end speech dominates the error, the rate collapses, so talking over
///   the call does not train the filter on your voice. An echo-path change raises the measured
///   leakage instead, so the filter still re-converges.
/// - A double-talk detector compares the error with the predicted residual echo plus the noise
///   floor. While it fires, the suppressor relaxes its floor and stops over-subtracting.
/// - Proportionate per-partition rates speed up convergence for sparse room responses.
///
/// Inputs are mono floats in [−1, 1] at `configuration.sampleRate`. The reference must already be
/// shifted by the bulk delay so the echo falls inside the filter. The output lags the microphone by
/// `latency` samples when the suppressor is on.
public final class EchoCanceller {

    public let configuration: EchoCancellerConfiguration
    public private(set) var statistics = EchoCancellerStatistics()
    /// True while the most recent block was classified as double talk.
    public private(set) var isDoubleTalk = false
    public var latency: Int { configuration.residualSuppression ? blockSize : 0 }

    private let blockSize: Int, fftSize: Int, bins: Int, partitionCount: Int
    private let fft: RealFFT
    private let scale: Float = 32_768

    // Linear filter state
    private var micHighPass: HighPassFilter
    private var referenceHighPass: HighPassFilter
    private let input: FloatBuffer
    private let referenceFrame: FloatBuffer
    private var referenceSpectra: [Spectrum]
    private var head = 0
    private var background: [Spectrum]
    private var foreground: [Spectrum]
    private let accumulator: Spectrum
    private let gradient: Spectrum
    private let errorSpectrum: Spectrum
    private let timeFrame: FloatBuffer
    private let foregroundEcho: FloatBuffer, backgroundEcho: FloatBuffer, outputEcho: FloatBuffer
    private let foregroundError: FloatBuffer, backgroundError: FloatBuffer, outputError: FloatBuffer
    private let difference: FloatBuffer
    private let hann: FloatBuffer
    private let farPower: FloatBuffer, stepSizes: FloatBuffer
    private let errorPower: FloatBuffer, echoPower: FloatBuffer, referencePower: FloatBuffer
    private let errorHistory: FloatBuffer, echoHistory: FloatBuffer
    private let scratchA: FloatBuffer, scratchB: FloatBuffer
    private var proportions: [Float]
    private var davg1: Float = 0, davg2: Float = 0, dvar1: Float = 0, dvar2: Float = 0
    private var peyAverage: Float = 1, pyyAverage: Float = 1
    private var leak: Float = 1
    private var sumAdapt: Float = 0
    private var adapted = false
    private var saturation = 0

    // Residual suppressor state
    private let sqrtHann: FloatBuffer
    private let residualFrame: FloatBuffer
    private let outputFrame: FloatBuffer
    private let residualSpectrum: Spectrum
    private let residualPower: FloatBuffer
    private let tailPower: FloatBuffer
    private let previousClean: FloatBuffer
    private let gains: FloatBuffer
    private let overlap: FloatBuffer
    private let tailDecay: Float
    private var noiseFloor: Float = -1
    private var pendingClass: BlockClass = .other
    private var pendingInputEnergy: Float = 0

    private enum BlockClass { case echoOnly, other }

    public init(configuration: EchoCancellerConfiguration = .init()) {
        precondition(configuration.blockSize >= 16 && configuration.blockSize & (configuration.blockSize - 1) == 0)
        precondition(configuration.partitions >= 1)
        self.configuration = configuration
        blockSize = configuration.blockSize
        fftSize = 2 * blockSize
        bins = blockSize + 1
        partitionCount = configuration.partitions
        let binCount = configuration.blockSize + 1
        fft = RealFFT(size: 2 * configuration.blockSize)
        micHighPass = HighPassFilter(cutoff: configuration.highPassCutoff, sampleRate: configuration.sampleRate)
        referenceHighPass = HighPassFilter(cutoff: configuration.highPassCutoff, sampleRate: configuration.sampleRate)
        input = FloatBuffer(blockSize)
        referenceFrame = FloatBuffer(fftSize)
        referenceSpectra = (0..<configuration.partitions).map { _ in Spectrum(bins: binCount) }
        background = (0..<configuration.partitions).map { _ in Spectrum(bins: binCount) }
        foreground = (0..<configuration.partitions).map { _ in Spectrum(bins: binCount) }
        accumulator = Spectrum(bins: blockSize + 1)
        gradient = Spectrum(bins: blockSize + 1)
        errorSpectrum = Spectrum(bins: blockSize + 1)
        timeFrame = FloatBuffer(fftSize)
        foregroundEcho = FloatBuffer(blockSize); backgroundEcho = FloatBuffer(blockSize); outputEcho = FloatBuffer(blockSize)
        foregroundError = FloatBuffer(blockSize); backgroundError = FloatBuffer(blockSize); outputError = FloatBuffer(blockSize)
        difference = FloatBuffer(blockSize)
        hann = FloatBuffer(fftSize)
        sqrtHann = FloatBuffer(fftSize)
        for index in 0..<fftSize {
            let value = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(fftSize)))
            hann[index] = value
            sqrtHann[index] = value.squareRoot()
        }
        farPower = FloatBuffer(blockSize + 1); stepSizes = FloatBuffer(blockSize + 1)
        errorPower = FloatBuffer(blockSize + 1); echoPower = FloatBuffer(blockSize + 1); referencePower = FloatBuffer(blockSize + 1)
        errorHistory = FloatBuffer(blockSize + 1); echoHistory = FloatBuffer(blockSize + 1)
        scratchA = FloatBuffer(blockSize + 1); scratchB = FloatBuffer(blockSize + 1)
        residualFrame = FloatBuffer(fftSize)
        outputFrame = FloatBuffer(fftSize)
        residualSpectrum = Spectrum(bins: blockSize + 1)
        residualPower = FloatBuffer(blockSize + 1)
        tailPower = FloatBuffer(blockSize + 1)
        previousClean = FloatBuffer(blockSize + 1)
        gains = FloatBuffer(blockSize + 1)
        overlap = FloatBuffer(blockSize)
        let hop = Double(configuration.blockSize) / configuration.sampleRate
        tailDecay = Float(pow(10, -6 * hop / max(0.01, configuration.tailReverbSeconds)))
        // Initial proportionate rates favour early partitions, where most room energy arrives.
        let decay = Float(exp(-2.4 / Double(configuration.partitions)))
        var initial: [Float] = [0.7]
        for _ in 1..<max(1, configuration.partitions) { initial.append(initial.last! * decay) }
        let total = initial.reduce(0, +)
        proportions = initial.map { 0.8 * $0 / total }
        for index in 0..<stepSizes.count { stepSizes[index] = 1 }
    }

    /// Processes one block of `blockSize` samples. `output` receives `blockSize` samples.
    public func process(microphone: UnsafePointer<Float>, reference: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>) {
        statistics.blocks += 1
        let B = blockSize, N = fftSize, K = bins, P = partitionCount
        let length = vDSP_Length(B)
        var s = scale
        vDSP_vsmul(microphone, 1, &s, input.pointer, 1, length)
        var peak: Float = 0
        vDSP_maxmgv(input.pointer, 1, &peak, length)
        if peak >= 32_000 { saturation = P + 1 }
        micHighPass.process(input.pointer, count: B)
        memmove(referenceFrame.pointer, referenceFrame.pointer + B, B * MemoryLayout<Float>.size)
        vDSP_vsmul(reference, 1, &s, referenceFrame.pointer + B, 1, length)
        referenceHighPass.process(referenceFrame.pointer + B, count: B)

        // Reference spectrum for the newest partition (scaled by 1/N like Speex's MDF).
        head = (head + 1) % P
        let newest = referenceSpectra[head]
        fft.forward(referenceFrame.pointer, into: newest)
        SpectralMath.scale(newest, by: 1 / Float(N))
        let sxx = SpectralMath.energy(referenceFrame.pointer + B, count: B)

        // Echo estimates from both filters.
        filter(foreground, into: foregroundEcho)
        vDSP_vsub(foregroundEcho.pointer, 1, input.pointer, 1, foregroundError.pointer, 1, length)
        let sff = SpectralMath.energy(foregroundError.pointer, count: B)
        filter(background, into: backgroundEcho)
        vDSP_vsub(backgroundEcho.pointer, 1, input.pointer, 1, backgroundError.pointer, 1, length)
        var see = SpectralMath.energy(backgroundError.pointer, count: B)
        vDSP_vsub(backgroundEcho.pointer, 1, foregroundEcho.pointer, 1, difference.pointer, 1, length)
        let dbf = 10 + SpectralMath.energy(difference.pointer, count: B)

        // Two-path logic: promote the background when it is significantly better; back off when worse.
        let delta = sff - see
        davg1 = 0.6 * davg1 + 0.4 * delta
        davg2 = 0.85 * davg2 + 0.15 * delta
        dvar1 = 0.36 * dvar1 + 0.16 * sff * dbf
        dvar2 = 0.7225 * dvar2 + 0.0225 * sff * dbf
        outputEcho.copy(from: foregroundEcho)
        if delta * abs(delta) > sff * dbf || davg1 * abs(davg1) > 0.5 * dvar1 || davg2 * abs(davg2) > 0.25 * dvar2 {
            davg1 = 0; davg2 = 0; dvar1 = 0; dvar2 = 0
            for index in 0..<P { foreground[index].copy(from: background[index]) }
            statistics.foregroundUpdates += 1
            // Cross-fade so the switch does not click.
            vDSP_vmul(foregroundEcho.pointer, 1, hann.pointer + B, 1, outputEcho.pointer, 1, length)
            vDSP_vma(backgroundEcho.pointer, 1, hann.pointer, 1, outputEcho.pointer, 1, outputEcho.pointer, 1, length)
        } else if -delta * abs(delta) > 4 * sff * dbf || -davg1 * abs(davg1) > 4 * dvar1 || -davg2 * abs(davg2) > 4 * dvar2 {
            for index in 0..<P { background[index].copy(from: foreground[index]) }
            backgroundEcho.copy(from: foregroundEcho)
            backgroundError.copy(from: foregroundError)
            see = sff
            davg1 = 0; davg2 = 0; dvar1 = 0; dvar2 = 0
            statistics.backgroundResets += 1
        }
        vDSP_vsub(outputEcho.pointer, 1, input.pointer, 1, outputError.pointer, 1, length)

        // Statistics for the learning rate.
        let sey = SpectralMath.dot(backgroundError.pointer, backgroundEcho.pointer, count: B)
        let syy = SpectralMath.energy(backgroundEcho.pointer, count: B)
        let sdd = SpectralMath.energy(input.pointer, count: B)
        halfFrameSpectrum(backgroundError, into: errorSpectrum)
        SpectralMath.power(errorSpectrum, into: errorPower)
        halfFrameSpectrum(backgroundEcho, into: accumulator)
        SpectralMath.power(accumulator, into: echoPower)
        SpectralMath.power(newest, into: referencePower)
        let ss = 0.35 / Float(P)
        var decay = 1 - ss, gain = ss, one: Float = 1
        vDSP_vsmsa(farPower.pointer, 1, &decay, &one, farPower.pointer, 1, vDSP_Length(K))
        vDSP_vsma(referencePower.pointer, 1, &gain, farPower.pointer, 1, farPower.pointer, 1, vDSP_Length(K))
        updateLeakEstimate(syy: syy, see: see)
        var rer = (0.0001 * sxx + 3 * leak * syy) / max(see, 1)
        let lowerBound = sey * sey / (1 + see * syy)
        if rer < lowerBound { rer = lowerBound }
        if rer > 0.5 { rer = 0.5 }
        if !adapted && sumAdapt > Float(P) { adapted = true }
        let count = vDSP_Length(K)
        var ten: Float = 10
        // Denominator: smoothed far-end power + 10 (scratchB).
        vDSP_vsadd(farPower.pointer, 1, &ten, scratchB.pointer, 1, count)
        if adapted {
            // μ(k) = r(k) / (e(k) · (power(k) + 10)), with e = error power + 1 and
            // r = 0.7 · min(2 · leak · echo power, e / 2) + 0.3 · RER · e.
            var unit: Float = 1, half: Float = 0.5, leakGain = 2 * leak, seven: Float = 0.7, share = 0.3 * rer
            vDSP_vsadd(errorPower.pointer, 1, &unit, scratchA.pointer, 1, count)
            vDSP_vsmul(echoPower.pointer, 1, &leakGain, stepSizes.pointer, 1, count)
            vDSP_vsmul(scratchA.pointer, 1, &half, referencePower.pointer, 1, count)
            vDSP_vmin(stepSizes.pointer, 1, referencePower.pointer, 1, stepSizes.pointer, 1, count)
            vDSP_vsmul(stepSizes.pointer, 1, &seven, stepSizes.pointer, 1, count)
            vDSP_vsma(scratchA.pointer, 1, &share, stepSizes.pointer, 1, stepSizes.pointer, 1, count)
            vDSP_vmul(scratchB.pointer, 1, scratchA.pointer, 1, scratchB.pointer, 1, count)
            vDSP_vdiv(scratchB.pointer, 1, stepSizes.pointer, 1, stepSizes.pointer, 1, count)
        } else {
            var rate: Float = 0
            if sxx > Float(N) * 1_000 {
                rate = min(0.5 * sxx, 0.5 * see) / max(see, 1)
            }
            vDSP_svdiv(&rate, scratchB.pointer, 1, stepSizes.pointer, 1, count)
            sumAdapt += rate
        }

        // Adapt the background filter: constrained gradient, so each partition stays a linear convolution.
        if saturation > 0 {
            saturation -= 1
        } else {
            if adapted { adjustProportions() }
            for index in 0..<P {
                let partition = referenceSpectra[(head - index + P) % P]
                SpectralMath.conjugateMultiply(partition, errorSpectrum, into: gradient)
                SpectralMath.scale(gradient, by: stepSizes)
                SpectralMath.scale(gradient, by: proportions[index])
                SpectralMath.add(gradient, into: background[index])
                fft.inverse(background[index], into: timeFrame.pointer)
                vDSP_vclr(timeFrame.pointer + B, 1, length)
                fft.forward(timeFrame.pointer, into: background[index])
            }
        }

        classifyAndSuppress(sxx: sxx, sdd: sdd, output: output)
        statistics.isAdapted = adapted
        statistics.leakEstimate = Double(leak)
    }

    /// Takes the converged filters and adaptation state of `other` (same configuration) while keeping
    /// this canceller's signal history empty. Offline processing converges on a stretch of the recording
    /// first, then processes it from the start, so the opening seconds are not left with echo.
    public func adoptConvergedState(from other: EchoCanceller) {
        precondition(other.configuration == configuration)
        for index in 0..<partitionCount {
            background[index].copy(from: other.background[index])
            foreground[index].copy(from: other.foreground[index])
        }
        farPower.copy(from: other.farPower)
        stepSizes.copy(from: other.stepSizes)
        errorHistory.copy(from: other.errorHistory)
        echoHistory.copy(from: other.echoHistory)
        proportions = other.proportions
        peyAverage = other.peyAverage; pyyAverage = other.pyyAverage; leak = other.leak
        sumAdapt = other.sumAdapt; adapted = other.adapted
        noiseFloor = other.noiseFloor
    }

    /// Convenience for whole signals: returns the cleaned microphone, time-aligned with the input.
    public func process(microphone: [Float], reference: [Float]) -> [Float] {
        let count = microphone.count
        let B = blockSize
        let total = count + latency
        let blocks = (total + B - 1) / B
        var mic = microphone + [Float](repeating: 0, count: blocks * B - count)
        var ref = Array(reference.prefix(count)) + [Float](repeating: 0, count: blocks * B - min(count, reference.count))
        var result = [Float](repeating: 0, count: blocks * B)
        mic.withUnsafeMutableBufferPointer { micPointer in
            ref.withUnsafeMutableBufferPointer { refPointer in
                result.withUnsafeMutableBufferPointer { out in
                    for block in 0..<blocks {
                        process(microphone: micPointer.baseAddress! + block * B, reference: refPointer.baseAddress! + block * B,
                                output: out.baseAddress! + block * B)
                    }
                }
            }
        }
        return Array(result[latency..<(latency + count)])
    }

    // MARK: - Internals

    private func filter(_ weights: [Spectrum], into echo: FloatBuffer) {
        let P = partitionCount
        accumulator.zero()
        for index in 0..<P {
            SpectralMath.multiplyAccumulate(weights[index], referenceSpectra[(head - index + P) % P], into: accumulator)
        }
        fft.inverse(accumulator, into: timeFrame.pointer)
        // Overlap-save: the last half is the linear convolution. Undo the 1/N from the forward scaling.
        var n = Float(fftSize)
        vDSP_vsmul(timeFrame.pointer + blockSize, 1, &n, echo.pointer, 1, vDSP_Length(blockSize))
    }

    /// Spectrum of [zeros, signal], scaled by 1/N.
    private func halfFrameSpectrum(_ signal: FloatBuffer, into spectrum: Spectrum) {
        vDSP_vclr(timeFrame.pointer, 1, vDSP_Length(blockSize))
        memcpy(timeFrame.pointer + blockSize, signal.pointer, blockSize * MemoryLayout<Float>.size)
        fft.forward(timeFrame.pointer, into: spectrum)
        SpectralMath.scale(spectrum, by: 1 / Float(fftSize))
    }

    /// Linear regression of error-power fluctuations on echo-estimate fluctuations: the fraction of
    /// the estimated echo that still leaks into the output.
    private func updateLeakEstimate(syy: Float, see: Float) {
        let K = vDSP_Length(bins)
        let average = Float(blockSize) / Float(configuration.sampleRate)
        vDSP_vsub(errorHistory.pointer, 1, errorPower.pointer, 1, scratchA.pointer, 1, K)
        vDSP_vsub(echoHistory.pointer, 1, echoPower.pointer, 1, scratchB.pointer, 1, K)
        var pey = SpectralMath.dot(scratchA.pointer, scratchB.pointer, count: bins)
        var pyy = SpectralMath.energy(scratchB.pointer, count: bins)
        var rate = average
        vDSP_vsma(scratchA.pointer, 1, &rate, errorHistory.pointer, 1, errorHistory.pointer, 1, K)
        vDSP_vsma(scratchB.pointer, 1, &rate, echoHistory.pointer, 1, echoHistory.pointer, 1, K)
        pyy = pyy.squareRoot()
        pey = pyy > 0 ? pey / pyy : 0
        let beta0 = 2 * average, betaMax = 0.5 * average
        var alpha = beta0 * syy
        if alpha > betaMax * see { alpha = betaMax * see }
        alpha = see > 0 ? alpha / see : 0
        peyAverage = (1 - alpha) * peyAverage + alpha * pey
        pyyAverage = (1 - alpha) * pyyAverage + alpha * pyy
        if pyyAverage < 1 { pyyAverage = 1 }
        if peyAverage < 0.005 * pyyAverage { peyAverage = 0.005 * pyyAverage }
        if peyAverage > pyyAverage { peyAverage = pyyAverage }
        leak = peyAverage / pyyAverage
    }

    private func adjustProportions() {
        let P = partitionCount
        var norms = [Float](repeating: 0, count: P)
        var maxNorm: Float = 1
        for index in 0..<P {
            let total = 1 + SpectralMath.energy(background[index].real.pointer, count: bins)
                + SpectralMath.energy(background[index].imag.pointer, count: bins)
            norms[index] = total.squareRoot()
            maxNorm = max(maxNorm, norms[index])
        }
        var sum: Float = 1
        for index in 0..<P { norms[index] += 0.1 * maxNorm; sum += norms[index] }
        for index in 0..<P { proportions[index] = 0.99 * norms[index] / sum }
    }

    private func classifyAndSuppress(sxx: Float, sdd: Float, output: UnsafeMutablePointer<Float>) {
        let B = blockSize, N = fftSize, K = bins
        let farEndActive = sxx > Float(N) * 1_000
        let errorEnergy = SpectralMath.energy(outputError.pointer, count: B)
        let echoEnergy = SpectralMath.energy(outputEcho.pointer, count: B)
        if noiseFloor < 0 { noiseFloor = errorEnergy }
        noiseFloor = errorEnergy < noiseFloor ? errorEnergy : noiseFloor * 1.002 + 1e-3
        let nearEndActive: Bool
        if adapted {
            nearEndActive = errorEnergy > 4 * (leak * echoEnergy + noiseFloor) && errorEnergy > Float(B) * 100
        } else {
            // Before convergence the echo path gain is unknown; a microphone louder than the
            // reference itself means someone is talking locally.
            nearEndActive = sdd > sxx && sdd > 4 * noiseFloor && sdd > Float(B) * 100
        }
        isDoubleTalk = farEndActive && nearEndActive
        if farEndActive { statistics.farEndBlocks += 1 }
        if isDoubleTalk { statistics.doubleTalkBlocks += 1 }
        let currentClass: BlockClass = adapted && farEndActive && !nearEndActive ? .echoOnly : .other

        guard configuration.residualSuppression else {
            var inverse = 1 / scale
            vDSP_vsmul(outputError.pointer, 1, &inverse, output, 1, vDSP_Length(B))
            record(currentClass, inputEnergy: sdd, outputEnergy: errorEnergy)
            return
        }

        // Residual echo estimate: the echo actually removed once converged, the far end before.
        memmove(residualFrame.pointer, residualFrame.pointer + B, B * MemoryLayout<Float>.size)
        if adapted {
            memcpy(residualFrame.pointer + B, outputEcho.pointer, B * MemoryLayout<Float>.size)
        } else {
            memcpy(residualFrame.pointer, referenceFrame.pointer, N * MemoryLayout<Float>.size)
        }
        vDSP_vmul(residualFrame.pointer, 1, sqrtHann.pointer, 1, timeFrame.pointer, 1, vDSP_Length(N))
        fft.forward(timeFrame.pointer, into: residualSpectrum)
        SpectralMath.power(residualSpectrum, into: residualPower)
        var leakFactor = leak > 0.5 ? 1 : 2 * leak
        vDSP_vsmul(residualPower.pointer, 1, &leakFactor, residualPower.pointer, 1, vDSP_Length(K))
        var tail = tailDecay
        vDSP_vsmul(tailPower.pointer, 1, &tail, tailPower.pointer, 1, vDSP_Length(K))
        vDSP_vmax(tailPower.pointer, 1, residualPower.pointer, 1, tailPower.pointer, 1, vDSP_Length(K))

        // Error spectrum on the same analysis window.
        memmove(outputFrame.pointer, outputFrame.pointer + B, B * MemoryLayout<Float>.size)
        memcpy(outputFrame.pointer + B, outputError.pointer, B * MemoryLayout<Float>.size)
        vDSP_vmul(outputFrame.pointer, 1, sqrtHann.pointer, 1, timeFrame.pointer, 1, vDSP_Length(N))
        fft.forward(timeFrame.pointer, into: residualSpectrum)
        SpectralMath.power(residualSpectrum, into: errorPower)

        // Decision-directed signal-to-residual-echo estimate and Wiener gain.
        // ξ = 0.9 · previous clean power / echo + 0.1 · max(error / echo − 1, 0);  G = max(ξ / (1 + ξ), floor).
        var floor = Float(pow(10, (isDoubleTalk ? configuration.doubleTalkSuppressionDB : configuration.echoSuppressionDB) / 20))
        var overSubtraction: Float = isDoubleTalk ? 1 : 2, epsilon: Float = 1e-3
        var minusOne: Float = -1, zero: Float = 0, smoothing: Float = 0.9, rest: Float = 0.1, one: Float = 1
        let count = vDSP_Length(K)
        vDSP_vsmsa(tailPower.pointer, 1, &overSubtraction, &epsilon, scratchA.pointer, 1, count)        // echo
        vDSP_vdiv(scratchA.pointer, 1, errorPower.pointer, 1, scratchB.pointer, 1, count)               // posterior
        vDSP_vsadd(scratchB.pointer, 1, &minusOne, scratchB.pointer, 1, count)
        vDSP_vthr(scratchB.pointer, 1, &zero, scratchB.pointer, 1, count)
        vDSP_vdiv(scratchA.pointer, 1, previousClean.pointer, 1, gains.pointer, 1, count)               // clean / echo
        vDSP_vsmul(gains.pointer, 1, &smoothing, gains.pointer, 1, count)
        vDSP_vsma(scratchB.pointer, 1, &rest, gains.pointer, 1, gains.pointer, 1, count)                // prior ξ
        vDSP_vsadd(gains.pointer, 1, &one, scratchA.pointer, 1, count)
        vDSP_vdiv(scratchA.pointer, 1, gains.pointer, 1, gains.pointer, 1, count)                       // ξ / (1 + ξ)
        vDSP_vthr(gains.pointer, 1, &floor, gains.pointer, 1, count)
        vDSP_vsq(gains.pointer, 1, previousClean.pointer, 1, count)
        vDSP_vmul(previousClean.pointer, 1, errorPower.pointer, 1, previousClean.pointer, 1, count)
        SpectralMath.scale(residualSpectrum, by: gains)
        fft.inverse(residualSpectrum, into: timeFrame.pointer)
        vDSP_vmul(timeFrame.pointer, 1, sqrtHann.pointer, 1, timeFrame.pointer, 1, vDSP_Length(N))
        vDSP_vadd(timeFrame.pointer, 1, overlap.pointer, 1, output, 1, vDSP_Length(B))
        memcpy(overlap.pointer, timeFrame.pointer + B, B * MemoryLayout<Float>.size)
        let outputEnergy = SpectralMath.energy(output, count: B)
        // The suppressor's output belongs to the previous block.
        record(pendingClass, inputEnergy: pendingInputEnergy, outputEnergy: outputEnergy)
        pendingClass = currentClass
        pendingInputEnergy = sdd
        var inverse = 1 / scale
        vDSP_vsmul(output, 1, &inverse, output, 1, vDSP_Length(B))
    }

    private func record(_ blockClass: BlockClass, inputEnergy: Float, outputEnergy: Float) {
        guard blockClass == .echoOnly else { return }
        statistics.echoOnlyBlocks += 1
        statistics.echoOnlyInputEnergy += Double(inputEnergy)
        statistics.echoOnlyOutputEnergy += Double(outputEnergy)
    }
}
