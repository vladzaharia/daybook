import XCTest
@testable import DaybookCore

/// Sketches from notebook pages as summary evidence: labels S1…, placement under sections, `sketchIDs` on the summary, and
/// reading each sketch once (a reading stands until the strokes' digest changes).
final class NotebookPlacementTests: XCTestCase {
    private typealias F = NotebookFixtures

    private func analysis(_ passage: NotebookPassage, caption: String? = "Floor plan of hall B", text: String? = "Hall B", informative: Bool = true) -> SketchAnalysis {
        SketchAnalysis(passageID: passage.id, strokeDigest: passage.strokeDigest,
                       analysis: PhotoAnalysis(caption: caption, recognizedText: text, labels: ["diagram"], isInformative: informative,
                                               settings: ProcessingSettings(modelID: "apple-vision/system", createdAt: F.start), createdAt: F.start))
    }

    private func meeting(_ sketches: [(key: String, time: TimeInterval?, informative: Bool)]) -> (Meeting, UUID) {
        let id = UUID()
        let passages = sketches.map { F.passage(id, key: $0.key, words: nil, kind: .sketch, time: $0.time) }
        var page = F.page(id, passages: passages)
        page.sketches = zip(passages, sketches).map { analysis($0, informative: $1.informative) }
        var meeting = F.meeting(pages: [page])
        meeting.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 20, text: "The hall layout needs the stage by the entrance.", speakerID: "a"),
                                     TranscriptSegment(trackID: UUID(), start: 300, end: 320, text: "Catering will arrive on Friday morning.", speakerID: "a")]
        return (meeting, id)
    }

    func testBehaviorSketchCandidatesAreLabelledSInTimeOrderAndNeedAnInformativeCurrentReading() {
        let (meeting, _) = meeting([("a", 200, true), ("b", 10, true), ("c", 50, false), ("d", nil, true)])
        let found = NotebookPlacement.candidates(in: meeting)
        XCTAssertEqual(found.map(\.label), ["S1", "S2", "S3"], "The one that read as nothing is left out")
        XCTAssertEqual(found.map(\.time), [10, 200, nil], "Timeline order, the untimed last")
        XCTAssertTrue(found.allSatisfy(\.isSketch))
        XCTAssertEqual(found.first?.caption, "Floor plan of hall B")
        XCTAssertEqual(found.first?.text, "Hall B")
        XCTAssertEqual(found.first?.page, 1)
        XCTAssertEqual(PhotoPlacement.evidence([found[0]]), "[S1]; drawn at 00:10 on page 1; shows: Floor plan of hall B; text in the drawing: Hall B")
        XCTAssertEqual(PhotoPlacement.evidence([found[2]]), "[S3]; drawn outside the recording on page 1; shows: Floor plan of hall B; text in the drawing: Hall B")
    }

    func testBehaviorEachSketchIsReadOnceAndAgainOnlyWhenItsStrokesChange() {
        var (meeting, id) = meeting([("a", 10, true)])
        XCTAssertTrue(meeting.sketchesNeedingReading.isEmpty, "Already read")
        // New strokes in the same place give the passage a new digest: the reading no longer stands.
        let changed = F.passage(id, key: "a", words: nil, kind: .sketch, time: 10)
        var newer = changed
        newer.strokeDigest = PassageGrouping.digest(of: ["a", "a2"])
        meeting.pages![0].reading!.passages = [newer]
        XCTAssertEqual(meeting.sketchesNeedingReading.map(\.passage.id), [newer.id])
        XCTAssertTrue(NotebookPlacement.candidates(in: meeting).isEmpty, "A reading of other strokes isn't offered")
        meeting.applySketchAnalyses([newer.id: analysis(newer, caption: "Revised plan")])
        XCTAssertTrue(meeting.sketchesNeedingReading.isEmpty)
        XCTAssertEqual(meeting.pages![0].sketches?.count, 1, "Replaces the earlier reading of the passage")
        XCTAssertEqual(NotebookPlacement.candidates(in: meeting).first?.caption, "Revised plan")
        let stamp = meeting.updatedAt
        meeting.applySketchAnalyses([newer.id: analysis(newer, caption: "Revised plan")], now: stamp.addingTimeInterval(99))
        XCTAssertEqual(meeting.updatedAt, stamp, "The same result changes nothing")
    }

    func testBehaviorHidingAPageTakesItsSketchesOutOfTheSummary() {
        let (meeting, pageID) = meeting([("a", 10, true)])
        var hidden = meeting
        let sketch = NotebookPlacement.candidates(in: meeting)[0]
        hidden.summary = MeetingSummary(overview: "x", sections: [SummarySection(heading: "Layout", body: "The hall layout.", sketchIDs: [sketch.id])])
        XCTAssertEqual(hidden.sketches(in: hidden.summary!.sections[0]).count, 1)
        hidden.setPageHiddenFromSummary(pageID, hidden: true)
        XCTAssertNil(hidden.summary?.sections[0].sketchIDs)
        XCTAssertTrue(NotebookPlacement.candidates(in: hidden).isEmpty)
        hidden.removePage(pageID)
        XCTAssertTrue(hidden.sketches(in: SummarySection(heading: "x", body: "y", sketchIDs: [sketch.id])).isEmpty, "Nor from a deleted page")
    }

    func testBehaviorArrangeKeepsValidSketchPlacementsAndPlacesARelevantOneByTime() {
        var (meeting, _) = meeting([("a", 10, true), ("b", 305, true)])
        let drawn = meeting.pages![0].passages[1]
        meeting.pages![0].sketches![1] = analysis(drawn, caption: "Catering timeline", text: "Catering arrives Friday morning")
        let sketches = NotebookPlacement.candidates(in: meeting)
        let stray = UUID()
        let summary = MeetingSummary(overview: "x", sections: [
            SummarySection(heading: "Layout", body: "The hall layout and the stage.", sketchIDs: [sketches[0].id, stray, sketches[0].id]),
            SummarySection(heading: "Catering", body: "Catering arrives Friday morning.")])
        let arranged = NotebookPlacement.arrange(summary, in: meeting)
        XCTAssertEqual(arranged.sections[0].sketchIDs, [sketches[0].id], "A made-up ID and a repeat are dropped")
        XCTAssertEqual(arranged.sections[1].sketchIDs, [sketches[1].id], "The second was drawn while catering was discussed: placed by time")
    }

    func testBehaviorSketchIDsRoundTripAndOlderSummariesDecodeWithoutThem() throws {
        let id = UUID()
        let section = SummarySection(heading: "H", body: "B", photoIDs: [UUID()], sketchIDs: [id])
        let decoded = try JSONDecoder().decode(SummarySection.self, from: JSONEncoder().encode(section))
        XCTAssertEqual(decoded.sketchIDs, [id])
        XCTAssertEqual(decoded, section)
        let older = #"{"id":"\#(UUID().uuidString)","heading":"H","body":"B"}"#
        XCTAssertNil(try JSONDecoder().decode(SummarySection.self, from: Data(older.utf8)).sketchIDs)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(SummarySection(heading: "H", body: "B")), as: UTF8.self).contains("sketchIDs"),
                       "None written for none")
        let evidence = PhotoEvidence(id: id, label: "S1", isSketch: true, page: 2)
        XCTAssertEqual(try JSONDecoder().decode(PhotoEvidence.self, from: JSONEncoder().encode(evidence)), evidence)
        let photo = #"{"id":"\#(id.uuidString)","label":"P1","labels":[]}"#
        XCTAssertFalse(try JSONDecoder().decode(PhotoEvidence.self, from: Data(photo.utf8)).isSketch, "Old evidence is a photo")
    }
}
