import Foundation

// Changes to a conversation's notebook pages. Each sets `updatedAt` on the page and the conversation; the ones the
// person would want to find again are recorded in Version History (a stroke commit isn't: there would be one per page turn).

/// A page as a recording leaves it, for filing.
public struct RecordedPage: Sendable, Equatable {
    /// The page, its drawing already stored in the conversation's folder.
    public var page: NotebookPage
    /// The conversation's copy when the recording loaded it; nil for a page made during the recording.
    public var base: NotebookPage?

    public init(page: NotebookPage, base: NotebookPage? = nil) {
        self.page = page; self.base = base
    }
}

extension Meeting {
    /// Adds a page, recorded in Version History. Does nothing when a page has its ID.
    public mutating func addPage(_ page: NotebookPage) {
        guard self.page(page.id) == nil else { return }
        pages = (pages ?? []) + [page]
        revisions.append(MeetingRevision(date: page.updatedAt, kind: .page(page.id), oldValue: "", newValue: "added"))
        updatedAt = max(updatedAt, page.updatedAt)
    }

    /// Stores new strokes for a page, stamped after the drawing they replace. Not recorded in Version History. Ignored for
    /// a deleted page and for the strokes it has already.
    public mutating func commitPageDrawing(_ pageID: UUID, drawing: PageDrawing, now: Date = Date()) {
        guard let index = pages?.firstIndex(where: { $0.id == pageID }), pages?[index].removedAt == nil,
              pages?[index].drawing?.sha256 != drawing.sha256 else { return }
        var stamped = drawing
        stamped.editedAt = NotebookPage.stamp(after: pages?[index].drawing?.editedAt, now: now)
        pages?[index].drawing = stamped
        pages?[index].updatedAt = now
        updatedAt = now
    }

    /// Stores what reading a page's strokes found, only when it read the strokes the page has now (a result for strokes
    /// since replaced is dropped). A passage whose ID and start are unchanged and which the new reading placed on no
    /// clock keeps the time it had: a re-read after filing has no recording clock.
    public mutating func applyPageReading(_ pageID: UUID, reading: PageReading, now: Date = Date()) {
        guard let index = pages?.firstIndex(where: { $0.id == pageID }),
              reading.drawingSHA256 == pages?[index].drawing?.sha256 else { return }
        var stored = reading
        let earlier = pages?[index].reading?.passages ?? []
        for position in stored.passages.indices where stored.passages[position].trackID == nil && stored.passages[position].time == nil {
            let passage = stored.passages[position]
            guard let before = earlier.first(where: { $0.id == passage.id && $0.start == passage.start }) else { continue }
            stored.passages[position].trackID = before.trackID
            stored.passages[position].time = before.time
        }
        guard pages?[index].reading != stored else { return }
        pages?[index].reading = stored
        pages?[index].updatedAt = now
        updatedAt = now
    }

    /// The person's words for a passage. Empty words, or the words that were read, take the correction away. Recorded in
    /// Version History as the words shown before and after.
    public mutating func correctPassage(pageID: UUID, passageID: UUID, text: String, now: Date = Date()) {
        guard let index = pages?.firstIndex(where: { $0.id == pageID }),
              let passage = pages?[index].passages.first(where: { $0.id == passageID }) else { return }
        let page = pages![index]
        let before = page.words(of: passage) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let read = (passage.words ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let keeps = !trimmed.isEmpty && trimmed != read
        let after = keeps ? trimmed : passage.words ?? ""
        guard after != before else { return }
        var corrections = (page.corrections ?? []).filter { $0.passageID != passageID }
        if keeps {
            corrections.append(PassageCorrection(passageID: passageID, strokeDigest: passage.strokeDigest, text: trimmed, editedAt: now))
            corrections.sort { $0.passageID.uuidString < $1.passageID.uuidString }
        }
        pages?[index].corrections = corrections.isEmpty ? nil : corrections
        pages?[index].updatedAt = now
        revisions.append(MeetingRevision(date: now, kind: .passage(passageID), oldValue: before, newValue: after))
        updatedAt = now
    }

    /// Deletes a page, keeping its record and files so it can be put back. Recorded in Version History.
    public mutating func removePage(_ id: UUID, at date: Date = Date()) {
        guard let index = pages?.firstIndex(where: { $0.id == id }), pages?[index].removedAt == nil else { return }
        pages?[index].removedAt = date
        pages?[index].updatedAt = date
        revisions.append(MeetingRevision(date: date, kind: .page(id), oldValue: "present", newValue: "removed"))
        updatedAt = date
    }

    /// Puts a deleted page back where it was. Recorded in Version History.
    public mutating func restorePage(_ id: UUID, at date: Date = Date()) {
        guard let index = pages?.firstIndex(where: { $0.id == id }), pages?[index].removedAt != nil else { return }
        pages?[index].removedAt = nil
        pages?[index].updatedAt = date
        revisions.append(MeetingRevision(date: date, kind: .page(id), oldValue: "removed", newValue: "present"))
        updatedAt = date
    }

    /// Takes the pages a recording wrote on filing. A page made during the recording is added; one the recording loaded
    /// from the conversation is merged three-way with the copy it loaded (`NotebookPage.merged`), so what was changed
    /// elsewhere meanwhile survives.
    public mutating func adoptRecordedPages(_ recorded: [RecordedPage], now: Date = Date()) {
        for entry in recorded {
            guard let index = pages?.firstIndex(where: { $0.id == entry.page.id }) else {
                addPage(entry.page)
                continue
            }
            guard let base = entry.base else { continue }
            let merged = NotebookPage.merged(base: base, local: pages![index], remote: entry.page) { _, _, _ in }
            guard merged != pages![index] else { continue }
            pages?[index] = merged
            updatedAt = now
        }
    }
}
