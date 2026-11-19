import Foundation

// Where to start playing for a handwritten passage: from when it was written, and for one written inside a pause, from the end of
// the silence the pause left in the audio.

extension RecordingClockMap {
    /// When `moment` falls in a stretch the recording was paused (the latest sample at or before it isn't running), the seconds into
    /// the audio at which that stretch ends: the pause is silence in the recording, as long as the pause was, so it ends at the
    /// seconds the pause began at plus its length. Nil when `moment` isn't in a pause, or the pause never ended in these samples.
    public static func endOfPause(containing moment: Date, samples: [RecordingClockSample]) -> TimeInterval? {
        let ordered = samples.sorted { $0.at < $1.at }
        guard let before = ordered.last(where: { $0.at <= moment }), !before.running,
              let resumed = ordered.first(where: { $0.at > before.at && $0.running }), resumed.at > moment else { return nil }
        let seconds = before.elapsed + resumed.at.timeIntervalSince(before.at)
        return seconds.isFinite ? max(0, seconds) : nil
    }
}

extension Meeting {
    /// Where `moment` falls on a recording this conversation was filed with a clock for: the track whose samples span it, and the
    /// seconds into it (`RecordingClockMap.elapsed`). Nil when no filed track's clock covers it.
    public func recordingPlacement(at moment: Date) -> (trackID: UUID?, time: TimeInterval?)? {
        for track in tracks where track.removal == nil {
            guard let samples = track.clockSamples, let first = samples.map(\.at).min(), let last = samples.map(\.at).max(),
                  moment >= first.addingTimeInterval(-RecordingClockMap.trailing),
                  moment <= last.addingTimeInterval(RecordingClockMap.trailing),
                  let seconds = RecordingClockMap.elapsed(at: moment, samples: samples) else { continue }
            return (track.id, seconds)
        }
        return nil
    }

    /// Where playing from a passage starts: seconds into the recording it was written during (`trackID`), or on the conversation's
    /// timeline when it wasn't written during one. A passage timed inside a pause starts at the end of the silence, not in it.
    /// Nil when nothing places it.
    public func playbackStart(of passage: NotebookPassage, on page: NotebookPage) -> (trackID: UUID?, seconds: TimeInterval)? {
        if let trackID = passage.trackID, let time = passage.time, let track = tracks.first(where: { $0.id == trackID }) {
            let seconds = RecordingClockMap.endOfPause(containing: passage.start, samples: track.clockSamples ?? []) ?? time
            return (trackID, seconds)
        }
        return timelineTime(of: passage, on: page).map { (nil, $0) }
    }
}
