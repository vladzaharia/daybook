#if os(macOS) && canImport(PencilKit)
import CoreGraphics
import DaybookCore
import Foundation
import PencilKit
import AppKit

/// A notebook page as a picture, for reading one on a Mac: the paper, then the strokes, always on light paper (a page is paper:
/// the colours written on it are the colours shown in Dark Mode too). Made off the main actor and kept per drawing and size.
/// The iPhone's notebook draws the same paper under its canvas (`PagePaperView`); the Mac only reads.
final class NotebookPageImages: @unchecked Sendable {
    static let shared = NotebookPageImages()
    private let cache = NSCache<NSString, Box>()
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }

    static let sheet = CGColor(srgbRed: 0.992, green: 0.988, blue: 0.976, alpha: 1)
    static let rule = CGColor(srgbRed: 0.62, green: 0.70, blue: 0.82, alpha: 0.38)
    static let margin = CGColor(srgbRed: 0.86, green: 0.45, blue: 0.45, alpha: 0.28)

    static func key(_ page: NotebookPage, maxPixels: Int) -> String { "\(page.id.uuidString)#\(page.drawing?.sha256 ?? "blank")#\(page.paper.rawValue)#\(maxPixels)" }

    func cached(_ page: NotebookPage, maxPixels: Int) -> CGImage? { cache.object(forKey: Self.key(page, maxPixels: maxPixels) as NSString)?.image }

    /// The page with the drawing in the file at `url` (nil: the paper alone); nil when the file isn't readable.
    func image(of page: NotebookPage, file url: URL?, maxPixels: Int) async -> CGImage? {
        if let hit = cached(page, maxPixels: maxPixels) { return hit }
        let made = await detachedWork(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            var drawing: PKDrawing?
            if let url {
                guard let data = try? Data(contentsOf: url), let read = try? PKDrawing(data: data) else { return nil }
                drawing = read
            }
            return Self.render(page, drawing: drawing, maxPixels: maxPixels)
        }
        if let made { cache.setObject(Box(made), forKey: Self.key(page, maxPixels: maxPixels) as NSString) }
        return made
    }

    /// The page's paper and strokes, at most `maxPixels` on the longer side (and no more than 3x the page's points).
    nonisolated static func render(_ page: NotebookPage, drawing: PKDrawing?, maxPixels: Int) -> CGImage? {
        guard page.width > 0, page.height > 0 else { return nil }
        let size = CGSize(width: page.width, height: page.height)
        let scale = min(3, CGFloat(maxPixels) / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(sheet)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if page.paper == .ruled {
            context.saveGState()
            // Page points, top left, downwards.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.setLineWidth(1)
            context.setStrokeColor(rule)
            var y = NotebookPage.ruleSpacing * 2
            while y < size.height - NotebookPage.ruleSpacing / 2 {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: size.width, y: y))
                y += NotebookPage.ruleSpacing
            }
            context.strokePath()
            context.setStrokeColor(margin)
            context.move(to: CGPoint(x: 52, y: 0))
            context.addLine(to: CGPoint(x: 52, y: size.height))
            context.strokePath()
            context.restoreGState()
        }
        if let drawing, !drawing.strokes.isEmpty {
            let rect = CGRect(origin: .zero, size: size)
            var inked: CGImage?
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                inked = drawing.image(from: rect, scale: scale).cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            if let inked { context.draw(inked, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        }
        return context.makeImage()
    }
}
#endif
