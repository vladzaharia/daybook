import DaybookDesign
import DaybookKit
import SwiftUI

/// One conversation in the library's list, on both apps, as Notes lists notes: the title, then the time and the
/// gist, and its tags. A glyph and a line of words take the gist's place only when the conversation isn't ready
/// (`ConversationRowStatus`, from DaybookKit's `ConversationStatusPresentation.row`): recording, a 2 pt gradient
/// line while it's processed, waiting, waiting for models, paused, couldn't finish, not transcribed; mint marks the
/// one playing; and when its work finishes an accent checkmark holds for a moment (`DoneMark`, `DaybookMotion.hold`)
/// before it fades.
///
/// The density sets the rest (`daybookDensity`). In a window the row is chrome, in the system's label colours with
/// a hover wash, and every row is the same height: the tags end the time's line (`RowTags.arrangements`), and the
/// gist takes one line, or two in a list column at least `twoLineGistWidth` wide (`conversationListIsWide`). Under
/// touch and in a panel it sits on paper, in the Ink scale, with its tags on a line of their own when they fit, one
/// line of gist in a panel and two under touch (three at accessibility sizes, where the title wraps too and the
/// time stacks over the gist).
public struct ConversationRowView: View {
    private let meeting: Meeting
    private let status: ConversationRowStatus?
    private let timeLabel: String
    private let isSelected: Bool
    @State private var hovering = false
    @State private var justFinished = false
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationListIsWide) private var listIsWide

    /// - Parameters:
    ///   - status: What it says while it isn't ready; nil shows its gist.
    ///   - timeLabel: When it was, as its date group puts it (`RowDate.format`).
    ///   - isSelected: The list selects it, so the hover wash stays off.
    public init(meeting: Meeting, status: ConversationRowStatus?, timeLabel: String, isSelected: Bool = false) {
        self.meeting = meeting
        self.status = status
        self.timeLabel = timeLabel
        self.isSelected = isSelected
    }

    /// A window's list column at least this wide gives each row two lines of gist, as Mail's two-line preview.
    public static let twoLineGistWidth: CGFloat = 360

    private var onPaper: Bool { density != .window }
    private var large: Bool { density == .touch && dynamicType.isAccessibilitySize }
    private var tags: [String] { meeting.tags ?? [] }

    public var body: some View {
        VStack(alignment: .leading, spacing: density == .touch ? 3 : 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.title(meeting))
                    .font(DaybookFont.rowTitle.font(density))
                    .foregroundStyle(onPaper ? AnyShapeStyle(DaybookPalette.Ink.title) : AnyShapeStyle(.primary))
                    .lineLimit(large ? 3 : 1)
                Spacer(minLength: 4)
                RowGlyph(kind: shownKind, fraction: status?.fraction ?? 0)
            }
            detailLine
                .font(DaybookFont.rowDetail.font(density))
                .daybookMotion(DaybookMotion.fade, value: status?.phrase)
            if density != .window, !tags.isEmpty {
                RowTags(tags: tags)
                    .padding(.top, density == .touch ? 3 : 2)
            }
        }
        .padding(.vertical, density == .touch ? 5 : 7)
        #if os(macOS)
        // The list column's hover wash; a panel's row is a button with its own.
        .padding(.horizontal, density == .window ? 4 : 0)
        .background(Color.primary.opacity(density == .window && hovering && !isSelected ? 0.05 : 0), in: DaybookRadius.shape(DaybookRadius.row))
        .padding(.horizontal, density == .window ? -4 : 0)
        .onHover { hovering = $0 }
        .daybookMotion(hovering ? DaybookMotion.hover : DaybookMotion.fade, value: hovering)
        #endif
        .onChange(of: status?.kind) { old, new in
            // Its work just finished: the checkmark lands, holds, and fades (the task below).
            guard old == .processing, new == nil || new == .justFinished else { return }
            withAnimation(DaybookMotion.resolved(DaybookMotion.land, reduceMotion: reduceMotion)) { justFinished = true }
        }
        .task(id: justFinished) {
            guard justFinished else { return }
            try? await Task.sleep(for: DaybookMotion.hold)
            guard !Task.isCancelled else { return }
            withAnimation(DaybookMotion.resolved(DaybookMotion.fade, reduceMotion: reduceMotion)) { justFinished = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spokenLabel(meeting, status: status, timeLabel: timeLabel))
    }

    /// The glyph shown: the status's, or the checkmark while it holds.
    private var shownKind: ConversationRowStatus.Kind? {
        if let kind = status?.kind { return kind }
        return justFinished ? .justFinished : nil
    }

    /// The time, then what's happening or the gist; at accessibility sizes the gist takes lines of its own. In a
    /// window the tags end the line.
    @ViewBuilder private var detailLine: some View {
        if density == .window, !tags.isEmpty {
            // As many tags as fit while the gist keeps its room; a status's words keep all of theirs.
            ViewThatFits(in: .horizontal) {
                ForEach(RowTags.arrangements(tags), id: \.self) { chips in
                    detailRow(chips: chips)
                }
                detailRow(chips: [])
            }
        } else {
            detailRow(chips: [])
        }
    }

    private func detailRow(chips: [String]) -> some View {
        let layout = large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        return layout {
            Text(timeLabel)
                .foregroundStyle(onPaper ? AnyShapeStyle(DaybookPalette.Ink.body) : AnyShapeStyle(.primary))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            if density == .window {
                // The gist asks for only its room beside the tags (they fit when that's left); a status's words ask
                // for all of theirs. Either takes what the line has left.
                words.frame(minWidth: 0, idealWidth: status?.text == nil && !chips.isEmpty ? Self.gistRoom : nil, maxWidth: .infinity,
                            alignment: .leading)
            } else {
                words
            }
            if !chips.isEmpty { RowTagChips(chips: chips, all: tags) }
        }
    }

    /// The room a window's gist keeps beside its tags: the start of a sentence.
    static let gistRoom: CGFloat = 96

    /// What's happening, or the gist.
    @ViewBuilder private var words: some View {
        let lines = Self.previewLines(density, accessibilitySize: dynamicType.isAccessibilitySize, wideList: listIsWide)
        // A window's rows keep the gist's lines whatever they hold, so the column reads as an even index.
        let reserves = density == .window
        if let status, let until = status.countdownUntil {
            // A summary's countdown, a second at a time, on the deadline's own phase: the list's subtitle counting
            // down to the same moment says the same number.
            TimelineView(.countdown(to: until)) { context in
                Text(status.text(at: context.date) ?? "")
                    .foregroundStyle(secondary)
                    .monospacedDigit()
                    .lineLimit(reserves ? lines : 1, reservesSpace: reserves)
            }
        } else {
            Text(status?.text ?? RowPreview.text(for: meeting))
                .foregroundStyle(secondary)
                .lineLimit(lines, reservesSpace: reserves)
                .contentTransition(.opacity)
        }
    }

    /// Previews and status words: secondary ink on paper (4.5:1 or better), the system's in a window.
    private var secondary: AnyShapeStyle {
        onPaper ? AnyShapeStyle(DaybookPalette.Ink.secondary) : AnyShapeStyle(.secondary)
    }

    /// Lines of gist: in a window one, or two in a wide list column (`twoLineGistWidth`); one in a panel; two under
    /// touch, three at accessibility sizes.
    static func previewLines(_ density: DaybookDensity, accessibilitySize: Bool, wideList: Bool) -> Int {
        switch density {
        case .window: return wideList ? 2 : 1
        case .panel: return 1
        case .touch: return accessibilitySize ? 3 : 2
        }
    }

    /// The title a row shows: the conversation's, or "Untitled Conversation".
    public static func title(_ meeting: Meeting) -> String {
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? LibraryWords.untitled : meeting.title
    }

    /// What VoiceOver reads for the row: what it shows, in order. The title, when, how long, then the words in
    /// the gist's place (what's happening, or the gist itself), and its tags, all of them, whatever fits.
    public static func spokenLabel(_ meeting: Meeting, status: ConversationRowStatus?, timeLabel: String) -> String {
        var parts = [title(meeting), timeLabel]
        if let duration = meeting.duration { parts.append(SpokenTime.format(duration)) }
        switch status?.kind {
        case .playing?: parts.append("Playing")
        case .justFinished?: parts.append("Done")
        default: break
        }
        parts.append(status?.text(at: Date()) ?? RowPreview.text(for: meeting))
        if let tags = meeting.tags, !tags.isEmpty { parts.append("Tags: " + tags.joined(separator: ", ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

extension EnvironmentValues {
    /// The window's list column is at least `ConversationRowView.twoLineGistWidth` wide, so its rows give the gist
    /// two lines. Only a window's rows read it.
    @Entry public var conversationListIsWide = false
}

/// A row's glyph, by its status's kind: drawn the same on both apps, in one language. The 2 pt gradient line only
/// while work runs; every other state a symbol centred in one slot (`slot`), so they line up down the list: secondary
/// ink while it waits (a clock, a pause, a download, audio not transcribed yet), red only recording, orange only a
/// failure, mint only playing, and the accent's checkmark as work lands.
public struct RowGlyph: View {
    private let kind: ConversationRowStatus.Kind?
    private let fraction: Double
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Under touch the symbol, its slot, and the line grow with the row's words (Dynamic Type), from the footnote's size.
    @ScaledMetric(relativeTo: .footnote) private var scaledGlyph = RowGlyph.touchGlyph
    @ScaledMetric(relativeTo: .footnote) private var scaledSlot = RowGlyph.slot
    @ScaledMetric(relativeTo: .footnote) private var scaledLine = RowGlyph.lineWidth

    public init(kind: ConversationRowStatus.Kind?, fraction: Double = 0) {
        self.kind = kind
        self.fraction = fraction
    }

    /// The processing line's length; under touch, at the default text size.
    public static let lineWidth: CGFloat = 44
    /// The width every symbol is centred in; under touch, at the default text size.
    public static let slot: CGFloat = 16
    /// A symbol's size under touch at the default text size, the footnote's.
    public static let touchGlyph: CGFloat = 13
    /// A symbol's size in a window and a panel, which don't scale.
    public static let fixedGlyph: CGFloat = 11

    /// A glyph's symbol size, slot, and line length.
    public struct Metrics: Equatable, Sendable {
        public var glyph: CGFloat
        public var slot: CGFloat
        public var line: CGFloat

        public init(glyph: CGFloat, slot: CGFloat, line: CGFloat) {
            self.glyph = glyph
            self.slot = slot
            self.line = line
        }
    }

    /// The sizes at a density: the Dynamic Type-scaled ones under touch, and the fixed ones in a window and a panel.
    public static func metrics(_ density: DaybookDensity, scaled: Metrics) -> Metrics {
        density == .touch ? scaled : Metrics(glyph: fixedGlyph, slot: slot, line: lineWidth)
    }

    private var sizes: Metrics {
        Self.metrics(density, scaled: Metrics(glyph: scaledGlyph, slot: scaledSlot, line: scaledLine))
    }

    public var body: some View {
        glyph
            .font(.system(size: sizes.glyph, weight: .semibold))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .processing?:
            // One moving neon line says "working" in the densest surface, without words.
            WorkProgress(fraction: fraction, style: .line, width: sizes.line)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        case let kind?:
            symbol(kind)
                .frame(minWidth: sizes.slot)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func symbol(_ kind: ConversationRowStatus.Kind) -> some View {
        switch kind {
        case .recording:
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DaybookPalette.Ink.record)
                .symbolEffect(.breathe, options: reduceMotion ? .nonRepeating : .repeating)
                .daybookGlow(DaybookPalette.Ink.record, radius: 3)
        case .playing:
            Image(systemName: "waveform")
                .foregroundStyle(DaybookPalette.liveGlyph)
                .symbolEffect(.variableColor.iterative, options: reduceMotion ? .nonRepeating : .repeating)
                .daybookGlow(DaybookPalette.neonMint, radius: 3)
        case .justFinished:
            DoneMark()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(DaybookPalette.Ink.warning)
        default:
            Image(systemName: kind.symbol ?? "clock")
                .foregroundStyle(density == .window ? AnyShapeStyle(.secondary) : AnyShapeStyle(DaybookPalette.Ink.secondary))
        }
    }
}

/// A row's tags on a line of their own (under touch and in a panel): as many as fit (up to three), and none when
/// even one doesn't.
struct RowTags: View {
    let tags: [String]

    var body: some View {
        let shown = Array(tags.prefix(3))
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(1, shown.count)).reversed(), id: \.self) { count in
                HStack(spacing: 4) {
                    ForEach(shown.prefix(count), id: \.self) { DaybookChip($0, kind: .tag) }
                }
            }
            Color.clear.frame(height: 0)
        }
        .accessibilityHidden(true)
    }

    /// The ways a window's row can end its time's line with its tags, most first: up to three by name with a count
    /// for the rest ("launch", "+2"), then the count alone ("+3").
    static func arrangements(_ tags: [String]) -> [[String]] {
        guard !tags.isEmpty else { return [] }
        let named = (1...min(3, tags.count)).reversed().map { count in
            Array(tags.prefix(count)) + (tags.count > count ? ["+\(tags.count - count)"] : [])
        }
        return named + [["+\(tags.count)"]]
    }
}

/// Tags at the end of a window's row: chips that keep to the line's height, every tag in the tooltip.
private struct RowTagChips: View {
    let chips: [String]
    let all: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.offset) { DaybookChip($0.element, kind: .tag) }
        }
        // The capsule's own padding overhangs the line, so a tagged row is as tall as any other.
        .padding(.vertical, -2)
        .help(all.joined(separator: ", "))
        .accessibilityHidden(true)
    }
}
