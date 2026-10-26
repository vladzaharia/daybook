import DaybookCore
import Foundation

// Reading a conversation, the same on the Mac and the iPhone: the transcript grouped into turns with
// notes and photos at their times, where bookmarks fall, which passage is under the playhead, and
// what a tap plays. `TranscriptLayout` works the first three out once per version of a conversation,
// so a page redrawn while audio plays doesn't sort and search the whole transcript again.

/// The two sides of a conversation page.
public enum PageMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case summary, transcript
    public var id: String { rawValue }
    public var title: String { self == .summary ? "Summary" : "Transcript" }
}

/// The transcript as it reads: consecutive passages from one speaker form a turn, and timed notes
/// and photos sit at their times.
public enum TranscriptBlock: Identifiable, Equatable, Sendable {
    case turn(id: String, speakerID: String?, segments: [TranscriptSegment])
    case note(TimedNote)
    /// A photo at the moment it was taken.
    case photo(MeetingPhoto, Double)

    public var id: String {
        switch self {
        case .turn(let id, _, _): return "turn:" + id
        case .note(let note): return "note:\(note.id)"
        case .photo(let photo, _): return "photo:\(photo.id)"
        }
    }

    public static func blocks(in meeting: Meeting) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for item in MeetingTimelineItem.items(in: meeting) {
            switch item {
            case .speech(let segment):
                if case .turn(let id, let speaker, var segments)? = blocks.last, speaker == segment.speakerID {
                    segments.append(segment)
                    blocks[blocks.count - 1] = .turn(id: id, speakerID: speaker, segments: segments)
                } else {
                    blocks.append(.turn(id: segment.id.uuidString, speakerID: segment.speakerID, segments: [segment]))
                }
            case .note(let note): blocks.append(.note(note))
            case .photo(let photo, let time): blocks.append(.photo(photo, time))
            case .highlight: break
            }
        }
        return blocks
    }
}

/// Where bookmarks fall: the passage that holds each one, and the label shown above it. Only the
/// holder is marked, so a short conversation isn't washed amber from end to end.
public struct BookmarkMarks: Equatable, Sendable {
    public var bookmarksBySegment: [UUID: [Highlight]] = [:]
    public var labelSegments: [UUID: String] = [:]
    /// The passages that hold a bookmark get the amber rule.
    public var holders: Set<UUID> { Set(bookmarksBySegment.keys) }

    /// Labels an earlier version wrote automatically; they read as no label.
    public static let automaticLabels: Set<String> = ["Marked moment", "Marked during review"]

    public init(meeting: Meeting) {
        let finder = HolderFinder(meeting.unifiedTranscript)
        for highlight in meeting.highlights {
            guard let time = meeting.alignedTime(for: highlight), let holder = finder.holder(at: time) else { continue }
            bookmarksBySegment[holder, default: []].append(highlight)
            let label = highlight.text.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty, !Self.automaticLabels.contains(label), labelSegments[holder] == nil { labelSegments[holder] = label }
        }
    }

    /// The passage under a bookmark: the last one starting at or before it on the timeline.
    public static func holder(of highlight: Highlight, in meeting: Meeting) -> UUID? {
        guard let time = meeting.alignedTime(for: highlight) else { return nil }
        return HolderFinder(meeting.unifiedTranscript).holder(at: time)
    }

    /// "The last passage, in transcript order, starting by `time` (else the first)", by binary
    /// search over the starts instead of a scan per bookmark.
    struct HolderFinder {
        private let segments: [TranscriptSegment]
        /// Starts in ascending order, and the latest transcript position among each prefix of them.
        private let starts: [Double]
        private let latest: [Int]

        init(_ segments: [TranscriptSegment]) {
            self.segments = segments
            let order = segments.indices.sorted { segments[$0].start < segments[$1].start }
            starts = order.map { segments[$0].start }
            var running = -1
            latest = order.map { running = max(running, $0); return running }
        }

        func holder(at time: Double) -> UUID? {
            let count = starts.partitioningIndex { $0 > time + 0.01 }
            return (count > 0 ? segments[latest[count - 1]] : segments.first)?.id
        }
    }
}

/// Which passage is under the playhead, matched in the recording that's playing: a passage that
/// cites that recording plays while the recording is within the cited span; one transcribed from it
/// without citations, while the recording plus its offset is within the passage. The first such
/// passage in transcript order wins. Built once per version; each lookup is a binary search.
public struct PlayheadIndex: Sendable {
    private struct Span: Sendable { var start: Double; var end: Double; var position: Int }
    /// Per recording: spans in the recording's own time (`cited`), and in the conversation's time,
    /// compared with the recording's time plus its offset (`own`). Each sorted by start, with the
    /// furthest end of every prefix, so a lookup stops once nothing earlier can reach the playhead.
    private struct Spans: Sendable {
        var spans: [Span] = []
        var reach: [Double] = []
        mutating func finish() {
            spans.sort { $0.start < $1.start }
            var furthest = -Double.infinity
            reach = spans.map { furthest = max(furthest, $0.end); return furthest }
        }
        func first(containing time: Double) -> Int? {
            var index = spans.partitioningIndex { $0.start > time } - 1
            var found: Int?
            while index >= 0, reach[index] >= time {
                if spans[index].end >= time { found = min(found ?? .max, spans[index].position) }
                index -= 1
            }
            return found
        }
    }

    private let ids: [UUID]
    private var cited: [UUID: Spans] = [:]
    private var own: [UUID: Spans] = [:]
    private var offsets: [UUID: Double] = [:]

    public init(meeting: Meeting) {
        ids = meeting.unifiedTranscript.map(\.id)
        for track in meeting.tracks where offsets[track.id] == nil { offsets[track.id] = track.offset ?? 0 }
        for (position, segment) in meeting.unifiedTranscript.enumerated() {
            var citedTracks = Set<UUID>()
            for source in segment.provenance where citedTracks.insert(source.trackID).inserted {
                cited[source.trackID, default: Spans()].spans.append(Span(start: source.start, end: max(source.start, source.end), position: position))
            }
            if !citedTracks.contains(segment.trackID) {
                own[segment.trackID, default: Spans()].spans.append(Span(start: segment.start, end: max(segment.start, segment.end), position: position))
            }
        }
        for key in cited.keys { cited[key]?.finish() }
        for key in own.keys { own[key]?.finish() }
    }

    public func segmentID(at position: TimeInterval, trackID: UUID) -> UUID? {
        let fromCitations = cited[trackID]?.first(containing: position)
        let fromOwn = own[trackID]?.first(containing: position + (offsets[trackID] ?? 0))
        guard let found = [fromCitations, fromOwn].compactMap({ $0 }).min() else { return nil }
        return ids[found]
    }
}

public enum TranscriptFollow {
    /// The passage under the playhead, matched in the recording that is playing (`PlayheadIndex`).
    public static func segmentID(at position: TimeInterval, trackID: UUID, in meeting: Meeting) -> UUID? {
        PlayheadIndex(meeting: meeting).segmentID(at: position, trackID: trackID)
    }
}

/// Something to play: a passage (from its original recording), a time on the conversation's
/// timeline, or a time within one recording.
public enum PlaybackTarget: Equatable, Sendable {
    case segment(TranscriptSegment)
    case timeline(Double)
    case source(RecordingTrack, Double)

    /// The recording and the time within it. A timeline time no placed recording covers plays the
    /// first recording that's transcribed (an original with a cleaned copy plays through the copy).
    public func resolve(in meeting: Meeting) -> (track: RecordingTrack, seconds: Double)? {
        switch self {
        case .segment(let segment):
            guard let track = meeting.tracks.first(where: { $0.id == segment.trackID }) else { return nil }
            let original = segment.provenance.first { $0.trackID == track.id }?.start ?? max(0, segment.start - (track.offset ?? 0))
            return (track, original)
        case .timeline(let seconds):
            if let position = MeetingPlaybackPosition.resolve(seconds, in: meeting),
               let track = meeting.tracks.first(where: { $0.id == position.trackID }) {
                return (track, position.seconds)
            }
            guard let track = meeting.tracks.first(where: { meeting.transcribableTracks.contains($0) }) ?? meeting.tracks.first else { return nil }
            return (track, max(0, seconds - (track.offset ?? 0)))
        case .source(let track, let seconds):
            return (track, max(0, seconds))
        }
    }
}

/// A conversation's transcript as a page draws it: blocks, bookmark marks, and the playhead index,
/// worked out once per version of the conversation (`cached(for:)`) rather than at every redraw.
public struct TranscriptLayout: Sendable {
    public let blocks: [TranscriptBlock]
    public let marks: BookmarkMarks
    public let playhead: PlayheadIndex

    public init(_ meeting: Meeting) {
        blocks = TranscriptBlock.blocks(in: meeting)
        marks = BookmarkMarks(meeting: meeting)
        playhead = PlayheadIndex(meeting: meeting)
    }

    /// The layout for this version of the conversation: worked out again only when it changed. An
    /// unchanged conversation shares its arrays, so the comparison is quick.
    @MainActor
    public static func cached(for meeting: Meeting) -> TranscriptLayout {
        if let hit = cache[meeting.id], hit.meeting == meeting { return hit.layout }
        if cache.count >= 8 { cache.removeAll() }
        let layout = TranscriptLayout(meeting)
        cache[meeting.id] = (meeting, layout)
        builds += 1
        return layout
    }

    @MainActor private static var cache: [UUID: (meeting: Meeting, layout: TranscriptLayout)] = [:]
    /// Layouts worked out (tests).
    @MainActor public private(set) static var builds = 0
}

extension Array {
    /// The index of the first element for which `belongsInSecondPart` is true, in an array where
    /// every such element follows every other (a binary search).
    func partitioningIndex(where belongsInSecondPart: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if belongsInSecondPart(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
