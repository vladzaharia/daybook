import CryptoKit
import Foundation

/// Local, never-synchronized record of the audio an on-demand replica holds: what it fetched, what it
/// recorded and published, and when each was last played. Losing it only makes eviction more cautious:
/// a file it doesn't list is treated as an original recorded here and is never evicted.
struct AudioCacheIndex: Codable {
    var schemaVersion = 1
    var entries: [String: AudioCacheEntry] = [:]
}

struct AudioCacheEntry: Codable, Equatable {
    var meetingID: UUID
    var trackID: UUID?
    var relativePath: String
    var sha256: String
    /// Size, modification date, and inode when the bytes were verified. Eviction deletes only these bytes.
    var stamp: VerifiedAsset
    var origin: CachedAudioOrigin
    var addedAt: Date
    var lastPlayedAt: Date?

    static func key(_ meetingID: UUID, _ relativePath: String) -> String { "\(meetingID.uuidString)/\(relativePath)" }
    var key: String { Self.key(meetingID, relativePath) }
    /// Never-played audio counts as used when it arrived.
    var lastUse: Date { lastPlayedAt ?? addedAt }
    var publicValue: CachedAudio {
        CachedAudio(meetingID: meetingID, trackID: trackID, relativePath: relativePath, sha256: sha256,
                    bytes: stamp.size, origin: origin, addedAt: addedAt, lastPlayedAt: lastPlayedAt)
    }
}

extension LibrarySyncEngine {
    // MARK: Availability

    /// Cheap and synchronous: whether each track's audio file is in the local library. On an on-demand
    /// replica `.notLocal` is a normal state; `fetchAudio` downloads and verifies the audio.
    public nonisolated func audioAvailability(for meeting: Meeting) -> [UUID: TrackAudioAvailability] {
        Dictionary(meeting.tracks.map { ($0.id, availability(of: $0, in: meeting.id)) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated func availability(of track: RecordingTrack, in meetingID: UUID) -> TrackAudioAvailability {
        let directory = localRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        guard let url = try? LocalFiles.relativeURL(track.relativePath, in: directory),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return .notLocal }
        return .local
    }

    // MARK: Fetch on demand

    /// Makes one track's audio local: requests the iCloud download of an evicted object, waits for it (or for
    /// the recording to finish uploading elsewhere), copies it with a coordinated read while computing its
    /// SHA-256, and installs it at the track's path in the local library. A courier delivery of the object in the
    /// inbox is used instead of waiting while the sync folder's copy isn't downloaded. Cancel the calling task to stop;
    /// nothing partial is ever left in the library. Corrupt objects throw `integrityMismatch` and install nothing.
    @discardableResult
    public func fetchAudio(for track: RecordingTrack, in meetingID: UUID, options: AudioFetchOptions = AudioFetchOptions(),
                           progress: (@Sendable (AudioFetchProgress) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        let directory = localRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        guard SyncFiles.isHash(track.sha256), track.relativePath.hasPrefix("Originals/"),
              let destination = try? LocalFiles.relativeURL(track.relativePath, in: directory),
              (try? SyncFiles.noSymlinks(destination, below: localRoot)) != nil else { throw AudioFetchError.invalidTrack(track.fileName) }
        guard (try? requireNotTrashed(meetingID)) != nil else { throw AudioFetchError.meetingInTrash }
        if try verified(destination, digest: track.sha256) {
            let bytes = Int64((try? assetStamp(destination, digest: track.sha256))?.size ?? 0)
            progress?(AudioFetchProgress(phase: .installed, completedBytes: bytes, totalBytes: bytes))
            return destination
        }
        // Sealed under a key held here in an encrypted library, else the plaintext object.
        let object = remoteObject(track.sha256)
        let remote = object.url
        try SyncFiles.noSymlinks(remote, below: remoteRoot)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".fetch-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        var digest: String?
        // A courier delivery of the object, while the sync folder's copy isn't downloaded, saves waiting for iCloud.
        if let delivered = courierObject(track.sha256) {
            try LocalFiles.directory(destination.deletingLastPathComponent())
            let total = ((try? fm.attributesOfItem(atPath: delivered.delivery.path))?[.size] as? NSNumber)?.int64Value
            let copied = try await copyVerifying(delivered.delivery, of: delivered.object, below: inboxBase, to: temporary, expected: track.sha256,
                                                 totalBytes: total, progress: progress)
            if copied == track.sha256 { digest = copied } else { try? fm.removeItem(at: temporary); discardDelivery(delivered.delivery) }
        }
        if digest == nil {
            try await waitUntilLocal(remote, options: options, progress: progress)
            try LocalFiles.directory(destination.deletingLastPathComponent())
            let total = ((try? fm.attributesOfItem(atPath: remote.path))?[.size] as? NSNumber)?.int64Value
            digest = try await copyVerifying(remote, of: object, below: remoteRoot, to: temporary, expected: track.sha256, totalBytes: total, progress: progress)
        }
        guard digest == track.sha256 else { throw AudioFetchError.integrityMismatch(track.fileName) }
        try Task.checkCancellation()
        // The actor ran other work during the copy; the conversation may have moved to the Trash.
        guard (try? requireNotTrashed(meetingID)) != nil else { throw AudioFetchError.meetingInTrash }
        if try !verified(destination, digest: track.sha256) {
            // A different file at the path is preserved under SyncConflicts, as during an eager pull.
            var ignored: [String] = []
            try install(temporary, at: destination, in: directory, warnings: &ignored)
        }
        let stamp = try assetStamp(destination, digest: track.sha256)
        verifiedAssets[destination.path] = stamp
        if audioPolicy == .onDemand {
            let key = AudioCacheEntry.key(meetingID, track.relativePath)
            updateAudioIndex { index in
                let previous = index.entries[key]
                index.entries[key] = AudioCacheEntry(meetingID: meetingID, trackID: track.id, relativePath: track.relativePath,
                    sha256: track.sha256, stamp: stamp, origin: previous?.origin ?? .fetched, addedAt: Date(), lastPlayedAt: previous?.lastPlayedAt)
            }
            try saveAudioIndexIfNeeded()
            // The library copy is the one played; don't also keep iCloud's local copy of the object.
            cloud.evictLocalCopy(remote)
        }
        let size = Int64(stamp.size)
        progress?(AudioFetchProgress(phase: .installed, completedBytes: size, totalBytes: size))
        if audioPolicy == .onDemand, audioCachePolicy != nil { _ = try? evictAudio(protecting: [track.id]) }
        return destination
    }

    private func waitUntilLocal(_ remote: URL, options: AudioFetchOptions, progress: (@Sendable (AudioFetchProgress) -> Void)?) async throws {
        let clock = ContinuousClock(), started = clock.now
        var lastRequest: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            let state = SyncFiles.itemState(remote)
            switch state {
            case .local: return
            case .inCloud:
                if let reason = SyncFiles.downloadError(remote) { throw AudioFetchError.downloadFailed(reason) }
                // Ask again now and then in case the provider dropped the request.
                if lastRequest.map({ clock.now - $0 >= .seconds(10) }) ?? true {
                    do { try cloud.requestDownload(remote) } catch { throw AudioFetchError.downloadFailed(error.localizedDescription) }
                    lastRequest = clock.now
                }
                progress?(AudioFetchProgress(phase: .downloading, downloadFraction: cloud.downloadFraction(remote)))
            case .absent:
                progress?(AudioFetchProgress(phase: .waitingForUpload))
            }
            if let timeout = options.timeout, clock.now - started >= timeout {
                throw state == .absent ? AudioFetchError.notUploadedYet : AudioFetchError.downloadTimedOut
            }
            try await Task.sleep(for: options.pollInterval)
        }
    }

    /// Runs off the actor so a long copy doesn't hold up sync passes. Copies and hashes in one pass; a sealed object is
    /// opened on the way (progress in plaintext bytes), and one that doesn't open returns "".
    private nonisolated func copyVerifying(_ remote: URL, of object: RemoteObject, below root: URL, to temporary: URL, expected: String,
                                           totalBytes: Int64?, progress: (@Sendable (AudioFetchProgress) -> Void)?) async throws -> String {
        if case .sealed = object {
            do {
                return try copyPlaintext(remote, of: object, below: root, libraryID: nil, to: temporary, expected: expected) { done, total in
                    progress?(AudioFetchProgress(phase: .copying, completedBytes: done, totalBytes: total))
                }
            } catch is SyncKeyPending { throw AudioFetchError.downloadFailed("This library’s key isn’t on this device yet.") }
        }
        return try SyncFiles.coordinateRead(remote, below: root) { source in
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var hasher = SHA256()
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 512 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                progress?(AudioFetchProgress(phase: .copying, completedBytes: copied, totalBytes: totalBytes))
            }
            try output.synchronize()
            return SyncDigest.hex(hasher.finalize())
        }
    }

    // MARK: Cache policy and eviction

    public func setAudioCachePolicy(_ policy: AudioCachePolicy?) { audioCachePolicy = policy }

    /// Local audio this on-demand replica tracks, least recently played first.
    public func cachedAudio() -> [CachedAudio] {
        audioIndex().entries.values.sorted(by: Self.evictionOrder).map(\.publicValue)
    }

    /// Records playback so eviction removes the least recently played audio first.
    public func noteAudioPlayed(trackID: UUID, in meetingID: UUID, at date: Date = Date()) {
        guard audioPolicy == .onDemand,
              let key = audioIndex().entries.first(where: { $0.value.meetingID == meetingID && $0.value.trackID == trackID })?.key else { return }
        updateAudioIndex { $0.entries[key]?.lastPlayedAt = date }
        try? saveAudioIndexIfNeeded()
    }

    /// Deletes local copies of audio, least recently played first, until the tracked total fits the cache
    /// budget. Only deletes bytes the cloud already holds: fetched copies whose object is still in the sync
    /// folder, and (if the policy allows) originals recorded here once iCloud reports them uploaded. Originals
    /// not yet uploaded, files changed since they were verified, and `protecting` tracks are never touched.
    /// Eager replicas never evict.
    @discardableResult
    public func evictAudio(protecting protected: Set<UUID> = []) throws -> AudioEvictionReport {
        guard audioPolicy == .onDemand, let policy = audioCachePolicy else {
            let inUse = audioIndex().entries.values.reduce(UInt64(0)) { $0 + $1.stamp.size }
            return AudioEvictionReport(evicted: [], bytesFreed: 0, bytesInUse: inUse, budgetBytes: audioCachePolicy?.budgetBytes)
        }
        // Forget audio that is no longer there (the conversation moved to the Trash, for example).
        for (key, entry) in audioIndex().entries where !fm.fileExists(atPath: localAudioURL(entry).path) {
            updateAudioIndex { $0.entries.removeValue(forKey: key) }
        }
        var inUse = audioIndex().entries.values.reduce(UInt64(0)) { $0 + $1.stamp.size }
        var evicted: [CachedAudio] = []
        var freed: UInt64 = 0
        // In an encrypted library, an original recorded here is evicted only once another device holds the key or a
        // recovery key was saved: otherwise iCloud's sealed copy could be the only one, unreadable if this device is lost.
        let originalsMayGo = sealing == nil || sealedOriginalsMayEvict()
        let candidates = audioIndex().entries.values
            .filter { entry in !(entry.trackID.map { protected.contains($0) } ?? false) }
            .sorted(by: Self.evictionOrder)
        for entry in candidates where inUse > policy.budgetBytes {
            try Task.checkCancellation()
            guard let url = evictableURL(entry, policy: policy, originalsMayGo: originalsMayGo) else { continue }
            try fm.removeItem(at: url)
            verifiedAssets.removeValue(forKey: url.path)
            updateAudioIndex { $0.entries.removeValue(forKey: entry.key) }
            inUse -= entry.stamp.size; freed += entry.stamp.size
            evicted.append(entry.publicValue)
        }
        try saveAudioIndexIfNeeded()
        return AudioEvictionReport(evicted: evicted, bytesFreed: freed, bytesInUse: inUse, budgetBytes: policy.budgetBytes)
    }

    private static func evictionOrder(_ a: AudioCacheEntry, _ b: AudioCacheEntry) -> Bool {
        (a.lastUse, a.addedAt, a.key) < (b.lastUse, b.addedAt, b.key)
    }

    private nonisolated func localAudioURL(_ entry: AudioCacheEntry) -> URL {
        localRoot.appendingPathComponent("Meetings/\(entry.meetingID.uuidString)/\(entry.relativePath)")
    }

    private func evictableURL(_ entry: AudioCacheEntry, policy: AudioCachePolicy, originalsMayGo: Bool) -> URL? {
        let directory = localRoot.appendingPathComponent("Meetings/\(entry.meetingID.uuidString)", isDirectory: true)
        guard let url = try? LocalFiles.relativeURL(entry.relativePath, in: directory),
              (try? SyncFiles.noSymlinks(url, below: localRoot)) != nil,
              // Only the exact bytes that were verified; anything changed since isn't this cache's to delete.
              (try? assetStamp(url, digest: entry.sha256)) == entry.stamp else { return nil }
        if entry.origin == .recordedHere && !policy.evictsUploadedOriginals { return nil }
        if entry.origin == .recordedHere, !originalsMayGo { return nil }
        let object = remoteObject(entry.sha256)
        let blob = object.url
        switch SyncFiles.itemState(blob) {
        case .absent:
            // The object is gone from the sync folder (or never arrived): the local file may be the only copy.
            return nil
        case .inCloud:
            break
        case .local:
            guard (try? verifiedRemote(object, digest: entry.sha256)) == true else { return nil }
        }
        if entry.origin == .recordedHere, !cloud.isUploaded(blob) { return nil }
        return url
    }

    private func verifiedRemote(_ object: RemoteObject, digest: String) throws -> Bool {
        let url = object.url
        let stamp = try assetStamp(url, digest: digest)
        if verifiedAssets[url.path] == stamp { return true }
        let valid = try objectHolds(object, digest: digest)
        if valid { verifiedAssets[url.path] = stamp }
        return valid
    }

    // MARK: Index storage

    private nonisolated var audioIndexURL: URL { localRoot.appendingPathComponent("Sync/audio-cache.json") }

    func audioIndex() -> AudioCacheIndex {
        if let audioIndexStorage { return audioIndexStorage }
        var index = AudioCacheIndex()
        if let data = try? Data(contentsOf: audioIndexURL),
           let decoded = try? JSONDecoder().decode(AudioCacheIndex.self, from: data), decoded.schemaVersion == 1 { index = decoded }
        audioIndexStorage = index
        return index
    }

    func updateAudioIndex(_ change: (inout AudioCacheIndex) -> Void) {
        var index = audioIndex()
        change(&index)
        audioIndexStorage = index; audioIndexDirty = true
    }

    func saveAudioIndexIfNeeded() throws {
        guard audioIndexDirty, let audioIndexStorage else { return }
        try SyncFiles.noSymlinks(audioIndexURL, below: localRoot)
        try LocalFiles.atomicWrite(SyncEncoding.data(audioIndexStorage), to: audioIndexURL)
        audioIndexDirty = false
    }

    func audioIndexEntry(at url: URL) -> AudioCacheEntry? {
        let meetings = localRoot.appendingPathComponent("Meetings", isDirectory: true).standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(meetings) else { return nil }
        return audioIndex().entries[String(path.dropFirst(meetings.count))]
    }

    /// An on-demand replica remembers the originals it published, so they can be evicted once uploaded.
    func noteLocalOriginal(_ asset: SyncAsset, at url: URL, in meeting: Meeting) {
        guard let track = meeting.tracks.first(where: { $0.relativePath == asset.relativePath }),
              let stamp = try? assetStamp(url, digest: asset.sha256) else { return }
        let key = AudioCacheEntry.key(meeting.id, asset.relativePath)
        if audioIndex().entries[key]?.stamp == stamp { return }
        updateAudioIndex { index in
            let previous = index.entries[key]
            index.entries[key] = AudioCacheEntry(meetingID: meeting.id, trackID: track.id, relativePath: asset.relativePath,
                sha256: asset.sha256, stamp: stamp, origin: previous?.origin ?? .recordedHere,
                addedAt: previous?.addedAt ?? Date(), lastPlayedAt: previous?.lastPlayedAt)
        }
    }
}
