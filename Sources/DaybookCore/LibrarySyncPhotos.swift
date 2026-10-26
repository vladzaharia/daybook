import Foundation

// Photos ride the journal the way recordings do: each photo's original is a content-addressed object
// in `Blobs/`, listed in the event's assets under its library path (`Originals/Photos/<id>.<ext>`),
// and referenced from the conversation's snapshot with its SHA-256. An eager replica (a Mac) copies
// and verifies every photo before the conversation applies; an on-demand replica (the iPhone) applies
// at once and fetches a photo when it's shown (`fetchPhoto`). Versions of Daybook before photos list
// the extra assets, accept them (they're under `Originals/`), and ignore them.

extension LibrarySyncEngine {
    /// Adds each photo's original to a publication's assets. A photo this replica holds is verified
    /// (and its digest filled in); an on-demand replica publishes one it never fetched by reference to
    /// the object already in the journal or `Blobs/`, as it does audio.
    func appendPhotoAssets(_ meeting: inout Meeting, directory: URL, journalAssets: Set<String>,
                           assets: inout [SyncAsset], byReference: inout Set<String>) throws {
        guard var photos = meeting.photos else { return }
        for index in photos.indices {
            try Task.checkCancellation()
            let photo = photos[index]
            let url = try LocalFiles.relativeURL(photo.relativePath, in: directory)
            try SyncFiles.noSymlinks(url, below: localRoot)
            guard fm.fileExists(atPath: url.path) else {
                if audioPolicy == .onDemand, SyncFiles.isHash(photo.sha256), try mayPublishByReference(photo.sha256, journalAssets: journalAssets) {
                    assets.append(SyncAsset(relativePath: photo.relativePath, sha256: photo.sha256))
                    byReference.insert(photo.relativePath)
                    continue
                }
                throw LibrarySyncError.missingLocalAudio(photo.fileName)
            }
            let digest: String
            if SyncFiles.isHash(photo.sha256), try verified(url, digest: photo.sha256) {
                digest = photo.sha256
            } else {
                digest = try SyncDigest.sha256(fileURL: url)
                guard photo.sha256.isEmpty || photo.sha256 == digest else { throw LibrarySyncError.missingLocalAudio(photo.fileName) }
                verifiedAssets[url.path] = try assetStamp(url, digest: digest)
            }
            photos[index].sha256 = digest
            assets.append(SyncAsset(relativePath: photo.relativePath, sha256: digest))
        }
        meeting.photos = photos
    }

    /// Every photo in a snapshot needs its object among the event's assets.
    func validatePhotoAssets(_ snapshot: Meeting, assets: [SyncAsset]) throws {
        for photo in snapshot.photos ?? [] {
            guard photo.relativePath.hasPrefix(MeetingPhoto.folder + "/"), SyncFiles.isHash(photo.sha256),
                  assets.contains(where: { $0.relativePath == photo.relativePath && $0.sha256 == photo.sha256 }) else {
                throw LibrarySyncError.invalidBlob(photo.fileName)
            }
        }
    }

    /// The assets a merged snapshot's photos need.
    nonisolated func photoAssets(of meeting: Meeting) -> [SyncAsset] {
        (meeting.photos ?? []).map { SyncAsset(relativePath: $0.relativePath, sha256: $0.sha256) }
    }

    // MARK: On demand

    /// Whether a photo's original is in the local library. On an on-demand replica a photo that isn't
    /// is a normal state: `fetchPhoto` makes it local.
    public nonisolated func isPhotoLocal(_ photo: MeetingPhoto, in meetingID: UUID) -> Bool {
        let directory = localRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        guard let url = try? LocalFiles.relativeURL(photo.relativePath, in: directory),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    /// Makes one photo's original local, the way `fetchAudio` does a recording's: it waits for the
    /// object (asking iCloud to download it), copies it while hashing, and installs it only when the
    /// digest matches. Fetched photos join the on-demand cache, so they can be evicted like audio and
    /// fetched again. Returns the photo's file in the library.
    @discardableResult
    public func fetchPhoto(_ photo: MeetingPhoto, in meetingID: UUID, options: AudioFetchOptions = AudioFetchOptions(),
                           progress: (@Sendable (AudioFetchProgress) -> Void)? = nil) async throws -> URL {
        guard photo.relativePath.hasPrefix(MeetingPhoto.folder + "/") else { throw AudioFetchError.invalidTrack(photo.fileName) }
        // The fetch is the same as a recording's: a track-shaped description of the photo's original.
        let original = RecordingTrack(id: photo.id, source: .imported, relativePath: photo.relativePath,
                                      fileName: photo.fileName, sha256: photo.sha256)
        return try await fetchAudio(for: original, in: meetingID, options: options, progress: progress)
    }
}
