import DaybookCaptions
import DaybookKit
import SwiftUI

extension EnvironmentValues {
    /// Where saved live captions are read from. Set by `LibraryBrowser`; nil shows none.
    @Entry var liveCaptionStore: LiveCaptionStore? = nil
}

/// Saved live captions as reading shows them: only while the conversation has no official
/// transcript (`Meeting.showsLiveCaptions`), never as evidence, never summarized, and never edited.
/// The Mac's transcript replaces them entirely.
enum SavedCaptions {
    /// The captions to show in the transcript's place, or nil when there are none to show.
    static func shown(_ captions: LiveCaptions?, for meeting: Meeting) -> LiveCaptions? {
        guard meeting.showsLiveCaptions, let captions, captions.meetingID == meeting.id,
              captions.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        return captions
    }

    /// Times are seconds into the phone's recording, so they play that recording.
    static func playback(_ segment: LiveCaptionSegment, captions: LiveCaptions, in meeting: Meeting) -> PlaybackTarget {
        if let id = captions.trackID, let track = meeting.tracks.first(where: { $0.id == id }) {
            return .source(track, segment.start)
        }
        if let track = meeting.tracks.first(where: { $0.deviceKind == PhoneDevice.kind }) {
            return .source(track, segment.start)
        }
        return .timeline(segment.start)
    }

    /// The caption under the playhead, while the phone's recording plays.
    static func playing(at position: TimeInterval, trackID: UUID?, captions: LiveCaptions, in meeting: Meeting) -> UUID? {
        guard let trackID else { return nil }
        let captionTrack = captions.trackID ?? meeting.tracks.first { $0.deviceKind == PhoneDevice.kind }?.id ?? meeting.tracks.first?.id
        guard captionTrack == trackID else { return nil }
        return captions.segments.first { (($0.start)...max($0.start, $0.end)).contains(position) }?.id
    }

    /// On-device search of saved captions, for conversations without a transcript: the first
    /// matching caption of each, labelled "Live captions" in the results.
    @MainActor
    static func hits(in meetings: [Meeting], query: String, store: LiveCaptionStore?) -> [(meeting: Meeting, segment: LiveCaptionSegment)] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !text.isEmpty else { return [] }
        return meetings.filter(\.showsLiveCaptions).compactMap { meeting in
            guard let captions = shown(store.captions(for: meeting.id), for: meeting),
                  let segment = captions.segments.first(where: { $0.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil })
            else { return nil }
            return (meeting, segment)
        }
    }
}

/// The transcript's page while only live captions exist: a quiet header saying what they are, then
/// the captions in a lighter ink, with times that play the recording. No speakers, no editing.
struct CaptionRows: View {
    let meeting: Meeting
    let captions: LiveCaptions
    let playing: UUID?
    let play: (PlaybackTarget) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "captions.bubble").foregroundStyle(PhoneStyle.Ink.meta).accessibilityHidden(true)
            Text("Live captions · tentative")
                .font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhoneStyle.quietFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, PhoneStyle.Space.s4)
        .padding(.bottom, PhoneStyle.Space.s2)
        .accessibilityElement(children: .combine)
        .id("captions-header")
        ForEach(captions.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { segment in
            CaptionRow(segment: segment, isPlaying: playing == segment.id) {
                play(SavedCaptions.playback(segment, captions: captions, in: meeting))
            }
            .id("caption:\(segment.id.uuidString)")
        }
    }
}

private struct CaptionRow: View {
    let segment: LiveCaptionSegment
    let isPlaying: Bool
    let play: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TimeButton(time: segment.start, play: play)
                .frame(minWidth: 36, alignment: .leading)
            Text(segment.text)
                .font(PhoneStyle.Typeface.body)
                .italic(segment.isTentative)
                .foregroundStyle(segment.isTentative ? PhoneStyle.Ink.meta : PhoneStyle.Ink.secondary)
                .lineSpacing(PhoneStyle.Typeface.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .leading) {
            if isPlaying {
                Capsule().fill(PhoneStyle.neonMint).frame(width: 3).neonGlow(PhoneStyle.neonMint, radius: 4).offset(x: -10)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Caption at \(SpokenTime.format(segment.start))\(segment.isTentative ? ", tentative" : ""): \(segment.text)")
        .accessibilityHint("Plays from here")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, play)
    }
}
