import Foundation

/// Voice embeddings for tests, without a model: a person is a pseudo-random unit vector, and a
/// recording of them is a vector with an exact cosine similarity to it. Deterministic by seed.
public enum SyntheticVoice {
    public static let dimensions = 64

    /// A person's voice.
    public static func person(_ seed: UInt64, dimensions: Int = SyntheticVoice.dimensions) -> [Float] {
        normalized(noise(seed &* 7919 &+ 17, dimensions: dimensions))
    }

    /// A vector whose cosine similarity to `voice` is `similarity`, in a direction set by `seed`.
    public static func near(_ voice: [Float], similarity: Double, seed: UInt64) -> [Float] {
        let base = normalized(voice)
        var other = noise(seed &* 104_729 &+ 3, dimensions: voice.count)
        let projection = zip(other, base).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        other = zip(other, base).map { Float(Double($0.0) - projection * Double($0.1)) }
        other = normalized(other)
        let rest = (1 - similarity * similarity).squareRoot()
        return zip(base, other).map { Float(similarity * Double($0.0) + rest * Double($0.1)) }
    }

    /// `voice` turned `degrees` further from `anchor`, in the plane they share.
    public static func turned(_ voice: [Float], awayFrom anchor: [Float], degrees: Double) -> [Float] {
        let a = normalized(anchor), v = normalized(voice)
        let along = zip(v, a).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let w = normalized(zip(v, a).map { Float(Double($0.0) - along * Double($0.1)) })
        let angle = acos(max(-1, min(1, along))) + degrees * .pi / 180
        return zip(a, w).map { Float(cos(angle) * Double($0.0) + sin(angle) * Double($0.1)) }
    }

    /// Halfway between two voices.
    public static func between(_ a: [Float], _ b: [Float]) -> [Float] {
        normalized(zip(normalized(a), normalized(b)).map { $0.0 + $0.1 })
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let na = a.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot(), nb = b.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        return dot / (na * nb)
    }

    private static func noise(_ seed: UInt64, dimensions: Int) -> [Float] {
        var state = seed | 1
        return (0..<dimensions).map { _ in
            // xorshift64*: deterministic on every machine.
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let value = state &* 2_685_821_657_736_338_717
            return Float(Double(value >> 11) / Double(1 << 53) * 2 - 1)
        }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        return vector.map { Float(Double($0) / norm) }
    }
}
