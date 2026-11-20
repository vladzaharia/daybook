#if canImport(PencilKit)
import CoreGraphics
import DaybookCore
import DaybookDesign
import DaybookKit
import Foundation
import PencilKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A sketch a summary section drew on, ready to show: where its page's strokes are kept and what it is called.
struct SummarySketch: Identifiable, Equatable {
    var id: UUID { passage.id }
    let passage: NotebookPassage
    let pageID: UUID
    /// The page's drawing file; nil for a page with none.
    let drawing: PageDrawing?
    /// What VoiceOver says: the reading's description, else "Sketch".
    let label: String

    /// The section's sketches in its order. Sketches on a page that is deleted or left out of summaries, and ones this version of
    /// the conversation doesn't have, aren't here (`Meeting.sketches(in:)`).
    static func items(in meeting: Meeting, section: SummarySection) -> [SummarySketch] {
        meeting.sketches(in: section).map { page, passage in
            let described = page.sketch(for: passage)?.analysis.caption.flatMap { $0.isEmpty ? nil : $0 }
            return SummarySketch(passage: passage, pageID: page.id, drawing: page.drawing, label: described.map { "Sketch: \($0)" } ?? "Sketch")
        }
    }
}

/// Small pictures of sketch passages for the summary: the passage's strokes alone, dark on light paper whatever the appearance,
/// made off the main actor and kept per passage and stroke digest. (`SketchReading.picture` makes the iPhone's full-size one for
/// reading; the two should be one renderer.)
final class SketchThumbnails: @unchecked Sendable {
    static let shared = SketchThumbnails()
    private let cache = NSCache<NSString, Box>()
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }

    /// Light paper, the colour notebook pages are.
    static let paper = CGColor(srgbRed: 0xFD / 255, green: 0xFC / 255, blue: 0xFA / 255, alpha: 1)

    static func key(_ passage: NotebookPassage, maxPixels: Int) -> String { "\(passage.id.uuidString)#\(passage.strokeDigest)#\(maxPixels)" }

    func cached(_ passage: NotebookPassage, maxPixels: Int) -> CGImage? { cache.object(forKey: Self.key(passage, maxPixels: maxPixels) as NSString)?.image }

    /// The picture of `passage` in the drawing file at `url`; nil when the file or the passage's strokes aren't readable.
    func image(of passage: NotebookPassage, page: UUID, file url: URL, maxPixels: Int) async -> CGImage? {
        if let hit = cached(passage, maxPixels: maxPixels) { return hit }
        let made = await detachedWork(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled, let data = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: data) else { return nil }
            return Self.render(passage, page: page, in: drawing, maxPixels: maxPixels)
        }
        if let made { cache.setObject(Box(made), forKey: Self.key(passage, maxPixels: maxPixels) as NSString) }
        return made
    }

    /// The passage's strokes on light paper, at most `maxPixels` on the longer side.
    nonisolated static func render(_ passage: NotebookPassage, page: UUID, in drawing: PKDrawing, maxPixels: Int) -> CGImage? {
        let strokes = NotebookReader.strokes(of: drawing)
        guard let group = PassageGrouping.group(strokes, page: page).first(where: { $0.id == passage.id }) else { return nil }
        let keys = Set(group.strokes.map(\.key))
        let drawn = zip(drawing.strokes, strokes.map(\.key)).filter { keys.contains($0.1) }.map(\.0)
        let ink = PKDrawing(strokes: drawn)
        guard !drawn.isEmpty, !ink.bounds.isEmpty else { return nil }
        let bounds = ink.bounds.insetBy(dx: -12, dy: -12)
        let scale = min(3, CGFloat(maxPixels) / max(bounds.width, bounds.height))
        var inked: CGImage?
        #if canImport(UIKit)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { inked = ink.image(from: bounds, scale: scale).cgImage }
        #else
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            inked = ink.image(from: bounds, scale: scale).cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        #endif
        guard let inked else { return nil }
        let size = (width: max(1, Int((bounds.width * scale).rounded())), height: max(1, Int((bounds.height * scale).rounded())))
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(paper)
        context.fill(rect)
        context.draw(inked, in: rect)
        return context.makeImage()
    }
}

/// The sketches a summary section drew on, under its text and beside its photos: each a small picture of its strokes on light
/// paper, in a tile shaped like a photo's. A tap opens it larger. A drawing that isn't on this device shows the quiet
/// placeholder a photo does; a section with none shows nothing.
public struct SectionSketches: View {
    private let meeting: Meeting
    private let sketches: [SummarySketch]
    private let library: LibraryController
    @State private var opened: SummarySketch?
    @Environment(\.readingScale) private var scale
    @Environment(\.daybookDensity) private var density

    public init(meeting: Meeting, section: SummarySection, library: LibraryController) {
        self.meeting = meeting
        self.sketches = SummarySketch.items(in: meeting, section: section)
        self.library = library
    }

    public var body: some View {
        if !sketches.isEmpty {
            PageBlock {
                let across = density == .touch || sketches.count == 1 ? 1 : 2
                let columns = Array(repeating: GridItem(.flexible(), spacing: DaybookSpacing.s3, alignment: .top), count: across)
                LazyVGrid(columns: columns, alignment: .leading, spacing: DaybookSpacing.s3) {
                    ForEach(sketches) { sketch in
                        Button { opened = sketch } label: { SketchPicture(sketch: sketch, meetingID: meeting.id, library: library, maxPixels: 1280) }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(sketch.label)
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .frame(maxWidth: density != .touch && sketches.count == 1 ? 480 * scale : .infinity, alignment: .leading)
            }
            .padding(.top, DaybookSpacing.s3)
            .sheet(item: $opened) { sketch in SketchSheet(sketch: sketch, meetingID: meeting.id, library: library) }
        }
    }
}

/// One sketch's picture, in the photo tile's shape and corners.
struct SketchPicture: View {
    let sketch: SummarySketch
    let meetingID: UUID
    let library: LibraryController
    let maxPixels: Int
    @State private var image: CGImage?

    /// Its own shape, kept between 3:4 and 2:1 so a thin line never makes a sliver of a tile.
    static func aspectRatio(_ passage: NotebookPassage) -> CGFloat {
        guard passage.width > 0, passage.height > 0 else { return 4.0 / 3 }
        return min(2, max(0.75, CGFloat(passage.width / passage.height)))
    }

    var body: some View {
        Color.clear
            .aspectRatio(Self.aspectRatio(sketch.passage), contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(DaybookPalette.quietFill)
                        .overlay { Image(systemName: "scribble").foregroundStyle(DaybookPalette.Ink.faint).accessibilityHidden(true) }
                }
            }
            .background(Color(cgColor: SketchThumbnails.paper))
            .clipShape(DaybookRadius.shape(DaybookRadius.row))
            .overlay(DaybookRadius.shape(DaybookRadius.row).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Rectangle())
            .task(id: "\(SketchThumbnails.key(sketch.passage, maxPixels: maxPixels)):\(sketch.drawing?.sha256 ?? "")") { await load() }
    }

    private func load() async {
        if let hit = SketchThumbnails.shared.cached(sketch.passage, maxPixels: maxPixels) { image = hit; return }
        image = nil
        guard let drawing = sketch.drawing, library.hasLocalPageDrawing(drawing, in: meetingID),
              let url = try? await library.pageDrawingURL(for: drawing, in: meetingID) else { return }
        let made = await SketchThumbnails.shared.image(of: sketch.passage, page: sketch.pageID, file: url, maxPixels: maxPixels)
        guard !Task.isCancelled else { return }
        image = made
    }
}

/// A sketch larger, over the page.
private struct SketchSheet: View {
    let sketch: SummarySketch
    let meetingID: UUID
    let library: LibraryController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: DaybookSpacing.s3) {
            SketchPicture(sketch: sketch, meetingID: meetingID, library: library, maxPixels: 2048)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(sketch.label)
            Button("Done") { dismiss() }
                .buttonStyle(.daybookLink)
                .keyboardShortcut(.cancelAction)
                .daybookHitTarget()
        }
        .padding(DaybookSpacing.s4)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
        .presentationDetents([.large])
    }
}
#endif
