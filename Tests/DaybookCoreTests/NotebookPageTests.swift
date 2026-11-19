import XCTest
@testable import DaybookCore

/// Notebook pages as stored: old conversations unchanged, unknown keys and values kept, readings and corrections that
/// stand only while their strokes do, and the editing methods' Version History.
final class NotebookPageTests: XCTestCase {
    private let start = NotebookFixtures.start
    private func encoded(_ meeting: Meeting) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(meeting)
    }

    // MARK: Stored format

    func testBehaviorConversationWithoutPagesDecodesAndEncodesUnchanged() throws {
        // A meeting.json as Daybook wrote it before pages, and the bytes a Daybook of any version writes for it back.
        let id = "6F3C1D2A-9B8E-4C7D-A1B2-3C4D5E6F7A8B"
        let legacy = """
        {"alignmentReports":[],"date":780000000,"highlights":[],"id":"\(id)","kind":"general","notes":"Ship it",\
        "revisions":[],"schemaVersion":1,"speakers":[],"status":"ready","title":"Planning","tracks":[],"transcripts":[],\
        "unifiedTranscript":[],"updatedAt":780000100}
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(legacy.utf8))
        XCTAssertNil(meeting.pages)
        XCTAssertTrue(meeting.visiblePages.isEmpty)
        XCTAssertEqual(meeting.nextPageOrder, 1)
        let written = try XCTUnwrap(String(data: try encoded(meeting), encoding: .utf8))
        XCTAssertEqual(written, legacy, "byte for byte as before")
        XCTAssertFalse(written.contains("pages"))
    }

    func testBehaviorRecordsWithoutTheOptionalDetailsEncodeUnchanged() throws {
        // A track and a page as 1a and before wrote them: none of the optional records (clock samples, background, erasures, page
        // turns) is written, and what is read is written back byte for byte.
        let track = "7A1B2C3D-0000-4000-8000-000000000001", page = "7A1B2C3D-0000-4000-8000-000000000002"
        let legacy = """
        {"alignmentReports":[],"date":780000000,"highlights":[],"id":"6F3C1D2A-9B8E-4C7D-A1B2-3C4D5E6F7A8B","kind":"general","notes":"",\
        "pages":[{"createdAt":780000000,"height":595,"id":"\(page)","order":1,"paper":"ruled","updatedAt":780000000,"width":420}],\
        "revisions":[],"schemaVersion":1,"speakers":[],"status":"ready","title":"Planning",\
        "tracks":[{"createdAt":780000000,"fileName":"a.wav","id":"\(track)","relativePath":"Originals\\/a.wav","sha256":"","source":"microphone"}],\
        "transcripts":[],"unifiedTranscript":[],"updatedAt":780000100}
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(legacy.utf8))
        XCTAssertNil(meeting.tracks[0].clockSamples)
        XCTAssertNil(meeting.pages?[0].background)
        XCTAssertNil(meeting.pages?[0].erased)
        XCTAssertNil(meeting.pageTurns)
        let written = try XCTUnwrap(String(data: try encoded(meeting), encoding: .utf8))
        XCTAssertEqual(written, legacy, "byte for byte as before")
    }

    /// A page with every optional present, as a dictionary, so unknown keys can be put into each record.
    private func fullPageJSON() throws -> (meeting: Meeting, json: [String: Any]) {
        let id = UUID()
        let drawing = NotebookFixtures.drawing(id, "a")
        let passage = NotebookFixtures.passage(id)
        var page = NotebookPage(id: id, order: 1, origin: PhotoOrigin(kind: "daybook.iphone", serial: "s"), now: start)
        page.drawing = drawing
        page.setAside = [NotebookFixtures.drawing(id, "b")]
        page.reading = NotebookFixtures.reading(of: drawing, [passage])
        page.corrections = [PassageCorrection(passageID: passage.id, strokeDigest: passage.strokeDigest, text: "hello world", editedAt: start)]
        page.sketches = [SketchAnalysis(passageID: passage.id, strokeDigest: passage.strokeDigest, analysis: PhotoAnalysis(caption: "A box", createdAt: start))]
        page.hiddenFromSummary = true
        let picture = AudioDigest.sha256(data: Data("picture".utf8))
        page.setBackground(PageBackground(relativePath: PageBackground.relativePath(page: id, sha256: picture, fileExtension: "pdf"), sha256: picture,
                                          byteCount: 900, kind: .pdf, fileExtension: "pdf", pageIndex: 2, width: 595, height: 842, editedAt: start), now: start)
        page.erased = [ErasedStroke(key: "1-3-10-10", madeAt: start, erasedAt: start.addingTimeInterval(9), trackID: UUID(), time: 4)]
        var meeting = NotebookFixtures.meeting(pages: [page])
        meeting.pageTurns = [PageTurn(at: start.addingTimeInterval(20), pages: [id], trackID: UUID(), time: 15)]
        var recording = RecordingTrack(source: .microphone, relativePath: "Originals/a.wav", fileName: "a.wav", createdAt: start)
        recording.clockSamples = [RecordingClockSample(at: start, elapsed: 0, running: true), RecordingClockSample(at: start.addingTimeInterval(30), elapsed: 30, running: false)]
        meeting.tracks = [recording]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoded(meeting)) as? [String: Any])
        return (meeting, json)
    }

    func testBehaviorUnknownKeysOnPageDrawingReadingPassageRoundTrip() throws {
        let (meeting, original) = try fullPageJSON()
        XCTAssertTrue(try XCTUnwrap(meeting.pages?.first).unknownFields.isEmpty)
        var json = original
        var pages = try XCTUnwrap(json["pages"] as? [[String: Any]])
        var page = pages[0]
        page["pageFuture"] = ["tags": [1, 2]]
        var drawing = try XCTUnwrap(page["drawing"] as? [String: Any])
        drawing["drawingFuture"] = "d"
        page["drawing"] = drawing
        var reading = try XCTUnwrap(page["reading"] as? [String: Any])
        reading["readingFuture"] = 7
        var passages = try XCTUnwrap(reading["passages"] as? [[String: Any]])
        passages[0]["passageFuture"] = "p"
        reading["passages"] = passages
        page["reading"] = reading
        var setAside = try XCTUnwrap(page["setAside"] as? [[String: Any]])
        setAside[0]["asideFuture"] = true
        page["setAside"] = setAside
        var corrections = try XCTUnwrap(page["corrections"] as? [[String: Any]])
        corrections[0]["correctionFuture"] = "c"
        page["corrections"] = corrections
        var sketches = try XCTUnwrap(page["sketches"] as? [[String: Any]])
        sketches[0]["sketchFuture"] = "s"
        page["sketches"] = sketches
        var background = try XCTUnwrap(page["background"] as? [String: Any])
        background["backgroundFuture"] = "b"
        page["background"] = background
        var erased = try XCTUnwrap(page["erased"] as? [[String: Any]])
        erased[0]["erasedFuture"] = "e"
        page["erased"] = erased
        pages[0] = page
        json["pages"] = pages
        var turns = try XCTUnwrap(json["pageTurns"] as? [[String: Any]])
        turns[0]["turnFuture"] = "t"
        json["pageTurns"] = turns
        var tracks = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        var samples = try XCTUnwrap(tracks[0]["clockSamples"] as? [[String: Any]])
        samples[0]["sampleFuture"] = "s"
        tracks[0]["clockSamples"] = samples
        tracks[0]["trackFuture"] = "k"
        json["tracks"] = tracks

        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        let stored = try XCTUnwrap(decoded.pages?.first)
        XCTAssertFalse(stored.unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(stored.drawing).unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(stored.reading).unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(stored.reading?.passages.first).unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(stored.setAside?.first).unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(stored.corrections?.first).unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(stored.sketches?.first).unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(stored.background).unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(stored.erased?.first).unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(decoded.pageTurns?.first).unknownFields.isEmpty)
        XCTAssertFalse(try XCTUnwrap(decoded.tracks[0].clockSamples?.first).unknownFields.isEmpty)

        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoded(decoded)) as? [String: Any])
        let writtenPage = try XCTUnwrap((again["pages"] as? [[String: Any]])?.first)
        XCTAssertEqual(writtenPage["pageFuture"] as? [String: [Int]], ["tags": [1, 2]])
        XCTAssertEqual((writtenPage["drawing"] as? [String: Any])?["drawingFuture"] as? String, "d")
        let writtenReading = try XCTUnwrap(writtenPage["reading"] as? [String: Any])
        XCTAssertEqual(writtenReading["readingFuture"] as? Int, 7)
        XCTAssertEqual((writtenReading["passages"] as? [[String: Any]])?.first?["passageFuture"] as? String, "p")
        XCTAssertEqual((writtenPage["setAside"] as? [[String: Any]])?.first?["asideFuture"] as? Bool, true)
        XCTAssertEqual((writtenPage["corrections"] as? [[String: Any]])?.first?["correctionFuture"] as? String, "c")
        XCTAssertEqual((writtenPage["sketches"] as? [[String: Any]])?.first?["sketchFuture"] as? String, "s")
        XCTAssertEqual((writtenPage["background"] as? [String: Any])?["backgroundFuture"] as? String, "b")
        XCTAssertEqual((writtenPage["erased"] as? [[String: Any]])?.first?["erasedFuture"] as? String, "e")
        XCTAssertEqual((again["pageTurns"] as? [[String: Any]])?.first?["turnFuture"] as? String, "t")
        let writtenTrack = try XCTUnwrap((again["tracks"] as? [[String: Any]])?.first)
        XCTAssertEqual(writtenTrack["trackFuture"] as? String, "k")
        XCTAssertEqual((writtenTrack["clockSamples"] as? [[String: Any]])?.first?["sampleFuture"] as? String, "s")
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: encoded(decoded)), decoded)
    }

    func testBehaviorUnknownPaperAndKindReadAsFallbackAndWriteBack() throws {
        var (_, json) = try fullPageJSON()
        var pages = try XCTUnwrap(json["pages"] as? [[String: Any]])
        pages[0]["paper"] = "watercolour"
        var background = try XCTUnwrap(pages[0]["background"] as? [String: Any])
        background["kind"] = "svg"
        pages[0]["background"] = background
        var reading = try XCTUnwrap(pages[0]["reading"] as? [String: Any])
        var passages = try XCTUnwrap(reading["passages"] as? [[String: Any]])
        passages[0]["kind"] = "diagram"
        reading["passages"] = passages
        pages[0]["reading"] = reading
        json["pages"] = pages
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        let page = try XCTUnwrap(decoded.pages?.first)
        XCTAssertEqual(page.paper, .plain)
        XCTAssertEqual(page.passages.first?.kind, .writing, "a newer kind reads as writing, so its words count")
        XCTAssertEqual(page.background?.kind, .image, "a newer background kind reads as a picture")
        let text = try XCTUnwrap(String(data: try encoded(decoded), encoding: .utf8))
        XCTAssertTrue(text.contains("\"paper\":\"watercolour\""))
        XCTAssertTrue(text.contains("\"kind\":\"diagram\""))
        XCTAssertTrue(text.contains("\"kind\":\"svg\""))
        // Setting a known value replaces the unknown one.
        var edited = decoded
        edited.pages?[0].paper = .grid
        XCTAssertTrue(try XCTUnwrap(String(data: try encoded(edited), encoding: .utf8)).contains("\"paper\":\"grid\""))
    }

    // MARK: Corrections and readings

    func testBehaviorCorrectionStandsWhileStrokesUnchanged() throws {
        let id = UUID()
        let passage = NotebookFixtures.passage(id)
        var meeting = NotebookFixtures.meeting(pages: [NotebookFixtures.page(id, passages: [passage])])
        meeting.correctPassage(pageID: id, passageID: passage.id, text: "  hello world ", now: start.addingTimeInterval(200))
        var page = try XCTUnwrap(meeting.page(id))
        XCTAssertEqual(page.words(of: passage), "hello world", "typed words, trimmed")
        XCTAssertEqual(page.correction(for: passage)?.strokeDigest, passage.strokeDigest)
        // Read again from the same strokes: the correction stands.
        let drawing = try XCTUnwrap(page.drawing)
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: drawing, [NotebookFixtures.passage(id, words: "hello wrld!")], at: 300))
        page = try XCTUnwrap(meeting.page(id))
        XCTAssertEqual(page.words(of: try XCTUnwrap(page.passages.first)), "hello world")
    }

    func testBehaviorCorrectionLapsesWhenStrokesChange() throws {
        let id = UUID()
        let passage = NotebookFixtures.passage(id)
        var meeting = NotebookFixtures.meeting(pages: [NotebookFixtures.page(id, passages: [passage])])
        meeting.correctPassage(pageID: id, passageID: passage.id, text: "hello world")
        // More strokes were added to the passage: same ID (same first stroke), another digest.
        var changed = passage
        changed.strokeDigest = PassageGrouping.digest(of: ["1-3-10-10", "2-4-50-10"])
        changed.words = "hello wrld again"
        meeting.commitPageDrawing(id, drawing: NotebookFixtures.drawing(id, "more ink"), now: start.addingTimeInterval(400))
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: try XCTUnwrap(meeting.page(id)?.drawing), [changed], at: 500))
        let page = try XCTUnwrap(meeting.page(id))
        let shown = try XCTUnwrap(page.passages.first)
        XCTAssertNil(page.correction(for: shown))
        XCTAssertEqual(page.words(of: shown), "hello wrld again", "what was read now")
        XCTAssertEqual(page.corrections?.count, 1, "kept, in case the strokes come back")
    }

    func testBehaviorReadingStaleAfterNewDrawingOrNewGroupingVersion() throws {
        let id = UUID()
        var page = NotebookFixtures.page(id, passages: [NotebookFixtures.passage(id)])
        XCTAssertTrue(page.isReadingCurrent)
        XCTAssertFalse(page.needsReading)
        // New strokes.
        var meeting = NotebookFixtures.meeting(pages: [page])
        meeting.commitPageDrawing(id, drawing: NotebookFixtures.drawing(id, "next"), now: start.addingTimeInterval(300))
        let recommitted = try XCTUnwrap(meeting.page(id))
        XCTAssertFalse(recommitted.isReadingCurrent)
        XCTAssertTrue(recommitted.needsReading)
        XCTAssertEqual(recommitted.passages.count, 1, "the earlier reading stays until the new one comes")
        // Another version of the grouping.
        page.reading = NotebookFixtures.reading(of: try XCTUnwrap(page.drawing), [NotebookFixtures.passage(id)], grouping: PassageGrouping.version - 1)
        XCTAssertFalse(page.isReadingCurrent)
        XCTAssertTrue(page.needsReading)
        page.reading?.settings = nil
        XCTAssertTrue(page.needsReading, "a reading that says nothing of its grouping is read again")
        // No strokes: nothing to read.
        XCTAssertFalse(NotebookPage(order: 1).needsReading)
        XCTAssertFalse(NotebookPage(order: 1).isReadingCurrent)
    }

    func testBehaviorReadingForReplacedDrawingIsDropped() throws {
        let id = UUID()
        var meeting = NotebookFixtures.meeting(pages: [NotebookFixtures.page(id, tag: "new")])
        let replaced = NotebookFixtures.drawing(id, "old")
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: replaced, [NotebookFixtures.passage(id)]))
        XCTAssertNil(meeting.page(id)?.reading)
        XCTAssertEqual(meeting.updatedAt, start, "nothing changed")
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: try XCTUnwrap(meeting.page(id)?.drawing), [NotebookFixtures.passage(id)]))
        XCTAssertNotNil(meeting.page(id)?.reading)
    }

    func testBehaviorRereadKeepsTimesOfUnchangedPassages() throws {
        let id = UUID(), track = UUID()
        let timed = NotebookFixtures.passage(id, key: "1-3-10-10", at: 0, trackID: track, time: 12)
        let later = NotebookFixtures.passage(id, key: "9-3-10-90", words: "next", at: 60, time: 70)
        var meeting = NotebookFixtures.meeting(pages: [NotebookFixtures.page(id, passages: [timed, later])])
        let drawing = try XCTUnwrap(meeting.page(id)?.drawing)
        // After filing there's no recording clock: the new reading has no times.
        var reread = timed; reread.trackID = nil; reread.time = nil
        var moved = later; moved.trackID = nil; moved.time = nil; moved.start = later.start.addingTimeInterval(5)
        let fresh = NotebookFixtures.passage(id, key: "20-3-10-200", words: "new", at: 120)
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: drawing, [reread, moved, fresh], at: 200))
        let passages = try XCTUnwrap(meeting.page(id)?.passages)
        XCTAssertEqual(passages[0].trackID, track)
        XCTAssertEqual(passages[0].time, 12, "same ID and start: keeps its time")
        XCTAssertNil(passages[1].time, "its start moved: not the same passage")
        XCTAssertNil(passages[2].time)
        // A time the new reading has is its own.
        var timedAgain = reread; timedAgain.time = 14
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: drawing, [timedAgain], at: 300))
        XCTAssertEqual(meeting.page(id)?.passages.first?.time, 14)
    }

    // MARK: Editing

    func testBehaviorCommitStampsAfterPreviousWhenClockBehind() throws {
        let id = UUID()
        var meeting = NotebookFixtures.meeting(pages: [NotebookPage(id: id, order: 1, now: start)])
        meeting.commitPageDrawing(id, drawing: NotebookFixtures.drawing(id, "one", at: .distantPast), now: start.addingTimeInterval(100))
        XCTAssertEqual(meeting.page(id)?.drawing?.editedAt, start.addingTimeInterval(100), "stamped by the committing clock, not the record's")
        // A device whose clock is 50 s behind commits next.
        meeting.commitPageDrawing(id, drawing: NotebookFixtures.drawing(id, "two"), now: start.addingTimeInterval(50))
        let second = try XCTUnwrap(meeting.page(id)?.drawing?.editedAt)
        XCTAssertEqual(second.timeIntervalSince(start), 100.001, accuracy: 0.0001)
        XCTAssertGreaterThan(second, start.addingTimeInterval(100))
        // The same strokes again commit nothing.
        meeting.commitPageDrawing(id, drawing: NotebookFixtures.drawing(id, "two"), now: start.addingTimeInterval(900))
        XCTAssertEqual(meeting.page(id)?.drawing?.editedAt, second)
        XCTAssertEqual(NotebookPage.stamp(after: nil, now: start), start)
        XCTAssertEqual(NotebookPage.stamp(after: start, now: start.addingTimeInterval(5)), start.addingTimeInterval(5))
        XCTAssertTrue(meeting.revisions.isEmpty, "a stroke commit isn't in Version History")
        // A deleted page takes no strokes.
        meeting.removePage(id, at: start.addingTimeInterval(1_000))
        meeting.commitPageDrawing(id, drawing: NotebookFixtures.drawing(id, "three"), now: start.addingTimeInterval(1_100))
        XCTAssertEqual(meeting.page(id)?.drawing?.sha256, NotebookFixtures.drawing(id, "two").sha256)
    }

    func testBehaviorRemoveAndRestorePageWriteVersionHistory() throws {
        let page = NotebookFixtures.page()
        var meeting = Meeting(title: "Pages", date: start)
        meeting.addPage(page)
        meeting.addPage(page)
        XCTAssertEqual(meeting.pages?.count, 1, "a page already there isn't added twice")
        meeting.removePage(page.id, at: start.addingTimeInterval(10))
        meeting.removePage(page.id, at: start.addingTimeInterval(11))
        XCTAssertTrue(meeting.visiblePages.isEmpty)
        XCTAssertEqual(meeting.pages?.count, 1, "the record and its files stay")
        XCTAssertEqual(meeting.page(page.id)?.removedAt, start.addingTimeInterval(10))
        meeting.restorePage(page.id)
        XCTAssertEqual(meeting.visiblePages.map(\.id), [page.id])
        XCTAssertNil(meeting.page(page.id)?.removedAt)
        XCTAssertEqual(meeting.revisions.map(\.kind), [.page(page.id), .page(page.id), .page(page.id)])
        XCTAssertEqual(meeting.revisions.map(\.oldValue), ["", "present", "removed"])
        XCTAssertEqual(meeting.revisions.map(\.newValue), ["added", "removed", "present"])
        XCTAssertEqual(meeting.revisions.map(\.field).first, "page:\(page.id.uuidString)")
    }

    func testBehaviorCorrectionWritesVersionHistory() throws {
        let id = UUID()
        let passage = NotebookFixtures.passage(id)
        var meeting = NotebookFixtures.meeting(pages: [NotebookFixtures.page(id, passages: [passage])])
        meeting.correctPassage(pageID: id, passageID: passage.id, text: "hello world", now: start.addingTimeInterval(10))
        meeting.correctPassage(pageID: id, passageID: passage.id, text: "hello world", now: start.addingTimeInterval(11))
        XCTAssertEqual(meeting.revisions.count, 1, "the same words again change nothing")
        XCTAssertEqual(meeting.revisions[0].kind, .passage(passage.id))
        XCTAssertEqual(meeting.revisions[0].oldValue, "hello wrld")
        XCTAssertEqual(meeting.revisions[0].newValue, "hello world")
        meeting.correctPassage(pageID: id, passageID: passage.id, text: "hello planet", now: start.addingTimeInterval(12))
        XCTAssertEqual(meeting.revisions[1].oldValue, "hello world")
        XCTAssertEqual(meeting.revisions[1].newValue, "hello planet")
        // The words that were read take the correction away, as does empty text.
        meeting.correctPassage(pageID: id, passageID: passage.id, text: "hello wrld ", now: start.addingTimeInterval(13))
        XCTAssertNil(meeting.page(id)?.corrections)
        XCTAssertEqual(meeting.revisions[2].oldValue, "hello planet")
        XCTAssertEqual(meeting.revisions[2].newValue, "hello wrld")
        meeting.correctPassage(pageID: id, passageID: passage.id, text: "x", now: start.addingTimeInterval(14))
        meeting.correctPassage(pageID: id, passageID: passage.id, text: "   ", now: start.addingTimeInterval(15))
        XCTAssertNil(meeting.page(id)?.corrections)
        XCTAssertEqual(meeting.revisions.last?.newValue, "hello wrld")
        // A passage that isn't on the page is no correction.
        let count = meeting.revisions.count
        meeting.correctPassage(pageID: id, passageID: UUID(), text: "ghost")
        XCTAssertEqual(meeting.revisions.count, count)
    }

    func testBehaviorVisiblePagesOrderByOrderCreatedThenID() {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        func page(_ id: UUID, order: Double, created: TimeInterval) -> NotebookPage {
            var page = NotebookPage(id: id, order: order, now: start.addingTimeInterval(created))
            page.updatedAt = start
            return page
        }
        let last = page(UUID(), order: 5, created: 0)
        let tieHigh = page(high, order: 2, created: 10)
        let tieLow = page(low, order: 2, created: 10)
        let earlier = page(UUID(), order: 2, created: 5)
        var gone = page(UUID(), order: 0, created: 0)
        gone.removedAt = start
        let meeting = NotebookFixtures.meeting(pages: [last, tieHigh, gone, tieLow, earlier])
        XCTAssertEqual(meeting.visiblePages.map(\.id), [earlier.id, low, high, last.id])
        XCTAssertEqual(meeting.pageNumber(of: high), 3)
        XCTAssertNil(meeting.pageNumber(of: gone.id), "a deleted page has no number")
        XCTAssertEqual(meeting.nextPageOrder, 6)
        var deletedLast = meeting
        var removed = page(UUID(), order: 9, created: 0)
        removed.removedAt = start
        deletedLast.pages?.append(removed)
        XCTAssertEqual(deletedLast.nextPageOrder, 10, "deleted pages count: a new page never reuses their place")
    }

    // MARK: The timeline

    private func track(startedAt: Date, offset: TimeInterval? = 0, device: DeviceRecordingIdentity? = nil, alignment: SourceAlignment? = nil) -> RecordingTrack {
        var value = RecordingTrack(source: .microphone, relativePath: "Originals/\(UUID().uuidString).m4a", fileName: "a.m4a", duration: 600,
                                   offset: offset, sha256: String(repeating: "b", count: 64), device: device, startedAt: startedAt, alignment: alignment)
        if device == nil { value.capture = TrackCaptureDetails() }
        return value
    }

    func testBehaviorPassageTimelineTimeFollowsTrackPlacement() throws {
        let macStart = Date(timeIntervalSince1970: 1_800_000_000)
        let phoneStart = macStart.addingTimeInterval(4 + 2.5)
        let identity = DeviceRecordingIdentity(kind: "daybook.iphone", serial: "install-1", recordingID: UUID().uuidString)
        let mic = track(startedAt: macStart)
        var phone = track(startedAt: phoneStart, offset: nil, device: identity, alignment: SourceAlignment(method: .pending, clockOffset: 4.0))
        var meeting = Meeting(title: "Design review", date: macStart, tracks: [mic, phone])
        let page = NotebookPage(order: 1, origin: PhotoOrigin(kind: "daybook.iphone", serial: "install-1"), now: macStart)
        var written = NotebookFixtures.passage(page.id, at: 0, trackID: phone.id, time: 60)
        written.start = phoneStart.addingTimeInterval(60)
        XCTAssertEqual(try XCTUnwrap(meeting.timelineTime(of: written, on: page)), 64, accuracy: 0.001, "the clock prior, before the sound places it")
        phone.alignment = SourceAlignment(method: .audio, offset: 4.2, rate: 1.0005, confidence: 0.9, referenceTrackID: mic.id)
        phone.offset = 4.2
        meeting.tracks[1] = phone
        XCTAssertEqual(try XCTUnwrap(meeting.timelineTime(of: written, on: page)), 4.2 + 1.0005 * 60, accuracy: 0.001, "moves with its recording")
        // On the timeline's own clock (no track): that time.
        let own = NotebookFixtures.passage(page.id, key: "2-1-0-0", at: 0, time: 95)
        XCTAssertEqual(meeting.timelineTime(of: own, on: page), 95)
        // The same arguments place a photo alike.
        let photo = MeetingPhoto(relativePath: "Originals/Photos/w.heic", fileName: "w.heic", sha256: "", capturedAt: written.start,
                                 trackID: phone.id, time: 60, origin: page.origin)
        XCTAssertEqual(meeting.timelineTime(of: photo), meeting.timelineTime(of: written, on: page))
    }

    func testBehaviorUntimedPassagePlacedByWallClockLikePhoto() throws {
        let macStart = Date(timeIntervalSince1970: 1_800_000_000)
        let phoneStart = macStart.addingTimeInterval(4 + 2.5)
        let identity = DeviceRecordingIdentity(kind: "daybook.iphone", serial: "install-1", recordingID: UUID().uuidString)
        let mic = track(startedAt: macStart)
        var phone = track(startedAt: phoneStart, offset: 4.2, device: identity)
        phone.alignment = SourceAlignment(method: .audio, offset: 4.2, rate: 1.0005, confidence: 0.9, referenceTrackID: mic.id)
        let meeting = Meeting(title: "Design review", date: macStart, tracks: [mic, phone])
        let page = NotebookPage(order: 1, origin: PhotoOrigin(kind: "daybook.iphone", serial: "install-1"), now: macStart)
        var late = NotebookFixtures.passage(page.id, at: 0)
        late.start = phoneStart.addingTimeInterval(620)
        let photo = MeetingPhoto(relativePath: "Originals/Photos/x.heic", fileName: "x.heic", sha256: "", capturedAt: late.start, origin: page.origin)
        XCTAssertEqual(try XCTUnwrap(meeting.timelineTime(of: late, on: page)), 4.2 + 1.0005 * 620, accuracy: 0.001, "read through the phone's recording")
        XCTAssertEqual(meeting.timelineTime(of: late, on: page), meeting.timelineTime(of: photo))
        // A passage of another day isn't on this timeline.
        var elsewhere = late
        elsewhere.start = macStart.addingTimeInterval(86_400)
        XCTAssertNil(meeting.timelineTime(of: elsewhere, on: NotebookPage(order: 1, now: macStart)))
        XCTAssertNil(Meeting(title: "Notes only").timelineTime(of: late, on: page), "no recordings, no timeline")
    }

    func testBehaviorAdoptingRecordedPagesAddsNewOnesAndMergesLoadedOnesWithTheirBase() throws {
        let kept = NotebookFixtures.page(order: 1, tag: "kept")
        var meeting = NotebookFixtures.meeting(pages: [kept])
        // A recording loaded `kept`, and another device hid it meanwhile.
        meeting.pages?[0].hiddenFromSummary = true
        var recorded = kept
        recorded.drawing = NotebookFixtures.drawing(kept.id, "more", at: start.addingTimeInterval(500))
        let made = NotebookFixtures.page(order: 2, tag: "new")
        meeting.adoptRecordedPages([RecordedPage(page: recorded, base: kept), RecordedPage(page: made, base: nil)], now: start.addingTimeInterval(600))
        let stored = try XCTUnwrap(meeting.page(kept.id))
        XCTAssertEqual(stored.drawing?.sha256, recorded.drawing?.sha256, "the recording's strokes")
        XCTAssertEqual(stored.hiddenFromSummary, true, "what changed elsewhere survives")
        XCTAssertEqual(meeting.visiblePages.map(\.id), [kept.id, made.id])
        XCTAssertEqual(meeting.revisions.filter { $0.kind == .page(made.id) }.count, 1)
        XCTAssertEqual(meeting.revisions.filter { $0.kind == .page(kept.id) }.count, 0)
    }

    // MARK: Fixes from review

    func testBehaviorReadingByNewerGroupingIsCurrentHere() throws {
        let id = UUID()
        var page = NotebookFixtures.page(id)
        page.reading = NotebookFixtures.reading(of: page.drawing!, [NotebookFixtures.passage(id)], grouping: PassageGrouping.version + 1)
        XCTAssertTrue(page.isReadingCurrent, "a newer grouping's reading isn't read again by an older version")
        XCTAssertFalse(page.needsReading)
        XCTAssertEqual(page.reading?.groupingVersion, PassageGrouping.version + 1)
        page.reading?.settings?.parameters["grouping"] = "garbage"
        XCTAssertEqual(page.reading?.groupingVersion, 0)
        XCTAssertTrue(page.needsReading)
    }

    func testBehaviorReadingByOlderGroupingIsRefusedForTheSameStrokes() throws {
        let id = UUID()
        let newer = PassageGrouping.version + 1
        var meeting = NotebookFixtures.meeting(pages: [NotebookFixtures.page(id)])
        let drawing = try XCTUnwrap(meeting.page(id)?.drawing)
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: drawing, [NotebookFixtures.passage(id, words: "newer")], grouping: newer))
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: drawing, [NotebookFixtures.passage(id, words: "older")], at: 500))
        XCTAssertEqual(meeting.page(id)?.passages.first?.words, "newer")
        // The same grouping again, or a newer, replaces it; and the first reading of other strokes is accepted whatever its grouping.
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: drawing, [NotebookFixtures.passage(id, words: "again")], at: 600, grouping: newer))
        XCTAssertEqual(meeting.page(id)?.passages.first?.words, "again")
        meeting.commitPageDrawing(id, drawing: NotebookFixtures.drawing(id, "next"), now: start.addingTimeInterval(900))
        let next = try XCTUnwrap(meeting.page(id)?.drawing)
        meeting.applyPageReading(id, reading: NotebookFixtures.reading(of: next, [NotebookFixtures.passage(id, words: "fresh")], at: 1_000))
        XCTAssertEqual(meeting.page(id)?.passages.first?.words, "fresh")
    }

    func testBehaviorAdoptingRecordedPageWithNoBaseKeepsStrokesAndNotesAConflict() throws {
        let existing = NotebookFixtures.page(order: 1, tag: "filed-before")
        var meeting = NotebookFixtures.meeting(pages: [existing])
        // Filing ran once and crashed before the staging folder went: it runs again with the same recorded page.
        var recorded = existing
        recorded.drawing = NotebookFixtures.drawing(existing.id, "recorded", at: start.addingTimeInterval(400))
        meeting.adoptRecordedPages([RecordedPage(page: recorded, base: nil)], now: start.addingTimeInterval(500))
        let page = try XCTUnwrap(meeting.page(existing.id))
        XCTAssertEqual(page.drawing?.sha256, recorded.drawing?.sha256, "the recorded strokes aren't dropped")
        XCTAssertEqual(page.setAside?.map(\.sha256), [existing.drawing!.sha256], "and the other are set aside, files kept")
        XCTAssertTrue(meeting.revisions.contains { $0.field == "sync:page-drawing:\(existing.id)" }, "with the usual History entry")
        // Again: nothing changes, and the entry isn't repeated.
        let again = meeting
        meeting.adoptRecordedPages([RecordedPage(page: recorded, base: nil)], now: start.addingTimeInterval(600))
        XCTAssertEqual(meeting.pages, again.pages)
        XCTAssertEqual(meeting.revisions.count, again.revisions.count)
    }

    func testBehaviorNestedTypesKeepUnknownKeys() throws {
        func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ json: String, key: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let decoded = try JSONDecoder().decode(T.self, from: Data(json.utf8))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let written = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(decoded)) as? [String: Any])
            XCTAssertNotNil(written[key], "\(T.self) keeps \(key)", file: file, line: line)
            XCTAssertEqual(try JSONDecoder().decode(T.self, from: encoder.encode(decoded)), decoded, file: file, line: line)
        }
        try roundTrip(PhotoOrigin.self, #"{"kind":"mac","name":"Studio","future":{"a":1}}"#, key: "future")
        try roundTrip(ProcessingSettings.self, #"{"modelID":"m","parameters":{"a":"b"},"createdAt":1,"future":[1,2]}"#, key: "future")
        try roundTrip(PhotoAnalysis.self, #"{"isInformative":true,"createdAt":1,"future":"x"}"#, key: "future")
        // Known data is written exactly as before: no extra keys.
        let origin = PhotoOrigin(kind: "mac", serial: nil, name: "Studio")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(origin), as: UTF8.self), #"{"kind":"mac","name":"Studio"}"#)
        XCTAssertEqual(origin.hashValue, PhotoOrigin(kind: "mac", serial: nil, name: "Studio").hashValue)
        let settings = ProcessingSettings(modelID: "m", parameters: [:], createdAt: Date(timeIntervalSinceReferenceDate: 1))
        XCTAssertEqual(String(decoding: try encoder.encode(settings), as: UTF8.self), #"{"createdAt":1,"modelID":"m","parameters":{}}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(PhotoAnalysis(createdAt: Date(timeIntervalSinceReferenceDate: 1))), as: UTF8.self),
                       #"{"createdAt":1,"isInformative":true}"#)
    }
}
