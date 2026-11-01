import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Where a summary runs and the countdown before it (docs/multipoint.md, "Where summaries run"): every
/// transition of `SummaryPlacementPlanner`, driven by a clock of the test's own, and `SummaryPlacements`
/// keeping one per conversation.
final class SummaryPlacementTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let studio = (id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "Studio Mac")
    private let laptop = (id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, name: "Vlad’s MacBook Pro")
    private let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                    inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)

    private func options(local: Bool = false, macs: [(id: UUID, name: String)] = [], cloud: Bool = true) -> SummaryOptions {
        SummaryOptions(thisDeviceCanSummarize: local, reachableMacs: macs, cloud: cloud ? sonnet : nil)
    }

    private func preferences(_ policy: CloudSummaryPreferences.Policy = .ask, seconds: Int = 15) -> CloudSummaryPreferences {
        var preferences = CloudSummaryPreferences()
        preferences.policy = policy
        preferences.countdownSeconds = seconds
        return preferences
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: Starting

    func testBehaviorCountsDownToThisDeviceWhenItCanSummarizeAndTheCloudIsOffered() {
        let planner = SummaryPlacementPlanner(options: options(local: true, macs: [studio]), preferences: preferences(), at: start)
        XCTAssertEqual(planner.phase, .countingDown(to: .thisDevice, until: at(15)), "This device first, even with a Mac around")
        XCTAssertEqual(planner.actions, [.useCloud, .startNow])
        XCTAssertEqual(planner.secondsLeft(at: at(2.5)), 13)
    }

    func testBehaviorTheCountdownLastsTheSetting() {
        let planner = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(seconds: 30), at: start)
        XCTAssertEqual(planner.deadline, at(30))
    }

    func testBehaviorCountsDownToAReachableMacWhenThisDeviceCannotSummarize() {
        let planner = SummaryPlacementPlanner(options: options(macs: [laptop, studio]), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertEqual(planner.phase, .countingDown(to: .mac(id: laptop.id, name: laptop.name), until: at(15)))
        XCTAssertEqual(planner.actions, [.useCloud, .startNow], "Wait for a Mac applies only to this device's own countdown")
    }

    func testBehaviorWaitsForAMacWithTheCloudOfferedWhenNothingCanSummarize() {
        let planner = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertEqual(planner.phase, .waitingForMac)
        XCTAssertNil(planner.deadline, "No countdown while there's no Mac")
        XCTAssertEqual(planner.actions, [.useCloud])
    }

    func testBehaviorWithNothingAnywhereItWaitsAsBefore() {
        let planner = SummaryPlacementPlanner(options: options(cloud: false), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertEqual(planner.phase, .waiting)
        XCTAssertEqual(planner.actions, [])
    }

    func testBehaviorWithoutAKeyNothingIsOfferedAndItStartsAtOnce() {
        let here = SummaryPlacementPlanner(options: options(local: true, cloud: false), preferences: preferences(), at: start)
        XCTAssertEqual(here.phase, .started(.thisDevice), "Nothing to choose, so no countdown")
        let mac = SummaryPlacementPlanner(options: options(macs: [studio], cloud: false), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertEqual(mac.phase, .started(.mac(id: studio.id, name: studio.name)))
    }

    func testBehaviorNeverKeepsTheKeyButNeverOffersTheCloud() {
        var planner = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(.never), at: start)
        XCTAssertNil(planner.cloud)
        XCTAssertEqual(planner.phase, .started(.thisDevice))
        let waiting = SummaryPlacementPlanner(options: options(), preferences: preferences(.never), at: start, waitsForMacs: true)
        XCTAssertEqual(waiting.phase, .waiting, "With Never and nowhere to run it, it waits as before")
        XCTAssertFalse(planner.perform(.useCloud, at: start))
    }

    func testBehaviorAlwaysSkipsTheCountdownForTheCloud() {
        let planner = SummaryPlacementPlanner(options: options(local: true, macs: [studio]), preferences: preferences(.always), at: start)
        XCTAssertEqual(planner.phase, .started(.cloud(sonnet)))
        // Always without a key: nothing to send it to, so it's as if there were no cloud.
        let withoutKey = SummaryPlacementPlanner(options: options(local: true, cloud: false), preferences: preferences(.always), at: start)
        XCTAssertEqual(withoutKey.phase, .started(.thisDevice))
    }

    func testBehaviorAskedForItStartsAtOnceWhereItCan() {
        let here = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start, immediately: true)
        XCTAssertEqual(here.phase, .started(.thisDevice), "Summarize Again and another device's request skip the countdown")
        let mac = SummaryPlacementPlanner(options: options(macs: [studio]), preferences: preferences(), at: start, immediately: true, waitsForMacs: true)
        XCTAssertEqual(mac.phase, .started(.mac(id: studio.id, name: studio.name)))
        let cloud = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(.always), at: start, immediately: true)
        XCTAssertEqual(cloud.phase, .started(.cloud(sonnet)))
        let nowhere = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, immediately: true, waitsForMacs: true)
        XCTAssertEqual(nowhere.phase, .waitingForMac, "Asked for with nowhere to run it, the cloud is still offered")
    }

    // MARK: The person's choices

    func testBehaviorTheCountdownRunningOutStartsTheDefault() {
        var planner = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start)
        planner.advance(to: at(14.9))
        XCTAssertEqual(planner.phase, .countingDown(to: .thisDevice, until: at(15)))
        XCTAssertEqual(planner.secondsLeft(at: at(14.9)), 1)
        planner.advance(to: at(15))
        XCTAssertEqual(planner.phase, .started(.thisDevice))
        XCTAssertEqual(planner.actions, [])
    }

    func testBehaviorUseTheCloudDuringACountdownOrWhileWaiting() {
        var counting = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start)
        XCTAssertTrue(counting.perform(.useCloud, at: at(3)))
        XCTAssertEqual(counting.phase, .started(.cloud(sonnet)))
        var waiting = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertTrue(waiting.perform(.useCloud, at: at(60)))
        XCTAssertEqual(waiting.started, .cloud(sonnet))
    }

    func testBehaviorStartNowStartsTheDefaultAtOnce() {
        var planner = SummaryPlacementPlanner(options: options(macs: [studio]), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertTrue(planner.perform(.startNow, at: at(1)))
        XCTAssertEqual(planner.phase, .started(.mac(id: studio.id, name: studio.name)))
    }

    func testBehaviorWaitForAMacPassesOverThisDevice() {
        var reachable = SummaryPlacementPlanner(options: options(local: true, macs: [studio]), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertEqual(reachable.actions, [.useCloud, .startNow, .waitForMac])
        XCTAssertTrue(reachable.perform(.waitForMac, at: at(2)))
        XCTAssertEqual(reachable.phase, .started(.mac(id: studio.id, name: studio.name)), "The person chose the Mac: it gets it now")

        var away = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertTrue(away.perform(.waitForMac, at: at(2)))
        XCTAssertEqual(away.phase, .waitingForMac)
        XCTAssertTrue(away.prefersMac)
        // This device still can, but the person chose a Mac: when one arrives, it counts down to it.
        away.update(options: options(local: true, macs: [laptop]), at: at(40))
        XCTAssertEqual(away.phase, .countingDown(to: .mac(id: laptop.id, name: laptop.name), until: at(55)))
        XCTAssertEqual(away.actions, [.useCloud, .startNow])
    }

    func testBehaviorWaitForAMacIsNotOfferedOnAMac() {
        var planner = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start, waitsForMacs: false)
        XCTAssertFalse(planner.actions.contains(.waitForMac))
        XCTAssertFalse(planner.perform(.waitForMac, at: at(1)))
        XCTAssertEqual(planner.phase, .countingDown(to: .thisDevice, until: at(15)))
    }

    func testBehaviorChoicesThatDontApplyChangeNothing() {
        var waiting = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertFalse(waiting.perform(.startNow, at: at(1)), "Nothing to start while waiting for a Mac")
        XCTAssertEqual(waiting.phase, .waitingForMac)
        var started = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start)
        started.perform(.startNow, at: at(1))
        XCTAssertFalse(started.perform(.useCloud, at: at(2)), "Started is final")
        XCTAssertEqual(started.phase, .started(.thisDevice))
    }

    // MARK: When what's on offer changes

    func testBehaviorAMacArrivingWhileWaitingStartsAFreshCountdown() {
        var planner = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, waitsForMacs: true)
        planner.update(options: options(macs: [studio]), at: at(300))
        XCTAssertEqual(planner.phase, .countingDown(to: .mac(id: studio.id, name: studio.name), until: at(315)))
        planner.advance(to: at(315))
        XCTAssertEqual(planner.phase, .started(.mac(id: studio.id, name: studio.name)))
    }

    func testBehaviorAMacArrivingWhenNothingWasOfferedStartsAtOnce() {
        var planner = SummaryPlacementPlanner(options: options(cloud: false), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertEqual(planner.phase, .waiting)
        planner.update(options: options(macs: [studio], cloud: false), at: at(30))
        XCTAssertEqual(planner.phase, .started(.mac(id: studio.id, name: studio.name)))
    }

    func testBehaviorTheMacGoingAwayMidCountdownMovesToAnotherOrWaits() {
        var planner = SummaryPlacementPlanner(options: options(macs: [studio, laptop]), preferences: preferences(), at: start, waitsForMacs: true)
        planner.update(options: options(macs: [laptop]), at: at(5))
        XCTAssertEqual(planner.phase, .countingDown(to: .mac(id: laptop.id, name: laptop.name), until: at(15)), "Another Mac, same deadline")
        planner.update(options: options(), at: at(8))
        XCTAssertEqual(planner.phase, .waitingForMac)
        XCTAssertNil(planner.deadline)
    }

    func testBehaviorThisDeviceStoppingMidCountdownMovesToAMac() {
        var planner = SummaryPlacementPlanner(options: options(local: true, macs: [studio]), preferences: preferences(), at: start, waitsForMacs: true)
        planner.update(options: options(macs: [studio]), at: at(4))
        XCTAssertEqual(planner.phase, .countingDown(to: .mac(id: studio.id, name: studio.name), until: at(15)))
        var alone = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start, waitsForMacs: true)
        alone.update(options: options(), at: at(4))
        XCTAssertEqual(alone.phase, .waitingForMac)
    }

    func testBehaviorThisDeviceBecomingAbleMidCountdownTakesItBack() {
        var planner = SummaryPlacementPlanner(options: options(macs: [studio]), preferences: preferences(), at: start, waitsForMacs: true)
        planner.update(options: options(local: true, macs: [studio]), at: at(6))
        XCTAssertEqual(planner.phase, .countingDown(to: .thisDevice, until: at(15)))
    }

    func testBehaviorAMacArrivingMidCountdownToThisDeviceChangesNothing() {
        var planner = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start, waitsForMacs: true)
        planner.update(options: options(local: true, macs: [studio]), at: at(6))
        XCTAssertEqual(planner.phase, .countingDown(to: .thisDevice, until: at(15)))
    }

    func testBehaviorTheKeyRemovedMidCountdownStartsTheDefaultNow() {
        var planner = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start)
        planner.update(options: options(local: true, cloud: false), at: at(3))
        XCTAssertEqual(planner.phase, .started(.thisDevice), "The countdown was there to offer the cloud")
        var toMac = SummaryPlacementPlanner(options: options(macs: [studio]), preferences: preferences(), at: start, waitsForMacs: true)
        toMac.update(preferences: preferences(.never), at: at(3))
        XCTAssertEqual(toMac.phase, .started(.mac(id: studio.id, name: studio.name)), "Never: the same, kept keys or not")
    }

    func testBehaviorTheKeyRemovedOrAddedWhileWaiting() {
        var planner = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, waitsForMacs: true)
        planner.update(options: options(cloud: false), at: at(3))
        XCTAssertEqual(planner.phase, .waiting)
        planner.update(options: options(), at: at(9))
        XCTAssertEqual(planner.phase, .waitingForMac, "A key added offers the cloud")
        XCTAssertEqual(planner.actions, [.useCloud])
    }

    func testBehaviorAKeyAddedOffersTheCloudWithoutRestarting() {
        var planner = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start)
        let other = CloudModel(provider: .openai, id: "gpt-6.1-sol", name: "GPT-6.1 Sol", tier: .balanced, inputPrice: 2, outputPrice: 10,
                               priceIsEstimated: false, contextTokens: 400_000, rank: 2)
        planner.update(options: SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: other), at: at(5))
        XCTAssertEqual(planner.deadline, at(15))
        XCTAssertTrue(planner.perform(.useCloud, at: at(6)))
        XCTAssertEqual(planner.started, .cloud(other))
    }

    func testBehaviorAlwaysChosenMidCountdownSendsItToTheCloud() {
        var planner = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start)
        planner.update(preferences: preferences(.always), at: at(2))
        XCTAssertEqual(planner.phase, .started(.cloud(sonnet)))
    }

    func testBehaviorStartedIsFinalWhateverChanges() {
        var planner = SummaryPlacementPlanner(options: options(macs: [studio]), preferences: preferences(), at: start, waitsForMacs: true)
        planner.perform(.startNow, at: at(1))
        planner.update(options: options(local: true), preferences: preferences(.always), at: at(2))
        XCTAssertEqual(planner.phase, .started(.mac(id: studio.id, name: studio.name)))
    }

    // MARK: Words

    func testBehaviorTheLineSaysWhereAndWhen() {
        let here = SummaryPlacementPlanner(options: options(local: true), preferences: preferences(), at: start)
        XCTAssertEqual(here.line(at: at(3), thisDevice: "this Mac"), "Summarizing on this Mac in 12 s")
        XCTAssertEqual(here.shortLine(at: at(3)), "Summarizing in 12 s")
        let mac = SummaryPlacementPlanner(options: options(macs: [laptop]), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertEqual(mac.line(at: at(0), thisDevice: "this iPhone"), "Summarizing on Vlad’s MacBook Pro in 15 s")
        let waiting = SummaryPlacementPlanner(options: options(), preferences: preferences(), at: start, waitsForMacs: true)
        XCTAssertEqual(waiting.line(at: at(0), thisDevice: "this iPhone"), "Waiting for a Mac to summarize")
        var cloud = waiting
        cloud.perform(.useCloud, at: at(1))
        XCTAssertEqual(cloud.line(at: at(1), thisDevice: "this iPhone"), "Summarizing with Claude Sonnet 5.5")
        let started = SummaryPlacementPlanner(options: options(local: true, cloud: false), preferences: preferences(), at: start)
        XCTAssertNil(started.line(at: at(0), thisDevice: "this Mac"), "The processing status says the rest")
        XCTAssertEqual(SummaryPlacementPlanner.Action.allCases.map(\.title), ["Use the Cloud", "Start Now", "Wait for a Mac"])
    }

    // MARK: Preferences

    func testBehaviorPreferencesResolveToTheChosenModelOrTheTiersBest() {
        let opus = CloudModel(provider: .anthropic, id: "claude-opus-5-5", name: "Claude Opus 5.5", tier: .best, inputPrice: 4, outputPrice: 20,
                              priceIsEstimated: false, contextTokens: nil, rank: 1)
        let sol = CloudModel(provider: .openai, id: "gpt-6.1-sol", name: "GPT-6.1 Sol", tier: .balanced, inputPrice: 2, outputPrice: 10,
                             priceIsEstimated: false, contextTokens: nil, rank: 2)
        var preferences = CloudSummaryPreferences()
        XCTAssertEqual(preferences.resolve(in: [sol, opus, sonnet]), sonnet, "Balanced, lowest rank")
        XCTAssertEqual(preferences.resolve(in: [sol, opus]), sol)
        XCTAssertEqual(preferences.resolve(in: [opus]), opus, "Another tier when the chosen one has none")
        preferences.model = opus.id
        XCTAssertEqual(preferences.resolve(in: [sol, opus, sonnet]), opus)
        preferences.model = "gone"
        XCTAssertEqual(preferences.resolve(in: [sol, sonnet]), sonnet, "A chosen model no key reaches falls back to the tier")
        XCTAssertNil(preferences.resolve(in: []), "No key, no model")
        preferences.policy = .never
        XCTAssertNil(preferences.resolve(in: [sonnet]))
    }

    func testBehaviorPreferencesAreStoredAndReadBack() {
        let defaults = makeTestDefaults()
        XCTAssertEqual(CloudSummaryPreferences.stored(in: defaults), CloudSummaryPreferences())
        var preferences = CloudSummaryPreferences()
        preferences.countdownSeconds = 30
        preferences.policy = .always
        preferences.store(in: defaults)
        XCTAssertEqual(CloudSummaryPreferences.stored(in: defaults), preferences)
    }

    // MARK: Every conversation on a device

    @MainActor
    func testBehaviorPlacementsKeepOnePlannerPerConversationAndSayWhenEachSettles() {
        var now = start
        let placements = SummaryPlacements(options: options(local: true), preferences: preferences(), waitsForMacs: false,
                                           clock: { now }, runsTimer: false)
        var settled: [(UUID, SummaryPlacementPlanner.Phase)] = []
        placements.onSettled = { settled.append(($0, $1)) }
        let a = UUID(), b = UUID()
        XCTAssertNil(placements.begin(a))
        now = at(5)
        XCTAssertNil(placements.begin(b))
        XCTAssertEqual(Set(placements.undecided), [a, b])
        now = at(15)
        placements.advance()
        XCTAssertEqual(settled.map(\.0), [a])
        XCTAssertEqual(placements[a]?.started, .thisDevice)
        XCTAssertEqual(placements[b]?.deadline, at(20))
        XCTAssertTrue(placements.perform(.useCloud, for: b))
        XCTAssertEqual(settled.last?.1, .started(.cloud(sonnet)))
        placements.end(a)
        XCTAssertNil(placements[a])
        XCTAssertEqual(placements[b]?.line(at: now, thisDevice: "this Mac"), "Summarizing with Claude Sonnet 5.5", "Kept until the app ends it")
    }

    @MainActor
    func testBehaviorAChangeOfOptionsReachesEveryCountdown() {
        let now = start
        let placements = SummaryPlacements(options: options(), preferences: preferences(), waitsForMacs: true, clock: { now }, runsTimer: false)
        let a = UUID(), b = UUID()
        placements.begin(a)
        placements.begin(b)
        XCTAssertEqual(placements[a]?.phase, .waitingForMac)
        placements.update(options: options(macs: [studio]))
        XCTAssertEqual(placements[a]?.phase, .countingDown(to: .mac(id: studio.id, name: studio.name), until: at(15)))
        XCTAssertEqual(placements[b]?.phase, .countingDown(to: .mac(id: studio.id, name: studio.name), until: at(15)))
        // A new conversation sees the latest options too.
        let c = UUID()
        placements.begin(c)
        XCTAssertEqual(placements[c]?.deadline, at(15))
    }

    @MainActor
    func testBehaviorLeavingTheScreenStartsEveryCountdownsDefault() {
        let now = start
        let placements = SummaryPlacements(options: options(macs: [studio]), preferences: preferences(), waitsForMacs: true, clock: { now }, runsTimer: false)
        var settled: [UUID] = []
        placements.onSettled = { id, _ in settled.append(id) }
        let a = UUID()
        placements.begin(a)
        placements.startDefaultsNow()
        XCTAssertEqual(settled, [a])
        XCTAssertEqual(placements[a]?.started, .mac(id: studio.id, name: studio.name))
    }

    @MainActor
    func testBehaviorBeingAskedDuringACountdownStartsItNow() {
        let now = start
        let placements = SummaryPlacements(options: options(local: true), preferences: preferences(), waitsForMacs: false, clock: { now }, runsTimer: false)
        let a = UUID()
        XCTAssertNil(placements.begin(a))
        XCTAssertEqual(placements.begin(a, immediately: true), .thisDevice, "Another device's request for it: no second countdown")
    }

    @MainActor
    func testBehaviorWaitingForThePlaceReturnsWhenItStartsOrEnds() async throws {
        var now = start
        let placements = SummaryPlacements(options: options(local: true), preferences: preferences(), waitsForMacs: false, clock: { now }, runsTimer: false)
        let a = UUID(), b = UUID()
        let first = Task { await placements.place(a) }
        try await waitUntil("the first to count down") { placements[a] != nil }
        now = at(10)
        let second = Task { await placements.place(b) }
        try await waitUntil("the second to count down") { placements[b] != nil }
        now = at(15)
        placements.advance()
        let firstPlace = await first.value
        XCTAssertEqual(firstPlace, .thisDevice)
        XCTAssertEqual(placements[b]?.deadline, at(25))
        placements.end(b)
        let secondPlace = await second.value
        XCTAssertNil(secondPlace, "Ended (paused) before it started")
        // Cancelling the waiting job ends its countdown.
        let c = UUID()
        let third = Task { await placements.place(c) }
        try await waitUntil("the third to count down") { placements[c] != nil }
        third.cancel()
        let thirdPlace = await third.value
        XCTAssertNil(thirdPlace)
        try await waitUntil("the countdown to end") { placements[c] == nil }
    }

    @MainActor
    func testBehaviorTheTimerStartsTheDefaultOnItsOwn() async throws {
        var preferences = preferences(seconds: 1)
        preferences.countdownSeconds = 1
        let placements = SummaryPlacements(options: options(local: true), preferences: preferences, waitsForMacs: false)
        let place = await placements.place(UUID())
        XCTAssertEqual(place, .thisDevice)
    }
}
