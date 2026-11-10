import AppKit
import DaybookDesign
import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookUI

/// The notes editor both apps share: how the lane reads the notes' paragraphs, where the recording's marks go, and
/// what VoiceOver and the keyboard reach in it on the Mac.
@MainActor
final class MarginNotesEditorTests: XCTestCase {
    // MARK: Paragraphs

    func testBehaviorParagraphsSplitAsTheTimelineSplitsThem() {
        let text = "First\n\n  \nSecond line\r\nThird" as NSString
        let ranges = NoteParagraphs.ranges(in: text)
        XCTAssertEqual(ranges.map { text.substring(with: $0) }, ["First", "Second line", "Third"], "blank lines aren't paragraphs")
        XCTAssertEqual(NoteParagraphs.ranges(in: "" as NSString), [])
    }

    /// A bookmark or photo goes before the first paragraph written after it; after the last when nothing was.
    func testBehaviorMarksSitBeforeTheParagraphWrittenAfterThem() {
        let times: [TimeInterval?] = [2, nil, 10]
        let marks = [NoteMark(id: "late", kind: .bookmark, time: 12), NoteMark(id: "early", kind: .bookmark, time: 4),
                     NoteMark(id: "photo", kind: .photo, time: 6)]
        let placed = NoteParagraphs.placement(of: marks, times: times)
        XCTAssertEqual(placed.map(\.mark.id), ["early", "photo", "late"], "in time order")
        XCTAssertEqual(placed.map(\.before), [2, 2, 3], "before the 0:10 paragraph, and after the last")
        XCTAssertEqual(NoteMark(id: "b", kind: .bookmark, time: 250).spoken, "Bookmark at \(SpokenTime.format(250))")
    }

    /// A bookmark after the last paragraph has nothing written beside it, so it says "Bookmark" there, as its row in
    /// the summary does; one beside a paragraph has that paragraph's words, and a photo shows itself.
    func testBehaviorOnlyABookmarkAfterTheLastParagraphIsWordless() {
        let times: [TimeInterval?] = [2, nil, 10]
        let marks = [NoteMark(id: "late", kind: .bookmark, time: 12), NoteMark(id: "early", kind: .bookmark, time: 4),
                     NoteMark(id: "photo", kind: .photo, time: 14)]
        let wordless = NoteParagraphs.placement(of: marks, times: times)
            .filter { NoteParagraphs.isWordless($0.mark, before: $0.before, paragraphs: times.count) }
        XCTAssertEqual(wordless.map(\.mark.id), ["late"])
        XCTAssertFalse(NoteParagraphs.isWordless(marks[0], before: 3, paragraphs: 4), "a paragraph written after it, untimed, is its words")
        XCTAssertEqual(BookmarkLabel.untitled, "Bookmark")
        XCTAssertEqual(BookmarkLabel.placeholder(for: Highlight(time: 4, text: ""), in: Meeting(title: "Call")), BookmarkLabel.untitled,
                       "the summary's row says the same word")
    }

    func testBehaviorPlayFromHerePlaysTheParagraphAtTheCaretOrTheOneBeforeIt() {
        let text = "Intro\nUntimed\nLater" as NSString
        let ranges = NoteParagraphs.ranges(in: text)
        let times: [TimeInterval?] = [5, nil, 40]
        XCTAssertEqual(NoteParagraphs.playTime(at: 2, ranges: ranges, times: times), 5)
        XCTAssertEqual(NoteParagraphs.playTime(at: 8, ranges: ranges, times: times), 5, "an untimed paragraph plays from the one before it")
        XCTAssertEqual(NoteParagraphs.playTime(at: text.length, ranges: ranges, times: times), 40)
        XCTAssertNil(NoteParagraphs.playTime(at: 0, ranges: ranges, times: [nil, nil, nil]))
    }

    func testBehaviorTheSearchsMatchesAreFoundWhateverTheirCaseAndAccents() {
        let text = "Beta date, then the BETA list and the bêta." as NSString
        XCTAssertEqual(NoteParagraphs.matches(of: "beta", in: text).map { text.substring(with: $0) }, ["Beta", "BETA", "bêta"])
        XCTAssertEqual(NoteParagraphs.matches(of: "  ", in: text), [], "no query, no marks")
    }

    // MARK: Writing Tools

    /// The notes as the app keeps them while recording: each change reconciled against the anchors, with the
    /// recording's time for new paragraphs (`AppState.editNotes`, `PhoneRecorder.editNotes`).
    private final class RecordingNotes {
        var text: String
        var anchors: [TimedNote]
        let elapsed: TimeInterval

        init(_ text: String, at time: TimeInterval, elapsed: TimeInterval) {
            self.text = text
            anchors = NoteTimeline.reconcile(previous: [], text: text, captureTime: time)
            self.elapsed = elapsed
        }

        var binding: Binding<String> {
            Binding(get: { self.text }, set: { text in
                self.anchors = NoteTimeline.reconcile(previous: self.anchors, text: text,
                                                      captureTime: NoteTimeline.captureTime(recording: self.elapsed))
                self.text = text
            })
        }
    }

    /// Regression: during a recording, Writing Tools' rewrite (Key Points, a list) came back as new paragraphs, each
    /// stamped with the moment of the rewrite. A rewrite is the notes reworded, not notes taken then: what it adds
    /// gets no time, and a paragraph it rewords keeps its own. Typing afterwards is timed again.
    func testBehaviorAWritingToolsRewriteDuringARecordingTimesNothingNew() {
        let notes = RecordingNotes("Launch is two weeks out", at: 30, elapsed: 95)
        let coordinator = MarginNotesEditor(text: notes.binding, times: []).makeCoordinator()

        coordinator.hand("Launch is two weeks out, on the 24th\nAnnual plan leads the pricing page", rewriting: true)
        XCTAssertEqual(notes.anchors.map(\.time), [30, nil], "the reworded paragraph keeps its time; the new one gets none")
        XCTAssertFalse(NoteTimeline.isRewriting, "only while the rewrite is handed on")

        coordinator.hand(notes.text + "\nShip the beta Friday", rewriting: false)
        XCTAssertEqual(notes.anchors.map(\.time), [30, nil, 95], "typing is timed")
    }

    /// Writing Tools leaves attachments alone (the iPhone's handwriting blocks); the Mac's plain notes have none.
    func testBehaviorWritingToolsLeavesAttachmentsAlone() {
        let text = NSMutableAttributedString(string: "Before\n")
        text.append(NSAttributedString(attachment: NSTextAttachment()))
        text.append(NSAttributedString(string: "\nAfter"))
        let all = NSRange(location: 0, length: text.length)
        XCTAssertEqual(NoteParagraphs.attachments(in: text, within: all), [NSRange(location: 7, length: 1)])
        XCTAssertEqual(NoteParagraphs.attachments(in: text, within: NSRange(location: 8, length: 6)), [], "outside the range")
        XCTAssertEqual(NoteParagraphs.attachments(in: text, within: NSRange(location: 4, length: 400)), [NSRange(location: 7, length: 1)],
                       "a range past the end is clipped")

        let view = editor("Launch is two weeks out\nAnnual plan", times: [])
        let coordinator = MarginNotesEditor(text: .constant(view.string), times: []).makeCoordinator()
        let enclosing = NSRange(location: 0, length: (view.string as NSString).length)
        XCTAssertEqual(coordinator.textView(view, writingToolsIgnoredRangesInEnclosingRange: enclosing), [])
    }

    // MARK: The Mac's lane

    private func editor(_ text: String, times: [TimeInterval?], marks: [NoteMark] = [], plays: ((TimeInterval) -> Void)? = nil) -> MarginTextView {
        let view = MarginTextView()
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        view.textContainer?.lineFragmentPadding = 0
        view.margin = 52
        view.times = times
        view.marks = marks
        view.playTime = plays
        view.string = text
        view.applyTypingStyle()
        view.updateGutter()
        return view
    }

    /// What VoiceOver finds beside the notes: the container's children after the notes themselves.
    private func items(_ view: MarginTextView) throws -> [NSAccessibilityElement] {
        let container = NotesContainerView(textView: view, content: view)
        let children = try XCTUnwrap(container.accessibilityChildren())
        XCTAssertTrue(children.first as AnyObject === view, "the notes first")
        return try XCTUnwrap(Array(children.dropFirst()) as? [NSAccessibilityElement])
    }

    /// Regression: the margin's times were drawn only, so VoiceOver never heard them and nothing but a click played
    /// from them. Each is now a button that says where it plays from, and each mark says itself.
    func testBehaviorVoiceOverHearsEachTimeAsAButtonThatPlaysAndEachMark() throws {
        var played: [TimeInterval] = []
        let view = editor("Launch is two weeks out\nAnnual plan leads the pricing page", times: [250, 316],
                          marks: [NoteMark(id: "b", kind: .bookmark, time: 260)], plays: { played.append($0) })
        let children = try items(view)
        XCTAssertEqual(children.map { $0.accessibilityLabel() }, [
            "Play from \(SpokenTime.format(250))", "Bookmark at \(SpokenTime.format(260))", "Play from \(SpokenTime.format(316))"
        ], "in reading order")
        XCTAssertEqual(children[0].accessibilityRole(), .button)
        XCTAssertEqual(children[1].accessibilityRole(), .staticText)
        XCTAssertTrue(children[2].accessibilityPerformPress())
        XCTAssertEqual(played, [316])
        XCTAssertFalse(children[1].accessibilityPerformPress(), "a mark doesn't play")
    }

    func testBehaviorTimesThatCantPlaySayWhenTheNoteWasTaken() throws {
        let view = editor("Written while recording", times: [12])
        let children = try items(view)
        XCTAssertEqual(children.map { $0.accessibilityLabel() }, ["Note at \(SpokenTime.format(12))"])
        XCTAssertEqual(children.first?.accessibilityRole(), .staticText)
        XCTAssertNil(view.accessibilityCustomActions()?.first { $0.name == MarginNotesEditor.playFromHere })
    }

    /// Regression: a page open while a recording stopped (the Summary page turns playing on once it does) kept its
    /// times as "Note at …" that played nothing, and while recording kept "Play from …" buttons that did nothing.
    /// VoiceOver's elements are made again when playing turns on or off.
    func testBehaviorTimesBecomeButtonsWhenPlayingTurnsOnAndStopWhenItTurnsOff() throws {
        let view = editor("Written while recording", times: [12])
        let container = NotesContainerView(textView: view, content: view)
        let before = try XCTUnwrap(container.accessibilityChildren()?.dropFirst().first as? NSAccessibilityElement)
        XCTAssertEqual(before.accessibilityRole(), .staticText)

        var played: [TimeInterval] = []
        view.playTime = { played.append($0) }
        let playing = try XCTUnwrap(container.accessibilityChildren()?.dropFirst().first as? NSAccessibilityElement)
        XCTAssertEqual(playing.accessibilityRole(), .button)
        XCTAssertEqual(playing.accessibilityLabel(), "Play from \(SpokenTime.format(12))")
        XCTAssertTrue(playing.accessibilityPerformPress())
        XCTAssertEqual(played, [12])

        view.playTime = nil
        let after = try XCTUnwrap(container.accessibilityChildren()?.dropFirst().first as? NSAccessibilityElement)
        XCTAssertEqual(after.accessibilityRole(), .staticText)
        XCTAssertEqual(after.accessibilityLabel(), "Note at \(SpokenTime.format(12))")
        XCTAssertFalse(after.accessibilityPerformPress(), "nothing to play while recording")
        XCTAssertEqual(played, [12])
    }

    /// Regression: the times' elements sat under the NSTextView, which reports no children, so VoiceOver never
    /// reached them however they were made. Through what SwiftUI hands VoiceOver for the editor (its host view's
    /// children, the container left out), each time and mark is found beside the notes, on the page and in Floating
    /// Notes, and pointing at one finds it.
    func testBehaviorVoiceOverReachesTheTimesThroughTheEditorsHost() throws {
        for scrolls in [false, true] {
            var played: [TimeInterval] = []
            let editor = MarginNotesEditor(text: .constant("Launch is two weeks out\nAnnual plan leads the pricing page"), times: [250, 316],
                                           marks: [NoteMark(id: "b", kind: .bookmark, time: 260)], scrolls: scrolls,
                                           playTime: { played.append($0) })
            let host = NSHostingView(rootView: editor.frame(width: 360, height: 300))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            defer { window.contentView = nil }

            let container = try XCTUnwrap(Self.find(NotesContainerView.self, in: host), "scrolls: \(scrolls)")
            XCTAssertFalse(container.isAccessibilityElement(), "left out of the tree: its children stand in its place")
            let representable = try XCTUnwrap(container.superview)
            var reached: [NSObject] = []
            Self.walk(representable, into: &reached)
            let items = reached.filter { Self.label(of: $0)?.hasPrefix("Play from") == true || Self.label(of: $0)?.hasPrefix("Bookmark at") == true }
            XCTAssertEqual(items.compactMap(Self.label(of:)), [
                "Play from \(SpokenTime.format(250))", "Bookmark at \(SpokenTime.format(260))", "Play from \(SpokenTime.format(316))"
            ], "scrolls: \(scrolls)")
            XCTAssertTrue(reached.contains { $0 === container.textView }, "and the notes")
            guard let last = items.last as? NSAccessibilityElement else { return XCTFail("scrolls: \(scrolls)") }
            XCTAssertTrue(last.accessibilityPerformPress())
            XCTAssertEqual(played, [316])
            XCTAssertTrue(last.accessibilityParent() as AnyObject === NSAccessibility.unignoredAncestor(of: container) as AnyObject,
                          "its parent is the notes' own")

            let frame = last.accessibilityFrame()
            XCTAssertFalse(frame.isEmpty)
            let center = NSPoint(x: frame.midX, y: frame.midY)
            XCTAssertTrue(representable.accessibilityHitTest(center) as AnyObject === last, "pointing at a time finds it (scrolls: \(scrolls))")
            XCTAssertTrue(container.textView.accessibilityHitTest(center) as AnyObject === last, "from the notes too")
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for subview in view.subviews { if let found = find(type, in: subview) { return found } }
        return nil
    }

    private static func label(of object: NSObject) -> String? {
        guard let element = object as? NSAccessibilityProtocol else { return nil }
        let label: (() -> String?)? = element.accessibilityLabel
        return label?() ?? nil
    }

    /// Every element under `object`, as an accessibility client walks children.
    private static func walk(_ object: NSObject, into found: inout [NSObject], depth: Int = 0) {
        guard depth < 60 else { return }
        found.append(object)
        guard let element = object as? NSAccessibilityProtocol else { return }
        let accessibilityChildren: (() -> [Any]?)? = element.accessibilityChildren
        let children = (accessibilityChildren?() ?? nil) ?? []
        for case let child as NSObject in children { walk(child, into: &found, depth: depth + 1) }
    }

    func testBehaviorPlayFromHereIsInTheMenuAndAVoiceOverAction() throws {
        var played: [TimeInterval] = []
        let view = editor("Intro\nThe pricing page", times: [5, 40], plays: { played.append($0) })
        view.setSelectedRange(NSRange(location: 8, length: 0))
        let action = try XCTUnwrap(view.accessibilityCustomActions()?.first { $0.name == MarginNotesEditor.playFromHere })
        XCTAssertTrue(action.handler?() ?? false)
        XCTAssertEqual(played, [40], "the paragraph at the insertion point")
        XCTAssertEqual(view.playableTime(at: 1), 5)
        XCTAssertTrue(view.usesFindBar, "⌘F finds in the notes")
        XCTAssertTrue(view.isIncrementalSearchingEnabled)
    }

    /// Bookmarks made while recording appear in the lane, beside the paragraph written after them, without moving
    /// the text or the times.
    func testBehaviorBookmarksAreTicksInTheLane() {
        let view = editor("First\nSecond", times: [2, 30], marks: [NoteMark(id: "b", kind: .bookmark, time: 10),
                                                                   NoteMark(id: "p", kind: .photo, time: 45)])
        XCTAssertEqual(view.gutter.labels.map(\.text), ["0:02", "0:30"])
        let ticks = view.gutter.ticks
        XCTAssertEqual(ticks.map(\.mark.id), ["b", "p"])
        XCTAssertLessThan(ticks[0].rect.maxX, view.margin, "in the lane, clear of the text")
        XCTAssertGreaterThan(ticks[0].rect.minX, view.gutter.rect(for: view.gutter.labels[1]).maxX, "between the time and the text")
        XCTAssertEqual(ticks[0].rect.minY, view.gutter.rect(for: view.gutter.labels[1]).minY, accuracy: 6, "beside the paragraph after it")
        XCTAssertGreaterThan(ticks[1].rect.minY, ticks[0].rect.maxY, "after the last paragraph, where the next goes")
    }
}
