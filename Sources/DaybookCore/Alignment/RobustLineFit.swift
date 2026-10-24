import Foundation

/// A timing measurement: at `time` (seconds in the other recording) the reference lagged by `lag`
/// seconds. `group` identifies the analysis window so one window counts once.
struct LagObservation {
    var time: Double
    var lag: Double
    var weight: Double
    var group: Int
}

/// `lag(t) = intercept + slope · t`, so `referenceTime = intercept + (1 + slope) · otherTime`.
struct LagLine: Equatable {
    var intercept: Double
    var slope: Double
    func lag(at time: Double) -> Double { intercept + slope * time }
}

enum RobustLineFit {
    struct Consensus {
        var line: LagLine
        var inliers: [LagObservation]
        var support: Double
        /// Support of the best hypothesis that disagrees by more than `distinctLag` seconds.
        var rivalSupport: Double
    }

    /// Exhaustive pair-hypothesis consensus (deterministic RANSAC). Hypotheses come from pairs of
    /// `primary` observations (each window's best peak); every observation can support one. A group
    /// (window) contributes at most once: its observation closest to the line.
    static func consensus(_ points: [LagObservation], primary: [Bool], tolerance: Double, maximumSlope: Double,
                          minimumSpan: Double, distinctLag: Double) -> Consensus? {
        guard !points.isEmpty, primary.count == points.count else { return nil }
        let times = points.map(\.time), lags = points.map(\.lag), weights = points.map(\.weight), groups = points.map(\.group)
        let groupCount = (groups.max() ?? 0) + 1
        let seeds = points.indices.filter { primary[$0] }
        var hypotheses: [LagLine] = seeds.map { LagLine(intercept: lags[$0], slope: 0) }
        for (position, i) in seeds.enumerated() {
            for j in seeds[(position + 1)...] where groups[j] != groups[i] {
                let span = times[j] - times[i]
                guard abs(span) >= minimumSpan else { continue }
                let slope = (lags[j] - lags[i]) / span
                guard abs(slope) <= maximumSlope else { continue }
                hypotheses.append(LagLine(intercept: lags[i] - slope * times[i], slope: slope))
            }
        }
        let middle = ((times.min() ?? 0) + (times.max() ?? 0)) / 2
        var bestResidual = [Double](repeating: .infinity, count: groupCount)
        var bestWeight = [Double](repeating: 0, count: groupCount)
        var supports = [Double](repeating: 0, count: hypotheses.count)
        var counts = [Int](repeating: 0, count: hypotheses.count)
        for (index, line) in hypotheses.enumerated() {
            for group in 0..<groupCount { bestResidual[group] = .infinity; bestWeight[group] = 0 }
            for point in 0..<times.count {
                let residual = abs(lags[point] - (line.intercept + line.slope * times[point]))
                if residual <= tolerance && residual < bestResidual[groups[point]] {
                    bestResidual[groups[point]] = residual; bestWeight[groups[point]] = weights[point]
                }
            }
            var support = 0.0, count = 0
            for group in 0..<groupCount where bestResidual[group].isFinite { support += bestWeight[group]; count += 1 }
            supports[index] = support; counts[index] = count
        }
        guard let winnerIndex = hypotheses.indices.max(by: {
            supports[$0] == supports[$1] ? counts[$0] < counts[$1] : supports[$0] < supports[$1]
        }), supports[winnerIndex] > 0 else { return nil }
        let winner = hypotheses[winnerIndex]
        var chosen: [Int: Int] = [:]
        for point in points.indices {
            let residual = abs(lags[point] - winner.lag(at: times[point]))
            guard residual <= tolerance else { continue }
            if let existing = chosen[groups[point]], abs(lags[existing] - winner.lag(at: times[existing])) <= residual { continue }
            chosen[groups[point]] = point
        }
        let inliers = chosen.values.sorted().map { points[$0] }
        let refined = leastSquares(inliers) ?? winner
        let rival = hypotheses.indices.filter { abs(hypotheses[$0].lag(at: middle) - winner.lag(at: middle)) > distinctLag }
            .map { supports[$0] }.max() ?? 0
        return Consensus(line: refined, inliers: inliers, support: supports[winnerIndex], rivalSupport: rival)
    }

    /// Weighted least squares; a single point (or no time spread) yields a constant lag.
    static func leastSquares(_ points: [LagObservation]) -> LagLine? {
        let total = points.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        let meanT = points.reduce(0) { $0 + $1.weight * $1.time } / total
        let meanL = points.reduce(0) { $0 + $1.weight * $1.lag } / total
        let spread = points.reduce(0) { $0 + $1.weight * pow($1.time - meanT, 2) }
        guard spread > 1e-9 else { return LagLine(intercept: meanL, slope: 0) }
        let slope = points.reduce(0) { $0 + $1.weight * ($1.time - meanT) * ($1.lag - meanL) } / spread
        return LagLine(intercept: meanL - slope * meanT, slope: slope)
    }

    /// Huber-weighted iteratively reweighted least squares: residuals beyond `delta` seconds get
    /// proportionally less influence, so a few wrong windows can't bend the line.
    static func huber(_ points: [LagObservation], start: LagLine, delta: Double, iterations: Int = 12) -> LagLine {
        var line = start
        for _ in 0..<iterations {
            let reweighted = points.map { point -> LagObservation in
                let residual = abs(point.lag - line.lag(at: point.time))
                var copy = point
                copy.weight = point.weight * (residual <= delta ? 1 : delta / residual)
                return copy
            }
            guard let next = leastSquares(reweighted) else { break }
            let converged = abs(next.intercept - line.intercept) < 1e-7 && abs(next.slope - line.slope) < 1e-10
            line = next
            if converged { break }
        }
        return line
    }
}
