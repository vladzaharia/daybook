import DaybookCore
import Foundation

/// The wiring of a Mac's compression pass, apart from the app so it can be tested: what the pass knows, which
/// conversations it reads, and what it may still do under the lock. AppState+Compression.swift gathers the inputs.
public enum RecordingCompressionPlanner {
    public struct Inputs: Sendable {
        public var now: Date
        public var age: RecordingCompressionAge
        /// This Mac's first day in this library (`RecordingCompressionSchedule.startDate`).
        public var startsAt: Date?
        /// This Mac applied the library's choices from sync since it connected (or the library doesn't sync).
        public var settingsApplied: Bool
        public var everyDeviceCompresses: Bool
        public var clockLooksAhead: Bool
        public var thisDevice: String
        /// The other Macs, from presence; nil for a library that doesn't sync.
        public var macs: [RecordingCompressionRunner.Mac]?
        /// Conversations recorded into, processed, played, or merged here now.
        public var inUse: Set<UUID>
        public var trashed: Set<UUID>
        /// Conversations whose processing status is done.
        public var done: Set<UUID>
        public var upgradeOffered: Set<UUID>
        public var voiceprints: [Voiceprint]
        /// Conversations no longer in the library (the Trash, and those deleted from it for good, as their tombstones keep
        /// them: `LibraryController.compressionLineage`) whose audio may live on in one that is: a voiceprint's
        /// conversation moved out of, merged away, or holding the same recording.
        public var lineage: [Meeting]
        /// Recordings held back, by SHA-256: refused under the current rule, or waiting after a failure
        /// (`LibraryController.compressionHeldBack`).
        public var refused: Set<String>
        /// This Mac's own clock check passed (`RecordingCompressionClock.trusts`).
        public var clockSteady: Bool
        /// This pass has the transcript bar's model: without it, a track with speech in its transcript waits.
        public var canListen: Bool

        public init(now: Date, age: RecordingCompressionAge, startsAt: Date?, settingsApplied: Bool, everyDeviceCompresses: Bool,
                    clockLooksAhead: Bool, thisDevice: String, macs: [RecordingCompressionRunner.Mac]?, inUse: Set<UUID> = [],
                    trashed: Set<UUID> = [], done: Set<UUID>, upgradeOffered: Set<UUID> = [], voiceprints: [Voiceprint] = [],
                    lineage: [Meeting] = [], refused: Set<String> = [], clockSteady: Bool = true, canListen: Bool = true) {
            self.now = now; self.age = age; self.startsAt = startsAt; self.settingsApplied = settingsApplied
            self.everyDeviceCompresses = everyDeviceCompresses; self.clockLooksAhead = clockLooksAhead; self.thisDevice = thisDevice
            self.macs = macs; self.inUse = inUse; self.trashed = trashed; self.done = done; self.upgradeOffered = upgradeOffered
            self.voiceprints = voiceprints; self.lineage = lineage; self.refused = refused; self.clockSteady = clockSteady
            self.canListen = canListen
        }
    }

    /// The pass's context. Before this Mac has the library's choices (a Never on another device may not have arrived),
    /// it hasn't started; a clock that looks ahead, or is behind anything in the library, can't be trusted for "30 days".
    public static func context(_ inputs: Inputs, meetings: [Meeting]) -> RecordingCompressionEligibility.Context {
        let behind = RecordingCompressionEligibility.newestDate(in: meetings).map { inputs.now < $0 } ?? false
        return .init(now: inputs.now, age: inputs.age, startsAt: inputs.settingsApplied ? inputs.startsAt : nil,
                     everyDeviceCompresses: inputs.everyDeviceCompresses, clockTrusted: !inputs.clockLooksAhead && !behind && inputs.clockSteady)
    }

    /// Conversations a voice profile learned from, and every conversation holding audio that came from one: a voiceprint
    /// names the conversation and recording it was learned from, and its audio may since have been merged into another
    /// (`mergedFrom`), moved into a conversation of its own (`removal.movedTo`), or be the same recording elsewhere (its
    /// bytes, or the track itself). `lineage` are conversations in the Trash or deleted from it for good, followed too,
    /// so a move whose source was deleted since still leads to the copy. A move can be followed only from the conversation
    /// it left (`movedTo`), so while any voiceprint's conversation is nowhere here (never on this device), every
    /// conversation holding a recording moved in from elsewhere (`Meeting.wasMovedHere`) is protected as well.
    public static func learnedFrom(_ meetings: [Meeting], voiceprints: [Voiceprint], lineage: [Meeting] = []) -> Set<UUID> {
        let meetings = meetings + lineage.filter { gone in !meetings.contains { $0.id == gone.id } }
        var protected = Set(voiceprints.map(\.meetingID))
        var trackIDs = Set(voiceprints.compactMap(\.trackID))
        let known = Set(meetings.map(\.id))
        if voiceprints.contains(where: { !known.contains($0.meetingID) }) {
            for meeting in meetings where meeting.tracks.contains(where: { meeting.wasMovedHere($0.id) }) { protected.insert(meeting.id) }
        }
        var grew = true
        while grew {
            grew = false
            let digests = Set(meetings.filter { protected.contains($0.id) }.flatMap { $0.tracks.flatMap(\.knownDigests) })
            let movedTo = Set(meetings.filter { protected.contains($0.id) }.flatMap { $0.tracks.compactMap { $0.removal?.movedTo } })
            for meeting in meetings where !protected.contains(meeting.id) {
                let descends = movedTo.contains(meeting.id) || meeting.tracks.contains { track in
                    trackIDs.contains(track.id) || track.mergedFrom.map(protected.contains) == true
                        || track.knownDigests.contains(where: digests.contains)
                }
                if descends { protected.insert(meeting.id); grew = true }
            }
            trackIDs.formUnion(meetings.filter { protected.contains($0.id) }.flatMap { $0.tracks.map(\.id) })
        }
        return protected
    }

    public static let assumedTrack = RecordingCompressionEligibility.TrackFacts(isVerified: true, isUploaded: true, storage: .lossless)

    public static func facts(_ meeting: Meeting, _ inputs: Inputs, learned: Set<UUID>,
                             tracks: [UUID: RecordingCompressionEligibility.TrackFacts]? = nil) -> RecordingCompressionEligibility.ConversationFacts {
        .init(isBusy: inputs.inUse.contains(meeting.id), isTrashed: inputs.trashed.contains(meeting.id), isDone: inputs.done.contains(meeting.id),
              offersUpgrade: inputs.upgradeOffered.contains(meeting.id), teachesVoiceProfile: learned.contains(meeting.id),
              tracks: tracks ?? Dictionary(uniqueKeysWithValues: meeting.tracks.map { ($0.id, assumedTrack) }))
    }

    /// The tracks of a decision this device compresses (`RecordingCompressionRunner`), less those held back (refused, or
    /// waiting after a failure) and, without the transcript bar's model this pass, those with speech.
    public static func mine(_ ids: [UUID], in meeting: Meeting, _ inputs: Inputs) -> [UUID] {
        ids.filter { id in
            meeting.tracks.first {
                $0.id == id && !inputs.refused.contains($0.sha256) && (inputs.canListen || !TranscriptSample.hasSpeech($0, in: meeting))
            }.map {
                RecordingCompressionRunner.runner(for: $0, thisDevice: inputs.thisDevice, macs: inputs.macs, now: inputs.now) == inputs.thisDevice
            } ?? false
        }
    }

    /// Conversations worth reading files for, oldest first, each with the tracks this device would compress: everything
    /// but the files is decided first, and conversations whose recordings another Mac compresses are left out before any
    /// file is read.
    public static func candidates(_ meetings: [Meeting], _ inputs: Inputs) -> [(meetingID: UUID, trackIDs: [UUID])] {
        let context = context(inputs, meetings: meetings), learned = learnedFrom(meetings, voiceprints: inputs.voiceprints, lineage: inputs.lineage)
        let oldestFirst = meetings.sorted { RecordingCompressionEligibility.lastActivity(of: $0) < RecordingCompressionEligibility.lastActivity(of: $1) }
        return oldestFirst.compactMap { meeting in
            guard case .compress(let ids) = RecordingCompressionEligibility.decide(meeting, facts: facts(meeting, inputs, learned: learned), context: context) else { return nil }
            let tracks = mine(ids, in: meeting, inputs)
            return tracks.isEmpty ? nil : (meeting.id, tracks)
        }
    }

    /// With the files read: this device's tracks to compress, or none.
    public static func tracks(_ meeting: Meeting, among meetings: [Meeting], _ inputs: Inputs,
                              files: [UUID: RecordingCompressionEligibility.TrackFacts]) -> [UUID] {
        let learned = learnedFrom(meetings, voiceprints: inputs.voiceprints, lineage: inputs.lineage)
        guard case .compress(let ids) = RecordingCompressionEligibility.decide(meeting, facts: facts(meeting, inputs, learned: learned, tracks: files),
                                                                               context: context(inputs, meetings: meetings)) else { return [] }
        return mine(ids, in: meeting, inputs)
    }

    /// Asked again under the lock, with what's true now (the files as already checked).
    public static func stillAllowed(_ meeting: Meeting, among meetings: [Meeting], _ inputs: Inputs) -> Bool {
        !tracks(meeting, among: meetings, inputs, files: Dictionary(uniqueKeysWithValues: meeting.tracks.map { ($0.id, assumedTrack) })).isEmpty
    }
}

/// Whether this Mac's clock is steady enough to judge "30 days ago" (alongside compaction's `clockLooksAhead` and the
/// library's newest date), against this Mac's last pass in the library. Since the same boot, the wall clock must have
/// moved as a clock nobody can set did (`elapsed`, the continuous clock, which counts through sleep), within an hour: a
/// jump either way is distrusted, and the app keeps measuring from before it until the Mac restarts. Across a restart,
/// it's distrusted when it went back more than an hour or moved more than 3 days ahead (a jump, or a long time off:
/// either way the pass waits one cycle, and the next measures from then). And in a synced library, it's distrusted when
/// it's more than 7 days past the newest presence any other device wrote (they'd be gone a week, or the clock jumped).
public enum RecordingCompressionClock {
    public static let largestGap: TimeInterval = 3 * 86_400
    public static let wentBack: TimeInterval = 3_600
    public static let othersTolerance: TimeInterval = 7 * 86_400

    public static func trusts(now: Date, lastPass: Date?, elapsed: TimeInterval? = nil, newestOtherDevice: Date?) -> Bool {
        if let lastPass {
            if let elapsed {
                if abs(now.timeIntervalSince(lastPass) - elapsed) > wentBack { return false }
            } else {
                if now < lastPass.addingTimeInterval(-wentBack) { return false }
                if now > lastPass.addingTimeInterval(largestGap) { return false }
            }
        }
        if let newestOtherDevice, now > newestOtherDevice.addingTimeInterval(othersTolerance) { return false }
        return true
    }
}
