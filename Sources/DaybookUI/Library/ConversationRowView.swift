import DaybookDesign
import DaybookKit
import SwiftUI

/// One conversation in the library's list, on both apps, as Notes lists notes: the title, then the time and the
/// gist, and its tags when the row has room. A glyph and a line of words take the gist's place only when the
/// conversation isn't ready (`ConversationRowStatus`, from DaybookKit's `ConversationStatusPresentation.row`):
/// recording, a 2 pt gradient line while it's processed, waiting, waiting for models, paused, couldn't finish, not
/// transcribed; mint marks the one playing; and when its work finishes an accent checkmark holds for a moment
/// (`DoneMark`, `DaybookMotion.hold`) before it fades.
///
/// The density sets the rest (`daybookDensity`): in a window the row is chrome, in the system's label colours with
/// one line of gist and a hover wash; under touch and in a panel it sits on paper, in the Ink scale, with two lines
/// of gist (three at accessibility sizes, where the title wraps too and the time stacks over the gist).
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

    private var onPaper: Bool { density != .window }
    private var large: Bool { density == .touch && dynamicType.isAccessibilitySize }

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
            if let tags = meeting.tags, !tags.isEmpty {
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

    /// The time, then what's happening or the gist; at accessibility sizes the gist takes lines of its own.
    private var detailLine: some View {
        let layout = large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        return layout {
            Text(timeLabel)
                .foregroundStyle(onPaper ? AnyShapeStyle(DaybookPalette.Ink.body) : AnyShapeStyle(.primary))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            if let status, status.countdownUntil != nil {
                // A summary's countdown, a second at a time.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(status.text(at: context.date) ?? "")
                        .foregroundStyle(secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            } else {
                Text(status?.text ?? RowPreview.text(for: meeting))
                    .foregroundStyle(secondary)
                    .lineLimit(previewLines)
                    .contentTransition(.opacity)
            }
        }
    }

    /// Previews and status words: secondary ink on paper (4.5:1 or better), the system's in a window.
    private var secondary: AnyShapeStyle {
        onPaper ? AnyShapeStyle(DaybookPalette.Ink.secondary) : AnyShapeStyle(.secondary)
    }

    /// One line in a window and a panel, two under touch, three at accessibility sizes.
    private var previewLines: Int {
        guard density == .touch else { return 1 }
        return dynamicType.isAccessibilitySize ? 3 : 2
    }

    /// The title a row shows: the conversation's, or "Untitled Conversation".
    public static func title(_ meeting: Meeting) -> String {
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? LibraryWords.untitled : meeting.title
    }

    /// What VoiceOver reads for the row: what it shows, in order. The title, when, how long, then the words in
    /// the gist's place (what's happening, or the gist itself), and its tags.
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

/// A row's glyph, by its status's kind: drawn the same on both apps.
public struct RowGlyph: View {
    private let kind: ConversationRowStatus.Kind?
    private let fraction: Double
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(kind: ConversationRowStatus.Kind?, fraction: Double = 0) {
        self.kind = kind
        self.fraction = fraction
    }

    /// The processing line's length.
    public static let lineWidth: CGFloat = 44

    public var body: some View {
        glyph
            .font(density == .touch ? .footnote.weight(.semibold) : .system(size: 11, weight: .semibold))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .recording?:
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DaybookPalette.Ink.record)
                .symbolEffect(.breathe, options: reduceMotion ? .nonRepeating : .repeating)
                .daybookGlow(DaybookPalette.Ink.record, radius: 3)
        case .processing?:
            // One moving neon line says "working" in the densest surface, without words.
            WorkProgress(fraction: fraction, style: .line, width: Self.lineWidth)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        case .notTranscribed?:
            Circle().fill(DaybookPalette.accent)
                .frame(width: density == .touch ? 8 : 7, height: density == .touch ? 8 : 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        case .playing?:
            Image(systemName: "waveform")
                .foregroundStyle(DaybookPalette.liveGlyph)
                .symbolEffect(.variableColor.iterative, options: reduceMotion ? .nonRepeating : .repeating)
                .daybookGlow(DaybookPalette.neonMint, radius: 3)
        case .justFinished?:
            DoneMark()
        case .failed?:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(DaybookPalette.Ink.warning)
        case let kind?:
            Image(systemName: kind.symbol ?? "clock")
                .foregroundStyle(density == .window ? AnyShapeStyle(.secondary) : AnyShapeStyle(DaybookPalette.Ink.secondary))
        case nil:
            EmptyView()
        }
    }
}

/// A row's tags, as many as fit on its line (up to three), and none when even one doesn't.
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
}
