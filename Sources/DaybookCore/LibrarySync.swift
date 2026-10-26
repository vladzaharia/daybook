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

public enum LibrarySyncError: LocalizedError {
    case unsafeLocation, invalidManifest, manifestConflict, unsupportedVersion(Int), invalidEvent(String), invalidBlob(String), missingLocalAudio(String), corruptState, invalidCheckpoint
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
    private var state = SyncCheckpoint()
    var verifiedAssets: [String: VerifiedAsset] = [:]
    // Journal records are immutable and content-addressed: once read and validated they never need
    // reading again. The directory listing each pass remains the source of truth for membership.
    private var eventCache: [String: SyncEventRecord] = [:]
    private var metadataCache: [String: SyncMetadataRecord] = [:]
    private var ownJournalWrites: Set<String> = []
    /// Files written into the sync folder that no returned pass has reported yet (`SyncResult.writtenFiles`).
    private var courierWrites: [String: SyncJournalFile] = [:]
    /// Devices that wrote the journal entries seen by the last pass, including ones without presence.
    var journalDeviceIDs: Set<String> = []
    /// Journal file names seen by the last pass that finished with nothing pending or deferred.
    var settledJournalListing: Set<String>?
    var presenceWritten: (record: SyncDeviceRecord, at: Date)?
    /// The sync library's ID, from its manifest, once a pass has read it. The iPhone's local link
    /// tags its Bonjour browsing with it (docs/link.md, "Discovery").
    public internal(set) var libraryID: UUID?
    var audioIndexStorage: AudioCacheIndex?
    var audioIndexDirty = false

    public init(localRoot: URL, remoteRoot: URL, deviceID: String, replica: SyncReplicaConfiguration = SyncReplicaConfiguration()) throws {
        self.localRoot = localRoot.standardizedFileURL
        self.remoteRoot = remoteRoot.standardizedFileURL
        self.deviceID = deviceID
        audioPolicy = replica.audioPolicy; cloud = replica.cloud; device = replica.device
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
    public func synchronize(meetings: [Meeting], deletedMeetingIDs: Set<UUID> = [], libraryMetadata: Data? = nil,
                            limits: SyncPassLimits = .unlimited) async throws -> SyncResult {
        try Task.checkCancellation()
        let manifest = try prepareRemote()
        libraryID = manifest.libraryID
        try loadCheckpoint(libraryID: manifest.libraryID)
        var budget = SyncPassBudget(limits)
        var warnings: [String] = []
        var pendingDownloads = 0
        var pendingUploads = 0
        var published = 0
        var unreadJournalFiles = 0
        var metadataIncomplete = false
        var failedPublications = Set<UUID>()
        var events: [String: SyncEventRecord] = [:]
        var metadata: [String: SyncMetadataRecord] = [:]
        ownJournalWrites = []
        let eventURLs = try journalListing(in: "Events"), metadataURLs = try journalListing(in: "Metadata")
        for url in eventURLs {
            try Task.checkCancellation()
            let name = url.deletingPathExtension().lastPathComponent
            if let cached = eventCache[name] { events[name] = cached; continue }
            guard budget.admitJournalRead() else { continue }
            do {
                let bytes = try readJournal(url, in: "Events")
                let hash = try eventHash(url, bytes: bytes)
                let event = try decoder.decode(SyncEventRecord.self, from: bytes)
                guard event.schemaVersion == 1, event.parents.allSatisfy(SyncFiles.isHash),
                      event.deleted != (event.snapshot != nil), event.snapshot?.id == event.meetingID || event.deleted else { throw LibrarySyncError.invalidEvent(url.lastPathComponent) }
                if let snapshot = event.snapshot { try validate(snapshot: snapshot, assets: event.assets) }
                events[hash] = event; eventCache[hash] = event
            } catch is SyncPendingDownload { pendingDownloads += 1; unreadJournalFiles += 1 }
            catch let error as CancellationError { throw error }
            catch { warnings.append(error.localizedDescription); pendingDownloads += 1; unreadJournalFiles += 1 }
        }
        for url in metadataURLs {
            try Task.checkCancellation()
            let name = url.deletingPathExtension().lastPathComponent
            if let cached = metadataCache[name] { metadata[name] = cached; continue }
            guard budget.admitJournalRead() else { metadataIncomplete = true; continue }
            do {
                let bytes = try readJournal(url, in: "Metadata")
                let hash = try eventHash(url, bytes: bytes)
                let record = try decoder.decode(SyncMetadataRecord.self, from: bytes)
                guard record.schemaVersion == 1, record.parents.allSatisfy(SyncFiles.isHash) else { throw LibrarySyncError.invalidEvent(url.lastPathComponent) }
                metadata[hash] = record; metadataCache[hash] = record
            } catch is SyncPendingDownload { pendingDownloads += 1; unreadJournalFiles += 1; metadataIncomplete = true }
            catch let error as CancellationError { throw error }
            catch { warnings.append(error.localizedDescription); pendingDownloads += 1; unreadJournalFiles += 1 }
        }
        journalDeviceIDs = Set(events.values.map(\.deviceID)).union(metadata.values.map(\.deviceID))
        // A parent belongs to the same conversation. Malformed cross-conversation edges
        // cannot provide ancestry or hide a legitimate head.
        for (id, event) in events where event.parents.contains(where: { events[$0].map { $0.meetingID != event.meetingID } ?? false }) {
            events.removeValue(forKey: id)
            warnings.append(LibrarySyncError.invalidEvent(id).localizedDescription); pendingDownloads += 1
        }
        let unknownParents = Set(events.values.flatMap(\.parents)).subtracting(events.keys)
        if !unknownParents.isEmpty {
            pendingDownloads += unknownParents.count
            warnings.append("Some changes are waiting for the next sync.")
        }

        // Assets any readable event references. An on-demand replica can publish a track whose audio it
        // never downloaded (or evicted) by reference to one of these.
        let journalAssets = Set(events.values.flatMap { $0.assets.map(\.sha256) })
        var deletes = deletedMeetingIDs.union(state.deletedIDs)
        let trash = localRoot.appendingPathComponent("Trash", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
            deletes.formUnion(children.compactMap { UUID(uuidString: $0.lastPathComponent) })
        }
        // Publish changes against the last applied heads, not newly observed remote heads. This is what
        // distinguishes a genuine offline concurrent edit from a sequential edit after a pull.
        for supplied in meetings.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            let key = supplied.id.uuidString
            guard !state.deletedIDs.contains(supplied.id) else { continue }
            // Cheap equality first: most meetings are unchanged on most passes.
            if supplied == state.bases[key] || (state.pending?.bases[key]).map({ $0 == supplied }) == true { continue }
            let fingerprint = try hash(supplied)
            guard fingerprint != state.submittedHashes[key], fingerprint != state.bases[key].flatMap({ try? hash($0) }),
                  fingerprint != state.pending?.bases[key].flatMap({ try? hash($0) }) else { continue }
            do {
                let prepared = try prepareUpload(supplied, journalAssets: journalAssets)
                pendingUploads += prepared.pendingUploads
                state.sequence += 1
                let event = SyncEventRecord(meetingID: supplied.id, deviceID: deviceID, sequence: state.sequence,
                    parents: (state.heads[key] ?? []).sorted(), snapshot: prepared.meeting, deleted: false, assets: prepared.assets)
                let id = try writeRecord(event, directory: "Events")
                events[id] = event; eventCache[id] = event; state.submittedHashes[key] = fingerprint
                state.heads[key] = [id]
                // Persist after every publication so interruption cannot accidentally reparent it later.
                try saveCheckpoint(); published += 1
            } catch is SyncPendingDownload { pendingDownloads += 1; pendingUploads += 1; failedPublications.insert(supplied.id) }
            catch let error as CancellationError { throw error }
            catch { warnings.append(error.localizedDescription); pendingUploads += 1; failedPublications.insert(supplied.id) }
        }
        // A deletion this replica already knows about has an event in the journal. When part of the journal
        // is unread (still downloading, or deferred by limits), don't mistake that for a missing tombstone.
        let journalIncomplete = unreadJournalFiles > 0 || budget.deferred > 0
        for id in deletes.sorted(by: { $0.uuidString < $1.uuidString })
        where !events.values.contains(where: { $0.meetingID == id && $0.deleted }) && !(journalIncomplete && state.deletedIDs.contains(id)) {
            state.sequence += 1
            let event = SyncEventRecord(meetingID: id, deviceID: deviceID, sequence: state.sequence,
                parents: (state.heads[id.uuidString] ?? []).sorted(), snapshot: nil, deleted: true, assets: [])
            let eventID = try writeRecord(event, directory: "Events")
            events[eventID] = event; eventCache[eventID] = event; state.heads[id.uuidString] = [eventID]
            try saveCheckpoint(); published += 1
        }
        deletes.formUnion(events.values.filter(\.deleted).map(\.meetingID))

        if let libraryMetadata {
            let fingerprint = SyncDigest.sha256(data: libraryMetadata)
            if fingerprint != state.metadataSubmittedHash {
                state.sequence += 1
                let record = SyncMetadataRecord(deviceID: deviceID, sequence: state.sequence, parents: state.metadataHeads.sorted(), data: libraryMetadata)
                let id = try writeRecord(record, directory: "Metadata")
                metadata[id] = record; metadataCache[id] = record; state.metadataSubmittedHash = fingerprint; state.metadataHeads = [id]
                try saveCheckpoint(); published += 1
            }
        }

        var output = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = Set<UUID>()
        var notLocalAudio: [UUID: Set<UUID>] = [:]
        var proposedBases = state.bases
        var proposedHeads = state.heads
        let grouped = Dictionary(grouping: events.keys, by: { events[$0]!.meetingID })
        for (meetingID, ids) in grouped.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            try Task.checkCancellation()
            if deletes.contains(meetingID) {
                output.removeValue(forKey: meetingID)
                if ids.contains(where: { events[$0]?.snapshot != nil }) {
                    // The immutable journal remains a recovery archive for edit/delete races.
                    proposedBases.removeValue(forKey: meetingID.uuidString)
                }
                proposedHeads[meetingID.uuidString] = heads(ids: ids, parents: { events[$0]?.parents ?? [] })
                continue
            }
            // Failed uploads must never let an older remote snapshot replace unsent local edits.
            guard !failedPublications.contains(meetingID) else { continue }
            let headIDs = heads(ids: ids, parents: { events[$0]?.parents ?? [] })
            guard !headIDs.isEmpty, headIDs.allSatisfy({ ancestorsComplete($0, events: events) }) else { continue }
            // With part of the journal unread (downloading, or deferred by limits), a conversation whose applied
            // heads weren't read this pass would roll back to an older snapshot. It waits for a fuller read.
            if journalIncomplete, let applied = state.heads[meetingID.uuidString], !applied.allSatisfy({ events[$0] != nil }) { continue }
            guard let firstID = headIDs.first, var merged = events[firstID]?.snapshot else { continue }
            var folded = [firstID]
            for nextID in headIDs.dropFirst() {
                guard let next = events[nextID]?.snapshot else { continue }
                let ancestor = commonAncestor(folded + [nextID], events: events).flatMap { events[$0]?.snapshot }
                let result = MeetingMerge.merge(base: ancestor, local: merged, remote: next)
                merged = result.meeting; warnings += result.warnings; folded.append(nextID)
            }
            let assets = mergedAssets(for: merged, eventIDs: ids, events: events)
            do {
                try validate(snapshot: merged, assets: assets)
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
                proposedBases[meetingID.uuidString] = merged
                proposedHeads[meetingID.uuidString] = headIDs
            } catch is SyncPendingDownload { pendingDownloads += 1 }
            catch is SyncDeferredWork { budget.deferred += 1 }
            catch let error as CancellationError { throw error }
            catch { warnings.append(error.localizedDescription); pendingDownloads += 1 }
        }
        for id in deletes { output.removeValue(forKey: id); changed.remove(id); notLocalAudio.removeValue(forKey: id) }
        state.deletedIDs.formUnion(deletes)
        var sourceMeetings: [String: Set<UUID>] = [:]
        for meeting in output.values {
            for track in meeting.tracks where !track.sha256.isEmpty { sourceMeetings[track.sha256, default: []].insert(meeting.id) }
        }
        if sourceMeetings.values.contains(where: { $0.count > 1 }) {
            warnings.append("The same recording is in more than one conversation. They stay separate.")
        }
        let metadataHeads = heads(ids: Array(metadata.keys), parents: { metadata[$0]?.parents ?? [] })
        let missingMetadataParents = Set(metadata.values.flatMap(\.parents)).subtracting(metadata.keys)
        let versions: [Data]
        if !missingMetadataParents.isEmpty {
            pendingDownloads += missingMetadataParents.count; versions = []
            warnings.append("Folders and templates are waiting for the next sync.")
        } else if metadataIncomplete {
            // Heads of a partial read could be older than those already applied; wait for the rest.
            versions = []
        } else {
            versions = metadataHeads.compactMap { metadata[$0]?.data }
        }
        let checkpointID = UUID()
        try Task.checkCancellation()
        state.pending = SyncPendingApply(id: checkpointID, bases: proposedBases, heads: proposedHeads,
            metadataHeads: missingMetadataParents.isEmpty && !metadataIncomplete ? metadataHeads : state.metadataHeads)
        try saveCheckpoint()
        // A coordinated local write is not necessarily uploaded to iCloud yet.
        pendingUploads += try countPendingCloudUploads()
        try saveAudioIndexIfNeeded()
        // Courier deliveries the sync folder now holds, downloaded and identical, aren't needed any more.
        pruneCourierInbox()
        let listing = Set((eventURLs + metadataURLs).map(\.lastPathComponent)).union(ownJournalWrites)
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

    /// A cheap check for a phone's timer: lists the journal folders without reading or downloading files.
    /// True when another replica added journal entries since the last pass that settled (nothing pending or
    /// deferred), or when no pass has settled in this process. Local edits are the caller's to track.
    public func hasRemoteChanges() -> Bool {
        guard let settled = settledJournalListing,
              let events = try? journalListing(in: "Events"), let metadata = try? journalListing(in: "Metadata") else { return true }
        return Set((events + metadata).map(\.lastPathComponent)) != settled
    }

    /// Commit causal acknowledgement only after the caller has saved the returned library.
    /// An interrupted apply is offered again after restart; merely downloading never advances it.
    public func acknowledge(_ checkpointID: UUID) throws {
        guard let pending = state.pending, pending.id == checkpointID else { throw LibrarySyncError.invalidCheckpoint }
        let previous = state
        state.bases = pending.bases; state.heads = pending.heads; state.metadataHeads = pending.metadataHeads
        for id in pending.bases.keys { state.submittedHashes.removeValue(forKey: id) }
        state.pending = nil
        do { try saveCheckpoint() } catch { state = previous; throw error }
    }

    private func prepareRemote() throws -> SyncManifest {
        try SyncFiles.noSymlinks(remoteRoot, below: remoteRoot)
        try LocalFiles.directory(remoteRoot)
        for name in ["Events", "Blobs", "Metadata"] {
            let directory = remoteRoot.appendingPathComponent(name, isDirectory: true)
            try SyncFiles.noSymlinks(directory, below: remoteRoot); try LocalFiles.directory(directory)
        }
        let manifestURL = remoteRoot.appendingPathComponent("daybook-sync.json")
        try SyncFiles.available(manifestURL, cloud: cloud)
        if !(NSFileVersion.unresolvedConflictVersionsOfItem(at: manifestURL) ?? []).isEmpty { throw LibrarySyncError.manifestConflict }
        if fm.fileExists(atPath: manifestURL.path) {
            let existing = try decoder.decode(SyncManifest.self, from: SyncFiles.read(manifestURL, below: remoteRoot, cloud: cloud))
            guard existing.format == "DaybookSync" else { throw LibrarySyncError.invalidManifest }
            guard existing.schemaVersion == 1 else { throw LibrarySyncError.unsupportedVersion(existing.schemaVersion) }
            return existing
        }
        var result = SyncManifest(libraryID: UUID())
        try SyncFiles.coordinateWrite(manifestURL, below: remoteRoot) { url in
            if self.fm.fileExists(atPath: url.path) {
                result = try self.decoder.decode(SyncManifest.self, from: Data(contentsOf: url))
            } else { try LocalFiles.atomicWrite(SyncEncoding.data(result), to: url) }
        }
        guard result.format == "DaybookSync", result.schemaVersion == 1 else { throw LibrarySyncError.invalidManifest }
        return result
    }

    /// The library's ID from a manifest the sync folder already holds downloaded, without creating one or waiting.
    func existingLibraryID() -> UUID? {
        let url = remoteRoot.appendingPathComponent("daybook-sync.json")
        guard SyncFiles.itemState(url) == .local, let bytes = try? SyncFiles.read(url, below: remoteRoot, cloud: cloud),
              let manifest = try? decoder.decode(SyncManifest.self, from: bytes),
              manifest.format == "DaybookSync", manifest.schemaVersion == 1 else { return nil }
        return manifest.libraryID
    }

    private func loadCheckpoint(libraryID: UUID) throws {
        let name = "\(libraryID.uuidString)-\(SyncDigest.sha256(data: Data(deviceID.utf8)).prefix(16)).json"
        let url = localRoot.appendingPathComponent("Sync/\(name)")
        try SyncFiles.noSymlinks(url, below: localRoot)
        if checkpointURL == url { return }
        if fm.fileExists(atPath: url.path) {
            guard let decoded = try? decoder.decode(SyncCheckpoint.self, from: Data(contentsOf: url)) else { throw LibrarySyncError.corruptState }
            state = decoded
        } else { state = SyncCheckpoint() }
        checkpointURL = url
    }
    private func saveCheckpoint() throws {
        guard let checkpointURL else { throw LibrarySyncError.corruptState }
        try SyncFiles.noSymlinks(checkpointURL, below: localRoot)
        try LocalFiles.atomicWrite(SyncEncoding.data(state), to: checkpointURL)
    }
    private func hash<T: Encodable>(_ value: T) throws -> String { SyncDigest.sha256(data: try SyncEncoding.data(value)) }
    private func eventHash(_ url: URL, bytes: Data) throws -> String {
        let expected = url.deletingPathExtension().lastPathComponent
        guard SyncFiles.isHash(expected), SyncDigest.sha256(data: bytes) == expected else { throw LibrarySyncError.invalidEvent(url.lastPathComponent) }
        return expected
    }
    private func writeRecord<T: Encodable>(_ record: T, directory: String) throws -> String {
        try Task.checkCancellation()
        let bytes = try SyncEncoding.data(record), id = SyncDigest.sha256(data: bytes)
        let url = remoteRoot.appendingPathComponent("\(directory)/\(id).json")
        try SyncFiles.coordinateWrite(url, below: remoteRoot) { target in
            if self.fm.fileExists(atPath: target.path) {
                guard try Data(contentsOf: target) == bytes else { throw LibrarySyncError.invalidEvent(target.lastPathComponent) }
            } else { try LocalFiles.atomicWrite(bytes, to: target) }
        }
        ownJournalWrites.insert(url.lastPathComponent)
        let path = "\(directory)/\(id).json"
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
                   journalAssets.contains(track.sha256) || SyncFiles.itemState(blobURL(track.sha256)) != .absent {
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
            for file in files where file.pathExtension == "json" && file.lastPathComponent.contains(".highlights-") {
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
    private func mergedAssets(for meeting: Meeting, eventIDs: [String], events: [String: SyncEventRecord]) -> [SyncAsset] {
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
            let remote = blobURL(asset.sha256)
            // While the sync folder's copy isn't downloaded, a courier delivery of the same object will do.
            let delivered = courierBlob(asset.sha256)
            if delivered == nil {
                try SyncFiles.available(remote, cloud: cloud)
                guard fm.fileExists(atPath: remote.path) else { throw SyncPendingDownload() }
            }
            try LocalFiles.directory(destination.deletingLastPathComponent())
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporary) }
            if let delivered {
                try SyncFiles.coordinateRead(delivered, below: inboxBase) { try self.fm.copyItem(at: $0, to: temporary) }
            } else {
                try SyncFiles.coordinateRead(remote, below: remoteRoot) { try self.fm.copyItem(at: $0, to: temporary) }
            }
            guard try SyncDigest.sha256(fileURL: temporary) == asset.sha256 else {
                if let delivered { discardDelivery(delivered); throw SyncPendingDownload() }
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
    private func ancestorsComplete(_ id: String, events: [String: SyncEventRecord], visiting: Set<String> = []) -> Bool {
        guard !visiting.contains(id), let event = events[id] else { return false }
        return event.parents.allSatisfy { ancestorsComplete($0, events: events, visiting: visiting.union([id])) }
    }
    private func ancestorIDs(_ id: String, events: [String: SyncEventRecord]) -> Set<String> {
        var result = Set<String>(), pending = [id]
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending += events[current]?.parents ?? []
        }
        return result
    }
    private func commonAncestor(_ ids: [String], events: [String: SyncEventRecord]) -> String? {
        guard let first = ids.first else { return nil }
        var common = ancestorIDs(first, events: events)
        for id in ids.dropFirst() { common.formIntersection(ancestorIDs(id, events: events)) }
        return common.sorted { a, b in
            let da = ancestorIDs(a, events: events).count, db = ancestorIDs(b, events: events).count
            return da == db ? a > b : da > db
        }.first
    }
    private func countPendingCloudUploads() throws -> Int {
        var count = 0
        var urls = [remoteRoot.appendingPathComponent("daybook-sync.json")]
        for name in ["Events", "Blobs", "Metadata"] {
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

struct SyncManifest: Codable { var format = "DaybookSync"; var schemaVersion = 1; var libraryID: UUID }
struct SyncAsset: Codable, Equatable { var relativePath: String; var sha256: String }
private struct SyncEventRecord: Codable {
    var schemaVersion = 1
    var meetingID: UUID
    var deviceID: String
    var sequence: Int
    var parents: [String]
    var snapshot: Meeting?
    var deleted: Bool
    var assets: [SyncAsset]
}
private struct SyncMetadataRecord: Codable {
    var schemaVersion = 1
    var deviceID: String
    var sequence: Int
    var parents: [String]
    var data: Data
}
private struct SyncCheckpoint: Codable {
    var sequence = 0
    var heads: [String: [String]] = [:]
    var bases: [String: Meeting] = [:]
    var submittedHashes: [String: String] = [:]
    var deletedIDs: Set<UUID> = []
    var metadataHeads: [String] = []
    var metadataSubmittedHash: String?
    var pending: SyncPendingApply?
}
private struct SyncPendingApply: Codable {
    var id: UUID
    var bases: [String: Meeting]
    var heads: [String: [String]]
    var metadataHeads: [String]
}
struct VerifiedAsset: Codable, Equatable { var digest: String; var size: UInt64; var modified: Date; var inode: UInt64 }
struct SyncPendingDownload: LocalizedError {
    var errorDescription: String? { "Waiting for iCloud to download a change." }
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
