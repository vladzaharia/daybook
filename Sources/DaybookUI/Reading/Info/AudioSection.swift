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
        // Only the recordings still in the conversation count: "the only recording" is the only one left.
        var shown = meeting
        shown.tracks = meeting.presentTracks
        let groups = ConversationActions.track(track, in: shown, context: services.actionContext(meeting))
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
        #if os(macOS)
        .help("Play this recording")
        #endif
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
            Image(systemName: touch ? "ellipsis.circle" : "ellipsis")
                .font(touch ? .title3 : .body)
                .foregroundStyle(touch ? DaybookPalette.Ink.link : DaybookPalette.Ink.secondary)
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
        return Label(words.text, systemImage: words.symbol).labelStyle(AudioFactLabelStyle())
    }

    /// Where a recording's audio is, where that's in doubt: "On this iPhone", "In iCloud · 12 MB", "Not on this iPhone
    /// yet", "Not in the library on this iPhone".
    static func words(_ availability: ReadingAudio, thisDevice: String) -> (text: String, symbol: String) {
        switch availability {
        case .local: return ("On \(thisDevice)", thisDevice.hasSuffix("iPhone") ? "iphone" : "laptopcomputer")
        case .downloadable(let bytes?): return ("In iCloud · \(ByteSize.format(bytes))", "icloud.and.arrow.down")
        case .downloadable(nil): return ("In iCloud", "icloud.and.arrow.down")
        case .offline: return ("Not on \(thisDevice) yet", "icloud.slash")
        case .missing: return ("Not in the library on \(thisDevice)", "questionmark.circle")
        }
    }
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
