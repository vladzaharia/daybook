import Foundation

/// Where one recording sits on another's timeline, found from the sound itself.
/// `referenceTime = offset + rate * otherTime`.
public struct AudioAlignment: Codable, Equatable, Sendable {
    /// Seconds to add to a time in the other recording to reach the reference recording's time.
    public var offset: TimeInterval
    /// Clock drift: reference seconds per second of the other recording (1 means none).
    public var rate: Double
    /// How sure the match is, from 0 to 1.
    public var confidence: Double
    public init(offset: TimeInterval, rate: Double = 1, confidence: Double) {
        self.offset = offset; self.rate = rate; self.confidence = confidence
    }
    /// Clock drift in parts per million: positive when the other recorder's clock runs slow.
    public var driftPPM: Double { (rate - 1) * 1_000_000 }
}

public struct AudioAlignmentOptions: Equatable, Sendable {
    /// Largest clock-rate difference considered. Consumer recorders are usually within ±100 ppm.
    public var maximumDriftPPM: Double
    /// Below this confidence `align` returns nil.
    public var minimumConfidence: Double
    /// Window length for the wide offset search, seconds.
    public var coarseWindow: TimeInterval
    /// Window length and spacing for the drift measurements, seconds.
    public var fineWindow: TimeInterval
    public var fineHop: TimeInterval
    /// Caps the wide-search work for long recordings; windows are spread over the whole file.
    public var maximumCoarseWindows: Int
    public init(maximumDriftPPM: Double = 1_000, minimumConfidence: Double = 0.15, coarseWindow: TimeInterval = 15,
                fineWindow: TimeInterval = 10, fineHop: TimeInterval = 5, maximumCoarseWindows: Int = 48) {
        self.maximumDriftPPM = maximumDriftPPM; self.minimumConfidence = minimumConfidence
        self.coarseWindow = coarseWindow; self.fineWindow = fineWindow; self.fineHop = fineHop
        self.maximumCoarseWindows = maximumCoarseWindows
    }
}

/// What the aligner measured, for diagnostics and the fusion report.
public struct AudioAlignmentReport: Equatable, Sendable {
    /// Nil when the recordings don't share enough sound, or confidence is below the minimum.
    public var alignment: AudioAlignment?
    /// The measured map and its confidence even when it was too weak to accept.
    public var candidate: AudioAlignment?
    /// Windows of the other recording compared across the whole search range, and how many agreed.
    public var coarseWindows: Int
    public var coarseInliers: Int
    /// Fine windows where both recordings have sound at the matched place, and how many matched.
    public var comparableWindows: Int
    public var matchedWindows: Int
    /// Median normalized correlation of the matched windows (0–1).
    public var medianPeak: Double
    /// Root-mean-square disagreement of matched windows with the fitted line, seconds.
    public var residual: TimeInterval?
    /// 0 when one timing clearly wins; near 1 when another, different timing fits almost as well.
    public var ambiguity: Double
    /// The span of the other recording that the reference also covers, in the other's seconds.
    public var overlap: ClosedRange<TimeInterval>?
    public var explanation: String
}

public enum AudioAligner {
    /// Stored with measurements so they can be redone when the method changes.
    public static let algorithmVersion = 1

    /// Aligns `other` against `reference` from their audio. `expectedOffset` is a prior from the
    /// recordings' clocks (nil when unknown); `searchRadius` bounds the search around it in seconds.
    /// Returns nil when the two recordings don't share enough sound to align. Runs synchronously and
    /// can take seconds for long recordings; call it off the main actor.
    ///
    /// Without `expectedOffset` (or with a radius that isn't a positive finite number) every
    /// placement where the recordings overlap is searched. Features are cached in
    /// `AudioFeatureCache.shared`, so aligning several sources against one reference decodes it once.
    public static func align(other: URL, reference: URL, expectedOffset: TimeInterval?,
                             searchRadius: TimeInterval) throws -> AudioAlignment? {
        try analyze(other: other, reference: reference, expectedOffset: expectedOffset, searchRadius: searchRadius).alignment
    }

    /// `align` with digests for cache keys, options, an explicit cache, and the full report.
    public static func analyze(other: URL, otherDigest: String? = nil, reference: URL, referenceDigest: String? = nil,
                               expectedOffset: TimeInterval?, searchRadius: TimeInterval,
                               options: AudioAlignmentOptions = .init(),
                               cache: AudioFeatureCache? = .shared) throws -> AudioAlignmentReport {
        let otherFeatures = try cache?.features(for: other, digest: otherDigest) ?? AudioFeatures.extract(from: other)
        try Task.checkCancellation()
        let referenceFeatures = try cache?.features(for: reference, digest: referenceDigest) ?? AudioFeatures.extract(from: reference)
        try Task.checkCancellation()
        return analyze(other: otherFeatures, reference: referenceFeatures, expectedOffset: expectedOffset,
                       searchRadius: searchRadius, options: options)
    }

    /// The alignment itself, on already extracted features.
    ///
    /// 1. Coarse: up to `maximumCoarseWindows` active 15-second windows of `other` are correlated
    ///    (normalized cross-correlation of onset envelopes, by FFT) against every allowed reference
    ///    position. Each window's three best peaks become timing observations.
    /// 2. Consensus: pair hypotheses (offset + drift, within `maximumDriftPPM`) are scored by how
    ///    many windows agree within 60 ms (deterministic RANSAC).
    /// 3. Fine: every 5 seconds along the overlap, a 10-second window is matched within ±0.2 s of the
    ///    consensus line, with sub-frame peak interpolation; a Huber fit gives offset and drift.
    /// 4. Confidence combines the number of matched windows, the share of comparable windows (both
    ///    recordings audible there) that matched, peak height, the margin over rival timings, and
    ///    the fit residual.
    public static func analyze(other: AudioFeatures, reference: AudioFeatures, expectedOffset: TimeInterval?,
                               searchRadius: TimeInterval, options: AudioAlignmentOptions = .init()) -> AudioAlignmentReport {
        let fps = AudioFeatures.frameRate
        let no = other.frameCount, nr = reference.frameCount
        var report = AudioAlignmentReport(alignment: nil, candidate: nil, coarseWindows: 0, coarseInliers: 0, comparableWindows: 0,
                                          matchedWindows: 0, medianPeak: 0, residual: nil, ambiguity: 1, overlap: nil,
                                          explanation: "")
        guard no >= Int(4 * fps), nr >= Int(4 * fps) else {
            report.explanation = "A recording is shorter than four seconds."
            return report
        }
        let maximumSlope = max(0, options.maximumDriftPPM) / 1_000_000
        let otherActivity = other.activityPrefix(), referenceActivity = reference.activityPrefix()
        func active(_ prefix: [Int32], _ start: Int, _ length: Int) -> Double {
            let lo = max(0, min(start, prefix.count - 1)), hi = max(lo, min(start + length, prefix.count - 1))
            return hi > lo ? Double(prefix[hi] - prefix[lo]) / Double(length) : 0
        }
        let lagBounds: ClosedRange<Double>
        if let expected = expectedOffset, expected.isFinite, searchRadius.isFinite, searchRadius > 0 {
            lagBounds = (expected - searchRadius)...(expected + searchRadius)
        } else {
            lagBounds = (-Double(no) / fps)...(Double(nr) / fps)
        }
        let correlator = WindowCorrelator(reference: reference.onset)

        // 1. Coarse observations.
        let coarseLength = min(no, nr, max(Int(3 * fps), min(Int(options.coarseWindow * fps), no / 2, nr / 2)))
        let coarseHop = max(1, coarseLength / 2)
        var starts = Array(stride(from: 0, through: no - coarseLength, by: coarseHop))
            .filter { active(otherActivity, $0, coarseLength) >= 0.15 }
        let limit = max(3, options.maximumCoarseWindows)
        if starts.count > limit {
            starts = (0..<limit).map { starts[$0 * (starts.count - 1) / (limit - 1)] }
        }
        var observations: [LagObservation] = []
        var primary: [Bool] = []
        for (group, start) in starts.enumerated() {
            let lo = max(0, start + Int((lagBounds.lowerBound * fps).rounded(.down)))
            let hi = min(nr - coarseLength, start + Int((lagBounds.upperBound * fps).rounded(.up)))
            guard hi >= lo else { continue }
            let curve = correlator.normalizedCorrelation(window: other.onset[start..<(start + coarseLength)], positions: lo...hi)
            let time = (Double(start) + Double(coarseLength) / 2) / fps
            for (rank, peak) in PeakPicker.peaks(in: curve, count: 3, separation: Int(0.3 * fps)).enumerated() where peak.value > 0.05 {
                let sharpness = curve.count >= 200 ? PeakPicker.peakToSidelobe(curve, peak: peak.index, exclusion: Int(0.5 * fps)) : 6
                let weight = Double(peak.value) * min(1, max(0, (sharpness - 3) / 4))
                guard weight > 0 else { continue }
                observations.append(LagObservation(time: time, lag: (Double(lo) + peak.position - Double(start)) / fps,
                                                   weight: weight, group: group))
                primary.append(rank == 0)
            }
        }
        report.coarseWindows = starts.count
        guard let consensus = RobustLineFit.consensus(observations, primary: primary, tolerance: 0.06, maximumSlope: maximumSlope,
                                                      minimumSpan: Double(coarseLength) / fps, distinctLag: 0.25),
              consensus.inliers.count >= 3 else {
            report.coarseInliers = 0
            report.explanation = "No timing was shared by three or more parts of the recording."
            return report
        }
        report.coarseInliers = consensus.inliers.count
        report.ambiguity = consensus.support > 0 ? min(1, consensus.rivalSupport / consensus.support) : 1

        // 3. Fine observations along the predicted overlap.
        let fineLength = min(coarseLength, max(Int(2 * fps), Int(options.fineWindow * fps)))
        let fineHop = max(1, min(fineLength / 2, Int(options.fineHop * fps)))
        let search = Int(0.2 * fps)
        var fine: [LagObservation] = []
        var comparable = 0
        var group = 0
        for start in stride(from: 0, through: no - fineLength, by: fineHop) {
            let time = (Double(start) + Double(fineLength) / 2) / fps
            let predicted = Double(start) + consensus.line.lag(at: time) * fps
            let lo = Int(predicted.rounded(.down)) - search, hi = Int(predicted.rounded(.up)) + search
            guard lo >= 0, hi + fineLength <= nr else { continue }
            guard active(otherActivity, start, fineLength) >= 0.15,
                  active(referenceActivity, Int(predicted.rounded()), fineLength) >= 0.15 else { continue }
            comparable += 1
            let curve = correlator.normalizedCorrelation(window: other.onset[start..<(start + fineLength)], positions: lo...hi)
            guard let peak = PeakPicker.peaks(in: curve, count: 1, separation: 1).first,
                  peak.index > 0, peak.index < curve.count - 1, peak.value >= 0.1 else { continue }
            fine.append(LagObservation(time: time, lag: (Double(lo) + peak.position - Double(start)) / fps,
                                       weight: Double(peak.value), group: group))
            group += 1
        }
        report.comparableWindows = comparable
        var line = RobustLineFit.huber(fine, start: consensus.line, delta: 0.01)
        var inliers = fine.filter { abs($0.lag - line.lag(at: $0.time)) <= 0.03 }
        if inliers.count >= 3 {
            line = RobustLineFit.huber(inliers, start: line, delta: 0.01)
            inliers = fine.filter { abs($0.lag - line.lag(at: $0.time)) <= 0.03 }
        }
        report.matchedWindows = inliers.count
        guard inliers.count >= 3, abs(line.slope) <= maximumSlope else {
            report.explanation = "Too few parts of the overlap matched closely."
            return report
        }
        let peaks = inliers.map(\.weight).sorted()
        report.medianPeak = peaks[peaks.count / 2]
        let rms = (inliers.reduce(0) { $0 + pow($1.lag - line.lag(at: $1.time), 2) } / Double(inliers.count)).squareRoot()
        report.residual = rms
        let rate = 1 + line.slope
        let otherEnd = Double(no) / fps, referenceEnd = Double(nr) / fps
        let first = max(0, -line.intercept / rate), last = min(otherEnd, (referenceEnd - line.intercept) / rate)
        if last > first { report.overlap = first...last }

        // 4. Confidence.
        let evidence = 1 - exp(-Double(inliers.count) / 6)
        let consistency = Double(inliers.count) / Double(max(comparable, inliers.count))
        let sharpness = min(1, max(0, (report.medianPeak - 0.1) / 0.35))
        let distinctness = 1 - report.ambiguity
        let precision = exp(-pow(rms / 0.025, 2))
        let confidence = evidence * (0.25 + 0.75 * consistency) * (0.35 + 0.65 * sharpness)
            * (0.4 + 0.6 * distinctness) * (0.5 + 0.5 * precision)
        let measured = AudioAlignment(offset: line.intercept, rate: rate, confidence: min(1, max(0, confidence)))
        report.candidate = measured
        let summary = "\(inliers.count) of \(comparable) comparable windows matched; drift \(String(format: "%.1f", measured.driftPPM)) ppm; residual \(String(format: "%.1f", rms * 1000)) ms."
        guard measured.confidence >= options.minimumConfidence else {
            report.explanation = "Weak match rejected. " + summary
            return report
        }
        report.alignment = measured
        report.explanation = summary
        return report
    }
}
