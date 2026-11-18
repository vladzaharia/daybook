import DaybookTestSupport
import XCTest
@testable import DaybookCore

/// Merging two copies of a conversation's pages: none dropped, strokes never mixed, and the same result whichever copy is
/// local.
final class NotebookMergeTests: XCTestCase {
    private let start = NotebookFixtures.start
    private let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    private func page(_ id: UUID? = nil, order: Double = 1, tag: String = "ink", offset: TimeInterval = 10) -> NotebookPage {
        NotebookFixtures.page(id ?? self.id, order: order, tag: tag, offset: offset)
    }

    /// The merge both ways round, and with itself: the laws every merge keeps.
    @discardableResult
    private func assertLaws(_ base: Meeting?, _ a: Meeting, _ b: Meeting, file: StaticString = #filePath, line: UInt = #line) -> MeetingMergeResult {
        let forward = MeetingMerge.merge(base: base, local: a, remote: b)
        let reverse = MeetingMerge.merge(base: base, local: b, remote: a)
        XCTAssertEqual(forward.meeting, reverse.meeting, "commutative", file: file, line: line)
        XCTAssertEqual(forward.warnings, reverse.warnings, file: file, line: line)
        XCTAssertEqual(MeetingMerge.merge(base: base, local: forward.meeting, remote: forward.meeting).meeting, forward.meeting, "idempotent", file: file, line: line)
        XCTAssertEqual(MeetingMerge.merge(base: base, local: forward.meeting, remote: a).meeting.pages?.map(\.id), forward.meeting.pages?.map(\.id), file: file, line: line)
        return forward
    }

    private func meeting(_ pages: [NotebookPage]?, updated: TimeInterval = 0) -> Meeting {
        var meeting = NotebookFixtures.meeting(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!, pages: pages)
        meeting.updatedAt = start.addingTimeInterval(updated)
        return meeting
    }

    // MARK: Survival

    func testBehaviorPagesFromBothSidesSurvive() throws {
        let shared = page(UUID(), order: 1, tag: "shared")
        let base = meeting([shared])
        let fromMac = page(UUID(), order: 2, tag: "mac")
        let fromPhone = page(UUID(), order: 3, tag: "phone")
        let mac = meeting([shared, fromMac], updated: 10)
        let phone = meeting([shared, fromPhone], updated: 20)
        let merged = assertLaws(base, mac, phone).meeting
        XCTAssertEqual(merged.pages?.map(\.id), [shared.id, fromMac.id, fromPhone.id])
        // Without an ancestor: the pages of each.
        XCTAssertEqual(Set(assertLaws(nil, mac, phone).meeting.pages?.map(\.id) ?? []), [shared.id, fromMac.id, fromPhone.id])
        // A copy that never had pages (an older Daybook's) takes the other's.
        let bare = meeting(nil, updated: 30)
        XCTAssertEqual(assertLaws(nil, bare, mac).meeting.pages, mac.pages)
        XCTAssertNil(assertLaws(nil, bare, bare).meeting.pages)
        // A page one side dropped, with the ancestor holding it, is still there.
        let dropped = meeting([], updated: 40)
        XCTAssertEqual(assertLaws(base, dropped, base).meeting.pages?.map(\.id), [shared.id])
    }

    func testBehaviorConcurrentDrawingsKeepNewerSetAsideOtherWithHistory() throws {
        var older = page(tag: "base")
        let base = meeting([older])
        var onMac = older, onPhone = older
        onMac.drawing = NotebookFixtures.drawing(id, "mac", at: start.addingTimeInterval(100))
        onPhone.drawing = NotebookFixtures.drawing(id, "phone", at: start.addingTimeInterval(200))
        onMac.reading = NotebookFixtures.reading(of: onMac.drawing!, [NotebookFixtures.passage(id)])
        onPhone.reading = NotebookFixtures.reading(of: onPhone.drawing!, [NotebookFixtures.passage(id, words: "phone words")], at: 50)
        older = onMac
        let mac = meeting([onMac], updated: 100), phone = meeting([onPhone], updated: 200)
        let result = assertLaws(base, mac, phone)
        let merged = try XCTUnwrap(result.meeting.pages?.first)
        XCTAssertEqual(merged.drawing, onPhone.drawing, "the later strokes are the page's")
        XCTAssertEqual(merged.setAside, [onMac.drawing!], "the other is set aside, its file kept")
        XCTAssertEqual(merged.reading, onPhone.reading, "and what was read follows the strokes chosen, though it was read earlier")
        let entry = try XCTUnwrap(result.meeting.revisions.first { $0.field == "sync:page-drawing:\(id)" })
        XCTAssertEqual(Set([entry.oldValue, entry.newValue]), [onMac.drawing!.sha256, onPhone.drawing!.sha256], "both hashes are in History")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("a page"))
        // A drawing set aside before stays aside, and the winner leaves the list.
        var again = merged
        again.drawing = NotebookFixtures.drawing(id, "third", at: start.addingTimeInterval(300))
        let third = assertLaws(meeting([merged]), meeting([again], updated: 300), meeting([merged], updated: 250)).meeting.pages?.first
        XCTAssertEqual(third?.drawing, again.drawing)
        XCTAssertEqual(third?.setAside, [onMac.drawing!], "kept, not repeated")
        // One side changed, the other didn't: no conflict at all.
        let quiet = assertLaws(base, mac, base)
        XCTAssertEqual(quiet.meeting.pages?.first?.drawing, onMac.drawing)
        XCTAssertNil(quiet.meeting.pages?.first?.setAside)
        XCTAssertTrue(quiet.warnings.isEmpty)
    }

    func testBehaviorDrawingTieBreaksBySHA() throws {
        let base = page(tag: "base")
        var a = base, b = base
        a.drawing = NotebookFixtures.drawing(id, "alpha", at: start.addingTimeInterval(500))
        b.drawing = NotebookFixtures.drawing(id, "beta", at: start.addingTimeInterval(500))
        let greater = max(a.drawing!.sha256, b.drawing!.sha256)
        let result = assertLaws(meeting([base]), meeting([a]), meeting([b]))
        XCTAssertEqual(result.meeting.pages?.first?.drawing?.sha256, greater)
        XCTAssertEqual(result.meeting.pages?.first?.setAside?.map(\.sha256), [min(a.drawing!.sha256, b.drawing!.sha256)])
        // The same strokes committed twice with other details are one drawing, not a conflict.
        var same = a
        same.drawing?.device = "Other iPhone"
        same.drawing?.editedAt = start.addingTimeInterval(501)
        let alike = assertLaws(meeting([base]), meeting([a]), meeting([same]))
        XCTAssertNil(alike.meeting.pages?.first?.setAside)
        XCTAssertTrue(alike.warnings.isEmpty)
        XCTAssertEqual(alike.meeting.pages?.first?.drawing?.device, "Other iPhone", "the later commit's details")
    }

    func testBehaviorReadingOfChosenDrawingWins() throws {
        let base = page(tag: "base")
        var a = base, b = base
        a.drawing = NotebookFixtures.drawing(id, "old", at: start.addingTimeInterval(100))
        b.drawing = NotebookFixtures.drawing(id, "new", at: start.addingTimeInterval(200))
        a.reading = NotebookFixtures.reading(of: a.drawing!, [NotebookFixtures.passage(id, words: "old words")], at: 900)
        b.reading = NotebookFixtures.reading(of: b.drawing!, [NotebookFixtures.passage(id, words: "new words")], at: 300)
        XCTAssertEqual(assertLaws(meeting([base]), meeting([a]), meeting([b])).meeting.pages?.first?.reading?.passages.first?.words, "new words")
        // Both read the same strokes: the later reading, a tie the greater encoding; no conflict either way.
        var c = b
        c.reading = NotebookFixtures.reading(of: b.drawing!, [NotebookFixtures.passage(id, words: "better words")], at: 400)
        let later = assertLaws(meeting([base]), meeting([b]), meeting([c]))
        XCTAssertEqual(later.meeting.pages?.first?.reading?.passages.first?.words, "better words")
        XCTAssertTrue(later.warnings.isEmpty)
        var d = c
        d.reading = NotebookFixtures.reading(of: b.drawing!, [NotebookFixtures.passage(id, words: "tied words")], at: 400)
        XCTAssertNotNil(assertLaws(meeting([base]), meeting([c]), meeting([d])).meeting.pages?.first?.reading)
        // Neither reads the chosen strokes (it hasn't been read yet): the later reading stays until it is.
        var unread = b
        unread.reading = nil
        var stale = a
        stale.drawing = b.drawing
        stale.reading = NotebookFixtures.reading(of: NotebookFixtures.drawing(id, "gone"), [NotebookFixtures.passage(id)], at: 50)
        XCTAssertEqual(assertLaws(meeting([base]), meeting([unread]), meeting([stale])).meeting.pages?.first?.reading, stale.reading)
        // Sketch readings follow the merged reading's digest, then the later analysis.
        let passage = NotebookFixtures.passage(id, kind: .sketch)
        var withSketches = b
        withSketches.reading = NotebookFixtures.reading(of: b.drawing!, [passage])
        var s1 = withSketches, s2 = withSketches
        s1.sketches = [SketchAnalysis(passageID: passage.id, strokeDigest: passage.strokeDigest, analysis: PhotoAnalysis(caption: "Older", createdAt: start))]
        s2.sketches = [SketchAnalysis(passageID: passage.id, strokeDigest: passage.strokeDigest, analysis: PhotoAnalysis(caption: "Newer", createdAt: start.addingTimeInterval(9))),
                       SketchAnalysis(passageID: UUID(), strokeDigest: "x", analysis: PhotoAnalysis(caption: "Other", createdAt: start))]
        let sketches = try XCTUnwrap(assertLaws(meeting([withSketches]), meeting([s1]), meeting([s2])).meeting.pages?.first?.sketches)
        XCTAssertEqual(sketches.count, 2)
        XCTAssertEqual(sketches.first { $0.passageID == passage.id }?.analysis.caption, "Newer")
        var outOfDate = s2
        outOfDate.sketches = [SketchAnalysis(passageID: passage.id, strokeDigest: "other strokes", analysis: PhotoAnalysis(caption: "Stale", createdAt: start.addingTimeInterval(99)))]
        XCTAssertEqual(assertLaws(meeting([withSketches]), meeting([s1]), meeting([outOfDate])).meeting.pages?.first?.sketches?.first?.analysis.caption, "Older",
                       "a reading of other strokes loses though it is newer")
    }

    // MARK: Deletion, corrections, order

    func testBehaviorDeletionAndEditApartDeletionStands() throws {
        let base = page(tag: "base")
        let passage = NotebookFixtures.passage(id)
        var edited = base
        edited.drawing = NotebookFixtures.drawing(id, "more", at: start.addingTimeInterval(100))
        edited.reading = NotebookFixtures.reading(of: edited.drawing!, [passage])
        edited.corrections = [PassageCorrection(passageID: passage.id, strokeDigest: passage.strokeDigest, text: "fixed", editedAt: start)]
        edited.hiddenFromSummary = true
        var deleted = base
        deleted.removedAt = start.addingTimeInterval(150)
        let merged = assertLaws(meeting([base]), meeting([edited], updated: 100), meeting([deleted], updated: 150)).meeting
        let page = try XCTUnwrap(merged.page(id))
        XCTAssertEqual(page.removedAt, start.addingTimeInterval(150), "the deletion stands")
        XCTAssertTrue(merged.visiblePages.isEmpty)
        XCTAssertEqual(page.drawing, edited.drawing, "and the strokes written meanwhile are kept, so Put Back finds them")
        XCTAssertEqual(page.corrections?.first?.text, "fixed")
        XCTAssertEqual(page.hiddenFromSummary, true)
        // A Put Back made after the deletion wins over it.
        var removedBase = base
        removedBase.removedAt = start.addingTimeInterval(150)
        var putBack = removedBase
        putBack.removedAt = nil
        let back = assertLaws(meeting([removedBase]), meeting([putBack], updated: 200), meeting([removedBase], updated: 150)).meeting
        XCTAssertEqual(back.visiblePages.map(\.id), [id])
        // A deletion on one side, none on the other, no ancestor: deleted.
        XCTAssertTrue(assertLaws(nil, meeting([base]), meeting([deleted])).meeting.visiblePages.isEmpty)
    }

    func testBehaviorCorrectionsMergeThreeWay() throws {
        func correction(_ passage: UUID, _ text: String) -> PassageCorrection {
            PassageCorrection(passageID: passage, strokeDigest: "d", text: text, editedAt: start)
        }
        let (p1, p2, p3, p4) = (UUID(), UUID(), UUID(), UUID())
        var base = page(tag: "base")
        base.corrections = [correction(p1, "one"), correction(p2, "two"), correction(p4, "four")]
        var local = base, remote = base
        local.corrections = [correction(p2, "two!"), correction(p4, "four")]                       // removed p1, edited p2
        remote.corrections = [correction(p1, "one"), correction(p2, "two"), correction(p3, "three"), correction(p4, "four?")]   // added p3, edited p4
        let merged = try XCTUnwrap(assertLaws(meeting([base]), meeting([local]), meeting([remote])).meeting.pages?.first?.corrections)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: merged.map { ($0.passageID, $0.text) }), [p2: "two!", p3: "three", p4: "four?"])
        XCTAssertEqual(merged.map(\.passageID), merged.map(\.passageID).sorted { $0.uuidString < $1.uuidString }, "sorted by passage")
        // Both edit one passage: the greater encoding stays, the other is in History, the same either way round.
        var left = base, right = base
        left.corrections = [correction(p1, "uno")]
        right.corrections = [correction(p1, "ein")]
        let result = assertLaws(meeting([base]), meeting([left]), meeting([right]))
        XCTAssertEqual(result.meeting.pages?.first?.corrections?.first?.text, "uno")
        XCTAssertTrue(result.meeting.revisions.contains { $0.field == "sync:page-correction:\(p1)" })
        XCTAssertEqual(result.warnings.count, 1)
        // A removal against an edit: the edit is kept (greater encoding), and noted.
        var removal = base
        removal.corrections = nil
        let clash = assertLaws(meeting([base]), meeting([removal]), meeting([left]))
        XCTAssertEqual(clash.meeting.pages?.first?.corrections?.map(\.text), ["uno"])
        // No ancestor: the corrections of both.
        XCTAssertEqual(try XCTUnwrap(assertLaws(nil, meeting([local]), meeting([remote])).meeting.pages?.first?.corrections).count, 4)
    }

    func testBehaviorConcurrentAppendsOrderDeterministically() throws {
        let base = meeting([page(UUID(), order: 1, tag: "first")])
        var one = NotebookPage(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!, order: 2, now: start.addingTimeInterval(30))
        var two = NotebookPage(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, order: 2, now: start.addingTimeInterval(20))
        var three = NotebookPage(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!, order: 2, now: start.addingTimeInterval(20))
        one.updatedAt = start; two.updatedAt = start; three.updatedAt = start
        var mac = base, phone = base
        mac.pages = (mac.pages ?? []) + [one, three]
        phone.pages = (phone.pages ?? []) + [two]
        let merged = assertLaws(base, mac, phone).meeting
        XCTAssertEqual(merged.pages?.map(\.id).dropFirst(), [two.id, three.id, one.id][...], "equal order: by createdAt, then ID")
        XCTAssertEqual(merged.visiblePages.map(\.id), merged.pages?.map(\.id))
    }

    func testBehaviorMergeCommutativeAndIdempotent() throws {
        // Everything at once: two devices that changed the same pages in every way there is.
        let passage = NotebookFixtures.passage(id)
        var base = page(tag: "base")
        base.reading = NotebookFixtures.reading(of: base.drawing!, [passage])
        base.corrections = [PassageCorrection(passageID: passage.id, strokeDigest: passage.strokeDigest, text: "base", editedAt: start)]
        var a = base, b = base
        a.paper = .grid; b.paper = .dots
        a.order = 4; b.order = 5
        a.hiddenFromSummary = true
        b.removedAt = start.addingTimeInterval(40)
        a.drawing = NotebookFixtures.drawing(id, "a", at: start.addingTimeInterval(60))
        b.drawing = NotebookFixtures.drawing(id, "b", at: start.addingTimeInterval(61))
        a.setAside = [NotebookFixtures.drawing(id, "old-a", at: start.addingTimeInterval(5))]
        b.setAside = [NotebookFixtures.drawing(id, "old-b", at: start.addingTimeInterval(6)), NotebookFixtures.drawing(id, "a", at: start.addingTimeInterval(1))]
        a.reading = NotebookFixtures.reading(of: a.drawing!, [passage], at: 200)
        b.reading = NotebookFixtures.reading(of: b.drawing!, [passage], at: 100)
        a.corrections = [PassageCorrection(passageID: passage.id, strokeDigest: passage.strokeDigest, text: "from a", editedAt: start)]
        b.corrections = [PassageCorrection(passageID: passage.id, strokeDigest: passage.strokeDigest, text: "from b", editedAt: start)]
        a.origin = PhotoOrigin(kind: "daybook.iphone", serial: "one")
        b.origin = PhotoOrigin(kind: "daybook.iphone", serial: "two")
        a.createdAt = start.addingTimeInterval(-9)
        a.updatedAt = start.addingTimeInterval(80)
        let extra = page(UUID(), order: 9, tag: "extra")
        let left = meeting([a, extra], updated: 80), right = meeting([b], updated: 70)
        assertLaws(meeting([base]), left, right)
        assertLaws(nil, left, right)
        let merged = try XCTUnwrap(MeetingMerge.merge(base: meeting([base]), local: left, remote: right).meeting.page(id))
        XCTAssertEqual(merged.createdAt, start.addingTimeInterval(-9), "the earlier")
        XCTAssertEqual(merged.updatedAt, start.addingTimeInterval(80), "the later")
        XCTAssertEqual(merged.drawing?.sha256, b.drawing?.sha256)
        XCTAssertEqual(Set(merged.setAside?.map(\.sha256) ?? []), Set([a.drawing!, a.setAside![0], b.setAside![0]].map(\.sha256)), "everything set aside once, the winner not among them")
        XCTAssertEqual(merged.setAside?.map(\.editedAt), merged.setAside?.map(\.editedAt).sorted(by: >), "newest first")
        // Unknown keys merge key by key.
        var unknownA = a, unknownB = b
        unknownA.unknownFields = UnknownFields(["future": .string("a")])
        unknownB.unknownFields = UnknownFields(["future": .string("b"), "other": .number(1)])
        let unknown = assertLaws(meeting([base]), meeting([unknownA]), meeting([unknownB]))
        XCTAssertNotNil(unknown.meeting.pages?.first?.unknownFields["other"])
        XCTAssertTrue(unknown.meeting.revisions.contains { $0.field == "sync:page-unknown:\(id):future" })
    }

    // MARK: Old copies and the store

    func testBehaviorSnapshotFromBeforePagesKeepsParentPages() throws {
        let kept = page(UUID(), order: 1, tag: "kept")
        let parent = meeting([kept])
        // An older Daybook edited it and dropped what it doesn't know.
        var snapshot = parent
        snapshot.pages = nil
        snapshot.title = "Renamed"
        let restored = snapshot.restoringPages(from: parent)
        XCTAssertEqual(restored.pages, [kept])
        XCTAssertEqual(restored.title, "Renamed", "everything else is the snapshot's")
        // One that kept them, or whose parent had none, is left as it is.
        XCTAssertEqual(parent.restoringPages(from: meeting([page()])).pages, [kept])
        XCTAssertNil(snapshot.restoringPages(from: meeting(nil)).pages)
        // Merging it with the copy that has them keeps them too, however the sides fall.
        let merged = assertLaws(parent, snapshot, parent).meeting
        XCTAssertEqual(merged.pages, [kept])
        XCTAssertEqual(merged.title, "Renamed")
    }

    func testBehaviorStaleSnapshotCannotDropPages() async throws {
        let root = makeTemporaryFolder("DaybookNotebookTests")
        let store = try MeetingStore(rootURL: root.appendingPathComponent("Library"))
        var current = Meeting(title: "Notebook")
        try await store.save(current)
        let stale = current
        let written = page(UUID(), order: 1, tag: "written")
        current.addPage(written)
        try await store.save(current)
        // A snapshot queued before the page was added can't take it away.
        try await store.save(stale)
        let reloaded = try await store.load(current.id)
        XCTAssertEqual(reloaded.pages?.map(\.id), [written.id])
        // Deleting marks it; the mark stays.
        current.removePage(written.id)
        try await store.save(current)
        let loaded = try await store.load(current.id)
        XCTAssertEqual(loaded.pages?.count, 1)
        XCTAssertNotNil(loaded.pages?.first?.removedAt)
        XCTAssertTrue(loaded.visiblePages.isEmpty)
    }

    func testBehaviorValidateRejectsPagePathOutsideFolderAndBadSizes() async throws {
        let root = makeTemporaryFolder("DaybookNotebookValidation")
        let store = try MeetingStore(rootURL: root.appendingPathComponent("Library"))
        let meeting = Meeting(title: "Notebook")
        func saving(_ change: (inout NotebookPage) -> Void) async -> Error? {
            var copy = meeting
            var made = page(UUID(), tag: "ok")
            change(&made)
            copy.pages = [made]
            do { try await store.save(copy); return nil } catch { return error }
        }
        let accepted = await saving { _ in }
        XCTAssertNil(accepted)
        let outside = await saving { $0.drawing?.relativePath = "Originals/Photos/x.pkdrawing" }
        XCTAssertNotNil(outside)
        let escaping = await saving { $0.drawing?.relativePath = "Originals/Pages/../../meeting.json" }
        XCTAssertNotNil(escaping)
        let asideOutside = await saving { $0.setAside = [NotebookFixtures.drawing($0.id, "x")]; $0.setAside?[0].relativePath = "/etc/passwd" }
        XCTAssertNotNil(asideOutside)
        let aside = await saving { $0.setAside = [NotebookFixtures.drawing($0.id, "x")] }
        XCTAssertNil(aside, "a set-aside drawing in the folder is fine")
        for size in [0.0, -1, .infinity, .nan] {
            let wide = await saving { $0.width = size }
            XCTAssertNotNil(wide, "width \(size)")
            let tall = await saving { $0.height = size }
            XCTAssertNotNil(tall, "height \(size)")
        }
        let slow = await saving {
            let passage = NotebookFixtures.passage($0.id, time: 5)
            $0.reading = NotebookFixtures.reading(of: $0.drawing!, [passage])
            $0.reading?.passages[0].time = -1
        }
        XCTAssertNotNil(slow)
        let finite = await saving { $0.reading = NotebookFixtures.reading(of: $0.drawing!, [NotebookFixtures.passage($0.id, time: 5)]) }
        XCTAssertNil(finite)
    }
}
