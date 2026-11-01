import AppKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import SwiftUI

/// Renders the Markdown subset local models produce: paragraphs, bullet and numbered lists,
/// headings, and inline emphasis. `Text` alone only understands the inline part.
struct MarkdownText: View {
    let source: String
    @Environment(\.readingScale) private var scale
    @Environment(\.findQuery) private var query
    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Self.inline(text, highlighting: query)).font(TypeStyle.body(scale)).lineSpacing(TypeStyle.bodyLineSpacing(scale))
                        .padding(.bottom, 4 * scale)
                case .heading(let text):
                    Text(Self.inline(text, highlighting: query)).font(TypeStyle.heading(scale))
                case .item(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Group {
                            if marker == "•" {
                                Circle().fill(DaybookStyle.accent.opacity(0.75)).frame(width: 5 * scale, height: 5 * scale)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 * scale }
                            } else {
                                Text(marker).font(TypeStyle.body(scale).monospacedDigit()).foregroundStyle(Ink.secondary)
                            }
                        }
                        .frame(width: 16 * scale, alignment: .leading)
                        Text(Self.inline(text, highlighting: query)).font(TypeStyle.body(scale)).lineSpacing(TypeStyle.bodyLineSpacing(scale))
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    enum Block { case paragraph(String), heading(String), item(String, String) }

    static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = [], paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush() }
            else if let range = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item("•", String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item(line[..<range.upperBound].trimmingCharacters(in: .whitespaces), String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush(); blocks.append(.heading(String(line[range.upperBound...])))
            } else { paragraph.append(line) }
        }
        flush()
        return blocks
    }

    /// Inline Markdown from a model, with its links dropped (`ModelText.inlineMarkdown`).
    static func inline(_ text: String) -> AttributedString { ModelText.inlineMarkdown(text) }

    /// Inline Markdown with the library search's matches marked (DaybookDesign's `FindHighlight`), as
    /// transcript passages mark them.
    static func inline(_ text: String, highlighting query: String) -> AttributedString {
        FindHighlight.mark(inline(text), query: query)
    }
}

/// The library search's text, so the page can mark its matches.
struct FindQueryKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var findQuery: String {
        get { self[FindQueryKey.self] }
        set { self[FindQueryKey.self] = newValue }
    }
}
