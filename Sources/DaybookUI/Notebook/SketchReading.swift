#if canImport(PencilKit)
import DaybookCore
import DaybookKit
import Foundation
import ImageIO
import PencilKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Getting sketch passages ready to be read (docs/notebook.md, "Sketches"): each one's strokes alone, drawn dark on light paper
/// whatever the appearance (`image(of:)`, the same on the iPhone and the Mac), written to a private folder the caller deletes after reading. The reading
/// itself is the engine's (`ProcessingEngine.describeSketches`), on the device like a photo's; nothing here leaves it.
public enum SketchReading {
    /// A PNG of one passage's strokes on light paper; nil when the drawing no longer has them.
    @MainActor
    public static func picture(of passage: NotebookPassage, on page: NotebookPage, in drawing: PKDrawing) -> Data? {
        let strokes = NotebookReader.strokes(of: drawing)
        guard let group = PassageGrouping.group(strokes, page: page.id).first(where: { $0.id == passage.id }) else { return nil }
        let keys = Set(group.strokes.map(\.key))
        let drawn = zip(drawing.strokes, strokes.map(\.key)).filter { keys.contains($0.1) }.map(\.0)
        guard !drawn.isEmpty, let image = image(of: PKDrawing(strokes: drawn)) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Dark ink on opaque white, at most 3x and 2048 pixels across, with 16 points of margin: one picture on both platforms.
    @MainActor
    static func image(of drawing: PKDrawing) -> CGImage? {
        #if os(iOS)
        return InkRecognizer.image(of: drawing)
        #else
        guard !drawing.bounds.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        let scale = min(3, 2048 / max(bounds.width, bounds.height))
        var ink: NSImage?
        // Light appearance: in Dark Mode a drawing would otherwise paint white ink onto the white paper.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { ink = drawing.image(from: bounds, scale: scale) }
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard let strokes = ink?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(strokes, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
        #endif
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
