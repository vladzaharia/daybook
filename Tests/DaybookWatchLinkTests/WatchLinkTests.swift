import DaybookWatchLink
import XCTest

final class WatchLinkTests: XCTestCase {
    private let conversation = UUID()

    private func recording(_ id: String = "rec-1", finished: Bool = false, segments: [Int] = [0], duration: TimeInterval = 60) -> WatchRecordingInfo {
        WatchRecordingInfo(id: id, conversationID: conversation, startedAt: Date(timeIntervalSince1970: 1_000), duration: duration,
                           segmentIndices: segments, isFinished: finished, byteCount: 1_024)
    }

    private func segment(_ index: Int, of info: WatchRecordingInfo) -> WatchSegment {
        WatchSegment(recordingID: info.id, index: index, startOffset: Double(index) * 120, duration: 120, recording: info)
    }

    // MARK: Payloads

    func testMessagesRoundTripThroughPropertyListDictionaries() throws {
        let state = WatchState(watchID: "watch", recording: recording(), isCapturing: true, change: .startedOnWatch, battery: 80)
        let messages: [WatchMessage] = [
            .start(WatchStart(conversationID: conversation, title: "Standup", startedAt: Date(timeIntervalSince1970: 5))),
            .stop(WatchStop(recordingID: "rec-1")),
            .status,
            .clock(phoneTime: Date(timeIntervalSince1970: 9)),
            .received(WatchReceipt(recordingID: "rec-1", segments: [0, 1], imported: true)),
            .context,
            .state(state)
        ]
        for message in messages {
            let dictionary = try WatchPayload.dictionary(message)
            XCTAssertTrue(PropertyListSerialization.propertyList(dictionary, isValidFor: .binary), "\(message)")
            XCTAssertEqual(WatchPayload.decode(WatchMessage.self, from: dictionary), message)
        }
        let replies: [WatchReply] = [.state(state), .context(PhoneContext(sharedRecording: nil)), .refused("No"),
                                     .clock(WatchClockSample(phoneSent: Date(), watchTime: Date()))]
        for reply in replies {
            XCTAssertEqual(WatchPayload.decode(WatchReply.self, from: try WatchPayload.dictionary(reply)), reply)
        }
    }

    func testAForeignDictionaryDecodesToNothing() {
        XCTAssertNil(WatchPayload.decode(WatchMessage.self, from: ["other": 1]))
        XCTAssertNil(WatchPayload.decode(WatchMessage.self, from: [WatchLink.payloadKey: Data("{\"newer\":{}}".utf8)]))
    }

    func testSegmentFileNamesSortInOrder() {
        let info = recording()
        XCTAssertEqual(segment(3, of: info).fileName, "rec-1-0003.m4a")
        XCTAssertLessThan(segment(9, of: info).fileName, segment(10, of: info).fileName)
    }

    // MARK: Clock

    func testTheClockTakesTheLeastDelayedSample() {
        var clock = WatchClock()
        let base = Date(timeIntervalSince1970: 100)
        // Watch 2 s ahead; a slow sample (0.8 s round trip, answered late) and a quick one.
        clock.add(WatchClockSample(phoneSent: base, watchTime: base.addingTimeInterval(2.7), phoneReceived: base.addingTimeInterval(0.8)))
        clock.add(WatchClockSample(phoneSent: base, watchTime: base.addingTimeInterval(2.05), phoneReceived: base.addingTimeInterval(0.1)))
        XCTAssertEqual(clock.offset ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(clock.phoneTime(base.addingTimeInterval(12)).timeIntervalSince(base), 10, accuracy: 0.001)
    }

    func testTheClockKeepsOnlyRecentSamplesAndIgnoresUnansweredOnes() {
        var clock = WatchClock()
        clock.add(WatchClockSample(phoneSent: Date(), watchTime: Date()))
        XCTAssertNil(clock.offset)
        for index in 0..<(WatchClock.kept + 3) {
            let sent = Date(timeIntervalSince1970: Double(index))
            clock.add(WatchClockSample(phoneSent: sent, watchTime: sent, phoneReceived: sent.addingTimeInterval(0.1)))
        }
        XCTAssertEqual(clock.samples.count, WatchClock.kept)
    }

    // MARK: Ledger

    func testARecordingIsCompleteOnceFinishedWithEverySegment() {
        var ledger = WatchSegmentLedger()
        let inProgress = recording(segments: [0])
        ledger.received(segment(0, of: inProgress))
        XCTAssertTrue(ledger.complete.isEmpty, "Still recording")

        let finished = recording(finished: true, segments: [0, 1, 2], duration: 300)
        ledger.update(finished)
        XCTAssertEqual(ledger["rec-1"]?.missing, [1, 2])
        ledger.received(segment(2, of: finished))
        ledger.received(segment(1, of: finished))
        XCTAssertEqual(ledger.complete.map(\.recording.id), ["rec-1"])
        XCTAssertEqual(ledger["rec-1"]?.orderedSegments.map(\.index), [0, 1, 2])
    }

    func testAnEarlierReportNeverUndoesAFinishedOne() {
        var ledger = WatchSegmentLedger()
        let finished = recording(finished: true, segments: [0, 1])
        ledger.update(finished)
        // A segment closed mid-recording arrives after the watch said it finished.
        ledger.received(segment(0, of: recording(segments: [0])))
        XCTAssertEqual(ledger["rec-1"]?.recording, finished)
    }

    func testAReportFromBeforeAdoptingNeverDropsTheConversation() {
        var ledger = WatchSegmentLedger()
        // Started on the wrist: two segments closed before the watch adopted the iPhone's conversation.
        var early = recording(segments: [0, 1])
        early.conversationID = nil
        ledger.received(segment(1, of: early))
        // The finished report names the conversation it adopted.
        ledger.update(recording(finished: true, segments: [0, 1, 2]))
        XCTAssertEqual(ledger["rec-1"]?.recording.conversationID, conversation)
        // A late, less advanced report without it changes nothing about the conversation.
        ledger.received(segment(0, of: early))
        XCTAssertEqual(ledger["rec-1"]?.recording.conversationID, conversation)

        // And the other way round: an in-progress report that adopted, then a finished one sent without it.
        var other = WatchSegmentLedger()
        other.update(recording("rec-2", segments: [0]))
        var finishedBare = recording("rec-2", finished: true, segments: [0, 1])
        finishedBare.conversationID = nil
        other.update(finishedBare)
        XCTAssertEqual(other["rec-2"]?.recording.conversationID, conversation)
        XCTAssertTrue(other["rec-2"]?.recording.isFinished == true)
    }

    func testASegmentLostToTheAppEndingIsntWaitedFor() {
        var ledger = WatchSegmentLedger()
        // Segment 1 was being written when the app was ended; the recovered recording lists 0 and 2.
        let recovered = recording(finished: true, segments: [0, 2])
        ledger.received(segment(0, of: recovered))
        ledger.received(segment(2, of: recovered))
        XCTAssertEqual(ledger.complete.count, 1)
    }

    func testImportedRecordingsDropTheirSegmentsAndAreForgottenLater() {
        var ledger = WatchSegmentLedger()
        let finished = recording(finished: true, segments: [0])
        ledger.received(segment(0, of: finished), at: Date(timeIntervalSince1970: 0))
        ledger.markImported("rec-1")
        XCTAssertTrue(ledger.complete.isEmpty)
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertEqual(ledger["rec-1"]?.segments.count, 0)
        ledger.prune(now: Date(timeIntervalSince1970: WatchSegmentLedger.importedMemory + 1))
        XCTAssertNil(ledger["rec-1"])
    }

    func testTheLedgerSurvivesBeingStored() throws {
        var ledger = WatchSegmentLedger()
        ledger.received(segment(0, of: recording()))
        let stored = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(WatchSegmentLedger.self, from: stored), ledger)
    }
}
