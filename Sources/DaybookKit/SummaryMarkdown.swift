import Foundation
import Synchronization

/// A summary section's Markdown, split as both apps draw it: paragraphs, list items ("-", "*", "•", "1.", "1)"),
/// and headings. The iPhone's tap-through to evidence indexes these same lines, so one parser serves the page, the
/// transcript's evidence, and Version History on both apps. Inline Markdown inside a block is `ModelText.inlineMarkdown`.
public enum SummaryMarkdown {
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(String)
        /// A list item: "•" for a bullet, "1." or "2)" for a numbered one, and its text.
        case item(marker: String, text: String)

        public var text: String {
            switch self {
            case .paragraph(let text), .heading(let text), .item(_, let text): return text
            }
        }
    }

    /// `source`'s blocks, worked out once per source string: a page redrawn for the same summary doesn't parse it again.
    public static func blocks(_ source: String) -> [Block] {
        if let cached = cache.value(for: source) { return cached }
        let blocks = parse(source)
        cache.store(blocks, for: source)
        return blocks
    }

    /// The parse itself, uncached.
    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = [], paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush() }
            else if let range = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item(marker: "•", text: String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush()
                blocks.append(.item(marker: line[..<range.upperBound].trimmingCharacters(in: .whitespaces), text: String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush(); blocks.append(.heading(String(line[range.upperBound...])))
            } else { paragraph.append(line) }
        }
        flush()
        return blocks
    }

    private static let cache = BlockCache()

    /// A small memo of recent sources, safe from any thread. A summary's sections are few; it's emptied when full.
    private final class BlockCache: Sendable {
        private let entries = Mutex<[String: [Block]]>([:])
        private let limit = 256

        func value(for source: String) -> [Block]? { entries.withLock { $0[source] } }

        func store(_ blocks: [Block], for source: String) {
            entries.withLock { entries in
                if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
                entries[source] = blocks
            }
        }
    }
}
