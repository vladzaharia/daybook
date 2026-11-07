import DaybookKit
import Foundation

/// Only timeline geometry, never bookmark text or transcript content. The extent is established by
/// the unified transcript and placed recordings, not by a bookmark that might be beyond their end.
@MainActor
struct ConversationSpineRailData {
 struct Player {
  let meetingID: UUID
  let trackID: UUID
  /// The loaded recording's actual length, when the library doesn't have one yet.
  let duration: TimeInterval
 }

 private struct Placement {
  let offset: TimeInterval
  let rate: Double
 }

 let duration: TimeInterval
 let bookmarks: [Double]
 private let playerPlacement: Placement?

 init?(meeting: Meeting, player: Player? = nil) {
  let activePlayer = player.flatMap { $0.meetingID == meeting.id ? $0 : nil }
  var end: TimeInterval = 0
  for segment in meeting.unifiedTranscript where segment.end.isFinite && segment.end > end {
   end = segment.end
  }

  var activePlacement: Placement?
  for track in meeting.tracks where !track.isRemoved {
   // In particular, a first recording explicitly reported unaligned is not a reference
   // just because timelinePlacement can otherwise default the first recording to zero.
   guard !RecordingWords.isUnaligned(track, in: meeting),
    let placed = meeting.timelinePlacement(of: track.id),
    placed.offset.isFinite, placed.rate.isFinite, placed.rate > 0
   else { continue }
   let placement = Placement(offset: placed.offset, rate: placed.rate)
   if activePlayer?.trackID == track.id { activePlacement = placement }

   func includeEnd(_ length: TimeInterval?) {
    guard let length, length.isFinite, length >= 0 else { return }
    let trackEnd = placement.offset + length * placement.rate
    if trackEnd.isFinite && trackEnd > end { end = trackEnd }
   }
   includeEnd(track.duration)
   if activePlayer?.trackID == track.id { includeEnd(activePlayer?.duration) }
  }
  guard end.isFinite, end > 0 else { return nil }

  duration = end
  playerPlacement = activePlacement
  bookmarks = meeting.presentHighlights.compactMap { bookmark in
   guard bookmark.time.isFinite, bookmark.time >= 0 else { return nil }
   if let trackID = bookmark.trackID {
    // Match the bookmark's own fused-timeline rule, and reject invalid transforms.
    guard let report = meeting.alignmentReports.first(where: { $0.trackID == trackID }),
     report.method != .unaligned, report.offset.isFinite,
     report.rate.isFinite, report.rate > 0
    else { return nil }
    if let track = meeting.tracks.first(where: { $0.id == trackID }),
     RecordingWords.isUnaligned(track, in: meeting)
    {
     return nil
    }
   }
   guard let time = meeting.alignedTime(for: bookmark), time.isFinite, time >= 0 else { return nil }
   return min(1, time / end)
  }
 }

 /// Position is local to the loaded recording; a paused but still open player keeps its place.
 func playhead(at position: TimeInterval) -> Double? {
  guard position.isFinite, position >= 0, let placement = playerPlacement else { return nil }
  let time = placement.offset + position * placement.rate
  guard time.isFinite, time >= 0 else { return nil }
  return min(1, time / duration)
 }
}

/// The view follows the player directly, so its 100 ms position ticks don't rebuild the pages or
/// recalculate the conversation's timeline extent and bookmarks.
struct ConversationSpineRail {
 let data: ConversationSpineRailData
 let player: PlaybackController?
}
