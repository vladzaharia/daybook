import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// P2.3, VI-06: bookmarks stand on the player's scrubber, which measures the recording loaded, rather than on the open
/// Duo's crease beside text laid out by scrolling. A tick is a bookmark's time in that recording, never a guess.
@MainActor
final class ScrubberBookmarksTests: XCTestCase {
    private func track(
        _ name: String, duration: TimeInterval? = nil, offset: TimeInterval? = nil, alignment: SourceAlignment? = nil
    ) -> RecordingTrack {
        RecordingTrack(relativePath: "Originals/\(name).m4a", fileName: "\(name).m4a", duration: duration, offset: offset,
                       alignment: alignment)
    }

    func testBehaviorTheLoadedRecordingsOwnBookmarksKeepTheirTimeAndTheTimelinesAreCarriedIntoIt() {
        let recording = track("placed", duration: 120)
        let meeting = Meeting(
            tracks: [recording],
            alignmentReports: [.init(trackID: recording.id, method: .anchors, offset: 20, rate: 1)],
            highlights: [
                .init(time: 0), .init(time: 65), .init(trackID: recording.id, time: 15), .init(time: 1_000),
            ])
        XCTAssertEqual(
            ScrubberBookmarks.fractions(in: meeting, trackID: recording.id, duration: 120), [15.0 / 120.0, 45.0 / 120.0],
            "its own bookmark at its own time; the timeline's at 65 − 20; one before it starts or after it ends has none")
        XCTAssertEqual(
            ScrubberBookmarks.fractions(in: meeting, trackID: recording.id, duration: 240), [15.0 / 240.0, 45.0 / 240.0],
            "the player's length is the line's")
    }

    func testBehaviorABookmarkInAnotherPlacedRecordingIsCarriedThroughBothPlacements() {
        let main = track("main", duration: 100)
        let recorder = track("recorder", duration: 60)
        let meeting = Meeting(
            tracks: [main, recorder],
            alignmentReports: [
                .init(trackID: main.id, method: .reference),
                .init(trackID: recorder.id, method: .anchors, offset: 30, rate: 1),
            ],
            highlights: [.init(trackID: recorder.id, time: 10), .init(trackID: main.id, time: 50)])
        XCTAssertEqual(ScrubberBookmarks.fractions(in: meeting, trackID: main.id, duration: 100), [0.4, 0.5])
        let onRecorder = ScrubberBookmarks.fractions(in: meeting, trackID: recorder.id, duration: 60)
        XCTAssertEqual(onRecorder.count, 2)
        XCTAssertEqual(onRecorder[0], 10.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(onRecorder[1], 20.0 / 60.0, accuracy: 0.000_001, "the main recording's 0:50 is 0:20 into this one")
    }

    func testBehaviorAStoredPlacementWinsOverAStaleReport() {
        let recording = track("manual", duration: 100, alignment: .init(method: .manual, offset: 20, rate: 1))
        let meeting = Meeting(
            tracks: [recording],
            alignmentReports: [.init(trackID: recording.id, method: .anchors, offset: 5, rate: 1)],
            highlights: [.init(time: 50)])
        XCTAssertEqual(ScrubberBookmarks.fractions(in: meeting, trackID: recording.id, duration: 100), [0.3],
                       "the stored placement's 0:20, not the stale report's 0:05")
    }

    func testBehaviorUnalignedUnplacedAndRemovedRecordingsGiveNoInventedTicks() {
        let reference = track("reference", duration: 100)
        let unaligned = track("unaligned", duration: 100, offset: 0)
        let pending = track("pending", duration: 100, alignment: .init(method: .pending))
        let sourceUnaligned = track("source-unaligned", duration: 100, alignment: .init(method: .unaligned))
        var removed = track("removed", duration: 100)
        removed.removal = RecordingRemoval(removedAt: Date())
        let meeting = Meeting(
            tracks: [reference, unaligned, pending, sourceUnaligned, removed],
            alignmentReports: [
                .init(trackID: reference.id, method: .reference),
                .init(trackID: unaligned.id, method: .unaligned),
                .init(trackID: sourceUnaligned.id, method: .anchors),
                .init(trackID: removed.id, method: .anchors),
            ],
            highlights: [
                .init(trackID: reference.id, time: 50), .init(trackID: unaligned.id, time: 5),
                .init(trackID: pending.id, time: 5), .init(trackID: sourceUnaligned.id, time: 5),
                .init(trackID: removed.id, time: 5), .init(time: 80),
            ])
        XCTAssertEqual(ScrubberBookmarks.fractions(in: meeting, trackID: reference.id, duration: 100), [0.5, 0.8],
                       "only placed recordings' bookmarks, and the timeline's")
        XCTAssertEqual(ScrubberBookmarks.fractions(in: meeting, trackID: unaligned.id, duration: 100), [0.05],
                       "an unaligned recording keeps its own bookmarks and nobody else's")
        XCTAssertEqual(ScrubberBookmarks.fractions(in: meeting, trackID: removed.id, duration: 100), [],
                       "a recording taken out of the conversation has no bookmarks to show")
    }

    func testBehaviorNothingLoadedOrNonfiniteTimesNeverMakeATick() {
        let recording = track("placed", duration: 100)
        let meeting = Meeting(
            tracks: [recording],
            highlights: [.init(time: .nan), .init(time: .infinity), .init(time: -1), .init(trackID: recording.id, time: 100)])
        XCTAssertEqual(ScrubberBookmarks.fractions(in: meeting, trackID: recording.id, duration: 100), [1],
                       "a bookmark at the very end sits at the end")
        XCTAssertEqual(ScrubberBookmarks.fractions(in: meeting, trackID: nil, duration: 100), [])
        XCTAssertEqual(ScrubberBookmarks.fractions(in: meeting, trackID: UUID(), duration: 100), [], "another recording")
        for length in [0, -5, .nan, .infinity] as [TimeInterval] {
            XCTAssertEqual(ScrubberBookmarks.fractions(in: meeting, trackID: recording.id, duration: length), [],
                           "no length yet, no line to place them on")
        }
    }

    func testBehaviorATickStaysOnTheLine() {
        XCTAssertEqual(Scrubber.tick, CGSize(width: 2, height: 10))
        XCTAssertEqual(Scrubber.tickOffset(0.5, width: 200), 99, "centred on its time")
        XCTAssertEqual(Scrubber.tickOffset(0, width: 200), 0)
        XCTAssertEqual(Scrubber.tickOffset(1, width: 200), 198, "the last tick ends with the line")
        XCTAssertEqual(Scrubber.tickOffset(.nan, width: 200), 0)
        XCTAssertEqual(Scrubber.tickOffset(0.5, width: 1), 0, "before the line is measured")
    }
}
