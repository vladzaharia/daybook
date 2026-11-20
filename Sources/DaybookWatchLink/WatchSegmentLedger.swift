import Foundation

/// The iPhone's record of a watch's recordings: which segments have arrived for each, and when one is complete
/// (finished on the watch, every segment it lists here) so it can be joined and imported. Stored with the device,
/// so segments that arrived before a relaunch still count.
public struct WatchSegmentLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The recording as last reported (its state, or a segment's snapshot).
        public var recording: WatchRecordingInfo
        /// Segments that have arrived, by index.
        public var segments: [Int: WatchSegment]
        /// It's in the library: nothing more to do, kept only so a late segment isn't taken for a new recording.
        public var imported: Bool
        /// When the iPhone first heard of it.
        public var firstSeen: Date

        public init(recording: WatchRecordingInfo, segments: [Int: WatchSegment] = [:], imported: Bool = false, firstSeen: Date) {
            self.recording = recording
            self.segments = segments
            self.imported = imported
            self.firstSeen = firstSeen
        }

        /// Finished on the watch, with every segment it lists here.
        public var isComplete: Bool {
            recording.isFinished && recording.segmentIndices.allSatisfy { segments[$0] != nil }
        }

        /// Segments the finished recording lists that haven't arrived.
        public var missing: [Int] { recording.segmentIndices.filter { segments[$0] == nil } }

        /// The arrived segments, in order.
        public var orderedSegments: [WatchSegment] { segments.keys.sorted().compactMap { segments[$0] } }
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Imported recordings are forgotten after this long.
    public static let importedMemory: TimeInterval = 7 * 86_400

    public init() {}

    public subscript(id: String) -> Entry? { entries[id] }

    /// A segment arrived.
    public mutating func received(_ segment: WatchSegment, at now: Date = Date()) {
        var entry = entries[segment.recordingID] ?? Entry(recording: segment.recording, firstSeen: now)
        entry.segments[segment.index] = segment
        entry.recording = Self.later(entry.recording, segment.recording)
        entries[segment.recordingID] = entry
    }

    /// The watch reported a recording (in progress, or finished).
    public mutating func update(_ recording: WatchRecordingInfo, at now: Date = Date()) {
        if var entry = entries[recording.id] {
            entry.recording = Self.later(entry.recording, recording)
            entries[recording.id] = entry
        } else {
            entries[recording.id] = Entry(recording: recording, firstSeen: now)
        }
    }

    /// The recording is in the library.
    public mutating func markImported(_ id: String) {
        entries[id]?.imported = true
        entries[id]?.segments = [:]
    }

    /// Drops a recording entirely (the person removed the watch, or it can never complete).
    public mutating func remove(_ id: String) { entries[id] = nil }

    /// Forgets imported recordings older than `importedMemory`.
    public mutating func prune(now: Date = Date()) {
        entries = entries.filter { !$0.value.imported || now.timeIntervalSince($0.value.firstSeen) < Self.importedMemory }
    }

    /// Complete recordings not yet imported, oldest first.
    public var complete: [Entry] {
        entries.values.filter { $0.isComplete && !$0.imported }.sorted { $0.recording.startedAt < $1.recording.startedAt }
    }

    /// Recordings not yet imported, newest first.
    public var pending: [Entry] {
        entries.values.filter { !$0.imported }.sorted { $0.recording.startedAt > $1.recording.startedAt }
    }

    /// The more advanced of two reports of one recording: a finished one over one in progress, then the one with more
    /// segments or more audio. Its conversation is whichever either names: a recording adopts one once and keeps it,
    /// so a report from before it adopted never takes it away.
    static func later(_ a: WatchRecordingInfo, _ b: WatchRecordingInfo) -> WatchRecordingInfo {
        var merged: WatchRecordingInfo
        if a.isFinished != b.isFinished {
            merged = a.isFinished ? a : b
        } else if a.segmentIndices.count != b.segmentIndices.count {
            merged = a.segmentIndices.count > b.segmentIndices.count ? a : b
        } else {
            merged = b.duration >= a.duration ? b : a
        }
        merged.conversationID = merged.conversationID ?? a.conversationID ?? b.conversationID
        return merged
    }
}
