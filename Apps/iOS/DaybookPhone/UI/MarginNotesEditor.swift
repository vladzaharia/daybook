import DaybookKit
import SwiftUI
import UIKit

/// The person's notes as free text, with each paragraph's recording time in a lane on the left,
/// as on the Mac (where `MarginNotesEditor` is AppKit). Shared by the conversation page and the
/// recorder, so it knows nothing about either: it edits a string and draws the times it's given.
///
/// - `times` are the recording times of the nonempty paragraphs, in order: `Meeting.paragraphTimes()`
///   on a page, or `NoteTimeline.paragraphTimes(anchors:text:)` while recording. Paragraphs are split
///   exactly as DaybookCore's `NoteTimeline` splits them (any newline, blank ones skipped), so
///   `times[n]` always lands on the paragraph it belongs to; a paragraph without a time shows none.
/// - Inside a page (`scrolls == false`) it sizes itself to its text, so the page scrolls as one
///   document and keeps the caret above the keyboard. With `scrolls` it scrolls on its own.
/// - Times are buttons when `playTime` is set (the page plays from there), plain text otherwise.
/// - Text follows Dynamic Type, and the lane widens with it.
struct MarginNotesEditor: UIViewRepresentable {
    @Binding var text: String
    var times: [TimeInterval?]
    var placeholder = "Add a note…"
    var textStyle: UIFont.TextStyle = .body
    /// The lane at the default text size; it grows with Dynamic Type. Zero hides the times.
    var lane: CGFloat = PhoneStyle.Page.lane
    var scrolls = false
    var isEditable = true
    var focusOnAppear = false
    /// When it scrolls: room under the last line, so it can clear a bar drawn over the bottom edge.
    var bottomInset: CGFloat = 0
    var playTime: ((TimeInterval) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MarginTextView {
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
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(view)
        view.setText(text)
        if focusOnAppear {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
        return view
    }

    func updateUIView(_ view: MarginTextView, context: Context) {
        context.coordinator.parent = self
        configure(view)
        view.isScrollEnabled = scrolls
        if scrolls, view.contentInset.bottom != bottomInset {
            view.contentInset.bottom = bottomInset
            view.verticalScrollIndicatorInsets.bottom = bottomInset
        }
        if view.text != text && !context.coordinator.isEditing {
            view.setText(text)
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarginTextView, context: Context) -> CGSize? {
        guard !scrolls, let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.height(forWidth: width))
    }

    private func configure(_ view: MarginTextView) {
        view.baseLane = lane
        view.textStyle = textStyle
        view.times = times
        view.placeholder = placeholder
        view.isEditable = isEditable
        view.playTime = playTime
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarginNotesEditor
        var isEditing = false
        init(_ parent: MarginNotesEditor) { self.parent = parent }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            parent.onFocusChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            parent.onFocusChange?(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? MarginTextView else { return }
            parent.text = view.text
            view.textDidChange()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? MarginTextView)?.keepCaretVisible()
        }
    }
}

/// The text view: TextKit 1, so each paragraph's first baseline can be read from the layout manager
/// the same way the Mac's gutter reads it.
final class MarginTextView: UITextView {
    var times: [TimeInterval?] = [] { didSet { if times != oldValue { setNeedsLayout() } } }
    var baseLane: CGFloat = PhoneStyle.Page.lane { didSet { if baseLane != oldValue { applyStyle() } } }
    var textStyle: UIFont.TextStyle = .body { didSet { if textStyle != oldValue { applyStyle() } } }
    var placeholder = "" { didSet { placeholderLabel.text = placeholder } }
    var playTime: ((TimeInterval) -> Void)? { didSet { gutter.playTime = playTime } }

    private let gutter = MarginGutterView()
    private let placeholderLabel = UILabel()

    init() {
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
        placeholderLabel.textColor = PhoneStyle.UIInk.faint
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

    /// The lane's width at the current text size; times are right-aligned 10 pt short of the text.
    var lane: CGFloat {
        guard baseLane > 0 else { return 0 }
        return min(baseLane * 1.9, UIFontMetrics(forTextStyle: .footnote).scaledValue(for: baseLane, compatibleWith: traitCollection))
    }

    private var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traitCollection) }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = PhoneStyle.Typeface.bodyLineSpacing
        paragraph.paragraphSpacing = bodyFont.pointSize * 0.45
        return [.font: bodyFont, .foregroundColor: PhoneStyle.UIInk.body, .paragraphStyle: paragraph]
    }

    func setText(_ value: String) {
        let selection = selectedRange
        textStorage.setAttributedString(NSAttributedString(string: value, attributes: attributes))
        let length = (value as NSString).length
        selectedRange = NSRange(location: min(selection.location, length), length: 0)
        textDidChange()
    }

    /// Typed notes draw in the page's Body ink, at the reader's text size.
    func applyStyle() {
        typingAttributes = attributes
        if textStorage.length > 0 {
            textStorage.beginEditing()
            textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
            textStorage.endEditing()
        }
        textContainerInset = UIEdgeInsets(top: 0, left: lane, bottom: 0, right: 0)
        placeholderLabel.font = bodyFont
        gutter.font = UIFont.monospacedDigitSystemFont(ofSize: UIFontMetrics(forTextStyle: .footnote)
            .scaledValue(for: 13, compatibleWith: traitCollection), weight: .regular)
        tintColor = PhoneStyle.UIInk.accent
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func textDidChange() {
        placeholderLabel.isHidden = !text.isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The height the text needs at a given width, to size the editor inside a page.
    func height(forWidth width: CGFloat) -> CGFloat {
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let placeholderHeight = text.isEmpty
            ? placeholderLabel.sizeThatFits(CGSize(width: max(40, width - lane), height: .greatestFiniteMagnitude)).height : 0
        return ceil(max(fitted, placeholderHeight, bodyFont.lineHeight))
    }

    override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else { return super.intrinsicContentSize }
        return CGSize(width: UIView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 320))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let placeholderWidth = max(40, bounds.width - lane)
        let size = placeholderLabel.sizeThatFits(CGSize(width: placeholderWidth, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(x: lane, y: textContainerInset.top, width: placeholderWidth, height: size.height)
        placeholderLabel.isHidden = !text.isEmpty
        layoutGutter()
    }

    /// Places each timed paragraph's time on its first line's baseline, right-aligned in the lane.
    private func layoutGutter() {
        let height = max(contentSize.height, bounds.height)
        gutter.frame = CGRect(x: 0, y: 0, width: lane, height: height)
        guard lane > 0, times.contains(where: { $0 != nil }) else {
            gutter.labels = []
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let text = self.text as NSString
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
                        let baseline = line.minY + layoutManager.location(forGlyphAt: glyph).y + textContainerInset.top
                        labels.append(.init(text: TimeLabel.short(time), baseline: baseline, time: time))
                    }
                }
                index += 1
            }
            guard separator.location != NSNotFound else { break }
            location = NSMaxRange(separator)
        }
        gutter.labels = labels
    }

    /// The times drawn in the lane, top to bottom, with their baselines (for tests and diagnostics).
    var laneTimes: [(text: String, baseline: CGFloat)] {
        layoutIfNeeded()
        return gutter.labels.map { ($0.text, $0.baseline) }
    }

    /// Keeps the caret above the keyboard when the page, not this view, scrolls.
    func keepCaretVisible() {
        guard !isScrollEnabled, isFirstResponder, let range = selectedTextRange else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroller = ancestor as? UIScrollView else { return }
        let caret = caretRect(for: range.end).insetBy(dx: 0, dy: -24)
        scroller.scrollRectToVisible(convert(caret, to: scroller), animated: true)
    }
}

/// The lane of times. Each time is a button when it can play (meta ink, link ink when pressed).
final class MarginGutterView: UIView {
    struct Label: Equatable { var text: String; var baseline: CGFloat; var time: TimeInterval }

    var labels: [Label] = [] { didSet { if labels != oldValue { rebuild() } } }
    var font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular) { didSet { if font != oldValue { rebuild() } } }
    var playTime: ((TimeInterval) -> Void)? { didSet { if (playTime == nil) != (oldValue == nil) { rebuild() } } }
    private var buttons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (button, label) in zip(buttons, labels) {
            let size = button.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
            // Hour-long times can be wider than a narrow lane; they shrink rather than run off the edge.
            let width = min(size.width, max(0, bounds.width - 10))
            button.frame = CGRect(x: bounds.width - 10 - width, y: label.baseline - font.ascender - 6,
                                  width: width, height: font.lineHeight + 12)
        }
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
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
                button.configuration?.baseForegroundColor = button.isHighlighted ? PhoneStyle.UIInk.link : PhoneStyle.UIInk.meta
            }
            button.contentHorizontalAlignment = .trailing
            button.isUserInteractionEnabled = playTime != nil
            button.accessibilityLabel = "Note at \(SpokenTime.format(label.time.rounded(.down)))"
            if playTime != nil { button.accessibilityHint = "Plays the recording from here." }
            button.accessibilityTraits = playTime == nil ? .staticText : .button
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
