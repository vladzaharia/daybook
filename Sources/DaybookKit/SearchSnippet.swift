import Foundation

extension SearchHit {
    /// A search result's snippet as a row shows it, with its match: a summary's Markdown as words, without "- " list
    /// markers or "**" around them; anything else as it was found.
    public var displaySnippet: DisplaySnippet {
        guard field == .summary else { return DisplaySnippet(text: snippet, match: match) }
        let text = Self.plainText(fromMarkdown: snippet)
        let matched = match.map { String(snippet[$0]) }
        let range = matched.flatMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
        return DisplaySnippet(text: text, match: range)
    }

    /// The words a row shows and the range of the match within them.
    public struct DisplaySnippet: Equatable, Sendable {
        public var text: String
        public var match: Range<String.Index>?
    }

    /// Markdown from a summary, as it reads: emphasis marks and list markers (at the start, or where the lines were
    /// joined after a sentence) removed. The words themselves are untouched.
    public static func plainText(fromMarkdown markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        let marker = try? NSRegularExpression(pattern: "(^|^…|(?<=[.!?:;…])\\s)[-*•]\\s+")
        text = marker?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1") ?? text
        return text
    }
}

/// Where the library search's text appears in what's shown, for marking it on the page, in the transcript, and in
/// a row: every match, without regard to case or accents. Each app colours them its own way.
public enum FindRanges {
    /// The matches of `query` in `text`, in order; none for an empty query.
    public static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<text.endIndex) {
            ranges.append(range)
            cursor = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
        }
        return ranges
    }

    /// The same in styled text, so marking them keeps its other styles.
    public static func ranges(in text: AttributedString, query: String) -> [Range<AttributedString.Index>] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var ranges: [Range<AttributedString.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex, let range = text[cursor...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            ranges.append(range)
            guard range.upperBound > cursor else { break }
            cursor = range.upperBound
        }
        return ranges
    }
}
