import DaybookCore
import DaybookKit
import DaybookUI
import Foundation

extension AppState {
    /// Reads the conversation's sketch passages that have no reading of their strokes, as the iPhone does before it summarizes
    /// (docs/notebook.md, "Sketches"): each one's strokes alone on light paper, described on this Mac like a photo. A page whose
    /// drawing isn't on this Mac yet is skipped, not failed: its sketch is read once the drawing arrives, and the summary is then
    /// out of date (`Meeting.summaryNotebookChanged`). A sketch that can't be read is left for the next summary. The pictures are
    /// deleted after; neither they nor what was read from them go to a cloud model. Returns how many were read.
    @discardableResult
    func readSketches(_ id: UUID, engine: any ProcessingEngine, progress: @escaping ProcessingProgressHandler) async throws -> Int {
        guard let meeting = meetings.first(where: { $0.id == id }), !meeting.sketchesNeedingReading.isEmpty else { return 0 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Daybook Sketches \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inputs = await SketchReading.inputs(for: meeting, in: folder) { [library] drawing in
            library.hasLocalPageDrawing(drawing, in: id) ? try? await library.pageDrawingURL(for: drawing, in: id) : nil
        }
        guard !inputs.isEmpty else { return 0 }
        let read: [UUID: SketchAnalysis]
        do { read = try await engine.describeSketches(inputs, progress: progress) }
        catch is CancellationError { throw CancellationError() }
        catch { return 0 }
        try Task.checkCancellation()
        guard !read.isEmpty else { return 0 }
        update(id) { $0.applySketchAnalyses(read) }
        return read.count
    }
}
