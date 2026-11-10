import Foundation

/// What a conversation's recordings say about its saved live captions: the one rule both apps read for when
/// a transcript replaces them, line by line (`LiveCaptionStore.shown`, `prune`).
///
/// A line is replaced once a recording that heard it is transcribed: its own source's (another device's
/// recording, found by `LiveCaptions.tracks`; this device's, by `trackID` or by when it began), or, for this
/// device's own lines and lines whose recording isn't known, any transcribed recording that ran while it was
/// heard. Another device's line whose recording is known waits for that recording: what it heard may be what
/// no one else did. Only transcripts made after the captions began count, so an earlier recording's never
/// does. Captions are deleted only once every line is replaced.
public struct LiveCaptionCoverage: Hashable, Sendable {
    /// One of the conversation's recordings (a track), as the rule needs it.
    public struct Recording: Hashable, Sendable {
        public var trackID: UUID
        /// Its audio source (`AudioSource` raw value: "microphone", "systemAudio"…).
        public var source: String
        /// The device it came from and its ID there; nil for a Mac's own capture.
        public var deviceKind: String?
        public var recordingID: String?
        /// When it began, by its own device's clock, and how long it ran, when known.
        public var startedAt: Date?
        public var createdAt: Date
        public var duration: TimeInterval?
        /// When its newest transcript was made (its own, or one of a track made from it); nil until then.
        public var transcribedAt: Date?

        public init(trackID: UUID, source: String, deviceKind: String? = nil, recordingID: String? = nil, startedAt: Date? = nil,
                    createdAt: Date, duration: TimeInterval? = nil, transcribedAt: Date? = nil) {
            self.trackID = trackID; self.source = source; self.deviceKind = deviceKind; self.recordingID = recordingID
            self.startedAt = startedAt; self.createdAt = createdAt; self.duration = duration; self.transcribedAt = transcribedAt
        }
    }

    public var recordings: [Recording]
    /// When transcripts of recordings the conversation doesn't list any more were made.
    public var otherTranscripts: [Date]

    public init(recordings: [Recording] = [], otherTranscripts: [Date] = []) {
        self.recordings = recordings
        self.otherTranscripts = otherTranscripts
    }

    /// How far apart a recording's start and its captions' may be: captions begin as the recorder does.
    public static let recordingMatch: TimeInterval = 60

    /// Whether anything is transcribed, so there may be captions to replace.
    public var hasTranscript: Bool { !otherTranscripts.isEmpty || recordings.contains { $0.transcribedAt != nil } }

    /// Whether a transcript replaces `line` of `captions`.
    public func replaces(_ line: LiveCaptionSegment, of captions: LiveCaptions) -> Bool {
        guard hasTranscript else { return false }
        let began = captions.createdAt
        var byTime = false
        for source in [line.source] + (line.alsoHeard ?? []).map(Optional.some) {
            if let heard = recording(of: source, in: captions), let made = heard.transcribedAt, made >= began { return true }
            if source?.isDevice != true || captions.tracks?[source?.rawValue ?? ""] == nil { byTime = true }
        }
        guard byTime else { return false }
        let at = captions.origin.addingTimeInterval((line.start + max(line.start, line.end)) / 2)
        for recording in recordings {
            guard let made = recording.transcribedAt, made >= began else { continue }
            // A recording whose time isn't known covers what was heard after it began, as its transcript did before.
            guard let start = recording.startedAt, let duration = recording.duration else { return true }
            if at >= start.addingTimeInterval(-1), at <= start.addingTimeInterval(duration + 1) { return true }
        }
        return otherTranscripts.contains { $0 >= began }
    }

    /// Whether every line of `captions` is replaced, so they can go.
    public func replacesAll(_ captions: LiveCaptions) -> Bool {
        captions.segments.allSatisfy { !$0.hasWords || replaces($0, of: captions) }
    }

    /// `captions` with only the lines nothing replaces yet, and words to read; nil when none is left.
    public func shown(_ captions: LiveCaptions) -> LiveCaptions? {
        var shown = captions
        shown.segments = captions.segments.filter { $0.hasWords && !replaces($0, of: captions) }
        return shown.segments.isEmpty ? nil : shown
    }

    /// The recording a source's lines were heard by, once it's in the conversation.
    public func recording(of source: LiveCaptionSource?, in captions: LiveCaptions) -> Recording? {
        if let source, source.isDevice { return captions.tracks?[source.rawValue].flatMap(find) }
        if let filed = captions.trackID, let recording = recordings.first(where: { $0.trackID == filed }) { return recording }
        return find(LiveCaptionTrack(capture: source == .call ? "systemAudio" : "microphone", startedAt: captions.origin))
    }

    /// A recording by its reference: filed, by its device's ID for it, or a device's own capture by when it began.
    public func find(_ track: LiveCaptionTrack) -> Recording? {
        if let id = track.trackID { return recordings.first { $0.trackID == id } }
        if let kind = track.deviceKind, let id = track.recordingID {
            return recordings.first { $0.deviceKind == kind && $0.recordingID == id }
        }
        guard let capture = track.capture, let began = track.startedAt else { return nil }
        func distance(_ recording: Recording) -> TimeInterval { abs((recording.startedAt ?? recording.createdAt).timeIntervalSince(began)) }
        return recordings.filter { $0.deviceKind == nil && $0.source == capture && distance($0) <= Self.recordingMatch }
            .min { distance($0) < distance($1) }
    }
}

extension LiveCaptionSegment {
    /// Whether it has words to read.
    public var hasWords: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
