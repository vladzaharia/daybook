import DaybookTestSupport
import XCTest
@testable import DaybookCore

/// The records kept beside a page's strokes for later (erased strokes, a page background, page turns) and the recording
/// clock filed with a track: bounded, merged the same whichever copy is local, and never a conflict for what is only added.
final class NotebookDetailsTests: XCTestCase {
    private let start = NotebookFixtures.start
    private let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    private func meeting(_ pages: [NotebookPage]?, tracks: [RecordingTrack] = [], turns: [PageTurn]? = nil, updated: TimeInterval = 0) -> Meeting {
        var meeting = NotebookFixtures.meeting(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!, pages: pages)
        meeting.tracks = tracks
        meeting.pageTurns = turns
        meeting.updatedAt = start.addingTimeInterval(updated)
        return meeting
    }

    private func laws(_ base: Meeting?, _ a: Meeting, _ b: Meeting, file: StaticString = #filePath, line: UInt = #line) -> Meeting {
        let forward = MeetingMerge.merge(base: base, local: a, remote: b).meeting
        XCTAssertEqual(forward, MeetingMerge.merge(base: base, local: b, remote: a).meeting, "commutative", file: file, line: line)
        let bytes = try? SyncEncoding.data(forward)
        for input in [a, b] {
            XCTAssertEqual(try? SyncEncoding.data(MeetingMerge.merge(base: base, local: forward, remote: input).meeting), bytes, "idempotent", file: file, line: line)
        }
        return forward
    }

    private func erased(_ key: String, made: TimeInterval = 0, erased: TimeInterval, track: UUID? = nil, time: TimeInterval? = nil) -> ErasedStroke {
        ErasedStroke(key: key, madeAt: start.addingTimeInterval(made), erasedAt: start.addingTimeInterval(erased), trackID: track, time: time)
    }

    private func picture(_ tag: String, width: Double = 595, height: Double = 842, at offset: TimeInterval = 0, ext: String = "pdf") -> PageBackground {
        let digest = AudioDigest.sha256(data: Data(tag.utf8))
        return PageBackground(relativePath: PageBackground.relativePath(page: id, sha256: digest, fileExtension: ext), sha256: digest, byteCount: 2_000,
                              kind: ext == "pdf" ? .pdf : .image, fileExtension: ext, pageIndex: ext == "pdf" ? 0 : nil, width: width, height: height,
                              editedAt: start.addingTimeInterval(offset))
    }

    // MARK: Erased strokes

    func testBehaviorErasedStrokesUnionByKeyDeterministically() {
        let track = UUID()
        var a = NotebookFixtures.page(id), b = a
        a.erased = [erased("1-3-10-10", erased: 5), erased("2-3-20-20", erased: 6)]
        // The other copy knows where in the recording the first was erased, and erased another.
        b.erased = [erased("1-3-10-10", erased: 5, track: track, time: 12), erased("3-3-30-30", erased: 7)]
        let merged = laws(nil, meeting([a]), meeting([b])).pages?.first?.erased
        XCTAssertEqual(merged?.map(\.key), ["1-3-10-10", "2-3-20-20", "3-3-30-30"], "oldest erasure first, one per stroke")
        XCTAssertEqual(merged?.first?.time, 12, "the one that knows the recording time")
        XCTAssertEqual(merged?.first?.trackID, track)

        // Of two that agree on what they know, the earlier erasure stands; a tie, the greater encoding.
        var early = a, late = a
        early.erased = [erased("9-1-1-1", erased: 10)]
        late.erased = [erased("9-1-1-1", erased: 20)]
        XCTAssertEqual(laws(nil, meeting([early]), meeting([late])).pages?.first?.erased?.first?.erasedAt, start.addingTimeInterval(10))
        // Neither has any: still none.
        a.erased = nil; b.erased = nil
        XCTAssertNil(laws(nil, meeting([a]), meeting([b])).pages?.first?.erased)
    }

    func testBehaviorErasedStrokesAreBoundedDroppingOldest() throws {
        let capacity = ErasedStroke.capacity
        var a = NotebookFixtures.page(id), b = a
        a.erased = (0..<capacity).map { erased("a-\($0)", erased: Double($0) * 2) }
        b.erased = (0..<capacity).map { erased("b-\($0)", erased: Double($0) * 2 + 1) }
        let merged = try XCTUnwrap(laws(nil, meeting([a]), meeting([b])).pages?.first?.erased)
        XCTAssertEqual(merged.count, capacity)
        XCTAssertEqual(merged.last?.key, "b-\(capacity - 1)", "the newest stay")
        XCTAssertEqual(merged.first?.erasedAt, start.addingTimeInterval(Double(capacity)), "the oldest half went")
        XCTAssertEqual(merged, merged.sorted { $0.erasedAt < $1.erasedAt })
        // Merged again with either copy: the same list, not a refilled one.
        XCTAssertEqual(MeetingMerge.merge(base: nil, local: meeting([NotebookFixtures.pageWithErased(id, merged)]), remote: meeting([a])).meeting.pages?.first?.erased, merged)
    }

    // MARK: Background

    func testBehaviorPageWithBackgroundTakesItsAspectWithinTheA5Width() {
        var page = NotebookFixtures.page(id)
        XCTAssertEqual(page.width, 420); XCTAssertEqual(page.height, 595)
        page.setBackground(picture("scan", width: 2_000, height: 1_000, ext: "png"), now: start)
        XCTAssertEqual(page.width, 420, "the A5 width")
        XCTAssertEqual(page.height, 210, "the background's aspect")
        XCTAssertTrue(page.hasBackgroundSize)
        XCTAssertTrue(page.background?.isStored(for: id) == true)
        // A receipt a metre long is drawn scaled to fit, not as a page that never ends; one a sliver wide likewise.
        page.setBackground(picture("receipt", width: 80, height: 8_000), now: start)
        XCTAssertEqual(page.height, 420 * 4)
        page.setBackground(picture("strip", width: 8_000, height: 80), now: start)
        XCTAssertEqual(page.height, 105)
        // Taking it away gives the page back its A5 size, and the strokes are untouched.
        let drawing = page.drawing
        page.setBackground(nil, now: start)
        XCTAssertEqual(page.height, 595)
        XCTAssertNil(page.background)
        XCTAssertEqual(page.drawing, drawing)
        // A background whose size is no use leaves the page A5.
        XCTAssertEqual(NotebookPage.size(for: picture("flat", width: 0, height: 10)).height, 595)
    }

    func testBehaviorBackgroundIsStampedAfterTheOneItReplaces() {
        var page = NotebookFixtures.page(id)
        page.setBackground(picture("one", at: 100), now: start.addingTimeInterval(100))
        let first = page.background?.editedAt
        page.setBackground(picture("two", at: 0), now: start.addingTimeInterval(50))
        XCTAssertEqual(page.background?.editedAt, first?.addingTimeInterval(0.001), "a clock that is behind can't make it older")
    }

    func testBehaviorBackgroundMergesThreeWayAndKeepsTheSizeRule() throws {
        let plain = NotebookFixtures.page(id)
        var withScan = plain
        withScan.setBackground(picture("scan", width: 600, height: 800, ext: "png"), now: start.addingTimeInterval(10))
        var withPdf = plain
        withPdf.setBackground(picture("pdf", width: 595, height: 842), now: start.addingTimeInterval(20))
        // One side set it, the other didn't: it's kept, and the page has its size on every device.
        let kept = laws(meeting([plain]), meeting([withScan], updated: 10), meeting([plain], updated: 20)).pages?.first
        XCTAssertEqual(kept?.background, withScan.background)
        XCTAssertEqual(kept?.height, 560)
        XCTAssertEqual(kept?.hasBackgroundSize, true)
        // Both set one, apart: the greater encoding stands the same either way round, and History says so.
        let both = MeetingMerge.merge(base: meeting([plain]), local: meeting([withScan], updated: 10), remote: meeting([withPdf], updated: 20))
        let chosen = try XCTUnwrap(both.meeting.pages?.first)
        XCTAssertTrue([withScan.background, withPdf.background].contains(chosen.background))
        XCTAssertEqual(chosen.hasBackgroundSize, true)
        XCTAssertTrue(both.meeting.revisions.contains { $0.field == "sync:page-background:\(id)" })
        _ = laws(meeting([plain]), meeting([withScan], updated: 10), meeting([withPdf], updated: 20))
        // One took it away, the other left it: gone.
        let removed = laws(meeting([withScan]), meeting([plain], updated: 30), meeting([withScan], updated: 5)).pages?.first
        XCTAssertNil(removed?.background)
        XCTAssertEqual(removed?.height, 595)
    }

    func testBehaviorBackgroundFilesAreNamedByThePage() {
        var page = NotebookFixtures.page(id)
        let background = picture("scan", ext: "png")
        page.setBackground(background, now: start)
        XCTAssertTrue(page.files.contains(PageFile(relativePath: background.relativePath, sha256: background.sha256)))
        XCTAssertTrue(page.hasDerivedPaths)
        XCTAssertEqual(background.relativePath, "Originals/Pages/\(id.uuidString)-background-\(background.sha256.prefix(16)).png")
        var other = background
        other.relativePath = PageBackground.relativePath(page: UUID(), sha256: background.sha256, fileExtension: "png")
        XCTAssertFalse(other.isStored(for: id), "another page's path")
        var odd = background
        odd.fileExtension = "../x"
        odd.relativePath = PageBackground.relativePath(page: id, sha256: background.sha256, fileExtension: odd.fileExtension)
        XCTAssertFalse(odd.isStored(for: id), "an extension a path can't carry")
        page.background = odd
        XCTAssertFalse(page.hasDerivedPaths)
    }

    func testBehaviorStoreRefusesAPageWhoseSizeIsNotItsBackgrounds() async throws {
        let store = try MeetingStore(rootURL: makeTemporaryFolder("DaybookDetails"))
        var page = NotebookFixtures.page(id)
        page.setBackground(picture("scan", width: 600, height: 800, ext: "png"), now: start)
        try await store.save(NotebookFixtures.meeting(pages: [page]))
        page.height = 595
        do { try await store.save(NotebookFixtures.meeting(pages: [page])); XCTFail("accepted a page that doesn't have its background's aspect") }
        catch LibraryError.corruptMeeting { }
        page.setBackground(picture("scan", width: 600, height: 800, ext: "png"), now: start)
        page.background?.relativePath = "Originals/Photos/scan.png"
        do { try await store.save(NotebookFixtures.meeting(pages: [page])); XCTFail("accepted a background outside the pages folder") }
        catch LibraryError.unsafePath { }
    }

    // MARK: Page turns

    func testBehaviorPageTurnsMergeAsALogBoundedDroppingOldest() throws {
        let track = UUID()
        let one = PageTurn(at: start.addingTimeInterval(1), pages: [id]), two = PageTurn(at: start.addingTimeInterval(2), pages: [id, UUID()])
        let timed = PageTurn(at: start.addingTimeInterval(1), pages: [id], trackID: track, time: 3)
        XCTAssertEqual(one.id, timed.id, "the same turn is one entry")
        let merged = laws(nil, meeting(nil, turns: [one, two]), meeting(nil, turns: [timed])).pageTurns
        XCTAssertEqual(merged?.map(\.id), [one.id, two.id])
        XCTAssertEqual(merged?.first?.time, 3, "the copy that knows the recording time")
        XCTAssertEqual(merged?.first?.trackID, track)
        XCTAssertNil(laws(nil, meeting(nil), meeting(nil)).pageTurns)

        let capacity = PageTurn.capacity
        let a = (0..<capacity).map { PageTurn(at: start.addingTimeInterval(Double($0) * 2), pages: [id]) }
        let b = (0..<capacity).map { PageTurn(at: start.addingTimeInterval(Double($0) * 2 + 1), pages: []) }
        let all = try XCTUnwrap(laws(nil, meeting(nil, turns: a), meeting(nil, turns: b)).pageTurns)
        XCTAssertEqual(all.count, capacity)
        XCTAssertEqual(all.last?.at, start.addingTimeInterval(Double(capacity) * 2 - 1), "the newest stay")
        XCTAssertEqual(all, all.sorted { $0.at < $1.at })
        XCTAssertTrue(PageTurn(at: start, pages: []).pages.isEmpty, "a turn to no pages is the notebook closing")
        XCTAssertNil(PageTurn(at: start, pages: [], time: -3).time)
    }

    // MARK: Size

    /// What the notebook's logs may add to every snapshot of a conversation: a snapshot is published whole at every edit, and
    /// the iPhone holds one this large (`LibrarySyncEngine.heldPublicationBytes`, 256 KB) on its own, so they stay well under.
    private static let notebookLogBudget = 128 * 1024

    func testBehaviorEveryNotebookLogAtItsCapStaysUnderTheSnapshotBudget() throws {
        let plain = NotebookFixtures.page(id)
        var full = plain
        let trackID = UUID()
        full.erased = (0..<ErasedStroke.capacity * 2).map { erased("\(1_800_000_000_000 + $0 * 4_321)-\(30 + $0 % 40)-\(100 + $0)-\(200 + $0)", made: Double($0), erased: Double($0) + 500, track: trackID, time: Double($0) * 1.37) }
        full.erased = ErasedStroke.merged(full.erased, nil)
        XCTAssertEqual(full.erased?.count, ErasedStroke.capacity)
        let turns = (0..<PageTurn.capacity * 2).map { PageTurn(at: start.addingTimeInterval(Double($0) * 7.7), pages: [id, UUID()], trackID: trackID, time: Double($0) * 7.7) }
        let flapping = (0..<2_000).map { RecordingClockSample(at: start.addingTimeInterval(Double($0) * 3.1), elapsed: Double($0) * 3.1, running: $0 % 2 == 0) }
        var recording = track(nil)
        var bare = meeting([plain], tracks: [recording])
        recording.clockSamples = RecordingClockMap.filed(flapping)
        XCTAssertEqual(recording.clockSamples?.count, RecordingClockMap.filedCapacity)
        var loaded = meeting([full], tracks: [recording], turns: PageTurn.merged(turns, nil))
        XCTAssertEqual(loaded.pageTurns?.count, PageTurn.capacity)
        bare.pageTurns = nil
        loaded.title = bare.title
        let share = try SyncEncoding.data(loaded).count - SyncEncoding.data(bare).count
        XCTAssertLessThan(share, Self.notebookLogBudget, "the notebook's logs add \(share) bytes")
        XCTAssertGreaterThan(share, 0)
    }

    // MARK: Recording clock on the track

    private func track(_ samples: [RecordingClockSample]?, id: UUID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!, offset: TimeInterval = 0) -> RecordingTrack {
        var track = RecordingTrack(id: id, source: .microphone, relativePath: "Originals/a.wav", fileName: "a.wav", createdAt: start, offset: offset)
        track.clockSamples = samples
        return track
    }

    private func samples(_ count: Int, paused: Bool = false) -> [RecordingClockSample] {
        (0..<count).map { RecordingClockSample(at: start.addingTimeInterval(Double($0) * 5), elapsed: Double($0) * 5, running: !(paused && $0 == count - 1)) }
    }

    func testBehaviorClockSamplesMergeACopyWithSamplesBeatsOneWithout() throws {
        let written = samples(4)
        let without = meeting(nil, tracks: [track(nil)]), with = meeting(nil, tracks: [track(written)], updated: 10)
        XCTAssertEqual(laws(nil, without, with).tracks.first?.clockSamples, written)
        XCTAssertEqual(laws(meeting(nil, tracks: [track(nil)]), without, with).tracks.first?.clockSamples, written)
        // Another change to the track made apart (its place on the timeline) isn't a conflict with them, and both stand.
        let moved = meeting(nil, tracks: [track(nil, offset: 30)], updated: 20)
        let result = MeetingMerge.merge(base: without, local: moved, remote: with)
        XCTAssertEqual(result.meeting.tracks.first?.clockSamples, written)
        XCTAssertEqual(result.meeting.tracks.first?.offset, 30)
        XCTAssertFalse(result.meeting.revisions.contains { $0.field.hasPrefix("sync:track") })
        // A filing tried again can leave two copies with samples: the longer, then the greater encoding.
        let more = samples(6)
        XCTAssertEqual(laws(nil, meeting(nil, tracks: [track(written)]), meeting(nil, tracks: [track(more)], updated: 10)).tracks.first?.clockSamples, more)
        let other = samples(4, paused: true)
        let tie = laws(nil, meeting(nil, tracks: [track(written)]), meeting(nil, tracks: [track(other)], updated: 10)).tracks.first?.clockSamples
        XCTAssertTrue(tie == written || tie == other)
        XCTAssertNil(RecordingClockSample.merged([], nil))
        // A track only one side has comes whole.
        XCTAssertEqual(laws(nil, meeting(nil, tracks: []), with).tracks.first?.clockSamples, written)
    }

    func testBehaviorClockSamplesMapThePhoneRecordingAcrossAPause() throws {
        // What filing writes: the samples place a passage written after a pause on the recording's clock, not the wall clock.
        let stored = [RecordingClockSample(at: start, elapsed: 0, running: true), RecordingClockSample(at: start.addingTimeInterval(60), elapsed: 60, running: false),
                      RecordingClockSample(at: start.addingTimeInterval(180), elapsed: 60, running: true)]
        let recording = track(stored)
        let encoded = try JSONEncoder().encode(recording)
        let back = try JSONDecoder().decode(RecordingTrack.self, from: encoded)
        XCTAssertEqual(back.clockSamples, stored)
        XCTAssertEqual(RecordingClockMap.elapsed(at: start.addingTimeInterval(200), samples: back.clockSamples ?? []), 80, "paused for two minutes")
    }
}

extension NotebookFixtures {
    static func pageWithErased(_ id: UUID, _ erased: [ErasedStroke]) -> NotebookPage {
        var page = NotebookFixtures.page(id)
        page.erased = erased
        return page
    }
}
