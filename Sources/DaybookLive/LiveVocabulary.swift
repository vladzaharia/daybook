import Foundation

/// The library's vocabulary (its approved terms) as live recognizers are biased toward it: names,
/// products, and jargon a streaming model would otherwise spell as it hears them. The apps keep it
/// current from the library; each running capture picks up a change before its next audio, so a term
/// approved during a recording helps the rest of it. Thread-safe.
public final class LiveVocabulary: @unchecked Sendable {
    private let lock = NSLock()
    private var terms: [String] = []
    private var version = 0

    public init(terms: [String] = []) {
        self.terms = Self.normalized(terms)
    }

    /// The terms and a number that changes whenever they do.
    public var current: (terms: [String], version: Int) { lock.withLock { (terms, version) } }

    /// Replaces the terms. Running captures apply them before their next audio.
    public func update(_ terms: [String]) {
        let normalized = Self.normalized(terms)
        lock.withLock {
            guard normalized != self.terms else { return }
            self.terms = normalized
            version += 1
        }
    }

    /// Trimmed, without blanks, each spelling once (the first, case aside), in the library's order.
    /// At most `limit`: a recognizer biased toward thousands of terms over-fires.
    static func normalized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            result.append(text)
            if result.count == limit { break }
        }
        return result
    }

    /// The most terms a capture is biased toward.
    public static let limit = 500
}
