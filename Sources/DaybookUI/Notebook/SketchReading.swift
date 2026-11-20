#if os(iOS)
import DaybookCore
import DaybookKit
import Foundation
import PencilKit
import UIKit

/// Getting sketch passages ready to be read (docs/notebook.md, "Sketches"): each one's strokes alone, drawn dark on light paper
/// whatever the appearance (`InkRecognizer.image`), written to a private folder the caller deletes after reading. The reading
/// itself is the engine's (`ProcessingEngine.describeSketches`), on the device like a photo's; nothing here leaves it.
public enum SketchReading {
    /// A PNG of one passage's strokes on light paper; nil when the drawing no longer has them.
    @MainActor
    public static func picture(of passage: NotebookPassage, on page: NotebookPage, in drawing: PKDrawing) -> Data? {
        let strokes = NotebookReader.strokes(of: drawing)
        guard let group = PassageGrouping.group(strokes, page: page.id).first(where: { $0.id == passage.id }) else { return nil }
        let keys = Set(group.strokes.map(\.key))
        let drawn = zip(drawing.strokes, strokes.map(\.key)).filter { keys.contains($0.1) }.map(\.0)
        guard !drawn.isEmpty, let image = InkRecognizer.image(of: PKDrawing(strokes: drawn)) else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    /// What there is to read in `meeting`: its sketch passages with no reading of their current strokes, as files in `folder`.
    /// `drawingFile` gives a page drawing's file on this device (nil when it isn't here).
    @MainActor
    public static func inputs(for meeting: Meeting, in folder: URL, drawingFile: (PageDrawing) async -> URL?) async -> [SketchProcessingInput] {
        var inputs: [SketchProcessingInput] = []
        var drawings: [UUID: PKDrawing] = [:]
        for (page, passage) in meeting.sketchesNeedingReading {
            if drawings[page.id] == nil, let stored = page.drawing, let url = await drawingFile(stored),
               let data = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: data) { drawings[page.id] = drawing }
            guard let drawing = drawings[page.id], let png = picture(of: passage, on: page, in: drawing) else { continue }
            let file = folder.appendingPathComponent("\(passage.id.uuidString).png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: file, options: .atomic)
            } catch { continue }
            inputs.append(SketchProcessingInput(passageID: passage.id, strokeDigest: passage.strokeDigest, url: file))
        }
        return inputs
    }
}
#endif
