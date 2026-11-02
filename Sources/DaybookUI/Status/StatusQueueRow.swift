import DaybookDesign
import DaybookKit
import SwiftUI

/// A conversation in a device's queue, as the status overview lists it under the device doing it: its title, what's
/// happening to it in the words of where it's shown ("Transcribing · 40%" under that device), and what can be done.
public struct StatusQueueItem: Identifiable, Equatable, Sendable {
    /// What a queued conversation offers.
    public enum Action: Hashable, Sendable {
        /// Where its summary runs: Use the Cloud, Start Now, Wait for a Mac.
        case placement(SummaryPlacementPlanner.Action)
        /// A failure's: asks again, as its page's Try Again does.
        case tryAgain(ProcessingRequest.Mode)

        public var title: String {
            switch self {
            case .placement(let action): return action.title
            case .tryAgain: return "Try Again"
            }
        }
    }

    public var id: UUID
    public var title: String
    /// What's happening to it.
    public var line: String
    /// After the line, quieter: "Requested from this iPhone".
    public var note: String?
    /// 0...1 while it runs with a figure.
    public var progress: Double?
    /// It couldn't finish: the line in warning ink.
    public var isProblem: Bool
    /// What a failure means, in a plain sentence ending "The recording is saved.".
    public var detail: String?
    /// The device's own words, behind Details.
    public var details: String?
    /// Its summary's countdown runs out then: the line counts down to it.
    public var countdownUntil: Date?
    public var actions: [Action]

    public init(id: UUID, title: String, line: String, note: String? = nil, progress: Double? = nil, isProblem: Bool = false,
                detail: String? = nil, details: String? = nil, countdownUntil: Date? = nil, actions: [Action] = []) {
        self.id = id; self.title = title; self.line = line; self.note = note; self.progress = progress; self.isProblem = isProblem
        self.detail = detail; self.details = details; self.countdownUntil = countdownUntil; self.actions = actions
    }

    /// The seconds left in its countdown at a moment, rounded up; nil without one.
    public func secondsLeft(at now: Date) -> Int? {
        countdownUntil.map { max(1, Int($0.timeIntervalSince(now).rounded(.up))) }
    }

    /// The line at a moment: a countdown's seconds move with it.
    public func line(at now: Date) -> String {
        guard let seconds = secondsLeft(at: now) else { return line }
        return line.replacingOccurrences(of: #"in \d+ s"#, with: "in \(seconds) s", options: .regularExpression)
    }
}

/// One conversation in a queue. Under a device's row it's indented to that row's text (`indented`); with no device
/// above it, it starts at the card's edge, with no empty glyph column. Its title and line open the conversation;
/// a failure offers Try Again and Details, and a summary its placement's choices.
public struct StatusQueueRow: View {
    private let item: StatusQueueItem
    private let indented: Bool
    private let open: (() -> Void)?
    private let perform: (StatusQueueItem.Action) -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - indented: Under a device's row, to its text; false at the top of a card, where the card lists it with
    ///     `.statusRowAtCardEdge()` so the divider above it starts at the edge too.
    ///   - open: Opens the conversation; nil leaves the row to be read.
    public init(_ item: StatusQueueItem, indented: Bool = true, open: (() -> Void)? = nil,
                perform: @escaping (StatusQueueItem.Action) -> Void = { _ in }) {
        self.item = item
        self.indented = indented
        self.open = open
        self.perform = perform
    }

    private var touch: Bool { density == .touch }

    public var body: some View {
        if indented {
            StatusRow(alignment: .top) { content }
        } else {
            content
                .padding(.horizontal, StatusCardMetrics.padding)
                .padding(.vertical, touch ? StatusCardMetrics.rowVertical : DaybookSpacing.s2)
                .frame(maxWidth: .infinity, minHeight: touch ? 44 : nil, alignment: .leading)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s1) {
            if let open {
                Button(action: open) { summary(leads: true) }
                    .buttonStyle(QueueRowPress())
                    .accessibilityHint("Opens the conversation")
            } else {
                summary(leads: false)
            }
            if item.details != nil || !item.actions.isEmpty {
                links
            }
        }
    }

    private func summary(leads: Bool) -> some View {
        HStack(spacing: DaybookSpacing.s2) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(touch ? .subheadline : .system(size: 12, weight: .medium))
                    .foregroundStyle(DaybookPalette.Ink.body)
                    .lineLimit(2)
                if item.countdownUntil != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        lineText(item.line(at: context.date))
                            .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                            .daybookMotion(DaybookMotion.tick, value: item.secondsLeft(at: context.date))
                    }
                } else {
                    lineText(item.line)
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(lineFont)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let progress = item.progress {
                    WorkProgressLine(fraction: progress).padding(.top, 2)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if leads {
                Image(systemName: "chevron.forward")
                    .font(touch ? .footnote.weight(.semibold) : .system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private var lineFont: Font { touch ? .footnote : .system(size: 11) }

    private func lineText(_ line: String) -> some View {
        let note = item.note.map { " · \($0)" } ?? ""
        return Text("\(Text(line.keepingSeparators).foregroundStyle(item.isProblem ? DaybookPalette.Ink.warning : DaybookPalette.Ink.secondary))\(Text(note).foregroundStyle(DaybookPalette.Ink.meta))")
            .font(lineFont)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Its choices as text links, beside each other or, at the accessibility sizes, under each other.
    private var links: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DaybookSpacing.s2))
            : AnyLayout(HStackLayout(spacing: DaybookSpacing.s4))
        return layout {
            ForEach(item.actions, id: \.self) { action in
                Button(action.title) { perform(action) }
                    // Among rows of the same choices, VoiceOver says which conversation's it is.
                    .accessibilityLabel("\(action.title), \(item.title)")
            }
            if let details = item.details {
                DetailsButton(details: details)
            }
        }
        .buttonStyle(.daybookLink)
        .font(touch ? .footnote.weight(.semibold) : .system(size: 11, weight: .semibold))
    }
}

/// The row dims while pressed, as a list row does.
private struct QueueRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}
