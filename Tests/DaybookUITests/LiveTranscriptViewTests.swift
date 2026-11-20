import AppKit
import DaybookCaptions
import DaybookDesign
import SwiftUI
import XCTest
@testable import DaybookUI

/// The live transcript's entry point and rows, as both apps share them: the caption line is a button only while
/// there is something to open, what it opens as, what VoiceOver is told, who each line is from, and a transcript of
/// thousands of lines lays out without a row for each.
@MainActor
final class LiveTranscriptViewTests: XCTestCase {
    private func line(_ text: String, _ start: TimeInterval, tentative: Bool = false) -> LiveCaptionSegment {
        LiveCaptionSegment(start: start, end: start + 1, text: text, isTentative: tentative)
    }

    private func hosted<V: View>(_ view: V, width: CGFloat = 400, height: CGFloat = 200) -> (NSHostingView<V>, NSWindow) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private let source = LiveTranscriptModel.Source(read: { LiveTranscriptModel.Reading(lines: []) })

    // MARK: The entry point

    func testBehaviorTheCaptionLineOpensTheTranscriptOnlyWhileItHasLines() {
        XCTAssertTrue(LiveTranscriptLink<EmptyView>.opens(state: .listening, lines: 1))
        XCTAssertFalse(LiveTranscriptLink<EmptyView>.opens(state: .listening, lines: 0), "Listening…, nothing to open yet")
        XCTAssertFalse(LiveTranscriptLink<EmptyView>.opens(state: .preparing, lines: 3))
        XCTAssertFalse(LiveTranscriptLink<EmptyView>.opens(state: .finished, lines: 3), "the line is gone once the captions end")
        XCTAssertFalse(LiveTranscriptLink<EmptyView>.opens(state: .failed("Stopped"), lines: 3))
    }

    func testBehaviorItOpensInASheetUnderTouchAndAPopoverInTheWindow() {
        XCTAssertTrue(LiveTranscriptLink<EmptyView>.usesSheet(.touch))
        XCTAssertFalse(LiveTranscriptLink<EmptyView>.usesSheet(.window))
        XCTAssertFalse(LiveTranscriptLink<EmptyView>.usesSheet(.panel), "Floating Notes: a popover from the line")
    }

    func testBehaviorTheCaptionLineTellsVoiceOverWhatItOpens() {
        XCTAssertEqual(LiveTranscriptLink<EmptyView>.hint, "Shows the live transcript")
    }

    // MARK: The rows

    func testBehaviorEachLineIsNamedByWhoSaidIt() {
        let names = ["device:rec": "Soundcore"]
        var named = line("Hello", 0)
        named.speaker = LiveCaptionSpeaker(slot: "S1", name: "Priya")
        var slot = line("Hi", 1)
        slot.speaker = LiveCaptionSpeaker(slot: "S2")
        var call = line("Welcome", 2)
        call.source = .call
        var device = line("From the recorder", 3)
        device.source = .device("rec")
        XCTAssertEqual(LiveTranscriptView.name(named, names: names), "Priya")
        XCTAssertEqual(LiveTranscriptView.name(slot, names: names), "S2", "the voice's own label when it has no name")
        XCTAssertEqual(LiveTranscriptView.name(call, names: names), "Call")
        XCTAssertEqual(LiveTranscriptView.name(device, names: names), "Soundcore")
        XCTAssertNil(LiveTranscriptView.name(line("Alone", 4), names: names), "one source, no one recognized: no label")
    }

    func testBehaviorThousandsOfLinesLayOutLazily() {
        let model = LiveTranscriptModel()
        model.apply(.init(lines: (0..<5_000).map { line("Line number \($0) of a very long meeting that goes on and on", Double($0) * 3) }))
        XCTAssertEqual(model.lines.count, 5_000)
        let started = Date()
        let (host, window) = hosted(LiveTranscriptView(source: source, model: model), width: 560, height: 520)
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "laid out for the rows in view, not all 5,000")
        XCTAssertEqual(host.frame.size, CGSize(width: 560, height: 520))
    }
}
