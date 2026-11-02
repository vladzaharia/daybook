import DaybookDesign
import DaybookKit
import SwiftUI

/// One change in Version History, the same on both apps: what it was before and after (a first summary on its own),
/// laid out as the page lays it out (`RevisionLayout`), bullets with the page's dot in their own column, and the
/// changed words marked over the text's own styling: removed words struck through on magenta, inserted words on mint.
public struct RevisionComparison: View {
    private let revision: MeetingRevision
    @Environment(\.colorScheme) private var scheme
    @Environment(\.daybookDensity) private var density

    public init(revision: MeetingRevision) { self.revision = revision }

    public var body: some View {
        let marked = RevisionLayout.marked(old: RevisionLayout(revision.oldValue, field: revision.field),
                                           new: RevisionLayout(revision.newValue, field: revision.field),
                                           removed: RevisionMarks.removed(dark: scheme == .dark),
                                           inserted: RevisionMarks.inserted(dark: scheme == .dark))
        VStack(alignment: .leading, spacing: DaybookSpacing.s5) {
            if RevisionText.hasBefore(revision) {
                version("Before", marked.old)
                version("After", marked.new)
            } else {
                version(nil, marked.new)
            }
        }
    }

    private func version(_ title: String?, _ layout: RevisionLayout) -> some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
            if let title {
                Text(title)
                    .font(DaybookFont.statusLead.font(density).weight(.semibold))
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            if layout.isEmpty {
                Text("Empty").italic().foregroundStyle(DaybookPalette.Ink.meta).font(DaybookFont.body.font(density))
            } else {
                RevisionTextBlocks(layout: layout)
            }
        }
    }
}

/// A version's blocks: paragraphs, headings at the page's semibold, and list items in a 16 pt hanging column, so a
/// wrapped line runs under its words.
struct RevisionTextBlocks: View {
    let layout: RevisionLayout
    @Environment(\.daybookDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(layout.blocks.enumerated()), id: \.offset) { _, block in
                Group {
                    switch block.kind {
                    case .paragraph:
                        text(block.text)
                    case .heading:
                        text(block.text).fontWeight(.semibold)
                    case .bullet:
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Circle().fill(DaybookPalette.accent.opacity(0.75)).frame(width: 5, height: 5)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                .frame(width: 16, alignment: .leading)
                                .accessibilityHidden(true)
                            text(block.text)
                        }
                    case .numbered(let marker):
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(marker).monospacedDigit().foregroundStyle(DaybookPalette.Ink.secondary)
                                .font(DaybookFont.body.font(density))
                                .frame(width: 16, alignment: .leading)
                            text(block.text)
                        }
                    }
                }
                .padding(.top, block.startsSection ? DaybookSpacing.s2 : 0)
            }
        }
        .textSelection(.enabled)
    }

    private func text(_ value: AttributedString) -> Text {
        Text(value)
            .font(DaybookFont.body.font(density))
            .foregroundStyle(DaybookPalette.Ink.body)
    }
}

/// How Version History marks changed words: removed in magenta, struck through; inserted washed in mint, and in Dark
/// Mode itself mint (over 10:1 on its wash).
public enum RevisionMarks {
    public static func removed(dark: Bool) -> AttributeContainer {
        var removed = AttributeContainer()
        removed.strikethroughStyle = Text.LineStyle(pattern: .solid, color: DaybookPalette.neonMagenta)
        removed.backgroundColor = DaybookPalette.neonMagenta.opacity(dark ? 0.20 : 0.16)
        return removed
    }

    public static func inserted(dark: Bool) -> AttributeContainer {
        var inserted = AttributeContainer()
        inserted.backgroundColor = DaybookPalette.neonMint.opacity(dark ? 0.22 : 0.16)
        if dark { inserted.foregroundColor = DaybookPalette.neonMint }
        return inserted
    }
}
