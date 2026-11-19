import Foundation

/// The words Ask indexes and searches with, and the sentences its surfaces show (docs/architecture.md, "Ask across
/// conversations").
public enum AskWords {
    /// What an answer says when nothing in the library answers the question.
    public static let notFound = "Nothing here answers that."

    /// The same when the search was narrower than the whole library: "Nothing in Work answers that."
    public static func notFound(in place: String) -> String { "Nothing in \(place) answers that." }

    /// Under a partial answer: some of what the model wrote was left out because its quote wasn't in a passage, or the
    /// passages answer only part of the question. A fixed phrase: the model's own words about what is missing are never shown.
    public static let partial = "This answers only part of the question."

    /// What a citation of the person's own writing reads as, in place of a speaker.
    public static let fromYourNotes = "from your notes"
    public static let fromABookmark = "from a bookmark"

    /// The terms a text is searched by: `SummaryEvidenceIndex`'s words (lowercased, lightly stemmed, without common
    /// words), plus short numbers, a trailing "e" dropped so "decide" meets "decided" ("decid"), and without the
    /// words every question has.
    public static func terms(_ text: String) -> [String] {
        let words = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { word -> String in
                var value = String(word)
                if value.hasSuffix("'s") { value.removeLast(2) }
                return value.replacingOccurrences(of: "'", with: "")
            }
        return words.compactMap { word -> String? in
            guard word.count >= 3 || word.allSatisfy(\.isNumber) && !word.isEmpty else { return nil }
            var stem = SummaryEvidenceIndex.stem(word)
            if stem.count > 4, stem.hasSuffix("e") { stem.removeLast() }
            guard !SummaryEvidenceIndex.stopWords.contains(stem), !SummaryEvidenceIndex.stopWords.contains(word),
                  !questionWords.contains(word) else { return nil }
            return stem
        }
    }

    /// Words every question has, and what a person asks about the conversations rather than in them.
    static let questionWords: Set<String> = [
        "what", "whats", "who", "whom", "whose", "why", "how", "which", "tell", "give", "show", "find", "said", "says",
        "say", "told", "talk", "talked", "talks", "discuss", "discussed", "mention", "mentioned", "meeting", "meetings",
        "conversation", "conversations", "last", "this", "since", "during", "across", "ever", "anything", "everything",
    ]

    /// A name as it's compared: without case or accents.
    static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether two names are one person's: the same, or one a first name of the other ("Sam" and "Sam Rivera").
    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        let a = folded(lhs), b = folded(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let first = { (name: String) in name.split(separator: " ").first.map(String.init) ?? name }
        let single = a.contains(" ") != b.contains(" ")
        return single && first(a) == first(b)
    }
}
