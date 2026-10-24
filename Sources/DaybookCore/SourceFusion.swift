import Foundation

/// Fuses a conversation's transcripts using each recording's stored placement, then settles the
/// recordings still waiting to be placed: by the phrases they share, then by the recorders' clocks.
///
/// It prepares `TranscriptFusion`'s inputs and annotates its reports; it doesn't change how fusion
/// works. A placement's clock drift is applied by scaling a copy of the recording's segment times
/// before fusion, while each segment's provenance keeps the recording's own times, so corrections
/// still find their passages. Recordings without a stored placement fuse exactly as before.
public enum SourceFusion {
    public struct Result: Sendable {
        public var fusion: FusionResult
        /// New placements for recordings that were waiting. Store them with `Meeting.applyPlacements`.
        public var settled: [UUID: SourceAlignment]
    }

    public static func fuse(_ meeting: Meeting, now: Date = Date()) -> Result {
        let placements = currentPlacements(meeting)
        var result = run(meeting, placements: placements)
        var settled: [UUID: SourceAlignment] = [:]
        let reference = result.alignments.first { $0.method == .reference }?.trackID
        for track in meeting.tracks where waiting(track) {
            guard let report = result.alignments.first(where: { $0.trackID == track.id }), report.method == .anchors else { continue }
            let prior = track.alignment
            settled[track.id] = SourceAlignment(method: .transcript, offset: report.offset, rate: report.rate,
                                                confidence: SourcePlacement.anchorConfidence(report), referenceTrackID: reference,
                                                clockOffset: prior?.clockOffset, clockID: prior?.clockID, audioChecked: prior?.audioChecked, date: now)
        }
        // A recording on the same clock as one that was placed moves with it.
        settled.merge(SourcePlacement.followingClockSiblings(meeting.tracks, placed: placements.merging(settled) { $1 }, now: now)) { current, _ in current }
        // The rest: the recorders' clocks, when they're known. Otherwise it stays separate.
        for track in meeting.tracks where waiting(track) && settled[track.id] == nil {
            guard let report = result.alignments.first(where: { $0.trackID == track.id }), let prior = track.alignment else { continue }
            // Nothing else was transcribed (the other recordings were silent): the clocks still place it.
            if report.method == .reference, let clock = prior.clockOffset, clock.isFinite {
                settled[track.id] = SourceAlignment(method: .clock, offset: clock, rate: 1, confidence: 0.2, clockOffset: clock,
                                                    clockID: prior.clockID, audioChecked: prior.audioChecked, date: now)
                continue
            }
            guard report.method == .unaligned else { continue }
            if let clock = prior.clockOffset, clock.isFinite {
                settled[track.id] = SourceAlignment(method: .clock, offset: clock, rate: 1, confidence: 0.2, referenceTrackID: reference,
                                                    clockOffset: clock, clockID: prior.clockID, audioChecked: prior.audioChecked, date: now)
            } else if prior.method != .unaligned {
                var unaligned = prior
                unaligned.method = .unaligned; unaligned.date = now
                settled[track.id] = unaligned
            }
        }
        // Fuse again with every placement, so recordings placed by their clock or a sibling join in.
        let all = placements.merging(settled.filter { $0.value.isPlaced }) { $1 }
        if settled.values.contains(where: \.isPlaced) { result = run(meeting, placements: all) }
        return Result(fusion: keepingNamedSpeakers(annotate(result, all), in: meeting), settled: settled)
    }

    /// When two recordings of one passage become one, fusion keeps the clearer recording's words
    /// and speaker. A speaker the person named stays on the passage rather than giving way to the
    /// new recording's unnamed one, so adding a source never takes a name off what someone said.
    static func keepingNamedSpeakers(_ result: FusionResult, in meeting: Meeting) -> FusionResult {
        let named = Set(meeting.revisions.compactMap { $0.field.hasPrefix("speaker:") ? String($0.field.dropFirst(8)) : nil })
        guard !named.isEmpty else { return result }
        var spokenBy: [UUID: String] = [:]
        for transcript in meeting.transcripts { for segment in transcript.segments { if let speaker = segment.speakerID { spokenBy[segment.id] = speaker } } }
        var kept = result
        for index in kept.segments.indices where kept.segments[index].provenance.count > 1 {
            guard kept.segments[index].speakerID.map({ !named.contains($0) }) ?? true,
                  let person = kept.segments[index].provenance.lazy.compactMap({ spokenBy[$0.segmentID] }).first(where: named.contains) else { continue }
            kept.segments[index].speakerID = person
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

    private static func run(_ meeting: Meeting, placements: [UUID: SourceAlignment]) -> FusionResult {
        var tracks = meeting.tracks
        var unplaced = Set<UUID>()
        for index in tracks.indices {
            if let placement = placements[tracks[index].id] { tracks[index].offset = placement.offset }
            else if waiting(tracks[index]) { tracks[index].offset = nil; unplaced.insert(tracks[index].id) }
        }
        var transcripts = meeting.transcripts.map { transcript -> TrackTranscript in
            var copy = transcript
            if let placement = placements[transcript.trackID] { copy.knownOffset = placement.offset }
            else if unplaced.contains(transcript.trackID) { copy.knownOffset = nil }
            return copy
        }
        // Recordings with a known place lead, so the timeline's origin never moves to one still waiting.
        transcripts = transcripts.filter { !unplaced.contains($0.trackID) } + transcripts.filter { unplaced.contains($0.trackID) }
        // Placements (with their drift) go to fusion as inputs rather than pre-scaled segment times, so
        // the multi-source vote also sees each recording's role, the speakers, and the renamed ones.
        var inputPlacements: [UUID: TrackPlacement] = [:]
        for (trackID, placement) in placements {
            guard let offset = placement.offset, let method = fusionMethod(placement.method) else { continue }
            inputPlacements[trackID] = TrackPlacement(offset: offset, rate: placement.rate, method: method,
                                                      confidence: placement.confidence, referenceTrackID: placement.referenceTrackID,
                                                      explanation: explanation(placement))
        }
        // A track this Mac recorded carries the drift its capture measured against the session clock
        // (the echo-cancelled microphone is already resampled, so its rate is 1).
        for track in tracks where inputPlacements[track.id] == nil && !unplaced.contains(track.id) {
            guard let rate = track.capture?.clockRate, abs(rate - 1) > 1e-9, let offset = track.offset else { continue }
            inputPlacements[track.id] = TrackPlacement(offset: offset, rate: rate, method: .provided,
                                                       explanation: "Recorded on this Mac; its clock drift was measured while recording.")
        }
        let starts = Dictionary(meeting.tracks.compactMap { track in track.startedAt.map { (track.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let inputs = FusionInputs(meeting: meeting, placements: inputPlacements, recordingStartDates: starts)
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
    private static func annotate(_ result: FusionResult, _ placements: [UUID: SourceAlignment]) -> FusionResult {
        var annotated = result
        for index in annotated.alignments.indices {
            guard let placement = placements[annotated.alignments[index].trackID], annotated.alignments[index].method != .unaligned else { continue }
            annotated.alignments[index].rate = placement.rate
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
    /// and computer audio) take its placement, shifted by the difference in their clock offsets.
    public static func followingClockSiblings(_ tracks: [RecordingTrack], placed: [UUID: SourceAlignment],
                                              now: Date = Date()) -> [UUID: SourceAlignment] {
        var result: [UUID: SourceAlignment] = [:]
        for track in tracks {
            guard let pending = track.alignment, pending.method == .pending || pending.method == .unaligned,
                  placed[track.id] == nil, let clockID = pending.clockID, let ownClock = pending.clockOffset else { continue }
            let siblings = tracks.compactMap { other -> (SourceAlignment, TimeInterval)? in
                guard other.id != track.id, other.alignment?.clockID == clockID, let placement = placed[other.id],
                      [.audio, .transcript, .manual].contains(placement.method),
                      let offset = placement.offset, offset.isFinite, let clock = other.alignment?.clockOffset else { return nil }
                return (placement, clock)
            }
            guard let (sibling, siblingClock) = siblings.max(by: { ($0.0.confidence ?? 0) < ($1.0.confidence ?? 0) }) else { continue }
            var following = sibling
            following.offset = sibling.offset! + sibling.rate * (ownClock - siblingClock)
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
