import Foundation

/// A recording arriving from a recorder or a file, before it joins the library.
public struct SourceArrival: Equatable, Sendable {
    /// When it started, by the recorder's clock or the file's date.
    public var start: Date?
    public var duration: TimeInterval
    public var device: DeviceRecordingIdentity?
    /// The start came from the recorder's own clock rather than a file date, which copying can change.
    public var startIsReliable: Bool

    public init(start: Date?, duration: TimeInterval, device: DeviceRecordingIdentity? = nil, startIsReliable: Bool) {
        self.start = start; self.duration = duration; self.device = device; self.startIsReliable = startIsReliable
    }

    public var span: DateInterval? {
        guard let start, duration.isFinite, duration > 0 else { return nil }
        return DateInterval(start: start, duration: duration)
    }
}

/// A conversation an arriving recording overlaps in time.
public struct SourceCandidate: Equatable, Sendable {
    public var meetingID: UUID
    public var overlap: TimeInterval
    /// The overlap as a share of the shorter of the two spans.
    public var share: Double
    /// Where the clocks put the arriving recording on this conversation's timeline.
    public var clockOffset: TimeInterval

    public init(meetingID: UUID, overlap: TimeInterval, share: Double, clockOffset: TimeInterval) {
        self.meetingID = meetingID; self.overlap = overlap; self.share = share; self.clockOffset = clockOffset
    }
}

/// Decides which conversation an arriving recording belongs to: a multipoint link first, then
/// overlap in time, confirmed by the sound (`AudioAligner`), and failing that by the transcript.
/// Overlapping in time is never proof on its own, so a recording joins a conversation automatically
/// only on a link or a confident sound match; anything less becomes a suggestion.
public enum SourceMatcher {
    public struct Policy: Equatable, Sendable {
        /// Less overlap than this isn't a candidate.
        public var minimumOverlap: TimeInterval = 20
        public var minimumShare: Double = 0.3
        /// A sound match at least this sure joins the conversation without asking.
        public var attachConfidence: Double = 0.6
        /// A weaker sound match is still offered as a suggestion.
        public var suggestConfidence: Double = 0.25
        /// A sound alignment at least this sure places a recording already in the conversation.
        public var placeConfidence: Double = 0.5
        /// A transcript alignment at least this sure confirms a suggested match.
        public var transcriptConfidence: Double = 0.55
        /// A link's recorder start and an arriving recording's start agree within this.
        public var linkTolerance: TimeInterval = 5
        /// Without a reported start, a recording starting this soon after the Mac fulfils the link.
        public var linkWindow: TimeInterval = 120
        /// The sound search around the clocks' estimate, for recorder clocks and for file dates.
        public var clockSearchRadius: TimeInterval = 120
        public var fileSearchRadius: TimeInterval = 900
        public init() {}
    }

    public enum Decision: Equatable, Sendable {
        case attach(UUID)
        /// Its own conversation, as before multipoint.
        case standalone
        /// Its own conversation, with a suggestion the person confirms.
        case suggest([UUID], SourceSuggestion.Reason, confidence: Double?)
        /// One conversation overlaps: compare the sound before deciding.
        case compareSound(SourceCandidate)
    }

    /// The conversation a multipoint link reserved for this recorder recording, and the link. The
    /// recording ID decides when the recorder reported one; otherwise the start times must agree.
    public static func linked(_ identity: DeviceRecordingIdentity, start: Date?, in meetings: [Meeting],
                              policy: Policy = Policy()) -> (meetingID: UUID, companionID: UUID)? {
        var best: (meetingID: UUID, companionID: UUID, strength: Int, distance: TimeInterval)?
        for meeting in meetings {
            for companion in meeting.companions ?? [] where companion.deviceKind == identity.kind {
                if let a = companion.deviceSerial, let b = identity.serial, !a.isEmpty, !b.isEmpty, a != b { continue }
                var strength = 0, distance = TimeInterval.infinity
                if let id = companion.recordingID {
                    guard id == identity.recordingID else { continue }
                    strength = 3; distance = 0
                } else if companion.expectsRecording, let start {
                    if let recorderStart = companion.recorderStartedAt {
                        distance = abs(start.timeIntervalSince(recorderStart))
                        if distance <= policy.linkTolerance { strength = 2 }
                    } else {
                        let delay = start.timeIntervalSince(companion.macStartedAt)
                        if delay >= -policy.linkTolerance && delay <= policy.linkWindow { strength = 1; distance = abs(delay) }
                    }
                }
                guard strength > 0 else { continue }
                if best == nil || strength > best!.strength || (strength == best!.strength && distance < best!.distance) {
                    best = (meeting.id, companion.id, strength, distance)
                }
            }
        }
        return best.map { ($0.meetingID, $0.companionID) }
    }

    /// Conversations the arriving recording overlaps in time, most overlap first. `live` adds the
    /// span of a conversation being recorded now, which may hold no recording yet.
    public static func candidates(for arrival: SourceArrival, in meetings: [Meeting], live: [UUID: DateInterval] = [:],
                                  excluding: Set<UUID> = [], startOf: (RecordingTrack) -> Date? = { $0.startedAt },
                                  policy: Policy = Policy()) -> [SourceCandidate] {
        guard let span = arrival.span else { return [] }
        var result: [SourceCandidate] = []
        for meeting in meetings where !excluding.contains(meeting.id) {
            var spans: [DateInterval] = []
            if let recorded = meeting.wallClockSpan(startOf: startOf) { spans.append(recorded) }
            if let now = live[meeting.id] { spans.append(now) }
            guard let lower = spans.map(\.start).min(), let upper = spans.map(\.end).max() else { continue }
            let other = DateInterval(start: lower, end: max(lower, upper))
            let overlap = min(span.end, other.end).timeIntervalSince(max(span.start, other.start))
            let shorter = max(1, min(span.duration, other.duration))
            guard overlap >= min(policy.minimumOverlap, shorter), overlap / shorter >= policy.minimumShare else { continue }
            let zero = meeting.knownTimelineStart(startOf: startOf) ?? lower
            result.append(SourceCandidate(meetingID: meeting.id, overlap: overlap, share: overlap / shorter,
                                          clockOffset: span.start.timeIntervalSince(zero)))
        }
        return result.sorted { $0.overlap == $1.overlap ? $0.meetingID.uuidString < $1.meetingID.uuidString : $0.overlap > $1.overlap }
    }

    /// The decision from time alone.
    public static func decide(_ candidates: [SourceCandidate]) -> Decision {
        switch candidates.count {
        case 0: return .standalone
        case 1: return .compareSound(candidates[0])
        default: return .suggest(candidates.map(\.meetingID), .severalConversations, confidence: nil)
        }
    }

    /// The decision for the one overlapping conversation, once the sound was compared. `sound` is the
    /// arriving recording's place on the candidate's timeline (the aligner's result composed onto the
    /// reference recording's place), like `clockOffset`. With nothing conclusive from the sound, the
    /// transcript decides after transcription.
    public static func decide(_ candidate: SourceCandidate, sound: AudioAlignment?, startIsReliable: Bool,
                              policy: Policy = Policy()) -> Decision {
        guard let sound, sound.confidence.isFinite, sound.offset.isFinite else {
            return .suggest([candidate.meetingID], .checkingTranscript, confidence: nil)
        }
        // Trustworthy clocks that disagree with the sound by more than the search allows mean the
        // match is something else (a repeated sound, the same broadcast in two rooms).
        let agrees = !startIsReliable || abs(sound.offset - candidate.clockOffset) <= policy.clockSearchRadius
        if sound.confidence >= policy.attachConfidence && agrees { return .attach(candidate.meetingID) }
        if sound.confidence >= policy.suggestConfidence { return .suggest([candidate.meetingID], .lowConfidence, confidence: sound.confidence) }
        return .suggest([candidate.meetingID], .checkingTranscript, confidence: nil)
    }

    /// Lines up a transcribed recording with another conversation by the phrases they share. Returns
    /// its placement on that conversation's timeline when the transcript confirms the match.
    public static func transcriptPlacement(of transcript: TrackTranscript, track: RecordingTrack, clockOffset: TimeInterval?,
                                           in candidate: Meeting, policy: Policy = Policy()) -> SourceAlignment? {
        guard candidate.transcripts.contains(where: { !$0.segments.isEmpty }) else { return nil }
        var probe = candidate
        var arriving = track
        arriving.offset = nil
        arriving.alignment = SourceAlignment(method: .pending, clockOffset: nil, audioChecked: true)
        probe.tracks.removeAll { $0.id == track.id }
        probe.tracks.append(arriving)
        var copy = transcript
        copy.knownOffset = nil
        probe.transcripts.removeAll { $0.trackID == track.id }
        probe.transcripts.append(copy)
        guard var placement = SourceFusion.fuse(probe).settled[track.id], placement.method == .transcript,
              (placement.confidence ?? 0) >= policy.transcriptConfidence else { return nil }
        placement.clockOffset = clockOffset
        return placement
    }
}
