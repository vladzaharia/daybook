import DaybookCore
import PencilKit
import XCTest

@testable import DaybookPhone
@testable import DaybookUI

/// The notebook's session over a stand-in for where pages are kept: when pages settle, what they commit, what is read and
/// what's dropped, what's recorded about erasures and page turns, and that a page whose strokes aren't here is never written.
@MainActor
final class NotebookSessionTests: XCTestCase {
    private let began = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Where the pages are kept, as the notebook sees it.
    @MainActor
    private final class Store {
        var pages: [NotebookPage] = []
        var content: [UUID: NotebookPageContent] = [:]
        var commits: [(page: UUID, data: Data)] = []
        var readings: [(page: UUID, reading: PageReading)] = []
        var turns: [PageTurn] = []
        var erased: [UUID: [ErasedStroke]] = [:]
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_100)

        var model: NotebookModel {
            NotebookModel(
                pages: { self.pages }, content: { self.content[$0] ?? .blank }, add: { self.pages.append($0) },
                saveDraft: { _, _ in true },
                commit: { id, data, _, _ in
                    self.commits.append((id, data))
                    return NotebookSession.sha256(data)
                },
                applyReading: { self.readings.append(($0, $1)) }, correct: { _, _, _ in }, remove: { _ in nil },
                recordErasures: { self.erased[$0, default: []] += $1 }, logTurn: { self.turns.append($0) },
                anchor: { (nil, $0.timeIntervalSince(self.clock) + 40) })
        }
    }

    private func session(_ store: Store, idle: Duration = .seconds(60), layout: NotebookLayout = .single(scale: 1)) -> NotebookSession {
        let session = NotebookSession(now: { store.clock }, idleSettle: idle, draftDelay: .seconds(60))
        // These tests are about when pages settle, not about reading: a real reading (PencilKit, then Vision when it can't) outlives
        // the test and, on a slow runner, holds threads the next tests' recorders need.
        session.reader = { [began] _, sha, _, _ in PageReading(drawingSHA256: sha, passages: [], readAt: began) }
        session.resolve(layout)
        session.bind(store.model)
        session.show(slot: 0)
        return session
    }

    private func store(pages: Int, written: Int = 0) -> Store {
        let store = Store()
        for index in 0..<pages {
            let page = NotebookPage(order: Double(index + 1), now: began)
            store.pages.append(page)
            if index < written {
                store.content[page.id] = .strokes(SyntheticInk.drawing("hello", start: began).dataRepresentation())
            }
        }
        return store
    }

    private func write(_ session: NotebookSession, page: UUID, _ drawing: PKDrawing) throws {
        let view = try XCTUnwrap(session.canvas(for: page))
        view.load(drawing)
        session.changed(view)
    }

    private func settle(_ seconds: Double = 0.25) async { try? await Task.sleep(for: .seconds(seconds)) }

    func testBehaviorPageTurnSettlesLeavingPages() async throws {
        let store = store(pages: 3)
        let session = session(store)
        session.show(slot: 0)
        try write(session, page: store.pages[0].id, SyntheticInk.drawing("hello", start: began))
        XCTAssertTrue(store.commits.isEmpty, "nothing commits while writing")
        session.turn(1)
        await settle()
        XCTAssertEqual(store.commits.map(\.page), [store.pages[0].id])
        XCTAssertEqual(store.turns.map(\.pages), [[store.pages[1].id]], "the turn is logged with the pages now open")
        XCTAssertEqual(store.turns.first?.time ?? 0, 40, accuracy: 0.001, "against the recording clock")
    }

    func testBehaviorIdleSettlesAfterEightSeconds() async throws {
        let store = store(pages: 1)
        let session = session(store, idle: .milliseconds(60))
        try write(session, page: store.pages[0].id, SyntheticInk.drawing("hello", start: began))
        await settle(0.02)
        XCTAssertTrue(store.commits.isEmpty)
        await settle(0.3)
        XCTAssertEqual(store.commits.count, 1)
        XCTAssertEqual(NotebookSession(now: Date.init).idleSettle, .seconds(8))
    }

    func testBehaviorUnchangedBytesCommitNothing() async throws {
        let store = store(pages: 1)
        let session = session(store)
        let id = store.pages[0].id
        try write(session, page: id, SyntheticInk.drawing("hello", start: began))
        await session.settle(.close)
        XCTAssertEqual(store.commits.count, 1)
        // Changed and changed back (an erasure undone): the same strokes are the same bytes, so nothing more is kept.
        session.changed(try XCTUnwrap(session.canvas(for: id)))
        await session.settle(.close)
        XCTAssertEqual(store.commits.count, 1)
    }

    func testBehaviorReadingResultForOldBytesDropped() async throws {
        let store = store(pages: 1)
        let session = session(store)
        var reads = 0
        session.reader = { _, sha, page, _ in
            reads += 1
            if reads == 1 { try? await Task.sleep(for: .milliseconds(200)) }
            return PageReading(drawingSHA256: sha, passages: [], readAt: self.began)
        }
        let id = store.pages[0].id
        try write(session, page: id, SyntheticInk.drawing("hello", start: began))
        await session.settle(.idle, pages: [id])
        let first = NotebookSession.sha256(store.commits[0].data)
        try write(session, page: id, SyntheticInk.drawing("world", start: began))
        await session.settle(.idle, pages: [id])
        await settle(0.6)
        let second = NotebookSession.sha256(store.commits[1].data)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.readings.map(\.reading.drawingSHA256), [second], "the reading of the old strokes was dropped, and the new ones read")
    }

    func testBehaviorLayoutChangeKeepsCanvasInstances() throws {
        let store = store(pages: 4)
        let session = session(store, layout: .spread(scale: 0.8))
        let left = try XCTUnwrap(session.canvas(for: store.pages[0].id))
        let right = try XCTUnwrap(session.canvas(for: store.pages[1].id))
        session.resolve(.single(scale: 0.8))
        XCTAssertTrue(session.canvas(for: store.pages[0].id) === left)
        session.resolve(.spread(scale: 0.8))
        XCTAssertTrue(session.canvas(for: store.pages[0].id) === left)
        XCTAssertTrue(session.canvas(for: store.pages[1].id) === right)
        XCTAssertEqual(session.visibleIDs, [store.pages[0].id, store.pages[1].id])
    }

    func testBehaviorErasuresCapturedAcrossTwoCommits() async throws {
        let store = store(pages: 1, written: 1)
        let session = session(store)
        let id = store.pages[0].id
        let all = SyntheticInk.drawing("hello", start: began).strokes
        let keys = NotebookReader.strokes(of: PKDrawing(strokes: all)).map(\.key)
        try write(session, page: id, PKDrawing(strokes: Array(all.dropLast(2))))
        store.clock = store.clock.addingTimeInterval(10)
        await session.settle(.close)
        XCTAssertEqual(store.erased[id]?.map(\.key), Array(keys.suffix(2)))
        XCTAssertEqual(store.erased[id]?.first?.madeAt, all[all.count - 2].path.creationDate, "when it was made")
        // Erased at the clock as it was when the stroke went; the stand-in anchors against the clock as it is now (40 s at its start).
        XCTAssertEqual(store.erased[id]?.first?.time ?? 0, 30, accuracy: 0.001, "and where in the recording it went")
        // The second commit only knows about what the first left.
        store.clock = store.clock.addingTimeInterval(30)
        try write(session, page: id, PKDrawing(strokes: Array(all.dropLast(3))))
        await session.settle(.close)
        XCTAssertEqual(Set(store.erased[id]?.map(\.key) ?? []), Set(keys.suffix(3)))
        XCTAssertEqual(store.commits.count, 2)
    }

    func testBehaviorPageNotLoadedNeverCommits() async throws {
        let store = store(pages: 1)
        store.content[store.pages[0].id] = .notLoaded
        let session = session(store)
        let id = store.pages[0].id
        XCTAssertFalse(session.isWritable(id), "closed over strokes that exist")
        XCTAssertNotNil(session.problem)
        try write(session, page: id, SyntheticInk.drawing("hello", start: began))
        await session.settle(.close)
        XCTAssertTrue(store.commits.isEmpty)
    }

    func testBehaviorNewPageMadeWithFirstStrokes() async throws {
        let store = store(pages: 2)
        let session = session(store, layout: .spread(scale: 0.8))
        session.newPage()
        XCTAssertEqual(store.pages.count, 2, "a blank page isn't kept")
        let blank = try XCTUnwrap(session.visible.first)
        try write(session, page: blank.id, SyntheticInk.drawing("hello", start: began))
        XCTAssertEqual(store.pages.count, 3, "kept with its first strokes")
        XCTAssertEqual(session.number(of: blank.id), 3)
    }

    func testBehaviorWritingPointFollowsTouchesOnAPage() throws {
        let store = store(pages: 1)
        let session = session(store)
        let view = try XCTUnwrap(session.canvas(for: store.pages[0].id))
        XCTAssertNil(session.writingPoint)
        view.touching?(CGPoint(x: 120, y: 300))
        XCTAssertEqual(session.writingPoint, CGPoint(x: 120, y: 300), "controls near it step aside")
        view.touching?(nil)
        XCTAssertNil(session.writingPoint, "and come back when the stroke ends")
    }
}
