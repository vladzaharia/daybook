// Frozen copy of the version 1 sync engine (Daybook 41809ef, before on-demand replicas and presence),
// renamed so it can run beside the current one. It stands in for an older Mac in compatibility tests.
// Do not modify: it must keep behaving exactly like the shipped engine.
import Foundation
@testable import DaybookCore

struct LegacySyncResult: Sendable {
    /// Acknowledge only after every returned change is durably saved locally.
    var checkpointID: UUID
    var meetings: [Meeting]
    var deletedMeetingIDs: Set<UUID>
    var metadataVersions: [Data]
    var warnings: [String]
    var pendingDownloads: Int
    var pendingUploads: Int
    var publishedEvents: Int
    var hasPendingTransfers: Bool { pendingDownloads > 0 || pendingUploads > 0 }
}

enum LegacyLibrarySyncError: LocalizedError {
    case unsafeLocation, invalidManifest, manifestConflict, unsupportedVersion(Int), invalidEvent(String), invalidBlob(String), missingLocalAudio(String), corruptState, invalidCheckpoint
    var errorDescription: String? {
        switch self {
        case .unsafeLocation: return "The sync folder must be separate from the local library and cannot contain symbolic links."
        case .invalidManifest: return "The selected folder has an invalid Daybook sync manifest. Its files were not replaced."
        case .manifestConflict: return "iCloud reported conflicting sync library identities. Synchronization paused; the existing manifest versions were preserved."
        case .unsupportedVersion(let version): return "This sync library uses unsupported version \(version). Update Daybook before synchronizing."
        case .invalidEvent(let name): return "A sync journal entry failed validation: \(name)."
        case .invalidBlob(let name): return "An audio sync object failed its SHA-256 integrity check: \(name)."
        case .missingLocalAudio(let name): return "The original recording is missing or changed: \(name). It has not been marked as uploaded."
        case .corruptState: return "The local sync checkpoint is unreadable. Synchronization stopped to preserve its causal history."
        case .invalidCheckpoint: return "This sync result has been superseded. Synchronize again before acknowledging local changes."
        }
    }
}

/// A coordinated, immutable file transport usable with an explicitly selected iCloud Drive folder
/// or a native ubiquity container. It never moves the live library into cloud storage.
actor LegacyLibrarySyncEngine {
    nonisolated let localRoot: URL
    nonisolated let remoteRoot: URL
    nonisolated let deviceID: String
    private let fm = FileManager.default
    private let decoder = JSONDecoder()
    private var checkpointURL: URL?
    private var state = LegacySyncCheckpoint()
    private var verifiedAssets: [String: LegacyVerifiedAsset] = [:]

    init(localRoot: URL, remoteRoot: URL, deviceID: String) throws {
        self.localRoot = localRoot.standardizedFileURL
        self.remoteRoot = remoteRoot.standardizedFileURL
        self.deviceID = deviceID
        let local = localRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let remote = remoteRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard !deviceID.isEmpty, local != remote, !local.hasPrefix(remote + "/"), !remote.hasPrefix(local + "/") else { throw LegacyLibrarySyncError.unsafeLocation }
        let syncDirectory = self.localRoot.appendingPathComponent("Sync", isDirectory: true)
        try LegacySyncFiles.noSymlinks(syncDirectory, below: self.localRoot)
        try LocalFiles.directory(syncDirectory)
        try LegacySyncFiles.noSymlinks(self.remoteRoot, below: self.remoteRoot)
    }

    func synchronize(meetings: [Meeting], deletedMeetingIDs: Set<UUID> = [], libraryMetadata: Data? = nil) async throws -> LegacySyncResult {
        try Task.checkCancellation()
        let manifest = try prepareRemote()
        try loadCheckpoint(libraryID: manifest.libraryID)
        var warnings: [String] = []
        var pendingDownloads = 0
        var pendingUploads = 0
        var published = 0
        var failedPublications = Set<UUID>()
        var events: [String: LegacySyncEventRecord] = [:]
        var metadata: [String: LegacySyncMetadataRecord] = [:]
        for url in try journalFiles(in: "Events") {
            do {
                let bytes = try LegacySyncFiles.read(url, below: remoteRoot)
                let hash = try eventHash(url, bytes: bytes)
                let event = try decoder.decode(LegacySyncEventRecord.self, from: bytes)
                guard event.schemaVersion == 1, event.parents.allSatisfy(LegacySyncFiles.isHash),
                      event.deleted != (event.snapshot != nil), event.snapshot?.id == event.meetingID || event.deleted else { throw LegacyLibrarySyncError.invalidEvent(url.lastPathComponent) }
                if let snapshot = event.snapshot { try validate(snapshot: snapshot, assets: event.assets) }
                events[hash] = event
            } catch is LegacySyncPendingDownload { pendingDownloads += 1 }
            catch { warnings.append(error.localizedDescription); pendingDownloads += 1 }
        }
        for url in try journalFiles(in: "Metadata") {
            do {
                let bytes = try LegacySyncFiles.read(url, below: remoteRoot)
                let hash = try eventHash(url, bytes: bytes)
                let record = try decoder.decode(LegacySyncMetadataRecord.self, from: bytes)
                guard record.schemaVersion == 1, record.parents.allSatisfy(LegacySyncFiles.isHash) else { throw LegacyLibrarySyncError.invalidEvent(url.lastPathComponent) }
                metadata[hash] = record
            } catch is LegacySyncPendingDownload { pendingDownloads += 1 }
            catch { warnings.append(error.localizedDescription); pendingDownloads += 1 }
        }
        // A parent belongs to the same conversation. Malformed cross-conversation edges
        // cannot provide ancestry or hide a legitimate head.
        for (id, event) in events where event.parents.contains(where: { events[$0].map { $0.meetingID != event.meetingID } ?? false }) {
            events.removeValue(forKey: id)
            warnings.append(LegacyLibrarySyncError.invalidEvent(id).localizedDescription); pendingDownloads += 1
        }
        let unknownParents = Set(events.values.flatMap(\.parents)).subtracting(events.keys)
        if !unknownParents.isEmpty {
            pendingDownloads += unknownParents.count
            warnings.append("Some sync journal ancestors are not available yet. Dependent changes will wait for the next sync.")
        }

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
            let fingerprint = try hash(supplied)
            guard fingerprint != state.submittedHashes[key], fingerprint != state.bases[key].flatMap({ try? hash($0) }),
                  fingerprint != state.pending?.bases[key].flatMap({ try? hash($0) }) else { continue }
            do {
                let prepared = try prepareUpload(supplied)
                pendingUploads += prepared.pendingUploads
                state.sequence += 1
                let event = LegacySyncEventRecord(meetingID: supplied.id, deviceID: deviceID, sequence: state.sequence,
                    parents: (state.heads[key] ?? []).sorted(), snapshot: prepared.meeting, deleted: false, assets: prepared.assets)
                let id = try writeRecord(event, directory: "Events")
                events[id] = event; state.submittedHashes[key] = fingerprint
                state.heads[key] = [id]
                // Persist after every publication so interruption cannot accidentally reparent it later.
                try saveCheckpoint(); published += 1
            } catch is LegacySyncPendingDownload { pendingDownloads += 1; pendingUploads += 1; failedPublications.insert(supplied.id) }
            catch { warnings.append(error.localizedDescription); pendingUploads += 1; failedPublications.insert(supplied.id) }
        }
        for id in deletes.sorted(by: { $0.uuidString < $1.uuidString }) where !events.values.contains(where: { $0.meetingID == id && $0.deleted }) {
            state.sequence += 1
            let event = LegacySyncEventRecord(meetingID: id, deviceID: deviceID, sequence: state.sequence,
                parents: (state.heads[id.uuidString] ?? []).sorted(), snapshot: nil, deleted: true, assets: [])
            let eventID = try writeRecord(event, directory: "Events")
            events[eventID] = event; state.heads[id.uuidString] = [eventID]
            try saveCheckpoint(); published += 1
        }
        deletes.formUnion(events.values.filter(\.deleted).map(\.meetingID))

        if let libraryMetadata {
            let fingerprint = AudioDigest.sha256(data: libraryMetadata)
            if fingerprint != state.metadataSubmittedHash {
                state.sequence += 1
                let record = LegacySyncMetadataRecord(deviceID: deviceID, sequence: state.sequence, parents: state.metadataHeads.sorted(), data: libraryMetadata)
                let id = try writeRecord(record, directory: "Metadata")
                metadata[id] = record; state.metadataSubmittedHash = fingerprint; state.metadataHeads = [id]
                try saveCheckpoint(); published += 1
            }
        }

        var output = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                try hydrate(assets, meetingID: meetingID, warnings: &warnings)
                output[meetingID] = merged
                proposedBases[meetingID.uuidString] = merged
                proposedHeads[meetingID.uuidString] = headIDs
            } catch is LegacySyncPendingDownload { pendingDownloads += 1 }
            catch { warnings.append(error.localizedDescription); pendingDownloads += 1 }
        }
        for id in deletes { output.removeValue(forKey: id) }
        state.deletedIDs.formUnion(deletes)
        var sourceMeetings: [String: Set<UUID>] = [:]
        for meeting in output.values {
            for track in meeting.tracks where !track.sha256.isEmpty { sourceMeetings[track.sha256, default: []].insert(meeting.id) }
        }
        if sourceMeetings.values.contains(where: { $0.count > 1 }) {
            warnings.append("The same recording appears in multiple conversations. They remain separate so unrelated conversations are not combined automatically.")
        }
        let metadataHeads = heads(ids: Array(metadata.keys), parents: { metadata[$0]?.parents ?? [] })
        let missingMetadataParents = Set(metadata.values.flatMap(\.parents)).subtracting(metadata.keys)
        let versions: [Data]
        if missingMetadataParents.isEmpty {
            versions = metadataHeads.compactMap { metadata[$0]?.data }
        } else {
            pendingDownloads += missingMetadataParents.count; versions = []
            warnings.append("Library organization and templates are waiting for sync metadata ancestors.")
        }
        let checkpointID = UUID()
        try Task.checkCancellation()
        state.pending = LegacySyncPendingApply(id: checkpointID, bases: proposedBases, heads: proposedHeads,
            metadataHeads: missingMetadataParents.isEmpty ? metadataHeads : state.metadataHeads)
        try saveCheckpoint()
        // A coordinated local write is not necessarily uploaded to iCloud yet.
        pendingUploads += try countPendingCloudUploads()
        return LegacySyncResult(checkpointID: checkpointID, meetings: output.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date },
            deletedMeetingIDs: deletes, metadataVersions: versions, warnings: Array(Set(warnings)).sorted(),
            pendingDownloads: pendingDownloads, pendingUploads: pendingUploads, publishedEvents: published)
    }

    /// Commit causal acknowledgement only after the caller has saved the returned library.
    /// An interrupted apply is offered again after restart; merely downloading never advances it.
    func acknowledge(_ checkpointID: UUID) throws {
        guard let pending = state.pending, pending.id == checkpointID else { throw LegacyLibrarySyncError.invalidCheckpoint }
        let previous = state
        state.bases = pending.bases; state.heads = pending.heads; state.metadataHeads = pending.metadataHeads
        for id in pending.bases.keys { state.submittedHashes.removeValue(forKey: id) }
        state.pending = nil
        do { try saveCheckpoint() } catch { state = previous; throw error }
    }

    private func prepareRemote() throws -> LegacySyncManifest {
        try LegacySyncFiles.noSymlinks(remoteRoot, below: remoteRoot)
        try LocalFiles.directory(remoteRoot)
        for name in ["Events", "Blobs", "Metadata"] {
            let directory = remoteRoot.appendingPathComponent(name, isDirectory: true)
            try LegacySyncFiles.noSymlinks(directory, below: remoteRoot); try LocalFiles.directory(directory)
        }
        let manifestURL = remoteRoot.appendingPathComponent("daybook-sync.json")
        try LegacySyncFiles.available(manifestURL)
        if !(NSFileVersion.unresolvedConflictVersionsOfItem(at: manifestURL) ?? []).isEmpty { throw LegacyLibrarySyncError.manifestConflict }
        if fm.fileExists(atPath: manifestURL.path) {
            let existing = try decoder.decode(LegacySyncManifest.self, from: LegacySyncFiles.read(manifestURL, below: remoteRoot))
            guard existing.format == "DaybookSync" else { throw LegacyLibrarySyncError.invalidManifest }
            guard existing.schemaVersion == 1 else { throw LegacyLibrarySyncError.unsupportedVersion(existing.schemaVersion) }
            return existing
        }
        var result = LegacySyncManifest(libraryID: UUID())
        try LegacySyncFiles.coordinateWrite(manifestURL, below: remoteRoot) { url in
            if self.fm.fileExists(atPath: url.path) {
                result = try self.decoder.decode(LegacySyncManifest.self, from: Data(contentsOf: url))
            } else { try LocalFiles.atomicWrite(SyncEncoding.data(result), to: url) }
        }
        guard result.format == "DaybookSync", result.schemaVersion == 1 else { throw LegacyLibrarySyncError.invalidManifest }
        return result
    }

    private func loadCheckpoint(libraryID: UUID) throws {
        let name = "\(libraryID.uuidString)-\(AudioDigest.sha256(data: Data(deviceID.utf8)).prefix(16)).json"
        let url = localRoot.appendingPathComponent("Sync/\(name)")
        try LegacySyncFiles.noSymlinks(url, below: localRoot)
        if checkpointURL == url { return }
        if fm.fileExists(atPath: url.path) {
            guard let decoded = try? decoder.decode(LegacySyncCheckpoint.self, from: Data(contentsOf: url)) else { throw LegacyLibrarySyncError.corruptState }
            state = decoded
        } else { state = LegacySyncCheckpoint() }
        checkpointURL = url
    }
    private func saveCheckpoint() throws {
        guard let checkpointURL else { throw LegacyLibrarySyncError.corruptState }
        try LegacySyncFiles.noSymlinks(checkpointURL, below: localRoot)
        try LocalFiles.atomicWrite(SyncEncoding.data(state), to: checkpointURL)
    }
    private func hash<T: Encodable>(_ value: T) throws -> String { AudioDigest.sha256(data: try SyncEncoding.data(value)) }
    private func eventHash(_ url: URL, bytes: Data) throws -> String {
        let expected = url.deletingPathExtension().lastPathComponent
        guard LegacySyncFiles.isHash(expected), AudioDigest.sha256(data: bytes) == expected else { throw LegacyLibrarySyncError.invalidEvent(url.lastPathComponent) }
        return expected
    }
    private func writeRecord<T: Encodable>(_ record: T, directory: String) throws -> String {
        try Task.checkCancellation()
        let bytes = try SyncEncoding.data(record), id = AudioDigest.sha256(data: bytes)
        let url = remoteRoot.appendingPathComponent("\(directory)/\(id).json")
        try LegacySyncFiles.coordinateWrite(url, below: remoteRoot) { target in
            if self.fm.fileExists(atPath: target.path) {
                guard try Data(contentsOf: target) == bytes else { throw LegacyLibrarySyncError.invalidEvent(target.lastPathComponent) }
            } else { try LocalFiles.atomicWrite(bytes, to: target) }
        }
        return id
    }
    private func journalFiles(in name: String) throws -> [URL] {
        let directory = remoteRoot.appendingPathComponent(name, isDirectory: true)
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isUbiquitousItemKey]).compactMap { url in
            if url.pathExtension == "json", LegacySyncFiles.isHash(url.deletingPathExtension().lastPathComponent) { return url }
            let filename = url.lastPathComponent
            if filename.hasPrefix("."), filename.hasSuffix(".json.icloud") {
                let logical = String(filename.dropFirst().dropLast(7))
                let target = directory.appendingPathComponent(logical)
                if LegacySyncFiles.isHash(target.deletingPathExtension().lastPathComponent) { return target }
            }
            return nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prepareUpload(_ supplied: Meeting) throws -> (meeting: Meeting, assets: [LegacySyncAsset], pendingUploads: Int) {
        var meeting = supplied
        let directory = localRoot.appendingPathComponent("Meetings/\(meeting.id.uuidString)", isDirectory: true)
        var assets: [LegacySyncAsset] = []
        for index in meeting.tracks.indices {
            try Task.checkCancellation()
            let track = meeting.tracks[index]
            let url = try LocalFiles.relativeURL(track.relativePath, in: directory)
            try LegacySyncFiles.noSymlinks(url, below: localRoot)
            guard fm.fileExists(atPath: url.path) else { throw LegacyLibrarySyncError.missingLocalAudio(track.fileName) }
            let digest = try AudioDigest.sha256(fileURL: url)
            guard track.sha256.isEmpty || track.sha256 == digest else { throw LegacyLibrarySyncError.missingLocalAudio(track.fileName) }
            meeting.tracks[index].sha256 = digest
            assets.append(LegacySyncAsset(relativePath: track.relativePath, sha256: digest))
        }
        let originals = directory.appendingPathComponent("Originals", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: originals, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for file in files where file.pathExtension == "json" && file.lastPathComponent.contains(".highlights-") {
                try LegacySyncFiles.noSymlinks(file, below: localRoot)
                assets.append(LegacySyncAsset(relativePath: "Originals/\(file.lastPathComponent)", sha256: try AudioDigest.sha256(fileURL: file)))
            }
        }
        try validate(snapshot: meeting, assets: assets)
        for asset in assets {
            try Task.checkCancellation()
            let source = try LocalFiles.relativeURL(asset.relativePath, in: directory)
            let target = remoteRoot.appendingPathComponent("Blobs/\(asset.sha256)")
            if fm.fileExists(atPath: target.path) {
                try LegacySyncFiles.available(target)
                let valid = try LegacySyncFiles.coordinateRead(target, below: remoteRoot) { try AudioDigest.sha256(fileURL: $0) == asset.sha256 }
                guard valid else { throw LegacyLibrarySyncError.invalidBlob(asset.sha256) }
                continue
            }
            try LegacySyncFiles.coordinateWrite(target, below: remoteRoot) { url in
                if self.fm.fileExists(atPath: url.path) {
                    guard try AudioDigest.sha256(fileURL: url) == asset.sha256 else { throw LegacyLibrarySyncError.invalidBlob(asset.sha256) }
                    return
                }
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".upload-\(UUID().uuidString)")
                defer { try? self.fm.removeItem(at: temporary) }
                try self.fm.copyItem(at: source, to: temporary)
                guard try AudioDigest.sha256(fileURL: temporary) == asset.sha256 else { throw LegacyLibrarySyncError.invalidBlob(asset.sha256) }
                try self.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                try self.fm.moveItem(at: temporary, to: url)
            }
        }
        return (meeting, assets, 0)
    }

    private func validate(snapshot: Meeting, assets: [LegacySyncAsset]) throws {
        guard snapshot.schemaVersion == 1 else { throw LegacyLibrarySyncError.unsupportedVersion(snapshot.schemaVersion) }
        try MeetingStore.validate(snapshot, expectedID: snapshot.id, rootURL: localRoot)
        let directory = localRoot.appendingPathComponent("Meetings/\(snapshot.id.uuidString)", isDirectory: true)
        for asset in assets {
            try Task.checkCancellation()
            guard LegacySyncFiles.isHash(asset.sha256), asset.relativePath.hasPrefix("Originals/") else { throw LegacyLibrarySyncError.invalidBlob(asset.relativePath) }
            let path = try LocalFiles.relativeURL(asset.relativePath, in: directory)
            try LegacySyncFiles.noSymlinks(path, below: localRoot)
        }
        for track in snapshot.tracks {
            guard LegacySyncFiles.isHash(track.sha256), assets.contains(where: { $0.relativePath == track.relativePath && $0.sha256 == track.sha256 }) else { throw LegacyLibrarySyncError.invalidBlob(track.fileName) }
        }
    }
    private func mergedAssets(for meeting: Meeting, eventIDs: [String], events: [String: LegacySyncEventRecord]) -> [LegacySyncAsset] {
        var assets = meeting.tracks.map { LegacySyncAsset(relativePath: $0.relativePath, sha256: $0.sha256) }
        for id in eventIDs.sorted() {
            for asset in events[id]?.assets ?? [] where asset.relativePath.contains(".highlights-") && !assets.contains(asset) { assets.append(asset) }
        }
        return assets
    }
    private func hydrate(_ assets: [LegacySyncAsset], meetingID: UUID, warnings: inout [String]) throws {
        let directory = localRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        guard !fm.fileExists(atPath: localRoot.appendingPathComponent("Trash/\(meetingID.uuidString)").path) else { throw LibraryError.trashedMeeting(meetingID) }
        try LocalFiles.directory(directory)
        for asset in assets {
            try Task.checkCancellation()
            let destination = try LocalFiles.relativeURL(asset.relativePath, in: directory)
            try LegacySyncFiles.noSymlinks(destination, below: localRoot)
            if try verified(destination, digest: asset.sha256) { continue }
            let remote = remoteRoot.appendingPathComponent("Blobs/\(asset.sha256)")
            try LegacySyncFiles.available(remote)
            guard fm.fileExists(atPath: remote.path) else { throw LegacySyncPendingDownload() }
            try LocalFiles.directory(destination.deletingLastPathComponent())
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporary) }
            try LegacySyncFiles.coordinateRead(remote, below: remoteRoot) { try self.fm.copyItem(at: $0, to: temporary) }
            guard try AudioDigest.sha256(fileURL: temporary) == asset.sha256 else { throw LegacyLibrarySyncError.invalidBlob(asset.sha256) }
            if fm.fileExists(atPath: destination.path) {
                let conflict = directory.appendingPathComponent("SyncConflicts", isDirectory: true)
                try LegacySyncFiles.noSymlinks(conflict, below: localRoot)
                try LocalFiles.directory(conflict)
                let oldHash = try AudioDigest.sha256(fileURL: destination)
                let saved = conflict.appendingPathComponent("\(oldHash)-\(destination.lastPathComponent)")
                if !fm.fileExists(atPath: saved.path) { try fm.copyItem(at: destination, to: saved) }
                warnings.append("An existing original differed from its sync object and was preserved at \(saved.path).")
                try fm.removeItem(at: destination)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try fm.moveItem(at: temporary, to: destination)
            verifiedAssets[destination.path] = try assetStamp(destination, digest: asset.sha256)
        }
    }
    private func assetStamp(_ url: URL, digest: String) throws -> LegacyVerifiedAsset {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        return LegacyVerifiedAsset(digest: digest, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date ?? .distantPast,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
    private func verified(_ url: URL, digest: String) throws -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }
        let stamp = try assetStamp(url, digest: digest)
        if verifiedAssets[url.path] == stamp { return true }
        guard try AudioDigest.sha256(fileURL: url) == digest else { return false }
        verifiedAssets[url.path] = stamp
        return true
    }
    private func heads(ids: [String], parents: (String) -> [String]) -> [String] {
        let ancestors = Set(ids.flatMap(parents))
        return ids.filter { !ancestors.contains($0) }.sorted()
    }
    private func ancestorsComplete(_ id: String, events: [String: LegacySyncEventRecord], visiting: Set<String> = []) -> Bool {
        guard !visiting.contains(id), let event = events[id] else { return false }
        return event.parents.allSatisfy { ancestorsComplete($0, events: events, visiting: visiting.union([id])) }
    }
    private func ancestorIDs(_ id: String, events: [String: LegacySyncEventRecord]) -> Set<String> {
        var result = Set<String>(), pending = [id]
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending += events[current]?.parents ?? []
        }
        return result
    }
    private func commonAncestor(_ ids: [String], events: [String: LegacySyncEventRecord]) -> String? {
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

private struct LegacySyncManifest: Codable { var format = "DaybookSync"; var schemaVersion = 1; var libraryID: UUID }
private struct LegacySyncAsset: Codable, Equatable { var relativePath: String; var sha256: String }
private struct LegacySyncEventRecord: Codable {
    var schemaVersion = 1
    var meetingID: UUID
    var deviceID: String
    var sequence: Int
    var parents: [String]
    var snapshot: Meeting?
    var deleted: Bool
    var assets: [LegacySyncAsset]
}
private struct LegacySyncMetadataRecord: Codable {
    var schemaVersion = 1
    var deviceID: String
    var sequence: Int
    var parents: [String]
    var data: Data
}
private struct LegacySyncCheckpoint: Codable {
    var sequence = 0
    var heads: [String: [String]] = [:]
    var bases: [String: Meeting] = [:]
    var submittedHashes: [String: String] = [:]
    var deletedIDs: Set<UUID> = []
    var metadataHeads: [String] = []
    var metadataSubmittedHash: String?
    var pending: LegacySyncPendingApply?
}
private struct LegacySyncPendingApply: Codable {
    var id: UUID
    var bases: [String: Meeting]
    var heads: [String: [String]]
    var metadataHeads: [String]
}
private struct LegacyVerifiedAsset: Equatable { var digest: String; var size: UInt64; var modified: Date; var inode: UInt64 }
private struct LegacySyncPendingDownload: LocalizedError {
    var errorDescription: String? { "iCloud is downloading a sync object. Changes will be retried when it becomes available." }
}

private enum LegacySyncFiles {
    static func isHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func noSymlinks(_ url: URL, below root: URL) throws {
        let base = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { throw LegacyLibrarySyncError.unsafeLocation }
        var current = root.standardizedFileURL
        let parts = path == base ? [] : String(path.dropFirst(base.count + 1)).split(separator: "/").map(String.init)
        for part in [""] + parts {
            if !part.isEmpty { current.appendPathComponent(part) }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil { throw LegacyLibrarySyncError.unsafeLocation }
        }
    }
    static func available(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current,
           values?.ubiquitousItemDownloadingStatus != .downloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw LegacySyncPendingDownload()
        }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: placeholder.path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw LegacySyncPendingDownload()
        }
    }
    static func read(_ url: URL, below root: URL) throws -> Data {
        try available(url)
        return try coordinateRead(url, below: root) { try Data(contentsOf: $0) }
    }
    static func coordinateRead<T>(_ url: URL, below root: URL, operation: (URL) throws -> T) throws -> T {
        try noSymlinks(url, below: root)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?, outcome: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            outcome = Result { try noSymlinks(target, below: root); return try operation(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw LegacyLibrarySyncError.invalidEvent(url.lastPathComponent) }
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
