import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Unsure words through the Mac's processing (docs/architecture.md, "Unsure words"): a recording transcribed again
/// that reads a word differently gets it flagged with the earlier reading, and words the recognizer was unsure of are
/// flagged too, without holding up the summary; answering a flag lasts through the next transcription. Temporary
/// libraries, synthetic audio, and a fake inference engine; no models, no microphone.
@MainActor
final class UnsureWordsProcessingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    private func shown(_ meeting: Meeting) -> [TranscriptFlagMark] {
        TranscriptLayout(meeting).unsure.values.flatMap { $0 }.sorted { $0.flag.start < $1.flag.start }
    }

    func testTranscribingAgainFlagsWhereTheTwoTranscriptsDisagreeWithoutHoldingUpTheSummary() async throws {
        let rig = try await rig()
        let mic = try rig.audio("mic.wav", frequency: 220)
        let floor = try XCTUnwrap(TranscriptFlags.confidenceFloor(for: TrackTranscript(trackID: UUID(), segments: [],
                                                                                        modelID: rig.state.transcriptionModel)),
                                  "The Mac's transcription model has calibrated confidences")
        try rig.inference.script(mic, words: [(2, "We ship the calendar feature on Thursday", [:]),
                                              (8, "Jordan reviews the database migration next", [:])])
        let id = try await rig.macConversation("Design review", at: start, seconds: 60, audio: mic)
        rig.state.processor.enqueue(id)
        try await rig.processed(id)
        let first = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(first.summary?.overview, "Summary 1")
        XCTAssertNil(first.transcriptFlags, "One confident transcript: nothing to flag")

        // Transcribed again, the recording reads a word differently, and the recognizer is unsure of a name.
        try rig.inference.script(mic, words: [(2, "We ship the calendar feature on Friday", [:]),
                                              (8, "Jordan reviews the Daybrook migration next", ["Daybrook": floor / 2])])
        rig.state.processor.enqueue(id, mode: .fullRetranscription)
        try await rig.processed(id)
        let second = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(second.transcripts.count, 2, "Both runs are kept")
        XCTAssertEqual(second.summary?.overview, "Summary 2", "The summary was written as before")
        let marks = shown(second)
        XCTAssertEqual(marks.map(\.flag.text), ["Friday", "Daybrook"])
        XCTAssertEqual(marks.map(\.flag.reason), [.disagreement, .disagreement])
        XCTAssertEqual(marks.map(\.flag.alternative), ["Thursday", "database"])
        XCTAssertEqual(try XCTUnwrap(marks.last?.flag.confidence), floor / 2, accuracy: 0.0001)
        let evidence = try XCTUnwrap(rig.inference.summarized.last)
        XCTAssertTrue(evidence.contains("on Friday"), "The summary reads the transcript as it stands, flags or not")

        // Take the earlier reading of one and keep the other; both stay answered when it's transcribed once more.
        let friday = try XCTUnwrap(marks.first), daybrook = try XCTUnwrap(marks.last)
        rig.state.update(id) { $0.useFlagAlternative(friday.flag.id) }
        rig.state.update(id) { $0.keepFlaggedWords(daybrook.flag.id) }
        let answered = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(answered.unifiedTranscript.first { $0.id == friday.segmentID }?.text, "We ship the calendar feature on Thursday")
        XCTAssertTrue(answered.revisions.contains { $0.kind == .segment(friday.segmentID) && $0.newValue.hasSuffix("Thursday") })
        XCTAssertTrue(shown(answered).isEmpty)

        rig.state.processor.enqueue(id, mode: .fullRetranscription)
        try await rig.processed(id)
        let third = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(third.transcripts.count, 3)
        XCTAssertTrue(shown(third).isEmpty, "\(shown(third).map(\.flag.text))")
        XCTAssertEqual(third.unifiedTranscript.first { $0.id == friday.segmentID }?.text, "We ship the calendar feature on Thursday",
                       "The correction carries over")
        XCTAssertEqual(third.transcriptFlagDismissals?.count, 2)
        XCTAssertNil(third.correctionTransferIssues)
    }
}
