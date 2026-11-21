import Foundation

// Superseded originals (docs/icloud-sync.md, "Compressed recordings"). Once a Mac replaces a recording with a verified
// compressed copy, the original's object in `Blobs/` is what every device that hasn't caught up may still need. It goes
// once nothing can: every journal entry that names it has been pruned by compaction, which happens only after every
// device seen in the last 30 days has acknowledged a state after the replacement (LibrarySyncCompaction.swift, the
// existing rule for devices that are away), the copy is in iCloud, uploaded, and here verified, the replacement's
// provenance records the original's SHA-256, and no track here names the original, all of that for a day without a
// break. One Mac deletes it, the one that compacts, in one place (`deleteSupersededObjects`).

/// A recording this device's library holds as a compressed copy, and the original it replaced.
struct SupersededOriginal: Equatable {
    /// The original's SHA-256 (`TrackEncoding.previousSHA256`): the object that may go.
    var original: String
    /// The copy's SHA-256, and where it is in this library.
    var copy: String
    var copyURL: URL
}

/// What the compacting Mac remembers of superseded objects between passes, beside its checkpoint (never synced): when
/// each became free to go, and its object's stamp then. Lost or damaged, every wait starts again.
struct SupersededObjectsState: Codable, Equatable {
    var schemaVersion = 1
    var objects: [String: Candidate] = [:]

    struct Candidate: Codable, Equatable {
        var copy: String
        var since: Date
        var stamp: VerifiedAsset
    }
}

extension LibrarySyncEngine {
    /// How long an original's object must have been free to go, without a break, before it goes: time for an edit made
    /// anywhere just before the decision to reach iCloud and be seen.
    static let supersededWait: TimeInterval = 24 * 60 * 60

    /// The superseded originals of the conversations a pass was given (`meetings`, less those deleted), each whose copy
    /// is a track's file, with every SHA-256 a track here holds as its file, the Trash included: those stay.
    func supersededOriginals(_ meetings: [Meeting], deleted: Set<UUID>) -> (originals: [SupersededOriginal], held: Set<String>) {
        var originals: [SupersededOriginal] = [], held = Set<String>()
        for meeting in meetings {
            for track in meeting.tracks where SyncFiles.isHash(track.sha256) { held.insert(track.sha256) }
            guard !deleted.contains(meeting.id) else { continue }
            let directory = localRoot.appendingPathComponent("Meetings/\(meeting.id.uuidString)", isDirectory: true)
            for track in meeting.tracks {
                guard let encoding = track.encoding, SyncFiles.isHash(encoding.previousSHA256), SyncFiles.isHash(track.sha256),
                      encoding.previousSHA256 != track.sha256, let url = try? LocalFiles.relativeURL(track.relativePath, in: directory) else { continue }
                originals.append(SupersededOriginal(original: encoding.previousSHA256, copy: track.sha256, copyURL: url))
            }
        }
        // What the Trash holds here comes back with its files if it's restored: it names its own.
        let trash = localRoot.appendingPathComponent("Trash", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: trash.path)) ?? [] where UUID(uuidString: name) != nil {
            let folder = trash.appendingPathComponent(name, isDirectory: true)
            for file in ["meeting.json", "meeting.recovery.json"] {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)),
                      let meeting = try? JSONDecoder().decode(Meeting.self, from: data) else { continue }
                for track in meeting.tracks where SyncFiles.isHash(track.sha256) { held.insert(track.sha256) }
            }
        }
        return (originals, held)
    }

    private var supersededStateURL: URL? {
        libraryID.map { localRoot.appendingPathComponent("Sync/superseded-\($0.uuidString).json") }
    }

    func supersededState() -> SupersededObjectsState {
        guard let url = supersededStateURL, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SupersededObjectsState.self, from: data), state.schemaVersion == 1 else { return SupersededObjectsState() }
        return state
    }

    private func saveSupersededState(_ state: SupersededObjectsState) {
        guard let url = supersededStateURL else { return }
        try? SyncFiles.noSymlinks(url, below: localRoot)
        try? DurableFiles.write(SyncEncoding.data(state), to: url)
    }

    /// The one place a superseded original's object is deleted from iCloud, on the compacting Mac at the end of a pass
    /// that read the whole journal (`runCompaction`'s guards: not while every other device is away, not with a clock
    /// that looks ahead). A plaintext library's `Blobs/<original>` goes once all of these have held for
    /// `supersededWait` without a break, and are true again now, with nothing awaited from here to the deletion:
    /// - every device seen in the last 30 days lists `compress-1` and `compact-1`, and every compaction commit is in iCloud;
    /// - no journal entry still here names it (every one that did was pruned, which needed every device seen in the last
    ///   30 days to acknowledge a state after the replacement);
    /// - a live conversation here has a track whose `encoding.previousSHA256` is it, whose object is in iCloud and reported
    ///   uploaded, and whose file is here verified (an eager Mac's complete pass puts back a copy that differs);
    /// - no track here (the Trash included) names it as its file;
    /// - its object has the stamp it had when it first became free to go (one written again since is someone's upload).
    /// An encrypted library's sealer retires what no live conversation uses on its own. Deleting a missing object is
    /// nothing, and what's remembered is saved after each step, so a crash anywhere repeats or resumes the same work.
    func deleteSupersededObjects(_ input: CompactionInput, others: [SyncDeviceRecord], now: Date, report: inout CompactionReport) {
        guard sealing == nil, supersededStateURL != nil else { return }
        guard others.allSatisfy({ ($0.features ?? []).contains(Self.compressionFeature) && ($0.features ?? []).contains(Self.compactionFeature) }),
              compactionRuntime.records.values.filter(\.record.isCommit).allSatisfy({ cloud.isUploaded($0.url) }) else { return }
        let pruned = compactionRuntime.prunedIDs
        let named = Set(input.events.filter { !pruned.contains($0.key) }.values.flatMap { $0.assets.map(\.sha256) })
        var free: [String: SupersededObjectsState.Candidate] = [:]
        for candidate in input.superseded.sorted(by: { ($0.original, $0.copy) < ($1.original, $1.copy) }) where free[candidate.original] == nil {
            let object = blobURL(candidate.original), copy = blobURL(candidate.copy)
            guard !named.contains(candidate.original), !input.heldDigests.contains(candidate.original),
                  SyncFiles.itemState(copy) != .absent, cloud.isUploaded(copy), (try? verified(candidate.copyURL, digest: candidate.copy)) == true,
                  let stamp = objectStamp(object, digest: candidate.original) else { continue }
            free[candidate.original] = .init(copy: candidate.copy, since: now, stamp: stamp)
        }
        var state = supersededState()
        let before = state
        // What isn't free any more forgets its wait; what changed starts it again.
        state.objects = state.objects.filter { free[$0.key] != nil }
        for (original, candidate) in free {
            if let known = state.objects[original], known.copy == candidate.copy, known.stamp == candidate.stamp, known.since <= now { continue }
            state.objects[original] = candidate
        }
        if state != before { saveSupersededState(state) }
        for (original, candidate) in state.objects.sorted(by: { $0.key < $1.key }) where now.timeIntervalSince(candidate.since) >= Self.supersededWait {
            let object = blobURL(original)
            guard objectStamp(object, digest: original) == candidate.stamp else { continue }
            deleteRemote(object)
            guard SyncFiles.itemState(object) == .absent else { continue }
            state.objects[original] = nil
            saveSupersededState(state)
            report.deletedSuperseded += 1
            report.deletedSupersededBytes += Int64(candidate.stamp.size)
            Self.log.info("Deleted a superseded original from iCloud: \(String(original.prefix(12)), privacy: .public)")
        }
    }

    /// What a proposal pruning `freedBy` would also free: the objects of superseded originals named only by those entries
    /// (so a library with few edits still compacts to let a replaced recording's original go).
    func supersededGain(_ input: CompactionInput, freedBy entries: Set<String>) -> Int64 {
        guard sealing == nil, !input.superseded.isEmpty else { return 0 }
        let pruned = compactionRuntime.prunedIDs
        var naming: [String: Set<String>] = [:]
        for (id, header) in input.events where !pruned.contains(id) {
            for asset in header.assets { naming[asset.sha256, default: []].insert(id) }
        }
        var total: Int64 = 0, counted = Set<String>()
        for candidate in input.superseded where counted.insert(candidate.original).inserted && !input.heldDigests.contains(candidate.original) {
            guard let named = naming[candidate.original], !named.isEmpty, named.isSubset(of: entries),
                  let stamp = objectStamp(blobURL(candidate.original), digest: candidate.original) else { continue }
            total += Int64(stamp.size)
        }
        return total
    }

    /// An object's stamp in the sync folder, downloaded or not; nil when it isn't there.
    private func objectStamp(_ url: URL, digest: String) -> VerifiedAsset? {
        switch SyncFiles.itemState(url) {
        case .absent: return nil
        case .local: return try? assetStamp(url, digest: digest)
        case .inCloud:
            if fm.fileExists(atPath: url.path) { return try? assetStamp(url, digest: digest) }
            return try? assetStamp(SyncFiles.placeholder(for: url), digest: digest)
        }
    }
}
