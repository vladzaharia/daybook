import DaybookDesign
import DaybookKit
import SwiftUI

/// A conversation's processing status on its page, drawn one way on both apps from DaybookKit's
/// `ConversationStatusPresentation` (docs/interface.md, "Status speaks only when there is something to say"):
///
/// - A working or waiting state is a bare line: its glyph (or a spinner) in a fixed column, the words in secondary ink
///   with what's worth knowing under them, a progress bar under the words when the work reports a figure, and its
///   actions as text links at the line's end, or under the words when they need the room.
/// - A state that needs the person is a quiet box (one radius and padding, from the tokens), its glyph on the title's
///   first baseline, at most two actions beside the words from 520 pt wide and under them below that, in the order the
///   presentation gives. The one that leads is prominent; Details shows the device's own words (a popover on the Mac,
///   a sheet on the iPhone).
///
/// A countdown's seconds roll (and fade under Reduce Motion); only its words redraw each second.
public struct StatusBlock: View {
    private let presentation: ConversationStatusPresentation
    private let perform: @MainActor (ConversationStatusPresentation.Action) -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .subheadline) private var scaledGlyph: CGFloat = 20
    @State private var width: CGFloat = AttentionBoxLayout.stackBelow

    public init(_ presentation: ConversationStatusPresentation, perform: @escaping @MainActor (ConversationStatusPresentation.Action) -> Void) {
        self.presentation = presentation
        self.perform = perform
    }

    public var body: some View {
        Group {
            switch presentation.kind {
            case .line: line
            case .box(let box): self.box(StatusBlockLayout.attention(box))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var touch: Bool { density == .touch }
    /// The glyph's column, so the words, the bar, and the actions share one edge.
    private var glyphColumn: CGFloat { touch ? min(scaledGlyph, 32) : 18 }
    private var gap: CGFloat { touch ? DaybookSpacing.s2 : 6 }
    private var stacked: Bool { StatusBlockLayout.stacksActions(width: width, density: density) }

    // MARK: Line

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: gap) {
            Group {
                if presentation.isWorking {
                    ProgressView().controlSize(.small)
                } else if let symbol = presentation.symbol {
                    Image(systemName: symbol).foregroundStyle(DaybookPalette.Ink.secondary)
                }
            }
            .frame(width: glyphColumn)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if presentation.actions.isEmpty {
                    lineWords
                } else {
                    // The actions at the line's end, as Record sits beside "Notes only"; under the words when they
                    // need the room, so neither breaks mid-word.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s3) {
                            lineWords.fixedSize()
                            Spacer(minLength: 0)
                            actions(prominent: false, wraps: false).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            lineWords
                            actions(prominent: false, wraps: true)
                        }
                    }
                }
                if let progress = presentation.progress {
                    WorkProgress(fraction: progress, style: .bar)
                        .frame(maxWidth: StatusBlockLayout.barWidth)
                        .accessibilityHidden(true)
                }
            }
        }
        .daybookFont(.status)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lineWords: some View {
        VStack(alignment: .leading, spacing: 2) {
            StatusTitle(presentation: presentation)
                .foregroundStyle(DaybookPalette.Ink.secondary)
            if let detail = presentation.detail {
                Text(detail).foregroundStyle(DaybookPalette.Ink.meta)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: Box

    private func box(_ kind: AttentionKind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s3) {
            Group {
                if let symbol = presentation.symbol {
                    Image(systemName: symbol)
                        .symbolRenderingMode(kind == .problem ? .monochrome : .hierarchical)
                        .foregroundStyle(StatusBlockLayout.tint(kind))
                }
            }
            .font(touch ? DaybookFont.statusLead.font(.touch) : .system(size: 14))
            .frame(width: glyphColumn)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: touch ? 10 : DaybookSpacing.s2) {
                VStack(alignment: .leading, spacing: 3) {
                    StatusTitle(presentation: presentation)
                        .daybookFont(.statusLead)
                        .foregroundStyle(AttentionBoxLayout.title(for: kind).ink.color)
                    if let detail = presentation.detail {
                        Text(detail)
                            .daybookFont(.status)
                            .foregroundStyle(AttentionBoxLayout.message(for: kind).ink.color)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                if stacked && !presentation.actions.isEmpty { actions(prominent: true, wraps: true) }
            }
            .layoutPriority(1)
            if !stacked && !presentation.actions.isEmpty {
                Spacer(minLength: DaybookSpacing.s3)
                actions(prominent: true, wraps: false).fixedSize()
            }
        }
        .padding(DaybookSpacing.s3)
        // Stacked or not, the box spans its column, so boxes and lines share both edges.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AttentionBoxLayout.wash(for: kind).color, in: DaybookRadius.shape(DaybookRadius.box))
        .overlay {
            if contrast == .increased {
                DaybookRadius.shape(DaybookRadius.box)
                    .strokeBorder(kind == .problem ? DaybookPalette.Ink.warning : DaybookPalette.Ink.meta, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Actions

    /// In the order given. Under touch each is its own 44 pt target, 24 pt apart, so a tap never lands on its neighbour.
    /// Under the words they wrap to another line rather than run out of the column.
    @ViewBuilder private func actions(prominent: Bool, wraps: Bool) -> some View {
        let spacing = StatusBlockLayout.actionSpacing(density)
        Group {
            if wraps {
                FlowLayout(spacing: spacing, lineSpacing: DaybookSpacing.s2) { buttons(prominent: prominent) }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: spacing) { buttons(prominent: prominent) }
            }
        }
        .daybookFont(.status)
        .fontWeight(.medium)
    }

    private func buttons(prominent: Bool) -> some View {
        ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, action in
            button(action, prominent: prominent && action.isPrimary)
        }
    }

    @ViewBuilder private func button(_ action: ConversationStatusPresentation.Action, prominent: Bool) -> some View {
        switch action {
        case .details(let words):
            DetailsButton(details: words).buttonStyle(.daybookLink)
        default:
            if prominent {
                Button(action.title) { perform(action) }
                    .buttonStyle(.daybookProminent)
                    .controlSize(touch ? .regular : .small)
            } else {
                Button(action.title) { perform(action) }
                    .buttonStyle(.daybookLink)
            }
        }
    }
}

/// The status's title: a countdown's seconds move once a second, rolling down (a fade under Reduce Motion).
private struct StatusTitle: View {
    let presentation: ConversationStatusPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let until = presentation.countdownUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let title = presentation.title(at: context.date)
                Text(title)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                    .animation(DaybookMotion.resolved(DaybookMotion.tick, reduceMotion: reduceMotion),
                               value: StatusBlockLayout.secondsLeft(until, at: context.date))
            }
        } else {
            Text(presentation.title)
        }
    }
}

/// The block's rules, as plain values.
public enum StatusBlockLayout {
    /// A working line's bar reaches at most this far.
    public static let barWidth: CGFloat = 220

    /// A box's actions move under its words in a narrow column (`AttentionBoxLayout.stackBelow`), and always in the
    /// panel.
    public static func stacksActions(width: CGFloat, density: DaybookDensity) -> Bool {
        density == .panel || width < AttentionBoxLayout.stackBelow
    }

    /// Between two actions: 24 pt under touch, so neighbours aren't mis-tapped; 12 in a window.
    public static func actionSpacing(_ density: DaybookDensity) -> CGFloat {
        density == .touch ? DaybookSpacing.s5 : DaybookSpacing.s3
    }

    public static func attention(_ box: ConversationStatusPresentation.Box) -> AttentionKind {
        switch box {
        case .problem: return .problem
        case .accent: return .accent
        case .info: return .info
        }
    }

    static func tint(_ kind: AttentionKind) -> Color {
        switch kind {
        case .problem: return DaybookPalette.Ink.warning
        case .accent: return DaybookPalette.accent
        case .info: return DaybookPalette.Ink.secondary
        }
    }

    static func secondsLeft(_ until: Date, at now: Date) -> Int { max(1, Int(until.timeIntervalSince(now).rounded(.up))) }

    /// What the page animates on: the kind, the words without their figure, and the actions. A new percent or a
    /// countdown's tick changes none of it, so progress never starts an animation.
    public static func motionKey(_ presentation: ConversationStatusPresentation?) -> String {
        guard let presentation else { return "" }
        return "\(presentation.kind)|\(presentation.phrase)|\(presentation.detail ?? "")|\(presentation.actions.map(\.title))"
    }
}
