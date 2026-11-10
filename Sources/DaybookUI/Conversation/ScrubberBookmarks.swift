import DaybookKit
import Foundation

/// Where a conversation's bookmarks fall along the recording the player has loaded, 0 to 1, for the scrubber's amber
/// ticks: the scrubber measures that recording, so a bookmark is placed by its time in it. A bookmark made in the
/// recording keeps its own time; one on the conversation's timeline, or in another placed recording, is carried through
/// both recordings' placements, and only when the loaded one is placed. A bookmark outside the recording, in an
/// unaligned one, or in one taken out of the conversation has no tick. Only times, never a bookmark's words.
@MainActor
public enum ScrubberBookmarks {
    /// - Parameters:
    ///   - trackID: The recording loaded.
    ///   - duration: Its length as the player has it.
    public static func fractions(in meeting: Meeting, trackID: UUID?, duration: TimeInterval) -> [Double] {
        guard let trackID, duration.isFinite, duration > 0,
            let loaded = meeting.tracks.first(where: { $0.id == trackID }), !loaded.isRemoved
        else { return [] }
        let loadedPlacement = placement(of: loaded, in: meeting)
        return meeting.presentHighlights.compactMap { bookmark -> Double? in
            guard bookmark.time.isFinite, bookmark.time >= 0 else { return nil }
            let local: TimeInterval
            if bookmark.trackID == trackID {
                local = bookmark.time
            } else {
                guard let loadedPlacement else { return nil }
                let timeline: TimeInterval
                if let source = bookmark.trackID {
                    guard let track = meeting.tracks.first(where: { $0.id == source }),
                        let placed = placement(of: track, in: meeting)
                    else { return nil }
                    timeline = placed.offset + bookmark.time * placed.rate
                } else {
                    timeline = bookmark.time
                }
                local = (timeline - loadedPlacement.offset) / loadedPlacement.rate
            }
            guard local.isFinite, local >= 0, local <= duration else { return nil }
            return local / duration
        }
        .sorted()
    }

    /// A recording's place on the conversation's timeline, when it has a usable one: never one fusion or the person
    /// reported unaligned, even the first recording, which the timeline otherwise starts from.
    private static func placement(of track: RecordingTrack, in meeting: Meeting) -> (offset: TimeInterval, rate: Double)? {
        guard !track.isRemoved, !RecordingWords.isUnaligned(track, in: meeting),
            let placed = meeting.timelinePlacement(of: track.id),
            placed.offset.isFinite, placed.rate.isFinite, placed.rate > 0
        else { return nil }
        return placed
    }
}
