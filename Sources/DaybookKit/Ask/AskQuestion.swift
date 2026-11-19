import Foundation

/// Whether what the person typed in the search field reads as a question, so Return asks it rather than only searching
/// (docs/interface.md, "Asking a question"). The rule is deliberately plain and the same every time:
///
/// - Text ending in a question mark is a question.
/// - Text that starts with a question word or an auxiliary verb ("what's" counts as what; who, what, when, where, why, how, did, do, does, is,
///   are, was, were, can, should) and has at least three words is a question; a shorter one ("how to", "do not") is a
///   search for those words.
/// - Nothing else is, and neither is text with no words in it. ⌘Return asks anything.
public enum AskQuestion {
    /// The words a question starts with.
    static let openers: Set<String> = ["who", "what", "when", "where", "why", "how", "did", "do", "does", "is", "are", "was", "were", "can", "should"]

    /// The fewest words a question without a question mark has.
    static let fewestWords = 3

    public static func readsAsQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "\u{2019}" }
        guard !words.isEmpty else { return false }
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("\u{FF1F}") { return true }
        guard words.count >= fewestWords, let first = words.first else { return false }
        var opener = first.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if opener.hasSuffix("'s") { opener.removeLast(2) }
        return openers.contains(opener)
    }
}

/// What the answer page and the search results' question row say (docs/interface.md, "Asking a question"). Status,
/// actions, and fixes only.
public enum AskPageWords {
    public static let allConversations = "All Conversations"
    public static let searching = "Searching…"
    public static let answering = "Answering…"
    public static let cancel = "Cancel"
    public static let askAgain = "Ask Again"
    public static let couldNotAnswer = "Couldn’t answer."
    public static let download = "Download"
    public static let downloadModel = "Download the summary model to ask."
    public static let sources = "Sources"
    public static let searchAll = "Search All"
    public static let closest = "Closest conversations"
    public static let play = "Play"
    public static let open = "Open"
    /// What a sentence's quoted words are: the words checked to be in the passage the sentence cites.
    public static let quoted = "Quoted"
    /// A question that waited too long behind another job.
    public static let modelBusy = "Another job is still using the model."

    /// "Waiting for “Weekly sync”", or without a name when the model is held by something that has none.
    public static func waiting(for job: String?) -> String {
        job.map { "Waiting for “\($0)”" } ?? "Waiting for another job"
    }

    public static func loading(_ fraction: Double) -> String { "Loading the model · \(Int((fraction * 100).rounded()))%" }

    /// The row at the top of the search results that asks the typed question.
    public static func askRow(_ question: String) -> String { "Ask “\(question)”" }

    /// "Answered on this Mac with Gemma 4 12B".
    public static func colophon(model: String?) -> String {
        model.map { "Answered on this Mac with \($0)" } ?? "Answered on this Mac"
    }

    /// A source's one line for a speaker: "Sam 14:22", "from your notes", "from a bookmark".
    public static func sourceMeta(_ citation: AskCitation) -> String {
        switch citation.kind {
        case .passage:
            let time = citation.time.map(timestamp)
            return [citation.speaker, time].compactMap { $0 }.joined(separator: " ")
        case .note: return AskWords.fromYourNotes
        case .bookmark: return AskWords.fromABookmark
        }
    }

    /// "14:22", or "1:02:03" past an hour.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// What VoiceOver reads for a source: "Source 1, Weekly product sync, Sam, 14 minutes 22 seconds".
    public static func spokenSource(number: Int, citation: AskCitation, untitled: String) -> String {
        var parts = ["Source \(number)", citation.conversationTitle ?? untitled]
        switch citation.kind {
        case .passage:
            if let speaker = citation.speaker { parts.append(speaker) }
            if let time = citation.time {
                let total = max(0, Int(time))
                parts.append(total >= 60 ? "\(total / 60) minutes \(total % 60) seconds" : "\(total) seconds")
            }
        case .note: parts.append(AskWords.fromYourNotes)
        case .bookmark: parts.append(AskWords.fromABookmark)
        }
        return parts.joined(separator: ", ")
    }

    /// How the question was read, when it named dates or people: "All Conversations · October 2026 · Sam"; nil when
    /// it named neither.
    public static func reading(scope: String?, query: AskQuery?) -> String? {
        var parts: [String] = []
        if let label = query?.dates?.label { parts.append(label) }
        if let people = query?.people, !people.isEmpty { parts.append(people.joined(separator: ", ")) }
        guard !parts.isEmpty else { return nil }
        if let scope { parts.insert(scope, at: 0) }
        return parts.joined(separator: " · ")
    }
}
