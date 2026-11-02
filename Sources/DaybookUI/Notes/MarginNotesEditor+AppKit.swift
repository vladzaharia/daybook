#if os(macOS)
import AppKit
import DaybookDesign
import DaybookKit
import SwiftUI

// The Mac's notes editor: an NSTextView with the lane drawn by a subview (NSTextView clips what it draws in its
// own `draw(_:)`). In a page it sizes itself to its text so the page scrolls as one document; in Floating Notes
// it scrolls on its own.

extension MarginNotesEditor: NSViewRepresentable {
    public init(text: Binding<String>, times: [TimeInterval?], marks: [NoteMark] = [], placeholder: String = MarginNotesEditor.placeholder,
                fontSize: CGFloat = 14, lineSpacing: CGFloat = 5, margin: CGFloat = ReadingGeometry.margin, trailingInset: CGFloat = 0,
                timeFontSize: CGFloat? = nil, bottomInset: CGFloat = 0, scrolls: Bool = false, isEditable: Bool = true,
                focusOnAppear: Bool = false, findQuery: String = "", playTime: ((TimeInterval) -> Void)? = nil,
                onFocusChange: ((Bool) -> Void)? = nil) {
        binding = text
        self.times = times
        self.marks = marks
        self.placeholder = placeholder
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.margin = margin
        self.trailingInset = trailingInset
        self.timeFontSize = timeFontSize
        self.bottomInset = bottomInset
        self.scrolls = scrolls
        self.isEditable = isEditable
        self.focusOnAppear = focusOnAppear
        self.findQuery = findQuery
        self.playTime = playTime
        self.onFocusChange = onFocusChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSView {
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
            return NotesContainerView(textView: textView, content: scrollView)
        }
        // Inside a page, SwiftUI sizes the view from `sizeThatFits`; the text view must not resize itself.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        if focusOnAppear { DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) } }
        return NotesContainerView(textView: textView, content: textView)
    }

    public func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        configure(textView)
        if let scrollView = (view as? NotesContainerView)?.scrollView, scrollView.contentInsets.bottom != bottomInset {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        // While typing, only a change from elsewhere (a phone's paragraph during a shared recording) is taken.
        if textView.string != text && (!context.coordinator.isEditing || text != context.coordinator.lastWritten) {
            context.coordinator.lastWritten = text
            let selection = textView.selectedRanges
            textView.string = text
            textView.applyTypingStyle()
            textView.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        textView.needsDisplay = true
        if !scrolls { textView.invalidateIntrinsicContentSize() }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard !scrolls, let textView = (nsView as? NotesContainerView)?.textView, let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: textView.height(forWidth: width))
    }

    private func configure(_ textView: MarginTextView) {
        textView.times = times
        textView.marks = marks
        textView.placeholder = placeholder
        textView.margin = margin
        textView.trailingInset = trailingInset
        textView.timeFontSize = timeFontSize
        textView.isEditable = isEditable
        textView.playTime = playTime
        textView.findQuery = findQuery
        textView.style = .init(fontSize: fontSize, lineSpacing: lineSpacing)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarginNotesEditor
        weak var textView: MarginTextView?
        var isEditing = false
        /// The text this editor last wrote back, so a change from elsewhere is told from its own.
        var lastWritten: String?
        init(_ parent: MarginNotesEditor) { self.parent = parent }

        public func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
            parent.onFocusChange?(true)
        }

        public func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            parent.onFocusChange?(false)
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isEditing = true
            lastWritten = textView.string
            parent.text = textView.string
            textView.invalidateIntrinsicContentSize()
            textView.needsDisplay = true
            DispatchQueue.main.async { [weak self] in self?.isEditing = textView.window?.firstResponder === textView }
        }
    }
}

/// Holds the notes for SwiftUI (the text view, or the scroll view around it), and gives VoiceOver what the text view
/// itself can't: its times (buttons where they play) and its marks, beside the notes. An NSTextView reports no
/// children, so elements under it are never reached.
final class NotesContainerView: NSView {
    let textView: MarginTextView
    /// The text view, or the scroll view around it.
    let content: NSView

    init(textView: MarginTextView, content: NSView) {
        self.textView = textView
        self.content = content
        super.init(frame: .zero)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        textView.gutter.container = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var scrollView: NSScrollView? { content as? NSScrollView }

    override var intrinsicContentSize: NSSize { scrollView == nil ? textView.intrinsicContentSize : super.intrinsicContentSize }

    override func resizeSubviews(withOldSize oldSize: NSSize) { content.frame = bounds }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { false }

    /// The notes first, then each time and mark in reading order.
    override func accessibilityChildren() -> [Any]? { [content] + textView.gutter.accessibilityItems }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        textView.gutter.accessibilityItem(at: point) ?? super.accessibilityHitTest(point)
    }
}

/// Keeps the notes at least as tall as the visible sheet, so a click anywhere below the last line
/// puts the caret there instead of landing on empty clip view.
final class NotesScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        let visible = max(0, contentSize.height - contentInsets.top - contentInsets.bottom)
        guard abs(textView.minSize.height - visible) > 0.5 else { return }
        textView.minSize = NSSize(width: 0, height: visible)
        textView.sizeToFit()
    }
}

/// The text view: TextKit 1, so each paragraph's first baseline can be read from the layout manager the same
/// way on both apps.
final class MarginTextView: NSTextView {
    struct Style: Equatable { var fontSize: CGFloat; var lineSpacing: CGFloat }

    var times: [TimeInterval?] = [] { didSet { if times != oldValue { updateGutter() } } }
    var marks: [NoteMark] = [] { didSet { if marks != oldValue { updateGutter() } } }
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var margin: CGFloat = ReadingGeometry.margin { didSet { if margin != oldValue { updateContainer(); updateGutter() } } }
    var trailingInset: CGFloat = 0 { didSet { if trailingInset != oldValue { updateContainer(); updateGutter() } } }
    var timeFontSize: CGFloat? { didSet { if timeFontSize != oldValue { updateGutter() } } }
    var playTime: ((TimeInterval) -> Void)? { didSet { gutter.playTime = playTime } }
    var findQuery = "" { didSet { if findQuery != oldValue { updateFindMarks() } } }
    var style = Style(fontSize: 14, lineSpacing: 5) {
        didSet { if style != oldValue { applyTypingStyle() } }
    }
    let gutter = MarginGutterView()

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        addSubview(gutter)
        // ⌘F finds in the notes, as it does in any text, highlighting as it types.
        usesFindBar = true
        isIncrementalSearchingEnabled = true
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
        let attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: DaybookPalette.Shade.body.nsColor,
                                                         .paragraphStyle: paragraphStyle]
        typingAttributes = attributes
        if let storage = textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        updateContainer()
        updateGutter()
        updateFindMarks()
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
        updateFindMarks()
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

    /// Inside a page the container is what SwiftUI sizes, so it hears that the notes changed height.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        (superview as? NotesContainerView)?.invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: DaybookPalette.Shade.faint.nsColor,
                                                         .paragraphStyle: paragraphStyle]
        (placeholder as NSString).draw(in: NSRect(x: margin, y: 0, width: textWidth(for: bounds.width), height: bounds.height), withAttributes: attributes)
    }

    /// Places each timed paragraph's time on its first line's baseline, right-aligned in the margin, and each
    /// mark beside the first line of the paragraph written after it (or the line after the last).
    func updateGutter() {
        gutter.frame = NSRect(x: 0, y: 0, width: margin, height: bounds.height)
        guard margin > 0, times.contains(where: { $0 != nil }) || !marks.isEmpty, let layoutManager, let textContainer else {
            gutter.update(labels: [], ticks: [])
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let text = string as NSString
        let ranges = NoteParagraphs.ranges(in: text)
        let font = NSFont.monospacedDigitSystemFont(ofSize: timeFontSize ?? max(10, style.fontSize * 11 / 14), weight: .regular)
        var labels: [MarginGutterView.Label] = []
        var lines: [CGRect] = []
        for range in ranges {
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            guard glyph < layoutManager.numberOfGlyphs else { lines.append(.null); continue }
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: 0, dy: textContainerOrigin.y)
            lines.append(line)
            let index = lines.count - 1
            if index < times.count, let time = times[index] {
                let baseline = line.minY + layoutManager.location(forGlyphAt: glyph).y
                labels.append(.init(text: TimeLabel.short(time), baseline: baseline, time: time))
            }
        }
        // After the last paragraph: the caret's next line.
        let used = layoutManager.usedRect(for: textContainer)
        let next: CGRect = text.length == 0 ? CGRect(x: 0, y: 0, width: 0, height: lineHeight)
            : layoutManager.extraLineFragmentRect.height > 0 ? layoutManager.extraLineFragmentRect
            : CGRect(x: 0, y: used.maxY + style.fontSize * 0.45, width: 0, height: lineHeight)
        var ticks: [MarginGutterView.Tick] = []
        for (mark, before) in NoteParagraphs.placement(of: marks, times: Array(times.prefix(ranges.count))) {
            let line = before < lines.count && !lines[before].isNull ? lines[before] : next
            let height = min(line.height, style.fontSize * 1.25)
            ticks.append(.init(mark: mark, rect: NSRect(x: margin - 6.5, y: line.minY + 1, width: 5, height: height - 2)))
        }
        gutter.font = font
        gutter.update(labels: labels, ticks: ticks)
    }

    /// The library search's matches, marked as the page marks them; the text itself never changes.
    private func updateFindMarks() {
        guard let layoutManager else { return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        for match in NoteParagraphs.matches(of: findQuery, in: string as NSString) {
            layoutManager.addTemporaryAttributes([.backgroundColor: DaybookPalette.Shade.findHighlight.nsColor,
                                                  .foregroundColor: DaybookPalette.Shade.onFind.nsColor], forCharacterRange: match)
        }
    }

    // MARK: Play from Here

    /// The time "Play from Here" plays from: the paragraph at `location`, or the insertion point's.
    func playableTime(at location: Int? = nil) -> TimeInterval? {
        guard playTime != nil else { return nil }
        let at = location ?? selectedRange().location
        return NoteParagraphs.playTime(at: at, ranges: NoteParagraphs.ranges(in: string as NSString), times: times)
    }

    @objc private func playFromHere(_ sender: NSMenuItem) {
        guard let time = sender.representedObject as? TimeInterval else { return }
        playTime?(time)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        if let time = playableTime(at: characterIndexForInsertion(at: point)) {
            let item = NSMenuItem(title: MarginNotesEditor.playFromHere, action: #selector(playFromHere(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = time
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    /// A point over a time or a mark finds it, as the container lists it.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        gutter.accessibilityItem(at: point) ?? super.accessibilityHitTest(point)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard playTime != nil else { return super.accessibilityCustomActions() }
        let play = NSAccessibilityCustomAction(name: MarginNotesEditor.playFromHere) { [weak self] in
            guard let self, let time = self.playableTime() else { return false }
            self.playTime?(time)
            return true
        }
        return (super.accessibilityCustomActions() ?? []) + [play]
    }
}

/// Draws paragraph times in the editor's left margin, in the Meta ink, and the recording's marks beside them.
/// Where times can play (the page), the one under the pointer turns link teal and plays from there when
/// clicked. For VoiceOver each time is a button ("Play from 4 minutes 10 seconds") and each mark says itself; the
/// container lists them beside the notes.
final class MarginGutterView: NSView {
    struct Label: Equatable { var text: String; var baseline: CGFloat; var time: TimeInterval }
    struct Tick: Equatable { var mark: NoteMark; var rect: NSRect }

    private(set) var labels: [Label] = []
    private(set) var ticks: [Tick] = []
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { if font != oldValue { needsDisplay = true } } }
    var playTime: ((TimeInterval) -> Void)? { didSet { if (playTime == nil) != (oldValue == nil) { hovered = nil; window?.invalidateCursorRects(for: self) } } }
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var elements: [NSAccessibilityElement] = []
    /// What VoiceOver finds the times and marks in.
    weak var container: NotesContainerView?
    override var isFlipped: Bool { true }

    func update(labels: [Label], ticks: [Tick]) {
        guard labels != self.labels || ticks != self.ticks else { return }
        self.labels = labels
        self.ticks = ticks
        hovered = nil
        elements = []
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if let container { NSAccessibility.post(element: container, notification: .layoutChanged) }
    }

    /// Hour-long times ("1:02:03") can be wider than a narrow gutter; those step down in size
    /// (to 8 pt at most) rather than run off the window's edge. The baseline stays shared.
    private func font(for label: Label) -> NSFont {
        let available = bounds.width - 8 - 2
        let width = (label.text as NSString).size(withAttributes: [.font: font]).width
        guard width > available, available > 0 else { return font }
        return font.withSize(max(8, font.pointSize * available / width))
    }

    func rect(for label: Label) -> NSRect {
        let font = font(for: label)
        let size = (label.text as NSString).size(withAttributes: [.font: font])
        return NSRect(x: bounds.width - 8 - size.width, y: label.baseline - font.ascender, width: size.width, height: size.height)
    }

    private func label(at point: NSPoint) -> Int? {
        labels.firstIndex { rect(for: $0).insetBy(dx: -4, dy: -3).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, label) in labels.enumerated() {
            let ink = index == hovered ? DaybookPalette.Shade.link.nsColor : DaybookPalette.Shade.meta.nsColor
            (label.text as NSString).draw(at: rect(for: label).origin, withAttributes: [.font: font(for: label), .foregroundColor: ink])
        }
        for tick in ticks {
            (tick.mark.kind == .bookmark ? DaybookPalette.Shade.bookmark.nsColor : DaybookPalette.Shade.meta.nsColor).setFill()
            MarkTick.path(tick.mark.kind, in: tick.rect).fill()
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

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { false }

    /// Each time and mark, in reading order. The container lists them; the gutter, inside the text view, keeps no
    /// children of its own.
    var accessibilityItems: [NSAccessibilityElement] {
        if elements.isEmpty && (!labels.isEmpty || !ticks.isEmpty) { elements = makeElements() }
        return elements
    }

    /// The time or mark at a point on screen.
    func accessibilityItem(at point: NSPoint) -> NSAccessibilityElement? {
        accessibilityItems.last { NSPointInRect(point, $0.accessibilityFrame()) }
    }

    /// One element per time, a button when it plays, and one per mark, in reading order.
    private func makeElements() -> [NSAccessibilityElement] {
        let plays = playTime != nil
        var items: [(y: CGFloat, element: NSAccessibilityElement)] = []
        for label in labels {
            let time = label.time
            let element = GutterElement(gutter: self, rect: { [weak self] in self.map { $0.rect(for: label).insetBy(dx: -4, dy: -3) } ?? .zero },
                                        press: plays ? { [weak self] in self?.playTime?(time) } : nil)
            element.setAccessibilityRole(plays ? .button : .staticText)
            element.setAccessibilityLabel(MarginNotesEditor.spokenTime(time, plays: plays))
            items.append((rect(for: label).minY, element))
        }
        for tick in ticks {
            let element = GutterElement(gutter: self, rect: { tick.rect.insetBy(dx: -4, dy: -2) }, press: nil)
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(tick.mark.spoken)
            items.append((tick.rect.minY - 0.5, element))
        }
        return items.sorted { $0.y < $1.y }.map(\.element)
    }
}

/// A time or a mark in the gutter, as VoiceOver finds it: beside the notes in their container, where it is on screen
/// now, and what pressing it does.
private final class GutterElement: NSAccessibilityElement {
    private weak var gutter: MarginGutterView?
    private let rect: () -> NSRect
    private let press: (() -> Void)?

    init(gutter: MarginGutterView, rect: @escaping () -> NSRect, press: (() -> Void)?) {
        self.gutter = gutter
        self.rect = rect
        self.press = press
        super.init()
    }

    /// The container that lists it, or what stands for it in the tree when the container itself is left out.
    override func accessibilityParent() -> Any? {
        guard let container = gutter?.container else { return nil }
        return NSAccessibility.unignoredAncestor(of: container) ?? container
    }

    override func accessibilityFrame() -> NSRect {
        guard let gutter, let window = gutter.window else { return .zero }
        return window.convertToScreen(gutter.convert(rect(), to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        press()
        return true
    }
}

/// The shape of a mark in the lane: a bookmark's ribbon, a photo's frame.
enum MarkTick {
    static func path(_ kind: NoteMark.Kind, in rect: NSRect) -> NSBezierPath {
        switch kind {
        case .bookmark:
            // A ribbon with a notch at its foot, like the Bookmark glyph.
            let path = NSBezierPath()
            let notch = min(rect.width * 0.6, rect.height * 0.3)
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY - notch))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.close()
            return path
        case .photo:
            let side = min(rect.width + 1, rect.height)
            return NSBezierPath(roundedRect: NSRect(x: rect.midX - side / 2, y: rect.minY + 1, width: side, height: side), xRadius: 1.5, yRadius: 1.5)
        }
    }
}
#endif
