import Foundation

/// User-marked emphasis and nearby speech are separate fields; annotation text is never a spoken quote.
public struct HighlightContext: Equatable, Identifiable, Sendable {
    public enum TimeBasis: String, Sendable { case meetingTimeline, sourceRecording }
    public var id: UUID { highlight.id }
    public var highlight: Highlight
    public var sourceName: String
    public var timeBasis: TimeBasis
    public var markerTime: TimeInterval
    public var rangeStart: TimeInterval
    public var rangeEnd: TimeInterval
    public var speechContext: [TranscriptSegment]
    public var isAligned: Bool { timeBasis == .meetingTimeline }
}

extension Meeting {
    /// A point marker defaults to 30 seconds before and 60 seconds after. Unaligned sources use their
    /// latest original transcript and source-local time, never an invented common-timeline position.
    public func highlightContexts(before: TimeInterval = 30, after: TimeInterval = 60) -> [HighlightContext] {
        let before = before.isFinite ? max(0, before) : 30
        let after = after.isFinite ? max(0, after) : 60
        // Background audio (a TV, music) stays out of a bookmark's context, as it does the transcript.
        let background = highlights.contains { alignedTime(for: $0) == nil } ? backgroundSegmentKinds() : [:]
        return highlights.compactMap { highlight in
            guard highlight.time.isFinite, highlight.time >= 0 else { return nil }
            let duration = highlight.duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            let source = tracks.first { $0.id == highlight.trackID }
            let name = source?.fileName ?? (highlight.trackID == nil ? "Meeting timeline" : "Original recording")
            if let aligned = alignedTime(for: highlight) {
                let rate = alignmentReports.first { $0.trackID == highlight.trackID }?.rate ?? 1
                let start = aligned - before, end = aligned + duration * rate + after
                return HighlightContext(highlight: highlight, sourceName: name, timeBasis: .meetingTimeline,
                    markerTime: aligned, rangeStart: start, rangeEnd: end,
                    speechContext: unifiedTranscript.filter { $0.end >= start && $0.start <= end })
            }
            let start = max(0, highlight.time - before), end = highlight.time + duration + after
            let transcript = transcripts.filter { $0.trackID == highlight.trackID }.max { $0.createdAt < $1.createdAt }
            return HighlightContext(highlight: highlight, sourceName: name, timeBasis: .sourceRecording,
                markerTime: highlight.time, rangeStart: start, rangeEnd: end,
                speechContext: transcript?.segments.filter { $0.end >= start && $0.start <= end && background[$0.id] == nil } ?? [])
        }
    }
}
