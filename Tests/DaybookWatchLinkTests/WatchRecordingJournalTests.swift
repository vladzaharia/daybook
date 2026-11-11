import DaybookWatchLink
import XCTest

final class WatchRecordingJournalTests: XCTestCase {
    private func journal() -> WatchRecordingJournal {
        WatchRecordingJournal(recording: WatchRecordingInfo(id: "rec-1", startedAt: Date(timeIntervalSince1970: 1_000)))
    }

    func testSegmentsCloseInOrderAndTheLastFinishesTheRecording() throws {
        var journal = journal()
        journal.openSegment(at: 0)
        let first = try XCTUnwrap(journal.closeSegment(duration: 120, byteCount: 900))
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.recording.segmentIndices, [0])
        XCTAssertFalse(first.recording.isFinished)

        journal.openSegment(at: 120)
        let last = try XCTUnwrap(journal.closeSegment(duration: 30, byteCount: 200, finishing: true))
        XCTAssertEqual(last.index, 1)
        XCTAssertEqual(last.startOffset, 120)
        XCTAssertTrue(last.recording.isFinished, "The last segment carries the finished recording")
        XCTAssertEqual(last.recording.segmentIndices, [0, 1])
        XCTAssertEqual(journal.recording.duration, 150)
        XCTAssertEqual(journal.recording.byteCount, 1_100)
        XCTAssertNil(journal.open)
    }

    func testAnInterruptionsGapIsKept() throws {
        var journal = journal()
        journal.openSegment(at: 0)
        journal.closeSegment(duration: 40, byteCount: 300)
        // A call: the next run starts 25 s after the first ended, on the wall clock.
        journal.openSegment(at: max(journal.end, 65))
        let resumed = try XCTUnwrap(journal.closeSegment(duration: 10, byteCount: 80, finishing: true))
        XCTAssertEqual(resumed.startOffset, 65)
        XCTAssertEqual(journal.recording.duration, 75, "From the first sample to the last, gaps included")
    }

    func testASegmentWithNoAudioIsLeftOut() {
        var journal = journal()
        journal.openSegment(at: 0)
        journal.closeSegment(duration: 60, byteCount: 500)
        journal.openSegment(at: 60)
        XCTAssertNil(journal.closeSegment(duration: 0, byteCount: 0, finishing: true))
        XCTAssertEqual(journal.recording.segmentIndices, [0])
        XCTAssertTrue(journal.recording.isFinished)
    }

    // MARK: Recovery

    func testRecoveryKeepsAReadableLastSegmentAsNotCleanlyClosed() throws {
        var journal = journal()
        journal.openSegment(at: 0)
        journal.closeSegment(duration: 120, byteCount: 900)
        journal.openSegment(at: 120)
        let recovered = try XCTUnwrap(journal.recover(openDuration: 45, openByteCount: 300))
        XCTAssertFalse(recovered.cleanlyClosed)
        XCTAssertEqual(recovered.index, 1)
        XCTAssertEqual(journal.recording.segmentIndices, [0, 1])
        XCTAssertTrue(journal.recording.isFinished)
        XCTAssertEqual(journal.recording.duration, 165)
    }

    func testRecoveryLeavesOutAnUnreadableLastSegment() {
        var journal = journal()
        journal.openSegment(at: 0)
        journal.closeSegment(duration: 120, byteCount: 900)
        journal.openSegment(at: 120)
        XCTAssertNil(journal.recover(openDuration: nil))
        XCTAssertEqual(journal.recording.segmentIndices, [0], "Every index listed is one the iPhone will receive")
        XCTAssertTrue(journal.recording.isFinished)
        XCTAssertNil(journal.open)

        // The ledger on the iPhone completes with what's listed.
        var ledger = WatchSegmentLedger()
        journal.segments.forEach { ledger.received($0) }
        ledger.update(journal.recording)
        XCTAssertEqual(ledger.complete.map(\.recording.id), ["rec-1"])
    }

    func testRecoveryBetweenSegmentsAndOfAFinishedRecording() {
        var interrupted = journal()
        interrupted.openSegment(at: 0)
        interrupted.closeSegment(duration: 30, byteCount: 200)
        XCTAssertNil(interrupted.recover(openDuration: 10), "Nothing was open: the app ended while paused for a call")
        XCTAssertEqual(interrupted.recording.segmentIndices, [0])
        XCTAssertTrue(interrupted.recording.isFinished)

        var finished = interrupted
        XCTAssertNil(finished.recover(openDuration: 10))
        XCTAssertEqual(finished, interrupted)
    }

    // MARK: Delivery

    func testDeliveredSegmentsArentSentAgain() throws {
        var journal = journal()
        for index in 0..<3 {
            journal.openSegment(at: Double(index) * 120)
            journal.closeSegment(duration: 120, byteCount: 900, finishing: index == 2)
        }
        journal.deliver([0, 2, 7])
        XCTAssertEqual(journal.undelivered.map(\.index), [1])
        XCTAssertEqual(journal.delivered, [0, 2])

        journal.conversationStartedAt = Date(timeIntervalSince1970: 5)
        journal.isOwn = true
        journal.sent(1, at: Date(timeIntervalSince1970: 2_000))
        let stored = try JSONEncoder().encode(journal)
        XCTAssertEqual(try JSONDecoder().decode(WatchRecordingJournal.self, from: stored), journal)
    }

    private func recorded(_ count: Int, finished: Bool) -> WatchRecordingJournal {
        var journal = journal()
        for index in 0..<count {
            journal.openSegment(at: Double(index) * 120)
            journal.closeSegment(duration: 120, byteCount: 900, finishing: finished && index == count - 1)
        }
        return journal
    }

    func testAFinishedTransferIsntDeliveryButIsntSentAgain() {
        var journal = recorded(3, finished: false)
        XCTAssertEqual(journal.unsent.map(\.index), [0, 1, 2])
        journal.sent(0)
        journal.sent(1)
        journal.sent(9)
        XCTAssertEqual(journal.unsent.map(\.index), [2], "Each segment goes once")
        XCTAssertEqual(journal.undelivered.map(\.index), [0, 1, 2], "Only a receipt delivers")
        XCTAssertEqual(Set(journal.transferred.keys), [0, 1])
    }

    func testAReceiptForARecordingInProgressDeliversWhatItNames() {
        var journal = recorded(3, finished: false)
        journal.sent(0)
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-1", segments: [0])), [], "Nothing is asked for while recording")
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-1", segments: [1])), [])
        XCTAssertEqual(journal.delivered, [0, 1])
        XCTAssertEqual(journal.unsent.map(\.index), [2])
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-2", segments: [2])), [], "Another recording's receipt")
        XCTAssertEqual(journal.delivered, [0, 1])
    }

    /// A time on the watch's clock, in seconds.
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testAnAskForAFinishedRecordingsMissingSegmentsSendsThemAgain() {
        var journal = recorded(4, finished: true)
        (0..<4).forEach { journal.sent($0, at: at(1_000)) }
        XCTAssertTrue(journal.unsent.isEmpty)
        // The iPhone stored 0 and 2: 1 and 3 never arrived, so it asks again, minutes later.
        let resend = journal.receive(WatchReceipt(recordingID: "rec-1", segments: [0, 2], requestsMissing: true), at: at(1_300))
        XCTAssertEqual(resend.map(\.index), [1, 3])
        XCTAssertEqual(journal.delivered, [0, 2])
        XCTAssertEqual(journal.unsent.map(\.index), [1, 3], "Until a transfer of them finishes, they go again at the next launch")
        journal.sent(1, at: at(1_310))
        XCTAssertEqual(journal.unsent.map(\.index), [3])
        // Its repeat a minute later, with 1 not stored yet, asks for 3 alone: 1's transfer finished moments ago.
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-1", segments: [0, 2], requestsMissing: true), at: at(1_360))
            .map(\.index), [3])
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-1", segments: [0, 1, 2, 3], requestsMissing: true), at: at(1_420)), [])
        XCTAssertTrue(journal.undelivered.isEmpty)
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-1", segments: [], imported: true)), [],
                       "Imported: nothing more to send")
    }

    /// The iPhone acknowledges each segment it stores; a later one may simply not have arrived yet, so only its ask (once
    /// a minute at most) sends anything again.
    func testAReceiptThatDoesntAskSendsNothingAgain() {
        var journal = recorded(3, finished: true)
        (0..<3).forEach { journal.sent($0, at: at(1_000)) }
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-1", segments: [0]), at: at(5_000)), [])
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-1", segments: [2]), at: at(5_001)), [])
        XCTAssertEqual(journal.delivered, [0, 2])
        XCTAssertTrue(journal.unsent.isEmpty, "1 is on its way, as far as the watch knows")
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-1", segments: [0, 2], requestsMissing: true), at: at(5_002))
            .map(\.index), [1])
    }

    /// A segment whose transfer finished moments ago may not have reached the iPhone's handler: an ask then leaves it, and
    /// one after `resendAfter` sends it.
    func testAnAskLeavesASegmentWhoseTransferJustFinished() {
        var journal = recorded(2, finished: true)
        journal.sent(0, at: at(1_000))
        journal.sent(1, at: at(1_100))
        let ask = WatchReceipt(recordingID: "rec-1", segments: [], requestsMissing: true)
        XCTAssertEqual(journal.receive(ask, at: at(1_000 + WatchRecordingJournal.resendAfter)).map(\.index), [0])
        XCTAssertEqual(Set(journal.transferred.keys), [1], "1 still counts as sent")
        XCTAssertEqual(journal.unsent.map(\.index), [0])
        XCTAssertEqual(journal.receive(ask, at: at(1_100 + WatchRecordingJournal.resendAfter)).map(\.index), [0, 1])
    }

    func testAnAskForARecordingInProgressSendsNothing() {
        var journal = recorded(2, finished: false)
        (0..<2).forEach { journal.sent($0, at: at(1_000)) }
        XCTAssertEqual(journal.receive(WatchReceipt(recordingID: "rec-1", segments: [0], requestsMissing: true), at: at(9_000)), [])
        XCTAssertEqual(journal.delivered, [0])
    }

    func testAJournalStoredWithoutLaterFieldsStillReads() throws {
        var stored = recorded(2, finished: true)
        stored.recording.conversationID = UUID()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        object["transferred"] = nil
        object["delivered"] = nil
        object["isOwn"] = nil
        let earlier = try JSONSerialization.data(withJSONObject: object)
        let read = try JSONDecoder().decode(WatchRecordingJournal.self, from: earlier)
        XCTAssertEqual(read.recording, stored.recording)
        XCTAssertEqual(read.segments, stored.segments)
        XCTAssertEqual(read.unsent.map(\.index), stored.segments.map(\.index), "Nothing known sent: all of it goes")
        XCTAssertFalse(read.isOwn)
        XCTAssertEqual(try JSONDecoder().decode(WatchRecordingJournal.self, from: JSONEncoder().encode(stored)), stored)
    }

    /// An earlier build stored only which segments' transfers finished, not when: they count as finished long ago, so
    /// the iPhone's ask sends them at once.
    func testAJournalThatStoredTransfersWithoutTimesStillReads() throws {
        var stored = recorded(3, finished: true)
        stored.sent(0, at: at(1_000))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        object["transferred"] = [0, 2]
        let earlier = try JSONSerialization.data(withJSONObject: object)
        var read = try JSONDecoder().decode(WatchRecordingJournal.self, from: earlier)
        XCTAssertEqual(read.transferred, [0: .distantPast, 2: .distantPast])
        XCTAssertEqual(read.unsent.map(\.index), [1])
        XCTAssertEqual(read.receive(WatchReceipt(recordingID: "rec-1", segments: [1], requestsMissing: true), at: at(1_001))
            .map(\.index), [0, 2])
    }
}
