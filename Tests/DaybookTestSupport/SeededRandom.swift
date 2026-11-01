import Foundation

/// Random numbers that are the same for a seed on every machine and every run (SplitMix64), so synthetic recordings,
/// libraries, and edit sequences are identical each time. The one generator every test bundle shares.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1), straight from the top 53 bits (much cheaper than `Double.random` in debug builds).
    public mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }

    public mutating func uniform(_ range: ClosedRange<Double>) -> Double { range.lowerBound + unit() * (range.upperBound - range.lowerBound) }

    /// Standard normal (Box–Muller).
    public mutating func gaussian() -> Double {
        let u = max(unit(), 1e-12), v = unit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    /// In 0..<bound.
    public mutating func next(upTo bound: Int) -> Int { Int(next() % UInt64(bound)) }
}
