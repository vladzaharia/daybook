import DaybookTestSupport
import XCTest
@testable import DaybookCore

/// A notebook page's strokes through the sync journal between independent temporary libraries and a shared temporary folder,
/// as `LibrarySyncPhotoTests` does for photos: no iCloud account, synthetic strokes (bytes) only.
final class LibrarySyncPageTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("Remote") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private let fast = AudioFetchOptions(pollInterval: .milliseconds(5), timeout: .seconds(10))
    private let start = NotebookFixtures.start

    override func setUpWithError() throws {
        root = makeTemporaryFolder("DaybookPageSyncTests")
    }

    private func engine(_ name: String, onDemand: Bool = false, holdsEditBursts: Bool = false) throws -> LibrarySyncEngine {
        var replica = onDemand ? SyncReplicaConfiguration.phone(displayName: "Alex's iPhone") : SyncReplicaConfiguration()
        replica.holdsEditBursts = holdsEditBursts
        return try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: replica)
    }

    @discardableResult
    private func apply(_ result: SyncResult, to name: String, using engine: LibrarySyncEngine) async throws -> SyncResult {
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs { _ = try? await store.moveToTrash(id) }
        try await engine.acknowledge(result.checkpointID)
        return result
    }

    private func bytes(_ tag: String) -> Data { Data((tag + String(repeating: "stroke", count: 60)).utf8) }

    /// A conversation on `name` with one written page: its strokes stored, a reading of them with one passage.
    private func meetingWithPage(on name: String = "A", tag: String = "first") async throws -> (Meeting, NotebookPage, Data) {
        let store = try MeetingStore(rootURL: local(name))
        var meeting = Meeting(title: "Whiteboard session")
        let id = UUID()
        let drawing = try await store.storePageDrawing(bytes(tag), page: id, in: meeting, strokeCount: 7, contentVersion: 1,
                                                       device: "Alex's iPhone", after: nil, now: start)
        var page = NotebookPage(id: id, order: 1, now: start)
        page.drawing = drawing
        page.reading = NotebookFixtures.reading(of: drawing, [NotebookFixtures.passage(id, words: "Budget review")])
        meeting.addPage(page)
        try await store.save(meeting)
        return (meeting, page, bytes(tag))
    }

    private func eventAssets() throws -> [[String: Any]] {
        let events = try FileManager.default.contentsOfDirectory(at: remote.appendingPathComponent("Events"), includingPropertiesForKeys: nil)
        return try events.flatMap { url -> [[String: Any]] in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            return object?["assets"] as? [[String: Any]] ?? []
        }
    }

    func testBehaviorPageDrawingTravelsAsBlob() async throws {
        var (meeting, page, written) = try await meetingWithPage()
        // A drawing a merge set aside, and a background, travel the same way.
        let store = try MeetingStore(rootURL: local("A"))
        let aside = try await store.storePageDrawing(bytes("aside"), page: page.id, in: meeting, strokeCount: 2, contentVersion: 1, device: nil,
                                                     after: nil, now: start.addingTimeInterval(-50))
        let picture = bytes("picture")
        let backgroundPath = PageBackground.relativePath(page: page.id, sha256: AudioDigest.sha256(data: picture), fileExtension: "png")
        try picture.write(to: try LocalFiles.relativeURL(backgroundPath, in: try await store.meetingDirectory(for: meeting.id)))
        meeting.pages?[0].setAside = [aside]
        meeting.pages?[0].setBackground(PageBackground(relativePath: backgroundPath, sha256: AudioDigest.sha256(data: picture), byteCount: picture.count,
                                                       kind: .image, fileExtension: "png", width: 1200, height: 1600, editedAt: start), now: start)
        page = try XCTUnwrap(meeting.pages?.first)
        try await store.save(meeting)

        let a = try engine("A"), b = try engine("B")
        let published = try await a.synchronize(meetings: [meeting])
        try await apply(published, to: "A", using: a)
        // The strokes are one object named by their SHA-256, listed in the event's assets under their library path.
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("Blobs/\(page.drawing!.sha256)")), written)
        let assets = try eventAssets()
        for file in page.files {
            XCTAssertTrue(assets.contains { $0["relativePath"] as? String == file.relativePath && $0["sha256"] as? String == file.sha256 }, file.relativePath)
        }

        // Mac B (eager) copies and verifies every file before the conversation applies.
        let pulled = try await b.synchronize(meetings: [])
        XCTAssertFalse(pulled.hasPendingTransfers)
        let arrived = try XCTUnwrap(pulled.meetings.first { $0.id == meeting.id })
        XCTAssertEqual(arrived.pages, meeting.pages, "the page, its reading, its drawings and its background travel")
        for file in page.files {
            let copy = local("B").appendingPathComponent("Meetings/\(meeting.id)/\(file.relativePath)")
            XCTAssertEqual(AudioDigest.sha256(data: try Data(contentsOf: copy)), file.sha256, file.relativePath)
        }
        try await apply(pulled, to: "B", using: b)

        // A deletion on B arrives on A as a deletion; the files stay on both.
        var edited = arrived
        edited.removePage(page.id, at: start.addingTimeInterval(500))
        try await MeetingStore(rootURL: local("B")).save(edited)
        try await apply(try await b.synchronize(meetings: [edited]), to: "B", using: b)
        let back = try await a.synchronize(meetings: [try await MeetingStore(rootURL: local("A")).load(meeting.id)])
        XCTAssertNotNil(try XCTUnwrap(back.meetings.first { $0.id == meeting.id }).page(page.id)?.removedAt)
        try await apply(back, to: "A", using: a)
        for file in page.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: local("A").appendingPathComponent("Meetings/\(meeting.id)/\(file.relativePath)").path))
        }
    }

    func testBehaviorEagerReplicaWaitsForDrawing() async throws {
        let (meeting, page, _) = try await meetingWithPage()
        let a = try engine("A")
        try await apply(try await a.synchronize(meetings: [meeting]), to: "A", using: a)
        let blob = remote.appendingPathComponent("Blobs/\(page.drawing!.sha256)")
        let saved = try Data(contentsOf: blob)
        try FileManager.default.removeItem(at: blob)
        let b = try engine("B")
        let waiting = try await b.synchronize(meetings: [])
        XCTAssertTrue(waiting.meetings.isEmpty, "the conversation waits for the strokes it names")
        XCTAssertGreaterThan(waiting.pendingDownloads, 0)
        try await b.acknowledge(waiting.checkpointID)
        try saved.write(to: blob)
        let arrived = try await b.synchronize(meetings: [])
        XCTAssertEqual(arrived.pendingDownloads, 0)
        XCTAssertEqual(arrived.meetings.first?.page(page.id)?.drawing, page.drawing)
    }

    func testBehaviorOnDemandReplicaAppliesWordsBeforeStrokes() async throws {
        let (meeting, page, written) = try await meetingWithPage()
        let mac = try engine("A")
        try await apply(try await mac.synchronize(meetings: [meeting]), to: "A", using: mac)
        let phone = try engine("Phone", onDemand: true)
        let pulled = try await phone.synchronize(meetings: [])
        XCTAssertEqual(pulled.pendingDownloads, 0, "strokes not on the phone are a normal state")
        let arrived = try XCTUnwrap(pulled.meetings.first)
        let words = try XCTUnwrap(arrived.page(page.id)?.passages.first)
        XCTAssertEqual(arrived.page(page.id)?.words(of: words), "Budget review", "the words are there before the strokes")
        let drawing = try XCTUnwrap(arrived.page(page.id)?.drawing)
        XCTAssertFalse(phone.isPageDrawingLocal(drawing, in: meeting.id))
        try await apply(pulled, to: "Phone", using: phone)
        let url = try await phone.fetchPageDrawing(drawing, in: meeting.id, options: fast)
        XCTAssertEqual(try Data(contentsOf: url), written)
        XCTAssertTrue(phone.isPageDrawingLocal(drawing, in: meeting.id))

        // Words and typed notes edited with the strokes not here publish the page by reference.
        var edited = try await MeetingStore(rootURL: local("Phone")).load(meeting.id)
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(phone.isPageDrawingLocal(drawing, in: meeting.id))
        edited.correctPassage(pageID: page.id, passageID: words.id, text: "Budget review, Q3", now: start.addingTimeInterval(900))
        let sent = try await phone.synchronize(meetings: [edited])
        XCTAssertEqual(sent.publishedEvents, 1)
        try await apply(sent, to: "Phone", using: phone)
        let onMac = try await mac.synchronize(meetings: [try await MeetingStore(rootURL: local("A")).load(meeting.id)])
        XCTAssertEqual(onMac.meetings.first?.page(page.id).flatMap { $0.words(of: words) }, "Budget review, Q3")
    }

    func testBehaviorFetchPageDrawingVerifiesDigest() async throws {
        let (meeting, page, _) = try await meetingWithPage()
        let mac = try engine("A")
        try await apply(try await mac.synchronize(meetings: [meeting]), to: "A", using: mac)
        let phone = try engine("Phone", onDemand: true)
        try await apply(try await phone.synchronize(meetings: []), to: "Phone", using: phone)
        let drawing = try XCTUnwrap(page.drawing)
        // The object in the journal isn't the bytes its name says.
        let blob = remote.appendingPathComponent("Blobs/\(drawing.sha256)")
        let good = try Data(contentsOf: blob)
        try bytes("tampered").write(to: blob)
        do {
            _ = try await phone.fetchPageDrawing(drawing, in: meeting.id, options: fast)
            XCTFail("installed bytes that aren't the digest")
        } catch AudioFetchError.integrityMismatch { }
        XCTAssertFalse(phone.isPageDrawingLocal(drawing, in: meeting.id), "nothing partial is left")
        // A path that isn't a page's, or a short digest, is refused before anything is read.
        var elsewhere = drawing
        elsewhere.relativePath = "Originals/Photos/x.jpg"
        do { _ = try await phone.fetchPageDrawing(elsewhere, in: meeting.id, options: fast); XCTFail("fetched outside the pages folder") }
        catch AudioFetchError.invalidTrack { }
        try good.write(to: blob)
        let url = try await phone.fetchPageDrawing(drawing, in: meeting.id, options: fast)
        XCTAssertEqual(AudioDigest.sha256(data: try Data(contentsOf: url)), drawing.sha256)
    }

    /// An event a Daybook that keeps `pages` as an unknown key wrote lists no page assets: it applies, and the drawings come
    /// from the pages themselves.
    func testBehaviorEventWithoutPageAssetsStillApplies() async throws {
        let (meeting, page, written) = try await meetingWithPage()
        let a = try engine("A")
        let first = try await a.synchronize(meetings: [meeting])
        try await apply(first, to: "A", using: a)
        let head = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("Events").path)
            .first { $0.hasSuffix(".json") }).dropLast(5)
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncEncoding.data(meeting)) as? [String: Any])
        snapshot["notes"] = "Typed on an older Mac"
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "meetingID": meeting.id.uuidString, "deviceID": "Old", "sequence": 1,
                                                                "parents": [String(head)], "snapshot": snapshot, "deleted": false, "assets": []] as [String: Any],
                                               options: [.sortedKeys])
        try bytes.write(to: remote.appendingPathComponent("Events/\(SyncDigest.sha256(data: bytes)).json"))

        let b = try engine("B")
        let pulled = try await b.synchronize(meetings: [])
        XCTAssertEqual(pulled.pendingDownloads, 0)
        XCTAssertEqual(pulled.warnings, [])
        let arrived = try XCTUnwrap(pulled.meetings.first)
        XCTAssertEqual(arrived.notes, "Typed on an older Mac")
        XCTAssertEqual(arrived.pages, meeting.pages)
        XCTAssertEqual(try Data(contentsOf: local("B").appendingPathComponent("Meetings/\(meeting.id)/\(page.drawing!.relativePath)")), written,
                       "hydrated from the page, not the event's list")
    }

    /// A page file under another page's path, or named by a short digest, is refused where the engine validates what it
    /// publishes and applies.
    func testBehaviorSnapshotWithPathNotDerivedFromPageIsRefused() async throws {
        var (meeting, _, _) = try await meetingWithPage()
        let sha = try XCTUnwrap(meeting.pages?.first?.drawing?.sha256)
        meeting.pages?[0].drawing?.relativePath = PageDrawing.relativePath(page: UUID(), sha256: sha)
        let a = try engine("A")
        let result = try await a.synchronize(meetings: [meeting])
        XCTAssertEqual(result.publishedEvents, 0, "a path that isn't the page's is never published")
        XCTAssertGreaterThan(result.pendingUploads, 0)
        XCTAssertFalse(result.warnings.isEmpty)
        // And one that arrives that way, from a device that published it, is refused where the engine checks formats.
        do { try await a.validatePageAssets(meeting); XCTFail("accepted it") } catch LibrarySyncError.invalidBlob { }
    }

    func testBehaviorIPhoneHoldsPublicationThatOnlyChangesDrawings() async throws {
        let (meeting, page, _) = try await meetingWithPage(on: "Phone")
        let phone = try engine("Phone", onDemand: true, holdsEditBursts: true), mac = try engine("B")
        let clock = PageClock()
        await phone.setPublicationClock { clock.now }
        // The first publication of a conversation goes at once.
        let first = try await phone.synchronize(meetings: [meeting])
        XCTAssertEqual(first.publishedEvents, 1)
        try await apply(first, to: "Phone", using: phone)

        // New strokes on the page: small as the conversation is, they're held, as many commits in a burst are one.
        let store = try MeetingStore(rootURL: local("Phone"))
        var edited = try await store.load(meeting.id)
        var writing = edited
        for tag in ["second", "third"] {
            clock.advance(20)
            let drawing = try await store.storePageDrawing(bytes(tag), page: page.id, in: writing, strokeCount: 9, contentVersion: 1, device: nil,
                                                           after: writing.page(page.id)?.drawing?.editedAt, now: clock.now)
            writing.commitPageDrawing(page.id, drawing: drawing, now: clock.now)
            let held = try await phone.synchronize(meetings: [writing])
            XCTAssertEqual(held.publishedEvents, 0, tag)
            XCTAssertEqual(held.nextPublication, clock.start.addingTimeInterval(LibrarySyncEngine.publicationInterval), tag)
            XCTAssertEqual(held.meetings.first?.page(page.id)?.drawing?.sha256, drawing.sha256, "the edit here stays as it is")
            try await apply(held, to: "Phone", using: phone)
        }
        // A note typed meanwhile is held with them: what the person did waits for one publication, as in a large conversation.
        edited = writing
        edited.setNotes("Notes typed meanwhile")
        let typed = try await phone.synchronize(meetings: [edited])
        XCTAssertEqual(typed.publishedEvents, 0)
        try await apply(typed, to: "Phone", using: phone)

        // Once it's due, one publication carries the burst.
        clock.advance(20)
        let fourth = try await store.storePageDrawing(bytes("fourth"), page: page.id, in: edited, strokeCount: 10, contentVersion: 1, device: nil,
                                                      after: edited.page(page.id)?.drawing?.editedAt, now: clock.now)
        edited.commitPageDrawing(page.id, drawing: fourth, now: clock.now)
        let heldAgain = try await phone.synchronize(meetings: [edited])
        XCTAssertEqual(heldAgain.publishedEvents, 0)
        try await apply(heldAgain, to: "Phone", using: phone)
        clock.advance(LibrarySyncEngine.publicationInterval)
        let burst = try await phone.synchronize(meetings: [edited])
        XCTAssertEqual(burst.publishedEvents, 1)
        XCTAssertNil(burst.nextPublication)
        try await apply(burst, to: "Phone", using: phone)
        let onMac = try await mac.synchronize(meetings: [])
        XCTAssertEqual(onMac.meetings.first?.page(page.id)?.drawing?.sha256, fourth.sha256)
        XCTAssertEqual(onMac.meetings.first?.notes, "Notes typed meanwhile")

        // With no strokes changed, a note in a small conversation goes at once, as any edit does.
        clock.advance(20)
        edited.setNotes("A second note")
        let plain = try await phone.synchronize(meetings: [edited])
        XCTAssertEqual(plain.publishedEvents, 1, "a change that isn't to the pages' files isn't held")
        try await apply(plain, to: "Phone", using: phone)

        // Leaving the conversation publishes what's held at once.
        clock.advance(20)
        let fifth = try await store.storePageDrawing(bytes("fifth"), page: page.id, in: edited, strokeCount: 11, contentVersion: 1, device: nil,
                                                     after: edited.page(page.id)?.drawing?.editedAt, now: clock.now)
        edited.commitPageDrawing(page.id, drawing: fifth, now: clock.now)
        let heldLast = try await phone.synchronize(meetings: [edited])
        XCTAssertEqual(heldLast.publishedEvents, 0)
        try await apply(heldLast, to: "Phone", using: phone)
        let released = await phone.publishHeldEdits(of: [edited.id])
        XCTAssertTrue(released)
        let left = try await phone.synchronize(meetings: [edited])
        XCTAssertEqual(left.publishedEvents, 1)
    }

    /// A Mac doesn't hold bursts: every commit that reaches it goes at once.
    func testBehaviorAMacPublishesEveryDrawingChange() async throws {
        let (meeting, page, _) = try await meetingWithPage()
        let a = try engine("A")
        let first = try await a.synchronize(meetings: [meeting])
        try await apply(first, to: "A", using: a)
        let store = try MeetingStore(rootURL: local("A"))
        var edited = meeting
        let next = try await store.storePageDrawing(bytes("again"), page: page.id, in: edited, strokeCount: 8, contentVersion: 1, device: nil,
                                                    after: page.drawing?.editedAt, now: start.addingTimeInterval(60))
        edited.commitPageDrawing(page.id, drawing: next, now: start.addingTimeInterval(60))
        let sent = try await a.synchronize(meetings: [edited])
        XCTAssertEqual(sent.publishedEvents, 1)
    }

    func testBehaviorPageFilesInHistoryAreWhatTheAppliedCopyNames() async throws {
        let (meeting, page, _) = try await meetingWithPage()
        let a = try engine("A")
        let before = await a.pageFilesInHistory(of: meeting.id)
        XCTAssertTrue(before.isEmpty)
        try await apply(try await a.synchronize(meetings: [meeting]), to: "A", using: a)
        let after = await a.pageFilesInHistory(of: meeting.id)
        XCTAssertEqual(after, [page.drawing!.relativePath])
    }

    func testBehaviorPageAssetsListEveryFileOnceIncludingDeletedPages() async throws {
        var (meeting, page, _) = try await meetingWithPage()
        page.setAside = [NotebookFixtures.drawing(page.id, "old")]
        meeting.pages = [page]
        meeting.removePage(page.id, at: start)
        let a = try engine("A")
        let assets = a.pageAssets(of: meeting)
        XCTAssertEqual(Set(assets.map(\.relativePath)), [page.drawing!.relativePath, page.setAside![0].relativePath], "a deleted page keeps its files live")
    }

    // MARK: A Daybook from before pages

    /// An older Mac (the frozen version 1 engine, which lists no page assets) edits a conversation with pages, and then merges
    /// two newer devices' changes to it as a Daybook that predates pages does: of the two `pages` arrays, the unknown key it
    /// is to it, it keeps the one with the greater encoding, so a page only the other side had isn't in its event. A newer
    /// Mac reading the journal still has every page, with its strokes: `Meeting.restoringPages` puts the lost one back.
    func testBehaviorLegacyEngineKeepsPagesAsUnknownField() async throws {
        let (base, first, _) = try await meetingWithPage(on: "A", tag: "mac")
        let a = try engine("A"), b = try engine("B"), c = try engine("C")
        try await apply(try await a.synchronize(meetings: [base]), to: "A", using: a)

        // The older Mac pulls it and types a note: its event lists no page assets, and carries the page.
        let legacy = try LegacyLibrarySyncEngine(localRoot: local("Old"), remoteRoot: remote, deviceID: "Old")
        let oldStore = try MeetingStore(rootURL: local("Old"))
        let pulled = try await legacy.synchronize(meetings: [])
        for meeting in pulled.meetings { try await oldStore.save(meeting) }
        try await legacy.acknowledge(pulled.checkpointID)
        var typed = try XCTUnwrap(pulled.meetings.first)
        XCTAssertEqual(typed.pages?.map(\.id), [first.id])
        typed.setNotes("Typed on the older Mac")
        let edit = try await legacy.synchronize(meetings: [typed])
        XCTAssertEqual(edit.publishedEvents, 1)
        try await legacy.acknowledge(edit.checkpointID)

        // Two newer devices each add a page to it, made apart: the second one's event is kept out of sight of the first.
        let onA = try await apply(try await a.synchronize(meetings: []), to: "A", using: a).meetings[0]
        let onB = try await apply(try await b.synchronize(meetings: []), to: "B", using: b).meetings[0]
        XCTAssertEqual(onA.notes, "Typed on the older Mac")
        func adding(_ tag: String, order: Double, to meeting: Meeting, on name: String) async throws -> (Meeting, NotebookPage) {
            let store = try MeetingStore(rootURL: local(name))
            var page = NotebookPage(id: UUID(), order: order, now: start.addingTimeInterval(order))
            page.drawing = try await store.storePageDrawing(bytes(tag), page: page.id, in: meeting, strokeCount: 3, contentVersion: 1, device: nil,
                                                            after: nil, now: start.addingTimeInterval(order * 10))
            var edited = meeting
            edited.addPage(page)
            try await store.save(edited)
            return (edited, page)
        }
        let (withThird, third) = try await adding("third", order: 3, to: onB, on: "B")
        let beforeThird = try events()
        try await apply(try await b.synchronize(meetings: [withThird]), to: "B", using: b)
        let thirdName = try XCTUnwrap(try events().subtracting(beforeThird).first)
        let aside = root.appendingPathComponent("aside.json"), withheld = remote.appendingPathComponent("Events/\(thirdName).json")
        try FileManager.default.moveItem(at: withheld, to: aside)
        let (withSecond, second) = try await adding("second", order: 2, to: onA, on: "A")
        try await apply(try await a.synchronize(meetings: [withSecond]), to: "A", using: a)
        let secondName = try XCTUnwrap(try events().subtracting(beforeThird).first)
        try FileManager.default.moveItem(at: aside, to: withheld)

        // The older Mac merges the two: it keeps one side's `pages` whole, by its encoding, and nothing of the other's.
        let (pagesA, pagesB) = (try pages(inEvent: secondName), try pages(inEvent: thirdName))
        func text(_ pages: [[String: Any]]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: pages, options: [.sortedKeys]), as: UTF8.self)
        }
        let keepsA = try text(pagesA) > text(pagesB)
        var merged = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncEncoding.data(withSecond)) as? [String: Any])
        merged["pages"] = keepsA ? pagesA : pagesB
        merged["notes"] = "Typed on the older Mac, then merged"
        let record: [String: Any] = ["schemaVersion": 1, "meetingID": base.id.uuidString, "deviceID": "Old", "sequence": 9,
                                     "parents": [secondName, thirdName].sorted(), "snapshot": merged, "deleted": false, "assets": []]
        let eventBytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try eventBytes.write(to: remote.appendingPathComponent("Events/\(SyncDigest.sha256(data: eventBytes)).json"))
        let kept = (merged["pages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(kept), keepsA ? [first.id.uuidString, second.id.uuidString] : [first.id.uuidString, third.id.uuidString],
                       "the older Mac's merge lost the other side's page")

        // A newer Mac reading the journal still has every page, with its strokes.
        let result = try await c.synchronize(meetings: [])
        XCTAssertEqual(result.pendingDownloads, 0)
        XCTAssertEqual(result.warnings, [])
        let arrived = try XCTUnwrap(result.meetings.first)
        XCTAssertEqual(arrived.notes, "Typed on the older Mac, then merged")
        XCTAssertEqual(Set(arrived.pages?.map(\.id) ?? []), [first.id, second.id, third.id], "no page is lost to a merge that doesn't know pages")
        for page in arrived.pages ?? [] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: local("C").appendingPathComponent("Meetings/\(base.id)/\(page.drawing!.relativePath)").path))
        }
        XCTAssertEqual(arrived.page(third.id)?.drawing, third.drawing)
        XCTAssertEqual(arrived.page(second.id)?.drawing, second.drawing)
    }

    private func events() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("Events").path).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    /// The `pages` an event's snapshot holds, as the JSON it was written as.
    private func pages(inEvent name: String) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: remote.appendingPathComponent("Events/\(name).json"))) as? [String: Any])
        return try XCTUnwrap((object["snapshot"] as? [String: Any])?["pages"] as? [[String: Any]])
    }
}

/// A clock a test moves on, read from the engine's actor.
private final class PageClock: @unchecked Sendable {
    private let lock = NSLock()
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var offset: TimeInterval = 0
    var now: Date { lock.withLock { start.addingTimeInterval(offset) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}
