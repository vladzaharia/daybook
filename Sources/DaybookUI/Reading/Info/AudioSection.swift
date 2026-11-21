import DaybookDesign
import DaybookKit
import SwiftUI

/// Info › Audio on both apps: each recording with its glyph (`RecordingWords.symbol`), name, length, how it lines up,
/// where its audio is (where that's in doubt), Play, and its menu (`ConversationActions.track`); then recordings
/// that were removed, each to put back.
struct AudioSection<Extras: View, AddRecording: View>: View {
    let meeting: Meeting
    let services: ConversationInfoServices
    @Binding var removing: RecordingTrack?
    @ViewBuilder var extras: Extras
    @ViewBuilder var addRecording: AddRecording

    var body: some View {
        let present = meeting.presentTracks
        ForEach(present) { track in
            AudioRow(meeting: meeting, track: track, services: services, removing: $removing)
        }
        if present.isEmpty { Text("No recording yet").foregroundStyle(DaybookPalette.Ink.secondary) }
        extras
        ForEach(meeting.removedTracks.filter { $0.derivedFrom == nil }) { track in
            RemovedAudioRow(meeting: meeting, track: track, services: services)
        }
        addRecording
    }
}

/// The glyph column every Audio row starts with, so names line up whatever the glyph.
enum AudioGlyph {
    static func width(_ density: DaybookDensity, scale: CGFloat) -> CGFloat { density == .touch ? 24 * scale : 16 }
    static func spacing(_ density: DaybookDensity) -> CGFloat { density == .touch ? 10 : 6 }
}

struct AudioRow: View {
    let meeting: Meeting
    let track: RecordingTrack
    let services: ConversationInfoServices
    @Binding var removing: RecordingTrack?
    @State private var availability: ReadingAudio?
    @State private var fetch = AudioFetch.idle
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var glyphScale: CGFloat = 1

    private var touch: Bool { density == .touch }
    private var name: String { services.recordingName(track, meeting) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize {
                // The largest sizes: the name a line of its own, then its length and controls.
                HStack(alignment: .firstTextBaseline, spacing: AudioGlyph.spacing(density)) {
                    glyph
                    Text(name).lineLimit(3).truncationMode(.middle)
                }
                HStack(spacing: AudioGlyph.spacing(density)) {
                    length
                    Spacer(minLength: 6)
                    play
                    menu
                }
                .padding(.leading, AudioGlyph.width(density, scale: glyphScale) + AudioGlyph.spacing(density))
            } else {
                HStack(spacing: AudioGlyph.spacing(density)) {
                    glyph
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    length
                    play
                    menu
                }
            }
            Group {
                details
                if let availability { availabilityLine(availability) }
            }
            .font(touch ? .footnote : .caption)
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .padding(.leading, AudioGlyph.width(density, scale: glyphScale) + AudioGlyph.spacing(density))
        }
        .task(id: track.id) {
            guard let lookup = services.availability else { return }
            availability = await lookup(track, meeting)
        }
    }

    private var glyph: some View {
        Image(systemName: RecordingWords.symbol(track)).foregroundStyle(DaybookPalette.Ink.secondary)
            .frame(width: AudioGlyph.width(density, scale: glyphScale)).accessibilityHidden(true)
    }

    private var length: some View {
        Text(track.duration.map(TimeLabel.short) ?? "—").monospacedDigit().foregroundStyle(DaybookPalette.Ink.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var actions: [ConversationActionGroup] {
        let groups = ConversationActions.track(track, in: meeting, context: services.actionContext(meeting))
        // A Mac dims what can't be done now; an iPhone leaves it out. Neither lists what this app doesn't offer.
        return groups.compactMap { group in
            let actions = group.actions.filter { services.offers($0.id) && (!touch || $0.isAvailable) }
            return actions.isEmpty ? nil : ConversationActionGroup(id: group.id, actions: actions)
        }
    }

    private func available(_ id: ConversationAction.ID) -> Bool {
        actions.flatMap(\.actions).first { $0.id == id }?.isAvailable == true
    }

    private var play: some View {
        Button { services.perform(.track(.play, track), meeting) } label: {
            Image(systemName: "play.circle.fill")
                .font(touch ? .title2 : .system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DaybookPalette.accent)
        }
        .buttonStyle(.borderless)
        .disabled(!available(.play))
        .accessibilityLabel("Play \(name)")
        .macHelp("Play this recording")
    }

    private var menu: some View {
        Menu {
            ForEach(actions) { group in
                Section {
                    ForEach(group.actions) { action in
                        Button(role: action.role == .destructive ? .destructive : nil) { choose(action.id) } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                        .disabled(!action.isAvailable)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(touch ? .title3 : .body)
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .daybookHitTarget()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        #if os(macOS)
        .menuStyle(.button)
        .fixedSize()
        .help("More")
        #endif
        .accessibilityLabel("More for \(name)")
    }

    private func choose(_ id: ConversationAction.ID) {
        if id == .removeRecording { removing = track } else { services.perform(.track(id, track), meeting) }
    }

    @ViewBuilder private var details: some View {
        if meeting.supersededLivePortions[track.id] != nil {
            // Kept for playback; the recorder's own file is what's transcribed.
            Text("Replaced by the full recording")
        } else if RecordingWords.isUnaligned(track, in: meeting) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DaybookPalette.Ink.warning)
                Text("Couldn’t line up")
                if available(.adjustTiming) {
                    Button("Adjust Timing…") { services.perform(.track(.adjustTiming, track), meeting) }
                        .buttonStyle(.daybookLink)
                }
            }
        } else if let line = services.recordingLine(track, meeting) {
            Text(line)
        }
    }

    private func availabilityLine(_ availability: ReadingAudio) -> some View {
        let words = Self.words(availability, thisDevice: context.thisDevice)
        return HStack(spacing: 8) {
            Label(words.text, systemImage: words.symbol).labelStyle(AudioFactLabelStyle())
            if let title = Self.downloadTitle(availability, fetch: fetch, canDownload: services.download != nil) {
                Button(title) { download() }
                    .buttonStyle(.daybookLink)
                    .disabled(fetch == .fetching)
            }
        }
    }

    private func download() {
        guard let fetcher = services.download else { return }
        fetch = .fetching
        Task {
            do {
                try await fetcher(track, meeting)
                fetch = .idle
            } catch {
                fetch = .failed
            }
            if let lookup = services.availability { availability = await lookup(track, meeting) }
        }
    }

    /// Where a recording's audio is, where that's in doubt: "On this iPhone", "Not on this iPhone", "Not in the library".
    static func words(_ availability: ReadingAudio, thisDevice: String) -> (text: String, symbol: String) {
        switch availability {
        case .local: return ("On \(thisDevice)", thisDevice.hasSuffix("iPhone") ? "iphone" : "laptopcomputer")
        case .downloadable: return ("Not on \(thisDevice)", "icloud.and.arrow.down")
        case .offline: return ("Not on \(thisDevice)", "icloud.slash")
        case .missing: return ("Not in the library", "questionmark.circle")
        }
    }

    /// The action beside "Not on this iPhone": "Download · 12 MB" (just "Download" when the size isn't known), "Try
    /// Again" after it failed, nothing while it downloads or where the audio can't be fetched now.
    static func downloadTitle(_ availability: ReadingAudio, fetch: AudioFetch, canDownload: Bool) -> String? {
        guard canDownload, case .downloadable(let bytes) = availability else { return nil }
        switch fetch {
        case .fetching: return "Downloading…"
        case .failed: return "Try Again"
        case .idle: return bytes.map { "Download · \(ByteSize.format($0))" } ?? "Download"
        }
    }
}

/// Where a Download from Info stands.
enum AudioFetch: Equatable {
    case idle, fetching, failed
}

/// A recording that was removed: dimmed, with Put Back.
struct RemovedAudioRow: View {
    let meeting: Meeting
    let track: RecordingTrack
    let services: ConversationInfoServices
    @Environment(\.daybookDensity) private var density
    @ScaledMetric(relativeTo: .body) private var glyphScale: CGFloat = 1

    var body: some View {
        HStack(spacing: AudioGlyph.spacing(density)) {
            Image(systemName: RecordingWords.symbol(track)).foregroundStyle(DaybookPalette.Ink.faint)
                .frame(width: AudioGlyph.width(density, scale: glyphScale)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(services.recordingName(track, meeting)).lineLimit(1).truncationMode(.middle).foregroundStyle(DaybookPalette.Ink.secondary)
                Text("Removed").font(density == .touch ? .footnote : .caption).foregroundStyle(DaybookPalette.Ink.secondary)
            }
            Spacer(minLength: 6)
            Button("Put Back") { services.perform(.putBack(track), meeting) }
                .buttonStyle(.daybookLink)
                .disabled(!services.actionContext(meeting).isIdle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A glyph and its words, close together, in the line's own size.
private struct AudioFactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

extension ConversationActions.Context {
    /// Nothing is recording or processing the conversation here, so its recordings can change.
    var isIdle: Bool { !isRecording && !isProcessingHere }
}
