#if os(macOS) && canImport(PencilKit) && DEBUG
import DaybookCore
import PencilKit
import XCTest

@testable import DaybookUI

/// A notebook page as the Mac shows it: its own shape, light paper, the strokes on it.
final class NotebookPageImagesTests: XCTestCase {
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        [UInt8](try XCTUnwrap(image.dataProvider?.data as Data?))
    }

    private func darkCount(_ image: CGImage) throws -> Int {
        let bytes = try pixels(image)
        return stride(from: 0, to: bytes.count - 3, by: 4).filter { bytes[$0 + 3] == 255 && bytes[$0] < 90 && bytes[$0 + 1] < 90 && bytes[$0 + 2] < 90 }.count
    }

    func testBehaviorAPageKeepsItsShapeAndItsPaperIsLight() throws {
        let page = NotebookPage(order: 1, paper: .plain)
        let image = try XCTUnwrap(NotebookPageImages.render(page, drawing: nil, maxPixels: 595))
        XCTAssertEqual(Double(image.width) / Double(image.height), 420.0 / 595.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 595)
        XCTAssertEqual(try darkCount(image), 0, "paper alone has no dark marks")
    }

    func testBehaviorStrokesAreDrawnDarkOnThePage() throws {
        let page = NotebookPage(order: 1, paper: .ruled)
        let blank = try XCTUnwrap(NotebookPageImages.render(page, drawing: nil, maxPixels: 840))
        let written = try XCTUnwrap(NotebookPageImages.render(page, drawing: SyntheticInk.drawing("hello"), maxPixels: 840))
        XCTAssertEqual(try darkCount(blank), 0, "the rules are faint")
        XCTAssertGreaterThan(try darkCount(written), 200, "the ink shows")
    }

    func testBehaviorRuledPaperHasRulesAndPlainHasNone() throws {
        let ruled = try XCTUnwrap(NotebookPageImages.render(NotebookPage(order: 1, paper: .ruled), drawing: nil, maxPixels: 595))
        let plain = try XCTUnwrap(NotebookPageImages.render(NotebookPage(order: 1, paper: .plain), drawing: nil, maxPixels: 595))
        XCTAssertNotEqual(try pixels(ruled), try pixels(plain))
    }

    func testBehaviorImagesAreKeptPerDrawingAndSize() async throws {
        var page = NotebookPage(order: 1)
        page.drawing = PageDrawing(relativePath: "p", sha256: "abc", byteCount: 1, strokeCount: 1, editedAt: Date())
        XCTAssertNil(NotebookPageImages.shared.cached(page, maxPixels: 300))
        let made = await NotebookPageImages.shared.image(of: page, file: nil, maxPixels: 300)
        XCTAssertNotNil(made)
        XCTAssertNotNil(NotebookPageImages.shared.cached(page, maxPixels: 300))
        XCTAssertNil(NotebookPageImages.shared.cached(page, maxPixels: 600), "another size is another picture")
    }

    func testBehaviorWordsMatchTheNotebooksOwn() {
        XCTAssertEqual(NotebookPagesWords.summaryChoice(leftOut: false), "Leave Out of Summaries")
        XCTAssertEqual(NotebookPagesWords.summaryChoice(leftOut: true), "Include in Summaries")
        XCTAssertEqual(NotebookPagesWords.label(2, leftOut: true), "Page 2, left out of summaries")
        XCTAssertEqual(NotebookPagesWords.position(2, of: 3), "Page 2 of 3")
    }
}
#endif
