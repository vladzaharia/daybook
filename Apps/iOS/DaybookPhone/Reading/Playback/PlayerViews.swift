import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// The conversation's player at the foot of its page: DaybookUI's `PlayerBar`, the Mac's too, over the reading
/// session's player. A bookmark it adds goes into the recording playing, at the time it's at.
struct ConversationPlayer: View {
    let library: LibraryController
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session

    var body: some View {
        PlayerBar(player: session.player, meeting: meeting) { trackID, seconds in
            library.addBookmark(in: meeting.id, trackID: trackID, at: seconds)
        }
        // Placed as a safe-area bar, the page's scroll edge effect runs under it, but only under something drawn: the
        // bar's room around the glass is drawn, unseen, so the page doesn't read sharp beneath the player.
        .background {
            if session.player.isActive(for: meeting.id) {
                Rectangle().fill(Color.primary.opacity(0.001)).accessibilityHidden(true)
            }
        }
    }
}

/// While browsing, what's playing stays in reach: a small glass capsule above Record.
struct MiniPlayer: View {
    @Bindable var player: PlaybackController
    let meeting: Meeting
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(PhoneStyle.neonMint)
                        .symbolEffect(
                            .variableColor.iterative, options: .repeating,
                            isActive: player.isPlaying && !reduceMotion
                        )
                        .neonGlow(PhoneStyle.neonMint, radius: 3)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title).font(
                            .subheadline.weight(.semibold)
                        ).lineLimit(1)
                        Text(
                            TimeLabel.short(player.position) + " / "
                                + TimeLabel.short(player.duration)
                        )
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(
                "Now playing: \(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title)"
            )
            .accessibilityHint("Opens the conversation")
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").contentTransition(
                    .symbolEffect(.replace)
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button {
                player.close()
            } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(
                    width: 44, height: 44
                ).contentShape(Rectangle())
            }
            .accessibilityLabel("Close player")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 2)
        .glassEffect(.regular, in: Capsule())
        .daybookTransition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The byline's play control: a teal pill with the length, which becomes a live mint waveform and
/// the position while this conversation plays.
struct PlayPill: View {
    @Bindable var player: PlaybackController
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
                            .symbolEffect(
                                .variableColor.iterative.dimInactiveLayers.nonReversing,
                                options: .repeating, isActive: !reduceMotion)
                    } else {
                        Image(systemName: "play.fill").imageScale(.small)
                    }
                }
                .contentTransition(.symbolEffect(.replace))
                Text(here ? TimeLabel.short(player.position) : DurationLabel.format(duration))
                    .monospacedDigit()
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
