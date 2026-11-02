import DaybookCaptions
import DaybookDesign
import DaybookKit
import Foundation
import SwiftUI

extension LiveCaptionStore {
    /// When each conversation's transcripts were made, by conversation: all `prune` needs, and cheap to
    /// compare, so the library changing in any other way (notes typed) never prunes.
    public static func transcriptDates(_ meetings: [Meeting]) -> [UUID: [Date]] {
        Dictionary(meetings.map { ($0.id, $0.transcripts.map(\.createdAt)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The captions to show for `meeting`: its own, until a transcript made after they began replaces
    /// them (`isReplaced`), and only with words to read.
    public static func shown(_ captions: LiveCaptions?, for meeting: Meeting) -> LiveCaptions? {
        shown(captions, conversation: meeting.id, transcriptsMadeAt: meeting.transcripts.map(\.createdAt))
    }

    /// Removes the captions a transcript has replaced, and those of conversations moved to the Trash
    /// (`prune(_:keeping:trashed:)`). `keeping`: the conversation being recorded.
    public func prune(meetings: [Meeting], keeping: UUID?, trashed: Set<UUID>? = nil) async {
        await prune(Self.transcriptDates(meetings), keeping: keeping.map { [$0] } ?? [], trashed: trashed)
    }
}

/// Saved live captions as reading shows them, the same on both apps: in the transcript's place while
/// there's no transcript to read, until one made after them replaces them; with times that play the
/// recording they were heard from; and found by search. Never evidence, never summarized, never edited.
public enum SavedCaptions {
    /// Whether a conversation's saved captions may stand in for its transcript: it has none to read yet.
    /// A cheap check before reading them; `shown` decides.
    public static func mayStandIn(for meeting: Meeting) -> Bool { meeting.unifiedTranscript.isEmpty }

    /// The captions to show in the transcript's place, or nil when there are none to show.
    public static func shown(_ captions: LiveCaptions?, for meeting: Meeting) -> LiveCaptions? {
        guard mayStandIn(for: meeting) else { return nil }
        return LiveCaptionStore.shown(captions, for: meeting)
    }

    /// The recording the captions were heard from: the one they were filed with, else the one that
    /// began as they did (an iPhone's recording before it was filed, a Mac's own). Nil when neither is there.
    public static func recording(of captions: LiveCaptions, in meeting: Meeting) -> RecordingTrack? {
        if let id = captions.trackID, let track = meeting.tracks.first(where: { $0.id == id }) { return track }
        let began = meeting.tracks.filter { track in
            abs((track.startedAt ?? track.createdAt).timeIntervalSince(captions.createdAt)) <= recordingMatch
        }
        return began.min { abs(($0.startedAt ?? $0.createdAt).timeIntervalSince(captions.createdAt))
            < abs(($1.startedAt ?? $1.createdAt).timeIntervalSince(captions.createdAt)) }
    }

    /// How far apart a recording's start and its captions' may be: captions begin as the recorder does.
    static let recordingMatch: TimeInterval = 60

    /// Times are seconds into the recording they were heard from, so they play that recording; without
    /// it, the conversation from that time.
    public static func playback(_ segment: LiveCaptionSegment, captions: LiveCaptions, in meeting: Meeting) -> PlaybackTarget {
        if let track = recording(of: captions, in: meeting) { return .source(track, segment.start) }
        return .timeline(segment.start)
    }

    /// The caption under the playhead while their recording plays (`trackID`: the recording playing).
    public static func playing(at position: TimeInterval, trackID: UUID?, captions: LiveCaptions, in meeting: Meeting) -> UUID? {
        guard let trackID, (recording(of: captions, in: meeting)?.id ?? meeting.tracks.first?.id) == trackID else { return nil }
        return captions.segment(at: position)
    }

    /// Search of saved captions, for conversations they stand in for: the first matching caption of
    /// each, labelled "Live captions" in the results.
    @MainActor
    public static func hits(in meetings: [Meeting], query: String, store: LiveCaptionStore?) -> [(meeting: Meeting, segment: LiveCaptionSegment)] {
        guard let store, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return meetings.filter(mayStandIn).compactMap { meeting in
            guard let captions = shown(store.captions(for: meeting.id), for: meeting), let segment = captions.firstMatch(query) else { return nil }
            return (meeting, segment)
        }
    }
}

// MARK: - The view

/// Saved live captions in the transcript's place, on both apps: a quiet line saying what they are, then
/// each caption with its time in the margin (a tap plays from there), the person live speakers recognized
/// or the device that heard it before its words, in a lighter ink than a transcript. The caption under
/// the playhead is marked in mint. Never editable. Each row has the scroll ID `caption:<id>`, the header
/// `captions-header`.
public struct SavedCaptionsView: View {
    private let meeting: Meeting
    private let captions: LiveCaptions
    private let playing: UUID?
    private let play: (PlaybackTarget) -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingWidth) private var readingWidth

    public init(meeting: Meeting, captions: LiveCaptions, playing: UUID?, play: @escaping (PlaybackTarget) -> Void) {
        self.meeting = meeting
        self.captions = captions
        self.playing = playing
        self.play = play
    }

    public var body: some View {
        let names = captions.sourceNames ?? [:]
        Group {
            MarginRow {
                Image(systemName: "captions.bubble").foregroundStyle(DaybookPalette.Ink.meta).accessibilityHidden(true)
            } content: {
                Text("Live captions · tentative")
                    .daybookFont(.statusLead)
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, DaybookSpacing.s4)
            .padding(.bottom, DaybookSpacing.s2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .id("captions-header")
            ForEach(captions.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { segment in
                SavedCaptionRow(segment: segment, name: LiveCaptionLabels.speaker(segment, names: names), isPlaying: playing == segment.id) {
                    play(SavedCaptions.playback(segment, captions: captions, in: meeting))
                }
                .id("caption:\(segment.id.uuidString)")
            }
        }
        // The iPhone's pages always keep their lane of times inside the column.
        .environment(\.readingWidth, density == .touch ? .narrow : readingWidth)
    }
}

/// One caption: its time, which plays from there, then the words.
private struct SavedCaptionRow: View {
    let segment: LiveCaptionSegment
    /// Before the words: the person live speakers recognized, or the device that heard it.
    let name: String?
    let isPlaying: Bool
    let play: () -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale

    var body: some View {
        MarginRow {
            CaptionTime(time: segment.start, play: play)
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Never cut off by the words.
                if let name {
                    Text(name)
                        .daybookFont(.speaker)
                        .foregroundStyle(DaybookPalette.Ink.meta)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(segment.text)
                    .daybookFont(.body)
                    .italic(segment.isTentative)
                    .foregroundStyle(segment.isTentative ? DaybookPalette.Ink.meta : DaybookPalette.Ink.secondary)
                    .lineSpacing(DaybookFont.bodyLineSpacing(density, scale: scale))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isPlaying {
                    // The playhead's rule, in the gutter before the words.
                    Capsule().fill(DaybookPalette.neonMint).frame(width: 3).daybookGlow(DaybookPalette.neonMint).offset(x: -5.5)
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name.map { "\($0), caption" } ?? "Caption") at \(SpokenTime.format(segment.start))\(segment.isTentative ? ", tentative" : ""): \(segment.text)")
        .accessibilityHint("Plays from here")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, play)
    }
}

/// A caption's time: Meta ink, link ink under the pointer, plays from there.
private struct CaptionTime: View {
    let time: TimeInterval
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: play) {
            Text(TimeLabel.short(time))
                .daybookFont(.time)
                .foregroundStyle(hovering ? DaybookPalette.Ink.link : DaybookPalette.Ink.meta)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .daybookHitTarget()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .daybookMotion(DaybookMotion.hover, value: hovering)
        .accessibilityLabel("Play from \(SpokenTime.format(time))")
    }
}
