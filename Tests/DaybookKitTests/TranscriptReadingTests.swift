import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The reading helpers both apps share: the playhead and bookmark lookups give exactly what the
/// linear scans they replace gave, the layout is worked out once per version, and a timeline time no
/// recording covers plays the transcribed recording on the Mac too.
@MainActor
final class TranscriptReadingTests: XCTestCase {
    /// The scan the pages ran at every playback tick before `PlayheadIndex`.
    private func scannedPlayhead(_ position: Double, _ trackID: UUID, _ meeting: Meeting) -> UUID? {
        meeting.unifiedTranscript.first { segment in
            if let source = segment.provenance.first(where: { $0.trackID == trackID }) { return (source.start...max(source.start, source.end)).contains(position) }
            guard segment.trackID == trackID else { return false }
            let offset = meeting.tracks.first { $0.id == trackID }?.offset ?? 0
            return (segment.start...max(segment.start, segment.end)).contains(position + offset)
        }?.id
    }

    /// The scan `BookmarkMarks` ran per bookmark before.
    private func scannedHolder(_ time: Double, _ segments: [TranscriptSegment]) -> UUID? {
        (segments.last { $0.start <= time + 0.01 } ?? segments.first)?.id
    }

    private func randomMeeting(_ generator: inout SystemRandomNumberGenerator) -> Meeting {
        let tracks = (0..<3).map { index in
            RecordingTrack(relativePath: "Originals/\(index).m4a", fileName: "\(index).m4a",
                           offset: index == 0 ? nil : Double.random(in: -20...20, using: &generator))
        }
        var segments: [TranscriptSegment] = []
        var clock = 0.0
        for _ in 0..<Int.random(in: 0...60, using: &generator) {
            // Mostly in order, sometimes overlapping or out of order, as fusion can leave them.
            clock += Double.random(in: -2...4, using: &generator)
            let length = Double.random(in: 0...5, using: &generator)
            let owner = tracks.randomElement(using: &generator)!.id
            var segment = TranscriptSegment(trackID: owner, start: max(0, clock), end: max(0, clock) + length, text: "words")
            for cited in tracks where Bool.random(using: &generator) && Bool.random(using: &generator) {
                let start = Double.random(in: 0...200, using: &generator)
                segment.provenance.append(SegmentProvenance(trackID: cited.id, segmentID: UUID(), start: start,
                                                            end: start + Double.random(in: -1...6, using: &generator), text: "", confidence: nil))
            }
            segments.append(segment)
        }
        var meeting = Meeting(title: "Random", tracks: tracks)
        meeting.unifiedTranscript = segments
        return meeting
    }

    func testThePlayheadAndBookmarkLookupsMatchTheScansTheyReplace() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let meeting = randomMeeting(&generator)
            let index = PlayheadIndex(meeting: meeting)
            let finder = BookmarkMarks.HolderFinder(meeting.unifiedTranscript)
            for _ in 0..<40 {
                let time = Double.random(in: -10...220, using: &generator)
                let track = meeting.tracks.randomElement(using: &generator)!.id
                XCTAssertEqual(index.segmentID(at: time, trackID: track), scannedPlayhead(time, track, meeting))
                XCTAssertEqual(finder.holder(at: time), scannedHolder(time, meeting.unifiedTranscript))
            }
        }
    }

    func testTheLayoutIsWorkedOutOncePerVersion() {
        var meeting = Meeting(title: "Layout")
        let track = UUID()
        meeting.unifiedTranscript = [TranscriptSegment(trackID: track, start: 0, end: 2, text: "Hello"),
                                     TranscriptSegment(trackID: track, start: 2, end: 4, text: "again")]
        meeting.highlights = [Highlight(time: 2.5, text: "Pricing")]
        let first = TranscriptLayout.cached(for: meeting)
        let builds = TranscriptLayout.builds
        for _ in 0..<10 { _ = TranscriptLayout.cached(for: meeting) }
        XCTAssertEqual(TranscriptLayout.builds, builds, "Redraws reuse it")
        XCTAssertEqual(first.marks.labelSegments[meeting.unifiedTranscript[1].id], "Pricing")
        XCTAssertEqual(first.blocks.count, 1)
        meeting.highlights.append(Highlight(time: 0.5, text: "Opening"))
        let second = TranscriptLayout.cached(for: meeting)
        XCTAssertEqual(TranscriptLayout.builds, builds + 1, "A change works it out again")
        XCTAssertEqual(second.marks.labelSegments[meeting.unifiedTranscript[0].id], "Opening")
    }

    func testATimelineTimeNoRecordingCoversPlaysTheTranscribedRecording() throws {
        let original = RecordingTrack(source: .microphone, relativePath: "Originals/mic.caf", fileName: "mic.caf")
        var cleaned = RecordingTrack(source: .microphone, relativePath: "Originals/clean.caf", fileName: "clean.caf")
        cleaned.derivedFrom = original.id
        let meeting = Meeting(title: "Echo removed", tracks: [original, cleaned])
        XCTAssertEqual(meeting.transcribableTracks.map(\.id), [cleaned.id])
        let resolved = try XCTUnwrap(PlaybackTarget.timeline(12).resolve(in: meeting))
        XCTAssertEqual(resolved.track.id, cleaned.id, "The copy that was transcribed, as on the iPhone")
        XCTAssertEqual(resolved.seconds, 12)
        XCTAssertEqual(PlaybackTarget.source(original, -3).resolve(in: meeting)?.seconds, 0)
    }
}
