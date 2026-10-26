import Foundation

/// Text a model wrote (summaries, action items, photo captions, transcripts) is untrusted: a
/// prompt-injected model can write a link that looks like part of the summary, or Markdown that makes
/// a Markdown reader fetch a URL carrying the summary.
public enum ModelText {
    /// Inline Markdown (bold, italics, code), keeping whitespace, for showing in the app. Links and
    /// image references are dropped; their text stays, as plain text.
    public static func inlineMarkdown(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let linked = attributed.runs.filter { $0.link != nil || $0.imageURL != nil }.map(\.range)
        for range in linked {
            attributed[range].link = nil
            attributed[range].imageURL = nil
        }
        return attributed
    }

    /// The characters that can start a link, an image, an autolink, raw HTML, or code: escaped, a
    /// Markdown viewer shows them as they are and fetches or links nothing.
    static let markdownSyntax: Set<Character> = ["\\", "[", "]", "(", ")", "!", "<", ">", "`"]

    /// Model text for a Markdown export or the clipboard. Emphasis, lists, and headings still work.
    public static func escapingMarkdown(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            if markdownSyntax.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
