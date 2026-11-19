#if os(iOS)
import DaybookCore
import UIKit

/// The paper a page is drawn on, in the page's own points and always light: a page is paper, so the colours written on it
/// are the colours shown in Dark Mode too. Drawn under the canvas, never into the strokes.
final class PagePaperView: UIView {
    var paper: PagePaper = .ruled { didSet { if paper != oldValue { setNeedsDisplay() } } }

    static let sheet = UIColor(red: 0.992, green: 0.988, blue: 0.976, alpha: 1)
    static let rule = UIColor(red: 0.62, green: 0.70, blue: 0.82, alpha: 0.38)
    static let margin = UIColor(red: 0.86, green: 0.45, blue: 0.45, alpha: 0.28)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.sheet
        isOpaque = true
        isUserInteractionEnabled = false
        overrideUserInterfaceStyle = .light
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard paper == .ruled, let context = UIGraphicsGetCurrentContext() else { return }
        context.setLineWidth(1)
        context.setStrokeColor(Self.rule.cgColor)
        // The first rule leaves a header's room, then one every `ruleSpacing`.
        var y = NotebookPage.ruleSpacing * 2
        while y < bounds.height - NotebookPage.ruleSpacing / 2 {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
            y += NotebookPage.ruleSpacing
        }
        context.strokePath()
        context.setStrokeColor(Self.margin.cgColor)
        context.move(to: CGPoint(x: 52, y: 0))
        context.addLine(to: CGPoint(x: 52, y: bounds.height))
        context.strokePath()
    }
}
#endif
