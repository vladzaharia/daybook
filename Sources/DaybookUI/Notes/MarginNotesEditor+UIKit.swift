#if os(iOS)
import DaybookDesign
import DaybookKit
import SwiftUI
import UIKit

// The iPhone's notes editor: a UITextView with the lane drawn by a subview that scrolls with the text. Text
// follows Dynamic Type and the lane grows with it, to 1.9 times; at the accessibility sizes the lane goes and
// each time sits on a line of its own above its paragraph, so the notes keep the whole width.

extension MarginNotesEditor: UIViewRepresentable {
    public init(text: Binding<String>, times: [TimeInterval?], marks: [NoteMark] = [], placeholder: String = MarginNotesEditor.placeholder,
                textStyle: UIFont.TextStyle = .body, lane: CGFloat = ReadingGeometry.lane, scrolls: Bool = false, isEditable: Bool = true,
                focusOnAppear: Bool = false, bottomInset: CGFloat = 0, findQuery: String = "", playTime: ((TimeInterval) -> Void)? = nil,
                onFocusChange: ((Bool) -> Void)? = nil, ink: NotesInkModel? = nil) {
        binding = text
        self.ink = ink
        self.times = times
        self.marks = marks
        self.placeholder = placeholder
        self.textStyle = textStyle
        self.lane = lane
        self.scrolls = scrolls
        self.isEditable = isEditable
        self.focusOnAppear = focusOnAppear
        self.bottomInset = bottomInset
        self.findQuery = findQuery
        self.playTime = playTime
        self.onFocusChange = onFocusChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> NotesContainerView {
        let view = MarginTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = scrolls
        view.alwaysBounceVertical = scrolls
        view.keyboardDismissMode = scrolls ? .interactive : .none
        view.smartQuotesType = .yes
        view.smartDashesType = .yes
        view.autocorrectionType = .default
        view.accessibilityLabel = "Your notes"
        // A scrolled paragraph fades under whatever sits above the notes rather than being sliced by it.
        view.topEdgeEffect.style = .soft
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(view)
        view.setText(text)
        if focusOnAppear {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
        return NotesContainerView(textView: view)
    }

    public func updateUIView(_ container: NotesContainerView, context: Context) {
        context.coordinator.parent = self
        let view = container.textView
        configure(view)
        view.isScrollEnabled = scrolls
        if scrolls, view.contentInset.bottom != bottomInset {
            view.contentInset.bottom = bottomInset
            view.verticalScrollIndicatorInsets.bottom = bottomInset
        }
        view.syncInk(with: text)
        // While typing, only a change from elsewhere (a Mac's paragraph during a shared recording) is taken.
        if view.serializedText != text && (!context.coordinator.isEditing || text != context.coordinator.lastWritten) {
            view.setText(text)
            context.coordinator.lastWritten = text
            view.invalidateIntrinsicContentSize()
            container.invalidateIntrinsicContentSize()
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: NotesContainerView, context: Context) -> CGSize? {
        guard !scrolls, let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.textView.height(forWidth: width))
    }

    private func configure(_ view: MarginTextView) {
        view.baseLane = lane
        view.textStyle = textStyle
        view.times = times
        view.marks = marks
        view.placeholder = placeholder
        view.isEditable = isEditable
        view.playTime = playTime
        view.findQuery = findQuery
        view.ink = ink
    }

    @MainActor
    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarginNotesEditor
        var isEditing = false
        /// The text this editor last wrote back, so a change from elsewhere is told from its own.
        var lastWritten: String?
        init(_ parent: MarginNotesEditor) { self.parent = parent }

        /// While a finger is writing, a touch on the words doesn't bring the keyboard back.
        public func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            (textView as? MarginTextView)?.ink?.session.isWriting != true
        }

        public func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            (textView as? MarginTextView)?.textTookFocus()
            parent.onFocusChange?(true)
        }

        public func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            parent.onFocusChange?(false)
        }

        public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            (textView as? MarginTextView)?.allowsEdit(in: range, replacing: text) ?? true
        }

        public func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? MarginTextView else { return }
            if let text = view.textToWriteBack() {
                lastWritten = text
                parent.text = text
            }
            view.textDidChange()
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? MarginTextView)?.keepCaretVisible()
        }

        /// Play from Here leads the edit menu where the times play.
        public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let view = textView as? MarginTextView, let time = view.playableTime(at: range.location) else { return nil }
            let play = UIAction(title: MarginNotesEditor.playFromHere, image: UIImage(systemName: "play")) { [weak view] _ in view?.playTime?(time) }
            return UIMenu(children: [play] + suggestedActions)
        }
    }
}

/// Holds the text view for SwiftUI, and gives VoiceOver what the text view itself can't: its times (buttons when
/// they play) and its marks, beside the notes.
public final class NotesContainerView: UIView {
    public let textView: MarginTextView

    init(textView: MarginTextView) {
        self.textView = textView
        super.init(frame: .zero)
        textView.frame = bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(textView)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: CGSize { textView.intrinsicContentSize }

    public override var accessibilityElements: [Any]? {
        get { [textView] + textView.inkAccessibilityItems + textView.gutter.accessibilityItems }
        set {}
    }
}

/// The text view: TextKit 1, so each paragraph's first baseline can be read from the layout manager the same
/// way on both apps.
public final class MarginTextView: UITextView {
    public var times: [TimeInterval?] = [] { didSet { if times != oldValue { restyleParagraphs(); setNeedsLayout() } } }
    public var marks: [NoteMark] = [] { didSet { if marks != oldValue { restyleParagraphs(); setNeedsLayout() } } }
    public var baseLane: CGFloat = ReadingGeometry.lane { didSet { if baseLane != oldValue { applyStyle() } } }
    public var textStyle: UIFont.TextStyle = .body { didSet { if textStyle != oldValue { applyStyle() } } }
    public var placeholder = "" { didSet { placeholderLabel.text = placeholder } }
    public var playTime: ((TimeInterval) -> Void)? { didSet { gutter.playTime = playTime; updateActions() } }
    public var findQuery = "" { didSet { if findQuery != oldValue { restyleParagraphs() } } }

    let gutter = MarginGutterView()
    private let placeholderLabel = UILabel()

    /// Handwriting: nil leaves it out.
    public var ink: NotesInkModel? { didSet { inkModelChanged() } }
    /// The canvases over the attachments, by block.
    var inkViews: [UUID: InkBlockView] = [:]
    /// The empty canvas past the last paragraph, where the next block starts.
    var tailView: InkBlockView?
    var observedSession: InkSession?
    var pendingRecognition: [UUID: Task<Void, Never>] = [:]
    /// Blocks nothing could read just now, so they aren't tried at every update.
    var unreadable = Set<UUID>()
    /// What puts back each block an edit took out of the text, for when Undo brings its attachment back.
    var undoVanishedInk: [UUID: () -> Void] = [:]
    /// Whether the writing tools were up at the last look, so blocks give back their room only as the writing ends.
    var wasShowingInkTools = false
    /// Whether a finger was writing at the last look, so the space at the caret opens as the writing starts.
    var wasWritingByHand = false
    /// The words have had the focus, so going back to them returns to the caret rather than the end.
    var hadWordsFocus = false
    /// The space opened after the caret's paragraph, which isn't in the notes until something is written in it.
    var inkGap: (view: InkBlockView, attachment: InkAttachment, after: Int)?
    /// Room under the text for the canvas past the last paragraph.
    private var tailInset: CGFloat = 0

    func updateTailInset(_ inset: CGFloat) {
        tailInset = inset
        textContainerInset.bottom = inset
    }

    public init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        addSubview(gutter)
        placeholderLabel.numberOfLines = 0
        placeholderLabel.textColor = DaybookPalette.Shade.faint.uiColor
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        applyStyle()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self,
                                 UITraitAccessibilityContrast.self]) { (view: MarginTextView, _: UITraitCollection) in
            view.applyStyle()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// At the accessibility sizes each time sits above its paragraph instead of in a lane beside it.
    var timesAbove: Bool { baseLane > 0 && traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    /// The lane's width at the current text size; times are right-aligned 10 pt short of the text.
    public var lane: CGFloat {
        guard baseLane > 0, !timesAbove else { return 0 }
        return min(baseLane * ReadingGeometry.laneGrowth,
                   UIFontMetrics(forTextStyle: .footnote).scaledValue(for: baseLane, compatibleWith: traitCollection))
    }

    var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traitCollection) }

    private func paragraph(spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = DaybookFont.bodyLineSpacing(.touch)
        paragraph.paragraphSpacing = bodyFont.pointSize * 0.45
        paragraph.paragraphSpacingBefore = spacingBefore
        return paragraph
    }

    var attributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: DaybookPalette.Shade.body.uiColor, .paragraphStyle: paragraph()]
    }

    /// A time's own line above its paragraph, at the accessibility sizes.
    private var headerHeight: CGFloat { ceil(gutter.font.lineHeight + 6) }

    public func setText(_ value: String) {
        let selection = selectedRange
        inkGap = nil
        textStorage.setAttributedString(displayString(for: value))
        syncInkViews()
        applied = nil
        selectedRange = NSRange(location: min(selection.location, textStorage.length), length: 0)
        textDidChange()
    }

    /// Typed notes draw in the page's Body ink, at the reader's text size.
    public func applyStyle() {
        typingAttributes = attributes
        gutter.font = UIFont.monospacedDigitSystemFont(ofSize: UIFontMetrics(forTextStyle: .footnote)
            .scaledValue(for: 13, compatibleWith: traitCollection), weight: .regular)
        if textStorage.length > 0 {
            textStorage.beginEditing()
            textStorage.addAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
            textStorage.endEditing()
        }
        applied = nil
        placeholderLabel.font = bodyFont
        tintColor = DaybookPalette.Shade.accent.uiColor
        restyleParagraphs()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    public func textDidChange() {
        placeholderLabel.isHidden = !text.isEmpty
        restyleParagraphs()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// What the text's attributes say beyond the base style, so they're set again only when it changes (never
    /// at every keystroke).
    private struct Restyle: Equatable {
        /// Where each paragraph that has a line above it starts, and how tall that line is.
        var headers: [Int] = []
        var header: CGFloat = 0
        var matches: [NSRange] = []
    }

    private var applied: Restyle?

    /// What each paragraph needs beyond the base style: room above it for its time at the accessibility sizes,
    /// and the library search's matches marked. Never while text is being composed (it would end the composition).
    private func restyleParagraphs() {
        let text = self.text as NSString
        let ranges = NoteParagraphs.ranges(in: text)
        var wanted = Restyle(header: headerHeight, matches: NoteParagraphs.matches(of: findQuery, in: text))
        if timesAbove {
            let marked = Set(NoteParagraphs.placement(of: marks, times: Array(times.prefix(ranges.count))).map(\.before))
            wanted.headers = ranges.enumerated()
                .filter { index, _ in (index < times.count && times[index] != nil) || marked.contains(index) }
                .map(\.element.location)
        }
        // The first paragraph's room is the text's top inset: TextKit gives the first line no space before it.
        let insets = UIEdgeInsets(top: wanted.headers.first == 0 ? headerHeight : 0, left: lane, bottom: tailInset, right: 0)
        if textContainerInset != insets { textContainerInset = insets }
        let plain = wanted.headers.isEmpty && wanted.matches.isEmpty
        guard markedTextRange == nil, applied.map({ $0 != wanted }) ?? !plain else { return }
        applied = wanted
        let whole = NSRange(location: 0, length: text.length)
        guard text.length > 0 else { return }
        textStorage.beginEditing()
        textStorage.removeAttribute(.backgroundColor, range: whole)
        textStorage.addAttribute(.foregroundColor, value: DaybookPalette.Shade.body.uiColor, range: whole)
        textStorage.addAttribute(.paragraphStyle, value: paragraph(), range: whole)
        for location in wanted.headers where location > 0 {
            textStorage.addAttribute(.paragraphStyle, value: paragraph(spacingBefore: wanted.header),
                                     range: text.paragraphRange(for: NSRange(location: location, length: 0)))
        }
        for match in wanted.matches {
            textStorage.addAttributes([.backgroundColor: DaybookPalette.Shade.findHighlight.uiColor,
                                       .foregroundColor: DaybookPalette.Shade.onFind.uiColor], range: match)
        }
        textStorage.endEditing()
    }

    /// The height the text needs at a given width, to size the editor inside a page.
    public func height(forWidth width: CGFloat) -> CGFloat {
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let placeholderHeight = text.isEmpty
            ? placeholderLabel.sizeThatFits(CGSize(width: max(40, width - lane), height: .greatestFiniteMagnitude)).height : 0
        return ceil(max(fitted, placeholderHeight, bodyFont.lineHeight))
    }

    public override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else { return super.intrinsicContentSize }
        return CGSize(width: UIView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 320))
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applySession() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let placeholderWidth = max(40, bounds.width - lane)
        let size = placeholderLabel.sizeThatFits(CGSize(width: placeholderWidth, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(x: lane, y: textContainerInset.top, width: placeholderWidth, height: size.height)
        placeholderLabel.isHidden = !text.isEmpty
        layoutGutter()
        layoutInk()
    }

    /// Places each timed paragraph's time on its first line's baseline, right-aligned in the lane (or on its own
    /// line above the paragraph), and each mark before the paragraph written after it.
    private func layoutGutter() {
        let height = max(contentSize.height, bounds.height)
        let above = timesAbove
        gutter.frame = CGRect(x: 0, y: 0, width: above ? bounds.width : lane, height: height)
        guard baseLane > 0, times.contains(where: { $0 != nil }) || !marks.isEmpty else {
            gutter.update(labels: [], ticks: [], above: above)
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let text = self.text as NSString
        let gap = inkGap.flatMap { open in inkAttachments.first { $0.attachment === open.attachment }?.location }
        let ranges = NoteParagraphs.ranges(in: text).filter { $0.location != gap }
        var labels: [MarginGutterView.Label] = []
        // Each paragraph's top and its first line, in this view's coordinates.
        var tops: [(top: CGFloat, line: CGRect)?] = []
        for (index, range) in ranges.enumerated() {
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            guard glyph < layoutManager.numberOfGlyphs else { tops.append(nil); continue }
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: 0, dy: textContainerInset.top)
            let top = above && range.location == 0 ? 0 : line.minY
            tops.append((top, line))
            if index < times.count, let time = times[index] {
                let onInk = textStorage.attribute(.attachment, at: range.location, effectiveRange: nil) is InkAttachment
                let baseline = above ? top + gutter.font.ascender + 2
                    : onInk ? line.minY + gutter.font.ascender + 4 : line.minY + layoutManager.location(forGlyphAt: glyph).y
                labels.append(.init(text: TimeLabel.short(time), baseline: baseline, time: time))
            }
        }
        let lineHeight = bodyFont.lineHeight
        let next = nextLineRect
        var ticks: [MarginGutterView.Tick] = []
        for (mark, before) in NoteParagraphs.placement(of: marks, times: Array(times.prefix(ranges.count))) {
            let place = before < tops.count ? tops[before] : nil
            if above {
                let y = place?.top ?? next.minY
                ticks.append(.init(mark: mark, rect: CGRect(x: 0, y: y + 3, width: 6, height: min(headerHeight, 16) - 4)))
            } else {
                let line = place?.line ?? next
                ticks.append(.init(mark: mark, rect: CGRect(x: lane - 7.5, y: line.minY + 2, width: 5, height: min(line.height, lineHeight * 1.1) - 4)))
            }
        }
        gutter.update(labels: labels, ticks: ticks, above: above)
    }

    /// Where the next paragraph would start, in this view's coordinates.
    var nextLineRect: CGRect {
        let lineHeight = bodyFont.lineHeight
        if textStorage.length == 0 { return CGRect(x: 0, y: textContainerInset.top, width: 0, height: lineHeight) }
        if layoutManager.extraLineFragmentRect.height > 0 { return layoutManager.extraLineFragmentRect.offsetBy(dx: 0, dy: textContainerInset.top) }
        let used = layoutManager.usedRect(for: textContainer)
        return CGRect(x: 0, y: used.maxY + textContainerInset.top + bodyFont.pointSize * 0.45, width: 0, height: lineHeight)
    }

    /// The times drawn in the lane, top to bottom, with their baselines (for tests and diagnostics).
    public var laneTimes: [(text: String, baseline: CGFloat)] {
        layoutIfNeeded()
        return gutter.labels.map { ($0.text, $0.baseline) }
    }

    /// The marks drawn in the lane, top to bottom (for tests and diagnostics).
    public var laneMarks: [(mark: NoteMark, frame: CGRect)] {
        layoutIfNeeded()
        return gutter.ticks.map { ($0.mark, $0.rect) }
    }

    /// Keeps the caret above the keyboard when the page, not this view, scrolls.
    public func keepCaretVisible() {
        guard !isScrollEnabled, isFirstResponder, let range = selectedTextRange else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroller = ancestor as? UIScrollView else { return }
        let caret = caretRect(for: range.end).insetBy(dx: 0, dy: -24)
        scroller.scrollRectToVisible(convert(caret, to: scroller), animated: true)
    }

    // MARK: Play from Here

    /// The time "Play from Here" plays from: the paragraph at `location`, or the insertion point's.
    public func playableTime(at location: Int? = nil) -> TimeInterval? {
        guard playTime != nil else { return nil }
        return NoteParagraphs.playTime(at: location ?? selectedRange.location, ranges: NoteParagraphs.ranges(in: text as NSString), times: times)
    }

    private func updateActions() {
        guard playTime != nil else { accessibilityCustomActions = nil; return }
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: MarginNotesEditor.playFromHere) { [weak self] _ in
            guard let self, let time = self.playableTime() else { return false }
            self.playTime?(time)
            return true
        }]
    }
}

/// The lane of times and marks. Each time is a button when it can play (meta ink, link ink when pressed); for
/// VoiceOver it's "Play from 4 minutes 10 seconds", or the time a note was taken.
final class MarginGutterView: UIView {
    struct Label: Equatable { var text: String; var baseline: CGFloat; var time: TimeInterval }
    struct Tick: Equatable { var mark: NoteMark; var rect: CGRect }

    private(set) var labels: [Label] = []
    private(set) var ticks: [Tick] = []
    private var above = false
    var font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular) { didSet { if font != oldValue { rebuild() } } }
    var playTime: ((TimeInterval) -> Void)? { didSet { if (playTime == nil) != (oldValue == nil) { rebuild() } } }
    private var buttons: [UIButton] = []
    private var markElements: [UIAccessibilityElement] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(labels: [Label], ticks: [Tick], above: Bool) {
        let rebuilds = labels != self.labels || above != self.above
        let redraws = ticks != self.ticks
        self.labels = labels
        self.ticks = ticks
        self.above = above
        if rebuilds { rebuild() } else { setNeedsLayout() }
        if redraws {
            markElements = []
            setNeedsDisplay()
        }
        if rebuilds || redraws { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
    }

    /// Times and marks in reading order, for the editor's container.
    var accessibilityItems: [Any] {
        if markElements.count != ticks.count {
            markElements = ticks.map { tick in
                let element = UIAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = tick.mark.spoken
                element.accessibilityTraits = .staticText
                element.accessibilityFrameInContainerSpace = tick.rect.insetBy(dx: -8, dy: -4)
                return element
            }
        }
        let items: [(CGFloat, Any)] = zip(buttons, labels).map { ($1.baseline - font.ascender, $0) }
            + zip(markElements, ticks).map { ($1.rect.minY - 0.5, $0) }
        return items.sorted { $0.0 < $1.0 }.map(\.1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (button, label) in zip(buttons, labels) {
            let size = button.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
            if above {
                let leading: CGFloat = ticks.contains { abs($0.rect.minY - (label.baseline - font.ascender - 2 + 3)) < 1 } ? 12 : 0
                button.frame = CGRect(x: leading, y: label.baseline - font.ascender - 6, width: min(size.width, bounds.width - leading),
                                      height: font.lineHeight + 12)
            } else {
                // Hour-long times can be wider than a narrow lane; they shrink rather than run off the edge.
                let width = min(size.width, max(0, bounds.width - 10))
                button.frame = CGRect(x: bounds.width - 10 - width, y: label.baseline - font.ascender - 6,
                                      width: width, height: font.lineHeight + 12)
            }
        }
    }

    override func draw(_ rect: CGRect) {
        for tick in ticks {
            let ink = tick.mark.kind == .bookmark ? DaybookPalette.Shade.bookmark.uiColor : DaybookPalette.Shade.meta.uiColor
            ink.setFill()
            Self.path(tick.mark.kind, in: tick.rect).fill()
        }
    }

    /// The shape of a mark in the lane: a bookmark's ribbon, a photo's frame.
    static func path(_ kind: NoteMark.Kind, in rect: CGRect) -> UIBezierPath {
        switch kind {
        case .bookmark:
            let path = UIBezierPath()
            let notch = min(rect.width * 0.6, rect.height * 0.3)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notch))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.close()
            return path
        case .photo:
            let side = min(rect.width + 1, rect.height)
            return UIBezierPath(roundedRect: CGRect(x: rect.midX - side / 2, y: rect.minY + 1, width: side, height: side), cornerRadius: 1.5)
        }
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        let plays = playTime != nil
        buttons = labels.map { label in
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
            configuration.attributedTitle = AttributedString(label.text, attributes: AttributeContainer([.font: font]))
            configuration.titleLineBreakMode = .byClipping
            button.configuration = configuration
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.7
            button.configurationUpdateHandler = { button in
                button.configuration?.baseForegroundColor = button.isHighlighted ? DaybookPalette.Shade.link.uiColor : DaybookPalette.Shade.meta.uiColor
            }
            button.contentHorizontalAlignment = above ? .leading : .trailing
            button.isUserInteractionEnabled = plays
            button.accessibilityLabel = MarginNotesEditor.spokenTime(label.time, plays: plays)
            button.accessibilityTraits = plays ? .button : .staticText
            let time = label.time
            button.addAction(UIAction { [weak self] _ in self?.playTime?(time) }, for: .primaryActionTriggered)
            addSubview(button)
            return button
        }
        setNeedsLayout()
    }

    /// Taps between the times reach the text view (to place the caret).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        buttons.contains { $0.frame.contains(point) && $0.isUserInteractionEnabled }
    }
}
#endif
