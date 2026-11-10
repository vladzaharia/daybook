#if os(iOS)
import DaybookCore
import DaybookDesign
import Observation
import PencilKit
import SwiftUI
import UIKit
import Vision

// Handwriting in the iPhone's notes editor (docs/iphone.md, "Handwriting"). Ink sits in the column between typed
// paragraphs, as one attachment each, so it moves with the text and stays whole when the Duo folds. The strokes are
// live PencilKit canvases laid over the attachments' rects; below the last paragraph, a canvas with nothing in it
// waits for the next stroke, so Apple Pencil can start writing anywhere past the words with no mode to enter.

/// What the editor needs from whoever keeps the notes.
public struct NotesInkModel {
    public var session: InkSession
    /// The ink in each nonempty paragraph of the notes, in order (`NoteTimeline.inkPlacements`).
    public var placements: [NoteInk?]
    /// A new block, as a new paragraph after the nonempty paragraph at the index, or at the end when nil.
    public var add: (NoteInk, Int?) -> Void
    /// New strokes, size, or words for a block.
    public var update: (NoteInk) -> Void
    /// Takes a block out, leaving its words as a typed paragraph when `keepingWords`. Returns what puts it back.
    public var remove: (_ id: UUID, _ keepingWords: Bool) -> (() -> Void)?

    public init(session: InkSession, placements: [NoteInk?], add: @escaping (NoteInk, Int?) -> Void, update: @escaping (NoteInk) -> Void,
                remove: @escaping (UUID, Bool) -> (() -> Void)?) {
        self.session = session
        self.placements = placements
        self.add = add
        self.update = update
        self.remove = remove
    }
}

/// How the editor is being written with, shared by its canvases and its tools.
@MainActor
@Observable
public final class InkSession {
    public enum Tool: String, CaseIterable, Identifiable, Sendable {
        case pen, marker, eraser, lasso
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .pen: return "Pen"
            case .marker: return "Highlighter"
            case .eraser: return "Eraser"
            case .lasso: return "Lasso"
            }
        }

        public var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .marker: return "highlighter"
            case .eraser: return "eraser"
            case .lasso: return "lasso"
            }
        }

        var pencilTool: PKTool {
            switch self {
            // Stored as black and drawn in the appearance's ink: PencilKit turns it light in Dark Mode.
            case .pen: return PKInkingTool(.pen, color: .black, width: 2.4)
            case .marker: return PKInkingTool(.marker, color: .systemYellow, width: 22)
            case .eraser: return PKEraserTool(.vector)
            case .lasso: return PKLassoTool()
            }
        }
    }

    /// A finger writes on the page and the keyboard is put away. Apple Pencil writes without this.
    public var isWriting = false { didSet { if isWriting != oldValue { changed() } } }
    /// Apple Pencil wrote since the words last had the focus, so the tools stay in reach.
    public var pencilActive = false { didSet { if pencilActive != oldValue { changed() } } }
    public var tool: Tool = .pen { didSet { if tool != oldValue { changed() } } }
    public private(set) var canUndo = false
    public private(set) var canRedo = false

    /// Whether the tools show.
    public var showsTools: Bool { isWriting || pencilActive }

    @ObservationIgnored var onChange: (() -> Void)?
    /// Puts the caret back in the words.
    @ObservationIgnored var focusWords: (() -> Void)?
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var previousTool: Tool = .pen

    public init() {}

    private func changed() { onChange?() }

    /// Back to typing.
    public func returnToKeyboard() {
        isWriting = false
        pencilActive = false
        focusWords?()
    }

    public func undo() {
        undoManager?.undo()
        refreshUndo()
    }

    public func redo() {
        undoManager?.redo()
        refreshUndo()
    }

    func refreshUndo() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }

    /// Double-tapping or squeezing Apple Pencil: the eraser, and back.
    func toggleEraser() {
        if tool == .eraser {
            tool = previousTool
        } else {
            previousTool = tool
            tool = .eraser
        }
    }
}

/// Reads words from ink, on this device.
public enum InkRecognizer {
    /// The words in a drawing: empty for one with none in it (a sketch), nil when nothing could read it.
    public static func text(in drawing: PKDrawing) async -> String? {
        guard !drawing.strokes.isEmpty else { return "" }
        if #available(iOS 27.0, *) {
            // One per reading: it holds one drawing, and two blocks read at once would each get the other's words.
            let recognizer = PKStrokeRecognizer()
            await recognizer.updateDrawing(drawing)
            if let words = await recognizer.recognizedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
                return words
            }
        }
        // The stroke recognizer is iOS 27 and doesn't take every language; Vision reads a picture of the ink.
        return await vision(drawing)
    }

    private static func vision(_ drawing: PKDrawing) async -> String? {
        guard let image = await image(of: drawing) else { return nil }
        return await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                return nil
            }
            return (request.results ?? [])
                .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    /// Dark ink on opaque white, whatever the phone's appearance: `PKDrawing.image` draws for the current traits, so in
    /// Dark Mode it would otherwise paint white ink onto the white ground and Vision would read nothing.
    @MainActor
    public static func image(of drawing: PKDrawing) -> CGImage? {
        guard !drawing.bounds.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        let scale = min(3, 2048 / max(bounds.width, bounds.height))
        var image: CGImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let ink = drawing.image(from: bounds, scale: scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            let rect = CGRect(origin: .zero, size: bounds.size)
            image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(rect)
                ink.draw(in: rect)
            }.cgImage
        }
        return image
    }
}

/// Holds one paragraph's place in the text and its height in the column.
final class InkAttachment: NSTextAttachment {
    let inkID: UUID
    /// The paragraph's text in the notes, written back unchanged however the ink is drawn.
    var paragraphText: String
    var inkWidth: CGFloat
    var inkHeight: CGFloat

    init(block: NoteInk, paragraphText: String) {
        inkID = block.id
        self.paragraphText = paragraphText
        inkWidth = CGFloat(block.width)
        inkHeight = CGFloat(block.height)
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The whole line's width, and the ink's height at the scale it fits the column.
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        let width = max(1, lineFrag.width)
        return CGRect(x: 0, y: 0, width: width, height: ceil(inkHeight * min(1, width / max(1, inkWidth))))
    }

    /// The canvas over it draws the strokes.
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? { nil }
}

/// A canvas over one attachment, or waiting past the last paragraph.
final class InkBlockView: UIView, PKCanvasViewDelegate {
    let id: UUID
    let canvas = PKCanvasView()
    /// The column it was written in, for a narrower column's scale.
    var authoredWidth: CGFloat
    var recognized: String?
    /// The strokes last saved, so a save coming back round doesn't reload the canvas.
    private(set) var savedDrawing = Data()
    private var isLoading = false

    /// The empty page past the last paragraph: a finger goes through it to the words, to place the caret.
    var lettingFingersThrough = false
    private var fingerDraws = false

    var began: ((InkBlockView) -> Void)?
    var changed: ((InkBlockView) -> Void)?

    init(id: UUID = UUID(), authoredWidth: CGFloat) {
        self.id = id
        self.authoredWidth = authoredWidth
        super.init(frame: .zero)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.delegate = self
        addSubview(canvas)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// How much smaller than it was written the ink draws, to fit a narrower column. Never enlarged.
    var fitScale: CGFloat { bounds.width > 0 ? min(1, bounds.width / max(1, authoredWidth)) : 1 }

    var hasInk: Bool { !canvas.drawing.strokes.isEmpty }
    /// Where the last stroke ends, in the strokes' own points.
    var inkBottom: CGFloat { hasInk ? canvas.drawing.bounds.maxY : 0 }

    func load(_ block: NoteInk) {
        authoredWidth = CGFloat(block.width)
        recognized = block.recognized
        accessibilityLabel = block.paragraphText == NoteInk.placeholder ? "Handwriting" : "Handwriting: \(block.paragraphText)"
        guard block.drawing != savedDrawing else { return }
        savedDrawing = block.drawing
        isLoading = true
        canvas.drawing = (try? PKDrawing(data: block.drawing)) ?? PKDrawing()
        isLoading = false
    }

    func markSaved(_ data: Data) { savedDrawing = data }

    /// Moves the strokes within the canvas, without it counting as writing.
    func shiftInk(byY delta: CGFloat) {
        guard abs(delta) > 0.25 else { return }
        isLoading = true
        canvas.drawing = canvas.drawing.transformed(using: CGAffineTransform(translationX: 0, y: delta))
        isLoading = false
    }

    func apply(tool: PKTool, fingerDraws: Bool, interactive: Bool) {
        canvas.tool = tool
        self.fingerDraws = fingerDraws
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        canvas.isUserInteractionEnabled = interactive
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The canvas stays the size it was written at and is drawn smaller as a whole, so nothing is cut off and the strokes
        // stay in the points they were written in. (Its own zoom scale keeps the unzoomed area, and clips the rest.)
        // Set only when different: each change asks for another layout pass.
        let scale = fitScale
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        if canvas.transform != transform { canvas.transform = transform }
        if canvas.bounds.size != size { canvas.bounds = CGRect(origin: .zero, size: size) }
        if canvas.center != center { canvas.center = center }
    }

    /// Asked before the touch is delivered: a touch known not to be Apple Pencil goes through the empty page.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard lettingFingersThrough, !fingerDraws, let touches = event?.allTouches, !touches.isEmpty else { return true }
        return touches.contains { $0.type == .pencil }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { began?(self) }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isLoading else { return }
        changed?(self)
    }
}

/// Writing tools over the notes: Pen, or the tools themselves once writing.
public struct InkTools: View {
    @Bindable private var session: InkSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(session: InkSession) {
        self.session = session
    }

    public var body: some View {
        HStack(spacing: 0) {
            if session.showsTools {
                ForEach(InkSession.Tool.allCases) { tool in
                    button(tool.title, symbol: tool.symbol, selected: session.tool == tool) { session.tool = tool }
                }
                divider
                button("Undo", symbol: "arrow.uturn.backward", enabled: session.canUndo) { session.undo() }
                button("Redo", symbol: "arrow.uturn.forward", enabled: session.canRedo) { session.redo() }
                divider
                button("Keyboard", symbol: "keyboard") { session.returnToKeyboard() }
            } else {
                button("Write by Hand", symbol: "pencil.tip") { session.isWriting = true }
            }
        }
        .padding(.horizontal, session.showsTools ? DaybookSpacing.s1 : 0)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
        .animation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion), value: session.showsTools)
    }

    private var divider: some View {
        Rectangle().fill(DaybookPalette.Ink.faint.opacity(0.4)).frame(width: 0.5, height: 22).padding(.horizontal, 2).accessibilityHidden(true)
    }

    private func button(_ title: String, symbol: String, selected: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(selected ? DaybookPalette.Ink.link : DaybookPalette.Ink.title)
                .frame(width: 42, height: 44)
                .background(selected ? DaybookPalette.Ink.link.opacity(0.14) : .clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
