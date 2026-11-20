#if DEBUG && canImport(PencilKit)
import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookTestSupport
import DaybookUI
import Foundation
import PencilKit
import XCTest
@testable import Daybook

/// The Mac describes a notebook page's sketches before it summarizes, as the iPhone does, from the drawing in its own library.
@MainActor
final class MacSketchReadingTests: XCTestCase {
    private final class Describer: ProcessingEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[SketchProcessingInput]] = []
        var calls: [[SketchProcessingInput]] { lock.withLock { _calls } }
        func transcribe(_ input: TrackProcessingInput, progress: @escaping ProcessingProgressHandler) async throws -> TrackProcessingOutput {
            throw AppError.noSpeech
        }
        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                       progress: @escaping ProcessingProgressHandler) async throws -> SummaryProcessingOutput {
            SummaryProcessingOutput(summary: MeetingSummary(overview: ""))
        }
        func describeSketches(_ sketches: [SketchProcessingInput], progress: @escaping ProcessingProgressHandler) async throws -> [UUID: SketchAnalysis] {
            lock.withLock { _calls.append(sketches) }
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            return Dictionary(uniqueKeysWithValues: sketches.map { input in
                (input.passageID, SketchAnalysis(passageID: input.passageID, strokeDigest: input.strokeDigest,
                                                 analysis: PhotoAnalysis(caption: "A house", labels: ["house"], isInformative: true,
                                                                         settings: ProcessingSettings(modelID: "apple-vision/system", createdAt: now), createdAt: now)))
            })
        }
    }

    /// A conversation with one page whose strokes are a sketch, committed to the library and read into a passage.
    private func rig(_ rig: MultiSourceRig) async throws -> (id: UUID, page: UUID, file: URL) {
        let id = rig.state.newMeeting(title: "Sketch")
        let library = rig.state.library
        let page = NotebookPage(order: 1)
        library.addPage(page, to: id)
        let drawing = SyntheticInk.sketch(origin: CGPoint(x: 80, y: 200), start: Date(timeIntervalSinceReferenceDate: 700_000_000))
        let stored = try await library.commitPageDrawing(drawing.dataRepresentation(), page: page.id, in: id, strokeCount: drawing.strokes.count,
                                                         contentVersion: 1, device: "Alex's iPhone")
        let reading = await NotebookReader.read(drawing, sha256: stored.sha256, page: page) { _ in (nil, nil) }
        library.applyPageReading(reading, to: page.id, in: id)
        return (id, page.id, library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(stored.relativePath)"))
    }

    func testBehaviorTheMacDescribesASketchAndKeepsTheReadingWithTheCurrentStrokeDigest() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let (id, pageID, _) = try await self.rig(rig)
        let passage = try XCTUnwrap(rig.meeting(id)?.sketchesNeedingReading.first?.passage)
        let describer = Describer()

        let read = try await rig.state.readSketches(id, engine: describer, progress: { _ in })

        XCTAssertEqual(read, 1)
        let sketch = try XCTUnwrap(rig.meeting(id)?.page(pageID)?.sketch(for: passage))
        XCTAssertEqual(sketch.strokeDigest, passage.strokeDigest)
        XCTAssertEqual(sketch.analysis.caption, "A house")
        XCTAssertEqual(describer.calls.count, 1)
        let sent = try XCTUnwrap(describer.calls.first?.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sent.url.path), "The picture is deleted after")
        // Read once: nothing left to read, so the engine is not asked again.
        let again = try await rig.state.readSketches(id, engine: describer, progress: { _ in })
        XCTAssertEqual(again, 0)
        XCTAssertEqual(describer.calls.count, 1)
    }

    func testBehaviorAPageWhoseDrawingIsNotOnThisMacYetIsSkippedAndReadOnceItArrives() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let (id, pageID, file) = try await self.rig(rig)
        let held = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        let describer = Describer()

        let skipped = try await rig.state.readSketches(id, engine: describer, progress: { _ in })
        XCTAssertEqual(skipped, 0)
        XCTAssertTrue(describer.calls.isEmpty, "Not failed, not asked")
        XCTAssertNil(rig.meeting(id)?.page(pageID)?.sketches)

        try held.write(to: file)
        let arrived = try await rig.state.readSketches(id, engine: describer, progress: { _ in })
        XCTAssertEqual(arrived, 1)
        XCTAssertEqual(rig.meeting(id)?.page(pageID)?.sketches?.count, 1)
    }
}
#endif
