import DaybookKit
import SwiftUI

/// The player: one glass card at the bottom of the page, shown once something plays. Back 15,
/// play (mint while playing), forward 15, speed, Bookmark, and close; the scrubber under them, with
/// the time at its ends. While the audio downloads it shows how far it has got; when the audio isn't on this
/// iPhone and can't be fetched, it says so plainly.
struct PlayerBar: View {
    @ObservedObject var player: PlaybackController
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    private static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]
    @State private var bookmarks = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if player.isActive(for: meeting.id) {
            Group {
                switch player.phase {
                case .loading(let fraction): loading(fraction)
                case .unavailable(let message): unavailable(message)
                case .ready, .idle: controls
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 560)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, PhoneStyle.Space.s3)
            .padding(.bottom, PhoneStyle.Space.s2)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var caption: String? {
        guard meeting.tracks.count > 1, let track = meeting.tracks.first(where: { $0.id == player.trackID }) else { return nil }
        return SourceDescription.name(track, in: meeting)
    }

    /// The buttons in one row, then the scrubber with the time at its ends, as Podcasts does: the
    /// row keeps its room on the narrowest iPhone, and the time never truncates.
    private var controls: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                    .accessibilityLabel("Back 15 seconds")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PhoneStyle.onPlayFill)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(PhoneStyle.playFill))
                        .neonGlow(player.isPlaying ? PhoneStyle.neonMint : .clear, radius: 6)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                    .accessibilityLabel("Forward 15 seconds")
                Spacer(minLength: 0)
                Menu {
                    Picker("Speed", selection: $player.rate) {
                        ForEach(Self.rates, id: \.self) { rate in Text(rate.formatted() + "×").tag(rate) }
                    }
                } label: {
                    Text(player.rate.formatted() + "×")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(PhoneStyle.quietFill, in: Capsule())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Playback speed, \(player.rate.formatted()) times")
                Button {
                    if let trackID = player.trackID {
                        library.addBookmark(in: meeting.id, trackID: trackID, at: player.position)
                        bookmarks += 1
                    }
                } label: {
                    Image(systemName: "bookmark").symbolEffect(.bounce, value: bookmarks)
                        .foregroundStyle(PhoneStyle.bookmark)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Add bookmark here")
                Button { withAnimation(.snappy(duration: 0.25)) { player.close() } } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Close player")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PhoneStyle.Ink.body)
            Scrubber(position: player.position, duration: player.duration) { player.seek(to: $0) }
            HStack(alignment: .firstTextBaseline, spacing: PhoneStyle.Space.s2) {
                Text(TimeLabel.short(player.position))
                    .contentTransition(.numericText(value: player.position))
                Spacer(minLength: 0)
                if let caption { Text(caption).lineLimit(1) }
                Spacer(minLength: 0)
                Text(TimeLabel.short(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(PhoneStyle.Ink.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func loading(_ fraction: Double?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down").foregroundStyle(PhoneStyle.Ink.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(fraction.map { "Downloading the audio · \(Int(($0 * 100).rounded()))%" } ?? "Getting the audio…")
                    .font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
                    .contentTransition(.numericText())
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.brand(width: nil, height: 3))
                } else {
                    ProgressView(value: 0.05).progressViewStyle(.brand(width: nil, height: 3)).opacity(0.5)
                }
            }
            Button { player.close() } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(PhoneStyle.Ink.body)
                .accessibilityLabel("Cancel download")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func unavailable(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "icloud.slash").foregroundStyle(PhoneStyle.Ink.secondary).accessibilityHidden(true)
            Text(message).font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { player.close() } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(PhoneStyle.Ink.body)
                .accessibilityLabel("Close")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// While browsing, what's playing stays in reach: a small glass capsule above Record.
struct MiniPlayer: View {
    @ObservedObject var player: PlaybackController
    let meeting: Meeting
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(PhoneStyle.neonMint)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: player.isPlaying && !reduceMotion)
                        .neonGlow(PhoneStyle.neonMint, radius: 3)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(TimeLabel.short(player.position) + " / " + TimeLabel.short(player.duration))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Now playing: \(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title)")
            .accessibilityHint("Opens the conversation")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.close() } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("Close player")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 2)
        .glassEffect(.regular, in: Capsule())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The byline's play control: a teal pill with the length, which becomes a live mint waveform and
/// the position while this conversation plays.
struct PlayPill: View {
    @ObservedObject var player: PlaybackController
    let meeting: Meeting
    let duration: TimeInterval
    let start: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var here: Bool { player.meetingID == meeting.id && player.phase == .ready }
    private var playing: Bool { here && player.isPlaying }

    var body: some View {
        Button {
            if here { player.toggle() } else { start() }
        } label: {
            HStack(spacing: 5) {
                Group {
                    if playing {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, options: .repeating, isActive: !reduceMotion)
                    } else {
                        Image(systemName: "play.fill").imageScale(.small)
                    }
                }
                .contentTransition(.symbolEffect(.replace))
                Text(here ? TimeLabel.short(player.position) : DurationLabel.format(duration)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(playing && scheme == .dark ? PhoneStyle.neonMint : PhoneStyle.Ink.link)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(PhoneStyle.accent.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Pause" : "Play conversation, \(SpokenTime.format(duration))")
    }
}

/// The playhead: a thin mint line that fills as the recording plays, with a knob that grows while
/// it's dragged. VoiceOver adjusts it in 15-second steps.
struct Scrubber: View {
    let position: TimeInterval
    let duration: TimeInterval
    let seek: (TimeInterval) -> Void
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let fraction = dragging ?? (duration > 0 ? min(1, max(0, position / duration)) : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                Capsule().fill(PhoneStyle.neonMint).frame(width: max(4, width * fraction), height: 4)
                    .neonGlow(PhoneStyle.neonMint, radius: 3)
                Circle().fill(PhoneStyle.neonMint)
                    .frame(width: dragging == nil ? 12 : 20, height: dragging == nil ? 12 : 20)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .offset(x: width * fraction - (dragging == nil ? 6 : 10))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragging = min(1, max(0, value.location.x / width)) }
                .onEnded { _ in
                    if let dragging { seek(dragging * duration) }
                    dragging = nil
                })
            .animation(.snappy(duration: 0.15), value: dragging == nil)
        }
        .frame(height: 22)
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
