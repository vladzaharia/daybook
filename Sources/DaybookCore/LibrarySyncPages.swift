import Foundation

// A notebook page's strokes ride the journal the way photos do: each drawing (and each drawing a merge set aside, and a
// page's background) is a content-addressed object in `Blobs/`, listed in the event's assets under its library path
// (`Originals/Pages/<page>-<sha16>.pkdrawing`) and referenced from the snapshot by its SHA-256. An eager replica (a Mac)
// copies and verifies them before the conversation applies; an on-demand replica (the iPhone) applies at once, with every
// page's words, and fetches a drawing when the page is shown (`fetchPageDrawing`). A Daybook from before pages keeps `pages`
// as an unknown key and lists no page assets, so validation here checks formats only and never asks for them to be listed;
// what a merged conversation needs is worked out from its pages (`pageAssets`).

extension LibrarySyncEngine {
    /// Adds each page's files to a publication's assets: every page, deleted ones included, its drawing, each drawing set aside,
    /// and its background. A file this replica holds is verified against the digest the page names; an on-demand replica
    /// publishes one it never fetched by reference to the object already in the journal or `Blobs/`, as it does a photo.
    func appendPageAssets(_ meeting: Meeting, directory: URL, journalAssets: Set<String>,
                          assets: inout [SyncAsset], byReference: inout Set<String>) throws {
        for page in meeting.pages ?? [] {
            let name = "Page \(meeting.pageNumber(of: page.id).map(String.init) ?? "")".trimmingCharacters(in: .whitespaces)
            for file in page.files {
                try Task.checkCancellation()
                guard SyncFiles.isHash(file.sha256) else { throw LibrarySyncError.invalidBlob(name) }
                let url = try LocalFiles.relativeURL(file.relativePath, in: directory)
                try SyncFiles.noSymlinks(url, below: localRoot)
                if fm.fileExists(atPath: url.path) {
                    guard try verified(url, digest: file.sha256) else { throw LibrarySyncError.missingLocalAudio(name) }
                } else if audioPolicy == .onDemand, try mayPublishByReference(file.sha256, journalAssets: journalAssets) {
                    byReference.insert(file.relativePath)
                } else {
                    throw LibrarySyncError.missingLocalAudio(name)
                }
                let asset = SyncAsset(relativePath: file.relativePath, sha256: file.sha256)
                if !assets.contains(asset) { assets.append(asset) }
            }
        }
    }

    /// The format of every page's files: under `Originals/Pages/`, at the path derived from the page and the whole digest.
    /// Not that the event lists them: a Daybook that keeps `pages` as an unknown key publishes edits without their assets.
    func validatePageAssets(_ snapshot: Meeting) throws {
        for page in snapshot.pages ?? [] where !page.hasDerivedPaths {
            throw LibrarySyncError.invalidBlob("Page \(snapshot.pageNumber(of: page.id) ?? 0)")
        }
    }

    /// The assets a merged snapshot's pages need: what an eager replica hydrates before the conversation applies, and what
    /// the sealer counts as live (`mergedAssets`).
    nonisolated func pageAssets(of meeting: Meeting) -> [SyncAsset] {
        var seen = Set<PageFile>()
        return meeting.pageFiles.filter { seen.insert($0).inserted }.map { SyncAsset(relativePath: $0.relativePath, sha256: $0.sha256) }
    }

    /// Whether publishing `meeting` changes what its pages' files are, against what this device last applied of it
    /// (`base`). On the iPhone such a publication is held like a large one (`publicationHeld`): each commit of a page
    /// republishes the whole conversation, and the strokes of a page being written change every few seconds.
    static func changesPageDrawings(_ meeting: Meeting, to base: Meeting?) -> Bool {
        Set(meeting.pageFiles) != Set(base?.pageFiles ?? [])
    }

    /// The paths of the page files that this device's applied copy of a conversation names (what other devices' unpublished
    /// edits may build on): `MeetingStore.prunePageDrawings` keeps them.
    public func pageFilesInHistory(of meetingID: UUID) -> Set<String> {
        Set(base(meetingID.uuidString)?.pageFiles.map(\.relativePath) ?? [])
    }

    // MARK: On demand

    /// Whether a page's drawing is in the local library. On an on-demand replica one that isn't is a normal state: the words
    /// are there, and `fetchPageDrawing` makes the strokes local.
    public nonisolated func isPageDrawingLocal(_ drawing: PageDrawing, in meetingID: UUID) -> Bool {
        let directory = localRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        guard let url = try? LocalFiles.relativeURL(drawing.relativePath, in: directory),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    /// Makes one drawing local, as `fetchPhoto` does a photo's original: it waits for the object (asking iCloud to download
    /// it), copies it while hashing, and installs it only when the digest matches. A fetched drawing joins the on-demand
    /// cache, so it can be evicted and fetched again. Returns its file in the library.
    @discardableResult
    public func fetchPageDrawing(_ drawing: PageDrawing, in meetingID: UUID, options: AudioFetchOptions = AudioFetchOptions(),
                                 progress: (@Sendable (AudioFetchProgress) -> Void)? = nil) async throws -> URL {
        guard drawing.relativePath.hasPrefix(PageDrawing.folder + "/"), SyncFiles.isHash(drawing.sha256) else {
            throw AudioFetchError.invalidTrack("Page")
        }
        // The fetch is the same as a recording's: a track-shaped description of the drawing.
        let original = RecordingTrack(id: SyncEncoding.uuid("page-drawing:\(drawing.sha256)"), source: .imported, relativePath: drawing.relativePath,
                                      fileName: (drawing.relativePath as NSString).lastPathComponent, sha256: drawing.sha256)
        return try await fetchAudio(for: original, in: meetingID, options: options, progress: progress)
    }
}
