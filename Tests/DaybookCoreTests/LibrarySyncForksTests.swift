import XCTest
@testable import DaybookCore

/// What a deletion never saw is kept (`Meeting.hasContent(notIn:)`): notebook pages count as person-made content.
final class LibrarySyncForksTests: XCTestCase {
    func testBehaviorDeletedConversationWithNewPageIsKept() {
        let seen = NotebookFixtures.meeting()
        XCTAssertFalse(seen.hasContent(notIn: seen), "nothing was added")
        // A page written on a device that was offline while the conversation was deleted elsewhere.
        var local = seen
        local.addPage(NotebookFixtures.page(order: 1, tag: "offline"))
        XCTAssertTrue(local.hasContent(notIn: seen))
        XCTAssertTrue(local.hasContent(notIn: nil), "with no copy the deletion saw, anything counts")
        // A blank page counts as well: the person added it.
        var blank = seen
        blank.addPage(NotebookPage(order: 1, now: seen.updatedAt))
        XCTAssertTrue(blank.hasContent(notIn: seen))
        // A page the deletion saw, left alone, is nothing new.
        var withPage = seen
        withPage.addPage(NotebookFixtures.page(order: 1, tag: "seen"))
        XCTAssertFalse(withPage.hasContent(notIn: withPage))
        // New strokes on a page it saw are.
        var written = withPage
        written.commitPageDrawing(withPage.pages![0].id, drawing: NotebookFixtures.drawing(withPage.pages![0].id, "more"), now: seen.updatedAt.addingTimeInterval(10))
        XCTAssertTrue(written.hasContent(notIn: withPage))
        // A page the person deleted isn't content, and a reading or a correction alone isn't new work.
        var deleted = seen
        deleted.pages = [{ var page = NotebookFixtures.page(order: 1, tag: "gone"); page.removedAt = seen.updatedAt; return page }()]
        XCTAssertFalse(deleted.hasContent(notIn: seen))
        var read = withPage
        let id = withPage.pages![0].id
        read.applyPageReading(id, reading: NotebookFixtures.reading(of: withPage.pages![0].drawing!, [NotebookFixtures.passage(id)]))
        XCTAssertFalse(read.hasContent(notIn: withPage))
        // Kept as a new conversation, its pages come with it.
        let kept = local.keptAs(UUID(), field: "source:kept-after-deletion", title: "Kept")
        XCTAssertEqual(kept.pages, local.pages)
        XCTAssertNotEqual(kept.id, local.id)
    }

    func testBehaviorConversationWithPagesIsNeverMovedToTheTrashOnItsOwn() {
        var meeting = NotebookFixtures.meeting()
        XCTAssertFalse(meeting.hasPersonMadeContent)
        meeting.addPage(NotebookFixtures.page())
        XCTAssertTrue(meeting.hasPersonMadeContent)
        meeting.removePage(meeting.pages![0].id)
        XCTAssertFalse(meeting.hasPersonMadeContent, "a deleted page is no more content than a deleted photo")
    }
}
