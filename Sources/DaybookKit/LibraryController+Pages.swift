import DaybookCore
import Foundation

// A conversation's notebook pages (`NotebookPages.swift`). Each change saves with the conversation, like the notes: a thin
// `update` over the Core edit. A page's strokes are files in the conversation's folder (`MeetingStore.storePageDrawing`).
extension LibraryController {
    /// A new page. Its strokes come with the first commit, so an empty page never syncs.
    public func addPage(_ page: NotebookPage, to id: UUID) {
        update(id) { $0.addPage(page) }
    }

    /// Stores the strokes (`PKDrawing.dataRepresentation()`) as the page's next drawing and records it, stamped after the one
    /// it replaces. The same bytes again change nothing. Files no page names any more, and are old, go afterwards.
    @discardableResult
    public func commitPageDrawing(_ data: Data, page pageID: UUID, in id: UUID, strokeCount: Int, contentVersion: Int?,
                                  device: String?, now: Date = Date()) async throws -> PageDrawing {
        guard let store, let meeting = meeting(id) else { throw DaybookError.libraryUnavailable }
        let drawing = try await store.storePageDrawing(data, page: pageID, in: meeting, strokeCount: strokeCount, contentVersion: contentVersion,
                                                       device: device, after: meeting.page(pageID)?.drawing?.editedAt, now: now)
        update(id) { $0.commitPageDrawing(pageID, drawing: drawing, now: now) }
        await prunePageDrawings(of: id, now: now)
        return self.meeting(id)?.page(pageID)?.drawing ?? drawing
    }

    /// A drawing a recording kept in its staging folder, stored in the conversation's folder for filing
    /// (`adoptRecordedPages`). The file isn't moved or changed.
    public func storeRecordedPageDrawing(from url: URL, page pageID: UUID, in id: UUID, strokeCount: Int, contentVersion: Int?,
                                         device: String?, after previous: Date?, now: Date = Date()) async throws -> PageDrawing {
        guard let store, let meeting = meeting(id) else { throw DaybookError.libraryUnavailable }
        return try await store.storePageDrawing(from: url, page: pageID, in: meeting, strokeCount: strokeCount, contentVersion: contentVersion,
                                                device: device, after: previous, now: now)
    }

    /// What reading the page's strokes found; dropped when the page has other strokes now.
    public func applyPageReading(_ reading: PageReading, to pageID: UUID, in id: UUID) {
        update(id) { $0.applyPageReading(pageID, reading: reading) }
    }

    /// The person's own words for a passage.
    public func correctPassage(pageID: UUID, passageID: UUID, text: String, in id: UUID) {
        update(id) { $0.correctPassage(pageID: pageID, passageID: passageID, text: text) }
    }

    /// Deletes a page. Its record and files stay, so Undo and Version History can put it back. Returns what undoes it.
    public func removePage(_ pageID: UUID, in id: UUID) -> (() -> Void)? {
        guard meeting(id)?.page(pageID)?.removedAt == nil else { return nil }
        update(id) { $0.removePage(pageID) }
        return { [weak self] in self?.update(id) { $0.restorePage(pageID) } }
    }

    /// Keeps a page out of summaries, or lets them use it again.
    public func setPageHiddenFromSummary(_ pageID: UUID, hidden: Bool, in id: UUID) {
        update(id) { $0.setPageHiddenFromSummary(pageID, hidden: hidden) }
    }

    /// Puts a deleted page back.
    public func restorePage(_ pageID: UUID, in id: UUID) {
        update(id) { $0.restorePage(pageID) }
    }

    /// Where a page's drawing is in the library. On an iPhone it may not be there yet; the sync engine's `fetchPageDrawing`
    /// brings it.
    public func pageDrawingURL(for drawing: PageDrawing, in id: UUID) async throws -> URL {
        guard let store else { throw DaybookError.libraryUnavailable }
        return try await store.url(of: drawing, in: id)
    }

    /// Whether a page's drawing is in this library now.
    public func hasLocalPageDrawing(_ drawing: PageDrawing, in id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(drawing.relativePath)").path)
    }

    /// Deletes the conversation's page files that nothing names and that are old (`MeetingStore.prunePageDrawings`), keeping
    /// those the sync history names (what other devices' unpublished edits may build on).
    public func prunePageDrawings(of id: UUID, now: Date = Date()) async {
        guard let store else { return }
        let history = await sync?.engine?.pageFilesInHistory(of: id) ?? []
        // Read after the await: what a pass applied meanwhile (a revert naming an old drawing again) counts.
        guard let meeting = meeting(id) else { return }
        await store.prunePageDrawings(of: meeting, keeping: history, now: now)
    }
}
