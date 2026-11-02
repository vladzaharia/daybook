import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// Info on both apps: its Now row speaks in the list row's words with the choices of a summary being placed, and
/// Audio says where a recording's audio is in the same words on every device that asks.
@MainActor
final class ConversationInfoTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                    inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)

    private func inputs(_ words: DeviceWords = .mac(id: "mac"), placement: ConversationStatusPresentation.Placement = .init())
        -> ConversationStatusPresentation.Inputs {
        ConversationStatusPresentation.Inputs(words: words, local: .mac(), placement: placement)
    }

    func testBehaviorTheNowRowSaysWhatTheRowSaysAndNothingWhenAllIsWell() {
        var meeting = Meeting(title: "Call", tracks: [RecordingTrack(source: .microphone, relativePath: "Originals/a.wav", fileName: "a.wav")])
        XCTAssertEqual(InfoNow.make(.recorded, meeting: meeting, inputs: inputs(), now: start)?.text, "Not transcribed yet")
        XCTAssertEqual(InfoNow.make(.recorded, meeting: meeting, inputs: inputs(), now: start)?.actions, [])
        meeting.summary = MeetingSummary(kind: .general, title: "Call", overview: "Done")
        XCTAssertNil(InfoNow.make(.done, meeting: meeting, inputs: inputs(), now: start), "nothing to say, no row")
    }

    func testBehaviorTheNowRowCountsDownWithTheSummarysChoicesAndStopsACloudRun() {
        let meeting = Meeting(title: "Call")
        var preferences = CloudSummaryPreferences()
        preferences.policy = .ask
        preferences.countdownSeconds = 15
        let planner = SummaryPlacementPlanner(options: SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: sonnet),
                                              preferences: preferences, at: start)
        let now = try? XCTUnwrap(InfoNow.make(.transcribed, meeting: meeting, inputs: inputs(placement: .init(planner: planner)), now: start))
        XCTAssertEqual(now?.text(at: start.addingTimeInterval(3)), "Summarizing in 12 s")
        XCTAssertEqual(now?.countdownUntil, start.addingTimeInterval(15))
        XCTAssertEqual(now?.actions, [.placement(.useCloud), .placement(.startNow)])

        let running = InfoNow.make(.transcribed, meeting: meeting, inputs: inputs(placement: .init(run: .cloud(sonnet))), now: start)
        XCTAssertEqual(running?.text, "Summarizing with Claude Sonnet 5.5")
        XCTAssertEqual(running?.actions, [.stopSummary])
    }

    func testBehaviorTheNowRowOffersDontWaitWhileRecordingsAreAwaited() {
        let meeting = Meeting(title: "Call", tracks: [RecordingTrack(source: .microphone, relativePath: "Originals/a.wav", fileName: "a.wav")])
        let awaited = [AwaitedRecording(deviceName: "Alex’s iPhone", deviceKind: "daybook.iphone", since: start)]
        let now = InfoNow.make(.awaitingRecordings(awaited), meeting: meeting, inputs: inputs(), now: start)
        XCTAssertNotNil(now?.text)
        XCTAssertEqual(now?.actions, [.dontWait], "as the page offers it")
    }

    func testBehaviorWhereAudioIsReadsTheSameForTheDeviceAsking() {
        XCTAssertEqual(AudioRow.words(.local, thisDevice: "this iPhone").text, "On this iPhone")
        XCTAssertEqual(AudioRow.words(.local, thisDevice: "this iPhone").symbol, "iphone")
        XCTAssertEqual(AudioRow.words(.downloadable(bytes: 12_000_000), thisDevice: "this iPhone").text, "In iCloud · \(ByteSize.format(12_000_000))")
        XCTAssertEqual(AudioRow.words(.downloadable(bytes: nil), thisDevice: "this iPhone").text, "In iCloud")
        XCTAssertEqual(AudioRow.words(.offline, thisDevice: "this iPhone").text, "Not on this iPhone yet")
        XCTAssertEqual(AudioRow.words(.missing, thisDevice: "this Mac").text, "Not in the library on this Mac")
    }
}
