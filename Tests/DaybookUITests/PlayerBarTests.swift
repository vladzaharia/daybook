import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// The one player both apps draw: one rule for its times, and a scrubber that stays on its line.
@MainActor
final class PlayerBarTests: XCTestCase {
    private final class Player: PlaybackControlling {
        var meetingID: UUID?
        var trackID: UUID?
        var phase: PlaybackPhase = .idle
        var isPlaying = false
        var position: TimeInterval = 0
        var duration: TimeInterval = 0
        var rate: Float = 1
        var backSkips = 0
        var forwardSkips = 0
        var problem: String?
        var problemDetails: String?
        func toggle() { isPlaying.toggle() }
        func skip(_ seconds: TimeInterval) { position += seconds }
        func seek(to seconds: TimeInterval) { position = seconds }
        func close() { phase = .idle }
    }

    func testBehaviorBothAppsShowWhatsPlayedAndWhatsLeft() {
        XCTAssertEqual(PlayerBar<Player>.remaining(position: 31, duration: 754), 723)
        XCTAssertEqual(PlayerBar<Player>.remainingLabel(723), "−12:03", "Podcasts' and Music's form, on the Mac and the iPhone")
        XCTAssertEqual(PlayerBar<Player>.remainingLabel(PlayerBar<Player>.remaining(position: 760, duration: 754)), "−0:00",
                       "never less than nothing")
        XCTAssertEqual(PlayerBar<Player>.rates, [0.75, 1, 1.25, 1.5, 2])
    }

    func testBehaviorTheScrubberStaysOnItsLine() {
        XCTAssertEqual(Scrubber.fraction(position: 30, duration: 60), 0.5)
        XCTAssertEqual(Scrubber.fraction(position: -5, duration: 60), 0)
        XCTAssertEqual(Scrubber.fraction(position: 90, duration: 60), 1)
        XCTAssertEqual(Scrubber.fraction(position: 10, duration: 0), 0, "nothing loaded yet")
    }

    func testBehaviorCopyingSaysCopiedEachTime() {
        let first = ConfirmationBeat.copied, second = ConfirmationBeat.copied
        XCTAssertEqual(first.words, "Copied")
        XCTAssertNotEqual(first.id, second.id, "copying again holds the word again")
    }
}
