import DaybookTestSupport
import XCTest
@testable import DaybookCore

/// A page's strokes as files in the conversation's folder (`MeetingStore+Pages.swift`): content-addressed, validated, and
/// pruned only when nothing names them. Temporary libraries and synthetic bytes.
final class MeetingStorePageTests: XCTestCase {
    private var root: URL!
    private let start = NotebookFixtures.start

    override func setUpWithError() throws {
        root = makeTemporaryFolder("DaybookPageStore")
    }

    private func store() throws -> MeetingStore { try MeetingStore(rootURL: root.appendingPathComponent("Library")) }

    private func bytes(_ tag: String) -> Data { Data((tag + String(repeating: "ink", count: 40)).utf8) }

    private func folder(of meeting: Meeting) -> URL {
        root.appendingPathComponent("Library/Meetings/\(meeting.id.uuidString)/\(PageDrawing.folder)")
    }

    func testBehaviorStorePageDrawingIsContentAddressed() async throws {
        let store = try store()
        let meeting = NotebookFixtures.meeting()
        let page = UUID()
        let first = try await store.storePageDrawing(bytes("one"), page: page, in: meeting, strokeCount: 4, contentVersion: 1,
                                                     device: "Alex's iPhone", after: nil, now: start)
        XCTAssertEqual(first.sha256, AudioDigest.sha256(data: bytes("one")))
        XCTAssertEqual(first.relativePath, PageDrawing.relativePath(page: page, sha256: first.sha256))
        XCTAssertEqual(first.relativePath, "Originals/Pages/\(page.uuidString)-\(first.sha256.prefix(16)).pkdrawing")
        XCTAssertEqual(first.byteCount, bytes("one").count)
        XCTAssertEqual(first.strokeCount, 4)
        XCTAssertEqual(first.device, "Alex's iPhone")
        XCTAssertTrue(first.isStored(for: page))
        let url = try await store.url(of: first, in: meeting.id)
        XCTAssertEqual(try Data(contentsOf: url), bytes("one"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "owner only")

        // Other bytes are another file; the first stays.
        let second = try await store.storePageDrawing(bytes("two"), page: page, in: meeting, strokeCount: 5, contentVersion: 1,
                                                      device: nil, after: first.editedAt, now: start.addingTimeInterval(-100))
        XCTAssertNotEqual(second.relativePath, first.relativePath)
        XCTAssertEqual(second.editedAt, first.editedAt.addingTimeInterval(0.001), "stamped after the drawing it replaces, though the clock is behind")
        XCTAssertEqual(try Data(contentsOf: url), bytes("one"))
        let secondURL = try await store.url(of: second, in: meeting.id)
        XCTAssertEqual(try Data(contentsOf: secondURL), bytes("two"))
    }

    func testBehaviorSameBytesReuseFile() async throws {
        let store = try store()
        let meeting = NotebookFixtures.meeting()
        let page = UUID()
        let first = try await store.storePageDrawing(bytes("same"), page: page, in: meeting, strokeCount: 2, contentVersion: nil,
                                                     device: nil, after: nil, now: start)
        let url = try await store.url(of: first, in: meeting.id)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        let again = try await store.storePageDrawing(bytes("same"), page: page, in: meeting, strokeCount: 2, contentVersion: nil,
                                                     device: nil, after: nil, now: start)
        XCTAssertEqual(again, first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, inode, "not written again")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder(of: meeting).path).count, 1)

        // What's there isn't those bytes (a torn write): it's replaced, never trusted by name.
        try Data("torn".utf8).write(to: url)
        _ = try await store.storePageDrawing(bytes("same"), page: page, in: meeting, strokeCount: 2, contentVersion: nil, device: nil, after: nil, now: start)
        XCTAssertEqual(try Data(contentsOf: url), bytes("same"))

        // From a file (filing from staging), the file is left as it is.
        let staged = root.appendingPathComponent("staged.pkdrawing")
        try bytes("staged").write(to: staged)
        let filed = try await store.storePageDrawing(from: staged, page: page, in: meeting, strokeCount: 1, contentVersion: 1, device: nil,
                                                     after: nil, now: start)
        XCTAssertEqual(filed.sha256, AudioDigest.sha256(data: bytes("staged")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testBehaviorPruneKeepsReferencedSetAsideAndRecent() async throws {
        let store = try store()
        var meeting = NotebookFixtures.meeting()
        let id = UUID()
        func put(_ tag: String, at date: Date) async throws -> PageDrawing {
            let drawing = try await store.storePageDrawing(bytes(tag), page: id, in: meeting, strokeCount: 1, contentVersion: 1, device: nil,
                                                           after: nil, now: start)
            let url = try await store.url(of: drawing, in: meeting.id)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return drawing
        }
        let now = start.addingTimeInterval(10 * 86_400), old = start
        let current = try await put("current", at: old), aside = try await put("aside", at: old)
        let stale = try await put("stale", at: old), recent = try await put("recent", at: now.addingTimeInterval(-3_600))
        let ancestor = try await put("ancestor", at: old)
        let background = bytes("picture")
        let backgroundPath = PageBackground.relativePath(page: id, sha256: AudioDigest.sha256(data: background), fileExtension: "png")
        let backgroundURL = try LocalFiles.relativeURL(backgroundPath, in: try await store.meetingDirectory(for: meeting.id))
        try background.write(to: backgroundURL)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: backgroundURL.path)
        var page = NotebookPage(id: id, order: 1, now: start)
        page.drawing = current
        page.setAside = [aside]
        page.setBackground(PageBackground(relativePath: backgroundPath, sha256: AudioDigest.sha256(data: background), byteCount: background.count,
                                          kind: .image, fileExtension: "png", width: 600, height: 800, editedAt: start), now: start)
        meeting.pages = [page]

        let deleted = await store.prunePageDrawings(of: meeting, keeping: [ancestor.relativePath], now: now)
        XCTAssertEqual(deleted, 1)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder(of: meeting).path))
        func name(_ drawing: PageDrawing) -> String { (drawing.relativePath as NSString).lastPathComponent }
        XCTAssertTrue(names.contains(name(current)), "the page's drawing")
        XCTAssertTrue(names.contains(name(aside)), "a drawing a merge set aside, so Version History can put it back")
        XCTAssertTrue(names.contains(name(recent)), "recent: a sync pass may still be publishing the previous version")
        XCTAssertTrue(names.contains(name(ancestor)), "one an ancestor in the sync history names")
        XCTAssertTrue(names.contains((backgroundPath as NSString).lastPathComponent), "the page's background")
        XCTAssertFalse(names.contains(name(stale)), "nothing names it, and it's old")

        // A deleted page keeps its files: it can be put back.
        meeting.removePage(id, at: now)
        let again = await store.prunePageDrawings(of: meeting, keeping: [], now: now.addingTimeInterval(86_401 * 2))
        XCTAssertEqual(again, 2, "the ancestor's and the one that was recent, which nothing names and is old now")
        let kept = try await store.url(of: current, in: meeting.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: folder(of: meeting).path))
        XCTAssertEqual(remaining.count, 3, "the drawing, the one set aside, and the background")
    }

    func testBehaviorValidateRejectsPagePathOutsideFolder() async throws {
        let store = try store()
        let id = UUID()
        func meeting(_ path: String) -> Meeting {
            var page = NotebookFixtures.page(id)
            page.drawing?.relativePath = path
            return NotebookFixtures.meeting(pages: [page])
        }
        for path in ["Originals/Photos/x.pkdrawing", "Originals/Pages/../x.pkdrawing", "../Pages/x.pkdrawing", "/Originals/Pages/x.pkdrawing", "Originals/Pagesx/y"] {
            do { try await store.save(meeting(path)); XCTFail("accepted \(path)") }
            catch LibraryError.unsafePath { }
        }
        var set = NotebookFixtures.page(id)
        set.setAside = [NotebookFixtures.drawing(id, "aside")]
        set.setAside?[0].relativePath = "Originals/Elsewhere/aside.pkdrawing"
        do { try await store.save(NotebookFixtures.meeting(pages: [set])); XCTFail("accepted a set-aside path outside the folder") }
        catch LibraryError.unsafePath { }
        var sized = NotebookFixtures.page(id)
        sized.height = 0
        do { try await store.save(NotebookFixtures.meeting(pages: [sized])); XCTFail("accepted a page with no height") }
        catch LibraryError.corruptMeeting { }
        try await store.save(meeting(PageDrawing.relativePath(page: id, sha256: NotebookFixtures.drawing(id, "ink").sha256)))
    }

    func testBehaviorPathsMustBeDerivedFromThePageAndTheWholeDigest() {
        let id = UUID(), drawing = NotebookFixtures.drawing(id, "ink")
        XCTAssertTrue(drawing.isStored(for: id))
        XCTAssertFalse(drawing.isStored(for: UUID()), "another page's path")
        var short = drawing
        short.sha256 = String(drawing.sha256.prefix(16))
        short.relativePath = PageDrawing.relativePath(page: id, sha256: short.sha256)
        XCTAssertFalse(short.isStored(for: id), "the path is derived from the whole digest")
        var upper = drawing
        upper.sha256 = drawing.sha256.uppercased()
        upper.relativePath = PageDrawing.relativePath(page: id, sha256: upper.sha256)
        XCTAssertFalse(upper.isStored(for: id))
        var elsewhere = drawing
        elsewhere.relativePath = "Originals/Pages/\(id.uuidString)-\(drawing.sha256.prefix(16)).png"
        XCTAssertFalse(elsewhere.isStored(for: id))

        var page = NotebookFixtures.page(id)
        XCTAssertTrue(page.hasDerivedPaths)
        page.setAside = [elsewhere]
        XCTAssertFalse(page.hasDerivedPaths, "a drawing set aside is checked too")
    }

    func testBehaviorCopyPageFileChecksTheDigestAndKeepsThePath() async throws {
        let store = try store()
        let from = NotebookFixtures.meeting(), into = NotebookFixtures.meeting()
        let page = UUID()
        let drawing = try await store.storePageDrawing(bytes("folded"), page: page, in: from, strokeCount: 1, contentVersion: 1, device: nil, after: nil)
        let source = try await store.url(of: drawing, in: from.id)
        try await store.copyPageFile(from: source, relativePath: drawing.relativePath, sha256: drawing.sha256, into: into.id)
        let copied = try await store.url(of: drawing, in: into.id)
        XCTAssertEqual(try Data(contentsOf: copied), bytes("folded"))
        try await store.copyPageFile(from: source, relativePath: drawing.relativePath, sha256: drawing.sha256, into: into.id)
        let other = NotebookFixtures.meeting()
        do {
            try await store.copyPageFile(from: source, relativePath: drawing.relativePath, sha256: AudioDigest.sha256(data: Data("other".utf8)), into: other.id)
            XCTFail("copied bytes that aren't the digest")
        } catch LibraryError.invalidAudio { }
        let notCopied = try await store.meetingDirectory(for: other.id).appendingPathComponent(drawing.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notCopied.path))
        do {
            try await store.copyPageFile(from: source, relativePath: "Originals/\(page.uuidString).wav", sha256: drawing.sha256, into: other.id)
            XCTFail("copied outside the pages folder")
        } catch LibraryError.unsafePath { }
    }
}
