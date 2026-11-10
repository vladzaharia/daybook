import DaybookCaptions
import DaybookDesign
import DaybookKit
import Foundation
import SwiftUI

extension LiveCaptionStore {
    /// When each conversation's transcripts were made, by conversation: when pruning is worth a look, and
    /// cheap to compare, so the library changing in any other way (notes typed) never prunes.
    public static func transcriptDates(_ meetings: [Meeting]) -> [UUID: [Date]] {
        Dictionary(meetings.map { ($0.id, $0.transcripts.map(\.createdAt)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Each conversation's recordings and transcripts, as the replacement rule reads them (`LiveCaptionCoverage`).
    public static func coverage(_ meetings: [Meeting]) -> [UUID: LiveCaptionCoverage] {
        Dictionary(meetings.map { ($0.id, LiveCaptionCoverage($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Removes the captions transcripts have replaced, and those of conversations moved to the Trash
    /// (`prune(_:keeping:trashed:)`). `keeping`: the conversation being recorded.
    public func prune(meetings: [Meeting], keeping: UUID?, trashed: Set<UUID>? = nil) async {
        await prune(Self.coverage(meetings), keeping: keeping.map { [$0] } ?? [], trashed: trashed)
    }
}

extension LiveCaptionCoverage {
    /// A conversation's recordings as the replacement rule reads them: each recording (a recording made from
    /// another, the microphone with the call's echo removed, counts as it), when it began and for how long, the
    /// device it came from and its ID there, and when it was last transcribed.
    public init(_ meeting: Meeting) {
        var made: [UUID: Date] = [:]
        for transcript in meeting.transcripts { made[transcript.trackID] = max(made[transcript.trackID] ?? .distantPast, transcript.createdAt) }
        let known = Set(meeting.tracks.map(\.id))
        var originals: [UUID: UUID] = [:]
        for track in meeting.tracks { originals[track.id] = track.derivedFrom.flatMap { known.contains($0) ? $0 : nil } ?? track.id }
        var transcribed: [UUID: Date] = [:]
        for (track, date) in made { if let original = originals[track] { transcribed[original] = max(transcribed[original] ?? date, date) } }
        let recordings = meeting.tracks.filter { $0.derivedFrom == nil && $0.removal == nil }.map { track in
            Recording(trackID: track.id, source: track.source.rawValue, deviceKind: track.deviceKind, recordingID: track.deviceRecordingID,
                      startedAt: track.startedAt, createdAt: track.createdAt, duration: track.duration, transcribedAt: transcribed[track.id])
        }
        self.init(recordings: recordings, otherTranscripts: made.filter { !known.contains($0.key) }.map(\.value).sorted())
    }
}

/// Saved live captions as reading shows them, the same on both apps, by one rule (`shown`): a
/// conversation's own, each recording's, the lines no transcript replaces yet (`LiveCaptionCoverage`: once
/// the recording that heard a line is transcribed, or, for the device's own lines, any transcript that
/// covers their time), with words to read. They read on the transcript's page, in the transcript's place
/// while there's none (`standsIn`), else after it; with times that play the recording they were heard from;
/// and found by search. Never evidence, never summarized, never edited.
public enum SavedCaptions {
    /// The captions to show for `meeting`, or nil when there are none to show: the one rule both apps
    /// read, for the page, its view switch, and search.
    public static func shown(_ captions: LiveCaptions?, for meeting: Meeting) -> LiveCaptions? {
        shown(captions.map { [$0] } ?? [], for: meeting)
    }

    /// The same for each recording's captions of the conversation, read together, the oldest recording's first.
    public static func shown(_ captures: [LiveCaptions], for meeting: Meeting) -> LiveCaptions? {
        guard !captures.isEmpty else { return nil }
        let coverage = LiveCaptionCoverage(meeting)
        return LiveCaptions.together(captures.flatMap { $0.parts ?? [$0] }.compactMap {
            LiveCaptionStore.shown($0, conversation: meeting.id, coverage: coverage)
        })
    }

    /// Whether shown captions take the transcript's place: there's no transcript to read yet. Otherwise
    /// they follow the transcript.
    public static func standsIn(for meeting: Meeting) -> Bool { meeting.unifiedTranscript.isEmpty }

    /// What a page reads a conversation's saved captions again for: another conversation, a transcript
    /// made, or captions saved (`lastSave`).
    public struct Reading: Hashable, Sendable {
        public var meetingID: UUID
        public var transcripts: [Date]
        public var lastSave: Date?

        public init(_ meeting: Meeting, lastSave: Date?) {
            meetingID = meeting.id
            transcripts = meeting.transcripts.map(\.createdAt)
            self.lastSave = lastSave
        }
    }

    /// Reads a conversation's saved captions, each recording's, off the caller's actor: those to show
    /// (`shown`), or nil.
    public static func read(for meeting: Meeting, from store: LiveCaptionStore?) async -> LiveCaptions? {
        guard let store else { return nil }
        let id = meeting.id
        let captures = await Task.detached(priority: .userInitiated) { store.captures(of: id) }.value
        return shown(captures, for: meeting)
    }

    /// The recording the captions were heard from: the one they were filed with, else the one that
    /// began as they did (an iPhone's recording before it was filed, a Mac's own). Nil when neither is there.
    /// Several recordings' read together: the first's.
    public static func recording(of captions: LiveCaptions, in meeting: Meeting) -> RecordingTrack? {
        let captions = captions.parts?.first ?? captions
        if let id = captions.trackID, let track = meeting.tracks.first(where: { $0.id == id }) { return track }
        func distance(_ track: RecordingTrack) -> TimeInterval { abs((track.startedAt ?? track.createdAt).timeIntervalSince(captions.origin)) }
        return meeting.tracks.filter { distance($0) <= LiveCaptionCoverage.recordingMatch }.min { distance($0) < distance($1) }
    }

    /// Times are seconds into the recording they were heard from, so they play that recording; without
    /// it, the conversation from that time.
    public static func playback(_ segment: LiveCaptionSegment, captions: LiveCaptions, in meeting: Meeting) -> PlaybackTarget {
        if let track = recording(of: captions.part(of: segment), in: meeting) { return .source(track, segment.start) }
        return .timeline(segment.start)
    }

    /// The caption under the playhead while their recording plays (`trackID`: the recording playing).
    public static func playing(at position: TimeInterval, trackID: UUID?, captions: LiveCaptions, in meeting: Meeting) -> UUID? {
        guard let trackID else { return nil }
        for part in captions.parts ?? [captions] where (recording(of: part, in: meeting)?.id ?? meeting.tracks.first?.id) == trackID {
            if let id = part.segment(at: position) { return id }
        }
        return nil
    }

    /// Search of saved captions, in the conversations they show for: the first matching caption of
    /// each, labelled `searchLocation` in the results. `captions`: saved captions by conversation.
    public static func hits(in meetings: [Meeting], query: String,
                            captions: [UUID: LiveCaptions]) -> [(meeting: Meeting, segment: LiveCaptionSegment)] {
        guard !captions.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return meetings.compactMap { meeting in
            guard let shown = shown(captions[meeting.id], for: meeting), let segment = shown.firstMatch(query) else { return nil }
            return (meeting, segment)
        }
    }

    /// The same, read from `store` now: only the conversations that have captions saved are read.
    public static func hits(in meetings: [Meeting], query: String, store: LiveCaptionStore?) -> [(meeting: Meeting, segment: LiveCaptionSegment)] {
        guard let store, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let saved = Set(store.conversations())
        var captions: [UUID: LiveCaptions] = [:]
        for meeting in meetings where saved.contains(meeting.id) { captions[meeting.id] = LiveCaptions.together(store.captures(of: meeting.id)) }
        return hits(in: meetings, query: query, captions: captions)
    }

    /// A saved caption's scroll ID on the transcript's page (`SavedCaptionsView`), which a search result or the
    /// playhead moves the page to.
    public static func rowID(_ id: UUID) -> String { "caption:\(id.uuidString)" }

    /// Where search found a caption, under the result: labelled so it never passes for the transcript.
    public static func searchLocation(_ segment: LiveCaptionSegment) -> String {
        "Live captions · tentative · \(TimeLabel.short(segment.start))"
    }
}

// MARK: - The view

/// Saved live captions on the transcript's page, on both apps, in the transcript's place or after it
/// (`SavedCaptions.standsIn`): a quiet line saying what they are, then each caption with its time in the
/// margin (a tap plays from there), the person live speakers recognized or the device that heard it
/// before its words, in a lighter ink than a transcript. The caption under the playhead is marked in
/// mint. Never editable. Each row has the scroll ID `caption:<id>`, the header `captions-header`.
public struct SavedCaptionsView: View {
    private let meeting: Meeting
    private let captions: LiveCaptions
    private let playing: UUID?
    private let play: (PlaybackTarget) -> Void
    private let spacingAbove: CGFloat
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingWidth) private var readingWidth

    /// - Parameter spacingAbove: More room above the label, where they follow a transcript. (The rows are
    ///   the page's own, so padding the view would pad each of them.)
    public init(meeting: Meeting, captions: LiveCaptions, playing: UUID?, spacingAbove: CGFloat = 0,
                play: @escaping (PlaybackTarget) -> Void) {
        self.meeting = meeting
        self.captions = captions
        self.playing = playing
        self.spacingAbove = spacingAbove
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
            .padding(.top, DaybookSpacing.s4 + spacingAbove)
            .padding(.bottom, DaybookSpacing.s2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .id("captions-header")
            ForEach(captions.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { segment in
                SavedCaptionRow(segment: segment, name: LiveCaptionLabels.speaker(segment, names: names), isPlaying: playing == segment.id) {
                    play(SavedCaptions.playback(segment, captions: captions, in: meeting))
                }
                .id(SavedCaptions.rowID(segment.id))
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
