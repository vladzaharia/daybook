import Foundation

public struct SyncResult: Sendable {
    /// Acknowledge only after every returned change is durably saved locally.
    public var checkpointID: UUID
    public var meetings: [Meeting]
    public var deletedMeetingIDs: Set<UUID>
    public var metadataVersions: [Data]
    public var warnings: [String]
    public var pendingDownloads: Int
    public var pendingUploads: Int
    public var publishedEvents: Int
    /// Conversations the caller must save: returned snapshots that differ from the copy it supplied (or that it
    /// didn't supply). A controller that supplies its whole library can skip merging every other meeting.
    public var changedMeetingIDs: Set<UUID> = []
    /// On an on-demand replica, valid synced tracks whose audio is not on this device yet, by meeting.
    /// This is a normal state, never an error, and is not counted in `pendingDownloads`. Empty when eager.
    public var notLocalAudio: [UUID: Set<UUID>] = [:]
    /// Journal reads or audio copies left for a later pass because this pass reached its `SyncPassLimits`.
    public var deferredItems: Int = 0
    /// Journal files this replica wrote into the sync folder since the last pass that returned: events, metadata, and
    /// audio objects it copied there. A courier sends them ahead of iCloud Drive (docs/icloud-sync.md, "Courier").
    public var writtenFiles: [SyncJournalFile] = []
    public var hasPendingTransfers: Bool { pendingDownloads > 0 || pendingUploads > 0 }
    /// Synchronize again soon: this pass stopped at its work limits.
    public var hasMoreWork: Bool { deferredItems > 0 }
}

/// What a pass exchanges.
public enum SyncPassScope: Sendable {
    /// Conversations and library settings.
    case full
    /// Library settings only (`LibrarySyncEngine.synchronize`).
    case metadataOnly
}

public enum LibrarySyncError: LocalizedError, Equatable {
    case unsafeLocation, invalidManifest, manifestConflict, unsupportedVersion(Int), invalidEvent(String), invalidBlob(String), missingLocalAudio(String), corruptState, invalidCheckpoint
    /// No library is visible in the sync folder yet, and iCloud hasn't finished listing it: one may be there.
    case waitingForICloud
    /// The library is encrypted and this device doesn't hold its current key (by ID, hex) yet. Nothing was read or
    /// written; local edits wait. Every pass checks the keychain again.
    case keyUnavailable(String)
    /// This device synced an encrypted library here, and the library there now isn't encrypted: sync pauses rather
    /// than publish plaintext (`SealingMemory`).
    case sealingRemoved
    /// This build can't keep a library key (no keychain group: an unsigned or ad hoc build).
    case keyStoreUnavailable
    public var errorDescription: String? {
        switch self {
        case .unsafeLocation: return "The sync folder must be separate from the local library and cannot contain symbolic links."
        case .invalidManifest: return "The selected folder has an invalid Daybook sync manifest. Its files were not replaced."
        case .manifestConflict: return "iCloud has two conflicting copies of this library, so sync is paused."
        case .unsupportedVersion(let version): return "This library was synced by a newer Daybook (version \(version)). Update Daybook to sync."
        case .invalidEvent(let name): return "A synced change couldn’t be read: \(name)."
        case .invalidBlob(let name): return "A synced recording was damaged: \(name)."
        case .missingLocalAudio(let name): return "The original recording is missing or changed: \(name)."
        case .corruptState: return "Sync stopped: this device’s sync record is unreadable."
        case .invalidCheckpoint: return "Sync again to finish."
        case .waitingForICloud: return "Waiting for iCloud…"
        case .keyUnavailable: return "Your library in iCloud is encrypted. Waiting for its key from iCloud Keychain."
        case .sealingRemoved: return "The library in iCloud is no longer encrypted."
        case .keyStoreUnavailable: return "This build of Daybook can’t keep encryption keys."
        }
    }
}

/// A coordinated, immutable file transport usable with an explicitly selected iCloud Drive folder
/// or a native ubiquity container. It never moves the live library into cloud storage.
public actor LibrarySyncEngine {
    public nonisolated let localRoot: URL
    public nonisolated let remoteRoot: URL
    public nonisolated let deviceID: String
    public nonisolated let audioPolicy: SyncAudioPolicy
    let cloud: SyncCloudFiles
    let presenceRefreshInterval: TimeInterval
    var device: SyncDeviceIdentity?
    var audioCachePolicy: AudioCachePolicy?
    let fm = FileManager.default
    private let decoder = JSONDecoder()
    private var checkpointURL: URL?
    private var basesURL: URL?
    private var mayCreateLibrary: Bool
    private var state = SyncCheckpoint()
    var verifiedAssets: [String: VerifiedAsset] = [:]
    // Journal records are immutable and content-addressed: once read and validated they never need
    // reading again. The directory listing each pass remains the source of truth for membership.
    // Every event's header stays in memory; a snapshot is kept only while passes use it (a head, or the
    // base of a merge) and is otherwise read again when needed, so memory follows the library, not its history.
    var eventCache: [String: SyncEventHeader] = [:]
    private var snapshotCache: [String: Meeting] = [:]
    private var snapshotsUsed: Set<String> = []
    var metadataCache: [String: SyncMetadataRecord] = [:]
    /// Journal entries that can't be read (a newer format, damage), with the warning to show. Never retried
    /// in this process: an entry's content can't change. A relaunch (perhaps after an update) reads them again.
    var unreadableJournal: [String: String] = [:]
    /// Paths of the journal files this pass wrote, so it doesn't count them as remote changes.
    var ownJournalWrites: Set<String> = []
    /// Whether each event or one of its ancestors carries photos (`resolvedSnapshot`).
    private var photoLineage: [String: Bool] = [:]
    /// Files written into the sync folder that no returned pass has reported yet (`SyncResult.writtenFiles`).
    var courierWrites: [String: SyncJournalFile] = [:]
    /// Devices that wrote the journal entries seen by the last pass, including ones without presence.
    var journalDeviceIDs: Set<String> = []
    /// Journal file names seen by the last pass that finished with nothing pending or deferred.
    var settledJournalListing: Set<String>?
    var presenceWritten: (record: SyncDeviceRecord, at: Date)?
    nonisolated let installation: String?
    /// What this device is doing, for its presence record (`publishActivity`).
    var activity: SyncDeviceActivity?
    /// Another device writes presence under this device ID: this one should take a new identity.
    public internal(set) var sharesIdentity = false
    /// The sync library's ID, from its manifest, once a pass has read it. The iPhone's local link
    /// tags its Bonjour browsing with it (docs/link.md, "Discovery").
    public internal(set) var libraryID: UUID?
    var audioIndexStorage: AudioCacheIndex?
    var audioIndexDirty = false
    /// Where this device keeps library keys (`SyncReplicaConfiguration.keyStore`).
    let keyStore: (any LibraryKeyStore)?
    /// An encrypted library's manifest and the keys held here, once a pass has read it (nil: plaintext, or no key).
    var sealing: SealingState?
    /// The current key (hex) of an encrypted library this device can't open yet.
    public internal(set) var waitingForKey: String?
    /// Sealed entries already opened, by path: the entry ID (SHA-256 of the plaintext record) each holds, and its key.
    var sealedNames: [String: String] = [:]
    var sealedKeys: [String: Data] = [:]
    /// Where each event was read, by ID, to read its snapshot again (sealed files have other names).
    var journalLocations: [String: URL] = [:]
    /// Sealed files this process read back and found whole (the sealer's retirement needs it).
    var sealerVerified: Set<String> = []
    /// What the sealer reported on the last pass that ran it.
    public internal(set) var sealerProgress: SealerProgress?
    /// The sealer's clock (tests move it past the grace periods).
    var sealerClock: @Sendable () -> Date = { Date() }
    func setSealerClock(_ clock: @escaping @Sendable () -> Date) { sealerClock = clock }

    /// `waitsForListing`: in the iCloud container, a library (`daybook-sync.json`) isn't created until
    /// `listingGathered()` says iCloud has listed what's there, so a fresh device doesn't start a second library
    /// beside one it can't see yet.
    /// `installation` (a random ID for this installation) goes in the presence record, so two devices that share a
    /// device ID can tell (`sharesIdentity`).
    public init(localRoot: URL, remoteRoot: URL, deviceID: String, replica: SyncReplicaConfiguration = SyncReplicaConfiguration(),
                waitsForListing: Bool = false, installation: String? = nil) throws {
        mayCreateLibrary = !waitsForListing
        self.installation = installation
        self.localRoot = localRoot.standardizedFileURL
        self.remoteRoot = remoteRoot.standardizedFileURL
        self.deviceID = deviceID
        audioPolicy = replica.audioPolicy; cloud = replica.cloud; device = replica.device; keyStore = replica.keyStore
        audioCachePolicy = replica.audioCache; presenceRefreshInterval = replica.presenceRefreshInterval
        let local = localRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let remote = remoteRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard !deviceID.isEmpty, local != remote, !local.hasPrefix(remote + "/"), !remote.hasPrefix(local + "/") else { throw LibrarySyncError.unsafeLocation }
        let syncDirectory = self.localRoot.appendingPathComponent("Sync", isDirectory: true)
        try SyncFiles.noSymlinks(syncDirectory, below: self.localRoot)
        try LocalFiles.directory(syncDirectory)
        try SyncFiles.noSymlinks(self.remoteRoot, below: self.remoteRoot)
    }

    /// One synchronization pass: read the journal, publish local changes, and return merged snapshots to
    /// save before `acknowledge`. `limits` bounds the pass for phones; leftover work sets `hasMoreWork`.
    /// Cancelling the calling task stops the pass; an unacknowledged pull is offered again next time.
    /// `protecting` are conversations this device is recording or processing into: a deletion from another
    /// device waits until they're no longer protected, and what this device added is then kept (see below).
    /// `scope` `.metadataOnly` exchanges library settings alone (a device busy recording).
    public func synchronize(meetings: [Meeting], deletedMeetingIDs: Set<UUID> = [], libraryMetadata: Data? = nil,
                            limits: SyncPassLimits = .unlimited, protecting: Set<UUID> = [], scope: SyncPassScope = .full) async throws -> SyncResult {
        try Task.checkCancellation()
        let manifest = try prepareRemote()
        libraryID = manifest.libraryID
        // An encrypted library whose key isn't here: nothing is read or written (the library never receives plaintext
        // from this device), and local edits wait. Presence says this device is waiting for the key.
        do { try loadSealing(manifest) } catch {
            if !Task.isCancelled { try? writePresence(now: Date(), force: false) }
            throw error
        }
        try loadCheckpoint(libraryID: manifest.libraryID, superseding: manifest.supersedes ?? [])
        if scope == .metadataOnly { return try synchronizeMetadataOnly(libraryMetadata, limits: limits) }
        var budget = SyncPassBudget(limits)
        var warnings: [String] = []
        var pendingDownloads = 0
        var pendingUploads = 0
        var published = 0
        var unreadJournalFiles = 0
        var metadataIncomplete = false
        var failedPublications = Set<UUID>()
        var events: [String: SyncEventHeader] = [:]
        var metadata: [String: SyncMetadataRecord] = [:]
        ownJournalWrites = []
        let eventEntries = try journalEntries(.event), metadataEntries = try journalEntries(.metadata)
        for entry in eventEntries {
            try Task.checkCancellation()
            // An entry's ID is its name when plaintext; a sealed one's is known once it has been opened.
            let name = entry.isSealed ? sealedNames[entry.path] : entry.name
            if let name, let cached = eventCache[name] { events[name] = cached; continue }
            let unreadableKey = entry.isSealed ? entry.path : entry.name
            if let reason = unreadableJournal[unreadableKey] { warnings.append(reason); unreadJournalFiles += 1; continue }
            guard budget.admitJournalRead() else { continue }
            do {
                let (hash, bytes) = try readEntry(entry, kind: .event)
                // Where to read its snapshot again: preferably sealed under the current key, which outlives the rest.
                if entry.isSealed, journalLocations[hash] == nil || sealedKeys[entry.path] == sealing?.current.id { journalLocations[hash] = entry.url }
                // The same entry, sealed and from before (or under two keys), is one entry.
                if let cached = eventCache[hash] { events[hash] = cached; continue }
                try requireSupportedVersion(bytes)
                let event = try decoder.decode(SyncEventRecord.self, from: bytes)
                guard event.schemaVersion == 1, event.parents.allSatisfy(SyncFiles.isHash),
                      event.deleted != (event.snapshot != nil), event.snapshot?.id == event.meetingID || event.deleted else { throw LibrarySyncError.invalidEvent(entry.url.lastPathComponent) }
                if let snapshot = event.snapshot { try validate(snapshot: snapshot, assets: event.assets) }
                let header = SyncEventHeader(event)
                events[hash] = header; eventCache[hash] = header
            } catch is SyncPendingDownload { pendingDownloads += 1; unreadJournalFiles += 1 }
            catch let error as CancellationError { throw error }
            catch where Self.isPermanent(error) { warnings.append(markUnreadable(unreadableKey, error)); unreadJournalFiles += 1 }
            catch { warnings.append(error.localizedDescription); pendingDownloads += 1; unreadJournalFiles += 1 }
        }
        let metadataRead = try readMetadata(metadataEntries, budget: &budget, warnings: &warnings)
        metadata = metadataRead.records
        metadataIncomplete = metadataRead.incomplete
        pendingDownloads += metadataRead.downloading; unreadJournalFiles += metadataRead.downloading
        journalDeviceIDs = Set(events.values.map(\.deviceID)).union(metadata.values.map(\.deviceID))
        // A parent belongs to the same conversation. Malformed cross-conversation edges
        // cannot provide ancestry or hide a legitimate head.
        for (id, event) in events where event.parents.contains(where: { events[$0].map { $0.meetingID != event.meetingID } ?? false }) {
            events.removeValue(forKey: id); eventCache.removeValue(forKey: id)
            warnings.append(markUnreadable(id, LibrarySyncError.invalidEvent(id))); unreadJournalFiles += 1
        }
        // A parent that couldn't be read holds back its descendants until an update can read it; that isn't a
        // download to wait for. Only parents not listed or not downloaded yet are. An encrypted library keeps only the
        // deletion of a deleted conversation (LibrarySyncSealer.swift), so its parents aren't waited for there.
        let deletedConversations = sealing == nil ? [] : Set(events.values.filter(\.deleted).map(\.meetingID))
        let unknownParents = Set(events.values.filter { !deletedConversations.contains($0.meetingID) }.flatMap(\.parents))
            .subtracting(events.keys).filter { unreadableJournal[$0] == nil }
        if !unknownParents.isEmpty {
            pendingDownloads += unknownParents.count
            warnings.append("Some changes are waiting for the next sync.")
        }

        // Assets any readable event references. An on-demand replica can publish a track whose audio it
        // never downloaded (or evicted) by reference to one of these.
        let journalAssets = Set(events.values.flatMap { $0.assets.map(\.sha256) })
        var deletedHere = deletedMeetingIDs
        let trash = localRoot.appendingPathComponent("Trash", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
            deletedHere.formUnion(children.compactMap { UUID(uuidString: $0.lastPathComponent) })
        }
        var deletes = deletedHere.union(state.deletedIDs)
        // Every publication of a pass shares one sequence number, and the checkpoint is saved once after them. A
        // pass interrupted between writing an entry and saving (a crash, a cancelled background pass) writes the
        // same bytes again next time for anything unchanged, so the entry it left is the one it publishes.
        let passSequence = state.sequence + 1
        let journalIncomplete = unreadJournalFiles > 0 || budget.deferred > 0
        do {
            // Publish changes against the last applied heads, not newly observed remote heads. This is what
            // distinguishes a genuine offline concurrent edit from a sequential edit after a pull.
            for supplied in meetings.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                try Task.checkCancellation()
                let key = supplied.id.uuidString
                guard !state.deletedIDs.contains(supplied.id) else { continue }
                // Cheap equality first: most meetings are unchanged on most passes.
                let pendingBase = state.pending?.changedBases?[key]
                // With a publication of this conversation not applied yet (the pass held it back), the base is behind
                // the journal: matching the base is then a revert, which must be published too.
                let baseIsCurrent = state.submittedHashes[key] == nil
                if (baseIsCurrent && supplied == state.bases[key]) || pendingBase == supplied { continue }
                let fingerprint = try hash(supplied)
                guard fingerprint != state.submittedHashes[key], !baseIsCurrent || fingerprint != state.bases[key].flatMap({ try? hash($0) }),
                      fingerprint != pendingBase.flatMap({ try? hash($0) }) else { continue }
                do {
                    let prepared = try prepareUpload(supplied, journalAssets: journalAssets)
                    pendingUploads += prepared.pendingUploads
                    let event = SyncEventRecord(meetingID: supplied.id, deviceID: deviceID, sequence: passSequence,
                        parents: (state.heads[key] ?? []).sorted(), snapshot: prepared.meeting, deleted: false, assets: prepared.assets)
                    let id = try writeRecord(event, directory: "Events")
                    events[id] = SyncEventHeader(event); eventCache[id] = events[id]; snapshotCache[id] = prepared.meeting
                    state.submittedHashes[key] = fingerprint
                    state.heads[key] = [id]
                    published += 1
                } catch is SyncPendingDownload { pendingDownloads += 1; pendingUploads += 1; failedPublications.insert(supplied.id) }
                catch let error as CancellationError { throw error }
                catch { warnings.append(error.localizedDescription); pendingUploads += 1; failedPublications.insert(supplied.id) }
            }
            // A deletion this replica already knows about has an event in the journal. When part of the journal
            // is unread (still downloading, or deferred by limits), don't mistake that for a missing tombstone.
            for id in deletes.sorted(by: { $0.uuidString < $1.uuidString })
            where !events.values.contains(where: { $0.meetingID == id && $0.deleted }) && !(journalIncomplete && state.deletedIDs.contains(id)) {
                let event = SyncEventRecord(meetingID: id, deviceID: deviceID, sequence: passSequence,
                    parents: (state.heads[id.uuidString] ?? []).sorted(), snapshot: nil, deleted: true, assets: [])
                let eventID = try writeRecord(event, directory: "Events")
                events[eventID] = SyncEventHeader(event); eventCache[eventID] = events[eventID]; state.heads[id.uuidString] = [eventID]
                published += 1
            }
            deletes.formUnion(events.values.filter(\.deleted).map(\.meetingID))

            if let libraryMetadata {
                let fingerprint = SyncDigest.sha256(data: libraryMetadata)
                if fingerprint != state.metadataSubmittedHash {
                    let record = SyncMetadataRecord(deviceID: deviceID, sequence: passSequence, parents: state.metadataHeads.sorted(), data: libraryMetadata)
                    let id = try writeRecord(record, directory: "Metadata")
                    metadata[id] = record; metadataCache[id] = record; state.metadataSubmittedHash = fingerprint; state.metadataHeads = [id]
                    published += 1
                }
            }
            // Deletions made here are recorded as synced with their tombstones, so a restore can tell at once.
            let newlyDeleted = deletedHere.subtracting(state.deletedIDs)
            state.deletedIDs.formUnion(deletedHere)
            if published > 0 { state.sequence = passSequence }
            if published > 0 || !newlyDeleted.isEmpty { try saveCheckpoint() }
        } catch {
            // Keep what was published before the pass stopped, so the next one builds on it.
            if published > 0 { state.sequence = passSequence; try? saveCheckpoint() }
            throw error
        }

        var output = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = Set<UUID>()
        var notLocalAudio: [UUID: Set<UUID>] = [:]
        var baseChanges: [String: Meeting] = [:]
        var removedBases = Set<String>()
        var proposedHeads = state.heads
        let completeAncestors = try completeAncestorIDs(events: events, budget: &budget)
        // Events whose only missing ancestors can't be read (a newer format): nothing will arrive to complete them.
        let unreadable = Set(unreadableJournal.keys)
        let settledAncestors = unreadable.isEmpty ? completeAncestors : try completeAncestorIDs(events: events, budget: &budget, present: unreadable)
        var memo = MergeMemo()
        /// What each conversation's merge uses, for the sealer of an encrypted library.
        var liveAssets: [UUID: [SyncAsset]] = [:]
        /// Deleted elsewhere but kept here this pass (protected, or waiting to read what the deletion saw).
        var held = Set<UUID>()
        var examinedDeletions = Set<UUID>()
        let grouped = Dictionary(grouping: events.keys, by: { events[$0]!.meetingID })
        for (meetingID, ids) in grouped.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            try Task.checkCancellation()
            guard !budget.timeExceeded else { budget.deferred += 1; continue }
            if deletes.contains(meetingID) {
                examinedDeletions.insert(meetingID)
                // Deleted on another device while this one still has it. A conversation being recorded or
                // processed here waits; then anything it holds that the deletion never saw (recordings, photos,
                // bookmarks, notes) is kept as a new conversation instead of disappearing with it.
                if let local = output[meetingID], !deletedHere.contains(meetingID) {
                    if protecting.contains(meetingID) { held.insert(meetingID); continue }
                    do {
                        if let fork = try keepContentAddedAfterDeletion(local, deletions: ids.filter { events[$0]?.deleted == true },
                                                                       events: events, memo: &memo, supplied: output) {
                            output[fork.id] = fork; changed.insert(fork.id)
                            if audioPolicy == .onDemand {
                                let missing = Set(fork.tracks.filter { availability(of: $0, in: fork.id) == .notLocal }.map(\.id))
                                if !missing.isEmpty { notLocalAudio[fork.id] = missing }
                            }
                            warnings.append("“\(local.title)” was deleted on another device after it changed here, so it’s kept as a new conversation.")
                        }
                    } catch is SyncPendingDownload { pendingDownloads += 1; held.insert(meetingID); continue }
                    catch let error as CancellationError { throw error }
                    catch { warnings.append(error.localizedDescription); held.insert(meetingID); continue }
                } else if output[meetingID] == nil {
                    trashOrphanFolder(meetingID)
                }
                output.removeValue(forKey: meetingID)
                if ids.contains(where: { events[$0]?.deleted == false }), state.bases[meetingID.uuidString] != nil {
                    // The immutable journal remains a recovery archive for edit/delete races.
                    removedBases.insert(meetingID.uuidString)
                }
                proposedHeads[meetingID.uuidString] = heads(ids: ids, parents: { events[$0]?.parents ?? [] })
                continue
            }
            // Failed uploads must never let an older remote snapshot replace unsent local edits.
            guard !failedPublications.contains(meetingID) else { continue }
            let allHeads = heads(ids: ids, parents: { events[$0]?.parents ?? [] })
            // A head waiting for a download holds the conversation. One that descends from an entry this version
            // can't read is set aside: the conversation applies as far as this version can read it.
            guard !allHeads.isEmpty, allHeads.allSatisfy(settledAncestors.contains) else { continue }
            let headIDs = allHeads.filter(completeAncestors.contains)
            guard !headIDs.isEmpty else { continue }
            // With part of the journal unread (downloading, or deferred by limits), a conversation whose applied
            // heads weren't read this pass would roll back to an older snapshot. It waits for a fuller read.
            if journalIncomplete, let applied = state.heads[meetingID.uuidString], !applied.allSatisfy({ events[$0] != nil }) { continue }
            memo.warnings = []
            do {
                guard let merged = try mergedSnapshot(of: headIDs, events: events, memo: &memo) else { continue }
                warnings += memo.warnings
                let assets = mergedAssets(for: merged, eventIDs: ids, events: events)
                try validate(snapshot: merged, assets: assets)
                liveAssets[meetingID] = assets
                switch audioPolicy {
                case .eager:
                    try hydrate(assets, meetingID: meetingID, warnings: &warnings, budget: &budget)
                case .onDemand:
                    // Audio is never required to apply or acknowledge. Tracks stay valid; their audio is
                    // fetched on demand, so nothing here reads, downloads, or judges a blob.
                    try requireNotTrashed(meetingID)
                    let missing = Set(merged.tracks.filter { availability(of: $0, in: meetingID) == .notLocal }.map(\.id))
                    if !missing.isEmpty { notLocalAudio[meetingID] = missing }
                }
                if output[meetingID] != merged { changed.insert(meetingID) }
                output[meetingID] = merged
                if state.bases[meetingID.uuidString] != merged { baseChanges[meetingID.uuidString] = merged }
                proposedHeads[meetingID.uuidString] = headIDs
            } catch is SyncPendingDownload { pendingDownloads += 1 }
            catch is SyncDeferredWork { budget.deferred += 1 }
            catch let error as CancellationError { throw error }
            catch { warnings.append(error.localizedDescription); pendingDownloads += 1 }
        }
        state.deletedIDs.formUnion(deletes)
        // A deleted conversation still here whose journal wasn't examined this pass (deferred by limits, or its
        // entries still unread) waits for a pass that can tell whether it holds anything the deletion never saw.
        for id in deletes where output[id] != nil && !deletedHere.contains(id) && !examinedDeletions.contains(id)
            && (grouped[id] != nil || journalIncomplete) { held.insert(id) }
        deletes.subtract(held)
        for id in deletes { output.removeValue(forKey: id); changed.remove(id); notLocalAudio.removeValue(forKey: id) }
        var sourceMeetings: [String: Set<UUID>] = [:]
        for meeting in output.values {
            for track in meeting.tracks where !track.sha256.isEmpty { sourceMeetings[track.sha256, default: []].insert(meeting.id) }
        }
        if sourceMeetings.values.contains(where: { $0.count > 1 }) {
            warnings.append("The same recording is in more than one conversation. They stay separate.")
        }
        let settings = metadataVersions(metadata, incomplete: metadataIncomplete, warnings: &warnings, pendingDownloads: &pendingDownloads)
        let metadataHeads = settings.heads, versions = settings.versions
        let checkpointID = UUID()
        try Task.checkCancellation()
        state.pending = SyncPendingApply(id: checkpointID, heads: proposedHeads, metadataHeads: settings.applied ? metadataHeads : state.metadataHeads,
            changedBases: baseChanges, removedBases: removedBases.sorted())
        try saveCheckpoint()
        retainCaches(heads: Set(proposedHeads.values.joined()).union(state.heads.values.joined()),
                     metadataHeads: Set(metadataHeads).union(state.metadataHeads))
        // An encrypted library: seal what's live from before (or under an older key), and retire what's no longer
        // needed once it's safe. Nothing here changes what this pass returns.
        if sealing != nil, !Task.isCancelled {
            let liveConversations = Set(grouped.keys).subtracting(deletes)
            let complete = pendingDownloads == 0 && budget.deferred == 0 && !journalIncomplete && !metadataIncomplete
                && liveConversations.isSubset(of: liveAssets.keys)
            sealerProgress = runSealer(SealerInput(events: events, metadata: metadata, eventEntries: eventEntries, metadataEntries: metadataEntries,
                                                   deleted: deletes, liveAssets: liveAssets, complete: complete), budget: &budget, now: sealerClock())
        }
        // A coordinated local write is not necessarily uploaded to iCloud yet.
        pendingUploads += try countPendingCloudUploads()
        try saveAudioIndexIfNeeded()
        // Courier deliveries the sync folder now holds, downloaded and identical, aren't needed any more.
        pruneCourierInbox()
        let listing = Set((eventEntries + metadataEntries).map(\.path)).union(ownJournalWrites)
        settledJournalListing = pendingDownloads == 0 && budget.deferred == 0 ? listing : nil
        // Presence is advisory: failing to refresh it never fails the pass.
        if !Task.isCancelled { try? writePresence(now: Date(), force: false) }
        let written = courierWrites.values.sorted { $0.path < $1.path }
        courierWrites = [:]
        return SyncResult(checkpointID: checkpointID, meetings: output.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date },
            deletedMeetingIDs: deletes, metadataVersions: versions, warnings: Array(Set(warnings)).sorted(),
            pendingDownloads: pendingDownloads, pendingUploads: pendingUploads, publishedEvents: published,
            changedMeetingIDs: changed, notLocalAudio: notLocalAudio, deferredItems: budget.deferred, writtenFiles: written)
    }

    /// Reads the library settings versions, first-time reads within `budget`.
    private func readMetadata(_ entries: [JournalEntry], budget: inout SyncPassBudget, warnings: inout [String])
        throws -> (records: [String: SyncMetadataRecord], incomplete: Bool, downloading: Int) {
        var metadata: [String: SyncMetadataRecord] = [:]
        var incomplete = false, downloading = 0
        for entry in entries {
            try Task.checkCancellation()
            let name = entry.isSealed ? sealedNames[entry.path] : entry.name
            if let name, let cached = metadataCache[name] { metadata[name] = cached; continue }
            let unreadableKey = entry.isSealed ? entry.path : entry.name
            if let reason = unreadableJournal[unreadableKey] { warnings.append(reason); continue }
            guard budget.admitJournalRead() else { incomplete = true; continue }
            do {
                let (hash, bytes) = try readEntry(entry, kind: .metadata)
                if let cached = metadataCache[hash] { metadata[hash] = cached; continue }
                try requireSupportedVersion(bytes)
                let record = try decoder.decode(SyncMetadataRecord.self, from: bytes)
                guard record.schemaVersion == 1, record.parents.allSatisfy(SyncFiles.isHash) else { throw LibrarySyncError.invalidEvent(entry.url.lastPathComponent) }
                // Library settings a newer Daybook wrote in a format this one can't merge stay out of the heads here;
                // they stay heads for the devices that read them, since nothing here is ever published over them.
                try requireSupportedVersion(record.data)
                metadata[hash] = record; metadataCache[hash] = record
            } catch is SyncPendingDownload { downloading += 1; incomplete = true }
            catch let error as CancellationError { throw error }
            catch where Self.isPermanent(error) { warnings.append(markUnreadable(unreadableKey, error)) }
            catch { warnings.append(error.localizedDescription); downloading += 1; incomplete = true }
        }
        return (metadata, incomplete, downloading)
    }

    /// The settings versions to offer: the readable heads. Library settings merge item by item, last change wins, so
    /// the readable heads merge on their own: a parent that can't be read (a newer format) doesn't hold them back. One
    /// still downloading does, as does a partial read, whose heads could be older than those already applied.
    private func metadataVersions(_ metadata: [String: SyncMetadataRecord], incomplete: Bool, warnings: inout [String],
                                  pendingDownloads: inout Int) -> (heads: [String], versions: [Data], applied: Bool) {
        let metadataHeads = heads(ids: Array(metadata.keys), parents: { metadata[$0]?.parents ?? [] })
        let missingParents = Set(metadata.values.flatMap(\.parents)).subtracting(metadata.keys).filter { unreadableJournal[$0] == nil }
        if !missingParents.isEmpty {
            pendingDownloads += missingParents.count
            warnings.append("Folders and templates are waiting for the next sync.")
            return (metadataHeads, [], false)
        }
        if incomplete { return (metadataHeads, [], false) }
        return (metadataHeads, metadataHeads.compactMap { metadata[$0]?.data }, true)
    }

    /// A pass over library settings only (recorder ownership, handoffs, folders, templates, vocabulary): for a device
    /// busy recording, so another device's handoff request or claim is seen without touching any conversation.
    private func synchronizeMetadataOnly(_ libraryMetadata: Data?, limits: SyncPassLimits) throws -> SyncResult {
        var budget = SyncPassBudget(limits)
        var warnings: [String] = []
        var pendingDownloads = 0, published = 0
        ownJournalWrites = []
        let read = try readMetadata(try journalEntries(.metadata), budget: &budget, warnings: &warnings)
        var metadata = read.records
        pendingDownloads += read.downloading
        if let libraryMetadata, SyncDigest.sha256(data: libraryMetadata) != state.metadataSubmittedHash {
            let sequence = state.sequence + 1
            let record = SyncMetadataRecord(deviceID: deviceID, sequence: sequence, parents: state.metadataHeads.sorted(), data: libraryMetadata)
            let id = try writeRecord(record, directory: "Metadata")
            metadata[id] = record; metadataCache[id] = record
            state.metadataSubmittedHash = SyncDigest.sha256(data: libraryMetadata); state.metadataHeads = [id]; state.sequence = sequence
            published += 1
            try saveCheckpoint()
        }
        let settings = metadataVersions(metadata, incomplete: read.incomplete, warnings: &warnings, pendingDownloads: &pendingDownloads)
        let checkpointID = UUID()
        try Task.checkCancellation()
        state.pending = SyncPendingApply(id: checkpointID, heads: state.heads, metadataHeads: settings.applied ? settings.heads : state.metadataHeads,
                                         changedBases: [:], removedBases: [])
        try saveCheckpoint()
        // Conversations weren't read: the next full pass decides what's new.
        settledJournalListing = nil
        if !Task.isCancelled { try? writePresence(now: Date(), force: false) }
        let written = courierWrites.values.sorted { $0.path < $1.path }
        courierWrites = [:]
        return SyncResult(checkpointID: checkpointID, meetings: [], deletedMeetingIDs: [], metadataVersions: settings.versions,
                          warnings: Array(Set(warnings)).sorted(), pendingDownloads: pendingDownloads, pendingUploads: 0,
                          publishedEvents: published, deferredItems: budget.deferred, writtenFiles: written)
    }

    /// A conversation deleted elsewhere that holds what the deletion never saw becomes a new conversation with
    /// it all, files included, named deterministically by the deletion so every device that keeps it makes the
    /// same one. Nil when there's nothing new to keep (the deletion simply applies).
    private func keepContentAddedAfterDeletion(_ local: Meeting, deletions: [String], events: [String: SyncEventHeader],
                                               memo: inout MergeMemo, supplied: [UUID: Meeting]) throws -> Meeting? {
        // The deletion itself, and what the device that deleted it had (the merge of its parents), must be read
        // before anything is judged new: a parent still downloading or deferred holds the conversation.
        guard !deletions.isEmpty else { throw SyncPendingDownload() }
        let allParents = Set(deletions.flatMap { events[$0]?.parents ?? [] })
        if allParents.contains(where: { events[$0] == nil && unreadableJournal[$0] == nil }) { throw SyncPendingDownload() }
        let parents = allParents.filter { events[$0]?.deleted == false }
        // A parent this version can't read: what the deletion saw is unknown, so the deletion simply applies.
        if parents.count < allParents.filter({ events[$0]?.deleted != true }).count { return nil }
        let seen = parents.isEmpty ? nil : try mergedSnapshot(of: Array(parents), events: events, memo: &memo)
        guard local.hasContent(notIn: seen) else { return nil }
        let forkID = SyncEncoding.uuid("\(local.id.uuidString):kept-after-deletion:\(deletions.sorted().joined(separator: ","))")
        if let existing = supplied[forkID] { return existing }
        try requireNotTrashed(forkID)
        let source = localRoot.appendingPathComponent("Meetings/\(local.id.uuidString)", isDirectory: true)
        let destination = localRoot.appendingPathComponent("Meetings/\(forkID.uuidString)", isDirectory: true)
        try SyncFiles.noSymlinks(source, below: localRoot); try SyncFiles.noSymlinks(destination, below: localRoot)
        try MeetingFolderCopy.copyFiles(from: source, to: destination)
        return local.keptAs(forkID, field: "source:kept-after-deletion", title: "Kept after it was deleted on another device")
    }
    /// A conversation deleted elsewhere whose folder here never got its `meeting.json` (an eager pass installed
    /// its audio, then the deletion arrived before the pass was saved) goes to the Trash with it.
    private func trashOrphanFolder(_ meetingID: UUID) {
        let folder = localRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        guard (try? SyncFiles.noSymlinks(folder, below: localRoot)) != nil, fm.fileExists(atPath: folder.path),
              !fm.fileExists(atPath: folder.appendingPathComponent("meeting.json").path),
              !fm.fileExists(atPath: folder.appendingPathComponent("meeting.recovery.json").path) else { return }
        let trash = localRoot.appendingPathComponent("Trash", isDirectory: true)
        var destination = trash.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        if fm.fileExists(atPath: destination.path) { destination = destination.appendingPathComponent("Orphaned-\(UUID().uuidString)", isDirectory: true) }
        try? LocalFiles.directory(destination.deletingLastPathComponent())
        try? fm.moveItem(at: folder, to: destination)
    }

    /// A cheap check for a phone's timer: lists the journal folders without reading or downloading files.
    /// True when another replica added journal entries since the last pass that settled (nothing pending or
    /// deferred), or when no pass has settled in this process. Local edits are the caller's to track.
    public func hasRemoteChanges() -> Bool {
        guard let settled = settledJournalListing, let listing = try? listingPaths() else { return true }
        return listing != settled
    }

    /// Commit causal acknowledgement only after the caller has saved the returned library.
    /// An interrupted apply is offered again after restart; merely downloading never advances it.
    public func acknowledge(_ checkpointID: UUID) throws {
        guard let pending = state.pending, pending.id == checkpointID else { throw LibrarySyncError.invalidCheckpoint }
        let previous = state
        // Forget what was published only where the applied base moved. A conversation held back this pass
        // (audio pending, a parent missing, an unread journal) keeps it, so the same edit isn't published again.
        for (id, base) in pending.changedBases ?? [:] where state.bases[id] != base {
            state.submittedHashes.removeValue(forKey: id); state.bases[id] = base
        }
        for id in pending.removedBases ?? [] where state.bases[id] != nil {
            state.submittedHashes.removeValue(forKey: id); state.bases.removeValue(forKey: id)
        }
        state.heads = pending.heads; state.metadataHeads = pending.metadataHeads
        state.pending = nil
        do {
            // Base files first: a crash before the checkpoint leaves bases ahead of heads, which only republishes.
            try saveBases(Array((pending.changedBases ?? [:]).keys), removing: pending.removedBases ?? [])
            try saveCheckpoint()
        } catch { state = previous; throw error }
    }

    func prepareRemote() throws -> SyncManifest {
        try SyncFiles.noSymlinks(remoteRoot, below: remoteRoot)
        try LocalFiles.directory(remoteRoot)
        // A plaintext library's folders, as always. A sync folder this device knows holds an encrypted library gets its
        // sealed folders instead, once the manifest says so.
        let sealedHere = syncedSealedLibraryHere
        if !sealedHere { try prepareFolders(["Events", "Blobs", "Metadata"]) }
        let manifestURL = remoteRoot.appendingPathComponent("daybook-sync.json")
        try SyncFiles.available(manifestURL, cloud: cloud)
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: manifestURL) ?? []
        let copies = manifestCopies()
        let manifest: SyncManifest
        if !conflicts.isEmpty || !copies.isEmpty {
            manifest = try resolveManifest(at: manifestURL, conflicts: conflicts, copies: copies)
        } else if fm.fileExists(atPath: manifestURL.path) {
            manifest = try SyncManifest.checked(SyncManifest.decode(SyncFiles.read(manifestURL, below: remoteRoot, cloud: cloud)))
        } else {
            guard mayCreateLibrary else { throw LibrarySyncError.waitingForICloud }
            // The encrypted library this device synced here is gone: starting a plaintext one in its place would be
            // a downgrade. The person resets encryption instead.
            guard !sealedHere else { throw LibrarySyncError.sealingRemoved }
            manifest = try createLibrary(at: manifestURL)
        }
        // Downgrade defense: a plaintext manifest where this device synced an encrypted library.
        if sealedHere, !manifest.isSealed { throw LibrarySyncError.sealingRemoved }
        if manifest.isSealed { try prepareFolders(["Sealed", "Sealed/Events", "Sealed/Metadata", "Sealed/Blobs"]) }
        return manifest
    }

    private func prepareFolders(_ names: [String]) throws {
        for name in names {
            let directory = remoteRoot.appendingPathComponent(name, isDirectory: true)
            try SyncFiles.noSymlinks(directory, below: remoteRoot); try LocalFiles.directory(directory)
        }
    }

    /// Starts a library: plaintext, or encrypted from the start when `sealsNewLibraries` (its key stored and read
    /// back before the manifest names it). Another device's manifest written meanwhile is kept instead.
    private func createLibrary(at manifestURL: URL) throws -> SyncManifest {
        var result = SyncManifest(libraryID: UUID())
        if Self.sealsNewLibraries, let keyStore {
            let key = LibraryKey.generate(libraryID: result.libraryID, createdBy: deviceID)
            try keyStore.store(key)
            result.schemaVersion = SyncManifest.sealedSchemaVersion
            result.sealing = SyncManifest.Sealing(current: key.idHex, sealedSince: key.createdAt, migrator: deviceID,
                                                  keys: [SyncManifest.Sealing.Key(id: key.idHex, created: key.createdAt)])
        }
        try SyncFiles.coordinateWrite(manifestURL, below: remoteRoot) { url in
            if self.fm.fileExists(atPath: url.path) {
                result = try SyncManifest.decode(Data(contentsOf: url))
            } else { try LocalFiles.atomicWrite(result.encoded(), to: url) }
        }
        return try SyncManifest.checked(result)
    }

    /// iCloud has listed the sync folder: if no library is there, this device may start one.
    public func listingGathered() { mayCreateLibrary = true }

    /// Copies iCloud made of the manifest when two devices wrote one (`daybook-sync 2.json`).
    private func manifestCopies() -> [URL] {
        let names = (try? fm.contentsOfDirectory(atPath: remoteRoot.path)) ?? []
        return names.filter { $0 != "daybook-sync.json" && $0.hasPrefix("daybook-sync") && $0.hasSuffix(".json") }.sorted()
            .map { remoteRoot.appendingPathComponent($0) }
    }

    /// Two devices each started a library here before seeing the other's (iCloud kept both: a conflict version
    /// or a renamed copy). Every device resolves it the same way: the smallest library ID wins, and the manifest
    /// names the others it supersedes, so each device continues from its checkpoint for whichever it had (see
    /// `loadCheckpoint`). The journal is shared either way; only its identity changes.
    private func resolveManifest(at url: URL, conflicts: [NSFileVersion], copies: [URL]) throws -> SyncManifest {
        // A version from a newer Daybook is remembered (and refused below), not mistaken for damage.
        var newer: Int?
        func decode(_ data: Data) -> SyncManifest? {
            do { return try SyncManifest.decode(data) } catch LibrarySyncError.unsupportedVersion(let version) { newer = version; return nil } catch { return nil }
        }
        var candidates: [SyncManifest] = []
        var current: SyncManifest?
        if fm.fileExists(atPath: url.path) {
            guard let manifest = decode(try SyncFiles.read(url, below: remoteRoot, cloud: cloud)) else { throw LibrarySyncError.invalidManifest }
            current = manifest; candidates.append(manifest)
        }
        for version in conflicts {
            // A version that can't be read yet can't be resolved; the person sees the conflict.
            guard let data = try? Data(contentsOf: version.url), let manifest = decode(data) else { throw LibrarySyncError.manifestConflict }
            candidates.append(manifest)
        }
        for copy in copies {
            guard SyncFiles.itemState(copy) == .local, let data = try? SyncFiles.read(copy, below: remoteRoot, cloud: cloud), let manifest = decode(data) else { continue }
            candidates.append(manifest)
        }
        if let newer { throw LibrarySyncError.unsupportedVersion(newer) }
        for candidate in candidates { _ = try SyncManifest.checked(candidate) }
        guard let winner = candidates.map(\.libraryID).min(by: { $0.uuidString < $1.uuidString }) else { throw LibrarySyncError.manifestConflict }
        let superseded = Set(candidates.map(\.libraryID) + candidates.flatMap { $0.supersedes ?? [] }).subtracting([winner])
        var resolved = SyncManifest(libraryID: winner)
        resolved.supersedes = superseded.isEmpty ? nil : superseded.sorted { $0.uuidString < $1.uuidString }
        // An encrypted library's manifest changes (keys added, a recovery key saved): versions of the same library merge,
        // keeping every key. Versions of different libraries where one is encrypted can't be merged safely: sync pauses.
        let sealings = candidates.compactMap(\.sealing)
        if !sealings.isEmpty {
            guard Set(candidates.map(\.libraryID)).count == 1 else { throw LibrarySyncError.manifestConflict }
            resolved.schemaVersion = SyncManifest.sealedSchemaVersion
            resolved.sealing = sealings.dropFirst().reduce(sealings[0]) { $0.merged(with: $1) }
        }
        if current != resolved {
            try SyncFiles.coordinateWrite(url, below: remoteRoot) { try LocalFiles.atomicWrite(resolved.encoded(), to: $0) }
        }
        if !conflicts.isEmpty {
            for version in conflicts { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        return resolved
    }

    /// The library's ID from a manifest the sync folder already holds downloaded, without creating one or waiting.
    func existingLibraryID() -> UUID? {
        let url = remoteRoot.appendingPathComponent("daybook-sync.json")
        guard SyncFiles.itemState(url) == .local, let bytes = try? SyncFiles.read(url, below: remoteRoot, cloud: cloud),
              let manifest = try? SyncManifest.checked(SyncManifest.decode(bytes)) else { return nil }
        return manifest.libraryID
    }

    /// The checkpoint (`Sync/<library>-<device>.json`) holds heads and what was published; the applied base of
    /// each conversation is its own file beside it (`Sync/Bases/<library>-<device>/<meeting>.json`), written only
    /// when it changes. Checkpoints from earlier versions held every base inline and are moved out once.
    private func loadCheckpoint(libraryID: UUID, superseding: [UUID] = []) throws {
        let stem = Self.checkpointStem(libraryID: libraryID, deviceID: deviceID)
        let url = localRoot.appendingPathComponent("Sync/\(stem).json")
        try SyncFiles.noSymlinks(url, below: localRoot)
        if checkpointURL == url { return }
        // The library this device synced was superseded by another identity for the same journal: carry on from it.
        if !fm.fileExists(atPath: url.path) {
            for old in superseding where try Self.adoptCheckpoint(localRoot: localRoot, deviceID: deviceID, from: old, to: libraryID) { break }
        }
        let bases = localRoot.appendingPathComponent("Sync/Bases/\(stem)", isDirectory: true)
        try SyncFiles.noSymlinks(bases, below: localRoot)
        basesURL = bases
        if fm.fileExists(atPath: url.path) {
            guard var decoded = try? decoder.decode(SyncCheckpoint.self, from: Data(contentsOf: url)) else { throw LibrarySyncError.corruptState }
            if decoded.baseFiles == true {
                decoded.bases = try loadBases(from: bases)
                state = decoded; checkpointURL = url
            } else {
                // Inline bases (and a full copy in an unacknowledged pass) from an earlier version.
                if let pending = decoded.pending, pending.changedBases == nil {
                    decoded.pending?.changedBases = pending.bases.filter { decoded.bases[$0.key] != $0.value }
                    decoded.pending?.removedBases = decoded.bases.keys.filter { pending.bases[$0] == nil }.sorted()
                }
                decoded.pending?.bases = [:]
                decoded.baseFiles = true
                state = decoded; checkpointURL = url
                do {
                    try saveBases(Array(state.bases.keys), removing: [])
                    try saveCheckpoint()
                } catch {
                    // Not moved yet: the next pass reads the earlier checkpoint again and retries.
                    checkpointURL = nil
                    throw error
                }
            }
        } else {
            state = SyncCheckpoint(); state.baseFiles = true
            // Bases left from an earlier checkpoint here would only be stale.
            try? fm.removeItem(at: bases)
            checkpointURL = url
        }
    }
    /// Copies this device's checkpoint, and its bases, from one library identity to another when it has none
    /// there yet: the journal is the same, only its identity changed (a move into the container, or a manifest
    /// conflict resolved to the other identity). True when it copied.
    static func adoptCheckpoint(localRoot: URL, deviceID: String, from old: UUID, to new: UUID) throws -> Bool {
        let fm = FileManager.default
        let sync = localRoot.appendingPathComponent("Sync", isDirectory: true)
        let fromStem = checkpointStem(libraryID: old, deviceID: deviceID), toStem = checkpointStem(libraryID: new, deviceID: deviceID)
        let from = sync.appendingPathComponent("\(fromStem).json"), to = sync.appendingPathComponent("\(toStem).json")
        try SyncFiles.noSymlinks(from, below: localRoot); try SyncFiles.noSymlinks(to, below: localRoot)
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return false }
        let fromBases = sync.appendingPathComponent("Bases/\(fromStem)", isDirectory: true)
        let toBases = sync.appendingPathComponent("Bases/\(toStem)", isDirectory: true)
        try SyncFiles.noSymlinks(fromBases, below: localRoot); try SyncFiles.noSymlinks(toBases, below: localRoot)
        if fm.fileExists(atPath: fromBases.path) {
            try? fm.removeItem(at: toBases)
            try LocalFiles.directory(toBases.deletingLastPathComponent())
            try fm.copyItem(at: fromBases, to: toBases)
        }
        try LocalFiles.atomicWrite(Data(contentsOf: from), to: to)
        return true
    }
    /// Whether one of this device's checkpoints (for any library) records `id` as deleted through sync.
    public static func recordsDeletion(of id: UUID, localRoot: URL, deviceID: String) -> Bool {
        struct Deletions: Decodable { var deletedIDs: Set<UUID>? }
        let sync = localRoot.standardizedFileURL.appendingPathComponent("Sync", isDirectory: true)
        let suffix = "-\(SyncDigest.sha256(data: Data(deviceID.utf8)).prefix(16)).json"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sync.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.contains { name in
            let deletions = try? JSONDecoder().decode(Deletions.self, from: Data(contentsOf: sync.appendingPathComponent(name)))
            return deletions?.deletedIDs?.contains(id) == true
        }
    }
    /// A device taking a new identity keeps its place in every library it synced: its checkpoints (and bases) are
    /// copied to the new device ID, so it continues from the same heads instead of publishing everything again.
    public static func carryOverCheckpoints(localRoot: URL, from oldDeviceID: String, to newDeviceID: String) {
        let fm = FileManager.default
        let sync = localRoot.standardizedFileURL.appendingPathComponent("Sync", isDirectory: true)
        let suffix = "-\(SyncDigest.sha256(data: Data(oldDeviceID.utf8)).prefix(16)).json"
        for name in (try? fm.contentsOfDirectory(atPath: sync.path)) ?? [] where name.hasSuffix(suffix) {
            guard let library = UUID(uuidString: String(name.dropLast(suffix.count))) else { continue }
            _ = try? adoptCheckpoint(localRoot: localRoot, oldDeviceID: oldDeviceID, newDeviceID: newDeviceID, library: library)
        }
    }
    private static func adoptCheckpoint(localRoot: URL, oldDeviceID: String, newDeviceID: String, library: UUID) throws {
        let fm = FileManager.default
        let sync = localRoot.standardizedFileURL.appendingPathComponent("Sync", isDirectory: true)
        let fromStem = checkpointStem(libraryID: library, deviceID: oldDeviceID), toStem = checkpointStem(libraryID: library, deviceID: newDeviceID)
        let from = sync.appendingPathComponent("\(fromStem).json"), to = sync.appendingPathComponent("\(toStem).json")
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        let fromBases = sync.appendingPathComponent("Bases/\(fromStem)", isDirectory: true)
        if fm.fileExists(atPath: fromBases.path) {
            let toBases = sync.appendingPathComponent("Bases/\(toStem)", isDirectory: true)
            try? fm.removeItem(at: toBases)
            try fm.copyItem(at: fromBases, to: toBases)
        }
        try LocalFiles.atomicWrite(Data(contentsOf: from), to: to)
    }
    static func checkpointStem(libraryID: UUID, deviceID: String) -> String {
        "\(libraryID.uuidString)-\(SyncDigest.sha256(data: Data(deviceID.utf8)).prefix(16))"
    }
    private func saveCheckpoint() throws {
        guard let checkpointURL else { throw LibrarySyncError.corruptState }
        try SyncFiles.noSymlinks(checkpointURL, below: localRoot)
        // Bases live in their own files. Empty inline copies keep the file readable by earlier versions.
        var stored = state
        stored.bases = [:]
        try LocalFiles.atomicWrite(SyncEncoding.data(stored), to: checkpointURL)
    }
    private func loadBases(from directory: URL) throws -> [String: Meeting] {
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var bases: [String: Meeting] = [:]
        for name in names where name.hasSuffix(".json") {
            let key = String(name.dropLast(5))
            guard UUID(uuidString: key) != nil else { continue }
            // A base that can't be read only means the next pass publishes that conversation again.
            if let base = try? decoder.decode(Meeting.self, from: Data(contentsOf: directory.appendingPathComponent(name))) { bases[key] = base }
        }
        return bases
    }
    private func saveBases(_ keys: [String], removing removed: [String]) throws {
        guard let basesURL else { throw LibrarySyncError.corruptState }
        guard !keys.isEmpty || !removed.isEmpty else { return }
        try SyncFiles.noSymlinks(basesURL, below: localRoot)
        try LocalFiles.directory(basesURL)
        for key in keys {
            guard UUID(uuidString: key) != nil, let base = state.bases[key] else { continue }
            try LocalFiles.atomicWrite(SyncEncoding.data(base), to: basesURL.appendingPathComponent("\(key).json"))
        }
        for key in removed where UUID(uuidString: key) != nil {
            try? fm.removeItem(at: basesURL.appendingPathComponent("\(key).json"))
        }
    }
    /// After a pass: snapshots the pass used stay (heads, bases of merges), others are read again if needed, and
    /// only the library settings that are heads keep their data.
    private func retainCaches(heads: Set<String>, metadataHeads: Set<String>) {
        let keep = snapshotsUsed.union(heads)
        snapshotCache = snapshotCache.filter { keep.contains($0.key) }
        snapshotsUsed = []
        for (id, record) in metadataCache where !metadataHeads.contains(id) && !record.data.isEmpty {
            metadataCache[id]?.data = Data()
        }
    }
    /// How much the engine holds in memory (tests).
    func cacheCounts() -> (headers: Int, snapshots: Int, metadataData: Int) {
        (eventCache.count, snapshotCache.count, metadataCache.values.filter { !$0.data.isEmpty }.count)
    }
    private func hash<T: Encodable>(_ value: T) throws -> String { SyncDigest.sha256(data: try SyncEncoding.data(value)) }
    /// A journal entry (or the library settings in one) that declares a schema newer than this version reads.
    private func requireSupportedVersion(_ bytes: Data) throws {
        struct Header: Decodable { var schemaVersion: Int? }
        if let version = (try? decoder.decode(Header.self, from: bytes))?.schemaVersion, version > 1 { throw LibrarySyncError.unsupportedVersion(version) }
    }
    /// Remembers an entry that can't be read, so later passes neither read it again nor wait for it: its content
    /// never changes. A newer Daybook's entries say so; anything else says it couldn't be read.
    /// A failure that reading the same bytes again would repeat: a newer format, a shape that doesn't decode, a
    /// snapshot that doesn't validate. Bytes that don't match their name (a file still settling) and file errors
    /// are retried every pass.
    static func isPermanent(_ error: Error) -> Bool {
        if error is SyncHashMismatch { return false }
        return error is DecodingError || error is LibrarySyncError || error is LibraryError
    }
    private func markUnreadable(_ name: String, _ error: Error) -> String {
        let reason: String
        switch error {
        case LibrarySyncError.unsupportedVersion, is DecodingError: reason = "Some changes were made with a newer version of Daybook. Update Daybook to see them."
        default: reason = error.localizedDescription
        }
        unreadableJournal[name] = reason
        return reason
    }
    private func eventHash(_ url: URL, bytes: Data) throws -> String {
        let expected = url.deletingPathExtension().lastPathComponent
        guard SyncFiles.isHash(expected) else { throw LibrarySyncError.invalidEvent(url.lastPathComponent) }
        guard SyncDigest.sha256(data: bytes) == expected else { throw SyncHashMismatch(name: url.lastPathComponent) }
        return expected
    }
    private func writeRecord<T: Encodable>(_ record: T, directory: String) throws -> String {
        try Task.checkCancellation()
        let bytes = try SyncEncoding.data(record), id = SyncDigest.sha256(data: bytes)
        // An encrypted library's entries are sealed under its current key; the entry's ID is the same either way.
        if let sealing {
            try writeSealed(bytes, id: id, kind: directory == "Events" ? .event : .metadata, key: sealing.current)
            return id
        }
        let url = remoteRoot.appendingPathComponent("\(directory)/\(id).json")
        try SyncFiles.coordinateWrite(url, below: remoteRoot) { target in
            if self.fm.fileExists(atPath: target.path) {
                guard try Data(contentsOf: target) == bytes else { throw LibrarySyncError.invalidEvent(target.lastPathComponent) }
            } else { try LocalFiles.atomicWrite(bytes, to: target) }
        }
        let path = "\(directory)/\(id).json"
        ownJournalWrites.insert(path)
        courierWrites[path] = SyncJournalFile(path: path, sha256: id, size: Int64(bytes.count))
        return id
    }
    func journalFiles(in name: String) throws -> [URL] {
        let directory = remoteRoot.appendingPathComponent(name, isDirectory: true)
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isUbiquitousItemKey]).compactMap { url in
            if url.pathExtension == "json", SyncFiles.isHash(url.deletingPathExtension().lastPathComponent) { return url }
            let filename = url.lastPathComponent
            if filename.hasPrefix("."), filename.hasSuffix(".json.icloud") {
                let logical = String(filename.dropFirst().dropLast(7))
                let target = directory.appendingPathComponent(logical)
                if SyncFiles.isHash(target.deletingPathExtension().lastPathComponent) { return target }
            }
            return nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prepareUpload(_ supplied: Meeting, journalAssets: Set<String>) throws -> (meeting: Meeting, assets: [SyncAsset], pendingUploads: Int) {
        var meeting = supplied
        let directory = localRoot.appendingPathComponent("Meetings/\(meeting.id.uuidString)", isDirectory: true)
        var assets: [SyncAsset] = []
        var byReference = Set<String>()
        for index in meeting.tracks.indices {
            try Task.checkCancellation()
            let track = meeting.tracks[index]
            let url = try LocalFiles.relativeURL(track.relativePath, in: directory)
            try SyncFiles.noSymlinks(url, below: localRoot)
            guard fm.fileExists(atPath: url.path) else {
                // An on-demand replica holds only some audio. A track it never fetched (or evicted) is still
                // published, unchanged, by reference to the object already in the sync folder or journal.
                if audioPolicy == .onDemand, SyncFiles.isHash(track.sha256),
                   journalAssets.contains(track.sha256) || hasRemoteObject(track.sha256) {
                    assets.append(SyncAsset(relativePath: track.relativePath, sha256: track.sha256))
                    byReference.insert(track.relativePath)
                    continue
                }
                throw LibrarySyncError.missingLocalAudio(track.fileName)
            }
            let digest: String
            if SyncFiles.isHash(track.sha256), try verified(url, digest: track.sha256) {
                digest = track.sha256
            } else {
                digest = try SyncDigest.sha256(fileURL: url)
                guard track.sha256.isEmpty || track.sha256 == digest else { throw LibrarySyncError.missingLocalAudio(track.fileName) }
                verifiedAssets[url.path] = try assetStamp(url, digest: digest)
            }
            meeting.tracks[index].sha256 = digest
            assets.append(SyncAsset(relativePath: track.relativePath, sha256: digest))
        }
        try appendPhotoAssets(&meeting, directory: directory, journalAssets: journalAssets, assets: &assets, byReference: &byReference)
        let originals = directory.appendingPathComponent("Originals", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: originals, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            // In name order, so publishing the same conversation again writes the same bytes.
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" && file.lastPathComponent.contains(".highlights-") {
                try SyncFiles.noSymlinks(file, below: localRoot)
                assets.append(SyncAsset(relativePath: "Originals/\(file.lastPathComponent)", sha256: try SyncDigest.sha256(fileURL: file)))
            }
        }
        try validate(snapshot: meeting, assets: assets)
        for asset in assets where !byReference.contains(asset.relativePath) {
            try Task.checkCancellation()
            let source = try LocalFiles.relativeURL(asset.relativePath, in: directory)
            try upload(asset, from: source)
            if audioPolicy == .onDemand { noteLocalOriginal(asset, at: source, in: meeting) }
        }
        return (meeting, assets, 0)
    }

    private func upload(_ asset: SyncAsset, from source: URL) throws {
        if let sealing { return try uploadSealed(asset, from: source, sealing: sealing) }
        let target = blobURL(asset.sha256)
        // Never download an object just to re-verify it: on a phone that would fetch every recording.
        if audioPolicy == .onDemand, SyncFiles.itemState(target) == .inCloud { return }
        if fm.fileExists(atPath: target.path) {
            try SyncFiles.available(target, cloud: cloud)
            if let stamp = try? assetStamp(target, digest: asset.sha256), verifiedAssets[target.path] == stamp { return }
            let valid = try SyncFiles.coordinateRead(target, below: remoteRoot) { try SyncDigest.sha256(fileURL: $0) == asset.sha256 }
            guard valid else { throw LibrarySyncError.invalidBlob(asset.sha256) }
            verifiedAssets[target.path] = try assetStamp(target, digest: asset.sha256)
            return
        }
        // A courier brought this object from the device that recorded it, and that device uploads it through iCloud
        // Drive. Writing it into the sync folder here as well would make two writers of one file.
        if inboxCopy("Blobs/\(asset.sha256)") != nil { return }
        var wrote = false
        try SyncFiles.coordinateWrite(target, below: remoteRoot) { url in
            if self.fm.fileExists(atPath: url.path) {
                guard try SyncDigest.sha256(fileURL: url) == asset.sha256 else { throw LibrarySyncError.invalidBlob(asset.sha256) }
                return
            }
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".upload-\(UUID().uuidString)")
            defer { try? self.fm.removeItem(at: temporary) }
            try self.fm.copyItem(at: source, to: temporary)
            guard try SyncDigest.sha256(fileURL: temporary) == asset.sha256 else { throw LibrarySyncError.invalidBlob(asset.sha256) }
            try self.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try self.fm.moveItem(at: temporary, to: url)
            wrote = true
        }
        let stamp = try? assetStamp(target, digest: asset.sha256)
        verifiedAssets[target.path] = stamp
        if wrote, let stamp {
            let path = "Blobs/\(asset.sha256)"
            courierWrites[path] = SyncJournalFile(path: path, sha256: asset.sha256, size: Int64(stamp.size))
        }
    }

    private func validate(snapshot: Meeting, assets: [SyncAsset]) throws {
        guard snapshot.schemaVersion == 1 else { throw LibrarySyncError.unsupportedVersion(snapshot.schemaVersion) }
        try MeetingStore.validate(snapshot, expectedID: snapshot.id, rootURL: localRoot)
        let directory = localRoot.appendingPathComponent("Meetings/\(snapshot.id.uuidString)", isDirectory: true)
        for asset in assets {
            try Task.checkCancellation()
            guard SyncFiles.isHash(asset.sha256), asset.relativePath.hasPrefix("Originals/") else { throw LibrarySyncError.invalidBlob(asset.relativePath) }
            let path = try LocalFiles.relativeURL(asset.relativePath, in: directory)
            try SyncFiles.noSymlinks(path, below: localRoot)
        }
        for track in snapshot.tracks {
            guard SyncFiles.isHash(track.sha256), assets.contains(where: { $0.relativePath == track.relativePath && $0.sha256 == track.sha256 }) else { throw LibrarySyncError.invalidBlob(track.fileName) }
        }
        try validatePhotoAssets(snapshot, assets: assets)
    }
    private func mergedAssets(for meeting: Meeting, eventIDs: [String], events: [String: SyncEventHeader]) -> [SyncAsset] {
        var assets = meeting.tracks.map { SyncAsset(relativePath: $0.relativePath, sha256: $0.sha256) } + photoAssets(of: meeting)
        for id in eventIDs.sorted() {
            for asset in events[id]?.assets ?? [] where asset.relativePath.contains(".highlights-") && !assets.contains(asset) { assets.append(asset) }
        }
        return assets
    }
    private func hydrate(_ assets: [SyncAsset], meetingID: UUID, warnings: inout [String], budget: inout SyncPassBudget) throws {
        let directory = localRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        try requireNotTrashed(meetingID)
        try LocalFiles.directory(directory)
        for asset in assets {
            try Task.checkCancellation()
            let destination = try LocalFiles.relativeURL(asset.relativePath, in: directory)
            try SyncFiles.noSymlinks(destination, below: localRoot)
            if try verified(destination, digest: asset.sha256) { continue }
            // Copying audio is the expensive part of an eager pass; respect the pass's time budget.
            if budget.timeExceeded { throw SyncDeferredWork() }
            // Sealed under a key held here, or plaintext from before an encrypted library's sealer reached it.
            var object = remoteObject(asset.sha256)
            // While the sync folder's copy isn't downloaded, a courier delivery of the same object will do.
            let delivered = courierObject(asset.sha256)
            if let delivered { object = delivered.object } else {
                try SyncFiles.available(object.url, cloud: cloud)
                guard fm.fileExists(atPath: object.url.path) else { throw SyncPendingDownload() }
            }
            try LocalFiles.directory(destination.deletingLastPathComponent())
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporary) }
            let digest: String
            if let delivered {
                digest = try copyPlaintext(delivered.delivery, of: object, below: inboxBase, libraryID: libraryID, to: temporary, expected: asset.sha256)
            } else {
                digest = try copyPlaintext(object.url, of: object, below: remoteRoot, libraryID: libraryID, to: temporary, expected: asset.sha256)
            }
            guard digest == asset.sha256 else {
                if let delivered { discardDelivery(delivered.delivery); throw SyncPendingDownload() }
                throw LibrarySyncError.invalidBlob(asset.sha256)
            }
            try install(temporary, at: destination, in: directory, warnings: &warnings)
            verifiedAssets[destination.path] = try assetStamp(destination, digest: asset.sha256)
        }
    }
    /// Moves verified bytes into the library. An existing different file is an original and is preserved.
    func install(_ temporary: URL, at destination: URL, in directory: URL, warnings: inout [String]) throws {
        if fm.fileExists(atPath: destination.path) {
            let conflict = directory.appendingPathComponent("SyncConflicts", isDirectory: true)
            try SyncFiles.noSymlinks(conflict, below: localRoot)
            try LocalFiles.directory(conflict)
            let oldHash = try SyncDigest.sha256(fileURL: destination)
            let saved = conflict.appendingPathComponent("\(oldHash)-\(destination.lastPathComponent)")
            if !fm.fileExists(atPath: saved.path) { try fm.copyItem(at: destination, to: saved) }
            warnings.append("An existing original differed from its sync object and was preserved at \(saved.path).")
            try fm.removeItem(at: destination)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try fm.moveItem(at: temporary, to: destination)
    }
    func requireNotTrashed(_ meetingID: UUID) throws {
        guard !fm.fileExists(atPath: localRoot.appendingPathComponent("Trash/\(meetingID.uuidString)").path) else { throw LibraryError.trashedMeeting(meetingID) }
    }
    nonisolated func blobURL(_ sha256: String) -> URL { remoteRoot.appendingPathComponent("Blobs/\(sha256)") }
    func assetStamp(_ url: URL, digest: String) throws -> VerifiedAsset {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        return VerifiedAsset(digest: digest, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date ?? .distantPast,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
    func verified(_ url: URL, digest: String) throws -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }
        let stamp = try assetStamp(url, digest: digest)
        if verifiedAssets[url.path] == stamp { return true }
        // An on-demand replica recorded the stamp of audio it installed or published, so a relaunch
        // doesn't re-hash every local recording.
        if audioPolicy == .onDemand, let entry = audioIndexEntry(at: url), entry.stamp == stamp {
            verifiedAssets[url.path] = stamp
            return true
        }
        guard try SyncDigest.sha256(fileURL: url) == digest else { return false }
        verifiedAssets[url.path] = stamp
        return true
    }
    private func heads(ids: [String], parents: (String) -> [String]) -> [String] {
        let ancestors = Set(ids.flatMap(parents))
        return ids.filter { !ancestors.contains($0) }.sorted()
    }
    /// Visit every edge once. Missing parents and cycles never become ready, while shared
    /// ancestors in a merge history do not multiply the work or consume the call stack.
    /// `present` are entries that count as available though they aren't among `events`.
    private func completeAncestorIDs(events: [String: SyncEventHeader], budget: inout SyncPassBudget, present: Set<String> = []) throws -> Set<String> {
        var remaining: [String: Int] = [:]
        var children: [String: [String]] = [:]
        var ready: [String] = []
        for (id, event) in events {
            try Task.checkCancellation()
            guard !budget.timeExceeded else { budget.deferred += 1; return [] }
            let parents = event.parents.filter { !present.contains($0) }
            remaining[id] = parents.count
            if parents.isEmpty { ready.append(id) }
            for parent in parents { children[parent, default: []].append(id) }
        }
        var complete = Set<String>()
        while let id = ready.popLast() {
            try Task.checkCancellation()
            guard !budget.timeExceeded else { budget.deferred += 1; break }
            complete.insert(id)
            for child in children[id] ?? [] {
                remaining[child, default: 0] -= 1
                if remaining[child] == 0 { ready.append(child) }
            }
        }
        return complete
    }
    private func ancestorIDs(_ id: String, events: [String: SyncEventHeader]) -> Set<String> {
        var result = Set<String>(), pending = [id]
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending += events[current]?.parents ?? []
        }
        return result
    }
    /// The merge of `ids` (heads of one conversation), folding each into the result against a virtual base:
    /// the merge of all their maximal common ancestors, computed the same way (git's recursive strategy).
    /// After a criss-cross, where two devices each applied the same merge and then edited, the base is that
    /// merge rather than one arbitrary parent of it, so a tag removed or a bookmark deleted there stays gone.
    private func mergedSnapshot(of ids: [String], events: [String: SyncEventHeader], memo: inout MergeMemo) throws -> Meeting? {
        let ids = ids.sorted()
        if let cached = memo.merged[ids] { return cached }
        // Only the heads' own merge reports conflicts; a virtual base's were reported when it was made.
        let reports = memo.depth == 0
        memo.depth += 1
        defer { memo.depth -= 1 }
        guard let first = ids.first, var merged = try resolvedSnapshot(first, events: events, memo: &memo) else { return nil }
        var folded = [first]
        for next in ids.dropFirst() {
            guard let snapshot = try resolvedSnapshot(next, events: events, memo: &memo) else { continue }
            var common = Set<String>()
            for id in folded { common.formUnion(ancestors(of: id, events: events, memo: &memo)) }
            common.formIntersection(ancestors(of: next, events: events, memo: &memo))
            // The maximal common ancestors: those no other common ancestor descends from.
            let maximal = common.subtracting(common.flatMap { events[$0]?.parents ?? [] }).filter { events[$0]?.deleted == false }
            let base = maximal.isEmpty ? nil : try mergedSnapshot(of: Array(maximal), events: events, memo: &memo)
            let result = MeetingMerge.merge(base: base, local: merged, remote: snapshot)
            merged = result.meeting; folded.append(next)
            if reports { memo.warnings += result.warnings }
        }
        memo.merged[ids] = merged
        return merged
    }
    /// An event's snapshot. One written by a Daybook that predates photos carries no photos, and its
    /// summary sections no photo IDs; they're taken from its parents, so its edit doesn't remove them.
    private func resolvedSnapshot(_ id: String, events: [String: SyncEventHeader], memo: inout MergeMemo) throws -> Meeting? {
        if let cached = memo.resolved[id] { return cached }
        guard let event = events[id], !event.deleted else { return nil }
        var snapshot = try self.snapshot(of: id)
        if snapshot.photos == nil, !event.parents.isEmpty, event.parents.contains(where: { ancestorHasPhotos($0, events: events) }),
           let parent = try mergedSnapshot(of: event.parents, events: events, memo: &memo) {
            snapshot = snapshot.restoringPhotos(from: parent)
        }
        memo.resolved[id] = snapshot
        return snapshot
    }
    /// An event's snapshot, as written: from memory, or read again (and checked against its name).
    private func snapshot(of id: String) throws -> Meeting {
        snapshotsUsed.insert(id)
        if let cached = snapshotCache[id] { return cached }
        let bytes: Data, url: URL
        if let sealing, let sealed = sealedLocation(of: id, sealing: sealing) {
            // Read again from a sealed file, opened and checked against the ID.
            url = sealed
            let directory = "Sealed/Events"
            bytes = try readSealed(JournalEntry(url: sealed, path: "\(directory)/\(sealed.lastPathComponent)", directory: directory,
                                                name: sealed.lastPathComponent, isSealed: true), kind: .event, sealing: sealing).0
        } else {
            url = remoteRoot.appendingPathComponent("Events/\(id).json")
            bytes = try readJournal(url, in: "Events")
        }
        guard SyncDigest.sha256(data: bytes) == id, let snapshot = try decoder.decode(SyncEventRecord.self, from: bytes).snapshot else {
            throw LibrarySyncError.invalidEvent(url.lastPathComponent)
        }
        snapshotCache[id] = snapshot
        return snapshot
    }
    private func ancestors(of id: String, events: [String: SyncEventHeader], memo: inout MergeMemo) -> Set<String> {
        if let cached = memo.ancestors[id] { return cached }
        let result = ancestorIDs(id, events: events)
        memo.ancestors[id] = result
        return result
    }
    /// Whether the event or any ancestor carries photos. Immutable, so remembered across passes.
    private func ancestorHasPhotos(_ id: String, events: [String: SyncEventHeader]) -> Bool {
        if let known = photoLineage[id] { return known }
        var stack = [id]
        while let current = stack.last {
            if photoLineage[current] != nil { stack.removeLast(); continue }
            guard let event = events[current] else { photoLineage[current] = false; stack.removeLast(); continue }
            let unknown = event.parents.filter { photoLineage[$0] == nil && !stack.contains($0) }
            if !unknown.isEmpty { stack += unknown; continue }
            photoLineage[current] = event.hasPhotos || event.parents.contains { photoLineage[$0] == true }
            stack.removeLast()
        }
        return photoLineage[id] ?? false
    }
    private func countPendingCloudUploads() throws -> Int {
        var count = 0
        var urls = [remoteRoot.appendingPathComponent("daybook-sync.json")]
        for name in ["Events", "Blobs", "Metadata"] where sealing == nil || fm.fileExists(atPath: remoteRoot.appendingPathComponent(name).path) {
            urls += try fm.contentsOfDirectory(at: remoteRoot.appendingPathComponent(name), includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey], options: [.skipsHiddenFiles])
        }
        for name in ["Sealed/Events", "Sealed/Metadata", "Sealed/Blobs"] where fm.fileExists(atPath: remoteRoot.appendingPathComponent(name).path) {
            urls += try fm.contentsOfDirectory(at: remoteRoot.appendingPathComponent(name), includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey], options: [.skipsHiddenFiles])
        }
        for url in urls {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
            if values.isUbiquitousItem == true && values.ubiquitousItemIsUploaded == false { count += 1 }
        }
        return count
    }
}

struct SyncManifest: Codable, Equatable {
    var format = "DaybookSync"; var schemaVersion = 1; var libraryID: UUID
    /// Library IDs this one replaced when two devices started a library in the same folder (`resolveManifest`).
    /// Additive: earlier versions ignore it.
    var supersedes: [UUID]?
    /// How an encrypted library (`schemaVersion` 2) is sealed (LibrarySyncSealing.swift). Nil in a plaintext one.
    var sealing: Sealing?
}
struct SyncAsset: Codable, Equatable { var relativePath: String; var sha256: String }
struct SyncEventRecord: Codable {
    var schemaVersion = 1
    var meetingID: UUID
    var deviceID: String
    var sequence: Int
    var parents: [String]
    var snapshot: Meeting?
    var deleted: Bool
    var assets: [SyncAsset]
}
struct SyncMetadataRecord: Codable {
    var schemaVersion = 1
    var deviceID: String
    var sequence: Int
    var parents: [String]
    var data: Data
}
/// What a pass needs of every event without its snapshot, which is read when a merge needs it.
struct SyncEventHeader {
    var meetingID: UUID
    var deviceID: String
    var parents: [String]
    var deleted: Bool
    var assets: [SyncAsset]
    var hasPhotos: Bool
    init(_ record: SyncEventRecord) {
        meetingID = record.meetingID; deviceID = record.deviceID; parents = record.parents; deleted = record.deleted
        assets = record.assets; hasPhotos = record.snapshot?.photos != nil
    }
}
private struct SyncCheckpoint: Codable {
    var sequence = 0
    var heads: [String: [String]] = [:]
    /// In memory, every conversation's applied base. On disk, empty: each base is its own file (`baseFiles`).
    /// Earlier versions wrote them here, and this is where they're read from once.
    var bases: [String: Meeting] = [:]
    var submittedHashes: [String: String] = [:]
    var deletedIDs: Set<UUID> = []
    var metadataHeads: [String] = []
    var metadataSubmittedHash: String?
    var pending: SyncPendingApply?
    /// Bases are in `Sync/Bases/<library>-<device>/`. Nil in checkpoints from earlier versions.
    var baseFiles: Bool?
}
/// One pass's merges: results by head set, resolved snapshots, and ancestor sets.
private struct MergeMemo {
    var merged: [[String]: Meeting] = [:]
    var resolved: [String: Meeting] = [:]
    var ancestors: [String: Set<String>] = [:]
    var warnings: [String] = []
    var depth = 0
}
private struct SyncPendingApply: Codable {
    var id: UUID
    /// A full copy of every base, in earlier versions; empty now (`changedBases`).
    var bases: [String: Meeting] = [:]
    var heads: [String: [String]]
    var metadataHeads: [String]
    /// The bases this pass changes, and those it removes (deleted conversations).
    var changedBases: [String: Meeting]?
    var removedBases: [String]?
}
struct VerifiedAsset: Codable, Equatable { var digest: String; var size: UInt64; var modified: Date; var inode: UInt64 }
struct SyncPendingDownload: LocalizedError {
    var errorDescription: String? { "Waiting for iCloud to download a change." }
}
/// A journal file whose bytes don't match its name: damaged, or still settling. Read again next pass.
struct SyncHashMismatch: LocalizedError {
    var name: String
    var errorDescription: String? { LibrarySyncError.invalidEvent(name).errorDescription }
}
/// Work left for a later pass because this one reached its `SyncPassLimits`. Never surfaced as a warning.
struct SyncDeferredWork: Error {}
struct SyncPassBudget {
    let limits: SyncPassLimits
    private let deadline: ContinuousClock.Instant?
    private(set) var journalReads = 0
    var deferred = 0
    init(_ limits: SyncPassLimits) {
        self.limits = limits
        deadline = limits.timeBudget.map { ContinuousClock.now.advanced(by: $0) }
    }
    var timeExceeded: Bool { deadline.map { ContinuousClock.now >= $0 } ?? false }
    /// Admits one first-time journal read, or counts it as deferred.
    mutating func admitJournalRead() -> Bool {
        if timeExceeded || limits.maxJournalReads.map({ journalReads >= $0 }) == true { deferred += 1; return false }
        journalReads += 1
        return true
    }
}

enum SyncFiles {
    static func isHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func noSymlinks(_ url: URL, below root: URL) throws {
        let base = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { throw LibrarySyncError.unsafeLocation }
        var current = root.standardizedFileURL
        let parts = path == base ? [] : String(path.dropFirst(base.count + 1)).split(separator: "/").map(String.init)
        for part in [""] + parts {
            if !part.isEmpty { current.appendPathComponent(part) }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil { throw LibrarySyncError.unsafeLocation }
        }
    }
    static func available(_ url: URL, cloud: SyncCloudFiles) throws {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current,
           values?.ubiquitousItemDownloadingStatus != .downloaded {
            try cloud.requestDownload(url)
            throw SyncPendingDownload()
        }
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: placeholder(for: url).path) {
            try cloud.requestDownload(url)
            throw SyncPendingDownload()
        }
    }
    static func read(_ url: URL, below root: URL, cloud: SyncCloudFiles) throws -> Data {
        try available(url, cloud: cloud)
        return try coordinateRead(url, below: root) { try Data(contentsOf: $0) }
    }
    /// The legacy iCloud placeholder for an evicted item: `.name.icloud` beside it.
    static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }
    enum ItemState { case absent, inCloud, local }
    /// Where an item in the sync folder is, without reading it or requesting a download.
    static func itemState(_ url: URL) -> ItemState {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current,
               values?.ubiquitousItemDownloadingStatus != .downloaded { return .inCloud }
            return .local
        }
        return FileManager.default.fileExists(atPath: placeholder(for: url).path) ? .inCloud : .absent
    }
    static func downloadError(_ url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]))?.ubiquitousItemDownloadingError?.localizedDescription
    }
    static func coordinateRead<T>(_ url: URL, below root: URL, operation: (URL) throws -> T) throws -> T {
        try noSymlinks(url, below: root)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?, outcome: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            outcome = Result { try noSymlinks(target, below: root); return try operation(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw LibrarySyncError.invalidEvent(url.lastPathComponent) }
        return try outcome.get()
    }
    /// Deletes an item with a coordinated write (`.forDeleting`). An item that isn't there is fine.
    static func coordinateDelete(_ url: URL, below root: URL) throws {
        try noSymlinks(url, below: root)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?, failure: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do {
                try noSymlinks(target, below: root)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }
    static func coordinateWrite(_ url: URL, below root: URL, operation: (URL) throws -> Void) throws {
        try Task.checkCancellation()
        try noSymlinks(url, below: root)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?, failure: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try noSymlinks(target, below: root); try operation(target) } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }
}
