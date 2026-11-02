import DaybookDesign
import DaybookKit
import SwiftUI

// One recorder for both apps (docs/interface.md, "Floating Notes"; docs/iphone.md, "iPhone Duo"): the phase, the
// chips for what records along, the title, the red clock with a meter for each source, your notes with their
// times, live captions, and Bookmark and Stop. Each app fills it from its own model (Floating Notes from AppState,
// the iPhone from PhoneAppModel) and keeps only what must differ around it: the panel's title band and keys on the
// Mac; the camera, the timeline, and table mode's dimming on the iPhone. It lays itself out by the surface's
// `SurfaceLayout`:
//
// - compact: Floating Notes under 380 pt tall. The clock and small meters, a line for a note, the newest caption,
//   and the controls.
// - column: Floating Notes, and the iPhone in the hand. The panel puts the meters beside its 34 pt clock; the
//   iPhone puts them under its 64 pt one, with the camera beside it.
// - spread: the open iPhone Duo. Your notes on the left page; the recorder on the right.
// - stage: table mode. The clock, level, and large captions on one half; a large Bookmark, Stop, and the tools
//   on the other.

/// The recording's elapsed time, as the surface's clock reads it.
public enum RecorderTime {
    /// Counting from a start, live.
    case since(Date)
    /// On the recorder's own clock: live, or frozen at a pause.
    case elapsed(isLive: Bool, frozenAt: TimeInterval?, value: () -> TimeInterval)

    var now: TimeInterval {
        switch self {
        case .since(let start): return max(0, Date().timeIntervalSince(start))
        case .elapsed(_, let frozen, let value): return frozen ?? value()
        }
    }
}

/// What the recorder shows.
public struct RecorderSurfaceState {
    /// The phase, drawn in the surface; nil when the host draws it (Floating Notes' title band).
    public var phase: RecorderPhase?
    public var title: String
    /// Renames the conversation from its title; nil shows the title as it is.
    public var rename: ((String) -> Void)?
    /// "Today · 10:15 AM", over the notes on a spread's left page.
    public var byline: String?
    public var chips: [RecorderChip]
    public var meters: [RecorderMeter]
    public var clock: RecorderTime
    /// Recording now: meters whose levels arrive move.
    public var isLive: Bool
    public var bookmarkCount: Int
    public var canBookmark: Bool
    public var isSaving: Bool
    public var pause: RecorderPause?
    /// Room the host keeps above the content (the panel's title band).
    public var topInset: CGFloat
    /// ⌘D and ⇧⌘R, with their tooltips (the Mac).
    public var keyboardShortcuts: Bool
    /// Table mode is dimmed: a touch only wakes it, so Stop and the tools don't take it. Bookmark always does.
    public var asleep: Bool

    public init(phase: RecorderPhase? = nil, title: String, rename: ((String) -> Void)? = nil, byline: String? = nil,
                chips: [RecorderChip] = [], meters: [RecorderMeter] = [], clock: RecorderTime, isLive: Bool, bookmarkCount: Int,
                canBookmark: Bool = true, isSaving: Bool = false, pause: RecorderPause? = nil, topInset: CGFloat = 0,
                keyboardShortcuts: Bool = false, asleep: Bool = false) {
        self.phase = phase; self.title = title; self.rename = rename; self.byline = byline; self.chips = chips; self.meters = meters
        self.clock = clock; self.isLive = isLive; self.bookmarkCount = bookmarkCount; self.canBookmark = canBookmark
        self.isSaving = isSaving; self.pause = pause; self.topInset = topInset; self.keyboardShortcuts = keyboardShortcuts
        self.asleep = asleep
    }

    /// Whether a touch on Stop reaches it. Dimmed, the touch only wakes the screen: it never ends the recording.
    /// Bookmark takes every touch, dimmed or not.
    public var stopTakesTouch: Bool { !asleep }
    /// Whether a touch on the tools beside Stop (Write Notes, Take Photo) reaches them; dimmed, it only wakes.
    public var toolsTakeTouch: Bool { !asleep }
}

/// What the recorder's controls do.
public struct RecorderActions {
    public var bookmark: () -> Void
    public var stop: () -> Void
    public var resume: () -> Void
    /// Adds a line as the notes' last paragraph (the compact panel's note field); nil leaves the field out.
    public var addNote: ((String) -> Void)?

    public init(bookmark: @escaping () -> Void, stop: @escaping () -> Void, resume: @escaping () -> Void = {},
                addNote: ((String) -> Void)? = nil) {
        self.bookmark = bookmark; self.stop = stop; self.resume = resume; self.addNote = addNote
    }
}

/// The views each app puts into the recorder.
public struct RecorderSlots {
    /// Your notes: the shared `MarginNotesEditor`, scrolling.
    public var notes: AnyView
    /// Live captions in the layout's style, or nothing.
    public var captions: AnyView
    /// Beside the clock (the iPhone's camera).
    public var accessory: AnyView?
    /// Under the meters on a spread's recorder page (the iPhone's live timeline).
    public var details: AnyView?
    /// One line when something needs saying while recording.
    public var notice: AnyView?
    /// Table mode's Write Notes and camera, beside Stop.
    public var tools: AnyView?
    /// What a chip's menu offers.
    public var menu: (RecorderChip) -> AnyView

    public init(notes: AnyView, captions: AnyView = AnyView(EmptyView()), accessory: AnyView? = nil, details: AnyView? = nil,
                notice: AnyView? = nil, tools: AnyView? = nil, menu: @escaping (RecorderChip) -> AnyView = { _ in AnyView(EmptyView()) }) {
        self.notes = notes; self.captions = captions; self.accessory = accessory; self.details = details; self.notice = notice
        self.tools = tools; self.menu = menu
    }
}

/// The recorder while a recording is under way.
public struct RecorderSurface: View {
    private let state: RecorderSurfaceState
    private let levels: RecorderLevels
    private let actions: RecorderActions
    private let slots: RecorderSlots
    private let writing: Binding<Bool>
    private let clockFocus: AccessibilityFocusState<Bool>.Binding?
    @Environment(\.surfaceLayout) private var layout
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - writing: Table mode's Write Notes: the notes take the clock's half until Done.
    ///   - clockFocus: Where VoiceOver goes as the recorder appears: the clock, which says it's recording and for how long.
    public init(state: RecorderSurfaceState, levels: RecorderLevels, actions: RecorderActions, slots: RecorderSlots,
                writing: Binding<Bool> = .constant(false), clockFocus: AccessibilityFocusState<Bool>.Binding? = nil) {
        self.state = state
        self.levels = levels
        self.actions = actions
        self.slots = slots
        self.writing = writing
        self.clockFocus = clockFocus
    }

    public var body: some View {
        let parts = RecorderPieces(state: state, levels: levels, actions: actions, slots: slots, clockFocus: clockFocus)
        switch layout {
        case .compact: CompactRecorder(parts: parts)
        case .column: ColumnRecorder(parts: parts, touch: density == .touch)
        case .spread(let crease):
            PageSpread(crease: crease) {
                SpreadNotesPage(parts: parts)
            } trailing: {
                SpreadRecorderPage(parts: parts)
            } single: {
                ColumnRecorder(parts: parts, touch: density == .touch)
            }
            .overlay(alignment: .leading) { CreaseLine(crease: crease) }
        case .stage: StageRecorder(parts: parts, writing: writing)
        }
    }
}

/// The pieces every layout arranges.
struct RecorderPieces {
    let state: RecorderSurfaceState
    let levels: RecorderLevels
    let actions: RecorderActions
    let slots: RecorderSlots
    let clockFocus: AccessibilityFocusState<Bool>.Binding?

    @ViewBuilder
    func phase(alignment: HorizontalAlignment = .leading) -> some View {
        if let phase = state.phase {
            RecordingPhaseLabel(phase.phase, title: phase.title, detail: phase.detail, detailIsWarning: phase.detailIsWarning)
                .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        }
    }

    @ViewBuilder var chips: some View {
        if !state.chips.isEmpty {
            RecorderChipRow(chips: state.chips) { slots.menu($0) }
        }
    }

    func clock(_ size: CGFloat, weight: Font.Weight = .medium) -> some View {
        Group {
            switch state.clock {
            case .since(let start):
                ElapsedClock(since: start, size: size, weight: weight)
            case .elapsed(let live, let frozen, let value):
                ElapsedClock(size: size, weight: weight, isLive: live, frozenAt: frozen, elapsed: value)
            }
        }
        .fixedSize()
        // Stop carries the elapsed time for VoiceOver too; the clock comes first among the recorder's pieces.
        .accessibilitySortPriority(1)
        .modifier(ClockFocus(binding: clockFocus))
    }

    func meters(_ stack: MeterStack) -> some View {
        RecorderMeters(meters: state.meters, levels: levels, isLive: state.isLive, stack: stack)
    }

    func bookmark(_ shape: BookmarkControl.Shape) -> some View {
        BookmarkControl(count: state.bookmarkCount, isEnabled: state.canBookmark, shape: shape, shortcut: state.keyboardShortcuts,
                        action: actions.bookmark)
    }

    func stop(_ metrics: RecorderControlMetrics) -> some View {
        StopControl(isSaving: state.isSaving, metrics: metrics, shortcut: state.keyboardShortcuts, elapsed: { state.clock.now },
                    action: actions.stop)
            .allowsHitTesting(state.stopTakesTouch)
    }

    func controls(_ metrics: RecorderControlMetrics) -> some View {
        RecorderControlRow(spacing: metrics.spacing) {
            bookmark(.tile(metrics))
        } trailing: {
            stop(metrics)
        }
    }

    @ViewBuilder
    func pauseOrMeters(_ stack: MeterStack, metrics: RecorderControlMetrics) -> some View {
        if let pause = state.pause {
            RecorderPauseBox(pause, metrics: metrics, resume: actions.resume)
                .daybookTransition(.opacity.combined(with: .move(edge: .top)))
        } else {
            meters(stack)
        }
    }
}

// MARK: - Compact

/// Floating Notes under 380 pt tall: the clock and small meters, a line for a note, the newest caption, and the
/// controls at 34 pt. The band carries the phase and the chips.
private struct CompactRecorder: View {
    let parts: RecorderPieces

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                parts.clock(26)
                parts.meters(.compact)
            }
            .padding(.horizontal, RecorderInsets.panel)
            .padding(.top, parts.state.topInset + 6)
            Spacer(minLength: 4)
            if let add = parts.actions.addNote {
                RecorderNoteField(add: add)
                    .padding(.horizontal, RecorderInsets.panel)
                    .padding(.bottom, 4)
            }
            // The newest caption sits on the controls, as the strip does on iPhone.
            parts.slots.captions
            PanelControlPadding(compact: true) { parts.controls(.panelCompact) }
        }
    }
}

// MARK: - Column

/// One column: Floating Notes at full size, and the iPhone in the hand.
private struct ColumnRecorder: View {
    let parts: RecorderPieces
    let touch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RecorderRule()
                .padding(.horizontal, touch ? RecorderInsets.touch : RecorderInsets.panel)
                .opacity(touch ? 0.6 : 1)
            parts.slots.notes
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if touch {
                VStack(spacing: DaybookSpacing.s3) {
                    parts.slots.captions
                    parts.slots.notice
                    parts.controls(.pocket)
                }
                .padding(.horizontal, DaybookSpacing.s4)
                .padding(.top, DaybookSpacing.s2)
                .padding(.bottom, DaybookSpacing.s3)
            } else {
                parts.slots.captions
                PanelControlPadding(compact: false) { parts.controls(.panel) }
            }
        }
        .daybookMotion(DaybookMotion.state, value: parts.state.pause)
    }

    @ViewBuilder private var header: some View {
        if touch {
            VStack(alignment: .leading, spacing: 10) {
                parts.phase()
                parts.chips
                RecorderTitle(parts.state.title, rename: parts.state.rename)
                HStack(alignment: .center) {
                    parts.clock(64)
                    Spacer(minLength: 8)
                    parts.slots.accessory
                }
                parts.pauseOrMeters(.pocket, metrics: .pocket)
            }
            // The header holds its size past this, so it never squeezes the notes away: during a call the notes,
            // Bookmark, and Stop come first.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.horizontal, RecorderInsets.touch)
            .padding(.top, DaybookSpacing.s3)
            .padding(.bottom, DaybookSpacing.s2)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                parts.phase()
                if !parts.state.chips.isEmpty {
                    // Spacing 10 plus this: the same gap to the title as after Stop.
                    parts.chips.padding(.bottom, 2)
                }
                RecorderTitle(parts.state.title, rename: parts.state.rename)
                if let pause = parts.state.pause {
                    HStack(alignment: .center, spacing: 14) { parts.clock(34) }
                    RecorderPauseBox(pause, metrics: .panel, resume: parts.actions.resume)
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        parts.clock(34)
                        parts.meters(.full)
                    }
                }
            }
            .padding(.horizontal, RecorderInsets.panel)
            .padding(.top, parts.state.topInset + (parts.state.chips.isEmpty ? 4 : 10))
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Spread

/// The open Duo's left page: the conversation and your notes.
private struct SpreadNotesPage: View {
    let parts: RecorderPieces
    @Environment(\.creaseEdge) private var creaseEdge

    /// The page keeps clear of the crease on its side.
    private var creaseEdges: Edge.Set { creaseEdge == .trailing ? .trailing : creaseEdge == .leading ? .leading : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                RecorderTitle(parts.state.title, rename: parts.state.rename)
                if let byline = parts.state.byline {
                    Text(byline)
                        .font(.subheadline)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                }
            }
            .padding(.horizontal, DaybookSpacing.s6)
            .padding(.top, DaybookSpacing.s5)
            .padding(.bottom, DaybookSpacing.s2)
            parts.slots.notes
                .padding(.leading, DaybookSpacing.s3)
        }
        .padding(creaseEdges, ReadingGeometry.creaseClearance - DaybookSpacing.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The open Duo's right page: the recorder.
private struct SpreadRecorderPage: View {
    let parts: RecorderPieces

    var body: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s4) {
            HStack(alignment: .top) {
                parts.phase()
                Spacer(minLength: 0)
                parts.slots.accessory
            }
            parts.chips
            parts.clock(76)
            parts.pauseOrMeters(.page, metrics: .page)
            parts.slots.details
            parts.slots.captions
                .frame(maxHeight: .infinity, alignment: .bottom)
                .clipped()
            parts.slots.notice
            parts.controls(.page)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .padding(.horizontal, DaybookSpacing.s5)
        .padding(.top, DaybookSpacing.s5)
        .padding(.bottom, DaybookSpacing.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .daybookMotion(DaybookMotion.state, value: parts.state.pause)
    }
}

/// The crease between the pages, a hairline where the display folds.
private struct CreaseLine: View {
    let crease: CGFloat?
    var body: some View {
        if let crease {
            Rectangle().fill(DaybookPalette.Ink.faint.opacity(0.35))
                .frame(width: 0.5)
                .offset(x: crease)
                .ignoresSafeArea(edges: .vertical)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Stage

/// Partly open, standing on a table: readable from across it. Turned a quarter like a laptop (flex), the
/// standing half shows the captions, clock, and level, and the flat half Bookmark and Stop under the hand.
/// Standing like a book, the clock's page and the Bookmark's page sit side by side. Writing, the notes take the
/// clock's half until Done.
private struct StageRecorder: View {
    let parts: RecorderPieces
    @Binding var writing: Bool

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.height > proxy.size.width {
                FlexStage(parts: parts, writing: $writing)
            } else {
                BookStage(parts: parts, writing: $writing)
            }
        }
    }
}

private struct FlexStage: View {
    let parts: RecorderPieces
    @Binding var writing: Bool

    var body: some View {
        GeometryReader { proxy in
            // The crease is the middle of the whole display, not of the safe area.
            let full = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            let crease = max(0, min(proxy.size.height, full / 2 - proxy.safeAreaInsets.top))
            VStack(spacing: 0) {
                standing.frame(height: crease)
                Rectangle().fill(DaybookPalette.Ink.faint.opacity(0.35)).frame(height: 0.5).accessibilityHidden(true)
                flat.frame(maxHeight: .infinity)
            }
        }
        // The keyboard covers the flat half instead of squeezing both.
        .ignoresSafeArea(.keyboard)
    }

    private var standing: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            HStack(alignment: .center, spacing: DaybookSpacing.s3) {
                if writing {
                    // The clock, Bookmark, and Done stay whole; beside them, the chips give way first.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DaybookSpacing.s3) { parts.phase().fixedSize(); parts.chips }
                        parts.phase().fixedSize()
                    }
                    Spacer(minLength: 0)
                    parts.clock(34)
                    HStack(spacing: DaybookSpacing.s2) {
                        parts.bookmark(.glyph)
                        Button { writing = false } label: {
                            Text("Done")
                                .font(.headline)
                                .foregroundStyle(DaybookPalette.Ink.title)
                                .frame(minHeight: 44)
                                .padding(.horizontal, DaybookSpacing.s1)
                                .contentShape(Rectangle())
                        }
                        .daybookControl(.standard, shape: .capsule)
                        .accessibilityHint("Puts the keyboard away")
                    }
                    .fixedSize()
                } else {
                    parts.phase()
                    parts.chips
                }
            }
            if writing {
                parts.slots.notes
                    .padding(.horizontal, -DaybookSpacing.s4)
                    .frame(maxHeight: .infinity)
            } else {
                HStack(alignment: .center, spacing: DaybookSpacing.s5) {
                    parts.clock(92, weight: .light)
                    parts.meters(.stage)
                }
                parts.slots.captions
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .padding(.horizontal, DaybookSpacing.s6)
        .padding(.top, DaybookSpacing.s5)
        .padding(.bottom, DaybookSpacing.s4)
    }

    private var flat: some View {
        HStack(spacing: DaybookSpacing.s4) {
            if let pause = parts.state.pause {
                RecorderPauseBox(pause, metrics: .pocket, resume: parts.actions.resume)
            } else {
                parts.bookmark(.wide)
            }
            VStack(spacing: DaybookSpacing.s3) {
                parts.stop(RecorderControlMetrics(height: 84, radius: DaybookRadius.control, size: nil, spacing: DaybookSpacing.s3))
                parts.slots.tools.allowsHitTesting(parts.state.toolsTakeTouch)
            }
            .frame(maxWidth: 170)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, DaybookSpacing.s6)
        .padding(.vertical, DaybookSpacing.s5)
        .frame(maxHeight: .infinity)
    }
}

private struct BookStage: View {
    let parts: RecorderPieces
    @Binding var writing: Bool

    var body: some View {
        GeometryReader { proxy in
            let full = proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            let crease = max(0, min(proxy.size.width, full / 2 - proxy.safeAreaInsets.leading))
            HStack(spacing: 0) {
                clockPage.frame(width: crease)
                Rectangle().fill(DaybookPalette.Ink.faint.opacity(0.35)).frame(width: 0.5).accessibilityHidden(true)
                bookmarkPage.frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var clockPage: some View {
        if writing {
            VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
                HStack(alignment: .center) {
                    parts.phase()
                    Spacer(minLength: 0)
                    parts.clock(34)
                }
                .padding(.horizontal, DaybookSpacing.s6)
                parts.slots.notes
                    .padding(.horizontal, DaybookSpacing.s2)
                    .frame(maxHeight: .infinity)
            }
            .padding(.top, DaybookSpacing.s4)
        } else {
            VStack(spacing: DaybookSpacing.s4) {
                Spacer(minLength: 0)
                parts.phase(alignment: .center)
                parts.clock(148, weight: .light)
                parts.meters(.stage).frame(maxWidth: 360)
                parts.chips.frame(maxWidth: 380)
                parts.slots.captions.frame(maxWidth: 380)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DaybookSpacing.s6)
        }
    }

    private var bookmarkPage: some View {
        VStack(spacing: DaybookSpacing.s5) {
            Spacer(minLength: 0)
            if let pause = parts.state.pause {
                RecorderPauseBox(pause, metrics: .pocket, resume: parts.actions.resume).frame(maxWidth: 340)
            } else {
                parts.bookmark(.round)
            }
            Spacer(minLength: 0)
            HStack(spacing: DaybookSpacing.s3) {
                parts.slots.tools.allowsHitTesting(parts.state.toolsTakeTouch)
                parts.stop(RecorderControlMetrics(height: 52, radius: DaybookRadius.control, size: nil, spacing: DaybookSpacing.s3))
                    .frame(maxWidth: 220)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, DaybookSpacing.s5)
        .padding(.vertical, DaybookSpacing.s4)
    }
}

/// VoiceOver lands on the clock as the recorder appears.
private struct ClockFocus: ViewModifier {
    let binding: AccessibilityFocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let binding { content.accessibilityFocused(binding) } else { content }
    }
}

// MARK: - Shared geometry

/// The recorder's side insets.
enum RecorderInsets {
    /// Floating Notes: every left and right edge of content.
    static let panel: CGFloat = 16
    /// The iPhone in the hand.
    static let touch: CGFloat = DaybookSpacing.s5
}

/// The panel's controls at its foot, inset like its content.
struct PanelControlPadding<Content: View>: View {
    let compact: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, RecorderInsets.panel)
            .padding(.top, compact ? 6 : 10)
            .padding(.bottom, compact ? 12 : 16)
    }
}
