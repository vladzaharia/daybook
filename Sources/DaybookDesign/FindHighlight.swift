import SwiftUI

/// Marks every match of the library search on the page and in the transcript, the same on both apps:
/// the opaque find shade behind it and dark ink on it, whatever ink the text around it is in, so a
/// match keeps its contrast on dark paper (docs/interface.md, principle 5).
public enum FindHighlight {
    public static func mark(_ text: AttributedString, query: String) -> AttributedString {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return text }
        var text = text
        var cursor = text.startIndex
        while cursor < text.endIndex, let range = text[cursor...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = DaybookPalette.findHighlight
            text[range].foregroundColor = DaybookPalette.Ink.onFind
            cursor = range.upperBound
        }
        return text
    }

    /// The ranges `mark` marks, for tests and for scrolling to the first.
    public static func matches(in text: AttributedString, query: String) -> [Range<AttributedString.Index>] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var ranges: [Range<AttributedString.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex, let range = text[cursor...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            ranges.append(range)
            cursor = range.upperBound
        }
        return ranges
    }
}
