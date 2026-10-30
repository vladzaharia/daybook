import Foundation

// Compaction (docs/icloud-sync.md, "Compaction"). Journal entries are immutable, and every library settings version
// carries every setting (each speaker profile's voiceprints included, about 1 KB apiece), so without compaction the sync
// folder grows with every change ever made. Compaction deletes history no device needs any more, in a way every device
// can apply on its own, whenever it next syncs:
//
// - Compaction records, `Compaction/<SHA-256>.json` (or `Sealed/Compaction/<name>`, sealed like everything else in an
//   encrypted library), say what's gone. A commit lists the entries it pruned; every device treats a pruned entry as gone
//   for good, even while its file is still there, and never waits for one: a parent a commit lists isn't a download.
// - Library settings merge item by item, the latest change winning, with no common ancestor: every settings version
//   that isn't a head can go at once. A device that publishes against one that's gone merges just the same.
// - A live conversation's merges need its history back to the common ancestor, and a device still holding a deleted one
//   needs what the deletion saw to tell what it added since, so both go in two steps. A proposal names each live
//   conversation's one head as its root, and the deleted conversations. Every device seen in the last 30 days
//   acknowledges it in its presence once everything it has applied of those conversations is the root or after it, and
//   it has applied those deletions, so it never publishes against what's pruned. Then a commit prunes each root's
//   ancestors, for the conversations whose every head still descends from it, and the deleted conversations' history
//   (their deletions stay). An ancestor that alone names a highlight sidecar stays too: a conversation's sidecars are
//   those any of its events names.
// - One Mac compacts: the one with the smallest device ID among Macs seen in the last 30 days (that hold the key, when
//   the library is encrypted, and aren't an earlier identity of a reinstalled Mac), only when every device seen in that
//   time can read a compacted library, after a pass that read the whole journal. In an encrypted library the sealer
//   seals compaction records again under a new key like the rest of the history. Before it deletes anything, the manifest becomes version 3, which earlier Daybooks refuse
//   ("Update Daybook to sync"): they'd otherwise wait forever for parents that are gone.
// - A device that comes back after what it last applied was pruned (away longer than 30 days, or restored from a backup)
//   merges its own changes against the base it stored when it applied them, and publishes the result as an ordinary edit
//   (`Rebase`, in `synchronize`). One whose own unsent entry was published against what's since pruned merges with no
//   common ancestor, as two devices that created the same conversation do: conflicts are kept in History.

/// When the compacting Mac compacts.
public struct SyncCompactionPolicy: Equatable, Sendable {
    /// Compact once at least this many entries could go…
    public var minimumEntries: Int
    /// …or at least this many bytes.
    public var minimumBytes: Int64
    /// At most this often.
    public var interval: TimeInterval
    /// More commit records than this are consolidated into one.
    public var maximumCommits: Int

    public init(minimumEntries: Int, minimumBytes: Int64, interval: TimeInterval, maximumCommits: Int) {
        self.minimumEntries = minimumEntries; self.minimumBytes = minimumBytes; self.interval = interval
        self.maximumCommits = maximumCommits
    }

    /// The apps': 256 entries or 8 MB (about 16 settings versions with 20 full speaker profiles), at most every six hours.
    public static let standard = SyncCompactionPolicy(minimumEntries: 256, minimumBytes: 8 << 20, interval: 6 * 60 * 60, maximumCommits: 8)
    /// Whenever anything can go (tests and measurements).
    public static let eager = SyncCompactionPolicy(minimumEntries: 1, minimumBytes: 0, interval: 0, maximumCommits: 2)
}

/// What compaction did on the pass that last ran it.
public struct CompactionReport: Equatable, Sendable {
    /// A proposal was written.
    public var proposed = false
    /// Entries a commit pruned.
    public var pruned = 0
    /// Files deleted from the sync folder, and their bytes.
    public var deletedFiles = 0
    public var deletedBytes: Int64 = 0
    /// Commit records were consolidated into one.
    public var consolidated = false
    public init() {}
}

/// A compaction record: a proposal (`roots`) or a commit (`pruned`). Immutable and content-addressed, like the journal.
struct SyncCompactionRecord: Codable, Equatable {
    static let currentFormat = "DaybookCompaction"
    var format = SyncCompactionRecord.currentFormat
    var schemaVersion = 1
    var deviceID: String
    var createdAt: Date
    /// A proposal: each conversation's root (its one head when proposed), by conversation ID.
    var roots: [String: String]?
    /// A proposal: conversations deleted when proposed, whose history (all but their deletions) goes.
    var deletions: [String]?
    /// A commit: the entries pruned, by ID.
    var pruned: [String]?
    /// The proposal a commit carried out.
    var proposal: String?

    var isProposal: Bool { roots != nil }
    var isCommit: Bool { pruned != nil }

    /// Reads a record, refusing another format and a version this one doesn't read.
    static func decode(_ bytes: Data) throws -> SyncCompactionRecord {
        struct Header: Decodable { var format: String?; var schemaVersion: Int? }
        let header = try JSONDecoder().decode(Header.self, from: bytes)
        guard header.format == currentFormat else { throw LibrarySyncError.invalidEvent("compaction record") }
        guard header.schemaVersion == 1 else { throw LibrarySyncError.unsupportedVersion(header.schemaVersion ?? 0) }
        let record = try JSONDecoder().decode(SyncCompactionRecord.self, from: bytes)
        guard (record.pruned ?? []).allSatisfy(SyncFiles.isHash), record.proposal.map(SyncFiles.isHash) ?? true,
              (record.roots ?? [:]).allSatisfy({ UUID(uuidString: $0.key) != nil && SyncFiles.isHash($0.value) }),
              (record.deletions ?? []).allSatisfy({ UUID(uuidString: $0) != nil }),
              record.isProposal != record.isCommit else { throw LibrarySyncError.invalidEvent("compaction record") }
        return record
    }
}

/// A compaction record as a pass found it.
struct CompactionEntry {
    var entry: JournalEntry
    var id: String
    var record: SyncCompactionRecord
    var path: String { entry.path }
    var url: URL { entry.url }
    var isSealed: Bool { entry.isSealed }
}

/// What compaction needs of a pass.
struct CompactionInput {
    var events: [String: SyncEventHeader]
    var metadata: [String: SyncMetadataRecord]
    var metadataHeads: [String]
    /// Every event and settings entry the pass listed, pruned ones included.
    var entries: [JournalEntry]
    /// Deleted conversations.
    var deleted: Set<UUID>
    /// The whole journal was read: nothing pending, deferred, or unreadable.
    var complete: Bool
}

extension LibrarySyncEngine {
    /// The presence feature saying a device reads compacted libraries.
    public static let compactionFeature = "compact-1"
    /// The plaintext folder of compaction records.
    static let compactionDirectory = "Compaction"
    /// A proposal not carried out after this long is replaced by a new one.
    static let proposalLifetime: TimeInterval = 7 * 24 * 60 * 60

    // MARK: Reading

    /// The compaction records in the sync folder: plaintext ones, and in an encrypted library the sealed ones.
    func compactionEntries() throws -> [JournalEntry] {
        var entries: [JournalEntry] = []
        let plain = remoteRoot.appendingPathComponent(Self.compactionDirectory, isDirectory: true)
        try SyncFiles.noSymlinks(plain, below: remoteRoot)
        if fm.fileExists(atPath: plain.path) {
            entries += try journalFiles(in: Self.compactionDirectory).map { url in
                JournalEntry(url: url, path: "\(Self.compactionDirectory)/\(url.lastPathComponent)", directory: Self.compactionDirectory,
                             name: url.deletingPathExtension().lastPathComponent, isSealed: false)
            }
        }
        if sealing != nil || waitingForKey != nil, let directory = SealedKind.compaction.directory {
            entries += try sealedListing(in: directory).map { url in
                JournalEntry(url: url, path: "\(directory)/\(url.lastPathComponent)", directory: directory, name: url.lastPathComponent, isSealed: true)
            }
        }
        return entries
    }

    /// Reads the compaction records (each once per process): what's pruned, and the proposal waiting to be carried out.
    /// Returns how many couldn't be read yet (still downloading, or a key on its way); until they are, a missing parent
    /// they might list is waited for. One that can't be read at all (a newer format) is a warning, not a download: it
    /// leaves compaction off here, and what it lists is waited for, as before.
    func readCompaction(warnings: inout [String]) throws -> Int {
        var read: [String: CompactionEntry] = [:]
        var pending = 0, unreadable = 0, heldBack = 0
        let entries = try compactionEntries()
        compactionPaths = Set(entries.map(\.path))
        for entry in entries {
            try Task.checkCancellation()
            if let known = compactionRecords[entry.path] { read[entry.path] = known; continue }
            let unreadableKey = entry.isSealed ? entry.path : entry.name
            if let reason = unreadableJournal[unreadableKey] { warnings.append(reason); unreadable += 1; continue }
            do {
                let (id, bytes) = try readEntry(entry, kind: .compaction)
                read[entry.path] = CompactionEntry(entry: entry, id: id, record: try SyncCompactionRecord.decode(bytes))
            } catch is SyncReplacedFile { setAside(entry) }
            catch let held as SyncHeldAsideFile {
                // One sealed with a retired key that a device holding it may yet seal again may list what was pruned:
                // this Mac doesn't compact meanwhile. After a month, nothing will open it.
                noteHeldAside(entry, held)
                if heldAsideLately(entry.path) { heldBack += 1 }
            }
            catch let error as CancellationError { throw error }
            catch where Self.isPermanent(error) { warnings.append(markUnreadable(unreadableKey, error)); unreadable += 1 }
            catch { pending += 1 }
        }
        compactionRecords = read
        // Pruning is final: what this process learned was pruned stays pruned, even while a consolidated commit that lists
        // it again is still on its way.
        let pruned = Set(read.values.flatMap { $0.record.pruned ?? [] }).subtracting(prunedIDs)
        if !pruned.isEmpty { forgetPruned(pruned) }
        let executed = Set(read.values.compactMap(\.record.proposal))
        let latest = read.values.filter(\.record.isProposal).max { ($0.record.createdAt, $0.id) < ($1.record.createdAt, $1.id) }
        pendingProposal = latest.flatMap { executed.contains($0.id) ? nil : $0 }
        compactionReadComplete = pending == 0 && unreadable == 0 && heldBack == 0
        return pending
    }

    /// Adds to what's pruned, and forgets what's remembered of it.
    func forgetPruned(_ ids: Set<String>) {
        prunedIDs.formUnion(ids)
        for id in ids {
            eventCache[id] = nil; snapshotCache[id] = nil; metadataCache[id] = nil; journalLocations[id] = nil
        }
    }

    /// Whether the sealer leaves an entry alone: a replaced library's, pruned, or held aside.
    func setAsideFromSealer(_ entry: JournalEntry) -> Bool {
        replacedEntries.contains(entry.path) || prunedEntryPaths.contains(entry.path) || heldAsideEntries[entry.path] != nil
    }

    /// A pruned entry a pass found: left out of what the pass read. A courier's copy goes at once (it would otherwise be
    /// written into the sync folder after a day); the sync folder's copy is the compacting Mac's to delete.
    func setAsidePruned(_ entry: JournalEntry) {
        prunedEntryPaths.insert(entry.path)
        if let delivered = inboxCopy(entry.path) { discardDelivery(delivered) }
    }

    // MARK: Acknowledging

    /// After a pass is acknowledged: whether what this device has applied of the pending proposal's conversations is each
    /// root or after it, and it has applied the proposal's deletions (so it no longer holds a deleted conversation, or kept
    /// what it added as a new one), so it never publishes against what the proposal prunes. Once true it stays true
    /// (applied heads only move on), and its presence says so.
    func noteCompactionAck() {
        guard let proposal = pendingProposal, let roots = proposal.record.roots, state.compactionAck != proposal.id else { return }
        for meeting in proposal.record.deletions ?? [] {
            guard let id = UUID(uuidString: meeting), state.deletedIDs.contains(id), !heldDeletions.contains(id) else { return }
        }
        for (meeting, root) in roots {
            guard let applied = state.heads[meeting], !applied.isEmpty else { continue }
            // A deleted conversation keeps only its deletions, whatever was applied of it.
            if let id = UUID(uuidString: meeting), state.deletedIDs.contains(id) { continue }
            if applied.contains(where: { eventCache[$0]?.deleted == true }) { continue }
            for head in applied where head != root {
                guard eventCache[head] != nil, ancestorIDs(head, events: eventCache).contains(root) else { return }
            }
        }
        state.compactionAck = proposal.id
    }

    // MARK: Compacting

    /// One run of compaction, at the end of a pass, on the compacting Mac. Best effort: what fails is tried again later.
    func runCompaction(_ input: CompactionInput, now: Date) {
        guard let policy = compactionPolicy, audioPolicy == .eager, device?.deviceClass == .mac, libraryID != nil,
              input.complete, compactionReadComplete, unreadableJournal.isEmpty else { return }
        // A run dated after now was by a clock that was ahead, since set right: it doesn't hold compaction back.
        if let last = lastCompaction, last <= now, now.timeIntervalSince(last) < policy.interval { return }
        // Every device seen lately reads a compacted library, and this is the Mac to compact it.
        guard let others = recentPresence(now: now), others.allSatisfy({ ($0.features ?? []).contains(Self.compactionFeature) }) else { return }
        let candidates = others.filter { record in
            record.deviceClass == .mac && sealing.map { record.key == SyncDeviceKeyState(state: .ready, id: $0.current.idHex) } ?? true
        }
        // An earlier identity of a reinstalled device never syncs again: it isn't the one to compact. (It still has to
        // acknowledge: a device with the same name that's merely away may come back.)
        let superseded = Set(((try? knownDevices(now: now)) ?? []).filter { $0.supersededBy != nil }.map(\.id))
        guard (candidates.map(\.deviceID).filter { !superseded.contains($0) } + [deviceID]).min() == deviceID else { return }
        lastCompaction = now
        var report = CompactionReport()
        // What earlier commits pruned that's still here.
        deletePrunedFiles(input.entries, report: &report)
        let sizes = entrySizes(input.entries)

        // What can go now: settings versions that aren't heads.
        var prunable = Set(input.metadata.keys).subtracting(input.metadataHeads)
        // Conversations' history, once every device seen lately has acknowledged the proposal. With no other device
        // seen lately while another has written presence that isn't superseded or six months old (all away for a while,
        // or this Mac's clock running a month or more ahead), every acknowledgement would pass for want of anyone to
        // give one: nothing of a conversation goes until another device is seen.
        let dormant = others.isEmpty && (allPresence(now: now).map { records in records.contains { !superseded.contains($0.deviceID) } } ?? true)
        // A clock more than a week ahead makes devices in use look away, or gone: nothing of a conversation goes either.
        let ahead = clockLooksAhead(now: now)
        var executed: String?
        if let proposal = pendingProposal, let roots = proposal.record.roots, state.compactionAck == proposal.id, !dormant, !ahead,
           others.allSatisfy({ $0.compaction == proposal.id }) {
            executed = proposal.id
            let grouped = Dictionary(grouping: input.events.keys, by: { input.events[$0]!.meetingID })
            for (meeting, root) in roots {
                guard let id = UUID(uuidString: meeting), !input.deleted.contains(id), input.events[root] != nil, let ids = grouped[id] else { continue }
                let heads = heads(ids: ids, parents: { input.events[$0]?.parents ?? [] })
                guard heads.allSatisfy({ $0 == root || ancestorIDs($0, events: input.events).contains(root) }) else { continue }
                prunable.formUnion(prunableHistory(before: root, events: input.events))
            }
            // A deleted conversation keeps only its deletions.
            let deletions = Set((proposal.record.deletions ?? []).compactMap(UUID.init(uuidString:)))
            for (id, header) in input.events where deletions.contains(header.meetingID) && input.deleted.contains(header.meetingID) && !header.deleted {
                prunable.insert(id)
            }
        }
        let fresh = prunable.subtracting(prunedIDs)
        let freshBytes = fresh.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        if executed != nil || (!fresh.isEmpty && (fresh.count >= policy.minimumEntries || freshBytes >= policy.minimumBytes)) {
            do {
                try ensureCompactedManifest(now)
                try writeCompactionRecord(SyncCompactionRecord(deviceID: deviceID, createdAt: now, pruned: fresh.sorted(), proposal: executed))
                forgetPruned(fresh)
                report.pruned = fresh.count
                if executed != nil { pendingProposal = nil }
                deletePrunedFiles(input.entries, report: &report)
            } catch {}
        }
        tidyCompactionRecords(policy, now: now, report: &report)
        if pendingProposal == nil || proposalIsStale(input, now: now) {
            let stale = pendingProposal
            propose(input, sizes: sizes, policy: policy, now: now, report: &report)
            // A stale proposal nothing replaced is withdrawn: devices stop acknowledging it.
            if let stale, pendingProposal?.id == stale.id { removeCompactionRecord(stale); pendingProposal = nil }
        }
        compactionReport = report
    }

    /// How far behind this device's clock the freshest presence it has seen change may say it was written.
    static let clockAheadTolerance: TimeInterval = 7 * 24 * 60 * 60

    /// Whether this device's clock looks more than a week ahead: of the other devices whose presence it has seen change in
    /// the last week (by its own clock), even the most recently written says it was written more than a week before it
    /// was seen. A device whose presence never changes (lost, given away) says nothing either way, so it never holds
    /// compaction back, and neither does one read only once. What it read is remembered in the checkpoint
    /// (`SyncCheckpoint.presenceSightings`), so a change made while this device was off counts too.
    func clockLooksAhead(now: Date) -> Bool {
        guard let records = allPresence(now: now, includingRetired: true) else { return false }
        var sightings: [String: SyncPresenceSighting] = [:]
        for record in records {
            let known = state.presenceSightings?[record.deviceID]
            if let known, known.lastSeen == record.lastSeen { sightings[record.deviceID] = known; continue }
            // Written since this device last read it. (Presence never goes back; a record that does, restored from
            // somewhere, says nothing about the clock.)
            let written = known.map { record.lastSeen > $0.lastSeen } ?? false
            sightings[record.deviceID] = SyncPresenceSighting(lastSeen: record.lastSeen, changed: written ? now : nil)
        }
        state.presenceSightings = sightings.isEmpty ? nil : sightings
        let lags = sightings.values.compactMap { sighting -> TimeInterval? in
            guard let changed = sighting.changed, changed <= now, now.timeIntervalSince(changed) < Self.clockAheadTolerance else { return nil }
            return changed.timeIntervalSince(sighting.lastSeen)
        }
        return (lags.min() ?? 0) > Self.clockAheadTolerance
    }

    /// Presence of every other device seen in the last 30 days, or nil while one can't be read (still downloading, or
    /// written lately in a form this version can't read): compaction waits rather than act without knowing what it can do.
    func recentPresence(now: Date) -> [SyncDeviceRecord]? {
        let directory = remoteRoot.appendingPathComponent(SyncPresenceFiles.directory, isDirectory: true)
        guard fm.fileExists(atPath: directory.path) else { return [] }
        guard let urls = try? journalFiles(in: SyncPresenceFiles.directory) else { return nil }
        var records: [SyncDeviceRecord] = []
        for url in urls {
            guard SyncFiles.itemState(url) == .local else { try? cloud.requestDownload(url); return nil }
            if let bytes = try? SyncFiles.read(url, below: remoteRoot, cloud: cloud), let record = SyncPresenceFiles.decode(bytes),
               url.lastPathComponent == SyncPresenceFiles.fileName(for: record.deviceID) {
                if record.deviceID != deviceID, now.timeIntervalSince(record.lastSeen) < Self.recentDevice { records.append(record) }
                continue
            }
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if now.timeIntervalSince(written) < Self.recentDevice { return nil }
        }
        return records
    }

    /// The size of each entry, by ID (every copy of it: plaintext, and sealed under each key).
    func entrySizes(_ entries: [JournalEntry]) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for entry in entries {
            guard let id = entry.isSealed ? sealedNames[entry.path] : entry.name,
                  let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            sizes[id, default: 0] += Int64(size)
        }
        return sizes
    }

    /// Deletes pruned entries still in the sync folder, once every commit is in iCloud: a device that finds one gone then
    /// finds the commit that says why (or waits for it, never for the entry).
    func deletePrunedFiles(_ entries: [JournalEntry], report: inout CompactionReport) {
        guard compactionRecords.values.filter(\.record.isCommit).allSatisfy({ cloud.isUploaded($0.url) }) else { return }
        for entry in entries {
            guard let id = entry.isSealed ? sealedNames[entry.path] : entry.name, prunedIDs.contains(id),
                  SyncFiles.itemState(entry.url) != .absent else { continue }
            let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            deleteRemote(entry.url)
            report.deletedFiles += 1; report.deletedBytes += Int64(size)
        }
    }

    /// The manifest becomes version 3 before anything is deleted, so an earlier Daybook stops at it.
    func ensureCompactedManifest(_ now: Date) throws {
        let url = remoteRoot.appendingPathComponent("daybook-sync.json")
        let manifest = try SyncManifest.checked(SyncManifest.decode(SyncFiles.read(url, below: remoteRoot, cloud: cloud)))
        guard !manifest.isCompacted else { return }
        _ = try updateManifest { manifest in
            manifest.schemaVersion = SyncManifest.compactedSchemaVersion
            manifest.compaction = manifest.compaction ?? .init(since: now)
        }
    }

    /// Writes a compaction record (sealed under the current key in an encrypted library). What every device reads for
    /// itself: the courier doesn't carry it.
    @discardableResult
    func writeCompactionRecord(_ record: SyncCompactionRecord) throws -> CompactionEntry {
        try writeCompactionBytes(SyncEncoding.data(record), record: record)
    }

    private func writeCompactionBytes(_ bytes: Data, record: SyncCompactionRecord) throws -> CompactionEntry {
        let id = SyncDigest.sha256(data: bytes)
        let reported = courierWrites
        defer { courierWrites = reported }
        let path: String
        if let sealing {
            path = try writeSealed(bytes, id: id, kind: .compaction, key: sealing.current)
        } else {
            let folder = remoteRoot.appendingPathComponent(Self.compactionDirectory, isDirectory: true)
            try SyncFiles.noSymlinks(folder, below: remoteRoot)
            try LocalFiles.directory(folder)
            path = "\(Self.compactionDirectory)/\(id).json"
            try SyncFiles.coordinateWrite(remoteRoot.appendingPathComponent(path), below: remoteRoot) { target in
                if self.fm.fileExists(atPath: target.path) {
                    guard try Data(contentsOf: target) == bytes else { throw LibrarySyncError.invalidEvent(path) }
                } else { try LocalFiles.atomicWrite(bytes, to: target) }
            }
            ownJournalWrites.insert(path)
        }
        let url = remoteRoot.appendingPathComponent(path)
        let journal = sealing == nil
            ? JournalEntry(url: url, path: path, directory: Self.compactionDirectory, name: id, isSealed: false)
            : JournalEntry(url: url, path: path, directory: SealedKind.compaction.directory!, name: url.lastPathComponent, isSealed: true)
        let entry = CompactionEntry(entry: journal, id: id, record: record)
        compactionRecords[path] = entry
        if record.isProposal { pendingProposal = entry }
        return entry
    }

    /// Keeps the records few and readable with the current key: proposals carried out or replaced go; one still waiting
    /// is sealed again under the current key (an older key is retired later); commits are consolidated into one when
    /// there are too many, or when one isn't sealed under the current key. A record goes only once what replaces it is
    /// in iCloud.
    private func tidyCompactionRecords(_ policy: SyncCompactionPolicy, now: Date, report: inout CompactionReport) {
        let records = Array(compactionRecords.values)
        let commits = records.filter(\.record.isCommit)
        guard commits.allSatisfy({ cloud.isUploaded($0.url) }) else { return }
        let executed = Set(commits.compactMap(\.record.proposal))
        func readable(_ entry: CompactionEntry) -> Bool {
            guard let sealing else { return true }
            return entry.isSealed && sealedKeys[entry.path] == sealing.current.id
        }
        for entry in records where entry.record.isProposal {
            if executed.contains(entry.id) || (pendingProposal.map { $0.id != entry.id } ?? true) {
                removeCompactionRecord(entry)
            } else if !readable(entry), let bytes = try? readEntry(entry.entry, kind: .compaction).bytes,
                      let moved = try? writeCompactionBytes(bytes, record: entry.record), moved.path != entry.path, cloud.isUploaded(moved.url) {
                removeCompactionRecord(entry)
            }
        }
        let current = compactionRecords.values.filter(\.record.isCommit)
        guard current.count > policy.maximumCommits || current.contains(where: { !readable($0) }) else { return }
        guard let merged = try? writeCompactionRecord(SyncCompactionRecord(deviceID: deviceID, createdAt: now, pruned: prunedIDs.sorted())),
              cloud.isUploaded(merged.url) else { return }
        for entry in current where entry.path != merged.path { removeCompactionRecord(entry) }
        report.consolidated = true
    }

    private func removeCompactionRecord(_ entry: CompactionEntry) {
        deleteRemote(entry.url)
        compactionRecords[entry.path] = nil
    }

    /// The pending proposal was made long ago, or a conversation in it has a head that doesn't descend from its root (a
    /// device's concurrent edit, which keeps that device from acknowledging it): a new one replaces it.
    private func proposalIsStale(_ input: CompactionInput, now: Date) -> Bool {
        guard let proposal = pendingProposal, let roots = proposal.record.roots else { return true }
        // So is one dated more than a week after now: proposed by a clock that was ahead.
        let age = now.timeIntervalSince(proposal.record.createdAt)
        if age >= Self.proposalLifetime || age < -Self.clockAheadTolerance { return true }
        let grouped = Dictionary(grouping: input.events.keys, by: { input.events[$0]!.meetingID })
        for (meeting, root) in roots {
            guard let id = UUID(uuidString: meeting), !input.deleted.contains(id), let ids = grouped[id] else { continue }
            let heads = heads(ids: ids, parents: { input.events[$0]?.parents ?? [] })
            if !heads.allSatisfy({ $0 == root || ancestorIDs($0, events: input.events).contains(root) }) { return true }
        }
        return false
    }

    /// Proposes compacting each live conversation with one head and history before it, and each deleted conversation with
    /// history beside its deletions, when there's enough to gain.
    private func propose(_ input: CompactionInput, sizes: [String: Int64], policy: SyncCompactionPolicy, now: Date, report: inout CompactionReport) {
        var roots: [String: String] = [:], deletions: [String] = []
        var older = Set<String>()
        let grouped = Dictionary(grouping: input.events.keys, by: { input.events[$0]!.meetingID })
        for (meeting, ids) in grouped {
            if input.deleted.contains(meeting) {
                let history = ids.filter { input.events[$0]?.deleted == false }
                if !history.isEmpty { deletions.append(meeting.uuidString); older.formUnion(history) }
                continue
            }
            let heads = heads(ids: ids, parents: { input.events[$0]?.parents ?? [] })
            guard heads.count == 1, let head = heads.first else { continue }
            let history = prunableHistory(before: head, events: input.events)
            guard !history.isEmpty else { continue }
            roots[meeting.uuidString] = head
            older.formUnion(history)
        }
        older.subtract(prunedIDs)
        let bytes = older.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        guard !older.isEmpty, older.count >= policy.minimumEntries || bytes >= policy.minimumBytes else { return }
        let proposal = SyncCompactionRecord(deviceID: deviceID, createdAt: now, roots: roots, deletions: deletions.isEmpty ? nil : deletions.sorted())
        if (try? writeCompactionRecord(proposal)) != nil { report.proposed = true }
    }

    /// What of a conversation's history before `root` can go: its ancestors still here, but for any that alone names a
    /// highlight sidecar (`mergedAssets` takes a conversation's sidecars from all its events), nearest the root first.
    func prunableHistory(before root: String, events: [String: SyncEventHeader]) -> Set<String> {
        func sidecars(_ id: String) -> Set<String> {
            Set((events[id]?.assets ?? []).filter { $0.relativePath.contains(".highlights-") }.map(\.sha256))
        }
        var named = sidecars(root), prunable = Set<String>(), seen: Set<String> = [root]
        var queue = (events[root]?.parents ?? []).sorted(), next = 0
        while next < queue.count {
            let id = queue[next]; next += 1
            guard seen.insert(id).inserted, events[id] != nil else { continue }
            let own = sidecars(id)
            if own.isSubset(of: named) { prunable.insert(id) } else { named.formUnion(own) }
            queue += (events[id]?.parents ?? []).sorted()
        }
        return prunable
    }

    /// Everything compaction remembers, for another library.
    func forgetCompaction() {
        compactionRecords = [:]; compactionPaths = []; prunedIDs = []; pendingProposal = nil; compactionReadComplete = false; lastCompaction = nil
        prunedEntryPaths = []
    }
}
