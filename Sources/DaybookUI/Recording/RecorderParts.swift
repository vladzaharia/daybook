import DaybookDesign
import DaybookKit
import SwiftUI

// The pieces both recorders are built from (`RecorderSurface`): the meters for every source, the chips that say
// what records along, the title, the large controls, the pause box, and the compact panel's note field.

// MARK: - Meters

/// How the meters share their area. One source takes it all; more split it, down to a minimum row, the area
/// growing to keep that; past the most the area may take, the rows thin instead (to a floor), so many sources
/// still leave the notes their room.
public struct MeterStack: Equatable, Sendable {
    /// The height one source takes, and two share.
    public var area: CGFloat
    /// Between two rows; more rows sit closer.
    public var gap: CGFloat
    public var tightGap: CGFloat
    public var minimumRow: CGFloat
    public var maximumArea: CGFloat
    public var floorRow: CGFloat
    /// The largest a row's glyph gets, and the column it sits in.
    public var glyph: CGFloat
    public var glyphColumn: CGFloat

    public init(area: CGFloat, gap: CGFloat, tightGap: CGFloat, minimumRow: CGFloat, maximumArea: CGFloat, floorRow: CGFloat,
                glyph: CGFloat = 10, glyphColumn: CGFloat = 16) {
        self.area = area; self.gap = gap; self.tightGap = tightGap; self.minimumRow = minimumRow
        self.maximumArea = maximumArea; self.floorRow = floorRow; self.glyph = glyph; self.glyphColumn = glyphColumn
    }

    /// Floating Notes, beside the 34 pt clock.
    public static let full = MeterStack(area: 40, gap: 6, tightGap: 4, minimumRow: 10, maximumArea: 56, floorRow: 4)
    /// Floating Notes compact, beside the 26 pt clock.
    public static let compact = MeterStack(area: 24, gap: 4, tightGap: 3, minimumRow: 8, maximumArea: 42, floorRow: 3)
    /// The iPhone in the hand, under its 64 pt clock.
    public static let pocket = MeterStack(area: 44, gap: 6, tightGap: 4, minimumRow: 12, maximumArea: 64, floorRow: 5, glyph: 15, glyphColumn: 22)
    /// The open iPhone Duo's recorder page.
    public static let page = MeterStack(area: 56, gap: 6, tightGap: 4, minimumRow: 14, maximumArea: 72, floorRow: 6, glyph: 15, glyphColumn: 22)
    /// Table mode, read from across the table.
    public static let stage = MeterStack(area: 64, gap: 8, tightGap: 6, minimumRow: 16, maximumArea: 84, floorRow: 8, glyph: 17, glyphColumn: 24)

    public func gap(_ count: Int) -> CGFloat { count > 2 ? tightGap : gap }

    public func rowHeight(_ count: Int) -> CGFloat {
        guard count > 1 else { return area }
        let gaps = gap(count) * CGFloat(count - 1)
        let shared = (area - gaps) / CGFloat(count)
        if shared >= minimumRow { return shared }
        if CGFloat(count) * minimumRow + gaps <= maximumArea { return minimumRow }
        return max(floorRow, (maximumArea - gaps) / CGFloat(count))
    }

    /// The whole stack's height.
    public func height(_ count: Int) -> CGFloat {
        count == 0 ? 0 : rowHeight(count) * CGFloat(count) + gap(count) * CGFloat(count - 1)
    }

    /// A row's glyph: as large as `glyph`, smaller when the rows are too close for it.
    public func glyphSize(row: CGFloat, gap: CGFloat) -> CGFloat { max(7, min(glyph, row + gap - 2)) }
}

/// One rolling meter per source the recording has now, each labelled with its chip's glyph, its name in the
/// tooltip and for VoiceOver, so a muted microphone, a call that isn't being captured, or a device that hears
/// nothing shows up during the call, not afterwards. The meters read the trails themselves, so only they redraw as
/// levels arrive.
public struct RecorderMeters: View {
    private let meters: [RecorderMeter]
    private let levels: RecorderLevels
    private let isLive: Bool
    private let stack: MeterStack

    /// - Parameter isLive: Recording now: a meter whose levels arrive moves; otherwise every meter rests.
    public init(meters: [RecorderMeter], levels: RecorderLevels, isLive: Bool, stack: MeterStack) {
        self.meters = meters
        self.levels = levels
        self.isLive = isLive
        self.stack = stack
    }

    public var body: some View {
        let row = stack.rowHeight(meters.count), gap = stack.gap(meters.count)
        VStack(spacing: gap) {
            ForEach(meters) { meter in
                RecorderMeterRow(meter: meter, trail: levels.trail(meter.source),
                                 isLive: isLive && meter.isRecording && levels.heard.contains(meter.source),
                                 height: row, glyph: stack.glyphSize(row: row, gap: gap), column: stack.glyphColumn)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: meters.map(\.source), initial: true) { _, sources in levels.follow(sources) }
    }
}

/// A source's glyph and its meter. Resting (flat and grey) while it isn't recording, or before its levels arrive.
struct RecorderMeterRow: View {
    let meter: RecorderMeter
    let trail: LevelTrail
    let isLive: Bool
    let height: CGFloat
    let glyph: CGFloat
    let column: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: meter.symbol)
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(meter.warning != nil ? DaybookPalette.Ink.warning : DaybookPalette.Ink.meta)
                // The row's height, whatever the glyph's: rows share the area exactly.
                .frame(width: column, height: height)
                .accessibilityHidden(true)
            RollingLevelMeter(trail: trail, isLive: isLive, accessibilityLabel: "\(meter.name) level")
                .frame(height: height)
                .accessibilityHint(meter.warning ?? "")
        }
        .help(meter.warning ?? meter.name)
    }
}

// MARK: - Chips

/// How much each chip in a bar says, widest first. A chip whose short label says as much shortens first; then
/// prominent chips (processing, anything that needs the person) keep their words while the others give theirs up.
public enum RecorderChipFit: CaseIterable, Sendable {
    case full, shortFirst, shortOthers, glyphOthers, short, glyph

    public func label(_ chip: RecorderChip) -> String? {
        switch self {
        case .full: return chip.label
        case .shortFirst: return chip.shortensFirst ? chip.shortLabel : chip.label
        case .shortOthers: return chip.isProminent ? RecorderChipFit.shortFirst.label(chip) : chip.shortLabel
        case .glyphOthers: return chip.isProminent ? RecorderChipFit.shortFirst.label(chip) : nil
        case .short: return chip.isProminent ? chip.shortLabel : nil
        case .glyph: return nil
        }
    }
}

/// The status chips in a row: whole labels when they fit, then short ones, then glyphs. Each is a menu whose first
/// line is the whole status in a sentence, then what can be done about it; the call chip only says.
public struct RecorderChipRow<MenuContent: View>: View {
    private let chips: [RecorderChip]
    private let menu: (RecorderChip) -> MenuContent

    public init(chips: [RecorderChip], @ViewBuilder menu: @escaping (RecorderChip) -> MenuContent) {
        self.chips = chips
        self.menu = menu
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(RecorderChipFit.allCases, id: \.self) { fit in
                HStack(spacing: 6) {
                    ForEach(chips) { chip in RecorderChipControl(chip: chip, fit: fit, menu: menu) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }
}

/// One chip at a fit: a menu with its whole status and what you can do about it. The call chip only says.
public struct RecorderChipControl<MenuContent: View>: View {
    private let chip: RecorderChip
    private let fit: RecorderChipFit
    private let menu: (RecorderChip) -> MenuContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(chip: RecorderChip, fit: RecorderChipFit, @ViewBuilder menu: @escaping (RecorderChip) -> MenuContent) {
        self.chip = chip
        self.fit = fit
        self.menu = menu
    }

    public var body: some View {
        if chip.countdownUntil != nil {
            // Only a countdown redraws each second, and only this chip; its digits roll down as they change.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = chip.at(context.date)
                control(now).animation(DaybookMotion.resolved(DaybookMotion.tick, reduceMotion: reduceMotion), value: now.label)
            }
        } else {
            control(chip)
        }
    }

    private func control(_ chip: RecorderChip) -> some View {
        let face = StatusChip(symbol: chip.symbol, text: fit.label(chip), tone: chip.tone, showsDot: chip.showsDot, progress: chip.progress,
                              filled: true, expands: chip.expands)
        return Group {
            if chip.target == .call {
                face
            } else {
                Menu {
                    Text(chip.detail)
                    Divider()
                    menu(chip)
                } label: {
                    face.daybookHitTarget()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
        // A chip at work spans what's left of its row; the others keep their own size.
        .fixedSize(horizontal: !chip.expands, vertical: true)
        .frame(maxWidth: chip.expands ? .infinity : nil)
        .help(chip.detail)
        .accessibilityLabel(chip.detail)
        .accessibilityValue(StatusChip.accessibilityValue(progress: chip.progress) ?? "")
    }
}

// MARK: - Title

/// The conversation's title in New York, editable in place where it can be renamed. In the panel it keeps one
/// line at a fixed size (scaling with the reading size to 1.3 times); under touch it follows Dynamic Type, and at
/// the accessibility sizes it wraps rather than cutting the name to "Conversati…".
public struct RecorderTitle: View {
    private let title: String
    private let rename: ((String) -> Void)?
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ title: String, rename: ((String) -> Void)? = nil) {
        self.title = title
        self.rename = rename
    }

    public static let untitled = "Untitled Conversation"

    private var font: Font {
        density == .touch ? .system(.title3, design: .serif, weight: .semibold)
            : .system(size: DaybookFont.docTitle.size(.panel) * min(scale, 1.3), weight: .semibold, design: .serif)
    }

    public var body: some View {
        Group {
            if let rename {
                let binding = Binding(get: { title }, set: { rename($0) })
                ZStack(alignment: .leading) {
                    if title.isEmpty {
                        Text(Self.untitled).foregroundStyle(DaybookPalette.Ink.faint).accessibilityHidden(true)
                    }
                    TextField("Title", text: binding, prompt: Text(verbatim: ""))
                        .textFieldStyle(.plain)
                        .foregroundStyle(DaybookPalette.Ink.title)
                        .labelsHidden()
                }
                .lineLimit(1)
                .truncationMode(.tail)
            } else {
                Text(title.isEmpty ? Self.untitled : title)
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .lineLimit(density == .touch && typeSize.isAccessibilitySize ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .font(font)
    }
}

// MARK: - Controls

/// The large controls' size on a surface.
public struct RecorderControlMetrics: Equatable, Sendable {
    public var height: CGFloat
    public var radius: CGFloat
    /// A fixed label size (the Mac); nil follows Dynamic Type.
    public var size: CGFloat?
    public var spacing: CGFloat

    public init(height: CGFloat, radius: CGFloat, size: CGFloat?, spacing: CGFloat) {
        self.height = height; self.radius = radius; self.size = size; self.spacing = spacing
    }

    /// Floating Notes.
    public static let panel = RecorderControlMetrics(height: 44, radius: 13, size: 14, spacing: 10)
    /// Floating Notes, compact.
    public static let panelCompact = RecorderControlMetrics(height: 34, radius: 10, size: 13, spacing: 8)
    /// The iPhone in the hand, at the thumb.
    public static let pocket = RecorderControlMetrics(height: 64, radius: DaybookRadius.control, size: nil, spacing: DaybookSpacing.s3)
    /// The open iPhone Duo's recorder page.
    public static let page = RecorderControlMetrics(height: 56, radius: DaybookRadius.control, size: nil, spacing: DaybookSpacing.s3)
}

/// Bookmark, the shapes it takes, and its feedback: it bounces (and, on the iPhone, taps the hand) for the person's
/// own tap alone, never for a bookmark another device added or one taken away. The count rolls either way.
public struct BookmarkControl: View {
    public enum Shape: Equatable, Sendable {
        /// Beside Stop.
        case tile(RecorderControlMetrics)
        /// Table mode laid flat (flex): a wide target under the hand.
        case wide
        /// Table mode standing like a book: a large round target hit without looking.
        case round
        /// Beside the clock while writing in table mode: the glyph and the count.
        case glyph
    }

    private let count: Int
    private let isEnabled: Bool
    private let shape: Shape
    private let shortcut: Bool
    private let action: () -> Void
    @State private var landed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter shortcut: ⌘D, with its tooltip (the Mac's panel).
    public init(count: Int, isEnabled: Bool = true, shape: Shape, shortcut: Bool = false, action: @escaping () -> Void) {
        self.count = count
        self.isEnabled = isEnabled
        self.shape = shape
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button {
            landed += 1
            action()
        } label: {
            label
        }
        .modifier(BookmarkSurface(shape: shape))
        .disabled(!isEnabled)
        .modifier(RecorderShortcut(enabled: shortcut, key: "d", modifiers: .command, help: "Add Bookmark (⌘D)"))
        .modifier(RecorderPressFeedback(trigger: landed, heavy: shape == .wide || shape == .round))
        .accessibilityLabel(count > 0 ? "Bookmark, \(count) so far" : "Bookmark")
        .accessibilityShowsLargeContentViewer {
            Label(count > 0 ? "Bookmark · \(count)" : "Bookmark", systemImage: "bookmark.fill")
        }
    }

    @ViewBuilder private var label: some View {
        switch shape {
        case .tile(let metrics):
            BookmarkControlLabel(count: count, size: metrics.size, landed: landed)
                .frame(maxWidth: .infinity, minHeight: metrics.height)
                .contentShape(Rectangle())
        case .wide:
            HStack(spacing: 14) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .daybookBounce(value: landed)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bookmark").font(.title2.weight(.semibold))
                    soFar
                }
            }
            .foregroundStyle(DaybookPalette.bookmark)
            .frame(maxWidth: .infinity, minHeight: 140)
            .contentShape(Rectangle())
        case .round:
            VStack(spacing: 10) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .daybookBounce(value: landed)
                Text("Bookmark").font(.title2.weight(.semibold))
                soFar
            }
            .foregroundStyle(DaybookPalette.bookmark)
            .frame(width: Self.roundTarget, height: Self.roundTarget)
            .contentShape(Circle())
        case .glyph:
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill").daybookBounce(value: landed)
                if count > 0 {
                    Text("\(count)").monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(count)))
                        .animation(DaybookMotion.resolved(DaybookMotion.tick, reduceMotion: reduceMotion), value: count)
                }
            }
            .font(.headline)
            .foregroundStyle(DaybookPalette.bookmark)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    /// The round target's side: meant to be hit without looking.
    public static let roundTarget: CGFloat = 248

    @ViewBuilder private var soFar: some View {
        if count > 0 {
            Text(count == 1 ? "1 so far" : "\(count) so far")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(DaybookPalette.Ink.bookmarkCount)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(count)))
                .animation(DaybookMotion.resolved(DaybookMotion.tick, reduceMotion: reduceMotion), value: count)
        }
    }
}

private struct BookmarkSurface: ViewModifier {
    let shape: BookmarkControl.Shape
    func body(content: Content) -> some View {
        switch shape {
        case .tile(let metrics): content.daybookControl(.standard, shape: .roundedRectangle(radius: metrics.radius))
        case .wide: content.daybookControl(.standard, shape: .roundedRectangle(radius: 28))
        case .round: content.daybookControl(.standard, shape: .circle)
        case .glyph: content.daybookControl(.standard, shape: .capsule)
        }
    }
}

/// Stop: the red control. A press is felt at once on the iPhone; whether it saved is said (and felt) when filing
/// finishes, on what's on screen then.
public struct StopControl: View {
    private let isSaving: Bool
    private let height: CGFloat
    private let radius: CGFloat
    private let size: CGFloat?
    private let shortcut: Bool
    private let elapsed: (() -> TimeInterval)?
    private let action: () -> Void
    @State private var pressed = 0

    /// - Parameters:
    ///   - shortcut: ⇧⌘R, with its tooltip (the Mac's panel).
    ///   - elapsed: The recording's length now, which VoiceOver reads with Stop.
    public init(isSaving: Bool, metrics: RecorderControlMetrics, shortcut: Bool = false, elapsed: (() -> TimeInterval)? = nil,
                action: @escaping () -> Void) {
        self.isSaving = isSaving
        height = metrics.height
        radius = metrics.radius
        size = metrics.size
        self.shortcut = shortcut
        self.elapsed = elapsed
        self.action = action
    }

    public var body: some View {
        Button {
            pressed += 1
            action()
        } label: {
            StopControlLabel(isSaving: isSaving, size: size)
                .frame(maxWidth: .infinity, minHeight: height)
                .contentShape(Rectangle())
        }
        .daybookControl(.stop, shape: .roundedRectangle(radius: radius))
        .disabled(isSaving)
        .modifier(RecorderShortcut(enabled: shortcut, key: "r", modifiers: [.command, .shift], help: "Stop Recording (⇧⌘R)"))
        .modifier(RecorderPressFeedback(trigger: pressed, heavy: false))
        .accessibilityLabel(isSaving ? "Saving" : "Stop recording")
        .accessibilityValue(elapsed.map { SpokenTime.format($0()) } ?? "")
        .accessibilityShowsLargeContentViewer {
            Label(isSaving ? "Saving…" : "Stop", systemImage: "stop.fill")
        }
    }
}

/// A recorder control's keyboard shortcut and tooltip, where it has one.
struct RecorderShortcut: ViewModifier {
    let enabled: Bool
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let help: String

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(key, modifiers: modifiers).help(help)
        } else {
            content
        }
    }
}

/// A tap the hand feels on the iPhone: the person's own press, never a change from elsewhere.
struct RecorderPressFeedback: ViewModifier {
    let trigger: Int
    let heavy: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sensoryFeedback(.impact(weight: heavy ? .heavy : .medium), trigger: trigger)
        #else
        content
        #endif
    }
}

/// Two large controls side by side at the foot, as one group of glass on the iPhone.
public struct RecorderControlRow<Leading: View, Trailing: View>: View {
    private let spacing: CGFloat
    private let leading: Leading
    private let trailing: Trailing

    public init(spacing: CGFloat, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.spacing = spacing
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        let row = HStack(spacing: spacing) {
            leading
            trailing
        }
        #if os(iOS)
        GlassEffectContainer(spacing: spacing) { row }
            // Glyphs alone hold at any size; past this the tiles would outgrow the screen.
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        #else
        row
        #endif
    }
}

// MARK: - Pause

/// Why a recording is paused, and whether it can go on.
public struct RecorderPause: Equatable, Sendable {
    public var title: String
    public var message: String
    public var canResume: Bool

    public init(title: String, message: String, canResume: Bool) {
        self.title = title; self.message = message; self.canResume = canResume
    }
}

/// The recording is paused: what happened in one box, and Resume Recording under it once it can.
public struct RecorderPauseBox: View {
    private let pause: RecorderPause
    private let metrics: RecorderControlMetrics
    private let resume: () -> Void

    public init(_ pause: RecorderPause, metrics: RecorderControlMetrics, resume: @escaping () -> Void) {
        self.pause = pause
        self.metrics = metrics
        self.resume = resume
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
            AttentionBox(title: pause.title, symbol: "pause.circle.fill", message: pause.message)
            // Resume only once it can: during a call the message says when it will.
            if pause.canResume {
                Button(action: resume) {
                    HStack(spacing: 8) {
                        Circle().fill(DaybookPalette.Ink.record).frame(width: 12, height: 12)
                            .daybookGlow(DaybookPalette.Ink.record, radius: 3)
                        Text("Resume Recording")
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(metrics.size.map { .system(size: $0, weight: .semibold) } ?? .headline)
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: min(metrics.height, 52))
                    .contentShape(Rectangle())
                }
                .daybookControl(.standard, shape: .roundedRectangle(radius: DaybookRadius.box))
            }
        }
    }
}

// MARK: - Notes

/// One line for a note in the compact panel: Return adds it as a paragraph at the time it was written, and the
/// field clears for the next, like a message.
public struct RecorderNoteField: View {
    private let add: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    public init(add: @escaping (String) -> Void) { self.add = add }

    public var body: some View {
        TextField("Note", text: $draft, prompt: Text(MarginNotesEditor.placeholder).foregroundStyle(DaybookPalette.Ink.faint))
            .textFieldStyle(.plain)
            .daybookFont(.body)
            .foregroundStyle(DaybookPalette.Ink.body)
            .focused($focused)
            .submitLabel(.return)
            .onSubmit {
                let line = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = ""
                focused = true
                if !line.isEmpty { add(line) }
            }
            .accessibilityLabel("Add a note")
    }

    /// The notes with `line` as a new last paragraph.
    public static func appending(_ line: String, to notes: String) -> String {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return notes }
        let kept = notes.trimmingCharacters(in: .newlines)
        return kept.isEmpty ? line : kept + "\n" + line
    }
}

/// A hairline between the recorder's header and the notes.
public struct RecorderRule: View {
    @Environment(\.colorSchemeContrast) private var contrast
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(contrast == .increased ? DaybookPalette.Ink.meta : DaybookPalette.Ink.faint.opacity(0.45))
            .frame(height: contrast == .increased ? 1 : 0.5)
            .accessibilityHidden(true)
    }
}
