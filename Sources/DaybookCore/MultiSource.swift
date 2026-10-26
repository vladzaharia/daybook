import Foundation

// One conversation, several recordings of it: this Mac's microphone and computer audio, a
// recorder worn in the room, a file added later. These records say where each recording sits on
// the conversation's timeline, which recorder was asked to record alongside this Mac, and which
// recordings may belong to a conversation but wait for the person to say so. All are optional
// additions, so libraries written before multipoint recording decode unchanged.

/// Where a recording sits on its conversation's timeline, and how Daybook found out.
/// `timeline = offset + rate * recordingTime`. A recording this Mac made for its own conversation
/// has none: its capture offset is its timing, as before.
public struct SourceAlignment: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// Found from the sound itself (`AudioAligner`).
        case audio
        /// Found from phrases both transcripts share.
        case transcript
        /// Placed by the recorders' clocks only.
        case clock
        /// Set by the person (Adjust Timing).
        case manual
        /// Not placed yet. Processing tries the sound, then the transcript, then the clocks.
        case pending
        /// Nothing placed it; its transcript stays separate until the person sets the timing.
        case unaligned
    }

    public var method: Method
    /// Seconds on the conversation's timeline where the recording's first second falls. Nil until placed.
    public var offset: TimeInterval?
    /// Conversation seconds per second of this recording (clock drift; 1 means none).
    public var rate: Double
    /// From 0 to 1, when the method reports one.
    public var confidence: Double?
    /// The recording it was lined up against.
    public var referenceTrackID: UUID?
    /// Where the recorders' clocks put it: the last resort, and the prior for the sound search.
    public var clockOffset: TimeInterval?
    /// Recordings made on one clock (one Mac recording's microphone and computer audio) share this
    /// and move together when only one of them can be lined up from the sound.
    public var clockID: UUID?
    /// The sound was compared and didn't settle it, so processing moves on to the transcript.
    public var audioChecked: Bool?
    /// Notes written while this Mac recorded into a conversation that already had recordings. They
    /// were timed by this recording's clock and move onto the timeline when it's placed.
    public var heldNoteIDs: [UUID]?
    /// Where this recording starts within its capture, for the held notes.
    public var captureOffset: TimeInterval?
    public var date: Date

    public init(method: Method, offset: TimeInterval? = nil, rate: Double = 1, confidence: Double? = nil,
                referenceTrackID: UUID? = nil, clockOffset: TimeInterval? = nil, clockID: UUID? = nil,
                audioChecked: Bool? = nil, heldNoteIDs: [UUID]? = nil, captureOffset: TimeInterval? = nil, date: Date = Date()) {
        self.method = method; self.offset = offset; self.rate = rate; self.confidence = confidence
        self.referenceTrackID = referenceTrackID; self.clockOffset = clockOffset; self.clockID = clockID
        self.audioChecked = audioChecked; self.heldNoteIDs = heldNoteIDs; self.captureOffset = captureOffset; self.date = date
    }

    /// Placed on the timeline: these are used as the recording's timing in place of anything inferred.
    public var isPlaced: Bool {
        guard let offset, offset.isFinite, rate.isFinite, rate > 0 else { return false }
        return [.audio, .transcript, .clock, .manual].contains(method)
    }

    /// Waiting for processing to place it.
    public var isPending: Bool { method == .pending }
}

/// A recorder Daybook asked to record alongside this Mac (multipoint). Its recording joins this
/// conversation when it arrives, however it arrives: automatic import, a later manual import, or
/// an export through the recorder's folder.
public struct CompanionRecording: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Connecting to the recorder or waiting for it to confirm.
        case starting
        /// The recorder confirmed it's recording.
        case recording
        /// It was already recording when this Mac started; Daybook leaves it running.
        case alreadyRecording
        /// It wasn't nearby or wouldn't connect.
        case unavailable
        /// It didn't confirm the start.
        case failed
        case stopping
        case stopped
        /// It didn't confirm the stop; the person stops it on the recorder.
        case stopFailed
        /// Its recording is in this conversation.
        case attached
    }

    public var id: UUID
    /// The configured device (`ConfiguredDevice.id`) on the Mac that asked.
    public var deviceID: String
    public var deviceKind: String
    public var deviceSerial: String?
    /// "Soundcore Work".
    public var deviceName: String
    /// When the Mac recording started.
    public var macStartedAt: Date
    public var macEndedAt: Date?
    /// When the recorder says its recording started.
    public var recorderStartedAt: Date?
    /// The recorder's ID for the recording, once it reports one.
    public var recordingID: String?
    public var state: State
    /// Daybook started the recorder, so it also stops it. False when it was already recording.
    public var startedByDaybook: Bool
    /// The track its recording became.
    public var trackID: UUID?
    /// The recorder's clock against this Mac's, measured when it was asked to record: the timing
    /// prior for its recording. Nil for recorders that report none (only Daybook's local link does).
    public var clock: CompanionClock?

    public init(id: UUID = UUID(), deviceID: String, deviceKind: String, deviceSerial: String? = nil, deviceName: String,
                macStartedAt: Date, state: State = .starting, startedByDaybook: Bool = false) {
        self.id = id; self.deviceID = deviceID; self.deviceKind = deviceKind; self.deviceSerial = deviceSerial
        self.deviceName = deviceName; self.macStartedAt = macStartedAt; self.state = state
        self.startedByDaybook = startedByDaybook
    }

    /// The recorder recorded, or may have, so its recording is expected.
    public var expectsRecording: Bool { [.recording, .alreadyRecording, .stopping, .stopped, .stopFailed].contains(state) }

    /// When the recorder's recording started, on this Mac's clock: its own report, corrected by the
    /// measured clock offset when there is one.
    public var recorderStartedOnMacClock: Date? { recorderStartedAt.map { clock?.macDate(fromRecorder: $0) ?? $0 } }
}

/// A recorder's clock against this Mac's, from clock samples over Daybook's local link (NTP-style).
public struct CompanionClock: Codable, Equatable, Sendable {
    /// The recorder's clock minus this Mac's, in seconds.
    public var offset: TimeInterval
    /// How far `offset` could be off: half the round trip of the sample it rests on.
    public var uncertainty: TimeInterval
    public var samples: Int
    /// When it was measured, on this Mac's clock.
    public var measuredAt: Date

    public init(offset: TimeInterval, uncertainty: TimeInterval, samples: Int, measuredAt: Date) {
        self.offset = offset; self.uncertainty = uncertainty; self.samples = samples; self.measuredAt = measuredAt
    }

    /// A time on the recorder's clock, on this Mac's.
    public func macDate(fromRecorder date: Date) -> Date { date.addingTimeInterval(-offset) }
}

/// A recording that may belong with another conversation. It stays in a conversation of its own,
/// with its original intact, until the person confirms, or until its transcript settles it.
public struct SourceSuggestion: Codable, Equatable, Identifiable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// More than one conversation overlaps it in time.
        case severalConversations
        /// One conversation overlaps it, but the sound matched only weakly.
        case lowConfidence
        /// One conversation overlaps it. Once both are transcribed, shared phrases decide.
        case checkingTranscript
    }

    public var id: UUID
    /// The recording, in the conversation that holds this suggestion.
    public var trackID: UUID
    /// Most likely first.
    public var candidateMeetingIDs: [UUID]
    public var reason: Reason
    public var confidence: Double?
    /// Where the clocks put the recording on each candidate's timeline, by candidate.
    public var clockOffsets: [UUID: TimeInterval]?
    public var createdAt: Date

    public init(id: UUID = UUID(), trackID: UUID, candidateMeetingIDs: [UUID], reason: Reason,
                confidence: Double? = nil, clockOffsets: [UUID: TimeInterval]? = nil, createdAt: Date = Date()) {
        self.id = id; self.trackID = trackID; self.candidateMeetingIDs = candidateMeetingIDs; self.reason = reason
        self.confidence = confidence; self.clockOffsets = clockOffsets; self.createdAt = createdAt
    }
}

extension Meeting {
    /// Where a recording sits on the timeline now: its stored placement, else the latest fused
    /// report, else its captured offset, else zero for the conversation's first recording.
    public func timelinePlacement(of trackID: UUID) -> (offset: TimeInterval, rate: Double)? {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return nil }
        if let alignment = track.alignment, alignment.isPlaced, let offset = alignment.offset { return (offset, alignment.rate) }
        if let original = track.derivedFrom, track.alignment == nil, let placed = timelinePlacement(of: original) { return placed }
        if let report = alignmentReports.first(where: { $0.trackID == trackID }), report.method != .unaligned,
           report.offset.isFinite, report.rate.isFinite, report.rate > 0 { return (report.offset, report.rate) }
        if track.alignment?.method == .pending || track.alignment?.method == .unaligned { return nil }
        if let offset = track.offset, offset.isFinite { return (offset, 1) }
        return tracks.first?.id == trackID ? (0, 1) : nil
    }

    /// When the timeline's zero happened by the wall clock, from a placed recording whose start is
    /// known (this Mac's own recordings first, since notes and bookmarks are timed by that clock).
    /// Nil when no recording's start is known.
    public func knownTimelineStart(startOf start: (RecordingTrack) -> Date? = { $0.startedAt }) -> Date? {
        let ordered = tracks.filter { $0.source == .microphone || $0.source == .systemAudio } + tracks.filter { $0.source != .microphone && $0.source != .systemAudio }
        for track in ordered {
            guard let begin = start(track), let placement = timelinePlacement(of: track.id) else { continue }
            return begin.addingTimeInterval(-placement.offset)
        }
        return nil
    }

    /// The timeline's zero by the wall clock, or the conversation's date when no start is known.
    public func timelineStart(startOf start: (RecordingTrack) -> Date? = { $0.startedAt }) -> Date {
        knownTimelineStart(startOf: start) ?? date
    }

    /// The recording a new source is lined up against: placed, and the one most likely to share
    /// sound with another recorder (this Mac's original microphone, then computer audio, then
    /// recorders and files), longest first.
    public func alignmentReference(excluding: Set<UUID> = []) -> RecordingTrack? {
        func rank(_ track: RecordingTrack) -> Int {
            switch track.source {
            case .microphone: return track.derivedFrom == nil ? 0 : 1
            case .systemAudio: return 2
            case .soundcore: return 3
            case .imported: return 4
            }
        }
        return tracks.filter { !excluding.contains($0.id) && timelinePlacement(of: $0.id) != nil }
            .min { lhs, rhs in
                rank(lhs) != rank(rhs) ? rank(lhs) < rank(rhs) : (lhs.duration ?? 0) > (rhs.duration ?? 0)
            }
    }

    /// The span the conversation's recordings cover by the wall clock, when a start is known.
    public func wallClockSpan(startOf start: (RecordingTrack) -> Date? = { $0.startedAt }) -> DateInterval? {
        guard !tracks.isEmpty, let zero = knownTimelineStart(startOf: start) else { return nil }
        var lower = TimeInterval.infinity, upper = -TimeInterval.infinity
        for track in tracks {
            let placement = timelinePlacement(of: track.id) ?? (track.alignment?.clockOffset).map { ($0, 1) }
            let begin = placement?.offset ?? 0, rate = placement?.rate ?? 1
            lower = min(lower, begin)
            upper = max(upper, begin + rate * (track.duration ?? 0))
        }
        guard lower.isFinite, upper.isFinite, upper >= lower else { return nil }
        return DateInterval(start: zero.addingTimeInterval(lower), end: zero.addingTimeInterval(upper))
    }

    /// Stores placements, and uses their offsets as the recordings' timing. Notes held by a
    /// recording move onto the timeline once it's placed.
    public mutating func applyPlacements(_ placements: [UUID: SourceAlignment]) {
        var changed = false
        for (trackID, alignment) in placements.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { continue }
            var alignment = alignment
            let held = alignment.heldNoteIDs ?? tracks[index].alignment?.heldNoteIDs
            if alignment.isPlaced, let held, !held.isEmpty, let offset = alignment.offset {
                let start = alignment.captureOffset ?? tracks[index].alignment?.captureOffset ?? 0
                if var notes = timedNotes {
                    for note in notes.indices where held.contains(notes[note].id) {
                        if let time = notes[note].time { notes[note].time = max(0, offset + alignment.rate * (time - start)) }
                    }
                    timedNotes = notes
                }
                alignment.heldNoteIDs = nil
            } else if alignment.heldNoteIDs == nil {
                alignment.heldNoteIDs = held
            }
            guard tracks[index].alignment != alignment else { continue }
            tracks[index].alignment = alignment
            if alignment.isPlaced { tracks[index].offset = alignment.offset }
            changed = true
        }
        if changed { updatedAt = Date() }
    }

    /// The person's own work in a conversation: notes, corrections, renamed speakers, bookmarks with
    /// text, tags, a folder, a chosen template or placement, completed next steps, or photos. A conversation
    /// with any of it is never moved to the Trash on its own.
    public var hasPersonMadeContent: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folderID != nil || !(tags ?? []).isEmpty
            || templateID != nil || placement != nil || summary?.actionItems.contains(where: \.completed) == true
            || revisions.contains { ["segment", "speaker", "notes"].contains($0.field.split(separator: ":").first.map(String.init) ?? "") }
            || highlights.contains { !$0.text.isEmpty } || !visiblePhotos.isEmpty
    }
}

/// Composes alignments on to the conversation's timeline.
public enum SourcePlacement {
    /// A sound alignment of `other` against a reference recording placed at `reference` gives
    /// `other`'s place on the timeline: `timeline = r.offset + r.rate * (a.offset + a.rate * t)`.
    public static func compose(_ alignment: AudioAlignment, onto reference: (offset: TimeInterval, rate: Double)) -> (offset: TimeInterval, rate: Double) {
        (reference.offset + reference.rate * alignment.offset, reference.rate * alignment.rate)
    }

    /// The prior to give `AudioAligner`: where the clocks put `other`'s start in the reference's own time.
    public static func expectedOffset(clockOffset: TimeInterval?, reference: (offset: TimeInterval, rate: Double)) -> TimeInterval? {
        guard let clockOffset, reference.rate > 0 else { return nil }
        return (clockOffset - reference.offset) / reference.rate
    }

    /// Confidence for a transcript-anchor alignment, from how many phrases agreed and how closely.
    public static func anchorConfidence(_ report: TrackAlignment) -> Double {
        guard report.method == .anchors else { return 0 }
        let count = min(1, Double(report.matchedAnchors) / 12)
        let closeness = report.residual.map { max(0, 1 - $0 / 1.5) } ?? 0.5
        return (0.45 + 0.4 * count + 0.15 * closeness).rounded(toPlaces: 2)
    }
}

fileprivate extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
