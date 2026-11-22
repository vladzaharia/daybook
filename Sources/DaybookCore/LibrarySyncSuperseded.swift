import Darwin
import Foundation

// Superseded originals (docs/icloud-sync.md, "Superseded objects go from iCloud"). Once a Mac replaces a recording with
// a verified compressed copy, the original's object in `Blobs/` is the last lossless copy anywhere, and what any device
// that hasn't caught up, or that holds the same bytes under a new reference, may still need. One Mac deletes it, the one
// that compacts, and only after announcing it:
//
// - The notice. The compacting Mac lists each object it means to delete in a synced record of its own,
//   `Superseded/<SHA-256 of its device ID>.json` (`SupersededRecord`), with the sequence and the epoch it was listed in,
//   and keeps there the log of what it deleted. Every device reads every such record on each full pass; one whose writer
//   isn't an eager Mac seen in the last 30 days is ignored (nothing it lists is waited for or acknowledged).
// - The acknowledgement. Each device says in its presence (`SyncDeviceRecord.superseded`) the latest sequence and the
//   epoch of each notice it has read, and which objects listed there, or possibly gone, its own library still names (a
//   track's file, its Trash included): those it holds. With it, the journal entries it wrote lately
//   (`SyncDeviceRecord.written`, as it stands at each presence write), and when it worked the acknowledgements out on a
//   full pass (`SyncDeviceRecord.supersededAt`). An object goes only once every device seen in the last 30 days lists
//   `superseded-1`, acknowledges a sequence at or after the object's in the notice's epoch without holding it, has done
//   so for a day, and has acknowledged again on a full pass after that day, seen here in the last six hours, every entry
//   it says it wrote applied here.
// - Possibly gone. On every device, a SHA-256 its library knows as a superseded original (`encoding.previousSHA256`),
//   one a record lists, and one a record says was deleted is possibly gone: a file of it is never let go on the strength
//   of the object (`evictAudio`), an on-demand replica never publishes it by reference unless the object is here and no
//   live notice lists it, and a device holding its bytes uploads it again whenever a live conversation names it and
//   iCloud doesn't have it (`repairSupersededObjects`). A deleted one named again is a warning, and its absence never
//   holds a conversation back.
// - The library's word. Before each pass the library says which conversations voice profiles hold, and whether to judge
//   at all (`SupersededJudgment`): under Never, or with settings this version can't read, nothing is listed.
// - The deletion happens after a pass that was applied and acknowledged, under the library's lock, with everything asked
//   again with nothing awaited: the library's conversations, its settings, and the voice profiles' holds as they are
//   then (`deleteSupersededObjects`).

/// A moment by this device's continuous clock (`mach_continuous_time`: it counts through sleep, and nobody can set it)
/// and the boot it counts from (`kern.bootsessionuuid`; empty when it can't be read, and then nothing is compared).
public struct SyncClockMark: Codable, Equatable, Sendable {
    public var boot: String
    public var seconds: TimeInterval

    public init(boot: String, seconds: TimeInterval) { self.boot = boot; self.seconds = seconds }

    public static func current() -> SyncClockMark {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return SyncClockMark(boot: bootSession, seconds: Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1e9)
    }

    static let bootSession: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }()

    /// Seconds since `self` by the continuous clock when `now` is in the same boot; nil across a restart.
    func elapsed(until now: SyncClockMark) -> TimeInterval? {
        guard !boot.isEmpty, boot == now.boot else { return nil }
        return now.seconds - seconds
    }
}

/// A recording this device's library holds as a compressed copy, and the original it replaced.
struct SupersededOriginal: Equatable {
    /// The original's SHA-256 (`TrackEncoding.previousSHA256`): the object that may go.
    var original: String
    /// The copy's SHA-256, and where it is in this library.
    var copy: String
    var copyURL: URL
    var meetingID: UUID
    var trackID: UUID
}

/// A compacting Mac's notice, synced (`Superseded/<SHA-256 of its device ID>.json`): the superseded originals' objects it
/// means to delete, each with the sequence it was listed at, the epoch those sequences count in, and the log of those it
/// deleted, with what justified each. Rewritten as either changes; `sequence` rises with every change to what's listed.
struct SupersededRecord: Codable, Equatable {
    static let currentFormat = "DaybookSuperseded"
    static let directory = "Superseded"
    static let maximumBytes = 8 << 20
    var format = SupersededRecord.currentFormat
    var schemaVersion = 1
    var deviceID: String
    /// Random, chosen when the Mac's own record of its waits begins: an acknowledgement counts only in the epoch it was
    /// given for, so a Mac that lost (or had restored) that record never takes an old acknowledgement for a new list.
    var epoch: String
    var writtenAt: Date
    var sequence: Int
    var objects: [Listed]
    var deleted: [Deletion]

    struct Listed: Codable, Equatable {
        var sha256: String
        var sequence: Int
    }

    /// One object deleted: when, its size, and each recording whose original it was (its conversation, its track, and the
    /// copy that replaced it), every one of which passed every check.
    struct Deletion: Codable, Equatable {
        var sha256: String
        var at: Date
        var size: Int64
        var tracks: [Track]

        struct Track: Codable, Equatable {
            var meetingID: UUID
            var trackID: UUID
            var copy: String
        }
    }

    static func fileName(for deviceID: String) -> String { SyncDigest.sha256(data: Data(deviceID.utf8)) + ".json" }

    /// What a record says besides when it was written.
    func sameContent(as other: SupersededRecord) -> Bool {
        var copy = self
        copy.writtenAt = other.writtenAt
        return copy == other
    }

    /// Another format, a newer version, an oversized file, or a name that isn't a SHA-256 is no record.
    static func decode(_ data: Data) -> SupersededRecord? {
        struct Header: Decodable { var format: String?; var schemaVersion: Int? }
        guard data.count <= maximumBytes, let header = try? JSONDecoder().decode(Header.self, from: data),
              header.format == currentFormat, header.schemaVersion == 1,
              let record = try? JSONDecoder().decode(SupersededRecord.self, from: data), !record.deviceID.isEmpty, !record.epoch.isEmpty,
              record.objects.allSatisfy({ SyncFiles.isHash($0.sha256) }), record.deleted.allSatisfy({ SyncFiles.isHash($0.sha256) }) else { return nil }
        return record
    }
}

/// A device's acknowledgement of a compacting Mac's notice, in its presence (`SyncDeviceRecord.superseded`): the latest
/// sequence it read of that Mac's record and the record's epoch, and the objects listed there, or possibly gone, that its
/// own library still names (it holds those). `holdsAll`: more than an acknowledgement carries, so it holds everything.
struct SupersededAck: Codable, Equatable {
    var device: String
    var epoch: String
    var through: Int
    var holds: [String]
    var holdsAll: Bool?
}

/// The journal entries a device wrote lately, in its presence beside its acknowledgements (`SyncDeviceRecord.written`):
/// its newest settings version, and the events it wrote in the last two days (`complete` false: more than fit, and the
/// Mac waits). The Mac deletes only once it has applied them all, so a voiceprint or a name given anywhere before a
/// device last wrote its presence is known first.
struct SupersededWatermark: Codable, Equatable {
    var settings: String?
    var events: [String]
    var complete: Bool
}

/// What the library says of judging superseded originals, beside which conversations voice profiles hold
/// (`LibrarySyncEngine.holdOriginalsInICloud`): judge them; pause (its settings aren't the library's yet: a wait goes on,
/// nothing comes due); or stop (Never was chosen, or a setting or voiceprint is in a shape this version can't read: the
/// notice lists nothing).
public enum SupersededJudgment: Sendable, Equatable {
    case judge, pause, stop
}

/// A journal entry this device wrote, kept in its checkpoint for its watermark (`SupersededWatermark`).
struct SyncRecentWrite: Codable, Equatable {
    var id: String
    var at: Date
}

/// What the compacting Mac remembers of superseded objects between passes, beside its checkpoint (never synced): its
/// epoch, each object free to go and since when, its object's stamp then, when every device first acknowledged it, the
/// sequence of its notice, the log of deletions, when it last checked and how long it has watched, and each other
/// device's presence as it last saw it. Lost or damaged, a new epoch begins and every wait starts again; the sequence
/// and the log come back from its own synced record.
struct SupersededObjectsState: Codable, Equatable {
    var schemaVersion = 4
    var epoch: String
    var objects: [String: Candidate] = [:]
    var sequence = 0
    var deleted: [String: SupersededRecord.Deletion] = [:]
    var lastCheck: Date?
    var lastClock: SyncClockMark?
    /// Seconds this Mac has watched, check after check: what the continuous clock moved between two checks at most
    /// `supersededCheckGap` apart (a longer gap, asleep or off, isn't counted), within a boot.
    var watched: TimeInterval = 0
    /// The first check after such a gap: every device must be seen since before anything comes due.
    var wokeAt: Date?
    var presence: [String: SeenPresence] = [:]

    init(epoch: String) { self.epoch = epoch }

    struct Candidate: Codable, Equatable {
        /// The copies of every recording here whose original it is.
        var copies: [String]
        var since: Date
        /// `watched` when it became free, and when every device first acknowledged it.
        var sinceWatched: TimeInterval
        var stamp: VerifiedAsset
        /// The notice's sequence when it was listed.
        var sequence: Int
        var acknowledgedSince: Date?
        var acknowledgedWatched: TimeInterval?
    }

    /// Another device's presence as this Mac saw it: when it says it last acknowledged (`SyncDeviceRecord.supersededAt`,
    /// which only its full passes advance), when (by this Mac's clock) this Mac first saw that, and the app
    /// installations seen writing it, with when each was last seen.
    struct SeenPresence: Codable, Equatable {
        var supersededAt: Date?
        var at: Date
        var installations: [String: Date] = [:]
    }
}

/// What the engine knows of superseded objects in this process.
struct SupersededRuntime {
    /// Every compacting Mac's notice as this device last read it, by device ID (this device's own included).
    var records: [String: SupersededRecord] = [:]
    /// The last read got every notice there is; and this Mac's own notice is there but couldn't be read.
    var allRecordsRead = true
    var ownRecordUnread = false
    /// Writers of notices that don't count: not an eager Mac, or not seen in the last 30 days.
    var staleWriters: Set<String> = []
    /// This device's acknowledgements and watermark, for its presence; nil when it can't say what it holds (a
    /// conversation in its library or Trash that can't be read), and then it acknowledges nothing.
    var acks: [SupersededAck]?
    var written: SupersededWatermark?
    /// When this device last worked out its acknowledgements and watermark, on a full pass (`supersededAt`).
    var acksAt: Date?
    /// Since when this Mac's own notice is there but unread, whether it was read but isn't a notice (damaged, too large),
    /// and whether its last write was refused for size: a warning once it lasts.
    var ownRecordUnreadSince: Date?
    var ownRecordDamaged = false
    var noticeTooLarge = false
    /// Each notice as decoded, by path, while its file's stamp holds.
    var recordCache: [String: (stamp: [Double], record: SupersededRecord)] = [:]
    /// What the library says of judging (`holdOriginalsInICloud`).
    var judgment: SupersededJudgment = .judge
    /// SHA-256s this device counts as possibly gone (see the top of this file).
    var possiblyGone: Set<String> = []
    /// Objects the compacting Mac's last pass found due (`runSupersededObjects`), for `deleteSupersededObjects`, with the
    /// journal entries that pass knew (an entry since may name one of them, or a voiceprint).
    var due: [String: SupersededObjectsState.Candidate] = [:]
    var dueJournal: Set<String> = []
    /// Of those, what the pass applied (the entries of a conversation whose own publication failed weren't).
    var dueApplied: Set<String> = []
    /// The epoch a new record of waits begins with, in this process.
    var freshEpoch = UUID().uuidString
    /// What each Trash conversation's files said, by path, while its stamp holds (`digestsNamedHere`).
    var trashDigests: [String: (stamp: [Double], digests: [String])] = [:]
}

extension LibrarySyncEngine {
    /// The presence feature saying a device reads compacting Macs' notices of superseded objects, acknowledges them, and
    /// treats what they list as possibly gone. An object goes only while every device seen in the last 30 days lists it.
    public static let supersededFeature = "superseded-1"

    /// How long an original's object must have been free to go and acknowledged by every device, each without a break,
    /// before it goes: time for an edit or presence written anywhere just before to reach iCloud and be seen.
    static let supersededWait: TimeInterval = 24 * 60 * 60
    /// A wall clock that disagrees with the continuous clock by more than this since the last check jumped: every wait
    /// starts again, as on a restart. A gap of more than `supersededCheckGap` between checks (asleep, off, or not checking)
    /// isn't counted as watched, and every device must be seen again after it: a day is a day watched.
    static let supersededClockTolerance: TimeInterval = 60 * 60
    static let supersededCheckGap: TimeInterval = 12 * 60 * 60
    /// At the deletion, every device must have acknowledged on a full pass this Mac saw at most this long ago.
    static let supersededRecentAck: TimeInterval = 6 * 60 * 60
    /// Log entries older than this keep only the object and when it went.
    static let supersededLogDetail: TimeInterval = 90 * 24 * 60 * 60
    /// How far back a device's watermark lists the events it wrote, and how many it carries.
    static let supersededWatermarkWindow: TimeInterval = 2 * 24 * 60 * 60
    static let supersededWatermarkEvents = 200
    /// How many objects an acknowledgement holds by name (beyond that it holds everything), so presence stays small.
    static let supersededHoldsLimit = 300

    // MARK: Every device

    /// Reads every compacting Mac's notice (`Superseded/`). One that isn't downloaded is asked for, and the one read
    /// before is kept meanwhile; one in a form this version can't read says nothing. A notice whose writer isn't an eager
    /// Mac seen in the last 30 days doesn't count (`staleWriters`).
    func readSupersededRecords(now: Date = Date()) {
        supersededRuntime.allRecordsRead = true
        supersededRuntime.ownRecordUnread = false
        let directory = remoteRoot.appendingPathComponent(SupersededRecord.directory, isDirectory: true)
        guard (try? SyncFiles.noSymlinks(directory, below: remoteRoot)) != nil else { supersededRuntime.allRecordsRead = false; return }
        guard fm.fileExists(atPath: directory.path) else {
            supersededRuntime.records = [:]; supersededRuntime.staleWriters = []
            supersededRuntime.ownRecordUnreadSince = nil; supersededRuntime.ownRecordDamaged = false
            return
        }
        guard let urls = try? journalFiles(in: SupersededRecord.directory) else { supersededRuntime.allRecordsRead = false; return }
        let ownName = SupersededRecord.fileName(for: deviceID)
        var seen = Set<String>(), ownUnread = false, ownDamaged = false
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = values?.fileSize ?? 0
            let stamp = [values?.contentModificationDate?.timeIntervalSince1970 ?? -1, Double(size)]
            if SyncFiles.itemState(url) == .local, stamp[0] >= 0, let cached = supersededRuntime.recordCache[url.path], cached.stamp == stamp {
                supersededRuntime.records[cached.record.deviceID] = cached.record
                seen.insert(cached.record.deviceID)
                continue
            }
            let bytes = size <= SupersededRecord.maximumBytes ? try? SyncFiles.read(url, below: remoteRoot, cloud: cloud) : nil
            guard let bytes, let record = SupersededRecord.decode(bytes), url.lastPathComponent == SupersededRecord.fileName(for: record.deviceID) else {
                supersededRuntime.allRecordsRead = false
                if url.lastPathComponent == ownName {
                    ownUnread = true
                    // Read, or too large to: not a download still on its way.
                    ownDamaged = bytes != nil || size > SupersededRecord.maximumBytes
                }
                if let known = supersededRuntime.records.first(where: { SupersededRecord.fileName(for: $0.key) == url.lastPathComponent }) { seen.insert(known.key) }
                continue
            }
            supersededRuntime.records[record.deviceID] = record
            supersededRuntime.recordCache[url.path] = (stamp, record)
            seen.insert(record.deviceID)
        }
        supersededRuntime.records = supersededRuntime.records.filter { seen.contains($0.key) }
        supersededRuntime.ownRecordUnread = ownUnread
        supersededRuntime.ownRecordDamaged = ownDamaged
        supersededRuntime.ownRecordUnreadSince = ownUnread ? (supersededRuntime.ownRecordUnreadSince ?? compactionClock()) : nil
        // Who wrote them: presence that can't be read says nothing, and every notice counts meanwhile. An earlier identity
        // of a reinstalled Mac never deletes again.
        if supersededRuntime.records.keys.contains(where: { $0 != deviceID }), let presence = allPresence(now: now, includingRetired: true) {
            let earlier = Set(((try? knownDevices(now: now)) ?? []).filter { $0.supersededBy != nil }.map(\.id))
            supersededRuntime.staleWriters = Set(supersededRuntime.records.keys.filter { writer in
                guard writer != deviceID else { return false }
                guard let record = presence.first(where: { $0.deviceID == writer }), !earlier.contains(writer) else { return true }
                return record.deviceClass != .mac || record.audioPolicy != SyncAudioPolicy.eager.rawValue
                    || now.timeIntervalSince(record.lastSeen) >= Self.recentDevice
            })
        } else {
            supersededRuntime.staleWriters = []
        }
    }

    /// The notices that count, other Macs': their writers are eager Macs seen in the last 30 days.
    private var liveNotices: [SupersededRecord] {
        supersededRuntime.records.values.filter { $0.deviceID != deviceID && !supersededRuntime.staleWriters.contains($0.deviceID) }
            .sorted { $0.deviceID < $1.deviceID }
    }

    /// What every notice lists or logs as deleted (a stale one's too), and what this library knows as superseded
    /// originals. On a pass that couldn't read every notice, nothing leaves the set.
    func notePossiblyGone(_ meetings: [Meeting]) {
        var gone = Set<String>()
        for record in supersededRuntime.records.values {
            gone.formUnion(record.objects.map(\.sha256))
            gone.formUnion(record.deleted.map(\.sha256))
        }
        for meeting in meetings {
            for track in meeting.tracks {
                guard let previous = track.encoding?.previousSHA256, SyncFiles.isHash(previous), previous != track.sha256 else { continue }
                gone.insert(previous)
            }
        }
        if !supersededRuntime.allRecordsRead {
            gone.formUnion(supersededRuntime.possiblyGone)
            if audioPolicy == .onDemand { gone.formUnion(audioIndex().possiblyGone ?? []) }
        }
        supersededRuntime.possiblyGone = gone
        if audioPolicy == .onDemand {
            let sorted = gone.sorted()
            if audioIndex().possiblyGone != sorted { updateAudioIndex { $0.possiblyGone = sorted } }
        }
    }

    /// Whether a notice that counts lists this object: it may go any time.
    func supersededDeletionListed(_ sha256: String) -> Bool {
        supersededRuntime.records.values.contains { record in
            !supersededRuntime.staleWriters.contains(record.deviceID) && record.objects.contains { $0.sha256 == sha256 }
        }
    }

    /// What every notice says was deleted.
    var supersededDeletions: Set<String> {
        Set(supersededRuntime.records.values.flatMap { $0.deleted.map(\.sha256) })
    }

    /// An object a notice says was deleted, absent from the sync folder and from every delivery: nothing is waited for
    /// it (`hydrate`), and it's published by reference as it stands.
    func deletedAndAbsent(_ sha256: String) -> Bool {
        supersededDeletions.contains(sha256) && !hasRemoteObject(sha256) && courierObject(sha256) == nil
    }

    /// Every SHA-256 a track names as its file in the library's conversations (and any conversation folder here the
    /// library didn't supply) and in the Trash here; nil when one of them can't be read (it may name anything), or a
    /// folder can't be listed.
    func digestsNamedHere(_ meetings: [Meeting]) -> Set<String>? {
        var named = Set<String>()
        for meeting in meetings { for track in meeting.tracks where SyncFiles.isHash(track.sha256) { named.insert(track.sha256) } }
        let supplied = Set(meetings.map(\.id))
        for top in ["Meetings", "Trash"] {
            let root = localRoot.appendingPathComponent(top, isDirectory: true)
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
            for name in names {
                guard let id = UUID(uuidString: name), top == "Trash" || !supplied.contains(id) else { continue }
                let folder = root.appendingPathComponent(name, isDirectory: true)
                for file in ["meeting.json", "meeting.recovery.json"] {
                    let url = folder.appendingPathComponent(file)
                    guard fm.fileExists(atPath: url.path) else { continue }
                    guard let digests = trackDigests(url) else { return nil }
                    named.formUnion(digests)
                }
            }
        }
        return named
    }

    /// The SHA-256s a saved conversation's tracks name, read once while the file's stamp holds; nil when it can't be read.
    private func trackDigests(_ url: URL) -> [String]? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = [values?.contentModificationDate?.timeIntervalSince1970 ?? -1, Double(values?.fileSize ?? -1)]
        if let known = supersededRuntime.trashDigests[url.path], known.stamp == stamp, stamp[0] >= 0 { return known.digests }
        guard let data = try? Data(contentsOf: url), let meeting = try? JSONDecoder().decode(Meeting.self, from: data) else { return nil }
        let digests = meeting.tracks.map(\.sha256).filter(SyncFiles.isHash)
        supersededRuntime.trashDigests[url.path] = (stamp, digests)
        return digests
    }

    /// This device's acknowledgements of other Macs' notices that count, for its presence: through each one's sequence in
    /// its epoch, holding what this library still names of what it lists or of what's possibly gone, and the entries this
    /// device wrote lately. Nothing while what it names can't be told.
    func noteSupersededAcks(_ meetings: [Meeting], now: Date = Date(), at stamp: Date = Date()) {
        // A notice that lists nothing is acknowledged too: what this device holds keeps its writer from listing it again.
        let notices = liveNotices
        guard !notices.isEmpty, let named = digestsNamedHere(meetings) else {
            supersededRuntime.acks = nil; supersededRuntime.written = nil; supersededRuntime.acksAt = nil; return
        }
        let holds = notices.map { record in named.intersection(Set(record.objects.map(\.sha256)).union(supersededRuntime.possiblyGone)).sorted() }
        // Held by name up to a limit across every acknowledgement; beyond it, everything is held.
        let holdsAll = holds.reduce(0) { $0 + $1.count } > Self.supersededHoldsLimit
        let acks = zip(notices, holds).map { record, held in
            holdsAll ? SupersededAck(device: record.deviceID, epoch: record.epoch, through: record.sequence, holds: [], holdsAll: true)
                : SupersededAck(device: record.deviceID, epoch: record.epoch, through: record.sequence, holds: held)
        }
        let written = supersededWatermark(now: now)
        // Advanced only here, on a full pass: when what it says changed, or every so often, so a write of presence between
        // full passes (a timer, a settings-only pass) never passes for one.
        if acks != supersededRuntime.acks || written != supersededRuntime.written || supersededRuntime.acksAt == nil
            || abs(stamp.timeIntervalSince(supersededRuntime.acksAt!)) >= presenceRefreshInterval {
            supersededRuntime.acksAt = stamp
        }
        supersededRuntime.acks = acks
        supersededRuntime.written = written
    }

    /// This device's watermark as it stands (`SupersededWatermark`), worked out again for every presence write: its newest
    /// settings version, and the events it wrote in the last two days.
    func supersededWatermark(now: Date = Date()) -> SupersededWatermark {
        let events = (state.recentWrites ?? []).filter { now.timeIntervalSince($0.at) < Self.supersededWatermarkWindow }.map(\.id)
        let complete = events.count <= Self.supersededWatermarkEvents
        return SupersededWatermark(settings: state.lastSettingsWrite,
                                   events: complete ? events : Array(events.suffix(Self.supersededWatermarkEvents)), complete: complete)
    }

    /// What a sync pass on the compacting Mac says of its own notice: there but unreadable (damaged, too large, or not
    /// downloaded for an hour), or too large to write. Nothing is listed or deleted meanwhile.
    func supersededWarnings(now: Date) -> [String] {
        if supersededRuntime.ownRecordDamaged || supersededRuntime.ownRecordUnreadSince.map({ now.timeIntervalSince($0) >= 60 * 60 }) == true {
            return [SyncWarningWords.compose(SyncWarningWords.originalsNoticeStuck, details: supersededRuntime.ownRecordDamaged
                ? "This Mac’s notice of them in iCloud is damaged or too large to read." : "This Mac’s notice of them in iCloud hasn’t downloaded.")]
        }
        if supersededRuntime.noticeTooLarge {
            return [SyncWarningWords.compose(SyncWarningWords.originalsNoticeStuck, details: "This Mac’s notice of them is too large to write.")]
        }
        return []
    }

    /// Remembers a journal entry this device wrote, for its watermark: the newest settings version, and the events of the
    /// last week (at most 500).
    func noteOwnWrite(_ id: String, directory: String, at now: Date = Date()) {
        if directory == "Metadata" { state.lastSettingsWrite = id; return }
        guard directory == "Events" else { return }
        var writes = (state.recentWrites ?? []).filter { $0.id != id && now.timeIntervalSince($0.at) < 7 * 24 * 60 * 60 }
        writes.append(SyncRecentWrite(id: id, at: now))
        state.recentWrites = Array(writes.suffix(500))
    }

    /// A device holding the bytes of an object a live conversation names, which iCloud doesn't have, uploads it again:
    /// the track's own file, or an original a compressed copy replaced that's still here. Only for objects that may be
    /// gone (`possiblyGone`), in a plaintext library. One a notice says was deleted that's still missing is a warning.
    func repairSupersededObjects(_ meetings: [Meeting], into pass: inout PassState) {
        guard sealing == nil, waitingForKey == nil, !syncedSealedLibraryHere else { return }
        let deletions = supersededDeletions
        let watched = supersededRuntime.possiblyGone.union(deletions)
        guard !watched.isEmpty else { return }
        let live = meetings.filter { !pass.deletes.contains($0.id) }
        var named = Set<String>()
        for meeting in live { for track in meeting.tracks where watched.contains(track.sha256) { named.insert(track.sha256) } }
        // What arrived in this pass too, applied or held back.
        for (id, assets) in pass.liveAssets where !pass.deletes.contains(id) {
            for asset in assets where watched.contains(asset.sha256) && !Self.isVoiceClip(asset) { named.insert(asset.sha256) }
        }
        for sha256 in named.sorted() where !hasRemoteObject(sha256) {
            if let (source, relativePath) = heldBytes(of: sha256, in: meetings) {
                do {
                    try upload(SyncAsset(relativePath: relativePath, sha256: sha256), from: source)
                    Self.log.info("Uploaded a recording's original again: \(String(sha256.prefix(12)), privacy: .public)")
                } catch {
                    Self.log.error("Couldn't upload a recording's original again: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard deletions.contains(sha256) else { continue }
            let again = hasRemoteObject(sha256)
            pass.warnings.append(SyncWarningWords.compose(SyncWarningWords.deletedOriginalNeeded,
                details: again ? "Uploaded again from this device (\(sha256.prefix(12)))." : "No copy of it is on this device (\(sha256.prefix(12)))."))
        }
    }

    /// A verified file here with these bytes, and the library path to name it by: a track's file, or the original a
    /// compressed copy replaced while it's still here.
    private func heldBytes(of sha256: String, in meetings: [Meeting]) -> (URL, String)? {
        for meeting in meetings {
            let directory = localRoot.appendingPathComponent("Meetings/\(meeting.id.uuidString)", isDirectory: true)
            for track in meeting.tracks {
                var paths: [String] = []
                if track.sha256 == sha256 { paths.append(track.relativePath) }
                if let encoding = track.encoding, encoding.previousSHA256 == sha256 { paths.append(encoding.previousRelativePath) }
                for path in paths where path.hasPrefix("Originals/") {
                    guard let url = try? LocalFiles.relativeURL(path, in: directory), (try? SyncFiles.noSymlinks(url, below: localRoot)) != nil,
                          (try? verified(url, digest: sha256)) == true else { continue }
                    return (url, path)
                }
            }
        }
        return nil
    }

    /// In iCloud Drive, only the provider's own yes is "uploaded" (`isObjectUploaded`); elsewhere, a file that's there is.
    /// What every check that lets something go on the strength of iCloud's copy asks.
    func uploadedStrictly(_ url: URL) -> Bool {
        guard SyncFiles.itemState(url) != .absent else { return false }
        if cloud.isICloudFolder(remoteRoot) { return cloud.uploadState(url) == true }
        return cloud.isUploaded(url)
    }

    // MARK: The compacting Mac

    /// This engine may delete superseded objects (the compacting Mac of a plaintext library), so the library tells it
    /// which conversations' originals voice profiles still need (`holdOriginalsInICloud`).
    public var mayDeleteSupersededObjects: Bool {
        compactionPolicy != nil && audioPolicy == .eager && device?.deviceClass == .mac && sealing == nil && waitingForKey == nil
    }

    /// The last pass found an object due: `deleteSupersededObjects` may delete it.
    public var hasSupersededObjectsDue: Bool { !supersededRuntime.due.isEmpty }

    /// The pass that found objects due wasn't applied: nothing goes on it.
    public func discardSupersededObjectsDue() { supersededRuntime.due = [:] }

    private var supersededStateURL: URL? {
        libraryID.map { localRoot.appendingPathComponent("Sync/superseded-\($0.uuidString).json") }
    }

    private var ownSupersededRecordURL: URL {
        remoteRoot.appendingPathComponent("\(SupersededRecord.directory)/\(SupersededRecord.fileName(for: deviceID))")
    }

    /// What's remembered here, reconciled with this Mac's own notice as read: in the same epoch, the sequence and the log
    /// come back from it, and a wait the notice doesn't list at the same sequence (a record restored from a backup) starts
    /// again; in another epoch (the record lost, or restored from elsewhere), or with no notice where one was written, a
    /// new epoch begins with no wait.
    func supersededState() -> SupersededObjectsState {
        var state = SupersededObjectsState(epoch: supersededRuntime.freshEpoch)
        if let url = supersededStateURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(SupersededObjectsState.self, from: data), saved.schemaVersion == 4 { state = saved }
        if let own = supersededRuntime.records[deviceID] {
            if own.epoch == state.epoch {
                let listed = Dictionary(own.objects.map { ($0.sha256, $0.sequence) }, uniquingKeysWith: { a, _ in a })
                state.objects = state.objects.filter { listed[$0.key] == $0.value.sequence }
            } else {
                state.objects = [:]
                if state.epoch != supersededRuntime.freshEpoch { state.epoch = supersededRuntime.freshEpoch }
            }
            state.sequence = max(state.sequence, own.sequence)
            for deletion in own.deleted where state.deleted[deletion.sha256] == nil { state.deleted[deletion.sha256] = deletion }
        } else if state.sequence > 0 || !state.deleted.isEmpty {
            // No notice of its own, though one was written (what's remembered here restored, or moved to a Mac whose iCloud
            // is still listing): a new epoch, so no acknowledgement of what that notice said counts; the log stays.
            state.objects = [:]
            if state.epoch == supersededRuntime.freshEpoch { supersededRuntime.freshEpoch = UUID().uuidString }
            state.epoch = supersededRuntime.freshEpoch
        }
        return state
    }

    private func saveSupersededState(_ state: SupersededObjectsState) throws {
        guard let url = supersededStateURL else { return }
        try SyncFiles.noSymlinks(url, below: localRoot)
        try DurableFiles.write(SyncEncoding.data(state), to: url)
    }

    /// Writes this Mac's notice when what it says changed. True once the notice in the sync folder says what `state`
    /// does and iCloud has it.
    @discardableResult
    func publishSupersededRecord(_ state: SupersededObjectsState, now: Date) -> Bool {
        // A deletion's details are kept for 90 days; after that, the object and when it went.
        let deleted = state.deleted.values.map { deletion -> SupersededRecord.Deletion in
            var kept = deletion
            if now.timeIntervalSince(deletion.at) >= Self.supersededLogDetail { kept.tracks = [] }
            return kept
        }
        let record = SupersededRecord(deviceID: deviceID, epoch: state.epoch, writtenAt: now, sequence: state.sequence,
                                      objects: state.objects.map { .init(sha256: $0.key, sequence: $0.value.sequence) }.sorted { $0.sha256 < $1.sha256 },
                                      deleted: deleted.sorted { $0.sha256 < $1.sha256 })
        let url = ownSupersededRecordURL
        let there = SyncFiles.itemState(url) != .absent
        if there, let known = supersededRuntime.records[deviceID], known.sameContent(as: record) { return uploadedStrictly(url) }
        // Nothing to say, and nothing said before.
        if record.objects.isEmpty, record.deleted.isEmpty, !there { return true }
        do {
            let directory = url.deletingLastPathComponent()
            try SyncFiles.noSymlinks(directory, below: remoteRoot)
            try LocalFiles.directory(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(record)
            // Never more than any device reads: the notice stays as it was (nothing new is listed or goes), and the sync
            // pass says so.
            supersededRuntime.noticeTooLarge = bytes.count > SupersededRecord.maximumBytes
            guard !supersededRuntime.noticeTooLarge else {
                Self.log.error("The notice of superseded originals is too large to write (\(bytes.count, privacy: .public) bytes)")
                return false
            }
            try SyncFiles.coordinateWrite(url, below: remoteRoot) { try LocalFiles.atomicWrite(bytes, to: $0) }
            supersededRuntime.records[deviceID] = record
        } catch {
            Self.log.error("Couldn't write the notice of superseded originals: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    /// This Mac can't delete now (it isn't the one that compacts, the library is encrypted, or a guard says nothing may
    /// go): its notice lists nothing, so nobody waits for it (its log stays). Never over a notice of its own it couldn't read.
    func withdrawSupersededNotice(now: Date) {
        supersededRuntime.due = [:]
        guard !supersededRuntime.ownRecordUnread, let own = supersededRuntime.records[deviceID], !own.objects.isEmpty else { return }
        var state = supersededState()
        state.objects = [:]
        state.sequence += 1
        try? saveSupersededState(state)
        publishSupersededRecord(state, now: now)
    }

    /// On a pass that can't judge what's free (it didn't read the whole journal), what certainly isn't free leaves the
    /// notice: what another device holds, what a track here names, what no live recording here was replaced from, what
    /// voice profiles hold. Removing is always safe; nothing is added or comes due.
    func trimSupersededNotice(_ input: CompactionInput, others: [SyncDeviceRecord]?, now: Date) {
        supersededRuntime.due = [:]
        guard sealing == nil, waitingForKey == nil, supersededRuntime.judgment != .stop else { withdrawSupersededNotice(now: now); return }
        guard supersededStateURL != nil, !supersededRuntime.ownRecordUnread,
              let own = supersededRuntime.records[deviceID], !own.objects.isEmpty else { return }
        var state = supersededState()
        guard let facts = supersededFacts(input.meetings, deleted: input.deleted) else {
            if !state.objects.isEmpty { state.objects = [:]; state.sequence += 1; try? saveSupersededState(state); publishSupersededRecord(state, now: now) }
            return
        }
        let acks = (others ?? []).flatMap { ($0.superseded ?? []).filter { $0.device == deviceID } }
        let holdsAll = acks.contains { $0.holdsAll == true }, held = Set(acks.flatMap(\.holds))
        let voice = originalsHeldForVoice
        let before = state.objects.count
        state.objects = state.objects.filter { original, _ in
            guard let tracks = facts.byOriginal[original], !tracks.isEmpty, !holdsAll, !held.contains(original), !facts.held.contains(original) else { return false }
            return tracks.allSatisfy { copy in voice.map { !$0.held.contains(copy.meetingID) } ?? false }
        }
        guard state.objects.count != before else { return }
        state.sequence += 1
        try? saveSupersededState(state)
        publishSupersededRecord(state, now: now)
    }

    /// How this check follows the last, by the continuous clock (which counts sleep): within `supersededCheckGap`, the
    /// seconds watched; a longer gap (asleep, off, or not checking) isn't counted; a restart, or a wall clock that moved
    /// more than an hour otherwise, starts every wait again.
    enum SupersededClockStep: Equatable { case watched(TimeInterval), gap, restart }

    private func supersededClockStep(_ state: SupersededObjectsState, now: Date, clock: SyncClockMark) -> SupersededClockStep {
        guard let last = state.lastCheck, let lastClock = state.lastClock else { return .gap }
        guard let elapsed = lastClock.elapsed(until: clock), elapsed >= 0,
              abs(now.timeIntervalSince(last) - elapsed) <= Self.supersededClockTolerance else { return .restart }
        return elapsed <= Self.supersededCheckGap ? .watched(elapsed) : .gap
    }

    /// A day has passed since `since` by the wall clock, and a day watched (`SupersededObjectsState.watched`) since `mark`.
    private static func supersededWaitPassed(since: Date, watched mark: TimeInterval, now: Date, state: SupersededObjectsState) -> Bool {
        now.timeIntervalSince(since) >= supersededWait && state.watched - mark >= supersededWait
    }

    /// The live conversations' recordings held as compressed copies, by the original they replaced, and every SHA-256 a
    /// track names as its file here (the Trash included); nil when a conversation here can't be read.
    func supersededFacts(_ meetings: [Meeting], deleted: Set<UUID>) -> (byOriginal: [String: [SupersededOriginal]], held: Set<String>)? {
        guard let held = digestsNamedHere(meetings) else { return nil }
        var byOriginal: [String: [SupersededOriginal]] = [:]
        for meeting in meetings where !deleted.contains(meeting.id) {
            let directory = localRoot.appendingPathComponent("Meetings/\(meeting.id.uuidString)", isDirectory: true)
            for track in meeting.tracks {
                guard let encoding = track.encoding, SyncFiles.isHash(encoding.previousSHA256), SyncFiles.isHash(track.sha256),
                      encoding.previousSHA256 != track.sha256, let url = try? LocalFiles.relativeURL(track.relativePath, in: directory) else { continue }
                byOriginal[encoding.previousSHA256, default: []].append(SupersededOriginal(original: encoding.previousSHA256, copy: track.sha256,
                                                                                         copyURL: url, meetingID: meeting.id, trackID: track.id))
            }
        }
        return (byOriginal, held)
    }

    /// A copy that stands for its original: its object in iCloud and uploaded (iCloud's own yes), and its file here with
    /// its SHA-256.
    private func copyStands(_ copy: SupersededOriginal) -> Bool {
        let object = blobURL(copy.copy)
        return SyncFiles.itemState(object) != .absent && uploadedStrictly(object) && (try? verified(copy.copyURL, digest: copy.copy)) == true
    }

    /// The other devices that must take part: every one seen in the last 30 days by what its presence says, and every one
    /// whose presence this Mac saw change in that time (a device whose clock is more than a month behind); nil while one
    /// can't be read.
    private func supersededParticipants(_ recent: [SyncDeviceRecord], now: Date) -> [SyncDeviceRecord]? {
        guard let all = allPresence(now: now, includingRetired: true) else { return nil }
        var result = recent
        let sightings = state.presenceSightings ?? [:]
        for record in all where !result.contains(where: { $0.deviceID == record.deviceID }) {
            if let changed = sightings[record.deviceID]?.changed, changed <= now, now.timeIntervalSince(changed) < Self.recentDevice { result.append(record) }
        }
        return result
    }

    /// Notes each device's presence as this Mac sees it now: a new date it says it last acknowledged (`supersededAt`, which
    /// only its full passes advance; a presence written in between doesn't count) is a new acknowledgement, seen now; and
    /// the app installations writing it.
    private func noteParticipants(_ others: [SyncDeviceRecord], in state: inout SupersededObjectsState, now: Date) {
        for record in others {
            var seen = state.presence[record.deviceID] ?? .init(supersededAt: record.supersededAt, at: now)
            if seen.supersededAt != record.supersededAt { seen.supersededAt = record.supersededAt; seen.at = now }
            if let installation = record.appInstallation { seen.installations[installation] = now }
            seen.installations = seen.installations.filter { now.timeIntervalSince($0.value) < Self.recentDevice }
            state.presence[record.deviceID] = seen
        }
    }

    /// Whether every device acknowledges this object: a sequence of this Mac's notice at or after the one it was listed
    /// at, in this epoch, without holding it; and not a device two apps write the presence of (one may hold what the
    /// other's acknowledgement doesn't say).
    private func supersededAcknowledged(_ sha256: String, sequence: Int, others: [SyncDeviceRecord], state: SupersededObjectsState) -> Bool {
        others.allSatisfy { record in
            (state.presence[record.deviceID]?.installations.count ?? 0) <= 1
                && (record.superseded ?? []).contains { ack in
                    ack.device == deviceID && ack.epoch == state.epoch && ack.through >= sequence && ack.holdsAll != true && !ack.holds.contains(sha256)
                }
        }
    }

    /// Whether every device acknowledged again on a full pass a day after the object was acknowledged, which this Mac
    /// saw in the last six hours, and after the last gap in its checks (not on the first check after it, either), and every
    /// entry its watermark names is applied here (`applied`).
    private func supersededCaughtUp(_ candidate: SupersededObjectsState.Candidate, others: [SyncDeviceRecord], state: SupersededObjectsState,
                                    applied: Set<String>, now: Date) -> Bool {
        guard let acknowledged = candidate.acknowledgedSince else { return false }
        if let woke = state.wokeAt, woke >= now { return false }
        return others.allSatisfy { record in
            guard let seen = state.presence[record.deviceID], seen.at <= now, seen.at >= acknowledged.addingTimeInterval(Self.supersededWait),
                  now.timeIntervalSince(seen.at) <= Self.supersededRecentAck, state.wokeAt.map({ seen.at > $0 }) ?? true,
                  let written = record.written, written.complete else { return false }
            return (written.events + [written.settings].compactMap { $0 }).allSatisfy(applied.contains)
        }
    }

    /// Every device seen lately can take part: it knows compressed recordings, compacted libraries, and notices.
    private func everyRecentDeviceReadsNotices(_ others: [SyncDeviceRecord]) -> Bool {
        others.allSatisfy { record in
            let features = record.features ?? []
            return features.contains(Self.compressionFeature) && features.contains(Self.compactionFeature) && features.contains(Self.supersededFeature)
        }
    }

    /// On the compacting Mac, after every pass that read the whole journal (compaction's guards: not while every other
    /// device is away, not with a clock that looks ahead), whether or not compaction itself runs then. Works out which
    /// superseded originals' objects are free to go, lists them in its notice, follows each one's day, and its
    /// acknowledgements', and leaves those due for `deleteSupersededObjects`. Free to go means: no journal entry still
    /// here names it (every one was pruned, which needed every device seen in the last 30 days to acknowledge a state
    /// after the replacement); no track here, the Trash included, names it as its file (and every conversation here can
    /// be read); no device holds it; every live recording whose original it is has its copy in iCloud, uploaded, and here
    /// verified, in a conversation the library judged and whose originals voice profiles don't hold
    /// (`holdOriginalsInICloud`); and its object is there. Nothing is listed where the library says to stop (Never, or
    /// settings this version can't read) or the library is encrypted. Nothing is judged in a pass that brought new
    /// settings, while the library's settings aren't current, or while a compaction commit is still on its way to iCloud: a
    /// wait already begun goes on, but nothing comes due then. Nor in a pass whose notice isn't in iCloud as it stands.
    /// An original of a conversation the pass changed, or couldn't bring up to date, starts its wait again. Due means free,
    /// with the stamp it had when it became free, for a day, acknowledged by every device for a day, both by the wall
    /// clock and watched (a gap in the checks isn't counted), every device having acknowledged again since on a full pass
    /// seen in the last six hours and after the last gap, with what it wrote applied.
    func runSupersededObjects(_ input: CompactionInput, others recent: [SyncDeviceRecord], now: Date) {
        supersededRuntime.due = [:]
        guard sealing == nil, waitingForKey == nil, supersededRuntime.judgment != .stop else { withdrawSupersededNotice(now: now); return }
        guard supersededStateURL != nil else { return }
        // Never over a notice of its own this Mac couldn't read: what it says (the epoch, the sequence, the log) would be lost.
        guard !supersededRuntime.ownRecordUnread else { return }
        guard let others = supersededParticipants(recent, now: now) else { trimSupersededNotice(input, others: recent, now: now); return }
        var state = supersededState()
        let before = state
        let clock = continuousClock()
        let step = supersededClockStep(state, now: now, clock: clock)
        if case .watched(let seconds) = step { state.watched += seconds } else { state.wokeAt = now }
        state.lastCheck = now; state.lastClock = clock
        noteParticipants(others, in: &state, now: now)
        var free: [String: (copies: [String], stamp: VerifiedAsset)] = [:]
        // What the pass can't judge (the library's word on voice profiles was given before it, without what it brought),
        // and what starts its wait again.
        var unjudged = Set<String>(), restarted = Set<String>()
        // So is a pass with a compaction commit still on its way to iCloud (a device finding an object gone must find what
        // pruned its history): pruning only frees more, so every wait goes on.
        let paused = input.settingsChanged || supersededRuntime.judgment == .pause
            || !compactionRuntime.records.values.filter(\.record.isCommit).allSatisfy({ uploadedStrictly($0.url) })
        if everyRecentDeviceReadsNotices(others), let facts = supersededFacts(input.meetings, deleted: input.deleted) {
            let pruned = compactionRuntime.prunedIDs
            let named = Set(input.events.filter { !pruned.contains($0.key) }.values.flatMap { $0.assets.map(\.sha256) })
            // What another device holds isn't free either, so its notice no longer lists it and that device may publish
            // it by reference; once it does, the journal names it.
            let acks = others.flatMap { ($0.superseded ?? []).filter { $0.device == deviceID } }
            let holdsAll = acks.contains { $0.holdsAll == true }, heldElsewhere = Set(acks.flatMap(\.holds))
            let voice = originalsHeldForVoice
            for (original, tracks) in facts.byOriginal {
                // A name given in it, say, isn't a voiceprint until the library has seen it: it starts again, judged or not.
                if tracks.contains(where: { input.changed.contains($0.meetingID) || input.unapplied.contains($0.meetingID) }) {
                    restarted.insert(original)
                    continue
                }
                if paused { unjudged.insert(original); continue }
                guard !named.contains(original), !facts.held.contains(original), !holdsAll, !heldElsewhere.contains(original),
                      tracks.allSatisfy({ copy in voice.map { !$0.held.contains(copy.meetingID) && $0.judged.contains(copy.meetingID) } ?? false }),
                      tracks.allSatisfy(copyStands), let stamp = objectStamp(blobURL(original), digest: original) else { continue }
                free[original] = (Set(tracks.map(\.copy)).sorted(), stamp)
            }
        }
        // What isn't free any more forgets its wait; what's new is listed in the notice at a new sequence. What the pass
        // couldn't judge stays as it was; what starts again stays listed.
        let kept = Set(state.objects.keys).intersection(unjudged.union(restarted))
        let added = Set(free.keys).subtracting(state.objects.keys), removed = Set(state.objects.keys).subtracting(free.keys).subtracting(kept)
        if !added.isEmpty || !removed.isEmpty { state.sequence += 1 }
        for key in removed { state.objects[key] = nil }
        let watched = state.watched
        func startAgain(_ original: String) {
            state.objects[original]?.since = now; state.objects[original]?.sinceWatched = watched
            state.objects[original]?.acknowledgedSince = nil; state.objects[original]?.acknowledgedWatched = nil
        }
        for (original, found) in free {
            if let known = state.objects[original] {
                // A copy that changed, an object written again since (someone's upload), or a clock that jumped: it starts again.
                if known.copies != found.copies || known.stamp != found.stamp || known.since > now || step == .restart {
                    state.objects[original]?.copies = found.copies; state.objects[original]?.stamp = found.stamp
                    startAgain(original)
                }
            } else {
                state.objects[original] = .init(copies: found.copies, since: now, sinceWatched: watched, stamp: found.stamp, sequence: state.sequence)
            }
        }
        for original in kept where restarted.contains(original) || step == .restart { startAgain(original) }
        // An acknowledgement starts only with the notice in iCloud, and ends only when it stops holding (a device
        // acknowledges a listing only once it has read the notice from iCloud).
        let noticed = publishSupersededRecord(state, now: now)
        for (original, var candidate) in state.objects {
            let starts = candidate.acknowledgedSince == nil || candidate.acknowledgedSince! > now
            if !supersededAcknowledged(original, sequence: candidate.sequence, others: others, state: state) || (starts && !noticed) {
                candidate.acknowledgedSince = nil; candidate.acknowledgedWatched = nil
            } else if starts {
                candidate.acknowledgedSince = now; candidate.acknowledgedWatched = watched
            }
            state.objects[original] = candidate
        }
        if state != before {
            do { try saveSupersededState(state) } catch {
                Self.log.error("Couldn't save superseded originals' waits: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        // What the pass read, and of that what it applied (a conversation whose own change couldn't be published wasn't).
        let known = Set(input.events.keys).union(input.metadata.keys).union(compactionRuntime.prunedIDs)
        let applied = known.subtracting(input.events.filter { input.unapplied.contains($0.value.meetingID) }.keys)
        // Nothing comes due in a pass whose notice isn't in iCloud as it stands.
        for (original, candidate) in state.objects where noticed && !unjudged.contains(original) {
            guard let acknowledged = candidate.acknowledgedSince, let mark = candidate.acknowledgedWatched,
                  Self.supersededWaitPassed(since: candidate.since, watched: candidate.sinceWatched, now: now, state: state),
                  Self.supersededWaitPassed(since: acknowledged, watched: mark, now: now, state: state),
                  supersededCaughtUp(candidate, others: others, state: state, applied: applied, now: now) else { continue }
            supersededRuntime.due[original] = candidate
        }
        supersededRuntime.dueJournal = known
        supersededRuntime.dueApplied = applied
    }

    /// The one place a superseded original's object is deleted from iCloud: after a pass found it due
    /// (`runSupersededObjects`) and was applied and acknowledged, under the library's lock, with nothing awaited from
    /// here to the deletion. Everything is asked again: this is still the Mac that compacts a plaintext library and may
    /// delete; no journal entry, event or settings version, arrived since that pass read it; every device seen lately
    /// still knows notices, acknowledges the object without holding it, acknowledged again on a full pass seen in the last
    /// six hours, and has applied here what it says it wrote; the library's conversations as they are now (`meetings`) still hold every
    /// recording whose original it is as a copy that stands (in iCloud, uploaded, here verified), the same copies as when
    /// its wait began, none in a conversation voice profiles hold (`heldForVoice`,
    /// `LibraryController.meetingsHoldingOriginalsInICloud`), and no track here, the Trash included, names it; and,
    /// inside the coordinated delete, its object still has the stamp it had when it became free. The deletion is logged
    /// durably first, then published in the notice. A delete that fails is the report's error and is tried again later;
    /// one that took the object away keeps its log entry whatever else failed.
    public func deleteSupersededObjects(meetings: [Meeting], heldForVoice: Set<UUID>) {
        let due = supersededRuntime.due
        supersededRuntime.due = [:]
        guard !due.isEmpty, mayDeleteSupersededObjects, supersededStateURL != nil, !supersededRuntime.ownRecordUnread else { return }
        let now = compactionClock()
        var report = compactionReport ?? CompactionReport()
        report.deletedSuperseded = 0; report.deletedSupersededBytes = 0
        defer { compactionReport = report }
        // Nothing new in the journal since the pass read it: no event, and no settings version (a voiceprint).
        for directory in ["Events", "Metadata"] {
            guard let listed = try? journalFiles(in: directory),
                  listed.allSatisfy({ supersededRuntime.dueJournal.contains($0.deletingPathExtension().lastPathComponent) }) else { return }
        }
        let earlier = Set(((try? knownDevices(now: now)) ?? []).filter { $0.supersededBy != nil }.map(\.id))
        guard let recent = recentPresence(now: now), compactsHere(recent, superseded: earlier),
              let others = supersededParticipants(recent, now: now), everyRecentDeviceReadsNotices(others),
              let facts = supersededFacts(meetings, deleted: []) else { return }
        var state = supersededState()
        noteParticipants(others, in: &state, now: now)
        var changed = false
        for (original, candidate) in due.sorted(by: { $0.key < $1.key }) {
            guard let known = state.objects[original], known.stamp == candidate.stamp, known.copies == candidate.copies,
                  supersededAcknowledged(original, sequence: known.sequence, others: others, state: state),
                  supersededCaughtUp(known, others: others, state: state, applied: supersededRuntime.dueApplied, now: now),
                  let tracks = facts.byOriginal[original], !tracks.isEmpty, !facts.held.contains(original),
                  Set(tracks.map(\.copy)).sorted() == known.copies,
                  tracks.allSatisfy({ !heldForVoice.contains($0.meetingID) }), tracks.allSatisfy(copyStands) else { continue }
            // The log first, durably: a crash after the delete still knows what went and why.
            let previous = state.deleted[original]
            state.deleted[original] = .init(sha256: original, at: now, size: Int64(known.stamp.size),
                                            tracks: tracks.map { .init(meetingID: $0.meetingID, trackID: $0.trackID, copy: $0.copy) }
                                                .sorted { ($0.meetingID.uuidString, $0.trackID.uuidString) < ($1.meetingID.uuidString, $1.trackID.uuidString) })
            do { try saveSupersededState(state) } catch {
                report.lastError = error.localizedDescription
                state.deleted[original] = previous
                continue
            }
            var gone: Bool
            do {
                gone = try deleteSupersededObject(original, stamp: known.stamp)
            } catch {
                report.lastError = error.localizedDescription
                Self.log.error("Couldn't delete a superseded original from iCloud: \(error.localizedDescription, privacy: .public)")
                // Gone all the same (a placeholder that wouldn't go, say): the log keeps it.
                gone = SyncFiles.itemState(blobURL(original)) == .absent
            }
            guard gone else {
                state.deleted[original] = previous
                try? saveSupersededState(state)
                continue
            }
            state.objects[original] = nil
            changed = true
            try? saveSupersededState(state)
            report.deletedSuperseded += 1
            report.deletedSupersededBytes += Int64(known.stamp.size)
            Self.log.info("Deleted a superseded original from iCloud: \(String(original.prefix(12)), privacy: .public)")
        }
        if changed {
            state.sequence += 1
            try? saveSupersededState(state)
            publishSupersededRecord(state, now: now)
        }
    }

    /// Deletes `Blobs/<sha256>` (and its legacy placeholder) with a coordinated write, checking its stamp inside the
    /// coordination. False when its stamp isn't `stamp` (written again since); throws when it couldn't be deleted.
    private func deleteSupersededObject(_ sha256: String, stamp: VerifiedAsset) throws -> Bool {
        let url = blobURL(sha256)
        try SyncFiles.noSymlinks(url, below: remoteRoot)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?, outcome: Result<Bool, Error> = .success(false)
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do {
                try SyncFiles.noSymlinks(target, below: remoteRoot)
                guard objectStamp(target, digest: sha256) == stamp else { outcome = .success(false); return }
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try supersededDeleteFault?()
                let placeholder = SyncFiles.placeholder(for: target)
                if fm.fileExists(atPath: placeholder.path) { try fm.removeItem(at: placeholder) }
                outcome = .success(true)
            } catch { outcome = .failure(error) }
        }
        verifiedAssets.removeValue(forKey: url.path)
        if let coordinationError { throw coordinationError }
        guard try outcome.get() else { return false }
        guard SyncFiles.itemState(url) == .absent else { throw LibrarySyncError.invalidBlob(sha256) }
        return true
    }

    /// What a proposal pruning `freedBy` would also free: the objects of superseded originals named only by those entries
    /// (so a library with few edits still compacts to let a replaced recording's original go).
    func supersededGain(_ input: CompactionInput, freedBy entries: Set<String>) -> Int64 {
        guard sealing == nil else { return 0 }
        let originals = Set(input.meetings.filter { !input.deleted.contains($0.id) }.flatMap { meeting in
            meeting.tracks.compactMap { track -> String? in
                guard let previous = track.encoding?.previousSHA256, SyncFiles.isHash(previous), previous != track.sha256 else { return nil }
                return previous
            }
        })
        guard !originals.isEmpty else { return 0 }
        let pruned = compactionRuntime.prunedIDs
        var naming: [String: Set<String>] = [:]
        for (id, header) in input.events where !pruned.contains(id) {
            for asset in header.assets where originals.contains(asset.sha256) { naming[asset.sha256, default: []].insert(id) }
        }
        var total: Int64 = 0
        for original in originals {
            guard let named = naming[original], !named.isEmpty, named.isSubset(of: entries),
                  let stamp = objectStamp(blobURL(original), digest: original) else { continue }
            total += Int64(stamp.size)
        }
        return total
    }

    /// An object's stamp in the sync folder, downloaded or not; nil when it isn't there.
    func objectStamp(_ url: URL, digest: String) -> VerifiedAsset? {
        switch SyncFiles.itemState(url) {
        case .absent: return nil
        case .local: return try? assetStamp(url, digest: digest)
        case .inCloud:
            if fm.fileExists(atPath: url.path) { return try? assetStamp(url, digest: digest) }
            return try? assetStamp(SyncFiles.placeholder(for: url), digest: digest)
        }
    }
}
