import DaybookDesign
import DaybookKit
import SwiftUI

/// How a summary block leads to what was said, in each app: `show` brings the passage into view (turning a column to
/// the transcript, or scrolling the transcript beside the page); with two pages side by side a tap on the block does
/// it (`onTap`), and otherwise it's in the block's menu, so reading never jumps away.
public struct PassageLinks {
    public var show: @MainActor (_ segmentID: UUID) -> Void
    public var onTap: Bool

    public init(onTap: Bool = false, show: @escaping @MainActor (_ segmentID: UUID) -> Void) {
        self.onTap = onTap
        self.show = show
    }

    /// Nowhere to go: previews and tests.
    public static let none = PassageLinks { _ in }
}

/// The page's blocks, for an app that scrolls to them.
public enum SummaryBlock: Hashable, Sendable {
    case lede, nextSteps, section(UUID), notesHeading
}

/// The summary on a conversation's page, the same on both apps: what happened (the lede), the next steps, and the
/// template's sections, ending at the "Your notes" heading. Its Markdown is a model's, read once per source
/// (`SummaryMarkdown`, `ModelText.inlineMarkdown`, links dropped), with the library search's matches marked in the
/// lede, the next steps, the sections, and their headings. Each line leads to its passage (`SummaryEvidenceIndex`).
/// A summary that arrives while the page is open fades up block by block (`revealing`).
public struct SummaryBody<Photos: View>: View {
    private let meeting: Meeting
    private let summary: MeetingSummary
    private let library: LibraryController
    private let query: String
    private let revealing: Bool
    private let passages: PassageLinks
    private let blockID: (SummaryBlock) -> String?
    private let photos: (SummarySection) -> Photos
    @State private var shown = false
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale

    /// - Parameters:
    ///   - query: The library search's text, whose matches are marked.
    ///   - revealing: The summary arrived while the page was open.
    ///   - blockID: Each block's scroll ID, for an app that scrolls to them.
    ///   - photos: A section's photos, after its text.
    public init(meeting: Meeting, summary: MeetingSummary, library: LibraryController, query: String = "", revealing: Bool = false,
                passages: PassageLinks = .none, blockID: @escaping (SummaryBlock) -> String? = { _ in nil },
                @ViewBuilder photos: @escaping (SummarySection) -> Photos) {
        self.meeting = meeting
        self.summary = summary
        self.library = library
        self.query = query
        self.revealing = revealing
        self.passages = passages
        self.blockID = blockID
        self.photos = photos
    }

    private var sections: [SummarySection] {
        summary.sections.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var body: some View {
        let evidence = SummaryEvidenceIndex.cached(for: meeting)
        let offset = summary.actionItems.isEmpty ? 1 : 2
        VStack(alignment: .leading, spacing: 0) {
            MarginRow {
                EvidenceLink(text: summary.overview, segment: segment(evidence.segment(for: summary.overview)), passages: passages) {
                    Text(FindHighlight.mark(ModelText.inlineMarkdown(summary.overview), query: query))
                        .daybookFont(.lede)
                        .foregroundStyle(DaybookPalette.Ink.body)
                        .lineSpacing(DaybookFont.bodyLineSpacing(density, scale: scale))
                        .fixedSize(horizontal: false, vertical: true)
                        .selectableInWindow()
                }
            }
            .padding(.top, DaybookSpacing.s5)
            .blockID(blockID(.lede))
            .summaryReveal(index: 0, revealing: revealing, shown: shown)
            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SummaryHeading(text: "Next steps", query: query)
                    VStack(alignment: .leading, spacing: density == .touch ? DaybookSpacing.s3 : DaybookSpacing.s2) {
                        ForEach(summary.actionItems) { item in
                            NextStepRow(item: item, meeting: meeting, library: library, query: query,
                                        segment: segment(evidence.segment(for: item.text, owner: item.owner)), passages: passages)
                        }
                    }
                    .padding(.top, density == .touch ? DaybookSpacing.s3 : DaybookSpacing.s2)
                }
                .blockID(blockID(.nextSteps))
                .summaryReveal(index: 1, revealing: revealing, shown: shown)
            }
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: 0) {
                    SummaryHeading(text: section.heading, query: query)
                    MarginRow { SectionMarkdown(source: section.body, query: query, meeting: meeting, evidence: evidence, passages: passages) }
                        .padding(.top, DaybookSpacing.s2)
                    photos(section)
                }
                .blockID(blockID(.section(section.id)))
                .summaryReveal(index: offset + index, revealing: revealing, shown: shown)
            }
            SummaryHeading(text: "Your notes", query: "").blockID(blockID(.notesHeading))
        }
        .onAppear { if revealing { shown = true } }
    }

    private func segment(_ id: UUID?) -> TranscriptSegment? {
        id.flatMap { id in meeting.unifiedTranscript.first { $0.id == id } }
    }
}

extension SummaryBody where Photos == EmptyView {
    public init(meeting: Meeting, summary: MeetingSummary, library: LibraryController, query: String = "", revealing: Bool = false,
                passages: PassageLinks = .none, blockID: @escaping (SummaryBlock) -> String? = { _ in nil }) {
        self.init(meeting: meeting, summary: summary, library: library, query: query, revealing: revealing, passages: passages,
                  blockID: blockID) { _ in EmptyView() }
    }
}

/// A heading on the page: body ink at semibold, 32 pt below the block before it. Weight, not grey, makes a heading.
public struct SummaryHeading: View {
    private let text: String
    private let query: String

    public init(text: String, query: String = "") {
        self.text = text
        self.query = query
    }

    public var body: some View {
        MarginRow {
            Text(FindHighlight.mark(AttributedString(text), query: query))
                .daybookFont(.heading)
                .foregroundStyle(DaybookPalette.Ink.body)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, DaybookSpacing.s6)
    }
}

// MARK: - Next steps

/// A next step: its checkbox (a Mac's checkbox, the iPhone's circle with a tap's haptic), the step, its owner in their
/// speaker's ink (the chip goes once it's done; the name stays, at full ink), and the time it was said, which leads to
/// the passage. Ticking it can be undone.
struct NextStepRow: View {
    let item: ActionItem
    let meeting: Meeting
    let library: LibraryController
    let query: String
    let segment: TranscriptSegment?
    let passages: PassageLinks
    @Environment(\.undoManager) private var undoManager
    @Environment(\.daybookDensity) private var density

    var body: some View {
        MarginRow {
            HStack(alignment: .firstTextBaseline, spacing: density == .touch ? 10 : DaybookSpacing.s2) {
                Toggle(isOn: Binding(get: { item.completed }, set: set)) { Text(String(ModelText.inlineMarkdown(item.text).characters)) }
                    .toggleStyle(NextStepToggleStyle())
                EvidenceLink(text: item.text, segment: segment, passages: passages) {
                    // The owner sits beside a short step, and under a long one.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
                            stepText.fixedSize()
                            owner
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            stepText.fixedSize(horizontal: false, vertical: true)
                            owner
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let segment {
                    Button { passages.show(segment.id) } label: {
                        QuietLink(rest: DaybookPalette.Ink.meta) {
                            Text(TimeLabel.short(segment.start)).daybookFont(.time)
                        }
                        .daybookHitTarget()
                    }
                    .buttonStyle(.plain)
                    .help("Show in Transcript")
                    .accessibilityLabel("Said at \(SpokenTime.format(segment.start))")
                    .accessibilityHint("Shows it in the transcript")
                }
            }
            .daybookMotion(DaybookMotion.fade, value: item.completed)
        }
    }

    private var stepText: some View {
        Text(FindHighlight.mark(ModelText.inlineMarkdown(item.text), query: query))
            .daybookFont(.body)
            .strikethrough(item.completed, color: DaybookPalette.Ink.meta)
            .foregroundStyle(item.completed ? DaybookPalette.Ink.secondary : DaybookPalette.Ink.body)
    }

    @ViewBuilder private var owner: some View {
        if let owner = item.owner, !owner.isEmpty {
            // Done, it's the name in its ink without the chip; never faded.
            DaybookChip(owner, kind: .owner(meeting.speakers.firstIndex { $0.name.caseInsensitiveCompare(owner) == .orderedSame }),
                        filled: !item.completed)
                .accessibilityLabel("Owner: \(owner)")
        }
    }

    private func set(_ done: Bool) {
        library.update(meeting.id, actionName: done ? "Mark as Done" : "Mark as Not Done", undoManager: undoManager) { value in
            guard let index = value.summary?.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
            value.summary?.actionItems[index].completed = done
        }
    }
}

/// A next step's checkbox: the Mac's own checkbox, and the iPhone's circle, a 44 pt target that answers the tap
/// itself with a haptic (never a change that synced in). The step's words are its label for VoiceOver only.
struct NextStepToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        NextStepToggle(configuration: configuration)
    }
}

private struct NextStepToggle: View {
    let configuration: ToggleStyleConfiguration
    @State private var taps = 0
    @Environment(\.daybookDensity) private var density

    var body: some View {
        #if os(macOS)
        if density != .touch {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
                .labelsHidden()
                // The box's middle at the step's x-height.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        } else {
            circle
        }
        #else
        circle
        #endif
    }

    private var circle: some View {
        Button {
            taps += 1
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(configuration.isOn ? DaybookPalette.accent : DaybookPalette.Ink.meta)
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
                // A 44 pt target without making the row taller.
                .daybookHitTarget()
        }
        .buttonStyle(.plain)
        // The circle's middle on the step's first line.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
        .sensoryFeedback(.selection, trigger: taps)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

// MARK: - Sections

/// A section's Markdown: paragraphs, bullets (teal dots), numbered items, and subheadings, each leading to its passage.
struct SectionMarkdown: View {
    let source: String
    let query: String
    let meeting: Meeting
    let evidence: SummaryEvidenceIndex
    let passages: PassageLinks
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale

    var body: some View {
        let bullet = SummaryMarkdownMetrics.bullet(density: density, scale: scale)
        VStack(alignment: .leading, spacing: density == .touch ? DaybookSpacing.s2 : 6 * scale) {
            ForEach(Array(SummaryMarkdown.blocks(source).enumerated()), id: \.offset) { _, block in
                let segment = evidence.segment(for: block.text).flatMap { id in meeting.unifiedTranscript.first { $0.id == id } }
                EvidenceLink(text: block.text, segment: segment, passages: passages) {
                    switch block {
                    case .paragraph(let text):
                        Text(FindHighlight.mark(ModelText.inlineMarkdown(text), query: query))
                            .lineSpacing(DaybookFont.bodyLineSpacing(density, scale: scale))
                    case .heading(let text):
                        Text(FindHighlight.mark(ModelText.inlineMarkdown(text), query: query)).daybookFont(.heading)
                    case .item(let marker, let text):
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Group {
                                if marker == "•" {
                                    Circle().fill(DaybookPalette.accent.opacity(0.75)).frame(width: bullet.dot, height: bullet.dot)
                                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + bullet.dot * 0.8 }
                                } else {
                                    Text(marker).monospacedDigit().foregroundStyle(DaybookPalette.Ink.secondary)
                                }
                            }
                            .frame(width: bullet.column, alignment: .leading)
                            .accessibilityHidden(true)
                            Text(FindHighlight.mark(ModelText.inlineMarkdown(text), query: query))
                                .lineSpacing(DaybookFont.bodyLineSpacing(density, scale: scale))
                        }
                    }
                }
                .daybookFont(.body)
                .foregroundStyle(DaybookPalette.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .selectableInWindow()
            }
        }
    }
}

/// A list's marks, one rule per density: a 5 pt dot in a 16 pt column in a window (growing with the reading scale),
/// 6 in 20 under touch.
public enum SummaryMarkdownMetrics {
    public static func bullet(density: DaybookDensity, scale: CGFloat = 1) -> (dot: CGFloat, column: CGFloat) {
        density == .touch ? (6, 20) : (5 * scale, 16 * scale)
    }
}

// MARK: - Evidence

/// A summary block that leads to what was said: its passage's menu (Show in Transcript, Copy) and VoiceOver action
/// everywhere; a tap when the transcript is beside the page.
struct EvidenceLink<Content: View>: View {
    let text: String
    let segment: TranscriptSegment?
    let passages: PassageLinks
    @ViewBuilder var content: Content
    @Environment(\.screenServices) private var services

    var body: some View {
        if let segment {
            content
                .contentShape(Rectangle())
                .onTapGesture { if passages.onTap { passages.show(segment.id) } }
                .contextMenu {
                    Button { passages.show(segment.id) } label: { Label("Show in Transcript", systemImage: "text.quote") }
                    Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                .accessibilityAction(named: "Show in Transcript") { passages.show(segment.id) }
        } else {
            content
        }
    }

    private func copy() {
        let plain = String(ModelText.inlineMarkdown(text).characters)
        if let services { services.copyLocally(plain) } else { LocalCopy.copy(plain) }
    }
}

extension View {
    /// A block's scroll ID, when the app gave one.
    @ViewBuilder func blockID(_ id: String?) -> some View {
        if let id { self.id(id) } else { self }
    }

    /// Text can be selected in a window; under touch a press opens the block's menu instead.
    func selectableInWindow() -> some View { modifier(SelectableInWindow()) }
}

private struct SelectableInWindow: ViewModifier {
    @Environment(\.daybookDensity) private var density
    func body(content: Content) -> some View {
        if density == .touch { content } else { content.textSelection(.enabled) }
    }
}
