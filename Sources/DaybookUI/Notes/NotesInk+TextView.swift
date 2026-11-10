#if os(iOS)
import DaybookCore
import DaybookDesign
import PencilKit
import UIKit

// The notes text view's handwriting (`NotesInk+UIKit.swift`). The view's own text holds one attachment character per
// block; `serializedText` is the same text with each block's paragraph back in place, which is what the notes are.

extension MarginTextView: UIScribbleInteractionDelegate, UIPencilInteractionDelegate, UIContextMenuInteractionDelegate {
    /// How close to a block's bottom the last stroke may come before the block makes more room.
    static let inkWritingRoom: CGFloat = 96
    /// The blank page under the last paragraph, when there's no more of the view to fill.
    static let inkTailHeight: CGFloat = 180
    static let inkRecognitionDelay: Duration = .milliseconds(900)

    /// The text as the notes hold it: each attachment back as its paragraph's words.
    public var serializedText: String {
        var output = ""
        let string = textStorage.string as NSString
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length), options: []) { value, range, _ in
            if let attachment = value as? InkAttachment {
                if attachment === inkGap?.attachment {
                    // Nothing written in it yet: not a paragraph of the notes, nor is the line break that opened it.
                    if output.hasSuffix("\n") { output.removeLast() }
                } else {
                    output += attachment.paragraphText
                }
            } else {
                // A pasted attachment arrives as a bare character: it isn't anything in the notes.
                output += string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return output
    }

    /// The attachments in the text, in order, with their character positions.
    var inkAttachments: [(attachment: InkAttachment, location: Int)] {
        var found: [(InkAttachment, Int)] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length), options: []) { value, range, _ in
            if let attachment = value as? InkAttachment { found.append((attachment, range.location)) }
        }
        return found
    }

    var inkAccessibilityItems: [Any] {
        inkAttachments.compactMap { inkViews[$0.attachment.inkID] }
    }

    /// `value` as the view shows it: the paragraphs with ink replaced by their attachments.
    func displayString(for value: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: value, attributes: attributes)
        guard let placements = ink?.placements, placements.contains(where: { $0 != nil }) else { return result }
        let ns = value as NSString
        let ranges = NoteParagraphs.ranges(in: ns)
        for (index, range) in ranges.enumerated().reversed() where index < placements.count {
            guard let block = placements[index] else { continue }
            let attachment = InkAttachment(block: block, paragraphText: ns.substring(with: range))
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
            result.replaceCharacters(in: range, with: replacement)
        }
        return result
    }

    /// Brings the attachments in line with the notes, before the text is compared: a block's words changing (or a paragraph
    /// of words corrected on another device) needs no rebuild, which would end whatever is being written.
    public func syncInk(with value: String) {
        guard let placements = ink?.placements else { return }
        let wanted = placements.compactMap { $0?.id }
        let attachments = inkAttachments.filter { $0.attachment !== inkGap?.attachment }
        guard wanted == attachments.map(\.attachment.inkID) else {
            // Handwriting became words, was deleted, or came back: a dissolve, not a jump.
            crossfading { [weak self] in self?.setText(value) }
            return
        }
        guard !attachments.isEmpty else { return }
        let ns = value as NSString
        let ranges = NoteParagraphs.ranges(in: ns)
        var next = 0
        for (index, block) in placements.enumerated() where block != nil && index < ranges.count {
            attachments[next].attachment.paragraphText = ns.substring(with: ranges[index])
            next += 1
        }
    }

    func inkModelChanged() {
        guard let ink else {
            inkViews.values.forEach { $0.removeFromSuperview() }
            inkViews = [:]
            tailView?.removeFromSuperview()
            tailView = nil
            return
        }
        if observedSession !== ink.session { adoptSession(ink.session) }
        for block in ink.placements.compactMap({ $0 }) { inkViews[block.id]?.load(block) }
        recognizeWhatsUnread(ink.placements.compactMap { $0 })
        applySession()
    }

    private func adoptSession(_ session: InkSession) {
        observedSession = session
        session.onChange = { [weak self] in self?.applySession() }
        session.focusWords = { [weak self] in self?.focusWordsAtEnd() }
        NotificationCenter.default.addObserver(self, selector: #selector(undoStackChanged), name: .NSUndoManagerCheckpoint, object: nil)
        if interactions.contains(where: { $0 is UIScribbleInteraction }) == false {
            addInteraction(UIScribbleInteraction(delegate: self))
            addInteraction(UIPencilInteraction(delegate: self))
        }
    }

    @objc private func undoStackChanged() { observedSession?.refreshUndo() }

    /// Back to typing: at the caret if the words had one, else after the last paragraph.
    private func focusWordsAtEnd() {
        if !hadWordsFocus { selectedRange = NSRange(location: textStorage.length, length: 0) }
        becomeFirstResponder()
    }

    /// Whether the page past the last paragraph takes the pen just now.
    private var tailAccepts: Bool {
        guard let session = ink?.session, isEditable else { return false }
        return session.isWriting || session.pencilActive || UIScribbleInteraction.isPencilInputExpected || UIPencilInteraction.prefersPencilOnlyDrawing
    }

    /// What the session says, on every canvas.
    func applySession() {
        guard let session = ink?.session else { return }
        session.undoManager = undoManager
        if session.isWriting, !wasWritingByHand, isFirstResponder { openInkGap() }
        wasWritingByHand = session.isWriting
        if session.isWriting, isFirstResponder { resignFirstResponder() }
        if !session.showsTools { closeInkGap() }
        for scroller in scrollersUpTheTree { scroller.panGestureRecognizer.minimumNumberOfTouches = session.isWriting ? 2 : 1 }
        if wasShowingInkTools, !session.showsTools { crossfading { [weak self] in self?.trimBlocks() } }
        wasShowingInkTools = session.showsTools
        session.refreshUndo()
        for view in Array(inkViews.values) + [tailView].compactMap({ $0 }) {
            view.apply(tool: session.tool.pencilTool, fingerDraws: session.isWriting, interactive: isEditable, live: session.showsTools)
        }
        updateInkKeyboardBar()
        setNeedsLayout()
    }

    /// The words have the focus again: the tools go, and blocks give back the room they were keeping.
    func textTookFocus() {
        hadWordsFocus = true
        guard let session = ink?.session else { return }
        session.isWriting = false
        session.pencilActive = false
    }

    /// This view and the scroll views it's inside: a finger that writes leaves one-finger scrolling to none of them.
    private var scrollersUpTheTree: [UIScrollView] {
        var found: [UIScrollView] = [self]
        var ancestor = superview
        while let view = ancestor {
            if let scroller = view as? UIScrollView { found.append(scroller) }
            ancestor = view.superview
        }
        return found
    }

    /// A change to the page's layout that isn't under the pen, as a short dissolve.
    private func crossfading(_ change: @escaping () -> Void) {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            change()
            return
        }
        UIView.transition(with: self, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            change()
            self.layoutIfNeeded()
        }
    }

    /// The text to write to the notes after an edit, once what the edit did to the ink is settled. Nil while text is being
    /// composed on a block's line: it isn't the paragraph's, and goes on a line of its own when the composing ends.
    public func textToWriteBack() -> String? {
        guard !markedTextTouchesInk else { return nil }
        keepInkOnItsOwnLines()
        settleInkAfterEdit()
        return serializedText
    }

    private var markedTextTouchesInk: Bool {
        guard let marked = markedTextRange else { return false }
        let start = offset(from: beginningOfDocument, to: marked.start), length = offset(from: marked.start, to: marked.end)
        let line = (textStorage.string as NSString).paragraphRange(for: NSRange(location: start, length: length))
        return inkAttachments.contains { NSLocationInRange($0.location, line) }
    }

    /// An edit that took a block out of the text (delete, cut, typing over a selection) takes it out of the notes before
    /// the anchors are reconciled, or the typed words would inherit its paragraph. Undo brings the attachment back, and it
    /// comes back to the notes the same way.
    private func settleInkAfterEdit() {
        guard let ink else { return }
        let present = Set(inkAttachments.map(\.attachment.inkID))
        let known = Set(ink.placements.compactMap { $0?.id })
        guard present != known else { return }
        for id in known.subtracting(present) {
            pendingRecognition.removeValue(forKey: id)?.cancel()
            if let undo = ink.remove(id, false) { undoVanishedInk[id] = undo }
        }
        for id in present.subtracting(known) where id != inkGap?.view.id {
            undoVanishedInk.removeValue(forKey: id)?()
        }
        syncInkViews()
    }

    /// Typing right beside a block goes on a line of its own, in the one edit so that Undo takes it back whole. Returns
    /// whether the text view should make the edit itself. Keyboards that compose are settled when the composing ends.
    public func allowsEdit(in range: NSRange, replacing replacement: String) -> Bool {
        guard !replacement.isEmpty, range.length == 0, markedTextRange == nil, !keyboardComposes else { return true }
        let length = textStorage.length
        let afterInk = range.location > 0 && range.location <= length
            && textStorage.attribute(.attachment, at: range.location - 1, effectiveRange: nil) is InkAttachment
        let beforeInk = range.location < length && textStorage.attribute(.attachment, at: range.location, effectiveRange: nil) is InkAttachment
        let leading = afterInk && !replacement.hasPrefix("\n") ? "\n" : ""
        let trailing = beforeInk && !replacement.hasSuffix("\n") ? "\n" : ""
        guard !(leading + trailing).isEmpty, let start = position(from: beginningOfDocument, offset: range.location),
              let target = textRange(from: start, to: start) else { return true }
        replace(target, withText: leading + replacement + trailing)
        selectedRange = NSRange(location: range.location + (leading + replacement).utf16.count, length: 0)
        return false
    }

    private var keyboardComposes: Bool {
        guard let language = textInputMode?.primaryLanguage else { return false }
        return ["zh", "ja", "ko"].contains { language.hasPrefix($0) }
    }

    /// Typing beside a block starts a new line, so a block stays a paragraph of its own.
    public func keepInkOnItsOwnLines() {
        guard markedTextRange == nil else { return }
        var inserted = false
        for (_, location) in inkAttachments.reversed() {
            let string = textStorage.string as NSString
            let after = location + 1
            if after < string.length, !CharacterSet.newlines.contains(UnicodeScalar(string.character(at: after)) ?? " ") {
                insertBreak(at: after)
                inserted = true
            }
            if location > 0, !CharacterSet.newlines.contains(UnicodeScalar(string.character(at: location - 1)) ?? " ") {
                insertBreak(at: location)
                inserted = true
            }
        }
        if inserted { setNeedsLayout() }
    }

    private func insertBreak(at location: Int) {
        let selection = selectedRange
        textStorage.replaceCharacters(in: NSRange(location: location, length: 0), with: NSAttributedString(string: "\n", attributes: attributes))
        selectedRange = NSRange(location: selection.location + (selection.location >= location ? 1 : 0), length: selection.length)
    }

    // MARK: Canvases

    /// One canvas per attachment; the rest go.
    func syncInkViews() {
        guard let ink else { return }
        let blocks = Dictionary(ink.placements.compactMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let attachments = inkAttachments
        let present = Set(attachments.map(\.attachment.inkID))
        for (id, view) in inkViews where !present.contains(id) {
            view.removeFromSuperview()
            inkViews[id] = nil
        }
        for (attachment, _) in attachments where inkViews[attachment.inkID] == nil {
            let view = makeInkView(id: attachment.inkID, authoredWidth: attachment.inkWidth)
            inkViews[attachment.inkID] = view
            if let block = blocks[attachment.inkID] { view.load(block) }
        }
        applySession()
        recognizeWhatsUnread(ink.placements.compactMap { $0 })
    }

    private func makeInkView(id: UUID = UUID(), authoredWidth: CGFloat) -> InkBlockView {
        let view = InkBlockView(id: id, authoredWidth: authoredWidth)
        view.began = { [weak self] _ in self?.penTouched() }
        view.changed = { [weak self] view in self?.blockChanged(view) }
        view.addInteraction(UIContextMenuInteraction(delegate: self))
        addSubview(view)
        if let session = ink?.session {
            view.apply(tool: session.tool.pencilTool, fingerDraws: session.isWriting, interactive: isEditable, live: session.showsTools)
        }
        return view
    }

    private func penTouched() {
        guard let session = ink?.session else { return }
        if !session.isWriting { session.pencilActive = true }
    }

    func layoutInk() {
        guard ink != nil else { return }
        layoutManager.ensureLayout(for: textContainer)
        for (attachment, location) in inkAttachments {
            guard let view = inkViews[attachment.inkID] else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            guard glyph < layoutManager.numberOfGlyphs else { continue }
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let size = layoutManager.attachmentSize(forGlyphAt: glyph)
            let top = line.minY + layoutManager.location(forGlyphAt: glyph).y - size.height + textContainerInset.top
            let frame = CGRect(x: textContainerInset.left + line.minX, y: top, width: line.width, height: size.height)
            if view.frame != frame { view.frame = frame }
        }
        layoutTail()
    }

    private func layoutTail() {
        let next = nextLineRect
        let room = isScrollEnabled ? max(0, bounds.height - next.minY - contentInset.bottom) : 0
        let height = tailAccepts ? max(Self.inkTailHeight, room) : room
        let inset = tailAccepts ? height : 0
        if abs(textContainerInset.bottom - inset) > 0.5 {
            setTailInset(inset)
        }
        guard height > 1, isEditable else {
            tailView?.removeFromSuperview()
            tailView = nil
            return
        }
        let width = max(1, bounds.width - textContainerInset.left)
        if tailView == nil {
            let view = makeInkView(authoredWidth: width)
            view.lettingFingersThrough = true
            view.accessibilityElementsHidden = true
            view.isAccessibilityElement = false
            tailView = view
        }
        tailView?.authoredWidth = width
        tailView?.frame = CGRect(x: textContainerInset.left, y: next.minY, width: width, height: height)
    }

    private func setTailInset(_ inset: CGFloat) {
        updateTailInset(inset)
        invalidateIntrinsicContentSize()
        superview?.invalidateIntrinsicContentSize()
    }

    /// Write by Hand with the caret in a paragraph opens a space right after it, pushing what follows down. After the last
    /// paragraph there's no need: the page past it is already there.
    private func openInkGap() {
        guard inkGap == nil else { return }
        let ranges = NoteParagraphs.ranges(in: textStorage.string as NSString)
        guard let index = NoteParagraphs.paragraph(at: selectedRange.location, in: ranges), index < ranges.count - 1 else { return }
        let width = max(1, bounds.width - textContainerInset.left)
        let block = NoteInk(drawing: Data(), width: Double(width), height: Double(Self.inkTailHeight))
        let attachment = InkAttachment(block: block, paragraphText: "")
        let opening = NSMutableAttributedString(string: "\n", attributes: attributes)
        let character = NSMutableAttributedString(attachment: attachment)
        character.addAttributes(attributes, range: NSRange(location: 0, length: character.length))
        opening.append(character)
        crossfading { [weak self] in
            self?.textStorage.insert(opening, at: NSMaxRange(ranges[index]))
            self?.textDidChange()
        }
        let view = makeInkView(id: block.id, authoredWidth: width)
        inkViews[block.id] = view
        inkGap = (view, attachment, index)
        setNeedsLayout()
    }

    /// The writing ended with nothing in the space: it closes.
    private func closeInkGap() {
        guard let gap = inkGap, !gap.view.hasInk else { return }
        inkGap = nil
        gap.view.removeFromSuperview()
        inkViews[gap.view.id] = nil
        guard let location = inkAttachments.first(where: { $0.attachment === gap.attachment })?.location, location > 0 else { return }
        crossfading { [weak self] in
            self?.textStorage.replaceCharacters(in: NSRange(location: location - 1, length: 2), with: "")
            self?.textDidChange()
        }
    }

    /// The first stroke in the space makes it a paragraph of the notes.
    private func commitInkGap(_ gap: (view: InkBlockView, attachment: InkAttachment, after: Int)) {
        guard let ink else { return }
        let height = ceil(gap.view.inkBottom + Self.inkWritingRoom)
        let data = gap.view.canvas.drawing.dataRepresentation()
        gap.view.markSaved(data)
        let block = NoteInk(id: gap.view.id, drawing: data, width: Double(gap.view.authoredWidth), height: Double(height))
        inkGap = nil
        gap.attachment.paragraphText = block.paragraphText
        resize(gap.attachment, to: height)
        ink.add(block, gap.after)
        recognize(gap.view)
    }

    /// Strokes changed on a canvas: a block saves them; the empty page past the last paragraph becomes a new block.
    private func blockChanged(_ view: InkBlockView) {
        if let gap = inkGap, gap.view === view {
            if view.hasInk { commitInkGap(gap) }
            return
        }
        if view === tailView {
            guard view.hasInk else { return }
            adoptTail(view)
            return
        }
        guard view.hasInk else {
            // Everything was erased or undone: nothing left to keep a paragraph for.
            if let ink, let undo = ink.remove(view.id, false) { registerUndo(undo) }
            return
        }
        growIfNeeded(view)
        save(view)
    }

    private func growIfNeeded(_ view: InkBlockView) {
        guard let attachment = inkAttachments.first(where: { $0.attachment.inkID == view.id })?.attachment else { return }
        let needed = ceil(view.inkBottom + Self.inkWritingRoom)
        guard needed > attachment.inkHeight else { return }
        resize(attachment, to: needed)
    }

    private func resize(_ attachment: InkAttachment, to height: CGFloat) {
        attachment.inkHeight = height
        guard let location = inkAttachments.first(where: { $0.attachment === attachment })?.location else { return }
        let range = NSRange(location: location, length: 1)
        textStorage.beginEditing()
        textStorage.edited(.editedAttributes, range: range, changeInLength: 0)
        textStorage.endEditing()
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        invalidateIntrinsicContentSize()
        superview?.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The block's strokes and height go to the notes at each pen-up, and its words a moment after the writing pauses.
    private func save(_ view: InkBlockView) {
        guard let ink, let attachment = inkAttachments.first(where: { $0.attachment.inkID == view.id })?.attachment else { return }
        let data = view.canvas.drawing.dataRepresentation()
        view.markSaved(data)
        ink.update(NoteInk(id: view.id, drawing: data, width: Double(view.authoredWidth), height: Double(attachment.inkHeight),
                           recognized: view.recognized, updatedAt: Date()))
        recognize(view)
    }

    private func recognize(_ view: InkBlockView) {
        let id = view.id
        pendingRecognition[id]?.cancel()
        let drawing = view.canvas.drawing
        pendingRecognition[id] = Task { [weak self] in
            do { try await Task.sleep(for: Self.inkRecognitionDelay) } catch { return }
            let words = await InkRecognizer.text(in: drawing)
            guard !Task.isCancelled, let self else { return }
            self.pendingRecognition[id] = nil
            self.recognized(words, for: id)
        }
    }

    private func recognized(_ words: String?, for id: UUID) {
        guard let words else {
            // Nothing could read it: not tried again until more strokes come.
            unreadable.insert(id)
            return
        }
        unreadable.remove(id)
        guard let ink, let view = inkViews[id], view.recognized != words,
              let attachment = inkAttachments.first(where: { $0.attachment.inkID == id })?.attachment else { return }
        view.recognized = words
        // At once, so a keystroke before SwiftUI's next update can't write the old words back.
        attachment.paragraphText = NoteInk.paragraph(for: words)
        ink.update(NoteInk(id: id, drawing: view.savedDrawing, width: Double(view.authoredWidth), height: Double(attachment.inkHeight),
                           recognized: words, updatedAt: Date()))
    }

    /// Ink that arrived unread (a recognizer that failed, a device that couldn't read it) is read once it's on the page.
    private func recognizeWhatsUnread(_ blocks: [NoteInk]) {
        for block in blocks where block.recognized == nil && pendingRecognition[block.id] == nil && !unreadable.contains(block.id) {
            guard let view = inkViews[block.id], view.hasInk else { continue }
            recognize(view)
        }
    }

    /// The first stroke past the last paragraph makes it a block: the canvas stays where it is, under the pen, and a new
    /// empty one takes its place below. TextKit decides exactly where the block's line lands, so the strokes shift by the
    /// difference and the ink doesn't move on the page.
    private func adoptTail(_ view: InkBlockView) {
        guard let ink else { return }
        let height = ceil(view.inkBottom + Self.inkWritingRoom)
        let top = view.frame.minY
        tailView = nil
        view.lettingFingersThrough = false
        view.isAccessibilityElement = true
        view.accessibilityElementsHidden = false
        inkViews[view.id] = view
        appendAttachment(for: NoteInk(id: view.id, drawing: Data(), width: Double(view.authoredWidth), height: Double(height)))
        layoutInk()
        view.shiftInk(byY: top - view.frame.minY)
        let data = view.canvas.drawing.dataRepresentation()
        view.markSaved(data)
        ink.add(NoteInk(id: view.id, drawing: data, width: Double(view.authoredWidth), height: Double(height)), nil)
        recognize(view)
        setNeedsLayout()
    }

    private func appendAttachment(for block: NoteInk) {
        let string = textStorage.string
        let breaks = string.isEmpty || string.hasSuffix("\n") ? "" : "\n"
        let result = NSMutableAttributedString(string: breaks, attributes: attributes)
        let attachment = NSMutableAttributedString(attachment: InkAttachment(block: block, paragraphText: block.paragraphText))
        attachment.addAttributes(attributes, range: NSRange(location: 0, length: attachment.length))
        result.append(attachment)
        textStorage.append(result)
        textDidChange()
    }

    /// Blocks written in keep a little under their last stroke, once the writing has moved on.
    private func trimBlocks() {
        guard let ink else { return }
        for (attachment, _) in inkAttachments {
            guard let view = inkViews[attachment.inkID], view.hasInk else { continue }
            let trimmed = ceil(view.inkBottom + 12)
            guard trimmed < attachment.inkHeight - 1 else { continue }
            resize(attachment, to: trimmed)
            ink.update(NoteInk(id: view.id, drawing: view.savedDrawing, width: Double(view.authoredWidth), height: Double(trimmed),
                               recognized: view.recognized, updatedAt: Date()))
        }
    }

    private func registerUndo(_ undo: @escaping () -> Void) {
        undoManager?.registerUndo(withTarget: self) { _ in undo() }
        ink?.session.refreshUndo()
    }

    // MARK: Tests and diagnostics

    /// Each block's canvas frame and ID, top to bottom.
    public var laneInk: [(id: UUID, frame: CGRect, zoom: CGFloat)] {
        layoutIfNeeded()
        inkViews.values.forEach { $0.layoutIfNeeded() }
        return inkAttachments.compactMap { attachment, _ in
            inkViews[attachment.inkID].map { (attachment.inkID, $0.frame, $0.canvas.transform.a) }
        }
    }

    /// Each block's canvas, top to bottom.
    public var inkCanvases: [PKCanvasView] {
        layoutIfNeeded()
        return inkAttachments.compactMap { attachment, _ in inkViews[attachment.inkID]?.canvas }
    }

    /// The canvas past the last paragraph, when there's room for one.
    public var inkTailCanvas: PKCanvasView? {
        layoutIfNeeded()
        return tailView?.canvas
    }

    public var inkTailFrame: CGRect? {
        layoutIfNeeded()
        return tailView?.frame
    }

    // MARK: Interactions

    /// Scribble writes into the words; the canvases keep Apple Pencil over ink and the page past the last paragraph.
    public func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        !(Array(inkViews.values) + [tailView].compactMap { $0 }).contains { $0.frame.contains(location) }
    }

    public func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction == .switchEraser else { return }
        ink?.session.toggleEraser()
    }

    /// A block's menu, on a long press: never while a finger is writing, or over the page with nothing on it.
    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                       configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let view = interaction.view as? InkBlockView, view !== tailView, ink?.session.isWriting != true, let ink else { return nil }
        let words = view.recognized?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = view.id
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIAction] = []
            if !words.isEmpty {
                actions.append(UIAction(title: "Convert to Text", image: UIImage(systemName: "text.cursor")) { _ in
                    if let undo = ink.remove(id, true) { self?.registerUndo(undo) }
                })
                actions.append(UIAction(title: "Copy Text", image: UIImage(systemName: "doc.on.doc")) { _ in
                    // This iPhone only, as every copy of a conversation's words is (`LocalCopy`).
                    LocalCopy.copy(words)
                })
            }
            actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                if let undo = ink.remove(id, false) { self?.registerUndo(undo) }
            })
            return UIMenu(children: actions)
        }
    }
}
#endif
