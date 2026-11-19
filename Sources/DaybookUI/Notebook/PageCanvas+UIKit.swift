#if os(iOS)
import DaybookCore
import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// One page: paper under a PencilKit canvas at the page's logical size, drawn smaller as a whole to fit the display, so the
/// strokes stay in the page's own points whatever the scale or the fold (docs/notebook.md). It draws in the light appearance
/// whatever the phone's, and never past content version 3, which every Mac this version reads can render.
@MainActor
final class PageCanvasView: UIView, PKCanvasViewDelegate {
    let pageID: UUID
    let canvas = PKCanvasView()
    private let paperView = PagePaperView()
    /// Holds the paper and the canvas at the page's size; scaled as a whole.
    private let content = UIView()
    private(set) var logicalSize: CGSize
    private var isLoading = false

    /// A stroke began (the tool's begin callback), and the drawing changed: what the session times and settles from.
    var began: ((PageCanvasView) -> Void)?
    var changed: ((PageCanvasView) -> Void)?
    /// Apple Pencil touched this page.
    var sawPencil: (() -> Void)? { didSet { watcher.onPencil = sawPencil } }
    /// Where a touch is on screen while it's down (window coordinates), and nil when it lifts: what floating controls step aside for.
    var touching: ((CGPoint?) -> Void)? { didSet { watcher.onTouch = touching } }
    private let watcher = PencilWatcher()

    init(pageID: UUID, size: CGSize, paper: PagePaper) {
        self.pageID = pageID
        logicalSize = size
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .light
        clipsToBounds = true
        content.bounds = CGRect(origin: .zero, size: size)
        content.layer.anchorPoint = .zero
        addSubview(content)
        paperView.paper = paper
        paperView.frame = content.bounds
        content.addSubview(paperView)
        canvas.frame = content.bounds
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.maximumSupportedContentVersion = .version3
        canvas.drawingPolicy = .anyInput
        canvas.delegate = self
        content.addSubview(canvas)
        canvas.addGestureRecognizer(watcher)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var drawing: PKDrawing { canvas.drawing }

    var paper: PagePaper {
        get { paperView.paper }
        set { paperView.paper = newValue }
    }

    /// Sets the strokes without telling anyone they changed.
    func load(_ drawing: PKDrawing) {
        isLoading = true
        canvas.drawing = drawing
        isLoading = false
    }

    var isWritable: Bool {
        get { canvas.isUserInteractionEnabled }
        set { canvas.isUserInteractionEnabled = newValue }
    }

    func apply(tool: PKTool, pencilOnly: Bool) {
        canvas.tool = tool
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = bounds.width / max(1, logicalSize.width)
        content.transform = CGAffineTransform(scaleX: scale, y: scale)
        content.layer.position = .zero
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { began?(self) }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isLoading else { return }
        changed?(self)
    }

    /// Watches the touches on the canvas without taking any: whether one was Apple Pencil (from then on fingers don't write, so a
    /// resting palm doesn't), and where a touch is while it's down.
    private final class PencilWatcher: UIGestureRecognizer {
        var onPencil: (() -> Void)?
        var onTouch: ((CGPoint?) -> Void)?

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        convenience init() { self.init(target: nil, action: nil) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if touches.contains(where: { $0.type == .pencil }) { onPencil?() }
            report(touches)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { report(touches) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { onTouch?(nil); state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { onTouch?(nil); state = .failed }

        private func report(_ touches: Set<UITouch>) {
            if let touch = touches.first { onTouch?(touch.location(in: nil)) }
        }
    }
}
#endif
