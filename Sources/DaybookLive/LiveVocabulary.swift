import Foundation
import Synchronization

/// The library's vocabulary (its approved terms) as live recognizers are biased toward it: names,
/// products, and jargon a streaming model would otherwise spell as it hears them. The apps keep it
/// current from the library; each running capture picks up a change before its next audio, so a term
/// approved during a recording helps the rest of it. Thread-safe.
public final class LiveVocabulary: Sendable {
    private let state: Mutex<(terms: [String], version: Int)>

    public init(terms: [String] = []) {
        state = Mutex((Self.normalized(terms), 0))
    }

    /// The terms and a number that changes whenever they do.
    public var current: (terms: [String], version: Int) { state.withLock { $0 } }

    /// Replaces the terms. Running captures apply them before their next audio.
    public func update(_ terms: [String]) {
        let normalized = Self.normalized(terms)
        state.withLock { state in
            guard normalized != state.terms else { return }
            state = (normalized, state.version + 1)
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
