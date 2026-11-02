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

    /// Whether the result shows its snippet: a match in the title is marked in the title itself instead.
    public var showsSnippet: Bool { field != .title || match == nil }

    /// The match within the conversation's title as a row shows it (`title`), when the title is where it was.
    public func titleMatch(in title: String) -> Range<String.Index>? {
        guard field == .title, let match, !match.isEmpty else { return nil }
        return title.range(of: String(snippet[match]), options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// Where it was found, under the result, the same on both apps: "Title", "Summary", "Your notes", "Transcript ·
    /// Maya · 0:12", "Transcript · 3 matches", and "Conversation" for one found by its tags or people alone.
    public var location: String {
        switch field {
        case .title: return match == nil ? "Conversation" : "Title"
        case .summary: return "Summary"
        case .notes: return "Your notes"
        case .transcript:
            if matchCount > 1 { return "Transcript · \(matchCount) matches" }
            return (["Transcript", speaker, time.map(TimeLabel.short)].compactMap { $0 }).joined(separator: " · ")
        }
    }

    /// The location's glyph.
    public var locationSymbol: String {
        switch field {
        case .title: return "textformat"
        case .summary: return "text.alignleft"
        case .notes: return "note.text"
        case .transcript: return "quote.bubble"
        }
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
