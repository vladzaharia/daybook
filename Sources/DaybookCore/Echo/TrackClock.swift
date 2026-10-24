import Foundation

/// One host-clock observation made while recording: the track frame at which a buffer started and
/// the host time stamped on it. `resync` marks the first anchor after a discontinuity (a padded gap,
/// or a device or format change), where the device clock may have changed.
public struct ClockAnchor: Codable, Equatable, Sendable {
    public var frame: Int64
    public var hostTime: TimeInterval
    public var resync: Bool?
    public init(frame: Int64, hostTime: TimeInterval, resync: Bool? = nil) {
        self.frame = frame; self.hostTime = hostTime; self.resync = resync
    }
}

/// Maps a track's frames to seconds on the session timeline (host time minus the session anchor).
/// A device clock runs slightly fast or slow against the host clock; each piece carries the rate
/// measured for that stretch of the recording.
public struct TrackClock: Codable, Equatable, Sendable {
    public struct Piece: Codable, Equatable, Sendable {
        public var startFrame: Int64
        /// Session seconds at `startFrame`.
        public var startTime: TimeInterval
        /// Frames per session second actually delivered (the nominal rate corrected for drift).
        public var framesPerSecond: Double
        public init(startFrame: Int64, startTime: TimeInterval, framesPerSecond: Double) {
            self.startFrame = startFrame; self.startTime = startTime; self.framesPerSecond = framesPerSecond
        }
    }

    public var nominalRate: Double
    /// Sorted by frame; never empty.
    public var pieces: [Piece]
    /// Last frame the measurements cover, which bounds the final piece when weighing pieces.
    public var lastFrame: Int64?

    public init(nominalRate: Double, pieces: [Piece], lastFrame: Int64? = nil) {
        precondition(!pieces.isEmpty)
        self.nominalRate = nominalRate
        self.pieces = pieces.sorted { $0.startFrame < $1.startFrame }
        self.lastFrame = lastFrame
    }

    /// A clock with no drift: frame 0 at `offset` seconds.
    public static func nominal(rate: Double, offset: TimeInterval) -> TrackClock {
        TrackClock(nominalRate: rate, pieces: [Piece(startFrame: 0, startTime: offset, framesPerSecond: rate)])
    }

    public func time(atFrame frame: Double) -> TimeInterval {
        let piece = pieces.last { Double($0.startFrame) <= frame } ?? pieces[0]
        return piece.startTime + (frame - Double(piece.startFrame)) / piece.framesPerSecond
    }

    public func frame(atTime time: TimeInterval) -> Double {
        let piece = pieces.last { $0.startTime <= time } ?? pieces[0]
        return Double(piece.startFrame) + (time - piece.startTime) * piece.framesPerSecond
    }

    /// Session seconds per nominal track second over the longest piece: what to multiply a
    /// track-relative time by (after the offset) to land on the session timeline.
    public var rate: Double {
        let main = longestPiece
        return nominalRate / main.framesPerSecond
    }

    /// Drift of the longest piece against the host clock, in parts per million (positive: fast).
    public var driftPPM: Double { (longestPiece.framesPerSecond / nominalRate - 1) * 1_000_000 }

    private var longestPiece: Piece {
        var best = pieces[0], bestLength: Int64 = -1
        for (index, piece) in pieces.enumerated() {
            let end = index + 1 < pieces.count ? pieces[index + 1].startFrame : max(piece.startFrame, lastFrame ?? piece.startFrame)
            let length = end - piece.startFrame
            if length > bestLength { best = piece; bestLength = length }
        }
        return best
    }
}

/// Fits a `TrackClock` to host-time anchors.
public enum ClockDriftEstimator {
    public struct Fit: Equatable, Sendable {
        public var clock: TrackClock
        /// Root-mean-square timing error of the anchors against the fit, in seconds.
        public var residualRMS: TimeInterval
        /// Seconds of recording covered by anchors used in the fit.
        public var span: TimeInterval
    }

    /// Pieces shorter than this keep the nominal rate; drift cannot be measured reliably in seconds.
    public static let minimumMeasuredSpan: TimeInterval = 20
    /// Device clocks are within a few hundred ppm; anything larger is a timestamp fault, not drift.
    public static let plausibleDriftPPM: Double = 1_000

    /// `sessionHostTime` is the host time of the session anchor; the clock maps to seconds after it.
    public static func fit(anchors: [ClockAnchor], nominalRate: Double, sessionHostTime: TimeInterval,
                           fallbackOffset: TimeInterval) -> Fit {
        let sorted = anchors.filter { $0.hostTime.isFinite && $0.frame >= 0 }.sorted { $0.frame < $1.frame }
        guard !sorted.isEmpty, nominalRate > 0 else {
            return Fit(clock: .nominal(rate: nominalRate, offset: fallbackOffset), residualRMS: 0, span: 0)
        }
        var runs: [[ClockAnchor]] = []
        for anchor in sorted {
            if anchor.resync == true || runs.isEmpty { runs.append([anchor]) } else { runs[runs.count - 1].append(anchor) }
        }
        var pieces: [TrackClock.Piece] = []
        var squaredError = 0.0, observations = 0, span = 0.0
        for (index, run) in runs.enumerated() {
            let startFrame = index == 0 ? 0 : run[0].frame
            let duration = Double(run.last!.frame - run[0].frame) / nominalRate
            // A short stretch after a gap keeps the previous stretch's measured rate.
            var rate = pieces.last?.framesPerSecond ?? nominalRate
            var points = run.map { (frame: Double($0.frame), time: $0.hostTime - sessionHostTime) }
            if run.count >= 3 && duration >= minimumMeasuredSpan {
                // Two passes: the second drops anchors whose stamps jittered by more than 3σ (min 2 ms).
                for _ in 0..<2 {
                    guard let line = leastSquares(points), line.slope > 0 else { break }
                    let fitted = 1 / line.slope
                    guard abs(fitted / nominalRate - 1) * 1_000_000 <= plausibleDriftPPM else { break }
                    rate = fitted
                    let residuals = points.map { $0.time - (line.intercept + line.slope * $0.frame) }
                    let sigma = (residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count)).squareRoot()
                    let limit = max(0.002, 3 * sigma)
                    let kept = zip(points, residuals).filter { abs($0.1) <= limit }.map(\.0)
                    if kept.count == points.count || kept.count < 3 { break }
                    points = kept
                }
                span += duration
            }
            // Intercept: the median timing of this run's anchors under the chosen rate.
            let intercepts = points.map { $0.time - $0.frame / rate }.sorted()
            let intercept = intercepts[intercepts.count / 2]
            for point in points {
                let error = point.time - (intercept + point.frame / rate)
                squaredError += error * error
                observations += 1
            }
            pieces.append(.init(startFrame: startFrame, startTime: intercept + Double(startFrame) / rate, framesPerSecond: rate))
        }
        let rms = observations > 0 ? (squaredError / Double(observations)).squareRoot() : 0
        return Fit(clock: TrackClock(nominalRate: nominalRate, pieces: pieces, lastFrame: sorted.last?.frame), residualRMS: rms, span: span)
    }

    private static func leastSquares(_ points: [(frame: Double, time: Double)]) -> (intercept: Double, slope: Double)? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let meanX = points.map(\.frame).reduce(0, +) / n
        let meanY = points.map(\.time).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for point in points {
            let dx = point.frame - meanX
            sxx += dx * dx
            sxy += dx * (point.time - meanY)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        return (meanY - slope * meanX, slope)
    }
}
