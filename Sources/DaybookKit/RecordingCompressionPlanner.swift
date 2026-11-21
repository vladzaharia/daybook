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

        public init(now: Date, age: RecordingCompressionAge, startsAt: Date?, settingsApplied: Bool, everyDeviceCompresses: Bool,
                    clockLooksAhead: Bool, thisDevice: String, macs: [RecordingCompressionRunner.Mac]?, inUse: Set<UUID> = [],
                    trashed: Set<UUID> = [], done: Set<UUID>, upgradeOffered: Set<UUID> = [], voiceprints: [Voiceprint] = []) {
            self.now = now; self.age = age; self.startsAt = startsAt; self.settingsApplied = settingsApplied
            self.everyDeviceCompresses = everyDeviceCompresses; self.clockLooksAhead = clockLooksAhead; self.thisDevice = thisDevice
            self.macs = macs; self.inUse = inUse; self.trashed = trashed; self.done = done; self.upgradeOffered = upgradeOffered
            self.voiceprints = voiceprints
        }
    }

    /// The pass's context. Before this Mac has the library's choices (a Never on another device may not have arrived),
    /// it hasn't started; a clock that looks ahead, or is behind anything in the library, can't be trusted for "30 days".
    public static func context(_ inputs: Inputs, meetings: [Meeting]) -> RecordingCompressionEligibility.Context {
        let behind = RecordingCompressionEligibility.newestDate(in: meetings).map { inputs.now < $0 } ?? false
        return .init(now: inputs.now, age: inputs.age, startsAt: inputs.settingsApplied ? inputs.startsAt : nil,
                     everyDeviceCompresses: inputs.everyDeviceCompresses, clockTrusted: !inputs.clockLooksAhead && !behind)
    }

    /// Conversations a voice profile learned from, and every conversation holding audio that came from one: a voiceprint
    /// names the conversation and recording it was learned from, and its audio may since have been merged into another
    /// (`mergedFrom`), moved into a conversation of its own (`removal.movedTo`), or be the same recording elsewhere (its
    /// bytes, or the track itself).
    public static func learnedFrom(_ meetings: [Meeting], voiceprints: [Voiceprint]) -> Set<UUID> {
        var protected = Set(voiceprints.map(\.meetingID))
        var trackIDs = Set(voiceprints.compactMap(\.trackID))
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

    /// The tracks of a decision this device compresses (`RecordingCompressionRunner`).
    public static func mine(_ ids: [UUID], in meeting: Meeting, _ inputs: Inputs) -> [UUID] {
        ids.filter { id in
            meeting.tracks.first { $0.id == id }.map {
                RecordingCompressionRunner.runner(for: $0, thisDevice: inputs.thisDevice, macs: inputs.macs, now: inputs.now) == inputs.thisDevice
            } ?? false
        }
    }

    /// Conversations worth reading files for, oldest first, each with the tracks this device would compress: everything
    /// but the files is decided first, and conversations whose recordings another Mac compresses are left out before any
    /// file is read.
    public static func candidates(_ meetings: [Meeting], _ inputs: Inputs) -> [(meetingID: UUID, trackIDs: [UUID])] {
        let context = context(inputs, meetings: meetings), learned = learnedFrom(meetings, voiceprints: inputs.voiceprints)
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
        let learned = learnedFrom(meetings, voiceprints: inputs.voiceprints)
        guard case .compress(let ids) = RecordingCompressionEligibility.decide(meeting, facts: facts(meeting, inputs, learned: learned, tracks: files),
                                                                               context: context(inputs, meetings: meetings)) else { return [] }
        return mine(ids, in: meeting, inputs)
    }

    /// Asked again under the lock, with what's true now (the files as already checked).
    public static func stillAllowed(_ meeting: Meeting, among meetings: [Meeting], _ inputs: Inputs) -> Bool {
        !tracks(meeting, among: meetings, inputs, files: Dictionary(uniqueKeysWithValues: meeting.tracks.map { ($0.id, assumedTrack) })).isEmpty
    }
}
