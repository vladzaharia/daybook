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

    @Extensible public var method: Method
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
    @Extensible public var state: State
    /// Daybook started the recorder, so it also stops it. False when it was already recording.
    public var startedByDaybook: Bool
    /// The track its recording became.
    public var trackID: UUID?
    /// The recorder's clock against this Mac's, measured when it was asked to record: the timing
    /// prior for its recording. Nil for recorders that report none (only Daybook's local link does).
    public var clock: CompanionClock?
    /// When the person chose Don't Wait: the conversation stops waiting for this recording, and adds it if it
    /// still arrives. Nil while it's waited for.
    public var stoppedWaitingAt: Date?

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
    @Extensible public var reason: Reason
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
    /// Where a recording sits on the timeline now (`clock(of:)`).
    public func timelinePlacement(of trackID: UUID) -> (offset: TimeInterval, rate: Double)? {
        clock(of: trackID).map { ($0.offset, $0.rate) }
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

    /// The recording a new source is lined up against: placed surely (`TimelineClock.isStrong`: never one placed only by
    /// shared phrases or the clocks, so a guess isn't composed on a guess), not on the same clock as anything
    /// `excluding` names, and the one most likely to share sound with another recorder (this Mac's original
    /// microphone, then computer audio, then recorders and files), longest first.
    public func alignmentReference(excluding: Set<UUID> = []) -> RecordingTrack? {
        func rank(_ track: RecordingTrack) -> Int {
            switch track.source {
            case .microphone: return track.derivedFrom == nil ? 0 : 1
            case .systemAudio: return 2
            case .soundcore: return 3
            case .imported: return 4
            }
        }
        let excludedClocks = Set(tracks.filter { excluding.contains($0.id) }.compactMap { $0.alignment?.clockID })
        let excludedFamilies = Set(tracks.filter { excluding.contains($0.id) }.flatMap { [$0.id] + ($0.derivedFrom.map { [$0] } ?? []) })
        // Nor one placed against an excluded recording (directly or in turn): comparing with it would compare a
        // recording with its own place.
        func restsOnExcluded(_ id: UUID) -> Bool {
            var current = clock(of: id)?.dependsOn, seen: Set<UUID> = [id]
            while let next = current, seen.insert(next).inserted {
                if excludedFamilies.contains(next) { return true }
                current = clock(of: next)?.dependsOn
            }
            return false
        }
        return tracks.filter { track in
            !excluding.contains(track.id) && !track.isRemoved && clock(of: track.id)?.isStrong == true
                && !(track.alignment?.clockID.map(excludedClocks.contains) ?? false)
                && !excludedFamilies.contains(track.derivedFrom ?? track.id) && !excludedFamilies.contains(track.id)
                && !restsOnExcluded(track.id)
        }
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
    /// recording move onto the timeline once it's placed, keeping their times in that recording: one
    /// taken before the timeline's zero (the iPhone led, and the Mac that sets the timeline joined
    /// later) is placed before it, at a negative time, as that recording's passages are.
    ///
    /// A recording that moves takes the recordings lined up against it along (`SourceAlignment.referenceTrackID`,
    /// placed by the sound or by following it on one clock), so nothing stays composed on a place it no longer has.
    public mutating func applyPlacements(_ placements: [UUID: SourceAlignment]) {
        var changed = false
        var moved: [(trackID: UUID, before: TimelineClock)] = []
        for (trackID, alignment) in placements.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { continue }
            let before = clock(of: trackID)
            var alignment = alignment
            let held = alignment.heldNoteIDs ?? tracks[index].alignment?.heldNoteIDs
            if alignment.isPlaced, let held, !held.isEmpty, let offset = alignment.offset {
                let start = alignment.captureOffset ?? tracks[index].alignment?.captureOffset ?? 0
                if var notes = timedNotes {
                    for note in notes.indices where held.contains(notes[note].id) {
                        if let time = notes[note].time { notes[note].time = offset + alignment.rate * (time - start) }
                    }
                    timedNotes = notes
                }
                alignment.heldNoteIDs = nil
            } else if alignment.heldNoteIDs == nil {
                alignment.heldNoteIDs = held
                if held != nil, alignment.captureOffset == nil { alignment.captureOffset = tracks[index].alignment?.captureOffset }
            }
            guard tracks[index].alignment != alignment else { continue }
            tracks[index].alignment = alignment
            if alignment.isPlaced { tracks[index].offset = alignment.offset }
            changed = true
            if let before, before.isStrong || before.method == .transcript || before.method == .clock { moved.append((trackID, before)) }
        }
        movingDependents(of: moved, except: Set(placements.keys))
        if changed { updatedAt = Date() }
    }

    /// Recordings placed against one that moved keep their place relative to it. The move is a map of the timeline
    /// (`timeline′ = α + β × timeline`, from the old and new clocks); each dependent's placement goes through the same
    /// map, and so do the recordings placed against it in turn.
    private mutating func movingDependents(of moved: [(trackID: UUID, before: TimelineClock)], except fixed: Set<UUID>) {
        var queue = moved, done = fixed
        while !queue.isEmpty {
            let (trackID, before) = queue.removeFirst()
            guard let after = clock(of: trackID), after != before, before.rate > 0 else { continue }
            let scale = after.rate / before.rate, shift = after.offset - scale * before.offset
            for index in tracks.indices where !done.contains(tracks[index].id) {
                guard var alignment = tracks[index].alignment, alignment.isPlaced, alignment.referenceTrackID == trackID,
                      [.audio, .transcript, .clock, .manual].contains(alignment.method), let offset = alignment.offset,
                      let previous = clock(of: tracks[index].id) else { continue }
                alignment.offset = shift + scale * offset
                alignment.rate = alignment.rate * scale
                tracks[index].alignment = alignment
                tracks[index].offset = alignment.offset
                done.insert(tracks[index].id)
                queue.append((tracks[index].id, previous))
            }
        }
    }

    /// What a recording made on another device (Daybook on iPhone) brings to its conversation: its
    /// notes and bookmarks, each added once by its ID, so filing again, or a copy that synced first,
    /// never doubles one, and a repeated paragraph keeps its own time.
    ///
    /// Joining a conversation another device leads, the recording is a source still to be placed:
    /// its bookmarks stay on its track, and its notes, timed by its clock, are held by the track and
    /// move onto the timeline once it's placed, whichever recording ends up setting the timeline.
    /// `shift` is where it probably starts on the timeline (from the link's clocks), so the notes
    /// read about right meanwhile.
    public mutating func addRecordingWork(trackID: UUID, notes added: [TimedNote], bookmarks: [Highlight], joining: Bool,
                                          shift: TimeInterval = 0) {
        let shift = joining && shift.isFinite ? max(0, shift) : 0
        for mark in bookmarks where !highlights.contains(where: { $0.id == mark.id }) {
            var kept = mark
            if joining { kept.trackID = trackID }
            highlights.append(kept)
        }
        var anchors = timedNotes ?? NoteTimeline.reconcile(previous: [], text: notes, captureTime: nil)
        let known = Set(anchors.map(\.id))
        let fresh = added.filter { !known.contains($0.id) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !fresh.isEmpty else { return }
        anchors += fresh.map { TimedNote(id: $0.id, time: $0.time.map { $0 + shift }, text: $0.text) }
        let text = fresh.map(\.text).joined(separator: "\n")
        notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : notes + (notes.hasSuffix("\n") ? "" : "\n") + text
        timedNotes = anchors
        let held = fresh.filter { $0.time != nil }.map(\.id)
        guard joining, !held.isEmpty, let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var alignment = tracks[index].alignment ?? SourceAlignment(method: .pending)
        alignment.heldNoteIDs = (alignment.heldNoteIDs ?? []) + held
        if alignment.captureOffset == nil { alignment.captureOffset = shift }
        applyPlacements([trackID: alignment])
    }

    /// One origin per conversation. Two Macs that recorded one conversation (an iPhone asked both to record along)
    /// each filed theirs as the timeline's origin, at their own capture offsets, so after sync both sit at zero and
    /// nothing places them. The recording that started first keeps the timeline; each other one becomes a source to
    /// place, all its tracks on one clock (`clockID`), with the clock prior where its start puts it: on the first's
    /// clock by the iPhone's measurements of both Macs while it recorded (`capture.peerClocks`), or else by the Macs'
    /// own clocks. Returns the placements to store (nothing when there's only one).
    public func separatingCaptureGroups(now: Date = Date()) -> [UUID: SourceAlignment] {
        let groups = captureGroups()
        guard groups.count > 1, let origin = groups.first, let originOffset = origin.lead.offset, originOffset.isFinite else { return [:] }
        let zero = origin.start.addingTimeInterval(-originOffset)
        var result: [UUID: SourceAlignment] = [:]
        for group in groups.dropFirst() {
            let shift = clockShift(from: group, to: origin) ?? 0
            for track in group.tracks {
                let start = track.startedAt ?? group.start.addingTimeInterval((track.offset ?? 0) - (group.lead.offset ?? 0))
                let prior = start.addingTimeInterval(shift).timeIntervalSince(zero)
                result[track.id] = SourceAlignment(method: .pending, clockOffset: prior.isFinite ? prior : nil, clockID: group.id, date: now)
            }
        }
        return result
    }

    /// Recordings this Mac or another made and filed as the timeline's own (no placement, a capture offset): one group
    /// per capture, the first-started first. A capture's tracks share `TrackCaptureDetails.captureID`; for ones filed
    /// before it was kept, each original microphone is its own capture, computer audio joins the microphone that
    /// started nearest it, and a derived copy joins its original.
    struct CaptureGroup {
        var id: UUID
        var tracks: [RecordingTrack]
        var lead: RecordingTrack
        /// When its first sample arrived, by its own device's clock.
        var start: Date { lead.startedAt ?? lead.createdAt }
        var deviceID: String? { lead.capture?.deviceID }
    }

    func captureGroups() -> [CaptureGroup] {
        let captured = tracks.filter { track in
            track.alignment == nil && track.deviceKind == nil && !track.isRemoved && track.capture != nil
                && (track.source == .microphone || track.source == .systemAudio) && track.offset?.isFinite == true
        }
        guard captured.count > 1 else { return [] }
        func start(_ track: RecordingTrack) -> Date { track.startedAt ?? track.createdAt }
        var key: [UUID: String] = [:]
        let microphones = captured.filter { $0.derivedFrom == nil && $0.source == .microphone && $0.capture?.captureID == nil }
        for track in captured where track.derivedFrom == nil {
            if let id = track.capture?.captureID { key[track.id] = id.uuidString; continue }
            if track.source == .microphone { key[track.id] = "track:\(track.id.uuidString)"; continue }
            let nearest = microphones.min { abs(start($0).timeIntervalSince(start(track))) < abs(start($1).timeIntervalSince(start(track))) }
            key[track.id] = nearest.flatMap { abs(start($0).timeIntervalSince(start(track))) <= 5 ? key[$0.id] : nil } ?? "track:\(track.id.uuidString)"
        }
        for track in captured where track.derivedFrom != nil {
            key[track.id] = track.derivedFrom.flatMap { key[$0] } ?? track.capture?.captureID?.uuidString ?? "track:\(track.id.uuidString)"
        }
        var groups: [CaptureGroup] = []
        for (name, members) in Dictionary(grouping: captured, by: { key[$0.id]! }) {
            let lead = members.filter { $0.derivedFrom == nil && $0.source == .microphone }.min { $0.id.uuidString < $1.id.uuidString }
                ?? members.filter { $0.derivedFrom == nil }.min { $0.id.uuidString < $1.id.uuidString } ?? members[0]
            let id = lead.capture?.captureID ?? UUID(uuidString: name) ?? SyncEncoding.uuid("capture:\(lead.id.uuidString)")
            groups.append(CaptureGroup(id: id, tracks: members.sorted { $0.id.uuidString < $1.id.uuidString }, lead: lead))
        }
        return groups.sorted { ($0.start, $0.lead.id.uuidString) < ($1.start, $1.lead.id.uuidString) }
    }

    /// Seconds to add to a time on `group`'s device clock to read it on `origin`'s: from an iPhone's measurements of
    /// both while it recorded (its offsets are the peer's clock minus its own). Nil when no recording measured both.
    private func clockShift(from group: CaptureGroup, to origin: CaptureGroup) -> TimeInterval? {
        func entry(_ target: CaptureGroup, in peers: [CapturePeerClock]) -> CapturePeerClock? {
            if let device = target.deviceID { return peers.first { $0.deviceID == device } }
            // Filed before the device was kept: the measured Mac whose recording started nearest this one, by its own clock.
            let start = target.start
            let nearest = peers.filter { $0.peerRecordingStartedAt != nil }
                .min { abs($0.peerRecordingStartedAt!.timeIntervalSince(start)) < abs($1.peerRecordingStartedAt!.timeIntervalSince(start)) }
            guard let nearest, abs(nearest.peerRecordingStartedAt!.timeIntervalSince(start)) <= 3 else { return nil }
            return nearest
        }
        for track in tracks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let peers = track.capture?.peerClocks, !peers.isEmpty,
                  let theirs = entry(group, in: peers), let ours = entry(origin, in: peers), theirs != ours else { continue }
            return ours.offset - theirs.offset
        }
        return nil
    }

    /// A recording filed as a source still to be placed (another device's, joining) that turns out to
    /// be its conversation's only one sets the timeline instead: offset 0, and the notes it held timed
    /// by its own clock.
    public mutating func makeTimelineOrigin(_ trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }), let alignment = tracks[index].alignment, alignment.isPending else { return }
        let held = Set(alignment.heldNoteIDs ?? []), start = alignment.captureOffset ?? 0
        if var notes = timedNotes {
            for note in notes.indices where held.contains(notes[note].id) {
                if let time = notes[note].time { notes[note].time = max(0, time - start) }
            }
            timedNotes = notes
        }
        tracks[index].alignment = nil
        tracks[index].offset = 0
        updatedAt = Date()
    }

    /// The person's own work in a conversation: notes, corrections, renamed speakers, bookmarks with
    /// text, tags, a folder, a chosen template or placement, completed next steps, or photos. A conversation
    /// with any of it is never moved to the Trash on its own.
    public var hasPersonMadeContent: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folderID != nil || !(tags ?? []).isEmpty
            || templateID != nil || placement != nil || summary?.actionItems.contains(where: \.completed) == true
            || revisions.contains { $0.kind.isPersonsEdit }
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

    /// Confidence for a transcript-anchor alignment: what the fit reported (it grows with how many phrases agreed,
    /// how closely, and how long a stretch they cover), or, for a fit made before it said, from the phrases alone.
    public static func anchorConfidence(_ report: TrackAlignment) -> Double {
        guard report.method == .anchors else { return 0 }
        if let confidence = report.confidence, confidence.isFinite { return confidence }
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
