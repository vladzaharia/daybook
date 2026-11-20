#if canImport(PencilKit) && DEBUG
import CoreGraphics
import DaybookCore
import DaybookKit
import PencilKit
import XCTest

@testable import DaybookUI

/// Getting sketch passages ready to read, on the Mac as on the iPhone: the passage's strokes alone, dark on light paper.
@MainActor
final class SketchReadingTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 700_000_000)

    /// A page of words and, far below, a sketch, read into passages (the sketch's by grouping alone).
    private func page(_ drawing: PKDrawing) async -> NotebookPage {
        var page = NotebookPage(order: 1)
        let reading = await NotebookReader.read(drawing, sha256: "abc", page: page) { _ in (nil, nil) }
        page.reading = reading
        page.drawing = PageDrawing(relativePath: "Originals/Pages/\(page.id.uuidString)-abc.pkdrawing", sha256: "abc", byteCount: 10,
                                   strokeCount: drawing.strokes.count, editedAt: start, contentVersion: 1)
        return page
    }

    private func pixels(_ data: Data) throws -> (width: Int, height: Int, dark: Int, light: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var dark = 0, light = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[index] < 100 && bytes[index + 1] < 100 { dark += 1 } else if bytes[index] > 240 && bytes[index + 1] > 240 { light += 1 }
        }
        return (image.width, image.height, dark, light)
    }

    func testBehaviorASketchsPictureIsItsStrokesAloneDarkOnLightPaper() async throws {
        let drawing = SyntheticInk.page(passages: [.init(.words("hello"), at: CGPoint(x: 60, y: 80), size: 34, after: 0),
                                                   .init(.sketch, at: CGPoint(x: 80, y: 600), size: 120, after: 30)], start: start)
        let page = await page(drawing)
        let sketch = try XCTUnwrap(page.passages.first { $0.y > 400 })
        let picture = try XCTUnwrap(SketchReading.picture(of: sketch, on: page, in: drawing))
        let found = try pixels(picture)
        XCTAssertGreaterThan(found.dark, 200, "The strokes are drawn")
        XCTAssertGreaterThan(found.light, found.dark, "On paper")
        // Sized by the passage's strokes with a margin, not the page: the words 500 points above are not in it.
        let strokes = NotebookReader.strokes(of: drawing).filter { $0.y > 400 }
        let box = strokes.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
        XCTAssertLessThan(Double(found.height), (box.height + 80) * 3.5)
        XCTAssertLessThanOrEqual(max(found.width, found.height), 2048 + 1)
        // The same drawing of the words alone is a different picture.
        let words = try XCTUnwrap(page.passages.first { $0.y < 400 })
        XCTAssertNotEqual(SketchReading.picture(of: words, on: page, in: drawing), picture)
    }

    func testBehaviorAPassageTheDrawingNoLongerHasHasNoPicture() async throws {
        let drawing = SyntheticInk.sketch(origin: CGPoint(x: 80, y: 200), start: start)
        let page = await page(drawing)
        let passage = try XCTUnwrap(page.passages.first)
        XCTAssertNil(SketchReading.picture(of: passage, on: page, in: PKDrawing()))
    }

    func testBehaviorAPageWhoseDrawingIsNotHereIsSkippedAndTheOthersAreWritten() async throws {
        let drawing = SyntheticInk.sketch(origin: CGPoint(x: 80, y: 200), start: start)
        let here = await page(drawing), away = await page(drawing)
        var meeting = Meeting(title: "Sketches")
        meeting.pages = [here, away]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sketches-\(UUID().uuidString)", isDirectory: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pkdrawing")
        try drawing.dataRepresentation().write(to: file)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: file) }
        let drawingHere = try XCTUnwrap(here.drawing)
        let inputs = await SketchReading.inputs(for: meeting, in: folder) { stored in stored == drawingHere ? file : nil }
        XCTAssertEqual(inputs.map(\.passageID), [here.passages[0].id], "The page with no drawing here is skipped, not failed")
        XCTAssertEqual(inputs.map(\.strokeDigest), [here.passages[0].strokeDigest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputs[0].url.path))
    }
}
#endif
