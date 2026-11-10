import Foundation

/// Fuses a conversation's transcripts using each recording's place on the timeline (`Meeting.clock(of:)`), then
/// settles the recordings still waiting to be placed: by the phrases they share, then by the recorders' clocks.
///
/// It prepares `TranscriptFusion`'s inputs and annotates its reports; it doesn't change how fusion
/// works. Each placement goes to fusion with its offset and clock drift (`TrackPlacement`), while each
/// segment's provenance keeps the recording's own times, so corrections still find their passages.
/// Recordings without a stored placement fuse exactly as before.
public enum SourceFusion {
    public struct Result: Sendable {
        public var fusion: FusionResult
        /// New placements for recordings that were waiting. Store them with `Meeting.applyPlacements`.
        public var settled: [UUID: SourceAlignment]
    }

    /// `version` is the fusion to run (`FusionSummary.currentVersion`; upkeep passes the conversation's own, so its
    /// wording doesn't change with a new Daybook until it's fused for a new reason).
    public static func fuse(_ original: Meeting, now: Date = Date(), version: Int = FusionSummary.currentVersion) -> Result {
        let version = FusionSummary.supported(version)
        var meeting = original
        var settled: [UUID: SourceAlignment] = [:]
        var repaired: [UUID: SourceAlignment] = [:]
        if version >= 2 {
            // One origin per conversation: a second Mac's recording, filed as an origin too, waits to be placed.
            let separated = meeting.separatingCaptureGroups(now: now)
            meeting.applyPlacements(separated)
            settled = separated
            // A phrase fit stored with a rate no clock runs at is fitted again, keeping its offset if that fails.
            for index in meeting.tracks.indices {
                guard let alignment = meeting.tracks[index].alignment, alignment.method == .transcript, alignment.isPlaced,
                      !ClockRate.isPlausible(alignment.rate) else { continue }
                var kept = alignment
                kept.rate = 1; kept.date = now
                repaired[meeting.tracks[index].id] = kept
                var waiting = alignment
                waiting.method = .pending; waiting.offset = nil; waiting.rate = 1
                meeting.tracks[index].alignment = waiting
                meeting.tracks[index].offset = nil
            }
        }
        var result = run(meeting, version: version)
        let reference = result.alignments.first { $0.method == .reference }?.trackID
        for track in meeting.tracks where waiting(track) {
            guard let report = result.alignments.first(where: { $0.trackID == track.id }), report.method == .anchors else { continue }
            let prior = track.alignment
            settled[track.id] = SourceAlignment(method: .transcript, offset: report.offset, rate: report.rate,
                                                confidence: SourcePlacement.anchorConfidence(report), referenceTrackID: reference,
                                                clockOffset: prior?.clockOffset, clockID: prior?.clockID, audioChecked: prior?.audioChecked,
                                                heldNoteIDs: prior?.heldNoteIDs, captureOffset: prior?.captureOffset, date: now)
        }
        // A recording on the same clock as one that was placed moves with it.
        let placed = currentPlacements(meeting).merging(settled.filter { $0.value.isPlaced }) { $1 }
        settled.merge(SourcePlacement.followingClockSiblings(meeting.tracks, placed: placed, now: now)) { current, following in
            current.isPlaced ? current : following
        }
        // The rest: the recorders' clocks, when they're known. Otherwise it stays separate.
        for track in meeting.tracks where waiting(track) && settled[track.id]?.isPlaced != true {
            guard let report = result.alignments.first(where: { $0.trackID == track.id }), let prior = track.alignment else { continue }
            if let kept = repaired[track.id] { settled[track.id] = kept; continue }
            // Nothing else was transcribed (the other recordings were silent): the clocks still place it.
            if report.method == .reference, let clock = prior.clockOffset, clock.isFinite {
                settled[track.id] = SourceAlignment(method: .clock, offset: clock, rate: 1, confidence: 0.2, clockOffset: clock,
                                                    clockID: prior.clockID, audioChecked: prior.audioChecked,
                                                    heldNoteIDs: prior.heldNoteIDs, captureOffset: prior.captureOffset, date: now)
                continue
            }
            guard report.method == .unaligned else { continue }
            if let clock = prior.clockOffset, clock.isFinite {
                settled[track.id] = SourceAlignment(method: .clock, offset: clock, rate: 1, confidence: 0.2, referenceTrackID: reference,
                                                    clockOffset: clock, clockID: prior.clockID, audioChecked: prior.audioChecked,
                                                    heldNoteIDs: prior.heldNoteIDs, captureOffset: prior.captureOffset, date: now)
            } else if prior.method != .unaligned {
                var unaligned = prior
                unaligned.method = .unaligned; unaligned.date = now
                settled[track.id] = unaligned
            }
        }
        // Fuse again with every placement, so recordings placed by their clock or a sibling join in.
        if settled.values.contains(where: \.isPlaced) {
            meeting = placing(settled, in: meeting)
            result = run(meeting, version: version)
        }
        return Result(fusion: keepingNamedSpeakers(annotate(result, meeting), in: original, version: version), settled: settled)
    }

    /// When two recordings of one passage become one, fusion keeps the clearer recording's words and speaker. A
    /// speaker the person named stays where the name stood in the transcript before: on the same passage, or on the
    /// passage made from the same recording's segment. A name from another recording that merely heard it (a room
    /// recorder's cluster that took in the call's voice) never labels it. Before fusion version 2, any named speaker
    /// in the passage's provenance did.
    static func keepingNamedSpeakers(_ result: FusionResult, in meeting: Meeting, version: Int = FusionSummary.currentVersion) -> FusionResult {
        let named = meeting.renamedSpeakerIDs
        guard !named.isEmpty else { return result }
        var kept = result
        guard version >= 2 else {
            var spokenBy: [UUID: String] = [:]
            for transcript in meeting.transcripts { for segment in transcript.segments { if let speaker = segment.speakerID { spokenBy[segment.id] = speaker } } }
            for index in kept.segments.indices where kept.segments[index].provenance.count > 1 {
                guard kept.segments[index].speakerID.map({ !named.contains($0) }) ?? true,
                      let person = kept.segments[index].provenance.lazy.compactMap({ spokenBy[$0.segmentID] }).first(where: named.contains) else { continue }
                kept.segments[index].speakerID = person
            }
            return kept
        }
        var byPassage: [UUID: String] = [:], byHome: [UUID: String] = [:]
        for passage in meeting.unifiedTranscript {
            guard let speaker = passage.speakerID, named.contains(speaker) else { continue }
            byPassage[passage.id] = speaker
            let home = passage.provenance.first?.segmentID ?? passage.id
            if byHome[home] == nil { byHome[home] = speaker }
        }
        for index in kept.segments.indices where kept.segments[index].provenance.count > 1 {
            let segment = kept.segments[index]
            guard segment.speakerID.map({ !named.contains($0) }) ?? true else { continue }
            if let person = byPassage[segment.id] ?? segment.provenance.first.flatMap({ byHome[$0.segmentID] }) {
                kept.segments[index].speakerID = person
            }
        }
        return kept
    }

    /// Placed recordings, including a derived recording (the microphone with the call's echo
    /// removed) that follows its original.
    public static func currentPlacements(_ meeting: Meeting) -> [UUID: SourceAlignment] {
        var placements: [UUID: SourceAlignment] = [:]
        for track in meeting.tracks {
            if let alignment = track.alignment, alignment.isPlaced { placements[track.id] = alignment }
        }
        for track in meeting.tracks where track.alignment == nil {
            if let original = track.derivedFrom, let placement = placements[original] { placements[track.id] = placement }
        }
        return placements
    }

    private static func waiting(_ track: RecordingTrack) -> Bool {
        track.alignment?.method == .pending || track.alignment?.method == .unaligned
    }

    /// The meeting with settled placements stored on its tracks, for fusing (notes and dependents are the caller's).
    private static func placing(_ settled: [UUID: SourceAlignment], in meeting: Meeting) -> Meeting {
        var placed = meeting
        for index in placed.tracks.indices {
            guard let alignment = settled[placed.tracks[index].id], alignment.isPlaced else { continue }
            placed.tracks[index].alignment = alignment
            placed.tracks[index].offset = alignment.offset
        }
        return placed
    }

    private static func run(_ meeting: Meeting, version: Int) -> FusionResult {
        var tracks = meeting.tracks
        var unplaced = Set<UUID>()
        // Every placed recording's clock (`Meeting.clock(of:)`), as fusion's input: with its drift, rather than
        // pre-scaled segment times, so the multi-source vote also sees each recording's role, the speakers, and the
        // renamed ones. A recording timed by its capture at rate 1 needs none; fusion reads its capture offset.
        var inputPlacements: [UUID: TrackPlacement] = [:]
        for index in tracks.indices {
            let track = tracks[index]
            if waiting(track) { tracks[index].offset = nil; unplaced.insert(track.id); continue }
            guard let clock = meeting.storedClock(of: track.id) else { continue }
            tracks[index].offset = clock.offset
            let original = track.derivedFrom.flatMap { id in meeting.tracks.first { $0.id == id } }
            let decided = track.alignment.flatMap { $0.isPlaced ? $0 : nil }
                ?? (track.alignment == nil ? original?.alignment.flatMap { $0.isPlaced ? $0 : nil } : nil)
            if let decided, let method = fusionMethod(decided.method) {
                inputPlacements[track.id] = TrackPlacement(offset: clock.offset, rate: clock.rate, method: method,
                                                           confidence: decided.confidence, referenceTrackID: decided.referenceTrackID,
                                                           explanation: explanation(decided))
            } else if abs(clock.rate - 1) > 1e-9 || (original.map { abs($0.captureRate - 1) > 1e-9 } ?? false) {
                // The drift its capture measured against the session clock. The echo-cancelled copy, resampled onto
                // that clock, is given its own place here, so it never follows its original's drift.
                inputPlacements[track.id] = TrackPlacement(offset: clock.offset, rate: clock.rate, method: .provided,
                                                           explanation: "Recorded on this Mac; its clock drift was measured while recording.")
            }
        }
        var transcripts = meeting.transcripts.map { transcript -> TrackTranscript in
            var copy = transcript
            if let placement = inputPlacements[transcript.trackID] { copy.knownOffset = placement.offset }
            else if unplaced.contains(transcript.trackID) { copy.knownOffset = nil }
            return copy
        }
        // Recordings with a known place lead, so the timeline's origin never moves to one still waiting.
        transcripts = transcripts.filter { !unplaced.contains($0.trackID) } + transcripts.filter { unplaced.contains($0.trackID) }
        // Wall-clock starts place what nothing else does, except a recording waiting with a clock prior: the prior is
        // the same estimate, corrected by the clocks a link measured, and it's applied below as a `.clock` placement.
        let starts = Dictionary(meeting.tracks.compactMap { track -> (UUID, Date)? in
            guard !(unplaced.contains(track.id) && track.alignment?.clockOffset?.isFinite == true) else { return nil }
            return track.startedAt.map { (track.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let inputs = FusionInputs(meeting: meeting, placements: inputPlacements, recordingStartDates: starts, options: FusionOptions(version: version))
        return TranscriptFusion.fuse(transcripts, tracks: tracks, inputs: inputs)
    }

    private static func fusionMethod(_ method: SourceAlignment.Method) -> TrackAlignment.Method? {
        switch method {
        case .audio: return .audio
        case .transcript: return .anchors
        case .clock: return .timestamps
        case .manual: return .provided
        case .pending, .unaligned: return nil
        }
    }

    /// Reports say how each placed recording was lined up, with its drift.
    private static func annotate(_ result: FusionResult, _ meeting: Meeting) -> FusionResult {
        let placements = currentPlacements(meeting)
        var annotated = result
        for index in annotated.alignments.indices {
            let trackID = annotated.alignments[index].trackID
            guard let placement = placements[trackID], annotated.alignments[index].method != .unaligned else { continue }
            annotated.alignments[index].rate = meeting.clock(of: trackID)?.rate ?? placement.rate
            if let explanation = explanation(placement) { annotated.alignments[index].explanation = explanation }
        }
        return annotated
    }

    static func explanation(_ placement: SourceAlignment) -> String? {
        let sure = placement.confidence.map { " (\(Int(($0 * 100).rounded()))% confidence)" } ?? ""
        switch placement.method {
        case .audio: return "Lined up from the sound itself\(sure). Short replies and differing wording remain separate."
        case .transcript: return "Lined up using phrases both recordings share\(sure). Short replies and differing wording remain separate."
        case .clock: return "Placed by the recorders’ clocks only; no shared sound or phrases were found. Adjust the timing if passages look out of step."
        case .manual: return "Timing set by you."
        case .pending, .unaligned: return nil
        }
    }
}

extension SourcePlacement {
    /// Recordings still waiting that share a clock with a placed one (one Mac recording's microphone
    /// and computer audio) take its placement, shifted by the difference in their clock offsets. The capture's
    /// clock runs at the sibling's rate over its capture rate; each recording runs on it at its own capture rate,
    /// so the echo-cancelled copy (resampled onto that clock) never takes the raw microphone's drift.
    /// `referenceTrackID` is the sibling it follows, so it moves when that does.
    public static func followingClockSiblings(_ tracks: [RecordingTrack], placed: [UUID: SourceAlignment],
                                              now: Date = Date()) -> [UUID: SourceAlignment] {
        var result: [UUID: SourceAlignment] = [:]
        for track in tracks {
            guard let pending = track.alignment, pending.method == .pending || pending.method == .unaligned,
                  placed[track.id] == nil, let clockID = pending.clockID, let ownClock = pending.clockOffset else { continue }
            let siblings = tracks.compactMap { other -> (id: UUID, placement: SourceAlignment, clock: TimeInterval, rate: Double)? in
                guard other.id != track.id, other.alignment?.clockID == clockID, let placement = placed[other.id],
                      [.audio, .transcript, .manual].contains(placement.method),
                      let offset = placement.offset, offset.isFinite, let clock = other.alignment?.clockOffset else { return nil }
                return (other.id, placement, clock, other.captureRate)
            }
            guard let sibling = siblings.max(by: {
                ($0.placement.confidence ?? 0, $1.id.uuidString) < ($1.placement.confidence ?? 0, $0.id.uuidString)
            }) else { continue }
            let session = (ClockRate.bounded(sibling.placement.rate) ?? 1) / sibling.rate
            var following = sibling.placement
            following.offset = sibling.placement.offset! + session * (ownClock - sibling.clock)
            following.rate = ClockRate.bounded(session * track.captureRate) ?? 1
            following.referenceTrackID = sibling.id
            following.clockOffset = ownClock
            following.clockID = clockID
            following.heldNoteIDs = pending.heldNoteIDs
            following.captureOffset = pending.captureOffset
            following.audioChecked = pending.audioChecked
            following.date = now
            result[track.id] = following
        }
        return result
    }
}
