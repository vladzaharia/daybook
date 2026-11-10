import DaybookDesign
import DaybookKit
import SwiftUI

/// A conversation in the Trash, on both apps: its title, when it was and how long, and Restore in sight. Its row
/// menu (and, on the iPhone, a swipe) offers Restore too; each app lists these from
/// `LibraryController.trashedMeetings()` and restores through `restoreFromTrash`. While the Personal lock hides it,
/// it's "Personal conversation", as a list's row is.
public struct TrashRowView: View {
    private let meeting: Meeting
    private let restore: () -> Void
    private let show: (() -> Void)?
    @Environment(\.daybookDensity) private var density
    @Environment(PersonalLock.self) private var personalLock: PersonalLock?

    /// `show`: a tap on its words shows it read only beside the list, where the list's selection doesn't (the
    /// iPhone's two pages); the Mac's Trash selects the row instead.
    public init(meeting: Meeting, restore: @escaping () -> Void, show: (() -> Void)? = nil) {
        self.meeting = meeting
        self.restore = restore
        self.show = show
    }

    private var onPaper: Bool { density != .window }
    private var hidden: Bool { personalLock?.hides(meeting) == true }
    private var title: String { hidden ? PersonalLockWords.hiddenTitle : ConversationRowView.title(meeting) }

    public var body: some View {
        HStack(alignment: .center, spacing: DaybookSpacing.s3) {
            if let show {
                Button(action: show) { words }.buttonStyle(.plain)
            } else {
                words
            }
            Button(TrashWords.restore, action: restore)
                .buttonStyle(.daybookTinted)
                .controlSize(.small)
                .accessibilityLabel("\(TrashWords.restore) \(title)")
        }
        .padding(.vertical, density == .touch ? 4 : 6)
        .accessibilityAction(named: TrashWords.restore, restore)
    }

    /// Its title and when, up to Restore.
    private var words: some View {
        VStack(alignment: .leading, spacing: density == .touch ? 3 : 2) {
            Text(title)
                .font(DaybookFont.rowTitle.font(density))
                .foregroundStyle(hidden ? onPaper ? AnyShapeStyle(DaybookPalette.Ink.secondary) : AnyShapeStyle(.secondary)
                                 : onPaper ? AnyShapeStyle(DaybookPalette.Ink.title) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Text(Self.detail(meeting))
                .font(DaybookFont.rowDetail.font(density))
                .foregroundStyle(onPaper ? AnyShapeStyle(DaybookPalette.Ink.secondary) : AnyShapeStyle(.secondary))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
    /// The page's status for a conversation in the Trash, with Restore.
    public static let inTheTrash = "In the Trash"
}

/// A conversation in the Trash, read only, with Restore: the Mac's page beside the Trash's list. Its title and byline,
/// "In the Trash" with Restore under them where every page's status sits, then what it was about (the gist, the next
/// steps, your notes), so it can be told apart before it's put back. A Personal one the lock hides stays shut, with
/// Unlock (`LockedConversationPage`).
public struct TrashedConversationPage: View {
    private let meeting: Meeting
    private let restore: () -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(PersonalLock.self) private var personalLock: PersonalLock?

    public init(meeting: Meeting, restore: @escaping () -> Void) {
        self.meeting = meeting
        self.restore = restore
    }

    public var body: some View {
        if let personalLock, personalLock.hides(meeting) {
            LockedConversationPage { Task { await personalLock.unlock() } }
        } else {
            page
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DaybookSpacing.s4) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: density == .touch ? DaybookSpacing.s2 : 6) {
                        Text(ConversationRowView.title(meeting))
                            .font(DaybookFont.docTitle.font(density))
                            .foregroundStyle(DaybookPalette.Ink.title)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(Self.bylineText(meeting))
                            .font(DaybookFont.byline.font(density))
                            .foregroundStyle(DaybookPalette.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Self.byline(meeting).joined(separator: ", "))
                    }
                    TrashStatusLine(restore: restore)
                        .padding(.top, DaybookSpacing.s5)
                }
                if let summary = meeting.summary {
                    if !summary.overview.isEmpty {
                        Text(ModelText.inlineMarkdown(summary.overview))
                            .font(DaybookFont.lede.font(density))
                            .foregroundStyle(DaybookPalette.Ink.body)
                            .lineSpacing(DaybookFont.ledeLineSpacing(density))
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
            .frame(maxWidth: ReadingGeometry.measure(density), alignment: .leading)
            .padding(.horizontal, DaybookSpacing.s5)
            .padding(.vertical, DaybookSpacing.s6)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .background(DaybookPalette.paper)
    }

    /// The page's byline in its words (`ConversationHeader`): how long, when, in the byline's date format, and who.
    static func byline(_ meeting: Meeting) -> [String] {
        let lead = meeting.duration.map(DurationLabel.format) ?? (meeting.presentTracks.isEmpty ? "Notes only" : nil)
        let date = meeting.date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).hour().minute())
        return [lead, date, meeting.peopleLine].compactMap { $0 }
    }

    /// The byline's parts with the page's separators between them, in meta ink.
    private static func bylineText(_ meeting: Meeting) -> AttributedString {
        var separator = AttributedString("  ·  ")
        separator.foregroundColor = DaybookPalette.Ink.meta
        return byline(meeting).map(AttributedString.init).reduce(into: AttributedString()) { text, part in
            if !text.characters.isEmpty { text += separator }
            text += part
        }
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

/// "In the Trash" with Restore, drawn as a page's status line is: its glyph in the status column, the words in secondary
/// ink, and Restore 16 pt after them.
private struct TrashStatusLine: View {
    let restore: () -> Void
    @Environment(\.daybookDensity) private var density

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: density == .touch ? DaybookSpacing.s2 : 6) {
            Image(systemName: "trash")
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .frame(width: density == .touch ? 20 : 18)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s4) {
                Text(TrashWords.inTheTrash).foregroundStyle(DaybookPalette.Ink.secondary)
                Button(TrashWords.restore, action: restore)
                    .buttonStyle(.daybookLink)
                    .fontWeight(.medium)
            }
        }
        .daybookFont(.status)
    }
}
