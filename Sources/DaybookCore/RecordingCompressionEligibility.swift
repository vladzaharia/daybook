import Foundation

/// Whether a conversation's recordings may be compressed now (docs/architecture.md, "Compressing older recordings").
/// Replacing a recording is irreversible, so every condition must hold and anything this version can't judge is a no:
/// the conversation is skipped and looked at again on a later pass.
public enum RecordingCompressionEligibility {
    /// How a track's file is stored, read from the file (`AudioCompressor.storage(of:)`).
    public enum Storage: Equatable, Sendable {
        /// Linear PCM, Apple Lossless, or FLAC: what's compressed.
        case lossless
        /// AAC, Opus, MP3, or anything else that already threw sound away (every iPhone and Watch recording): never
        /// encoded again.
        case lossy
        /// Couldn't be read, or a layout the encoder doesn't take (more than two channels, an unusual sample rate).
        case unsupported
    }

    /// What this device found of one track's file.
    public struct TrackFacts: Equatable, Sendable {
        /// The file is here and its bytes have the track's SHA-256 (checked against the file, not trusted).
        public var isVerified: Bool
        /// iCloud holds the object and reports it uploaded; nil when the library doesn't sync.
        public var isUploaded: Bool?
        public var storage: Storage
        public init(isVerified: Bool, isUploaded: Bool?, storage: Storage) {
            self.isVerified = isVerified; self.isUploaded = isUploaded; self.storage = storage
        }
    }

    /// What the app knows of the conversation beyond its own record.
    public struct ConversationFacts: Equatable, Sendable {
        /// Recording, processing (queued or running), playing, importing, merging or moving, or being synced into, now.
        public var isBusy: Bool
        /// In the Trash.
        public var isTrashed: Bool
        /// Its processing status is done (`ProcessingStatus.done`): nothing waits, nothing awaited, nothing failed.
        public var isDone: Bool
        /// An Upgrade is offered for it here (`Upgrades.offer`).
        public var offersUpgrade: Bool
        /// A voice profile learned from it. Its recordings stay as they are until profiles keep their own clips of the
        /// speech they learned from.
        public var teachesVoiceProfile: Bool
        /// Every track's file, by track ID. A track missing here is a track this device couldn't check.
        public var tracks: [UUID: TrackFacts]
        public init(isBusy: Bool = false, isTrashed: Bool = false, isDone: Bool, offersUpgrade: Bool = false,
                    teachesVoiceProfile: Bool = false, tracks: [UUID: TrackFacts]) {
            self.isBusy = isBusy; self.isTrashed = isTrashed; self.isDone = isDone; self.offersUpgrade = offersUpgrade
            self.teachesVoiceProfile = teachesVoiceProfile; self.tracks = tracks
        }
    }

    /// What holds for the whole pass.
    public struct Context: Equatable, Sendable {
        public var now: Date
        public var age: RecordingCompressionAge
        /// When this device may start (the first-run wait: `RecordingCompressionSchedule`); nil while it hasn't been set.
        public var startsAt: Date?
        /// Every device seen in the last 30 days compresses (presence feature `compress-1`), or the library doesn't sync.
        /// A device that doesn't would keep the original and could merge it back.
        public var everyDeviceCompresses: Bool
        public init(now: Date, age: RecordingCompressionAge, startsAt: Date?, everyDeviceCompresses: Bool) {
            self.now = now; self.age = age; self.startsAt = startsAt; self.everyDeviceCompresses = everyDeviceCompresses
        }
    }

    public enum Refusal: Equatable, Sendable {
        case off, notStarted, notEveryDevice
        case trashed, busy, notDone, failed, notTranscribed, noSummary, noSpeakers, openRequest, upgradeOffered
        case tooRecent, teachesVoiceProfile, newerFields
        case notVerified(UUID), notUploaded(UUID)
        case nothingToCompress
    }

    public enum Decision: Equatable, Sendable {
        /// These tracks may be compressed now, in this order.
        case compress([UUID])
        case skip(Refusal)
    }

    /// The last time anything happened to the conversation: an edit, a result, a request, a recording added.
    public static func lastActivity(of meeting: Meeting) -> Date {
        var dates = [meeting.updatedAt, meeting.date]
        dates += meeting.revisions.map(\.date)
        dates += meeting.transcripts.map(\.createdAt)
        if let summary = meeting.summary { dates.append(summary.createdAt) }
        for request in meeting.processingRequests ?? [] {
            dates.append(request.createdAt)
            if let finished = request.outcome?.finishedAt { dates.append(finished) }
            if let heartbeat = request.claim?.heartbeat { dates.append(heartbeat) }
        }
        dates += meeting.tracks.map(\.createdAt)
        return dates.max() ?? meeting.updatedAt
    }

    public static func decide(_ meeting: Meeting, facts: ConversationFacts, context: Context) -> Decision {
        guard let interval = context.age.interval else { return .skip(.off) }
        guard let startsAt = context.startsAt, context.now >= startsAt else { return .skip(.notStarted) }
        guard context.everyDeviceCompresses else { return .skip(.notEveryDevice) }
        if facts.isTrashed { return .skip(.trashed) }
        if facts.isBusy { return .skip(.busy) }
        // What this version can't read on the conversation or a recording might say not to.
        guard meeting.unknownFields.isEmpty, meeting.tracks.allSatisfy({ $0.unknownFields.isEmpty && $0.$source.isKnown }) else {
            return .skip(.newerFields)
        }
        if meeting.status == .failed || meeting.errorMessage != nil { return .skip(.failed) }
        guard meeting.status == .ready, facts.isDone else { return .skip(.notDone) }
        guard !meeting.hasUntranscribedTranscribableAudio, !meeting.unifiedTranscript.isEmpty else { return .skip(.notTranscribed) }
        guard meeting.summary != nil else { return .skip(.noSummary) }
        guard !meeting.speakers.isEmpty else { return .skip(.noSpeakers) }
        // Open on any device: asked for, claimed, or in a mode this version doesn't know.
        if (meeting.processingRequests ?? []).contains(where: \.isOpen) { return .skip(.openRequest) }
        if facts.offersUpgrade { return .skip(.upgradeOffered) }
        guard context.now.timeIntervalSince(lastActivity(of: meeting)) >= interval else { return .skip(.tooRecent) }
        if facts.teachesVoiceProfile { return .skip(.teachesVoiceProfile) }
        // Every recording, compressed or not, is here and whole, and in iCloud when the library syncs.
        for track in meeting.tracks {
            guard let found = facts.tracks[track.id], found.isVerified else { return .skip(.notVerified(track.id)) }
            if let uploaded = found.isUploaded, !uploaded { return .skip(.notUploaded(track.id)) }
        }
        let compressible = meeting.tracks.filter { track in
            track.encoding == nil && facts.tracks[track.id]?.storage == .lossless
        }
        return compressible.isEmpty ? .skip(.nothingToCompress) : .compress(compressible.map(\.id))
    }
}

/// Which device compresses a recording, so two Macs don't both do it (two copies would be made, one thrown away).
public enum RecordingCompressionRunner {
    /// A Mac this device knows of from presence.
    public struct Mac: Equatable, Sendable {
        public var id: String
        public var lastSeen: Date
        /// An earlier identity of a reinstalled Mac (`KnownSyncDevice.supersededBy`).
        public var isSuperseded: Bool
        public init(id: String, lastSeen: Date, isSuperseded: Bool = false) {
            self.id = id; self.lastSeen = lastSeen; self.isSuperseded = isSuperseded
        }
    }

    /// Seen this recently to count as around.
    public static let recent: TimeInterval = 30 * 86_400

    /// The device that compresses `track`: the Mac that recorded it while it's been seen in the last 30 days, otherwise
    /// the Mac with the smallest device ID among those seen in that time (as for compaction). `thisDevice` is a Mac;
    /// `macs` are the others. With no sync, this device.
    public static func runner(for track: RecordingTrack, thisDevice: String, macs: [Mac]?, now: Date) -> String {
        guard let macs else { return thisDevice }
        let around = macs.filter { !$0.isSuperseded && $0.id != thisDevice && now.timeIntervalSince($0.lastSeen) < recent }.map(\.id)
        if let recorder = track.capture?.deviceID, recorder == thisDevice || around.contains(recorder) { return recorder }
        return (around + [thisDevice]).min() ?? thisDevice
    }
}
