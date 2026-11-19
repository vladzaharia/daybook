import Foundation

// Merging two copies of a conversation's pages (`MeetingMerge`). Pages are originals: every page either copy has
// survives. Strokes are never mixed: of two drawings made apart the later one is the page's, and the other is set aside
// so Version History can put it back. A reading is a measurement of one drawing, so it follows the drawing that was chosen.

extension NotebookPage {
    /// Field-wise merge of two copies of one page: the person's corrections, deletion, and summary choice, and
    /// processing's readings, are independent changes. A conflicting value keeps one deterministically (the same on
    /// every device, whichever copy is local); `conflict` reports the field for History.
    static func merged(base: NotebookPage?, local: NotebookPage, remote: NotebookPage,
                       conflict: (String, String, String) -> Void) -> NotebookPage {
        /// The three-way pick; a field named "" is settled the same way without a note in History.
        func pick<T: Equatable & Encodable>(_ field: String, _ a: T, _ b: T, _ old: T?) -> T {
            if a == b { return a }
            if let old { if a == old { return b }; if b == old { return a } }
            let left = SyncEncoding.string(a), right = SyncEncoding.string(b)
            if !field.isEmpty { conflict(field, min(left, right), max(left, right)) }
            return left > right ? a : b
        }
        let id = local.id
        var result = local
        result.order = pick("", local.order, remote.order, base?.order)
        // Made once and never changed: the copies agree in practice, and if not, every device picks alike.
        result.width = max(local.width, remote.width)
        result.height = max(local.height, remote.height)
        result.createdAt = min(local.createdAt, remote.createdAt)
        switch (local.origin, remote.origin) {
        case let (a?, b?): result.origin = SyncEncoding.string(a) >= SyncEncoding.string(b) ? a : b
        case let (a, b): result.origin = a ?? b
        }
        result.$paper = pick("page-paper:\(id)", local.$paper, remote.$paper, base?.$paper)

        let (drawing, beaten) = mergedDrawing(base: base?.drawing, local.drawing, remote.drawing) { smaller, larger in
            conflict("page-drawing:\(id)", smaller, larger)
        }
        result.drawing = drawing
        result.setAside = mergedSetAside(local.setAside, remote.setAside, beaten, chosen: drawing)

        result.reading = mergedReading(local.reading, remote.reading, drawing: drawing)
        result.corrections = mergedCorrections(base: base?.corrections, local: local.corrections, remote: remote.corrections,
                                               hasBase: base != nil, conflict: conflict)
        result.sketches = mergedSketches(local.sketches, remote.sketches, reading: result.reading)
        result.hiddenFromSummary = pick("page-summary:\(id)", local.hiddenFromSummary, remote.hiddenFromSummary, base.map(\.hiddenFromSummary))
        // The picture under the strokes: a three-way pick, and the page takes its aspect (the A5 width, the background's
        // height), so the size is the same on every device whichever picture stands. A page without one keeps the greater size.
        result.background = pick("page-background:\(id)", local.background, remote.background, base.map(\.background))
        if result.background != nil { (result.width, result.height) = NotebookPage.size(for: result.background) }
        result.erased = ErasedStroke.merged(local.erased, remote.erased)
        // A deletion and an edit made apart: the deletion stands, and a Put Back made later wins over it.
        // When both changed it (one put the page back, the other deleted it again) the greater encoding stays, and `null`
        // is greater than any date: the page comes back, and nothing is hidden by a conflict. A decision, pinned by a test.
        // With no ancestor, a deletion on one side is a deletion.
        if base == nil, local.removedAt == nil || remote.removedAt == nil {
            result.removedAt = local.removedAt ?? remote.removedAt
        } else {
            result.removedAt = pick("page-removed:\(id)", local.removedAt, remote.removedAt, base.map(\.removedAt))
        }
        result.updatedAt = max(local.updatedAt, remote.updatedAt)
        result.unknownFields = UnknownFields.merged(base: base?.unknownFields, local.unknownFields, remote.unknownFields) { key, smaller, larger in
            conflict("page-unknown:\(id):\(key)", smaller, larger)
        }
        return result
    }

    /// Both copies' pages: every page either copy has, or the ancestor had (none is dropped), merged field by field; a
    /// page one copy has is taken as it is. Sorted by `order`, `createdAt`, then `id`, so the order never depends on
    /// which copy is local.
    static func mergedList(base: [NotebookPage], local: [NotebookPage], remote: [NotebookPage],
                           conflict: (String, String, String) -> Void) -> [NotebookPage] {
        let ids = Set((base + local + remote).map(\.id))
        let merged = ids.compactMap { id -> NotebookPage? in
            let a = local.first { $0.id == id }, b = remote.first { $0.id == id }, old = base.first { $0.id == id }
            if let a, let b { return a == b ? a : merged(base: old, local: a, remote: b, conflict: conflict) }
            return a ?? b ?? old
        }
        return merged.sorted(by: precedes)
    }

    /// The drawing of a page and the drawing it beat, if two were made apart. One side unchanged from the ancestor takes
    /// the other's. Of two changes the later `editedAt` wins, a tie the greater digest.
    private static func mergedDrawing(base: PageDrawing?, _ a: PageDrawing?, _ b: PageDrawing?,
                                      conflict: (String, String) -> Void) -> (chosen: PageDrawing?, beaten: PageDrawing?) {
        if a == b { return (a, nil) }
        guard let a else { return (b, nil) }
        guard let b else { return (a, nil) }
        if let base { if a == base { return (b, nil) }; if b == base { return (a, nil) } }
        let winner = (a.editedAt, a.sha256, SyncEncoding.string(a)) > (b.editedAt, b.sha256, SyncEncoding.string(b)) ? a : b
        let loser = winner == a ? b : a
        // The same strokes with other details (who committed them, when) aren't two drawings.
        if a.sha256 == b.sha256 { return (winner, nil) }
        conflict(min(a.sha256, b.sha256), max(a.sha256, b.sha256))
        return (winner, loser)
    }

    /// Drawings no copy chose, by digest, newest first, without the one chosen. Nil when none.
    static func mergedSetAside(_ a: [PageDrawing]?, _ b: [PageDrawing]?, _ beaten: PageDrawing?, chosen: PageDrawing?) -> [PageDrawing]? {
        var byDigest: [String: PageDrawing] = [:]
        for drawing in (a ?? []) + (b ?? []) + [beaten].compactMap({ $0 }) where drawing.sha256 != chosen?.sha256 {
            if let held = byDigest[drawing.sha256],
               (held.editedAt, SyncEncoding.string(held)) >= (drawing.editedAt, SyncEncoding.string(drawing)) { continue }
            byDigest[drawing.sha256] = drawing
        }
        let sorted = byDigest.values.sorted { $0.editedAt != $1.editedAt ? $0.editedAt > $1.editedAt : $0.sha256 < $1.sha256 }
        return sorted.isEmpty ? nil : sorted
    }

    /// A reading is a measurement. Of the two, the better: one of the chosen drawing, then by the newer grouping (so a
    /// version never undoes a newer one's reading, which it would then be read again for forever), then the later, then
    /// the greater encoding.
    private static func mergedReading(_ a: PageReading?, _ b: PageReading?, drawing: PageDrawing?) -> PageReading? {
        func rank(_ reading: PageReading) -> (Int, Int, Date, String) {
            (reading.drawingSHA256 == drawing?.sha256 ? 1 : 0, reading.groupingVersion, reading.readAt, SyncEncoding.string(reading))
        }
        return [a, b].compactMap { $0 }.max { rank($0) < rank($1) }
    }

    /// Each passage's correction, three-way: absence on one side where the ancestor had it is a removal. With no
    /// ancestor, a correction one side lacks was added on the other. Sorted by passage.
    private static func mergedCorrections(base: [PassageCorrection]?, local: [PassageCorrection]?, remote: [PassageCorrection]?,
                                          hasBase: Bool, conflict: (String, String, String) -> Void) -> [PassageCorrection]? {
        let ids = Set((base ?? []).map(\.passageID) + (local ?? []).map(\.passageID) + (remote ?? []).map(\.passageID))
        let merged = ids.compactMap { id -> PassageCorrection? in
            let a = local?.first { $0.passageID == id }, b = remote?.first { $0.passageID == id }
            if a == b { return a }
            if hasBase {
                let old = base?.first { $0.passageID == id }
                if a == old { return b }
                if b == old { return a }
            } else if a == nil || b == nil {
                return a ?? b
            }
            let left = SyncEncoding.string(a), right = SyncEncoding.string(b)
            conflict("page-correction:\(id)", min(left, right), max(left, right))
            return left > right ? a : b
        }
        return merged.isEmpty ? nil : merged.sorted { $0.passageID.uuidString < $1.passageID.uuidString }
    }

    /// Each passage's sketch reading: one of the strokes the merged reading has, else the later; the same either way
    /// round. Sorted by passage.
    private static func mergedSketches(_ a: [SketchAnalysis]?, _ b: [SketchAnalysis]?, reading: PageReading?) -> [SketchAnalysis]? {
        let digests = Dictionary((reading?.passages ?? []).map { ($0.id, $0.strokeDigest) }, uniquingKeysWith: { first, _ in first })
        func rank(_ sketch: SketchAnalysis) -> (Int, Date, String) {
            (digests[sketch.passageID] == sketch.strokeDigest ? 1 : 0, sketch.analysis.createdAt, SyncEncoding.string(sketch))
        }
        var chosen: [UUID: SketchAnalysis] = [:]
        for sketch in (a ?? []) + (b ?? []) {
            if let held = chosen[sketch.passageID], rank(held) >= rank(sketch) { continue }
            chosen[sketch.passageID] = sketch
        }
        return chosen.isEmpty ? nil : chosen.values.sorted { $0.passageID.uuidString < $1.passageID.uuidString }
    }
}

extension NotebookPage {
    /// This page, a snapshot's copy, with the strokes the stored copy has that it lacks: a snapshot made before the
    /// stored copy's later commit can't take them back. The later drawing stays the page's, the other is set aside (its
    /// file is kept), and the stored copy's set-aside drawings and reading of the kept drawing come along.
    func keepingStrokes(of stored: NotebookPage) -> NotebookPage {
        var result = self
        if let kept = stored.drawing, drawing == nil || (kept.sha256 != drawing?.sha256 && kept.editedAt > drawing!.editedAt) {
            let replaced = drawing
            result.drawing = kept
            result.setAside = Self.mergedSetAside(setAside, stored.setAside, replaced, chosen: kept)
            if let reading = stored.reading, reading.drawingSHA256 == kept.sha256 { result.reading = reading }
        } else if let stored = stored.setAside {
            result.setAside = Self.mergedSetAside(setAside, stored, nil, chosen: drawing)
        }
        return result
    }
}

extension Meeting {
    /// This snapshot with every page of `parent` it lacks, in page order: it was written by a Daybook that predates pages,
    /// which drops what it doesn't know on edit, or keeps one whole `pages` array when two changed apart. No Daybook that
    /// knows pages ever removes one (deleting marks it), so a page missing here was lost.
    func restoringPages(from parent: Meeting) -> Meeting {
        let known = Set((pages ?? []).map(\.id))
        let missing = (parent.pages ?? []).filter { !known.contains($0.id) }
        guard !missing.isEmpty else { return self }
        var result = self
        result.pages = ((pages ?? []) + missing).sorted(by: NotebookPage.precedes)
        return result
    }
}

extension Meeting {
    /// This snapshot of an event with several parents, with the notebook it should have: written by a Daybook that predates
    /// pages, it keeps one parent's whole `pages` (and `pageTurns`) as the unknown keys they are, so edits and deletions made
    /// to a page on the other side are lost, not only the pages that side added. A Daybook that knows pages never keeps one
    /// side's array unless it already equals the merge, so an array that equals one parent's and not the merge of them is
    /// replaced by the merge (`merged`, the parents merged with their common ancestor as base). Then every page of the merge the
    /// snapshot lacks is put back (`restoringPages`).
    func repairingNotebook(parents: [Meeting], merged: Meeting) -> Meeting {
        var result = self
        if let kept = pages, kept != merged.pages, parents.contains(where: { $0.pages == kept }) { result.pages = merged.pages }
        if let kept = pageTurns, kept != merged.pageTurns, parents.contains(where: { $0.pageTurns == kept }) { result.pageTurns = merged.pageTurns }
        return result.restoringPages(from: merged)
    }
}
