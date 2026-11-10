import DaybookDesign
import DaybookKit
import SwiftUI

/// A player the shared player bar drives: the Mac's and the iPhone's, both over DaybookKit's `PlaybackEngine`.
/// Each observes itself, so the bar redraws as it plays.
@MainActor
public protocol PlaybackControlling: AnyObject {
    /// The conversation loaded, or loading.
    var meetingID: UUID? { get }
    /// Which of its recordings.
    var trackID: UUID? { get }
    var phase: PlaybackPhase { get }
    var isPlaying: Bool { get }
    var position: TimeInterval { get }
    var duration: TimeInterval { get }
    /// Playback speed, kept from one recording to the next.
    var rate: Float { get set }
    /// How many times each skip was asked for (`PlaybackEngine`), so the skip buttons answer every press.
    var backSkips: Int { get }
    var forwardSkips: Int { get }
    /// Something wrong with the recording that's open, in one sentence: playback stopped early, say. Nil on the iPhone,
    /// whose problems are an unavailable phase.
    var problem: String? { get }
    /// The system's own words behind `problem` or an unavailable phase, when there are some.
    var problemDetails: String? { get }
    func toggle()
    func skip(_ seconds: TimeInterval)
    func seek(to seconds: TimeInterval)
    /// Stops and lets the recording go, which hides the bar.
    func close()
}

/// The player, on both apps: one glass surface at the foot of a conversation's page, shown once something of that
/// conversation plays. Back 15, Play (mint while playing), Forward 15, the position with the time either side of it
/// (played, and what's left), the speed, an amber Bookmark, and Close.
///
/// It lays itself out in the room it has: everything on one row; on the Mac, then without the skip buttons and then
/// without the speed; then, as on every iPhone, the buttons on one row and the scrubber under them with the times at
/// its ends. The Mac's slider is the system's; under touch it's `Scrubber`, with a finger's hit area and an amber tick
/// for each bookmark in the recording (`ScrubberBookmarks`). While the audio downloads it says how far it has got; when
/// it can't play, it says why.
public struct PlayerBar<Player: PlaybackControlling>: View {
    private let player: Player
    private let meeting: Meeting
    private let isRecording: Bool
    private let addBookmark: @MainActor (_ trackID: UUID, _ seconds: TimeInterval) -> Void
    @State private var bookmarks = 0
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.creaseEdge) private var creaseEdge

    /// The speeds offered.
    public static var rates: [Float] { [0.75, 1, 1.25, 1.5, 2] }

    /// - Parameters:
    ///   - isRecording: This device is recording, so Play is off (the microphone would record it).
    ///   - addBookmark: Adds a bookmark in the recording playing, at a time in it.
    public init(
        player: Player, meeting: Meeting, isRecording: Bool = false,
        addBookmark: @escaping @MainActor (_ trackID: UUID, _ seconds: TimeInterval) -> Void
    ) {
        self.player = player
        self.meeting = meeting
        self.isRecording = isRecording
        self.addBookmark = addBookmark
    }

    private var touch: Bool { density == .touch }

    public var body: some View {
        if player.meetingID == meeting.id, player.phase != .idle {
            FloatingGlassGroup {
                switch player.phase {
                case .loading(let fraction): message { loading(fraction) }
                case .unavailable(let words): message { unavailable(words) }
                case .ready, .idle: controls
                }
            }
            .frame(maxWidth: touch ? 560 : ReadingGeometry.measure)
            .padding(.horizontal, touch ? DaybookSpacing.s3 : DaybookSpacing.s5)
            // On the open Duo, clear of the crease, as the page is.
            .padding(
                Edge.Set(creaseEdge ?? .leading),
                creaseEdge == nil ? 0 : ReadingGeometry.creaseClearance - DaybookSpacing.s3
            )
            .padding(.bottom, touch ? DaybookSpacing.s2 : DaybookSpacing.s3)
            .daybookTransition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Layouts

    @ViewBuilder private var controls: some View {
        // The first that fits: one row as wide as it likes, then narrower rows (the Mac), then two rows.
        ViewThatFits(in: .horizontal) {
            oneRow(skips: true, speed: true)
            if !touch {
                oneRow(skips: false, speed: true)
                oneRow(skips: false, speed: false)
            }
            twoRows
        }
    }

    private func oneRow(skips: Bool, speed: Bool) -> some View {
        VStack(spacing: 2) {
            if let problem = player.problem { problemLine(problem) }
            HStack(spacing: touch ? 4 : 10) {
                if skips { skipButton(back: true) }
                playButton
                if skips { skipButton(back: false) }
                VStack(spacing: 0) {
                    if let caption {
                        Text(caption).font(.system(size: touch ? 12 : 10)).foregroundStyle(
                            DaybookPalette.Ink.secondary
                        ).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        // Equal widths either side keep the slider centred.
                        playedTime.frame(minWidth: 44, alignment: .trailing)
                        positionControl.frame(minWidth: 72)
                        remainingTime.frame(minWidth: 44, alignment: .leading)
                    }
                }
                if speed { speedMenu }
                bookmarkButton
                closeButton
            }
        }
        .padding(.horizontal, 14).padding(.vertical, touch ? 6 : 8)
        .floatingGlass(
            in: Capsule(style: .circular), backdrop: creaseEdge == nil ? nil : DaybookPalette.paper)
    }

    /// The buttons on a row, then the position under them with the times at its ends, as Podcasts does: the row keeps
    /// its room on the narrowest iPhone, and the times never truncate.
    private var twoRows: some View {
        VStack(spacing: 2) {
            if let problem = player.problem { problemLine(problem) }
            HStack(spacing: 4) {
                skipButton(back: true)
                playButton
                skipButton(back: false)
                Spacer(minLength: 0)
                speedMenu
                bookmarkButton
                closeButton
            }
            positionControl
            HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
                playedTime
                Spacer(minLength: 0)
                if let caption {
                    Text(caption).font(timeFont).foregroundStyle(DaybookPalette.Ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                remainingTime
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .floatingGlass(
            in: DaybookRadius.shape(DaybookRadius.panel),
            backdrop: creaseEdge == nil ? nil : DaybookPalette.paper)
    }

    /// A sentence in place of the controls, while there's nothing to play yet.
    private func message(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.leading, 14).padding(.trailing, touch ? 4 : 10).padding(
                .vertical, touch ? 4 : 8
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .floatingGlass(
                in: DaybookRadius.shape(DaybookRadius.panel),
                backdrop: creaseEdge == nil ? nil : DaybookPalette.paper)
    }

    // MARK: Pieces

    /// Which recording plays, when the conversation has several: its name, as Info › Audio says it.
    private var caption: String? {
        guard meeting.tracks.count > 1,
            let track = meeting.tracks.first(where: { $0.id == player.trackID })
        else { return nil }
        return RecordingWords.name(track, in: meeting)
    }

    private var timeFont: Font { DaybookFont.time.font(density) }

    private var playedTime: some View {
        Text(TimeLabel.short(player.position))
            .font(timeFont)
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .contentTransition(reduceMotion ? .identity : .numericText(value: player.position))
            .lineLimit(1)
            .accessibilityLabel(SpokenTime.format(player.position))
    }

    /// What's left, as Podcasts and Music show it: "−12:03".
    private var remainingTime: some View {
        let left = Self.remaining(position: player.position, duration: player.duration)
        return Text(Self.remainingLabel(left))
            .font(timeFont)
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .lineLimit(1)
            .accessibilityLabel("\(SpokenTime.format(left)) left")
    }

    /// What's left to play, never less than nothing.
    public static func remaining(position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        max(0, duration - position)
    }

    /// "−12:03": the time left, with the minus a time before the start also wears.
    public static func remainingLabel(_ seconds: TimeInterval) -> String {
        "−" + TimeLabel.short(max(0, seconds))
    }

    @ViewBuilder private var positionControl: some View {
        #if os(macOS)
            Slider(
                value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                in: 0...max(1, player.duration)
            )
            .controlSize(.mini)
            .tint(DaybookPalette.neonMint)
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                "\(SpokenTime.format(player.position)) of \(SpokenTime.format(player.duration))")
        #else
            Scrubber(
                position: player.position, duration: player.duration,
                bookmarks: ScrubberBookmarks.fractions(in: meeting, trackID: player.trackID, duration: player.duration)
            ) { player.seek(to: $0) }
        #endif
    }

    private var playButton: some View {
        let side: CGFloat = touch ? 44 : 28
        return Button {
            player.toggle()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(touch ? .body.weight(.semibold) : .system(size: 12, weight: .semibold))
                .foregroundStyle(DaybookPalette.onPlayFill)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: side, height: side)
                .background(Circle().fill(DaybookPalette.playFill))
                .daybookGlow(player.isPlaying ? DaybookPalette.neonMint : .clear, radius: 5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isRecording)
        .opacity(isRecording ? 0.4 : 1)
        .help(isRecording ? "Playback is off while recording" : "Play or Pause")
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    private func skipButton(back: Bool) -> some View {
        SkipButton(back: back, presses: back ? player.backSkips : player.forwardSkips, touch: touch)
        {
            withAnimation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion)) {
                player.skip(back ? -15 : 15)
            }
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                ForEach(Self.rates, id: \.self) { rate in Text(rate.formatted() + "×").tag(rate) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(player.rate.formatted() + "×")
                .font(
                    touch
                        ? .footnote.weight(.semibold).monospacedDigit()
                        : .system(size: 11, weight: .medium).monospacedDigit()
                )
                .foregroundStyle(DaybookPalette.Ink.body)
                .padding(.horizontal, touch ? 7 : 6).padding(.vertical, touch ? 3 : 2)
                .background(DaybookPalette.quietFill, in: Capsule())
                .frame(minWidth: touch ? 44 : nil, minHeight: touch ? 44 : nil)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .fixedSize()
        #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.plain)
        #endif
        .help("Playback Speed")
        .accessibilityLabel("Playback speed, \(player.rate.formatted()) times")
    }

    private var bookmarkButton: some View {
        Button {
            guard let trackID = player.trackID else { return }
            addBookmark(trackID, player.position)
            bookmarks += 1
        } label: {
            Image(systemName: "bookmark")
                .foregroundStyle(DaybookPalette.bookmark)
                .daybookBounce(value: bookmarks)
                .frame(width: touch ? 44 : nil, height: touch ? 44 : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Add Bookmark at This Moment")
        .accessibilityLabel("Add bookmark here")
    }

    private var closeButton: some View {
        Button {
            withAnimation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion)) {
                player.close()
            }
        } label: {
            Image(systemName: "xmark")
                .font(touch ? .footnote.weight(.semibold) : nil)
                .foregroundStyle(DaybookPalette.Ink.body)
                .frame(width: touch ? 44 : nil, height: touch ? 44 : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(player.phase == .ready ? "Close Player" : "Close")
        .accessibilityLabel(closeLabel)
    }

    private var closeLabel: String {
        if case .loading = player.phase { return "Cancel download" }
        return player.phase == .ready ? "Close player" : "Close"
    }

    private func problemLine(_ problem: String) -> some View {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(DaybookPalette.Ink.warning)
            .lineLimit(2)
            .help(player.problemDetails ?? problem)
    }

    private func loading(_ fraction: Double?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down").foregroundStyle(DaybookPalette.Ink.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    fraction.map { "Downloading the audio · \(Int(($0 * 100).rounded(.down)))%" }
                        ?? "Getting the audio…"
                )
                .font(touch ? .subheadline : .system(size: 12))
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .contentTransition(reduceMotion ? .identity : .numericText())
                // A download's bar; until there's a figure, a faint start of one.
                WorkProgress(fraction: fraction ?? 0.05, style: .bar)
                    .opacity(fraction == nil ? 0.5 : 1)
            }
            closeButton
        }
        .accessibilityElement(children: .contain)
    }

    private func unavailable(_ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "speaker.slash").foregroundStyle(DaybookPalette.Ink.secondary)
                .accessibilityHidden(true)
            Text(words)
                .font(touch ? .subheadline : .system(size: 12))
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(player.problemDetails ?? words)
            Spacer(minLength: 0)
            closeButton
        }
    }
}

/// Back or Forward 15. The arrow turns the way it skips each time it's pressed (the keyboard's shortcut too), and stays
/// still under Reduce Motion. On the Mac it's quiet until the pointer is over it.
private struct SkipButton: View {
    let back: Bool
    let presses: Int
    let touch: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            arrow
                .font(touch ? .title3 : nil)
                .frame(width: touch ? 44 : nil, height: touch ? 44 : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(touch || hovering ? DaybookPalette.Ink.body : DaybookPalette.Ink.secondary)
        .onHover { hovering = $0 }
        .animation(DaybookMotion.hover, value: hovering)
        .help(back ? "Back 15 Seconds (⌥⌘←)" : "Forward 15 Seconds (⌥⌘→)")
        .accessibilityLabel(back ? "Back 15 seconds" : "Forward 15 seconds")
    }

    @ViewBuilder private var arrow: some View {
        let image = Image(systemName: back ? "gobackward.15" : "goforward.15")
        if reduceMotion {
            image
        } else if back {
            image.symbolEffect(.wiggle.counterClockwise, options: .nonRepeating, value: presses)
        } else {
            image.symbolEffect(.wiggle.clockwise, options: .nonRepeating, value: presses)
        }
    }
}

/// The playhead under touch: a thin mint line that fills as the recording plays, with a knob that grows while it's
/// dragged, and a finger's height to grab it by. The recording's bookmarks stand on the line as amber ticks under the
/// knob, so the line that measures time is the one that shows where they are. VoiceOver adjusts it in 15-second steps.
public struct Scrubber: View {
    private let position: TimeInterval
    private let duration: TimeInterval
    private let bookmarks: [Double]
    private let seek: (TimeInterval) -> Void
    @State private var dragging: Double?
    @State private var width: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter bookmarks: Where the recording's bookmarks fall along it, 0 to 1 (`ScrubberBookmarks`).
    public init(
        position: TimeInterval, duration: TimeInterval, bookmarks: [Double] = [],
        seek: @escaping (TimeInterval) -> Void
    ) {
        self.position = position
        self.duration = duration
        self.bookmarks = bookmarks
        self.seek = seek
    }

    /// A bookmark's tick: 2 pt wide and as tall as the knob at rest, so it stands out of the 4 pt line and hides under
    /// the knob as it passes.
    public static let tick = CGSize(width: 2, height: 10)

    /// Where a tick's leading edge sits on a line `width` wide: centred on its fraction, and kept on the line.
    public static func tickOffset(_ fraction: Double, width: CGFloat) -> CGFloat {
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return min(max(0, width - tick.width), max(0, width * clamped - tick.width / 2))
    }

    /// Where along the line a time falls, 0 to 1.
    public static func fraction(position: TimeInterval, duration: TimeInterval) -> Double {
        duration > 0 ? min(1, max(0, position / duration)) : 0
    }

    public var body: some View {
        let fraction = dragging ?? Self.fraction(position: position, duration: duration)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
            Capsule().fill(DaybookPalette.neonMint).frame(
                width: max(4, width * fraction), height: 4
            )
            .daybookGlow(DaybookPalette.neonMint, radius: 3)
            ForEach(Array(bookmarks.enumerated()), id: \.offset) { _, mark in
                Capsule().fill(DaybookPalette.bookmark)
                    .frame(width: Self.tick.width, height: Self.tick.height)
                    .offset(x: Self.tickOffset(mark, width: width))
            }
            Circle().fill(DaybookPalette.neonMint)
                .frame(width: dragging == nil ? 12 : 20, height: dragging == nil ? 12 : 20)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .offset(x: width * fraction - (dragging == nil ? 6 : 10))
        }
        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = max(1, $0)
        }
        // A finger's height to grab, without making the bar taller.
        .daybookHitTarget()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in dragging = min(1, max(0, value.location.x / width)) }
                .onEnded { _ in
                    if let dragging { seek(dragging * duration) }
                    dragging = nil
                }
        )
        .animation(
            DaybookMotion.resolved(DaybookMotion.hover, reduceMotion: reduceMotion),
            value: dragging == nil
        )
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(SpokenTime.format(position)) of \(SpokenTime.format(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(duration, position + 15))
            case .decrement: seek(max(0, position - 15))
            @unknown default: break
            }
        }
    }
}
