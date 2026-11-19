import DaybookCore
import XCTest
@testable import DaybookKit

/// What reads notebook pages: the summary's source (handwriting as notes labelled H), library search, and the exports.
final class NotebookReadersTests: XCTestCase {
    private typealias Pages = NotebookTestPages
    private let track = UUID()

    private func meeting(notes: String = "", pages: [NotebookPage], speech: Bool = true) -> Meeting {
        var meeting = Meeting(title: "Launch", notes: notes, speakers: [Speaker(id: "alex", name: "Alex")])
        if speech {
            meeting.unifiedTranscript = [TranscriptSegment(trackID: track, start: 0, end: 8, text: "Let's start with the launch.", speakerID: "alex"),
                                         TranscriptSegment(trackID: track, start: 100, end: 108, text: "Pricing is twelve dollars.", speakerID: "alex")]
        }
        meeting.pages = pages
        return meeting
    }

    // MARK: Summary source

    func testBehaviorWritingPassagesBecomeTimedNotesLabelledHInTimeOrderUntimedLast() {
        let id = UUID(), second = UUID()
        let first = Pages.page(id, order: 1, [Pages.passage(id, key: "a", words: "ask about budget", time: 120, y: 200),
                                              Pages.passage(id, key: "b", words: "venue by Friday", time: 30, y: 40),
                                              Pages.passage(id, key: "c", words: "someone to call", y: 100)])
        let later = Pages.page(second, order: 2, [Pages.passage(second, key: "d", words: "page two idea", time: 75)])
        let source = MeetingEvidence.summarySource(meeting(notes: "Typed note", pages: [later, first]))
        let handwriting = source.anchors.filter(\.isHandwriting)
        XCTAssertEqual(handwriting.map(\.label), ["H1", "H2", "H3", "H4"])
        XCTAssertEqual(handwriting.map(\.text), ["venue by Friday", "page two idea", "ask about budget", "someone to call"],
                       "By conversation time; the one with no time after the timed ones")
        XCTAssertEqual(handwriting.map(\.time), [30, 75, 120, nil])
        XCTAssertEqual(handwriting.map(\.page), [1, 2, 1, 1])
        XCTAssertEqual(source.anchors.map(\.label), ["N1", "H1", "H2", "H3", "H4"], "After the typed notes")
        XCTAssertEqual(handwriting[0].window, (30 - 60)...(34 + 15), "A note's window around the writing")
        XCTAssertTrue(source.annotatedTranscript.contains("[00:30] NOTE H1, handwritten on page 1 by the user (not spoken; read from handwriting, so a word may be misread): venue by Friday"))
        let payload = source.notesPayload.last!
        XCTAssertEqual(payload["placement"] as? String, "written outside the recording")
        XCTAssertEqual(payload["source"] as? String, "handwriting")
        // The same lines in time order among the transcript.
        let lines = source.annotatedTranscript.components(separatedBy: "\n")
        XCTAssertLessThan(lines.firstIndex { $0.contains("NOTE H1") }!, lines.firstIndex { $0.contains("Pricing is twelve") }!)
        XCTAssertGreaterThan(lines.firstIndex { $0.contains("NOTE H3") }!, lines.firstIndex { $0.contains("Pricing is twelve") }!)
    }

    func testBehaviorCorrectedWordsAreUsedAndRemovedOrHiddenPagesAndEmptyPassagesLeftOut() {
        let id = UUID(), gone = UUID(), hidden = UUID()
        var kept = Pages.page(id, [Pages.passage(id, key: "a", words: "bugdet 40k", time: 20), Pages.passage(id, key: "b", words: "  ", time: 30),
                                   Pages.passage(id, key: "s", words: "sketch words", kind: .sketch, time: 40)])
        var meeting = meeting(pages: [kept, Pages.page(gone, order: 2, [Pages.passage(gone, key: "x", words: "deleted page words", time: 50)]),
                                      Pages.page(hidden, order: 3, [Pages.passage(hidden, key: "y", words: "hidden page words", time: 60)])])
        meeting.correctPassage(pageID: id, passageID: kept.passages[0].id, text: "budget 40k")
        meeting.removePage(gone)
        meeting.setPageHiddenFromSummary(hidden, hidden: true)
        kept = meeting.page(id)!
        let anchors = MeetingEvidence.summarySource(meeting).anchors
        XCTAssertEqual(anchors.map(\.text), ["budget 40k"], "The correction wins; no deleted or hidden page, no empty passage, no sketch's words")
        XCTAssertFalse(MeetingEvidence.notes(meeting).contains("deleted page words"))
        XCTAssertTrue(MeetingEvidence.notes(meeting).contains("[USER HANDWRITING — page 1, written at meeting time 00:20] budget 40k"))
    }

    func testBehaviorHandwritingAlreadyInTypedNotesIsNotSentTwice() {
        let id = UUID()
        let page = Pages.page(id, [Pages.passage(id, key: "a", words: "Budget cap is firm at 40k", time: 20),
                                   Pages.passage(id, key: "b", words: "Call the venue", time: 40)])
        let source = MeetingEvidence.summarySource(meeting(notes: "Budget cap is firm at 40k\nOther note", pages: [page]))
        XCTAssertEqual(source.anchors.map(\.text), ["Budget cap is firm at 40k", "Other note", "Call the venue"])
        XCTAssertEqual(source.anchors.map(\.label), ["N1", "N2", "H1"])
    }

    func testBehaviorAConversationWithNoSpeechIsSaidSoAndStillHasContent() {
        let id = UUID()
        let page = Pages.page(id, [Pages.passage(id, key: "a", words: "design review next week", time: 20)])
        let source = MeetingEvidence.summarySource(meeting(pages: [page], speech: false))
        XCTAssertTrue(source.hasContent)
        XCTAssertTrue(source.annotatedTranscript.hasPrefix(SummarySource.noSpeech))
        XCTAssertTrue(source.annotatedTranscript.contains("design review next week"))
        XCTAssertEqual(source.transcript, "", "Nothing to check quotes against")
        XCTAssertFalse(MeetingEvidence.summarySource(meeting(pages: [], speech: false)).hasContent, "Nothing said and nothing written")
        XCTAssertTrue(MeetingEvidence.summarySource(meeting(notes: "Only a note", pages: [], speech: false)).hasContent)
        XCTAssertFalse(MeetingEvidence.summarySource(meeting(pages: [], speech: true)).annotatedTranscript.contains("No speech"))
    }

    func testBehaviorACorrectionChangesTheSummaryInputsButReadingTheSameStrokesAgainDoesNot() {
        let id = UUID()
        let original = meeting(pages: [Pages.page(id, [Pages.passage(id, key: "a", words: "bugdet", time: 20)])])
        var reread = original
        reread.applyPageReading(id, reading: PageReading(drawingSHA256: original.pages![0].drawing!.sha256, passages: original.pages![0].passages,
                                                          readAt: Pages.start.addingTimeInterval(999), settings: original.pages![0].reading?.settings))
        XCTAssertFalse(reread.summaryInputsChanged(since: original), "The same reading again")
        var corrected = original
        corrected.correctPassage(pageID: id, passageID: original.pages![0].passages[0].id, text: "budget")
        XCTAssertTrue(corrected.summaryInputsChanged(since: original))
        XCTAssertEqual(corrected.revisions.last?.field, "passage:" + original.pages![0].passages[0].id.uuidString,
                       "A correction is in Version History as it always was")
    }

    // MARK: Search

    func testBehaviorSearchFindsWordsOnPagesIncludingCorrectionsNotDeletedPages() {
        let id = UUID(), gone = UUID()
        var meeting = meeting(pages: [Pages.page(id, [Pages.passage(id, key: "a", words: "zephyr rollout plan", time: 20)]),
                                      Pages.page(gone, order: 2, [Pages.passage(gone, key: "b", words: "quokka migration", time: 30)])])
        func hits(_ text: String) -> [SearchHit] { LibrarySearch.hits(in: [meeting], text: text, tokens: [], scope: .all) }
        XCTAssertEqual(hits("zephyr").first?.field, .pages)
        XCTAssertEqual(hits("zephyr").first?.location, "Notebook")
        XCTAssertEqual(hits("quokka").count, 1)
        meeting.removePage(gone)
        XCTAssertTrue(hits("quokka").isEmpty, "A deleted page isn't searched")
        meeting.correctPassage(pageID: id, passageID: meeting.pages![0].passages[0].id, text: "platypus rollout")
        XCTAssertEqual(hits("platypus").first?.field, .pages, "The correction is found")
        XCTAssertTrue(hits("zephyr").isEmpty, "And what it replaced is not")
    }

    // MARK: Exports

    func testBehaviorMarkdownListsEachPagesWordsInOrderAndSketchDescriptions() {
        let id = UUID()
        let sketch = Pages.passage(id, key: "s", words: nil, kind: .sketch, time: 75, y: 300)
        var page = Pages.page(id, [Pages.passage(id, key: "a", words: "first line\nsecond line", time: 20, y: 10), sketch])
        page.sketches = [Pages.analysis(of: sketch, caption: "Floor plan [click](http://x.test)", text: "Hall B")]
        let markdown = MeetingExport.markdown(meeting(pages: [page]))
        let notebook = try! XCTUnwrap(markdown.components(separatedBy: "## Notebook").last)
        XCTAssertTrue(notebook.contains("### Page 1"))
        XCTAssertTrue(notebook.contains("[00:20] first line / second line"))
        XCTAssertTrue(notebook.contains("[01:15] **Sketch:** Floor plan"), notebook)
        XCTAssertTrue(notebook.contains("“Hall B”"))
        XCTAssertFalse(notebook.contains("[click](http://x.test)"), "A model's caption is escaped")
        XCTAssertLessThan(markdown.range(of: "## Notebook")!.lowerBound, markdown.range(of: "## Transcript")!.lowerBound)
        XCTAssertFalse(MeetingExport.markdown(meeting(pages: [])).contains("## Notebook"))
    }

    func testBehaviorFullDataExportCarriesPageDrawingFilesReadingsAndTheClockSamples() throws {
        let id = UUID()
        var meeting = meeting(pages: [Pages.page(id, [Pages.passage(id, key: "a", words: "hello", time: 20)])])
        var recording = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a")
        recording.clockSamples = [RecordingClockSample(at: Pages.start, elapsed: 12.5, running: true)]
        meeting.tracks = [recording]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("page.pkdrawing")
        try Data("strokes".utf8).write(to: file)
        let drawing = try XCTUnwrap(meeting.pages?[0].drawing)
        let data = try MeetingExport.json(meeting, pageDrawings: [drawing.relativePath: file])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try XCTUnwrap(object["pageDrawingFiles"] as? [[String: String]])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0]["relativePath"], drawing.relativePath)
        XCTAssertEqual(Data(base64Encoded: files[0]["base64"] ?? ""), Data("strokes".utf8))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("hello"), "The reading")
        XCTAssertTrue(text.contains("clockSamples"), "The recording clock")
        XCTAssertFalse(String(decoding: try MeetingExport.json(meeting), as: UTF8.self).contains("pageDrawingFiles"), "No files given, none carried")
    }
}
