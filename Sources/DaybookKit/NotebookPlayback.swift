import DaybookCore
import Foundation

extension Meeting {
    /// What to play to hear a passage as it was written (`playbackStart`): its recording from that second, or the timeline's.
    public func playbackTarget(of passage: NotebookPassage, on page: NotebookPage) -> PlaybackTarget? {
        guard let start = playbackStart(of: passage, on: page) else { return nil }
        if let trackID = start.trackID, let track = tracks.first(where: { $0.id == trackID }) { return .source(track, start.seconds) }
        return .timeline(start.seconds)
    }
}
