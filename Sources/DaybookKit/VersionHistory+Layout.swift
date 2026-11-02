import DaybookCore
import Foundation

/// A change's text as Version History lays it out on both apps. A summary is drawn as the page draws it, block by
/// block (`SummaryMarkdown`): its overview, each section's heading over its body, bullets and numbered items each in
/// their own row so a wrapped line hangs under its words, not under the bullet. Anything else is one paragraph, as it
/// was written. Each block's words carry their inline Markdown (bold, italics; links dropped).
public struct RevisionLayout: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        /// A section's heading, or a subheading inside its body: the page's semibold.
        case heading
        case bullet
        /// A numbered item, with its marker ("1.", "2)").
        case numbered(String)
    }

    public struct Block: Equatable, Sendable {
        public var kind: Kind
        public var text: AttributedString
        /// The first block of a summary section (its heading): the page leaves room above it.
        public var startsSection: Bool

        public init(kind: Kind, text: AttributedString, startsSection: Bool = false) {
            self.kind = kind
            self.text = text
            self.startsSection = startsSection
        }
    }

    public var blocks: [Block]

    public init(blocks: [Block]) { self.blocks = blocks }

    /// Nothing to show: an empty Before.
    public var isEmpty: Bool { blocks.allSatisfy { $0.text.characters.isEmpty } }

    /// `value` as Version History lays it out (`field` says what it is).
    public init(_ value: String, field: String) {
        guard let summary = Self.summary(value, field: field) else {
            self.init(blocks: [Block(kind: .paragraph, text: AttributedString(RevisionText.readable(value, field: field)))])
            return
        }
        var blocks: [Block] = []
        for block in SummaryMarkdown.blocks(summary.overview) { blocks.append(Self.block(block)) }
        for section in summary.sections {
            blocks.append(Block(kind: .heading, text: ModelText.inlineMarkdown(section.heading), startsSection: true))
            for block in SummaryMarkdown.blocks(section.body) { blocks.append(Self.block(block)) }
        }
        self.init(blocks: blocks)
    }

    /// Both versions with their changed words marked (`WordChanges`): removed words in `old` given `removed`,
    /// inserted words in `new` given `inserted`. Words are compared across the whole text, so a sentence that moved
    /// from one bullet to the next reads as moved; then each version is laid out again in its own blocks.
    public static func marked(old: RevisionLayout, new: RevisionLayout, removed: AttributeContainer,
                              inserted: AttributeContainer) -> (old: RevisionLayout, new: RevisionLayout) {
        let marked = WordChanges.marked(old: old.joined, new: new.joined, removed: removed, inserted: inserted)
        return (old.splitting(marked.old), new.splitting(marked.new))
    }

    /// The blocks' words in one text, a line break between blocks.
    var joined: AttributedString {
        var text = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { text += AttributedString("\n") }
            text += block.text
        }
        return text
    }

    /// The same blocks, their words taken from `text`: `joined` with marks added, so every block keeps its length.
    func splitting(_ text: AttributedString) -> RevisionLayout {
        guard text.characters.count == joined.characters.count else { return self }
        var result = self
        var cursor = text.startIndex
        for index in blocks.indices {
            if index > 0 { cursor = text.characters.index(after: cursor) }
            let end = text.characters.index(cursor, offsetBy: blocks[index].text.characters.count)
            result.blocks[index].text = AttributedString(text[cursor..<end])
            cursor = end
        }
        return result
    }

    private static func block(_ block: SummaryMarkdown.Block) -> Block {
        switch block {
        case .paragraph(let text): return Block(kind: .paragraph, text: ModelText.inlineMarkdown(text))
        case .heading(let text): return Block(kind: .heading, text: ModelText.inlineMarkdown(text))
        case .item(let marker, let text):
            return Block(kind: marker == "•" ? .bullet : .numbered(marker), text: ModelText.inlineMarkdown(text))
        }
    }

    /// A summary change, or the other version two devices' summaries left in history.
    private static func summary(_ value: String, field: String) -> MeetingSummary? {
        guard field == "summary" || field == "sync:summary", let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }
}
