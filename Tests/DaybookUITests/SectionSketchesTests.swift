#if canImport(PencilKit) && DEBUG
import DaybookCore
import PencilKit
import XCTest

@testable import DaybookUI

/// The sketches a summary section shows: which ones, in what order, and their small pictures.
@MainActor
final class SectionSketchesTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func drawn() async -> (page: NotebookPage, drawing: PKDrawing) {
        let drawing = SyntheticInk.page(passages: [
            .init(.sketch, at: CGPoint(x: 40, y: 80), size: 120, after: 0),
            .init(.sketch, at: CGPoint(x: 40, y: 380), size: 100, after: 60),
        ], start: start)
        var page = NotebookPage(order: 1)
        page.reading = await NotebookReader.read(drawing, sha256: "abc", page: page) { _ in (nil, nil) }
        page.drawing = PageDrawing(relativePath: "p.drawing", sha256: "abc", byteCount: 1, strokeCount: drawing.strokes.count, editedAt: start)
        return (page, drawing)
    }

    private func meeting(_ page: NotebookPage) -> Meeting {
        var meeting = Meeting(title: "Layout")
        meeting.pages = [page]
        return meeting
    }

    func testBehaviorSectionSketchesKeepTheSectionsOrderAndLeaveOutGonePages() async throws {
        var (page, _) = await drawn()
        let ids = page.passages.map(\.id)
        XCTAssertEqual(ids.count, 2)
        let section = SummarySection(heading: "Hall", body: "x", sketchIDs: [ids[1], ids[0], UUID()])
        var conversation = meeting(page)
        XCTAssertEqual(SummarySketch.items(in: conversation, section: section).map(\.id), [ids[1], ids[0]], "the section's order; an unknown one is not shown")
        XCTAssertTrue(SummarySketch.items(in: conversation, section: SummarySection(heading: "x", body: "y")).isEmpty, "no sketches, no row")
        conversation.setPageHiddenFromSummary(page.id, hidden: true)
        XCTAssertTrue(SummarySketch.items(in: conversation, section: section).isEmpty, "left out of summaries")
        conversation.setPageHiddenFromSummary(page.id, hidden: false)
        conversation.removePage(page.id)
        XCTAssertTrue(SummarySketch.items(in: conversation, section: section).isEmpty, "deleted")
        page.drawing = nil
        XCTAssertNil(SummarySketch.items(in: meeting(page), section: section).first?.drawing, "no drawing file: the placeholder")
    }

    func testBehaviorTheLabelIsTheReadingsDescriptionWhileItsStrokesStand() async throws {
        var (page, _) = await drawn()
        let passage = page.passages[0]
        let settings = ProcessingSettings(modelID: "apple-vision/system", createdAt: start)
        let reading = { (digest: String) in
            SketchAnalysis(passageID: passage.id, strokeDigest: digest, analysis: PhotoAnalysis(caption: "Floor plan", recognizedText: nil, labels: nil, isInformative: true, settings: settings, createdAt: self.start))
        }
        let section = SummarySection(heading: "Hall", body: "x", sketchIDs: [passage.id])
        XCTAssertEqual(SummarySketch.items(in: meeting(page), section: section).first?.label, "Sketch")
        page.sketches = [reading(passage.strokeDigest)]
        XCTAssertEqual(SummarySketch.items(in: meeting(page), section: section).first?.label, "Sketch: Floor plan")
        page.sketches = [reading("other")]
        XCTAssertEqual(SummarySketch.items(in: meeting(page), section: section).first?.label, "Sketch", "a reading of other strokes isn't this sketch's")
    }

    func testBehaviorThumbnailIsNotBlankAndOnLightPaper() async throws {
        let (page, drawing) = await drawn()
        let image = try XCTUnwrap(SketchThumbnails.render(page.passages[0], page: page.id, in: drawing, maxPixels: 300))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 300)
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let pixels = [UInt8](data)
        var dark = 0, light = 0
        for index in stride(from: 0, to: pixels.count - 3, by: 4) {
            if pixels[index] < 100 { dark += 1 } else if pixels[index] > 230 { light += 1 }
        }
        XCTAssertGreaterThan(dark, 20, "the strokes are drawn")
        XCTAssertGreaterThan(light, dark, "on light paper")
    }

    func testBehaviorThumbnailsAreKeptPerPassageAndStrokeDigest() async throws {
        let (page, drawing) = await drawn()
        let passage = page.passages[0]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).drawing")
        try drawing.dataRepresentation().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = SketchThumbnails()
        XCTAssertNil(cache.cached(passage, maxPixels: 200))
        let made = await cache.image(of: passage, page: page.id, file: file, maxPixels: 200)
        XCTAssertNotNil(made)
        XCTAssertNotNil(cache.cached(passage, maxPixels: 200))
        var changed = passage
        changed.strokeDigest = "other"
        XCTAssertNil(cache.cached(changed, maxPixels: 200), "other strokes are another picture")
        XCTAssertNil(cache.cached(passage, maxPixels: 400), "as is another size")
        let missing = await cache.image(of: passage, page: page.id, file: file.appendingPathExtension("gone"), maxPixels: 100)
        XCTAssertNil(missing, "a file that isn't here is a placeholder, not an error")
    }
}
#endif
