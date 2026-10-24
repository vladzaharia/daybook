import AppKit
import DaybookKit
import SwiftUI

/// The person's notes as free text, with each paragraph's recording time hung in the left margin.
/// In a page it sizes itself to its text so the page scrolls as one document; in the floating
/// panel it scrolls on its own.
struct MarginNotesEditor: NSViewRepresentable {
    @Binding var text: String
    /// Recording times of the non-empty paragraphs, in order (`Meeting.paragraphTimes()`);
    /// nil for paragraphs written outside a recording.
    var times: [TimeInterval?]
    var placeholder: String
    var fontSize: CGFloat = 14
    var lineSpacing: CGFloat = 5
    /// The time margin: text starts here, and times are right-aligned 8 pt short of it.
    var margin: CGFloat = DaybookStyle.margin
    /// Room between the end of every line and the trailing edge.
    var trailingInset: CGFloat = 0
    /// A fixed size for the times. Nil scales them with the text, as the page does.
    var timeFontSize: CGFloat?
    /// When it scrolls: room under the last line, so it can clear a bar drawn over the bottom edge.
    var bottomInset: CGFloat = 0
    var scrolls = false
    var isEditable = true
    var focusOnAppear = false
    var playTime: ((TimeInterval) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let textView = MarginTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("Your notes")
        context.coordinator.textView = textView
        configure(textView)
        textView.string = text
        textView.applyTypingStyle()
        if scrolls {
            let scrollView = NotesScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            // Insets are this editor's own: the panel's title bar is laid out by SwiftUI above it.
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            scrollView.documentView = textView
            if focusOnAppear { DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) } }
            return scrollView
        }
        // Inside a page, SwiftUI sizes the view from `sizeThatFits`; the text view must not resize itself.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        if focusOnAppear { DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) } }
        return textView
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        configure(textView)
        if let scrollView = view as? NSScrollView, scrollView.contentInsets.bottom != bottomInset {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        if textView.string != text && !context.coordinator.isEditing {
            let selection = textView.selectedRanges
            textView.string = text
            textView.applyTypingStyle()
            textView.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        textView.needsDisplay = true
        if !scrolls { textView.invalidateIntrinsicContentSize() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard !scrolls, let textView = nsView as? MarginTextView, let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: textView.height(forWidth: width))
    }

    private func configure(_ textView: MarginTextView) {
        textView.times = times
        textView.placeholder = placeholder
        textView.margin = margin
        textView.trailingInset = trailingInset
        textView.timeFontSize = timeFontSize
        textView.isEditable = isEditable
        textView.playTime = playTime
        textView.style = .init(fontSize: fontSize, lineSpacing: lineSpacing)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarginNotesEditor
        weak var textView: MarginTextView?
        var isEditing = false
        init(_ parent: MarginNotesEditor) { self.parent = parent }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }
        func textDidEndEditing(_ notification: Notification) { isEditing = false }
        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isEditing = true
            parent.text = textView.string
            textView.invalidateIntrinsicContentSize()
            textView.needsDisplay = true
            DispatchQueue.main.async { [weak self] in self?.isEditing = textView.window?.firstResponder === textView }
        }
    }
}

/// Keeps the notes at least as tall as the visible sheet, so a click anywhere below the last line
/// puts the caret there instead of landing on empty clip view.
private final class NotesScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        let visible = max(0, contentSize.height - contentInsets.top - contentInsets.bottom)
        guard abs(textView.minSize.height - visible) > 0.5 else { return }
        textView.minSize = NSSize(width: 0, height: visible)
        textView.sizeToFit()
    }
}

final class MarginTextView: NSTextView {
    struct Style: Equatable { var fontSize: CGFloat; var lineSpacing: CGFloat }

    var times: [TimeInterval?] = [] { didSet { if times != oldValue { updateGutter() } } }
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var margin: CGFloat = DaybookStyle.margin { didSet { if margin != oldValue { updateContainer(); updateGutter() } } }
    var trailingInset: CGFloat = 0 { didSet { if trailingInset != oldValue { updateContainer(); updateGutter() } } }
    var timeFontSize: CGFloat? { didSet { if timeFontSize != oldValue { updateGutter() } } }
    var playTime: ((TimeInterval) -> Void)? { didSet { gutter.playTime = playTime } }
    var style = Style(fontSize: 14, lineSpacing: 5) {
        didSet { if style != oldValue { applyTypingStyle() } }
    }
    private let gutter = MarginGutterView()

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        addSubview(gutter)
    }

    private var bodyFont: NSFont { .systemFont(ofSize: style.fontSize) }
    private var paragraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = style.fontSize * 0.45
        return paragraph
    }

    /// Typed notes draw in the page's Body ink, the same colour SwiftUI uses for text on paper.
    func applyTypingStyle() {
        let attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: Ink.bodyNS, .paragraphStyle: paragraphStyle]
        typingAttributes = attributes
        if let storage = textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        updateContainer()
        updateGutter()
        needsDisplay = true
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: margin, y: 0) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContainer()
        updateGutter()
    }

    override func didChangeText() {
        super.didChangeText()
        updateGutter()
    }

    override func layout() {
        super.layout()
        updateGutter()
    }

    private func textWidth(for width: CGFloat) -> CGFloat { max(40, width - margin - trailingInset) }

    private func updateContainer() {
        textContainer?.containerSize = NSSize(width: textWidth(for: bounds.width), height: .greatestFiniteMagnitude)
    }

    /// The height the text needs at a given width, used to size the editor inside a page.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        let previous = textContainer.containerSize
        textContainer.containerSize = NSSize(width: textWidth(for: width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        // The used rect already includes the empty line after a trailing newline (and the caret's line
        // in empty text), so nothing is added: empty notes are one line tall, not two.
        let height = max(layoutManager.usedRect(for: textContainer).maxY, layoutManager.extraLineFragmentRect.maxY)
        textContainer.containerSize = previous
        return max(ceil(height), lineHeight)
    }

    private var lineHeight: CGFloat { ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading + style.lineSpacing) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: Ink.faintNS, .paragraphStyle: paragraphStyle]
        (placeholder as NSString).draw(in: NSRect(x: margin, y: 0, width: textWidth(for: bounds.width), height: bounds.height), withAttributes: attributes)
    }

    /// Places each timed paragraph's time on its first line's baseline, right-aligned in the margin.
    /// Paragraphs are split exactly as `NoteTimeline` splits them (any newline character, blank ones
    /// skipped), so `times[n]` always lands on the paragraph it belongs to.
    private func updateGutter() {
        gutter.frame = NSRect(x: 0, y: 0, width: margin, height: bounds.height)
        guard margin > 0, times.contains(where: { $0 != nil }), let layoutManager, let textContainer else {
            gutter.labels = []
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let text = string as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: timeFontSize ?? max(10, style.fontSize * 11 / 14), weight: .regular)
        var labels: [MarginGutterView.Label] = []
        var index = 0
        var location = 0
        while location <= text.length {
            let rest = NSRange(location: location, length: text.length - location)
            let separator = text.rangeOfCharacter(from: .newlines, options: [], range: rest)
            let end = separator.location == NSNotFound ? text.length : separator.location
            let range = NSRange(location: location, length: end - location)
            if !text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if index < times.count, let time = times[index] {
                    let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
                    if glyph < layoutManager.numberOfGlyphs {
                        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                        let baseline = line.minY + layoutManager.location(forGlyphAt: glyph).y + textContainerOrigin.y
                        labels.append(.init(text: TimeLabel.short(time), baseline: baseline, time: time))
                    }
                }
                index += 1
            }
            guard separator.location != NSNotFound else { break }
            location = NSMaxRange(separator)
        }
        gutter.font = font
        gutter.labels = labels
    }
}

/// Draws paragraph times in the editor's left margin, in the Meta ink. Where times can play
/// (the page), the one under the pointer turns link teal and plays from there when clicked.
final class MarginGutterView: NSView {
    struct Label: Equatable { var text: String; var baseline: CGFloat; var time: TimeInterval }
    var labels: [Label] = [] {
        didSet {
            guard labels != oldValue else { return }
            hovered = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { if font != oldValue { needsDisplay = true } } }
    var playTime: ((TimeInterval) -> Void)? { didSet { if (playTime == nil) != (oldValue == nil) { hovered = nil; window?.invalidateCursorRects(for: self) } } }
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private static let linkInk = NSColor(Ink.link)
    override var isFlipped: Bool { true }

    /// Hour-long times ("1:02:03") can be wider than a narrow gutter; those step down in size
    /// (to 8 pt at most) rather than run off the window's edge. The baseline stays shared.
    private func font(for label: Label) -> NSFont {
        let available = bounds.width - 8 - 2
        let width = (label.text as NSString).size(withAttributes: [.font: font]).width
        guard width > available, available > 0 else { return font }
        return font.withSize(max(8, font.pointSize * available / width))
    }

    private func rect(for label: Label) -> NSRect {
        let font = font(for: label)
        let size = (label.text as NSString).size(withAttributes: [.font: font])
        return NSRect(x: bounds.width - 8 - size.width, y: label.baseline - font.ascender, width: size.width, height: size.height)
    }

    private func label(at point: NSPoint) -> Int? {
        labels.firstIndex { rect(for: $0).insetBy(dx: -4, dy: -3).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, label) in labels.enumerated() {
            let ink = index == hovered ? Self.linkInk : Ink.metaNS
            (label.text as NSString).draw(at: rect(for: label).origin, withAttributes: [.font: font(for: label), .foregroundColor: ink])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let playTime, let index = label(at: point) { playTime(labels[index].time); return }
        superview?.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = playTime == nil ? nil : label(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func resetCursorRects() {
        guard playTime != nil else { return }
        for label in labels { addCursorRect(rect(for: label).insetBy(dx: -4, dy: -3), cursor: .pointingHand) }
    }

    override func accessibilityChildren() -> [Any]? { nil }
}
