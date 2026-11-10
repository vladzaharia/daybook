import DaybookCore
import DaybookKit
import DaybookUI
import PencilKit
import UIKit
import XCTest

@testable import DaybookPhone

@MainActor
final class NotesInkEditorTests: XCTestCase {
    // MARK: Reading the ink

    /// Regression: `PKDrawing.image` draws for the current traits, so in Dark Mode the "dark ink on white" picture for
    /// Vision was white on white and every recognition came back empty.
    func testBehaviorThePictureOfTheInkIsDarkOnWhiteInDarkMode() throws {
        let drawing = SyntheticInk.drawing("hello world")
        var image: CGImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            image = InkRecognizer.image(of: drawing)
        }
        XCTAssertGreaterThan(darkFraction(try XCTUnwrap(image)), 0.01, "the strokes are there to read")
    }

    func testBehaviorHandwritingIsRead() async throws {
        let words = await InkRecognizer.text(in: SyntheticInk.drawing("hello world"))
        XCTAssertEqual(words?.lowercased().contains("hello"), true, "read \(words ?? "nothing")")
    }

    /// Regression: one shared recognizer holds one drawing, so two blocks read at once swapped words.
    func testBehaviorTwoBlocksReadAtOnceKeepTheirOwnWords() async throws {
        async let hello = InkRecognizer.text(in: SyntheticInk.drawing("hello"))
        async let world = InkRecognizer.text(in: SyntheticInk.drawing("world"))
        let (first, second) = await (hello, world)
        XCTAssertEqual(first?.lowercased().contains("hello"), true, "read \(first ?? "nothing")")
        XCTAssertEqual(second?.lowercased().contains("world"), true, "read \(second ?? "nothing")")
    }

    func testBehaviorEmptyInkHasNoWords() async {
        let words = await InkRecognizer.text(in: PKDrawing())
        XCTAssertEqual(words, "")
    }

    // MARK: The note holds both

    func testBehaviorInkSitsBetweenTypedParagraphsAndTheNotesStayWords() throws {
        let (view, _) = makeEditor()
        let block = ink(recognized: "hello world", width: 200, height: 140)
        let notes = "Before\nhello world\nAfter"
        view.ink = model(view.ink?.session, placements: [nil, block, nil])
        view.setText(notes)

        XCTAssertEqual(view.text, "Before\n\u{FFFC}\nAfter", "the view holds one character for the block")
        XCTAssertEqual(view.serializedText, notes, "the notes are still words")
        let drawn = try XCTUnwrap(view.laneInk.first)
        XCTAssertEqual(drawn.id, block.id)
        XCTAssertEqual(drawn.frame.height, 140)
        XCTAssertGreaterThan(drawn.frame.minY, view.font?.lineHeight ?? 0, "below the first paragraph")

        // The paragraph after it starts below it.
        let after = (view.text as NSString).range(of: "After")
        let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: after.location))
        XCTAssertGreaterThanOrEqual(view.caretRect(for: position).minY, drawn.frame.maxY - 1)
    }

    func testBehaviorTypingAboveInkMovesItDown() throws {
        let (view, _) = makeEditor()
        view.ink = model(view.ink?.session, placements: [nil, ink(recognized: "hello", height: 100)])
        view.setText("One\nhello")
        let before = try XCTUnwrap(view.laneInk.first).frame.minY
        view.ink = model(view.ink?.session, placements: [nil, nil, nil, ink(recognized: "hello", height: 100)])
        view.setText("One\nTwo\nThree\nhello")
        XCTAssertGreaterThan(try XCTUnwrap(view.laneInk.first).frame.minY, before)
    }

    func testBehaviorTypingBesideInkKeepsItAParagraphOfItsOwn() {
        let (view, _) = makeEditor()
        view.ink = model(view.ink?.session, placements: [ink(recognized: "hello", height: 100)])
        view.setText("hello")
        view.selectedRange = NSRange(location: 1, length: 0)
        view.textStorage.replaceCharacters(in: view.selectedRange, with: NSAttributedString(string: "typed", attributes: view.typingAttributes))
        view.selectedRange = NSRange(location: 6, length: 0)
        view.keepInkOnItsOwnLines()
        XCTAssertEqual(view.serializedText, "hello\ntyped")
        XCTAssertEqual(view.selectedRange.location, 7, "the caret stays after what was typed")
    }

    /// Typing beside a block is one edit, so Undo takes the line break and the words back together.
    func testBehaviorTypingRightAfterInkIsOneEditOnItsOwnLine() throws {
        let (view, _) = makeEditor()
        let window = hostingWindow(view)
        defer { window.isHidden = true }
        view.ink = model(view.ink?.session, placements: [ink(recognized: "hello", height: 100)])
        view.setText("hello")
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 1, length: 0)
        XCTAssertFalse(view.allowsEdit(in: view.selectedRange, replacing: "t"), "made here, with its line break")
        XCTAssertEqual(view.serializedText, "hello\nt")
        XCTAssertEqual(view.selectedRange.location, 3, "the caret follows what was typed")
        XCTAssertTrue(view.allowsEdit(in: view.selectedRange, replacing: "y"), "further along the line, an ordinary edit")
    }

    func testBehaviorTypingRightBeforeInkGoesAboveIt() throws {
        let (view, _) = makeEditor()
        let window = hostingWindow(view)
        defer { window.isHidden = true }
        view.ink = model(view.ink?.session, placements: [ink(recognized: "hello", height: 100)])
        view.setText("hello")
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(view.allowsEdit(in: view.selectedRange, replacing: "t"))
        XCTAssertEqual(view.serializedText, "t\nhello")
        XCTAssertEqual(view.selectedRange.location, 1, "still on the line being typed")
    }

    /// Regression: composing right after a block wrote every composition state into the block's paragraph.
    func testBehaviorComposingBesideInkWaitsForTheComposingToEnd() throws {
        let (view, _) = makeEditor()
        let window = hostingWindow(view)
        defer { window.isHidden = true }
        view.ink = model(view.ink?.session, placements: [ink(recognized: "hello", height: 100)])
        view.setText("hello")
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 1, length: 0)
        view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNil(view.textToWriteBack(), "nothing reaches the notes yet")
        view.unmarkText()
        XCTAssertEqual(view.textToWriteBack(), "hello\nk", "then it goes on its own line")
    }

    /// Regression: a block deleted with the text left its canvas floating where it was.
    func testBehaviorDeletingABlockWithTheTextTakesItOutEverywhere() throws {
        let (view, log) = makeEditor()
        let block = ink(recognized: "hello", height: 100)
        view.ink = model(view.ink?.session, placements: [nil, block, nil], log: log)
        view.setText("One\nhello\nTwo")
        XCTAssertEqual(view.laneInk.count, 1)

        view.textStorage.replaceCharacters(in: NSRange(location: 3, length: 2), with: "")
        XCTAssertEqual(view.textToWriteBack(), "One\nTwo")
        XCTAssertEqual(log.removed.map(\.id), [block.id], "out of the notes before the anchors are reconciled")
        XCTAssertEqual(view.laneInk.count, 0)
        XCTAssertTrue(view.inkCanvases.isEmpty)
    }

    /// Regression: typing over a selected block gave the typed words its paragraph, and the ink came back over them.
    func testBehaviorTypingOverABlockRetiresIt() throws {
        let (view, log) = makeEditor()
        let block = ink(recognized: "hello", height: 100)
        view.ink = model(view.ink?.session, placements: [block], log: log)
        view.setText("hello")
        view.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: NSAttributedString(string: "typed"))
        XCTAssertEqual(view.textToWriteBack(), "typed")
        XCTAssertEqual(log.removed.map(\.id), [block.id])
    }

    func testBehaviorUndoBringsADeletedBlockBack() throws {
        let (view, log) = makeEditor()
        let block = ink(recognized: "hello", height: 100)
        view.ink = model(view.ink?.session, placements: [nil, block], log: log)
        view.setText("One\nhello")
        let range = NSRange(location: 3, length: 2)
        let deleted = view.textStorage.attributedSubstring(from: range)
        view.textStorage.replaceCharacters(in: range, with: "")
        _ = view.textToWriteBack()
        // The model no longer holds it, as SwiftUI's next update would say.
        view.ink = model(view.ink?.session, placements: [nil], log: log)

        view.textStorage.insert(deleted, at: 3)
        XCTAssertEqual(view.textToWriteBack(), "One\nhello")
        XCTAssertEqual(log.restored, [block.id])
        XCTAssertEqual(view.inkCanvases.count, 1, "its canvas is back too")
    }

    func testBehaviorStyleChangesKeepTheInk() {
        let (view, _) = makeEditor()
        view.ink = model(view.ink?.session, placements: [ink(recognized: "hello", height: 100)])
        view.setText("hello")
        view.applyStyle()
        XCTAssertEqual(view.serializedText, "hello")
        XCTAssertEqual(view.laneInk.count, 1)
    }

    func testBehaviorTheTimeOfAnInkParagraphIsAtItsTop() throws {
        let (view, _) = makeEditor()
        view.ink = model(view.ink?.session, placements: [ink(recognized: "hello", height: 200)])
        view.times = [75]
        view.setText("hello")
        let drawn = try XCTUnwrap(view.laneInk.first)
        let time = try XCTUnwrap(view.laneTimes.first)
        XCTAssertEqual(time.text, "1:15")
        XCTAssertLessThan(time.baseline, drawn.frame.minY + 40, "beside the first line of writing, not under the block")
    }

    func testBehaviorANarrowerColumnScalesTheInkToFit() throws {
        let (view, _) = makeEditor(width: 200)
        view.baseLane = 0
        view.ink = model(view.ink?.session, placements: [ink(recognized: "hello", width: 400, height: 100)])
        view.setText("hello")
        let drawn = try XCTUnwrap(view.laneInk.first)
        XCTAssertEqual(drawn.frame.width, 200, accuracy: 0.5)
        XCTAssertEqual(drawn.frame.height, 50, accuracy: 1)
        XCTAssertEqual(drawn.zoom, 0.5, accuracy: 0.01)
        let canvas = try XCTUnwrap(view.inkCanvases.first)
        XCTAssertEqual(canvas.bounds.width, 400, accuracy: 0.5, "the canvas keeps the whole of what was written")
        XCTAssertEqual(canvas.bounds.height, 100, accuracy: 1, "nothing is cut off")
    }

    /// Regression: resetting the canvas's geometry at every layout asked for another layout, forever.
    func testBehaviorAScaledBlockSettlesAfterOneLayout() throws {
        let (view, _) = makeEditor(width: 200)
        view.baseLane = 0
        view.ink = model(view.ink?.session, placements: [ink(recognized: "hello", width: 400, height: 100)])
        view.setText("hello")
        _ = view.laneInk
        let block = try XCTUnwrap(view.inkCanvases.first?.superview)
        block.layoutIfNeeded()
        XCTAssertFalse(block.layer.needsLayout(), "nothing left to lay out")
        block.setNeedsLayout()
        block.layoutIfNeeded()
        XCTAssertFalse(block.layer.needsLayout(), "laying it out again changes nothing, so asks for nothing")
    }

    func testBehaviorAWiderColumnNeverEnlargesTheInk() throws {
        let (view, _) = makeEditor(width: 500)
        view.baseLane = 0
        view.ink = model(view.ink?.session, placements: [ink(recognized: "hello", width: 300, height: 100)])
        view.setText("hello")
        let drawn = try XCTUnwrap(view.laneInk.first)
        XCTAssertEqual(drawn.frame.height, 100, accuracy: 0.5)
        XCTAssertEqual(drawn.zoom, 1, accuracy: 0.01)
    }

    // MARK: Writing

    func testBehaviorTheFirstStrokePastTheWordsBecomesABlockInThatSpot() throws {
        for (notes, expected) in [("Before", "Before\n\(NoteInk.placeholder)"), ("Before\n", "Before\n\(NoteInk.placeholder)"), ("", NoteInk.placeholder)] {
            let (view, log) = makeEditor()
            view.ink?.session.isWriting = true
            view.setText(notes)
            let tail = try XCTUnwrap(view.inkTailFrame)
            let canvas = try XCTUnwrap(view.inkTailCanvas)

            let written = SyntheticInk.drawing("hello")
            let inkTop = written.bounds.minY
            canvas.drawing = written

            let block = try XCTUnwrap(log.added.first)
            XCTAssertNil(log.addedAfter.first ?? nil, "at the end of the notes")
            XCTAssertEqual(view.serializedText, expected)
            let drawn = try XCTUnwrap(view.laneInk.first)
            XCTAssertEqual(drawn.id, block.id)
            let onThePage = drawn.frame.minY + (try XCTUnwrap(view.inkCanvases.first)).drawing.bounds.minY
            XCTAssertEqual(onThePage, tail.minY + inkTop, accuracy: 2, "the ink doesn't move out from under the pen (notes: \(notes.debugDescription))")
            XCTAssertGreaterThan(try XCTUnwrap(view.inkTailFrame).minY, drawn.frame.minY, "a new empty page below it")
            XCTAssertFalse(try XCTUnwrap(view.inkTailCanvas) === canvas)
        }
    }

    func testBehaviorWritingFromTheCaretOpensASpaceAfterItsParagraph() throws {
        let (view, log) = makeEditor()
        let window = hostingWindow(view)
        defer { window.isHidden = true }
        view.setText("One\nTwo")
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 1, length: 0)

        view.ink?.session.isWriting = true
        XCTAssertEqual(view.text, "One\n\u{FFFC}\nTwo", "the space is in the column")
        XCTAssertEqual(view.serializedText, "One\nTwo", "and not yet in the notes")
        XCTAssertFalse(view.isFirstResponder, "the keyboard goes")

        let canvas = try XCTUnwrap(view.inkCanvases.first)
        canvas.drawing = SyntheticInk.drawing("hello")
        XCTAssertEqual(log.addedAfter.first ?? nil, 0, "after the caret's paragraph")
        XCTAssertEqual(view.serializedText, "One\n\(NoteInk.placeholder)\nTwo")
    }

    func testBehaviorASpaceNothingWasWrittenInCloses() throws {
        let (view, log) = makeEditor()
        let window = hostingWindow(view)
        defer { window.isHidden = true }
        view.setText("One\nTwo")
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 1, length: 0)
        let session = try XCTUnwrap(view.ink?.session)
        session.isWriting = true
        XCTAssertEqual(view.laneInk.count, 1)
        session.isWriting = false
        XCTAssertEqual(view.text, "One\nTwo")
        XCTAssertEqual(view.laneInk.count, 0)
        XCTAssertTrue(log.added.isEmpty)
    }

    func testBehaviorWritingFromTheLastParagraphUsesThePagePastIt() throws {
        let (view, _) = makeEditor()
        let window = hostingWindow(view)
        defer { window.isHidden = true }
        view.setText("One\nTwo")
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 7, length: 0)
        view.ink?.session.isWriting = true
        XCTAssertEqual(view.text, "One\nTwo", "no space needed")
        XCTAssertNotNil(view.inkTailCanvas)
    }

    func testBehaviorWritingNearTheBottomMakesMoreRoom() throws {
        let (view, log) = makeEditor()
        let block = ink(drawing: SyntheticInk.drawing("hello"), recognized: "hello", height: 100)
        view.ink = model(view.ink?.session, placements: [block], log: log)
        view.setText("hello")
        let canvas = try XCTUnwrap(view.inkCanvases.first)
        canvas.drawing = SyntheticInk.drawing("hello", origin: CGPoint(x: 20, y: 400))
        XCTAssertGreaterThan(try XCTUnwrap(view.laneInk.first).frame.height, canvas.drawing.bounds.maxY)
        XCTAssertEqual(log.updated.last?.id, block.id, "saved at the pen-up")
    }

    func testBehaviorErasingEverythingTakesTheParagraphOut() throws {
        let (view, log) = makeEditor()
        let block = ink(drawing: SyntheticInk.drawing("hello"), recognized: "hello", height: 100)
        view.ink = model(view.ink?.session, placements: [block], log: log)
        view.setText("hello")
        let canvas = try XCTUnwrap(view.inkCanvases.first)
        canvas.drawing = PKDrawing()
        XCTAssertEqual(log.removed.map(\.id), [block.id])
        XCTAssertEqual(log.removed.map(\.keepingWords), [false])
    }

    func testBehaviorAWordsChangeFromRecognitionDoesNotRebuildTheNote() throws {
        let (view, _) = makeEditor()
        var block = ink(recognized: nil, height: 100)
        view.ink = model(view.ink?.session, placements: [nil, block])
        view.setText("Before\n\(NoteInk.placeholder)")
        let before = try XCTUnwrap(view.laneInk.first?.id)
        view.selectedRange = NSRange(location: 3, length: 0)

        block.recognized = "hello world"
        view.ink = model(view.ink?.session, placements: [nil, block])
        view.syncInk(with: "Before\nhello world")

        XCTAssertEqual(view.serializedText, "Before\nhello world")
        XCTAssertEqual(view.selectedRange.location, 3, "the caret is where it was")
        XCTAssertEqual(view.laneInk.first?.id, before)
    }

    func testBehaviorAFingerWritingPutsTheKeyboardAwayAndPencilNeedsNoMode() throws {
        let (view, _) = makeEditor()
        view.setText("Before")
        let session = try XCTUnwrap(view.ink?.session)
        XCTAssertFalse(session.showsTools)
        session.isWriting = true
        XCTAssertTrue(session.showsTools)
        XCTAssertEqual(view.panGestureRecognizer.minimumNumberOfTouches, 2, "a finger writes, two scroll")
        XCTAssertEqual(try XCTUnwrap(view.inkTailCanvas).drawingPolicy, .anyInput)
        session.isWriting = false
        XCTAssertEqual(view.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertEqual(try XCTUnwrap(view.inkTailCanvas).drawingPolicy, .pencilOnly, "Apple Pencil still writes, fingers scroll")
    }

    func testBehaviorThePageWithoutAPencilAddsNoRoomInsideAPage() {
        let (view, _) = makeEditor()
        view.isScrollEnabled = false
        view.setText("Before")
        view.layoutIfNeeded()
        XCTAssertEqual(view.textContainerInset.bottom, 0, "a conversation's page doesn't grow a blank page for nothing")
    }

    // MARK: While recording

    func testBehaviorHandwritingWhileRecordingIsTimedJournaledAndFiled() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Notes")
        rig.pump(2)
        rig.recorder.editNotes("Earlier")
        rig.pump(3)
        let block = ink(recognized: "ship it", height: 100)
        rig.recorder.addInk(block, after: nil)
        XCTAssertEqual(rig.recorder.notes, "Earlier\nship it")
        XCTAssertEqual(rig.recorder.timedNotes.map(\.time), [2, 5])
        XCTAssertEqual(rig.recorder.timedNotes.last?.id, block.id)

        await rig.recorder.flush()
        let journal = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(journal.ink, [block], "a recording recovered after a crash keeps its handwriting")

        let recording = try await rig.stop()
        XCTAssertEqual(recording.ink, [block])

        let library = LibraryController(rootURL: try temporaryDirectory(), sync: nil)
        try await library.load()
        let id = library.newMeeting(title: "Notes")
        library.update(id) { meeting in
            meeting.addRecordingWork(trackID: UUID(), notes: recording.timedNotes, bookmarks: [], joining: false)
            meeting.adoptInk(recording.ink)
        }
        XCTAssertEqual(library.meeting(id)?.inkPlacements().map { $0?.id }, [nil, block.id])
    }

    func testBehaviorDeletingWhileRecordingCanBeUndone() async throws {
        let rig = RecorderRig()
        try await rig.recorder.start(in: try temporaryDirectory().appendingPathComponent("capture"), title: "Notes")
        rig.pump(2)
        let block = ink(recognized: "ship it", height: 100)
        rig.recorder.addInk(block, after: nil)
        let undo = try XCTUnwrap(rig.recorder.removeInk(block.id, keepingWords: false))
        XCTAssertEqual(rig.recorder.notes, "")
        undo()
        XCTAssertEqual(rig.recorder.notes, "ship it")
        XCTAssertEqual(NoteTimeline.inkPlacements(rig.recorder.ink, anchors: rig.recorder.timedNotes, text: rig.recorder.notes).first??.id, block.id)
        _ = try await rig.stop()
    }

    func testBehaviorHandwritingInAConversationSavesAndReopens() async throws {
        let library = LibraryController(rootURL: try temporaryDirectory(), sync: nil)
        try await library.load()
        let id = library.newMeeting(title: "Notes")
        library.editNotes(id, text: "Typed")
        let block = ink(drawing: SyntheticInk.drawing("hello"), recognized: "hello", height: 100)
        library.addInk(block, to: id, after: nil)
        await library.flush()

        let reopened = LibraryController(rootURL: library.rootURL, sync: nil)
        try await reopened.load()
        XCTAssertEqual(reopened.meeting(id)?.notes, "Typed\nhello")
        XCTAssertEqual(reopened.meeting(id)?.inkPlacements().map { $0?.id }, [nil, block.id])
        XCTAssertEqual(try PKDrawing(data: try XCTUnwrap(reopened.meeting(id)?.ink?.first?.drawing)).strokes.count, SyntheticInk.drawing("hello").strokes.count)
    }

    func testPostStopHandwritingSuspendsAndRestartsTheTenSecondLinger() async throws {
        let linger = AfterStopLinger()
        var didDismiss = false
        linger.update(stay: AfterStop.lingers, writing: false) { didDismiss = true }
        try await Task.sleep(for: .milliseconds(100))

        linger.update(stay: AfterStop.lingers, writing: true) { didDismiss = true }
        try await Task.sleep(for: AfterStop.lingers + .milliseconds(100))
        XCTAssertFalse(didDismiss, "the handwriting draft must outlive the normal ten-second linger")

        linger.update(stay: .milliseconds(20), writing: false) { didDismiss = true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(didDismiss, "putting the pen down restarts the linger")
    }

    // MARK: Helpers

    private final class Log {
        var added: [NoteInk] = []
        var addedAfter: [Int?] = []
        var updated: [NoteInk] = []
        var removed: [(id: UUID, keepingWords: Bool)] = []
        var restored: [UUID] = []
    }

    private func model(_ session: InkSession?, placements: [NoteInk?], log: Log = Log()) -> NotesInkModel {
        NotesInkModel(
            session: session ?? InkSession(), placements: placements,
            add: { log.added.append($0); log.addedAfter.append($1) },
            update: { log.updated.append($0) },
            remove: { id, keepingWords in
                log.removed.append((id, keepingWords))
                return { log.restored.append(id) }
            })
    }

    private func makeEditor(width: CGFloat = 360) -> (DaybookUI.MarginTextView, Log) {
        let view = DaybookUI.MarginTextView()
        view.frame = CGRect(x: 0, y: 0, width: width, height: 640)
        let log = Log()
        view.ink = model(InkSession(), placements: [], log: log)
        return (view, log)
    }

    private func ink(drawing: PKDrawing = PKDrawing(), recognized: String?, width: Double = 320, height: Double) -> NoteInk {
        NoteInk(drawing: drawing.dataRepresentation(), width: width, height: height, recognized: recognized, updatedAt: Date(timeIntervalSince1970: 100))
    }

    private func hostingWindow(_ view: UIView) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 700))
        window.addSubview(view)
        window.makeKeyAndVisible()
        return window
    }

    private func darkFraction(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var dark = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] < 128 { dark += 1 }
        return Double(dark) / Double(width * height)
    }
}
