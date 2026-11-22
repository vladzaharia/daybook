import Darwin
import Foundation

// Superseded originals (docs/icloud-sync.md, "Superseded objects go from iCloud"). Once a Mac replaces a recording with
// a verified compressed copy, the original's object in `Blobs/` is the last lossless copy anywhere, and what any device
// that hasn't caught up, or that holds the same bytes under a new reference, may still need. One Mac deletes it, the one
// that compacts, and only after announcing it:
//
// - The notice. The compacting Mac lists each object it means to delete in a synced record of its own,
//   `Superseded/<SHA-256 of its device ID>.json` (`SupersededRecord`), with the sequence at which it was listed, and
//   keeps there the log of what it deleted. Every device reads every such record each pass.
// - The acknowledgement. Each device says in its presence (`SyncDeviceRecord.superseded`) the latest sequence of each
//   record it has read, and which of the listed objects its own library still names (a track's file, its Trash
//   included): those it holds. An object goes only once every device seen in the last 30 days lists `superseded-1`
//   and acknowledges a sequence at or after the object's without holding it, and that has held, with everything else,
//   for a full day by the wall clock and, within a boot, by the continuous clock.
// - Possibly gone. On every device, a SHA-256 its library knows as a superseded original (`encoding.previousSHA256`),
//   one a record lists, and one a record says was deleted is possibly gone: a file of it is never let go on the strength
//   of the object (`evictAudio`), an on-demand replica never publishes it by reference unless the object is here and no
//   record lists it, and a device holding its bytes uploads it again whenever a live conversation names it and iCloud
//   doesn't have it (`repairSupersededObjects`). A deleted one named again is a warning.
// - The deletion happens after the pass, under the library's lock, with everything asked again with nothing awaited:
//   the library's conversations and the voice profiles' holds as they are then (`deleteSupersededObjects`).

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
/// means to delete, each with the sequence it was listed at, and the log of those it deleted, with what justified each.
/// Rewritten as either changes; `sequence` rises with every change to what's listed.
struct SupersededRecord: Codable, Equatable {
    static let currentFormat = "DaybookSuperseded"
    static let directory = "Superseded"
    static let maximumBytes = 8 << 20
    var format = SupersededRecord.currentFormat
    var schemaVersion = 1
    var deviceID: String
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
              let record = try? JSONDecoder().decode(SupersededRecord.self, from: data), !record.deviceID.isEmpty,
              record.objects.allSatisfy({ SyncFiles.isHash($0.sha256) }), record.deleted.allSatisfy({ SyncFiles.isHash($0.sha256) }) else { return nil }
        return record
    }
}

/// A device's acknowledgement of a compacting Mac's notice, in its presence (`SyncDeviceRecord.superseded`): the latest
/// sequence it read of that Mac's record, and the objects listed there its own library still names (it holds those).
struct SupersededAck: Codable, Equatable {
    var device: String
    var through: Int
    var holds: [String]
}

/// What the compacting Mac remembers of superseded objects between passes, beside its checkpoint (never synced): each
/// object free to go and since when, its object's stamp then, when every device first acknowledged it, the sequence of
/// its notice, the log of deletions, and when it last checked. Lost or damaged, every wait starts again; the sequence and
/// the log come back from its own synced record.
struct SupersededObjectsState: Codable, Equatable {
    var schemaVersion = 2
    var objects: [String: Candidate] = [:]
    var sequence = 0
    var deleted: [String: SupersededRecord.Deletion] = [:]
    var lastCheck: Date?
    var lastClock: SyncClockMark?

    struct Candidate: Codable, Equatable {
        /// The copies of every recording here whose original it is.
        var copies: [String]
        var since: Date
        var clock: SyncClockMark
        var stamp: VerifiedAsset
        /// The notice's sequence when it was listed.
        var sequence: Int
        var acknowledgedSince: Date?
        var acknowledgedClock: SyncClockMark?
    }
}

/// What the engine knows of superseded objects in this process.
struct SupersededRuntime {
    /// Every compacting Mac's notice as this device last read it, by device ID (this device's own included).
    var records: [String: SupersededRecord] = [:]
    /// This device's acknowledgements, for its presence; nil when it can't say what it holds (a conversation in its Trash
    /// that can't be read), and then it acknowledges nothing.
    var acks: [SupersededAck]?
    /// SHA-256s this device counts as possibly gone (see the top of this file).
    var possiblyGone: Set<String> = []
    /// Objects the compacting Mac's last pass found due (`runSupersededObjects`), for `deleteSupersededObjects`, with the
    /// journal entries that pass knew (an entry since may name one of them).
    var due: [String: SupersededObjectsState.Candidate] = [:]
    var dueJournal: Set<String> = []
}

extension LibrarySyncEngine {
    /// The presence feature saying a device reads compacting Macs' notices of superseded objects, acknowledges them, and
    /// treats what they list as possibly gone. An object goes only while every device seen in the last 30 days lists it.
    public static let supersededFeature = "superseded-1"

    /// How long an original's object must have been free to go and acknowledged by every device, each without a break,
    /// before it goes: time for an edit or presence written anywhere just before to reach iCloud and be seen.
    static let supersededWait: TimeInterval = 24 * 60 * 60
    /// A wall clock that disagrees with the continuous clock by more than this within a boot jumped; across a restart, one
    /// that went back more than this, or on by more than `supersededLargestGap`, may have: every wait starts again.
    static let supersededClockTolerance: TimeInterval = 60 * 60
    static let supersededLargestGap: TimeInterval = 3 * 24 * 60 * 60

    // MARK: Every device

    /// Reads every compacting Mac's notice (`Superseded/`). One that isn't downloaded is asked for, and the one read
    /// before is kept meanwhile; one in a form this version can't read says nothing.
    func readSupersededRecords() {
        let directory = remoteRoot.appendingPathComponent(SupersededRecord.directory, isDirectory: true)
        guard (try? SyncFiles.noSymlinks(directory, below: remoteRoot)) != nil, fm.fileExists(atPath: directory.path),
              let urls = try? journalFiles(in: SupersededRecord.directory) else { return }
        var seen = Set<String>()
        for url in urls {
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > SupersededRecord.maximumBytes { continue }
            guard let bytes = try? SyncFiles.read(url, below: remoteRoot, cloud: cloud), let record = SupersededRecord.decode(bytes),
                  url.lastPathComponent == SupersededRecord.fileName(for: record.deviceID) else {
                if let known = supersededRuntime.records.first(where: { SupersededRecord.fileName(for: $0.key) == url.lastPathComponent }) { seen.insert(known.key) }
                continue
            }
            supersededRuntime.records[record.deviceID] = record
            seen.insert(record.deviceID)
        }
        supersededRuntime.records = supersededRuntime.records.filter { seen.contains($0.key) }
    }

    /// What every notice lists or logs as deleted, and what this library knows as superseded originals.
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
        supersededRuntime.possiblyGone = gone
        if audioPolicy == .onDemand {
            let sorted = gone.sorted()
            if audioIndex().possiblyGone != sorted { updateAudioIndex { $0.possiblyGone = sorted } }
        }
    }

    /// Whether a compacting Mac's notice lists this object: it may go any time.
    func supersededDeletionListed(_ sha256: String) -> Bool {
        supersededRuntime.records.values.contains { $0.objects.contains { $0.sha256 == sha256 } }
    }

    /// What every notice says was deleted.
    var supersededDeletions: Set<String> {
        Set(supersededRuntime.records.values.flatMap { $0.deleted.map(\.sha256) })
    }

    /// Every SHA-256 a track names as its file in the library's conversations and in the Trash here; nil when a
    /// conversation in the Trash can't be read (it may name anything), or the Trash can't be listed.
    func digestsNamedHere(_ meetings: [Meeting]) -> Set<String>? {
        var named = Set<String>()
        for meeting in meetings { for track in meeting.tracks where SyncFiles.isHash(track.sha256) { named.insert(track.sha256) } }
        // What the Trash holds here comes back with its files if it's restored: it names its own.
        let trash = localRoot.appendingPathComponent("Trash", isDirectory: true)
        guard fm.fileExists(atPath: trash.path) else { return named }
        guard let names = try? fm.contentsOfDirectory(atPath: trash.path) else { return nil }
        for name in names where UUID(uuidString: name) != nil {
            let folder = trash.appendingPathComponent(name, isDirectory: true)
            for file in ["meeting.json", "meeting.recovery.json"] {
                let url = folder.appendingPathComponent(file)
                guard fm.fileExists(atPath: url.path) else { continue }
                guard let data = try? Data(contentsOf: url), let meeting = try? JSONDecoder().decode(Meeting.self, from: data) else { return nil }
                for track in meeting.tracks where SyncFiles.isHash(track.sha256) { named.insert(track.sha256) }
            }
        }
        return named
    }

    /// This device's acknowledgements of other Macs' notices, for its presence: through each one's sequence, holding
    /// what this library still names of what it lists. Nothing while that can't be told.
    func noteSupersededAcks(_ meetings: [Meeting]) {
        let records = supersededRuntime.records.values.filter { $0.deviceID != deviceID }
        guard !records.isEmpty else { supersededRuntime.acks = nil; return }
        let listed = Set(records.flatMap { $0.objects.map(\.sha256) })
        let named: Set<String>?
        if listed.isEmpty { named = [] } else { named = digestsNamedHere(meetings) }
        guard let named else { supersededRuntime.acks = nil; return }
        supersededRuntime.acks = records.sorted { $0.deviceID < $1.deviceID }.map { record in
            SupersededAck(device: record.deviceID, through: record.sequence, holds: record.objects.map(\.sha256).filter(named.contains).sorted())
        }
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
        // What arrived in this pass too, held back or not (an eager replica waiting for the object).
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

    private var supersededStateURL: URL? {
        libraryID.map { localRoot.appendingPathComponent("Sync/superseded-\($0.uuidString).json") }
    }

    private var ownSupersededRecordURL: URL {
        remoteRoot.appendingPathComponent("\(SupersededRecord.directory)/\(SupersededRecord.fileName(for: deviceID))")
    }

    /// What's remembered here, with the sequence and the log its own synced record has when they're further along.
    func supersededState() -> SupersededObjectsState {
        var state = SupersededObjectsState()
        if let url = supersededStateURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(SupersededObjectsState.self, from: data), saved.schemaVersion == 2 { state = saved }
        if let own = supersededRuntime.records[deviceID] {
            state.sequence = max(state.sequence, own.sequence)
            for deletion in own.deleted where state.deleted[deletion.sha256] == nil { state.deleted[deletion.sha256] = deletion }
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
        let record = SupersededRecord(deviceID: deviceID, writtenAt: now, sequence: state.sequence,
                                      objects: state.objects.map { .init(sha256: $0.key, sequence: $0.value.sequence) }.sorted { $0.sha256 < $1.sha256 },
                                      deleted: state.deleted.values.sorted { $0.sha256 < $1.sha256 })
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
            try SyncFiles.coordinateWrite(url, below: remoteRoot) { try LocalFiles.atomicWrite(bytes, to: $0) }
            supersededRuntime.records[deviceID] = record
        } catch {
            Self.log.error("Couldn't write the notice of superseded originals: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    /// A Mac that no longer compacts lists nothing: what it listed isn't going (its log stays).
    func withdrawSupersededNotice(now: Date) {
        supersededRuntime.due = [:]
        guard sealing == nil, let own = supersededRuntime.records[deviceID], !own.objects.isEmpty else { return }
        var state = supersededState()
        state.objects = [:]
        state.sequence += 1
        try? saveSupersededState(state)
        publishSupersededRecord(state, now: now)
    }

    /// The wall clock moved as the continuous clock did since the last check, within an hour, in the same boot; across a
    /// restart, it didn't go back more than an hour or on more than three days (#103's clock guard).
    private func supersededClockIsSteady(_ state: SupersededObjectsState, now: Date, clock: SyncClockMark) -> Bool {
        guard let last = state.lastCheck else { return true }
        if let elapsed = state.lastClock?.elapsed(until: clock) {
            return abs(now.timeIntervalSince(last) - elapsed) <= Self.supersededClockTolerance
        }
        return now >= last.addingTimeInterval(-Self.supersededClockTolerance) && now <= last.addingTimeInterval(Self.supersededLargestGap)
    }

    /// A day has passed since `since` by the wall clock, and, in the same boot, by the continuous clock too.
    private static func supersededWaitPassed(since: Date, clock mark: SyncClockMark, now: Date, clock: SyncClockMark) -> Bool {
        guard now.timeIntervalSince(since) >= supersededWait else { return false }
        if let elapsed = mark.elapsed(until: clock) { return elapsed >= supersededWait }
        return true
    }

    /// The live conversations' recordings held as compressed copies, by the original they replaced, and every SHA-256 a
    /// track names as its file here (the Trash included); nil when a conversation in the Trash can't be read.
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

    /// Whether every device seen lately acknowledges this object: a sequence of this Mac's notice at or after the one it
    /// was listed at, without holding it.
    private func supersededAcknowledged(_ sha256: String, sequence: Int, others: [SyncDeviceRecord]) -> Bool {
        others.allSatisfy { record in
            (record.superseded ?? []).contains { $0.device == deviceID && $0.through >= sequence && !$0.holds.contains(sha256) }
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
    /// after the replacement); no track here, the Trash included, names it as its file (and every conversation in the
    /// Trash can be read); every live recording whose original it is has its copy in iCloud, uploaded, and here
    /// verified, in a conversation the library judged and whose originals voice profiles don't hold
    /// (`holdOriginalsInICloud`); and its object is there. Due means free, with the stamp it had when it became free,
    /// for a day, and acknowledged by every device for a day, by a clock that didn't jump.
    func runSupersededObjects(_ input: CompactionInput, others: [SyncDeviceRecord], now: Date) {
        supersededRuntime.due = [:]
        guard sealing == nil, waitingForKey == nil, supersededStateURL != nil else { return }
        var state = supersededState()
        let before = state
        let clock = continuousClock()
        let steady = supersededClockIsSteady(state, now: now, clock: clock)
        state.lastCheck = now; state.lastClock = clock
        var free: [String: (copies: [String], stamp: VerifiedAsset)] = [:]
        if everyRecentDeviceReadsNotices(others),
           compactionRuntime.records.values.filter(\.record.isCommit).allSatisfy({ uploadedStrictly($0.url) }),
           let facts = supersededFacts(input.meetings, deleted: input.deleted) {
            let pruned = compactionRuntime.prunedIDs
            let named = Set(input.events.filter { !pruned.contains($0.key) }.values.flatMap { $0.assets.map(\.sha256) })
            // What another device holds isn't free either, so its notice no longer lists it and that device may publish
            // it by reference; once it does, the journal names it.
            let heldElsewhere = Set(others.flatMap { ($0.superseded ?? []).filter { $0.device == deviceID }.flatMap(\.holds) })
            let voice = originalsHeldForVoice
            for (original, tracks) in facts.byOriginal {
                guard !named.contains(original), !facts.held.contains(original), !heldElsewhere.contains(original),
                      tracks.allSatisfy({ copy in voice.map { !$0.held.contains(copy.meetingID) && $0.judged.contains(copy.meetingID) } ?? false }),
                      tracks.allSatisfy(copyStands), let stamp = objectStamp(blobURL(original), digest: original) else { continue }
                free[original] = (Set(tracks.map(\.copy)).sorted(), stamp)
            }
        }
        // What isn't free any more forgets its wait; what's new is listed in the notice at a new sequence.
        let added = Set(free.keys).subtracting(state.objects.keys), removed = Set(state.objects.keys).subtracting(free.keys)
        if !added.isEmpty || !removed.isEmpty { state.sequence += 1 }
        for key in removed { state.objects[key] = nil }
        for (original, found) in free {
            if var known = state.objects[original] {
                // A copy that changed, an object written again since (someone's upload), or a clock that jumped: it starts again.
                if known.copies != found.copies || known.stamp != found.stamp || known.since > now || !steady {
                    known.copies = found.copies; known.stamp = found.stamp; known.since = now; known.clock = clock
                    known.acknowledgedSince = nil; known.acknowledgedClock = nil
                    state.objects[original] = known
                }
            } else {
                state.objects[original] = .init(copies: found.copies, since: now, clock: clock, stamp: found.stamp, sequence: state.sequence)
            }
        }
        let noticed = publishSupersededRecord(state, now: now)
        for (original, var candidate) in state.objects {
            if noticed, supersededAcknowledged(original, sequence: candidate.sequence, others: others) {
                if candidate.acknowledgedSince == nil || candidate.acknowledgedSince! > now || !steady {
                    candidate.acknowledgedSince = now; candidate.acknowledgedClock = clock
                }
            } else {
                candidate.acknowledgedSince = nil; candidate.acknowledgedClock = nil
            }
            state.objects[original] = candidate
        }
        if state != before {
            do { try saveSupersededState(state) } catch {
                Self.log.error("Couldn't save superseded originals' waits: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        for (original, candidate) in state.objects {
            guard let acknowledged = candidate.acknowledgedSince, let mark = candidate.acknowledgedClock,
                  Self.supersededWaitPassed(since: candidate.since, clock: candidate.clock, now: now, clock: clock),
                  Self.supersededWaitPassed(since: acknowledged, clock: mark, now: now, clock: clock) else { continue }
            supersededRuntime.due[original] = candidate
        }
        supersededRuntime.dueJournal = Set(input.events.keys).union(compactionRuntime.prunedIDs)
    }

    /// The one place a superseded original's object is deleted from iCloud: after a pass found it due
    /// (`runSupersededObjects`), under the library's lock, with nothing awaited from here to the deletion. Everything is
    /// asked again: no journal entry arrived since that pass read it; every device seen lately still knows notices and
    /// acknowledges the object without holding it; the library's conversations as they are now (`meetings`) still hold
    /// every recording whose original it is as a copy that stands (in iCloud, uploaded, here verified), the same copies
    /// as when its wait began, none in a conversation voice profiles hold (`heldForVoice`,
    /// `LibraryController.meetingsHoldingOriginalsInICloud`), and no track here, the Trash included, names it; and,
    /// inside the coordinated delete, its object still has the stamp it had when it became free. The deletion is logged
    /// durably first, then published in the notice. A failed delete is the report's error and is tried again later.
    public func deleteSupersededObjects(meetings: [Meeting], heldForVoice: Set<UUID>) {
        let due = supersededRuntime.due
        supersededRuntime.due = [:]
        guard !due.isEmpty, sealing == nil, waitingForKey == nil, supersededStateURL != nil else { return }
        let now = compactionClock()
        var report = compactionReport ?? CompactionReport()
        report.deletedSuperseded = 0; report.deletedSupersededBytes = 0
        defer { compactionReport = report }
        // Nothing new in the journal since the pass read it.
        guard let listed = try? journalFiles(in: "Events"),
              listed.allSatisfy({ supersededRuntime.dueJournal.contains($0.deletingPathExtension().lastPathComponent) }) else { return }
        guard let others = recentPresence(now: now), everyRecentDeviceReadsNotices(others),
              let facts = supersededFacts(meetings, deleted: []) else { return }
        var state = supersededState()
        var changed = false
        for (original, candidate) in due.sorted(by: { $0.key < $1.key }) {
            guard let known = state.objects[original], known.stamp == candidate.stamp, known.copies == candidate.copies,
                  supersededAcknowledged(original, sequence: known.sequence, others: others),
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
            do {
                guard try deleteSupersededObject(original, stamp: known.stamp) else {
                    state.deleted[original] = previous
                    try? saveSupersededState(state)
                    continue
                }
            } catch {
                report.lastError = error.localizedDescription
                Self.log.error("Couldn't delete a superseded original from iCloud: \(error.localizedDescription, privacy: .public)")
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
                let placeholder = SyncFiles.placeholder(for: target)
                if fm.fileExists(atPath: placeholder.path) { try fm.removeItem(at: placeholder) }
                outcome = .success(true)
            } catch { outcome = .failure(error) }
        }
        if let coordinationError { throw coordinationError }
        guard try outcome.get() else { return false }
        verifiedAssets.removeValue(forKey: url.path)
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
