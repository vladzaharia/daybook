import DaybookDesign
import DaybookKit
import SwiftUI

#if os(iOS)
import UIKit
#endif

// The recorder's sheet on the iPhone (docs/iphone.md, "While recording"): one sheet at the foot of the column in the
// hand and of the open Duo's right page, at one of four sizes. It rests at the posture's size; the person can expand
// it to a level, which stays through folding and turning; dismissing clears that level back to rest. The sheet takes
// its height and the notes or the captions over it take what's left; nothing floats over them. Stop and Bookmark are
// at every size. In the hand the notes carry a header (the title, and the byline with what records along) and the
// newest caption sits on the sheet, so the resting recorder says what it's recording.

/// How much of its column or page the recorder's sheet takes.
public enum RecorderSheetSize: String, CaseIterable, Sendable {
    /// One row: the phase, the clock, a small meter, a glyph-sized Bookmark, and a glyph-sized Stop.
    case mini
    /// The phase, the clock beside its meters, and a Bookmark and Stop row.
    case collapsed
    /// The whole recorder.
    case expanded
    /// The whole column or page: the whole recorder, the live timeline, and the bookmarks.
    case full

    /// What VoiceOver hears for it.
    public var spokenName: String {
        switch self {
        case .mini: return "Mini"
        case .collapsed: return "Collapsed"
        case .expanded: return "Expanded"
        case .full: return "Full"
        }
    }

    /// The next size up or down, staying at the ends.
    public func stepped(up: Bool) -> RecorderSheetSize {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        return all[max(0, min(all.count - 1, index + (up ? 1 : -1)))]
    }

    // MARK: Rules

    /// The size the sheet rests at for a posture: the whole recorder on the open Duo's right page, which has the room
    /// (the left page has the notes); one row on a closed Duo or another iPhone turned on its side (`isWide`); a little
    /// more in the hand upright, where the whole recorder fits one thumb. The keyboard still takes it to one row.
    public static func resting(in layout: SurfaceLayout, isWide: Bool) -> RecorderSheetSize {
        switch layout {
        case .spread: return .expanded
        case .column: return isWide ? .mini : .collapsed
        case .compact, .stage: return .collapsed
        }
    }

    /// The smallest the sheet is drawn at a rest: its posture's size, or big enough for a notice.
    public static func floor(rest: RecorderSheetSize, hasNotice: Bool) -> RecorderSheetSize {
        hasNotice ? max(rest, .collapsed) : rest
    }

    /// The level the sheet is at: the expansion if the person has made one, else its posture's rest, never below the
    /// floor.
    public static func selected(expansion: RecorderSheetSize?, rest: RecorderSheetSize, hasNotice: Bool) -> RecorderSheetSize {
        max(expansion ?? rest, floor(rest: rest, hasNotice: hasNotice))
    }

    /// The size drawn for a level. The keyboard takes all but one row, and a notice is never hidden by a small size,
    /// even over a keyboard. Neither changes the expansion, so the sheet comes back when they go.
    public func rendered(keyboardUp: Bool, hasNotice: Bool) -> RecorderSheetSize {
        let size: RecorderSheetSize = keyboardUp ? .mini : self
        return size == .mini && hasNotice ? .collapsed : size
    }

    /// The expansion after a tap on the grabber at a drawn size: up one size, and from the whole column back to rest.
    public static func expansionAfterTap(drawn: RecorderSheetSize) -> RecorderSheetSize? {
        drawn == .full ? nil : drawn.stepped(up: true)
    }

    /// The expansion after Collapse: down one size, or back to rest at the floor.
    public static func expansionAfterCollapse(drawn: RecorderSheetSize, floor: RecorderSheetSize) -> RecorderSheetSize? {
        let down = drawn.stepped(up: false)
        return down <= floor ? nil : down
    }

    /// How fast a downward flick has to go to dismiss the sheet from any level, in points a second.
    public static let flickSpeed: CGFloat = 900

    /// How far ahead a release's speed reaches, in seconds, when choosing where it lands.
    private static let projection: CGFloat = 0.1

    /// The expansion a drag ends on: nil is back at rest. A downward flick dismisses from any level; otherwise the
    /// sheet lands on the reachable size nearest where it was let go (with a little of its speed), and a landing at
    /// or below the floor is rest.
    /// - Parameters:
    ///   - start: The size drawn when the drag began.
    ///   - translation: How far it moved, down positive.
    ///   - velocity: How fast it was moving when let go, in points a second, down positive.
    ///   - floor: The smallest the sheet can be drawn (`floor(rest:hasNotice:)`).
    ///   - heights: How tall each size is; a size missing from it isn't landed on.
    public static func expansionAfterDrag(from start: RecorderSheetSize, translation: CGFloat, velocity: CGFloat, floor: RecorderSheetSize,
                                          heights: [RecorderSheetSize: CGFloat]) -> RecorderSheetSize? {
        if velocity >= flickSpeed, translation > 0 { return nil }
        let reachable = allCases.filter { $0 >= floor && heights[$0] != nil }
        guard let height = heights[start], !reachable.isEmpty else { return start > floor ? start : nil }
        let target = height - translation - velocity * projection
        let landing = reachable.min { abs(heights[$0]! - target) < abs(heights[$1]! - target) } ?? start
        return landing <= floor ? nil : landing
    }

    /// The reachable size nearest a height, for what the sheet shows mid-drag.
    public static func nearest(to height: CGFloat, floor: RecorderSheetSize, heights: [RecorderSheetSize: CGFloat]) -> RecorderSheetSize {
        allCases.filter { $0 >= floor && heights[$0] != nil }
            .min { abs(heights[$0]! - height) < abs(heights[$1]! - height) } ?? floor
    }

    /// The sheet's height for a raw one while dragged: exact between the ends, and past them less and less.
    public static func trackedHeight(_ raw: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        if raw > maximum { return maximum + rubberBand(raw - maximum) }
        if raw < minimum { return minimum - rubberBand(minimum - raw) }
        return raw
    }

    private static func rubberBand(_ distance: CGFloat) -> CGFloat { 36 * (1 - 1 / (distance / 90 + 1)) }

    /// Whether the newest caption's line, this tall, shows under notes that keep their minimum in `available`: in the
    /// hand it gives way before the notes do.
    public static func captionLineFits(height: CGFloat, in available: CGFloat, minimumNotes: CGFloat) -> Bool {
        height > 0 && available - height >= minimumNotes
    }

    /// Whether a keyboard this tall takes the screen. A hardware keyboard's bar is shorter and leaves the sheet alone.
    public static func keyboardTakesTheScreen(height: CGFloat) -> Bool { height >= 120 }
}

extension RecorderSheetSize: Comparable {
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: RecorderSheetSize, b: RecorderSheetSize) -> Bool { a.rank < b.rank }
}

// MARK: - The look

/// What differs between the sheet in the hand and on the open Duo's right page.
struct RecorderSheetLook {
    /// The clock at the whole recorder's size.
    let wholeClock: CGFloat
    let meterStack: MeterStack
    let controls: RecorderControlMetrics
    /// In the hand: the sheet reaches the screen's sides, and the title and what records along head the notes above
    /// it, so the sheet shows them only at full, which covers the notes. On the open Duo the title heads the left page
    /// and the chips are in the sheet.
    let inHand: Bool
    /// The captions take what's left of the page and give way first, and only the whole-page size has them in the
    /// sheet (over smaller sizes they're on the page above it). In the hand the strip is in the sheet from expanded
    /// up, and under that the newest line sits on the sheet.
    let captionsFill: Bool
    /// The live timeline from the whole recorder up, as on the page, which rests there; otherwise only at full.
    let timelineWhole: Bool

    static let hand = RecorderSheetLook(wholeClock: 64, meterStack: .pocket, controls: .pocket, inHand: true, captionsFill: false,
                                        timelineWhole: false)
    static let page = RecorderSheetLook(wholeClock: 76, meterStack: .page, controls: .page, inHand: false, captionsFill: true,
                                        timelineWhole: true)
}

// MARK: - The column

/// In the hand: what's recording (the title, and the byline with what records along), your notes, and the newest
/// caption on top; the sheet below.
struct RecorderSheetColumn: View {
    let parts: RecorderPieces
    let expansion: Binding<RecorderSheetSize?>
    @Environment(\.surfaceLayout) private var layout
    /// A line of notes at the person's text size.
    @ScaledMetric(relativeTo: .body) private var notesLine: CGFloat = 22
    @State private var isWide = false

    /// One column rests as one column does, a spread too narrow for its two pages too.
    private var posture: SurfaceLayout {
        if case .spread = layout { return .column }
        return layout
    }

    var body: some View {
        RecorderSheetLayout(parts: parts, expansion: expansion, rest: RecorderSheetSize.resting(in: posture, isWide: isWide), look: .hand) { drawn in
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                RecorderNotesHeader(parts: parts, inHand: true)
                    .padding(.horizontal, RecorderInsets.touch + DaybookSpacing.s2)
                // At least two lines of notes. Laid out last, as the most flexible piece, they take what the sheet
                // leaves; a higher priority would squeeze a notice to its first line instead. The caption's line
                // gives way before they do.
                NotesOverCaptionLine(minimumNotes: notesLine * 2) {
                    parts.slots.notes.frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Under the whole recorder; from expanded up the sheet has the captions' strip.
                    if drawn < .expanded, let line = parts.slots.captionLine {
                        line.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
                    }
                }
            }
            // With the recorder in the sheet, nothing else keeps the title off the top of the screen.
            .padding(.top, DaybookSpacing.s4)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isWide = $0 }
    }
}

/// The notes over the newest caption's line: the line gives way first, so the notes always keep `minimumNotes`.
struct NotesOverCaptionLine: Layout {
    let minimumNotes: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.first?.sizeThatFits(proposal).width ?? 0
        return CGSize(width: width, height: max(minimumNotes, proposal.height ?? minimumNotes))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let notes = subviews.first else { return }
        let line = subviews.count > 1 ? subviews[1] : nil
        let height = line?.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height ?? 0
        let showsLine = RecorderSheetSize.captionLineFits(height: height, in: bounds.height, minimumNotes: minimumNotes)
        let notesHeight = showsLine ? bounds.height - height : bounds.height
        notes.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: notesHeight))
        line?.place(at: CGPoint(x: bounds.minX, y: bounds.minY + notesHeight),
                    proposal: ProposedViewSize(width: bounds.width, height: showsLine ? height : 0))
    }

}

/// `above` over the sheet: the notes in the hand, the captions on the open Duo's right page. Out of the layout at the
/// full size, which takes the whole column or page. The sheet's height follows the finger while dragged, and the
/// size under it shows as it goes.
struct RecorderSheetLayout<Above: View>: View {
    let parts: RecorderPieces
    let expansion: Binding<RecorderSheetSize?>
    let rest: RecorderSheetSize
    let look: RecorderSheetLook
    /// What's over the sheet at the size drawn.
    @ViewBuilder let above: (RecorderSheetSize) -> Above
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keyboardUp = false
    @State private var dragging = false
    @State private var dragHeight: CGFloat?
    @State private var dragLevel: RecorderSheetSize?
    @State private var dragStart: (level: RecorderSheetSize, height: CGFloat)?
    /// Each size's height, for where a drag lands: the size on screen and the whole column as they're laid out, the
    /// others measured while a drag is under way.
    @State private var heights: [RecorderSheetSize: CGFloat] = [:]

    private static var handleHeight: CGFloat { 20 }

    var body: some View {
        let floor = RecorderSheetSize.floor(rest: rest, hasNotice: parts.state.hasNotice)
        let level = dragLevel ?? RecorderSheetSize.selected(expansion: expansion.wrappedValue, rest: rest, hasNotice: parts.state.hasNotice)
        let drawn = level.rendered(keyboardUp: keyboardUp, hasNotice: parts.state.hasNotice)
        VStack(spacing: 0) {
            if drawn != .full {
                above(drawn).transition(fade)
            }
            sheet(drawn, floor: floor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[.full] = $0 }
        .animation(reduceMotion ? nil : DaybookMotion.state, value: rest)
        .animation(reduceMotion ? nil : DaybookMotion.state, value: parts.state.hasNotice)
        .daybookMotion(DaybookMotion.state, value: parts.state.pause)
        .modifier(KeyboardWatch(up: $keyboardUp))
    }

    /// Fades, with its own curve under Reduce Motion, where nothing else may animate.
    private var fade: AnyTransition { reduceMotion ? .opacity.animation(DaybookMotion.reduced) : .opacity }

    private func sheet(_ drawn: RecorderSheetSize, floor: RecorderSheetSize) -> some View {
        VStack(spacing: 0) {
            // While the keyboard is up the sheet stays one row, and a grabber there could only do nothing.
            if !keyboardUp { handle(drawn, floor: floor) }
            RecorderSheetContent(parts: parts, size: drawn, look: look, keyboardUp: keyboardUp, space: space)
                // The foot stays put under the thumb and the size under the finger sinks behind the grabber.
                .frame(height: dragHeight.map { max(0, $0 - Self.handleHeight) }, alignment: .bottom)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: drawn == .full ? .infinity : nil, alignment: .top)
        .background { measuringCopies(of: drawn, floor: floor) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if dragHeight == nil { heights[drawn] = $0 } }
        // Past the foot of the screen; in the hand out to its sides too, on the page clear of the crease.
        .background { surface.ignoresSafeArea(.container, edges: look.inHand ? [.bottom, .horizontal] : .bottom) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recorder")
        .accessibilityAction(.escape) { setExpansion(nil, animation: stateAnimation) }
    }

    private var surface: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: DaybookRadius.panel, topTrailingRadius: DaybookRadius.panel, style: .continuous)
        #if os(iOS)
        return Color.clear.glassEffect(.regular, in: shape)
        #else
        return shape.fill(.regularMaterial)
        #endif
    }

    /// Only while a drag is under way, the sizes that aren't on screen, laid out out of sight, for their real heights
    /// at this width and text size. Mini isn't one of them under a notice, which it can't be drawn with.
    @ViewBuilder private func measuringCopies(of drawn: RecorderSheetSize, floor: RecorderSheetSize) -> some View {
        if dragging {
            ForEach(RecorderSheetSize.allCases.filter { $0 != drawn && $0 != .full && $0 >= floor }, id: \.self) { other in
                RecorderSheetContent(parts: parts, size: other, look: look, keyboardUp: false, space: nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[other] = $0 + Self.handleHeight }
                    .hidden()
            }
        }
    }

    private func handle(_ drawn: RecorderSheetSize, floor: RecorderSheetSize) -> some View {
        Button {
            setExpansion(RecorderSheetSize.expansionAfterTap(drawn: drawn), animation: stateAnimation)
        } label: {
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: Self.handleHeight)
                // Under the finger, 44 pt tall; the row below still takes its own touches.
                .contentShape(Rectangle().inset(by: -12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recorder")
        .accessibilityValue(drawn.spokenName)
        .accessibilityActions {
            if drawn != .full { Button("Expand") { setExpansion(drawn.stepped(up: true), animation: stateAnimation) } }
            if drawn > floor {
                Button("Collapse") {
                    setExpansion(RecorderSheetSize.expansionAfterCollapse(drawn: drawn, floor: floor), animation: stateAnimation)
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { value in track(value, drawn: drawn, floor: floor) }
                .onEnded { value in settle(value, drawn: drawn, floor: floor) })
    }

    private var stateAnimation: Animation? { reduceMotion ? nil : DaybookMotion.state }

    private func setExpansion(_ value: RecorderSheetSize?, animation: Animation?) {
        withAnimation(animation) { expansion.wrappedValue = value }
    }

    /// Follows the finger: the height exactly, rubber-banding past the ends, and the size nearest it in place. Under
    /// Reduce Motion nothing moves until it's let go.
    private func track(_ value: DragGesture.Value, drawn: RecorderSheetSize, floor: RecorderSheetSize) {
        dragging = true
        guard !reduceMotion else { return }
        let start = dragStart ?? (drawn, heights[drawn] ?? 0)
        if dragStart == nil { dragStart = start }
        let height = RecorderSheetSize.trackedHeight(start.height - value.translation.height, minimum: heights[floor] ?? start.height,
                                                     maximum: heights[.full] ?? start.height)
        dragHeight = height
        let level = RecorderSheetSize.nearest(to: height, floor: floor, heights: heights)
        if level != (dragLevel ?? drawn) { withAnimation(DaybookMotion.state) { dragLevel = level } }
    }

    /// Lands where it was let go, on a spring carrying the release's speed.
    private func settle(_ value: DragGesture.Value, drawn: RecorderSheetSize, floor: RecorderSheetSize) {
        let start = dragStart?.level ?? drawn
        let landing = RecorderSheetSize.expansionAfterDrag(from: start, translation: value.translation.height, velocity: value.velocity.height,
                                                           floor: floor, heights: heights)
        let target = heights[max(landing ?? rest, floor)]
        let distance = (target ?? dragHeight ?? 0) - (dragHeight ?? target ?? 0)
        let speed = distance == 0 ? 0 : min(25, max(-25, -value.velocity.height / distance))
        let animation: Animation? = reduceMotion ? nil : DaybookMotion.settle(initialVelocity: speed)
        withAnimation(animation) {
            expansion.wrappedValue = landing
            dragHeight = nil
            dragLevel = nil
            dragStart = nil
            dragging = false
        }
    }
}

// MARK: - A size's contents

/// A size's contents, the same for the sheet and for measuring it. The clock, the meter, Bookmark, and Stop travel
/// between their places in each size; what's only in one size crossfades in and out.
private struct RecorderSheetContent: View {
    let parts: RecorderPieces
    let size: RecorderSheetSize
    let look: RecorderSheetLook
    let keyboardUp: Bool
    /// Where the travelling pieces are matched; nil for a measuring copy.
    let space: Namespace.ID?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var whole: Bool { size == .expanded || size == .full }
    /// What records along: in the hand it's over the notes, so here only at full, which covers them; on the page from
    /// the whole recorder up.
    private var showsChips: Bool { look.inHand ? size == .full : whole }
    /// The title: in the hand only at full, for the same reason; on the page it heads the left page.
    private var showsTitle: Bool { look.inHand && size == .full }
    private var showsTimeline: Bool { size == .full || (size == .expanded && look.timelineWhole) }

    /// In the hand at the accessibility sizes, a pause's box takes the captions' room: nothing is heard while it's
    /// paused, and the notes keep theirs. Over smaller sizes the page shows them above the sheet.
    private var showsCaptions: Bool {
        guard size == .full || (size == .expanded && !look.captionsFill) else { return false }
        return look.captionsFill || !(typeSize.isAccessibilitySize && parts.state.pause != nil)
    }

    private var clockSize: CGFloat {
        switch size {
        case .mini: return 28
        case .collapsed: return 34
        case .expanded, .full: return look.wholeClock
        }
    }

    private var fade: AnyTransition { reduceMotion ? .opacity.animation(DaybookMotion.reduced) : .opacity }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: DaybookSpacing.s3) {
                if showsCaptions {
                    if look.captionsFill {
                        // The captions take what's left and give way first, newest lines kept: Bookmark and Stop always fit.
                        parts.slots.captions
                            .frame(minHeight: 0, maxHeight: .infinity, alignment: .bottom)
                            .clipped()
                            .layoutPriority(-1)
                            .padding(.horizontal, DaybookSpacing.s2)
                            .transition(fade)
                    } else {
                        parts.slots.captions.transition(fade)
                    }
                }
                // Here at every size, empty in mini (which a notice is never drawn in), so it's heard as it arrives.
                parts.slots.notice
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if size != .mini { controls.fixedSize(horizontal: false, vertical: true).layoutPriority(1) }
            }
            .padding(.horizontal, DaybookSpacing.s4)
            .padding(.top, size == .mini ? 0 : DaybookSpacing.s2)
            .padding(.bottom, size == .mini ? 0 : DaybookSpacing.s3)
        }
    }

    private var controls: some View {
        RecorderControlRow(spacing: look.controls.spacing) {
            parts.bookmark(.tile(look.controls)).matched("bookmark", in: space)
        } trailing: {
            // Write by Hand between them: the handwriting tools are the control layer's, never over the notes.
            if let write = parts.slots.write { write(look.controls).transition(fade) }
            parts.stop(look.controls).matched("stop", in: space)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: size == .mini ? 0 : 10) {
            if size != .mini { phaseRow.transition(fade) }
            if showsChips { parts.chips.transition(fade) }
            if showsTitle { RecorderTitle(parts.state.title, rename: parts.state.rename).transition(fade) }
            clockRow
            if size != .mini, let pause = parts.state.pause {
                RecorderPauseBox(pause, metrics: look.controls, resume: parts.actions.resume)
                    .daybookTransition(.opacity.combined(with: .move(edge: .top)))
            } else if whole {
                parts.meters(look.meterStack).matched("meter", in: space)
            }
            if showsTimeline { parts.slots.details.transition(fade) }
            if size == .full {
                if let log = parts.slots.log {
                    log.frame(maxHeight: .infinity, alignment: .top).transition(fade)
                } else if !look.captionsFill {
                    Spacer(minLength: 0)
                }
            }
        }
        // The header holds its size past this, so it never squeezes the notes away: during a call the notes,
        // Bookmark, and Stop come first.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, size == .mini ? DaybookSpacing.s4 : RecorderInsets.touch)
        .padding(.top, size == .mini && keyboardUp ? DaybookSpacing.s2 : 0)
        .padding(.bottom, size == .mini ? (keyboardUp ? DaybookSpacing.s2 : 0) : DaybookSpacing.s2)
    }

    private var clockRow: some View {
        HStack(alignment: .center, spacing: size == .mini ? DaybookSpacing.s3 : whole ? 8 : DaybookSpacing.s3) {
            if size == .mini { miniPhase.layoutPriority(1).transition(fade) }
            parts.clock(clockSize)
                // Each size's clock at its own font, so its digits never reflow; the two meet at the same place and
                // crossfade as they travel. (Under Reduce Motion, only the fade.)
                .matched("clock", in: space, anchor: .leading)
                .transition(fade)
                .id(clockSize)
            if !whole, parts.state.pause == nil {
                parts.meters(.compact).matched("meter", in: space)
            } else if size == .mini {
                Spacer(minLength: 0)
            }
            if size == .mini { miniButtons }
        }
        .frame(minHeight: size == .mini ? RecorderControlMetrics.glyph.height : nil)
    }

    /// The phase, and the camera at its end, so a photo never waits for the sheet to be expanded.
    private var phaseRow: some View {
        HStack(alignment: .center, spacing: DaybookSpacing.s3) {
            parts.phase()
            if let accessory = parts.slots.accessory { accessory }
        }
    }

    @ViewBuilder private var miniButtons: some View {
        if let pause = parts.state.pause, pause.canResume {
            resumeGlyph
        } else {
            parts.bookmark(.glyph).fixedSize().matched("bookmark", in: space)
        }
        parts.stop(.glyph, glyph: true).fixedSize().matched("stop", in: space)
    }

    /// The dot and the phase, the dot alone when the row can't spare the words (the clock says it for VoiceOver); a
    /// warning stays beside it while there's room.
    @ViewBuilder private var miniPhase: some View {
        if let phase = parts.state.phase {
            ViewThatFits(in: .horizontal) {
                RecordingPhaseLabel(phase.phase, title: phase.title, detail: phase.detailIsWarning ? phase.detail : nil,
                                    detailIsWarning: phase.detailIsWarning, detailYields: true)
                RecordingPhaseLabel(phase.phase, title: "")
            }
        }
    }

    private var resumeGlyph: some View {
        Button(action: parts.actions.resume) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DaybookSpacing.s1 + 2) {
                    resumeDot
                    Text("Resume").lineLimit(1)
                }
                resumeDot
            }
            .font(.headline)
            .foregroundStyle(DaybookPalette.Ink.title)
            .padding(.horizontal, DaybookSpacing.s3)
            .frame(minWidth: RecorderControlMetrics.glyph.height, minHeight: RecorderControlMetrics.glyph.height)
            .contentShape(Rectangle())
        }
        .daybookControl(.standard, shape: .capsule)
        .fixedSize()
        .matched("bookmark", in: space)
        .accessibilityLabel("Resume Recording")
    }

    private var resumeDot: some View {
        Circle().fill(DaybookPalette.Ink.record).frame(width: 12, height: 12).daybookGlow(DaybookPalette.Ink.record, radius: 3)
    }
}

private extension View {
    /// A piece that travels between sizes.
    @ViewBuilder func matched(_ id: String, in space: Namespace.ID?, anchor: UnitPoint = .center) -> some View {
        if let space { matchedGeometryEffect(id: id, in: space, anchor: anchor) } else { self }
    }
}

// MARK: - The keyboard

/// Says whether the keyboard has taken the screen, on the keyboard's own curve.
private struct KeyboardWatch: ViewModifier {
    @Binding var up: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                set(RecorderSheetSize.keyboardTakesTheScreen(height: frame?.height ?? 0), note: note)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                set(false, note: note)
            }
        #else
        content
        #endif
    }

    #if os(iOS)
    private func set(_ value: Bool, note: Notification) {
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        // The keyboard's own curve (`UIView.AnimationCurve` 7) as a spring: a fade-free cut under Reduce Motion.
        let curve: Animation? = reduceMotion || duration == 0 ? nil : .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)
        withAnimation(curve) { up = value }
    }
    #endif
}
