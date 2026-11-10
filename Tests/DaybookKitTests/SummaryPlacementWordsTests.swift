import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// Where a summary runs, in the words both apps say it (`SummaryPlacementWords`): the countdown, the wait for a Mac, a
/// summary under way, and the choices. The page, the list row and subtitle, the inspector, Floating Notes, the menu bar,
/// and the iPhone's status sheet all say them from here, so these are the only literal copies of the words.
final class SummaryPlacementWordsTests: XCTestCase {
    private typealias Words = SummaryPlacementWords
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let studio = (id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "Studio Mac")
    private let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                    inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func preferences(_ policy: CloudSummaryPreferences.Policy) -> CloudSummaryPreferences {
        var preferences = CloudSummaryPreferences()
        preferences.policy = policy
        preferences.countdownSeconds = 15
        return preferences
    }

    // MARK: The countdown

    func testBehaviorACountdownSaysWhereAndWhen() {
        XCTAssertEqual(Words.countdown(seconds: 12), "Summarizing in 12 s")
        XCTAssertEqual(Words.countdown(on: "Studio Mac", seconds: 12), "Summarizing on Studio Mac in 12 s")
        XCTAssertEqual(Words.countdown(to: .thisDevice, thisDevice: "this Mac", seconds: 12), "Summarizing on this Mac in 12 s")
        XCTAssertEqual(Words.countdown(to: .thisDevice, thisDevice: "this iPhone", seconds: 15), "Summarizing on this iPhone in 15 s")
        XCTAssertEqual(Words.countdown(to: .mac(id: studio.id, name: studio.name), thisDevice: "this iPhone", seconds: 30),
                       "Summarizing on Studio Mac in 30 s")
        XCTAssertEqual(Words.countdown(of: "“Roadmap”", seconds: 12), "Summarizing “Roadmap” in 12 s", "The menu bar names it")
        XCTAssertEqual(Words.countdown(of: "a personal conversation", seconds: 12), "Summarizing a personal conversation in 12 s")
        XCTAssertEqual(Words.seconds(12), "12 s", "A chip with no room for the words")
        XCTAssertEqual(Words.phrase, "Summarizing in", "What a line animates on: the words without their seconds")
    }

    func testBehaviorOneSecondAndManyReadAlike() {
        // "s" is a unit, not a plural: the last second and the first read the same way, and so does a queue's count.
        XCTAssertEqual(Words.countdown(seconds: 1), "Summarizing in 1 s")
        XCTAssertEqual(Words.countdown(on: "this Mac", seconds: 1), "Summarizing on this Mac in 1 s")
        XCTAssertEqual(Words.seconds(1), "1 s")
        XCTAssertEqual(Words.countdown(of: "“Roadmap”", seconds: 1), "Summarizing “Roadmap” in 1 s")
        let queue = { (waiting: Int) in QueueStatusWords.subtitle(QueueStatusWords.Queue(countdown: self.at(12), waiting: waiting), now: self.start) }
        XCTAssertEqual(queue(0), "Summarizing in 12 s")
        XCTAssertEqual(queue(1), "Summarizing in 12 s · 1 waiting")
        XCTAssertEqual(queue(2), "Summarizing in 12 s · 2 waiting")
    }

    func testBehaviorSecondsRoundUpAndNeverFallUnderOne() {
        XCTAssertEqual(Words.secondsLeft(until: at(12), at: start), 12)
        XCTAssertEqual(Words.secondsLeft(until: at(12), at: at(0.5)), 12, "11.5 s left reads 12")
        XCTAssertEqual(Words.secondsLeft(until: at(12), at: at(11.9)), 1)
        XCTAssertEqual(Words.secondsLeft(until: at(12), at: at(12)), 1, "Never 0")
        XCTAssertEqual(Words.secondsLeft(until: at(12), at: at(30)), 1, "Nor after it ran out")
        XCTAssertEqual(Words.countdown(until: at(12), at: at(3)), "Summarizing in 9 s")
        XCTAssertEqual(Words.countdown(on: "Studio Mac", until: at(12), at: at(3)), "Summarizing on Studio Mac in 9 s")
    }

    func testBehaviorACountdownTicksInItsOwnWords() {
        XCTAssertEqual(Words.ticking("Summarizing in 12 s · 1 waiting", to: 9), "Summarizing in 9 s · 1 waiting")
        XCTAssertEqual(Words.ticking("Summarizing on Studio Mac in 12 s", to: 3), "Summarizing on Studio Mac in 3 s")
        XCTAssertEqual(Words.ticking("Summarizing on this iPhone in 15 s", until: at(15), at: at(4.5)), "Summarizing on this iPhone in 11 s")
        XCTAssertEqual(Words.ticking("12 s", to: 8), "8 s", "A chip's seconds alone move too")
        XCTAssertEqual(Words.ticking("Transcribing · 40%", to: 3), "Transcribing · 40%", "Words without a countdown stay")
        XCTAssertEqual(Words.ticking(Words.countdown(seconds: 12), to: 1), Words.countdown(seconds: 1), "It moves what it says")
    }

    // MARK: Where it runs

    func testBehaviorASummaryUnderWayNamesWhereItRuns() {
        XCTAssertEqual(Words.where(.thisDevice, thisDevice: "this Mac"), "on this Mac")
        XCTAssertEqual(Words.where(.mac(id: studio.id, name: studio.name), thisDevice: "this iPhone"), "on Studio Mac")
        XCTAssertEqual(Words.where(.cloud(sonnet), thisDevice: "this Mac"), "with Claude Sonnet 5.5")
        XCTAssertEqual(Words.running(.thisDevice, thisDevice: "this iPhone"), "Summarizing on this iPhone")
        XCTAssertEqual(Words.running(.thisDevice, thisDevice: "this iPhone"), ProcessingWords.elsewhere(.summarizing, device: "this iPhone"),
                       "As processing says work here")
        XCTAssertEqual(Words.running(.mac(id: studio.id, name: studio.name), thisDevice: "this iPhone"), "Summarizing on Studio Mac")
        XCTAssertEqual(Words.running(.cloud(sonnet), thisDevice: "this Mac"), "Summarizing with Claude Sonnet 5.5")
        XCTAssertEqual(Words.inCloud("Claude Sonnet 5.5"), "Summarizing with Claude Sonnet 5.5")
        XCTAssertEqual(Words.inCloud("Claude Sonnet 5.5", of: "“Roadmap”"), "Summarizing “Roadmap” with Claude Sonnet 5.5")
    }

    func testBehaviorWaitingForAMacAndTheChoices() {
        XCTAssertEqual(Words.waitingForMac, "Waiting for a Mac to summarize")
        XCTAssertEqual(Words.title(.useCloud), "Use the Cloud")
        XCTAssertEqual(Words.title(.startNow), "Start Now")
        XCTAssertEqual(Words.title(.waitForMac), "Wait for a Mac")
        XCTAssertEqual(SummaryPlacementPlanner.Action.allCases.map(\.title), SummaryPlacementPlanner.Action.allCases.map(Words.title))
        XCTAssertEqual(ConversationStatusPresentation.Action.placement(.useCloud).title, "Use the Cloud")
    }

    // MARK: Every surface

    func testBehaviorThePlannerSaysItsPhaseInTheseWords() {
        let options = SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: sonnet)
        let here = SummaryPlacementPlanner(options: options, preferences: preferences(.ask), at: start)
        XCTAssertEqual(here.line(at: at(3), thisDevice: "this Mac"), Words.countdown(on: "this Mac", seconds: 12))
        XCTAssertEqual(here.shortLine(at: at(3)), Words.countdown(seconds: 12))
        let mac = SummaryPlacementPlanner(options: SummaryOptions(thisDeviceCanSummarize: false, reachableMacs: [studio], cloud: sonnet),
                                          preferences: preferences(.ask), at: start, waitsForMacs: true)
        XCTAssertEqual(mac.line(at: at(0), thisDevice: "this iPhone"), Words.countdown(on: studio.name, seconds: 15))
        var waiting = SummaryPlacementPlanner(options: SummaryOptions(thisDeviceCanSummarize: false, reachableMacs: [], cloud: sonnet),
                                              preferences: preferences(.ask), at: start, waitsForMacs: true)
        XCTAssertEqual(waiting.line(at: start, thisDevice: "this iPhone"), Words.waitingForMac)
        XCTAssertEqual(waiting.shortLine(at: start), Words.waitingForMac)
        waiting.perform(.useCloud, at: at(1))
        XCTAssertEqual(waiting.line(at: at(1), thisDevice: "this iPhone"), Words.inCloud(sonnet.name))
        XCTAssertEqual(waiting.shortLine(at: at(1)), Words.inCloud(sonnet.name))

        // The list row and the queue's line count down in the same words, on the same second.
        let row = ConversationRowStatus(kind: .waiting, text: Words.countdown(seconds: 15), countdownUntil: at(15))
        XCTAssertEqual(row.text(at: at(3)), here.shortLine(at: at(3)))
        XCTAssertEqual(row.phrase, Words.phrase)
        let queue = QueueStatusWords.line(QueueStatusWords.Queue(countdown: at(15), waiting: 1), words: .mac(), now: start)
        XCTAssertEqual(queue?.text(at: at(3)), Words.countdown(seconds: 12) + " · 1 waiting")
        XCTAssertEqual(queue?.shortText, Words.countdown(seconds: 15))
    }

    func testBehaviorAPersonalConversationUnderAlwaysCountsDownInTheSameWords() {
        // ux-mac-10: Personal is never sent to the cloud on its own. Under Always it counts down as Offer First does, so
        // it reads as any countdown, with Use the Cloud a tap away; the words don't name it Personal.
        let options = SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: sonnet)
        let personal = SummaryPlacementPlanner(options: options, preferences: preferences(.always), at: start, personal: true)
        XCTAssertEqual(personal.line(at: at(3), thisDevice: "this Mac"), Words.countdown(on: "this Mac", seconds: 12))
        XCTAssertEqual(personal.shortLine(at: at(3)), Words.countdown(seconds: 12))
        XCTAssertEqual(personal.actions.map(\.title), [Words.title(.useCloud), Words.title(.startNow)])
        let offerFirst = SummaryPlacementPlanner(options: options, preferences: preferences(.ask), at: start)
        XCTAssertEqual(personal.line(at: at(3), thisDevice: "this Mac"), offerFirst.line(at: at(3), thisDevice: "this Mac"))
        // Work under Always goes to the cloud at once, and says so.
        let work = SummaryPlacementPlanner(options: options, preferences: preferences(.always), at: start)
        XCTAssertEqual(work.line(at: start, thisDevice: "this Mac"), Words.inCloud(sonnet.name))
        // With nowhere else to run it, a Personal one waits for a Mac, with Use the Cloud.
        let nowhere = SummaryPlacementPlanner(options: SummaryOptions(thisDeviceCanSummarize: false, reachableMacs: [], cloud: sonnet),
                                              preferences: preferences(.always), at: start, waitsForMacs: true, personal: true)
        XCTAssertEqual(nowhere.line(at: start, thisDevice: "this iPhone"), Words.waitingForMac)
        XCTAssertEqual(nowhere.actions.map(\.title), [Words.title(.useCloud)])
    }
}
