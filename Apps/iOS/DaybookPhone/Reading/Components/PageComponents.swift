import DaybookKit
import SwiftUI

extension EnvironmentValues {
    /// The side of this page that meets the iPhone Duo's crease, if any. Pages keep their content
    /// clear of it (`PhoneStyle.Page.creaseClearance`).
    @Entry var creaseEdge: Edge? = nil
    /// The library search's text, so the page can mark its matches.
    @Entry var findQuery: String = ""
    /// True when this page is one of two (the notebook): links between the pages work by scrolling
    /// the other page instead of switching to it.
    @Entry var isTwoPage: Bool = false
}

/// A page's column: centred, at most the Mac's measure wide, with the gutters a phone page needs and
/// extra room on the side that meets the crease.
struct PageColumn: ViewModifier {
    @Environment(\.creaseEdge) private var creaseEdge

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: PhoneStyle.Page.measure, alignment: .leading)
            .padding(.leading, PhoneStyle.Page.gutter + (creaseEdge == .leading ? PhoneStyle.Page.creaseClearance - 8 : 0))
            .padding(.trailing, PhoneStyle.Page.gutter + (creaseEdge == .trailing ? PhoneStyle.Page.creaseClearance - 8 : 0))
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func pageColumn() -> some View { modifier(PageColumn()) }
}

/// A row with something in the lane (a time, a glyph) and content beside it, on the same baseline.
/// The lane grows with Dynamic Type exactly as the notes editor's does, so their times line up.
struct LaneRow<Lane: View, Content: View>: View {
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder var lane: Lane
    @ViewBuilder var content: Content
    @ScaledMetric(relativeTo: .footnote) private var scaled = PhoneStyle.Page.lane

    var body: some View {
        HStack(alignment: alignment, spacing: 0) {
            HStack(spacing: 3) { lane }
                .frame(width: max(0, min(scaled, PhoneStyle.Page.lane * 1.9) - 10), alignment: .trailing)
                .padding(.trailing, 10)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A time that plays from there: meta ink, monospaced digits.
struct TimeButton: View {
    let time: TimeInterval
    var ink: Color = PhoneStyle.Ink.meta
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            Text(TimeLabel.short(time))
                .font(PhoneStyle.Typeface.time)
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play from \(SpokenTime.format(time))")
    }
}

/// A heading on the page: Body ink at semibold. Weight, not grey, makes a heading.
struct PageHeading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(PhoneStyle.Typeface.heading)
            .foregroundStyle(PhoneStyle.Ink.body)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The processing status on the page: one bare line while something works or waits, a quiet
/// filled box with at most two actions when something needs the person. The symbol sits in a
/// fixed column, so the words, the progress line, and the actions start at the same edge.
struct StatusView: View {
    let presentation: StatusPresentation
    let perform: (StatusPresentation.Action) -> Void
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .subheadline) private var glyphWidth: CGFloat = 20

    var body: some View {
        switch presentation.kind {
        case .line: line
        case .problem, .info: box
        }
    }

    private var column: CGFloat { min(glyphWidth, 32) }
    private var gap: CGFloat { 8 }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: gap) {
            Group {
                if presentation.isWorking {
                    ProgressView().controlSize(.small)
                } else if let symbol = presentation.symbol {
                    Image(systemName: symbol).foregroundStyle(PhoneStyle.Ink.secondary)
                }
            }
            .frame(width: column)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if presentation.actions.isEmpty {
                    lineWords
                } else {
                    // The line's action at its end, as Record sits beside "No recording yet"; under
                    // the words when they need the room, so neither breaks mid-word.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: PhoneStyle.Space.s3) {
                            lineWords.fixedSize()
                            Spacer(minLength: 0)
                            actions.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            lineWords
                            actions
                        }
                    }
                }
                if let progress = presentation.progress {
                    ProgressView(value: progress).progressViewStyle(.brand(width: nil, height: 3))
                        .frame(maxWidth: 220)
                }
            }
        }
        .font(PhoneStyle.Typeface.status)
    }

    private var lineWords: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presentation.title)
                .foregroundStyle(PhoneStyle.Ink.secondary)
                .contentTransition(.numericText())
            if let detail = presentation.detail {
                Text(detail).foregroundStyle(PhoneStyle.Ink.meta).font(.footnote)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var box: some View {
        let problem = presentation.kind == .problem
        return HStack(alignment: .firstTextBaseline, spacing: gap) {
            Group {
                if let symbol = presentation.symbol {
                    Image(systemName: symbol)
                        .symbolRenderingMode(problem ? .monochrome : .hierarchical)
                        .foregroundStyle(problem ? PhoneStyle.Ink.warning : PhoneStyle.Ink.secondary)
                }
            }
            .frame(width: column)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(PhoneStyle.Typeface.statusLead)
                        .foregroundStyle(problem ? PhoneStyle.Ink.warning : PhoneStyle.Ink.body)
                    if let detail = presentation.detail {
                        Text(detail).font(PhoneStyle.Typeface.status).foregroundStyle(PhoneStyle.Ink.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                if !presentation.actions.isEmpty {
                    actions
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(problem ? PhoneStyle.Ink.warning.opacity(scheme == .dark ? 0.12 : 0.08) : PhoneStyle.quietFill,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: 16) {
            ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, action in
                actionButton(action)
            }
        }
    }

    @ViewBuilder private func actionButton(_ action: StatusPresentation.Action) -> some View {
        switch action {
        case .request(let mode):
            if presentation.kind == .line {
                // On a calm line, the action is a link, as quiet as the line.
                Button(mode == .newAudio ? "Transcribe" : "Try Again") { perform(action) }
                    .buttonStyle(.daybookLink).font(.subheadline.weight(.semibold))
            } else {
                Button("Try Again") { perform(action) }
                    .buttonStyle(.borderedProminent)
                    .tint(PhoneStyle.prominentFill)
                    .controlSize(.small)
                    .font(.subheadline.weight(.semibold))
            }
        case .details:
            Button("Details") { perform(action) }.buttonStyle(.daybookLink).font(.subheadline.weight(.medium))
        case .dismiss:
            Button("Dismiss") { perform(action) }.buttonStyle(.daybookLink).font(.subheadline.weight(.medium))
        }
    }
}

/// A next step's owner, in their speaker ink when they spoke. Done rows keep the name, not the chip.
struct OwnerChip: View {
    let name: String
    let ink: Color?
    var filled = true

    var body: some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ink ?? PhoneStyle.Ink.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((ink ?? .clear).opacity(filled ? 0.14 : 0), in: Capsule())
            .background(ink == nil && filled ? PhoneStyle.quietFill : .clear, in: Capsule())
            .fixedSize()
            .accessibilityLabel("Owner: \(name)")
    }
}

/// A tag, as a teal chip.
struct TagChip: View {
    let tag: String
    var body: some View {
        Text(tag)
            .font(.caption.weight(.medium))
            .foregroundStyle(PhoneStyle.Ink.link)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(PhoneStyle.accent.opacity(0.14), in: Capsule())
    }
}

/// Wraps subviews onto new lines, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                let y = rows[rows.count - 1].y + rows[rows.count - 1].height + lineSpacing
                rows.append(Row(y: y))
            }
            let last = rows.count - 1
            rows[last].width = rows[last].indices.isEmpty ? size.width : rows[last].width + spacing + size.width
            rows[last].height = max(rows[last].height, size.height)
            rows[last].indices.append(index)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// Paper behind a page, under the status column and home indicator too.
struct PaperBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(PhoneStyle.paper.ignoresSafeArea())
    }
}

extension View {
    func paperBackground() -> some View { modifier(PaperBackground()) }
}
