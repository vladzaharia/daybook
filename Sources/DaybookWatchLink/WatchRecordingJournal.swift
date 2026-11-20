import Foundation

/// A recording's journal on the watch (docs/watch.md, "Segments and recovery"): its closed segments, the one being
/// written, and which the iPhone has. Saved beside the segments (`journal.json`) whenever it changes, so a recording
/// the app was ended during is closed at the next launch (`recover`). Pure values: the watch app's writer keeps it, and
/// the Mac tests it.
public struct WatchRecordingJournal: Codable, Equatable, Sendable {
    /// The segment being written.
    public struct OpenSegment: Codable, Equatable, Sendable {
        public var index: Int
        /// Seconds from the recording's first sample.
        public var startOffset: TimeInterval

        public init(index: Int, startOffset: TimeInterval) {
            self.index = index
            self.startOffset = startOffset
        }
    }

    public static let fileName = "journal.json"

    public var recording: WatchRecordingInfo
    /// Closed segments, in order, each with the recording as it was when it closed.
    public private(set) var segments: [WatchSegment] = []
    /// The segment being written; nil between segments (an interruption) and once finished.
    public private(set) var open: OpenSegment?
    /// Segments the iPhone holds: its receipt named them (`WatchReceipt`). A finished transfer isn't proof it kept the file.
    public private(set) var delivered: Set<Int> = []
    /// When each segment's transfer finished, by index: each is sent once, and again only when the iPhone asks
    /// (`receive`), never moments after its transfer finished.
    public private(set) var transferred: [Int: Date] = [:]
    /// When the shared recording it records along with started, on the iPhone's clock (`WatchFollowing`).
    public var conversationStartedAt: Date?
    /// Started by the iPhone's `.start` for no conversation (Record on the watch's page on the iPhone): the watch's own.
    /// It may adopt a shared recording, but the iPhone's context never stops it (`WatchFollowing`).
    public var isOwn = false

    /// How long after a segment's transfer finished the iPhone's ask doesn't send it again: WatchConnectivity may not
    /// have handed the file to the iPhone's handler yet.
    public static let resendAfter: TimeInterval = 120

    public init(recording: WatchRecordingInfo) {
        self.recording = recording
    }

    private enum CodingKeys: String, CodingKey {
        case recording, segments, open, delivered, transferred, conversationStartedAt, isOwn
    }

    /// Leniently: only the recording is required. A field an earlier build didn't store takes its default, so a journal
    /// written before it is still recovered rather than left unreadable beside its audio.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recording = try container.decode(WatchRecordingInfo.self, forKey: .recording)
        segments = (try? container.decodeIfPresent([WatchSegment].self, forKey: .segments)) ?? []
        open = try? container.decodeIfPresent(OpenSegment.self, forKey: .open)
        delivered = (try? container.decodeIfPresent(Set<Int>.self, forKey: .delivered)) ?? []
        if let dated = try? container.decodeIfPresent([Int: Date].self, forKey: .transferred) {
            transferred = dated
        } else if let indices = try? container.decodeIfPresent(Set<Int>.self, forKey: .transferred) {
            // An earlier build stored only which: finished long ago, as far as anyone knows.
            transferred = Dictionary(uniqueKeysWithValues: indices.map { ($0, Date.distantPast) })
        }
        conversationStartedAt = try? container.decodeIfPresent(Date.self, forKey: .conversationStartedAt)
        isOwn = (try? container.decodeIfPresent(Bool.self, forKey: .isOwn)) ?? false
    }

    /// Where the closed segments end: the start of the next run's audio is never before it.
    public var end: TimeInterval {
        segments.map { $0.startOffset + $0.duration }.max() ?? 0
    }

    /// Opens the next segment, starting `startOffset` seconds into the recording.
    @discardableResult
    public mutating func openSegment(at startOffset: TimeInterval) -> OpenSegment {
        let index = max(segments.map(\.index).max() ?? -1, open?.index ?? -1) + 1
        let segment = OpenSegment(index: index, startOffset: max(startOffset, 0))
        open = segment
        return segment
    }

    /// Closes the open segment, `duration` seconds and `byteCount` bytes, and returns it; with `finishing`, the recording
    /// finishes with it. A segment with no audio is left out (its file is the caller's to delete), and nil comes back.
    @discardableResult
    public mutating func closeSegment(duration: TimeInterval, byteCount: UInt64, cleanly: Bool = true,
                                      finishing: Bool = false) -> WatchSegment? {
        defer { if finishing { finish() } }
        guard let open else { return nil }
        self.open = nil
        guard duration > 0 else { return nil }
        recording.byteCount += byteCount
        recording.segmentIndices.append(open.index)
        recording.duration = max(recording.duration, open.startOffset + duration)
        if finishing { recording.isFinished = true }
        let segment = WatchSegment(recordingID: recording.id, index: open.index, startOffset: open.startOffset,
                                   duration: duration, cleanlyClosed: cleanly, recording: recording)
        segments.append(segment)
        return segment
    }

    /// Finishes the recording with the segments it has. A segment still open is left out.
    public mutating func finish() {
        open = nil
        recording.isFinished = true
        recording.segmentIndices = segments.map(\.index)
        recording.duration = max(recording.duration, end)
    }

    /// Closes a recording found unfinished at launch (the app was ended while it recorded). The segment being written
    /// is kept when its file reads (`openDuration` seconds of audio), as not cleanly closed, and left out when it
    /// doesn't (nil or zero: the caller deletes its file). Returns the segment kept, which still has to go to the
    /// iPhone.
    @discardableResult
    public mutating func recover(openDuration: TimeInterval?, openByteCount: UInt64 = 0) -> WatchSegment? {
        guard !recording.isFinished else { return nil }
        guard open != nil, let openDuration, openDuration > 0 else {
            finish()
            return nil
        }
        return closeSegment(duration: openDuration, byteCount: openByteCount, cleanly: false, finishing: true)
    }

    /// The iPhone has these segments.
    public mutating func deliver(_ indices: [Int]) {
        delivered.formUnion(indices.filter { index in segments.contains { $0.index == index } })
    }

    /// A segment's transfer finished, `now`: it isn't sent again unless the iPhone asks.
    public mutating func sent(_ index: Int, at now: Date = Date()) {
        if segments.contains(where: { $0.index == index }) { transferred[index] = now }
    }

    /// The iPhone's receipt for this recording: the segments it names are delivered. Only one that `requestsMissing`
    /// (for a finished recording, it names every segment the iPhone holds) sends anything again: the segments it leaves
    /// out come back, in order, to send, and count as unsent until a transfer of them finishes. Not one whose transfer
    /// finished within `resendAfter` of `now` (it may still be on its way to the iPhone's handler); the caller skips those
    /// it's sending now.
    @discardableResult
    public mutating func receive(_ receipt: WatchReceipt, at now: Date = Date()) -> [WatchSegment] {
        guard receipt.recordingID == recording.id else { return [] }
        guard receipt.requestsMissing, recording.isFinished, !receipt.imported else {
            deliver(receipt.segments)
            return []
        }
        let held = Set(receipt.segments)
        delivered = Set(segments.map(\.index).filter(held.contains))
        let missing = segments.filter { segment in
            guard !held.contains(segment.index) else { return false }
            guard let finished = transferred[segment.index] else { return true }
            return abs(now.timeIntervalSince(finished)) >= Self.resendAfter
        }
        for segment in missing { transferred[segment.index] = nil }
        return missing
    }

    /// Closed segments the iPhone hasn't named yet, in order.
    public var undelivered: [WatchSegment] { segments.filter { !delivered.contains($0.index) } }

    /// Closed segments to send: the iPhone hasn't named them and no transfer of them has finished, in order.
    public var unsent: [WatchSegment] { segments.filter { !delivered.contains($0.index) && transferred[$0.index] == nil } }
}
