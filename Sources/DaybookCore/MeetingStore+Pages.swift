import Foundation

extension MeetingStore {
    /// Writes the bytes of a page's drawing (`PKDrawing.dataRepresentation()`) into the conversation's folder as the page's
    /// next drawing, at the path its digest gives (`PageDrawing.relativePath(page:sha256:)`): owner-only, atomic, and flushed
    /// with the next barrier like a photo. The same bytes already stored return the file there, written again only when what's
    /// there isn't them. `after` is the committed time of the drawing it replaces: the new one is stamped after it. The caller
    /// commits the returned drawing (`Meeting.commitPageDrawing`) and saves the conversation.
    public func storePageDrawing(_ data: Data, page: UUID, in meeting: Meeting, strokeCount: Int, contentVersion: Int?,
                                 device: String?, after previous: Date?, now: Date = Date()) throws -> PageDrawing {
        let digest = AudioDigest.sha256(data: data)
        let drawing = PageDrawing(relativePath: PageDrawing.relativePath(page: page, sha256: digest), sha256: digest, byteCount: data.count,
                                  strokeCount: strokeCount, editedAt: NotebookPage.stamp(after: previous, now: now),
                                  contentVersion: contentVersion, device: device)
        let directory = try meetingDirectory(for: meeting.id)
        let destination = try LocalFiles.relativeURL(drawing.relativePath, in: directory)
        if (try? destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
           (try? AudioDigest.sha256(fileURL: destination)) == digest {
            LocalFiles.touch(destination, now: now)
            return drawing
        }
        let folder = destination.deletingLastPathComponent()
        try LocalFiles.requireContained(folder, in: directory)
        try LocalFiles.directory(folder)
        try LocalFiles.atomicWrite(data, to: destination)
        noteWrite(destination)
        return drawing
    }

    /// The same, from a file: a recording's staging folder (filing), or a drawing set aside for a merge. The file isn't
    /// moved or changed.
    public func storePageDrawing(from url: URL, page: UUID, in meeting: Meeting, strokeCount: Int, contentVersion: Int?,
                                 device: String?, after previous: Date?, now: Date = Date()) throws -> PageDrawing {
        try storePageDrawing(Data(contentsOf: url), page: page, in: meeting, strokeCount: strokeCount, contentVersion: contentVersion,
                             device: device, after: previous, now: now)
    }

    /// Copies a page's file (a drawing, or a background) from another conversation's folder into this one's at the same path
    /// (page IDs are global, so a folded conversation's page keeps its files' paths), checking its digest. Does nothing when
    /// the file is there already.
    public func copyPageFile(from url: URL, relativePath: String, sha256: String, into meetingID: UUID) throws {
        guard relativePath.hasPrefix(PageDrawing.folder + "/"), SyncFiles.isHash(sha256) else { throw LibraryError.unsafePath(relativePath) }
        let directory = try meetingDirectory(for: meetingID)
        let destination = try LocalFiles.relativeURL(relativePath, in: directory)
        if (try? destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
           (try? AudioDigest.sha256(fileURL: destination)) == sha256 { LocalFiles.touch(destination); return }
        let data = try Data(contentsOf: url)
        guard AudioDigest.sha256(data: data) == sha256 else { throw LibraryError.invalidAudio((relativePath as NSString).lastPathComponent) }
        try LocalFiles.directory(destination.deletingLastPathComponent())
        try LocalFiles.atomicWrite(data, to: destination)
        noteWrite(destination)
    }

    /// Where a page's drawing is in the library. It may not be there yet on an iPhone (`LibrarySyncEngine.fetchPageDrawing`).
    public func url(of drawing: PageDrawing, in meetingID: UUID) throws -> URL {
        try LocalFiles.relativeURL(drawing.relativePath, in: try meetingDirectory(for: meetingID))
    }

    /// Deletes files in a conversation's `Originals/Pages` that no page names (its `drawing`, `setAside`, and `background`),
    /// that `keeping` doesn't name (the files a sync history that other devices may still build on names: an ancestor's
    /// strokes come back when a merge chooses them), and that were last written more than `age` ago (a sync pass may still be
    /// publishing the previous version). Run after a page commit and when a conversation opens. Returns how many it deleted.
    @discardableResult
    public func prunePageDrawings(of meeting: Meeting, keeping: Set<String> = [], olderThan age: TimeInterval = 86_400,
                                  now: Date = Date()) -> Int {
        guard let directory = try? meetingDirectory(for: meeting.id),
              let folder = try? LocalFiles.relativeURL(PageDrawing.folder, in: directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        let named = Set(meeting.pageFiles.map(\.relativePath)).union(keeping)
        var deleted = 0
        for name in names where !named.contains("\(PageDrawing.folder)/\(name)") {
            let file = folder.appendingPathComponent(name)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > age else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { deleted += 1 }
        }
        return deleted
    }
}
