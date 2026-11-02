import DaybookDesign
import DaybookKit
import SwiftUI

/// A conversation in the Trash, on both apps: its title, when it was and how long, and Restore in sight. Its row
/// menu (and, on the iPhone, a swipe) offers Restore too; each app lists these from
/// `LibraryController.trashedMeetings()` and restores through `restoreFromTrash`.
public struct TrashRowView: View {
    private let meeting: Meeting
    private let restore: () -> Void
    @Environment(\.daybookDensity) private var density

    public init(meeting: Meeting, restore: @escaping () -> Void) {
        self.meeting = meeting
        self.restore = restore
    }

    private var onPaper: Bool { density != .window }

    public var body: some View {
        HStack(alignment: .center, spacing: DaybookSpacing.s3) {
            VStack(alignment: .leading, spacing: density == .touch ? 3 : 2) {
                Text(ConversationRowView.title(meeting))
                    .font(DaybookFont.rowTitle.font(density))
                    .foregroundStyle(onPaper ? AnyShapeStyle(DaybookPalette.Ink.title) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(Self.detail(meeting))
                    .font(DaybookFont.rowDetail.font(density))
                    .foregroundStyle(onPaper ? AnyShapeStyle(DaybookPalette.Ink.secondary) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(TrashWords.restore, action: restore)
                .buttonStyle(.daybookTinted)
                .controlSize(.small)
                .accessibilityLabel("\(TrashWords.restore) \(ConversationRowView.title(meeting))")
        }
        .padding(.vertical, density == .touch ? 4 : 6)
        .accessibilityAction(named: TrashWords.restore, restore)
    }

    /// "Sep 3, 2026 at 10:15 AM · 28 min".
    static func detail(_ meeting: Meeting) -> String {
        [meeting.date.formatted(date: .abbreviated, time: .shortened), meeting.duration.map(DurationLabel.format)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The words the Trash shares between its row, its menus, and its page.
public enum TrashWords {
    public static let restore = "Restore"
    public static let restoreSymbol = "arrow.uturn.backward"
    /// The page's box over a conversation in the Trash.
    public static let inTheTrash = "In the Trash"
}

/// A conversation in the Trash, read only, with Restore: the Mac's page beside the Trash's list. Its title and
/// when, then what it was about (the gist, the next steps, your notes), so it can be told apart before it's put back.
public struct TrashedConversationPage: View {
    private let meeting: Meeting
    private let restore: () -> Void
    @Environment(\.daybookDensity) private var density

    public init(meeting: Meeting, restore: @escaping () -> Void) {
        self.meeting = meeting
        self.restore = restore
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DaybookSpacing.s4) {
                AttentionBox(kind: .info, title: TrashWords.inTheTrash, symbol: "trash", message: nil) {
                    Button(TrashWords.restore, action: restore).buttonStyle(.daybookProminent)
                }
                VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                    Text(ConversationRowView.title(meeting))
                        .font(DaybookFont.docTitle.font(density))
                        .foregroundStyle(DaybookPalette.Ink.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(TrashRowView.detail(meeting))
                        .font(DaybookFont.byline.font(density))
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                }
                if let summary = meeting.summary {
                    if !summary.overview.isEmpty {
                        Text(ModelText.inlineMarkdown(summary.overview))
                            .font(DaybookFont.lede.font(density))
                            .foregroundStyle(DaybookPalette.Ink.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !summary.actionItems.isEmpty {
                        section("Next steps") {
                            ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                                bullet(item.text, done: item.completed)
                            }
                        }
                    }
                    ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, part in
                        section(part.heading) {
                            ForEach(Array(SummaryMarkdown.blocks(part.body).enumerated()), id: \.offset) { _, block in
                                switch block {
                                case .item(_, let text): bullet(text, done: false)
                                case .paragraph(let text), .heading(let text): body(text)
                                }
                            }
                        }
                    }
                }
                let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !notes.isEmpty {
                    section("Your notes") { body(notes) }
                }
            }
            .frame(maxWidth: ReadingGeometry.measure, alignment: .leading)
            .padding(.horizontal, DaybookSpacing.s5)
            .padding(.vertical, DaybookSpacing.s6)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .background(DaybookPalette.paper)
    }

    private func section(_ heading: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
            Text(heading)
                .font(DaybookFont.heading.font(density))
                .foregroundStyle(DaybookPalette.Ink.body)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, DaybookSpacing.s3)
    }

    private func body(_ text: String) -> some View {
        Text(ModelText.inlineMarkdown(text))
            .font(DaybookFont.body.font(density))
            .foregroundStyle(DaybookPalette.Ink.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
            Text(done ? "✓" : "•").foregroundStyle(DaybookPalette.Ink.meta).accessibilityHidden(true)
            Text(ModelText.inlineMarkdown(text))
                .foregroundStyle(done ? DaybookPalette.Ink.secondary : DaybookPalette.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(DaybookFont.body.font(density))
    }
}
