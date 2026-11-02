import DaybookDesign
import DaybookKit
import SwiftUI

/// The byline's play control on both apps: a teal pill with the conversation's length, which becomes a live waveform
/// and the position while it plays here. It never truncates (`fixedSize`): a narrow byline gives up its date first.
///
/// What it shows is read from the app's player through `player` as it draws, so only the pill redraws while the
/// position moves.
public struct ConversationPlayPill: View {
    /// The app's player, as the pill reads it.
    public struct Player {
        /// This conversation is in the player (playing or paused partway).
        public var isHere: @MainActor () -> Bool
        public var isPlaying: @MainActor () -> Bool
        /// Where in it, in seconds.
        public var position: @MainActor () -> TimeInterval
        /// Pauses or resumes it, once it's here.
        public var toggle: @MainActor () -> Void
        /// Plays it from the start.
        public var start: @MainActor () -> Void

        public init(isHere: @escaping @MainActor () -> Bool, isPlaying: @escaping @MainActor () -> Bool,
                    position: @escaping @MainActor () -> TimeInterval, toggle: @escaping @MainActor () -> Void,
                    start: @escaping @MainActor () -> Void) {
            self.isHere = isHere; self.isPlaying = isPlaying; self.position = position; self.toggle = toggle; self.start = start
        }
    }

    private let duration: TimeInterval
    private let player: Player
    /// Why it can't play now (this device is recording), for its tooltip; nil when it can.
    private let unavailable: String?
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale

    public init(duration: TimeInterval, player: Player, unavailable: String? = nil) {
        self.duration = duration
        self.player = player
        self.unavailable = unavailable
    }

    public var body: some View {
        let here = player.isHere()
        let playing = here && player.isPlaying()
        let touch = density == .touch
        Button {
            if here { player.toggle() } else { player.start() }
        } label: {
            HStack(spacing: 5) {
                Group {
                    if playing && !hovering {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, options: .repeating, isActive: !reduceMotion)
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(touch ? .caption.weight(.bold) : .system(size: 9 * scale, weight: .bold))
                    }
                }
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: touch ? nil : 12 * scale)
                Text(here ? TimeLabel.short(player.position()) : DurationLabel.format(duration))
                    .monospacedDigit()
            }
            .daybookFont(.byline)
            .fontWeight(.medium)
            .foregroundStyle(playing && scheme == .dark ? DaybookPalette.neonMint : DaybookPalette.Ink.link)
            .padding(.horizontal, touch ? 10 : 8)
            .padding(.vertical, touch ? 4 : 2)
            .background(DaybookPalette.accent.opacity(hovering ? 0.22 : 0.14), in: DaybookRadius.chip)
            .contentShape(DaybookRadius.chip)
            .fixedSize()
            .daybookHitTarget()
        }
        .buttonStyle(.plain)
        .opacity(unavailable == nil ? 1 : 0.4)
        .disabled(unavailable != nil)
        .onHover { hovering = $0 }
        .daybookMotion(DaybookMotion.hover, value: hovering)
        .help(unavailable ?? (playing ? "Pause" : "Play the conversation"))
        .accessibilityLabel(playing ? "Pause" : "Play conversation, \(SpokenTime.format(duration))")
    }
}
