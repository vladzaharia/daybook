import DaybookCore
@testable import DaybookKit
import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

extension LinkEvents {
    /// The Mac as the phone last heard it describe itself.
    var peer: LinkPeer? {
        all.compactMap { event -> LinkPeer? in
            switch event {
            case .connected(let peer), .peerUpdated(let peer): return peer
            default: return nil
            }
        }.last
    }
}

/// A cloud the tests control: the models a key reaches, and summaries that wait until let go.
final class FakeCloud: CloudSummarizing, @unchecked Sendable {
    static let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                   inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)
    let models: [CloudModel]
    private let lock = NSLock()
    private var _summarized: [UUID] = []
    private var _held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(models: [CloudModel] = [FakeCloud.sonnet]) { self.models = models }

    var summarized: [UUID] { lock.withLock { _summarized } }
    var isWaiting: Bool { lock.withLock { !waiting.isEmpty } }
    /// Summaries wait until `release()`.
    func hold() { lock.withLock { _held = true } }
    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in _held = false; defer { waiting = [] }; return waiting }
        resumed.forEach { $0.resume() }
    }

    func availableModels(refresh: Bool) async -> [CloudModel] { models }

    func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel, effort: CloudEffort,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
        lock.withLock { _summarized.append(meeting.id) }
        await withCheckedContinuation { continuation in
            let held = lock.withLock { () -> Bool in if _held { waiting.append(continuation) }; return _held }
            if !held { continuation.resume() }
        }
        progress(1)
        return MeetingSummary(title: "Call", overview: "From the cloud", modelID: model.id)
    }
}

/// The Mac's summary step through the placement planner (docs/multipoint.md, "Where summaries run"): the
/// countdown, Use the Cloud and Start Now here and from a phone, summaries asked for starting at once, a
/// Mac standing down for another device's summary, and capabilities in presence and over the link. Fake
/// inference and a fake cloud; no models, no network.
@MainActor
final class SummaryPlacementProcessingTests: XCTestCase {
    private func rig(cloud: FakeCloud? = FakeCloud(), policy: CloudSummaryPreferences.Policy = .ask, seconds: Int = 15) async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self)
        rig.state.requestTiming = RequestTiming(lease: 600, renewInterval: .milliseconds(40))
        var preferences = CloudSummaryPreferences()
        preferences.policy = policy
        preferences.countdownSeconds = seconds
        rig.state.cloudPreferences = preferences
        rig.state.cloudSummarizer = cloud
        if cloud != nil { try await waitUntil("the cloud's models") { !rig.state.cloudModels.isEmpty } }
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    private func conversation(_ rig: MultiSourceRig, _ title: String, frequency: Double) async throws -> UUID {
        let audio = try rig.audio("\(title).wav", frequency: frequency)
        return try await rig.waitingConversation(title, audio: audio, script: [(0, "We ship on Friday.")])
    }

    private func countingDown(_ rig: MultiSourceRig, _ id: UUID) async throws {
        try await waitUntil("the countdown") { rig.state.placements[id]?.deadline != nil }
    }

    // MARK: On this Mac

    func testBehaviorWithoutAKeyTheSummaryStartsAtOnceAsBefore() async throws {
        let rig = try await rig(cloud: nil)
        let id = try await conversation(rig, "No key", frequency: 300)
        var counted = false
        let watch = rig.state.placements.$planners.sink { planners in if planners[id]?.deadline != nil { counted = true } }
        defer { watch.cancel() }
        rig.state.enqueue(id)
        try await rig.processed(id)
        XCTAssertFalse(counted, "Nothing to choose: no countdown")
        XCTAssertEqual(rig.inference.summarized.count, 1)
        let summary = try XCTUnwrap(rig.meeting(id)?.summary)
        XCTAssertEqual(summary.origin.deviceID, rig.state.library.thisDevice.id, "Where it ran is recorded")
        XCTAssertNil(summary.origin.cloudModel)
        XCTAssertEqual(summary.modelsByRole["summarization"], rig.state.summaryModel)
        XCTAssertEqual(summary.modelsByRole["transcription"], rig.state.transcriptionModel, "And the models behind what it read")
        XCTAssertEqual(summary.origin.colophon(thisDeviceID: rig.state.library.thisDevice.id, thisDevice: "this Mac", unknown: "this Mac"),
                       "Summarized on this Mac")
    }

    func testBehaviorWithAKeyItCountsDownThenSummarizesHere() async throws {
        let rig = try await rig(seconds: 1)
        let id = try await conversation(rig, "Countdown", frequency: 320)
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        let planner = try XCTUnwrap(rig.state.placements[id])
        XCTAssertEqual(planner.line(at: Date(), thisDevice: AppState.thisDeviceWords), "Summarizing on this Mac in 1 s")
        XCTAssertEqual(planner.actions, [.useCloud, .startNow])
        XCTAssertTrue(rig.inference.summarized.isEmpty, "Nothing runs while it counts down")
        try await rig.processed(id)
        XCTAssertEqual(rig.inference.summarized.count, 1, "The countdown ran out: here")
        let cloud = try XCTUnwrap(rig.state.cloudSummarizer as? FakeCloud)
        XCTAssertTrue(cloud.summarized.isEmpty)
        XCTAssertNil(rig.state.placements[id], "Ended with the job")
    }

    func testBehaviorTheCountdownShowsWhereProcessingStatusShows() async throws {
        let rig = try await rig(seconds: 30)
        let id = try await conversation(rig, "Shown", frequency: 330)
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        let meeting = try XCTUnwrap(rig.meeting(id))
        let row = RowStatus(state: rig.state, meeting: meeting)
        XCTAssertEqual(row.kind, .waiting)
        XCTAssertNotNil(row.countdown, "The row counts down")
        XCTAssertEqual(row.text?.hasPrefix("Summarizing in "), true)
        guard case .summaryCountdown(_, let cloud)? = FloatingStatusInputs.work(for: meeting, state: rig.state) else {
            return XCTFail("Floating Notes shows the countdown")
        }
        XCTAssertTrue(cloud)
        XCTAssertNotNil(rig.state.placementProgress(id)?.countdown, "and so do phones")
        rig.state.chooseSummaryPlacement(.startNow, for: id)
        try await rig.processed(id)
        XCTAssertNil(RowStatus(state: rig.state, meeting: try XCTUnwrap(rig.meeting(id))).countdown)
    }

    func testBehaviorStartNowSkipsTheRestOfTheCountdown() async throws {
        let rig = try await rig(seconds: 30)
        let id = try await conversation(rig, "Start now", frequency: 340)
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        rig.state.chooseSummaryPlacement(.startNow, for: id)
        try await rig.processed(id)
        XCTAssertEqual(rig.inference.summarized.count, 1)
    }

    func testBehaviorUseTheCloudSummarizesThereAndSaysSo() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, seconds: 30)
        let id = try await conversation(rig, "Cloud", frequency: 360)
        cloud.hold()
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        rig.state.chooseSummaryPlacement(.useCloud, for: id)
        try await waitUntil("the cloud to be asked") { cloud.isWaiting }
        XCTAssertEqual(rig.state.placements[id]?.line(at: Date(), thisDevice: AppState.thisDeviceWords), "Summarizing with Claude Sonnet 5.5")
        cloud.release()
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertTrue(rig.inference.summarized.isEmpty, "Not here too")
        let summary = try XCTUnwrap(rig.meeting(id)?.summary)
        XCTAssertEqual(summary.overview, "From the cloud")
        XCTAssertEqual(summary.origin.cloudModel, "Claude Sonnet 5.5")
        XCTAssertEqual(summary.origin.deviceID, rig.state.library.thisDevice.id, "Sent by this Mac")
        XCTAssertEqual(summary.modelsByRole["summarization"], "claude-sonnet-5-5")
        XCTAssertEqual(summary.origin.colophon(thisDeviceID: rig.state.library.thisDevice.id, thisDevice: "this Mac", unknown: "this Mac"),
                       "Summarized with Claude Sonnet 5.5")
    }

    func testBehaviorAlwaysUsesTheCloudWithoutACountdown() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .always)
        let id = try await conversation(rig, "Always", frequency: 380)
        rig.state.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertTrue(rig.inference.summarized.isEmpty)
    }

    func testBehaviorNeverKeepsTheKeyAndSummarizesHereAtOnce() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .never)
        let id = try await conversation(rig, "Never", frequency: 390)
        rig.state.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(rig.inference.summarized.count, 1)
        XCTAssertTrue(cloud.summarized.isEmpty)
    }

    func testBehaviorSummarizeAgainStartsAtOnce() async throws {
        let rig = try await rig(seconds: 30)
        let id = try await conversation(rig, "Again", frequency: 400)
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        rig.state.chooseSummaryPlacement(.startNow, for: id)
        try await rig.processed(id)
        var counted = false
        let watch = rig.state.placements.$planners.sink { planners in if planners[id]?.deadline != nil { counted = true } }
        defer { watch.cancel() }
        rig.state.enqueue(id, mode: .summaryOnly)
        try await waitUntil("the second summary") { rig.inference.summarized.count == 2 }
        try await rig.processed(id)
        XCTAssertFalse(counted, "The person asked: no countdown")
    }

    func testBehaviorAPhonesSummaryRequestStartsAtOnce() async throws {
        let rig = try await rig(seconds: 30)
        let id = try await conversation(rig, "Phone asks", frequency: 420)
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        rig.state.chooseSummaryPlacement(.startNow, for: id)
        try await rig.processed(id)
        // The phone counted down already (or the person asked there): this Mac starts at once.
        rig.state.library.requestProcessing(id, mode: .summaryOnly, by: .phone)
        var counted = false
        let watch = rig.state.placements.$planners.sink { planners in if planners[id]?.deadline != nil { counted = true } }
        defer { watch.cancel() }
        rig.state.pickUpRequests()
        try await rig.processed(id)
        XCTAssertFalse(counted)
        XCTAssertEqual(rig.inference.summarized.count, 2)
        XCTAssertEqual(rig.meeting(id)?.processingRequests?.first?.outcome?.result, .completed)
    }

    func testBehaviorAPhonesRequestJoiningACountdownStartsItNow() async throws {
        let rig = try await rig(seconds: 60)
        let id = try await conversation(rig, "Joining", frequency: 430)
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        // The phone's own countdown for this conversation ran out and sent the request: no second wait.
        rig.state.library.requestProcessing(id, mode: .summaryOnly, by: .phone)
        rig.state.pickUpRequests()
        try await rig.processed(id)
        XCTAssertEqual(rig.inference.summarized.count, 1, "One summary, carrying the phone's request")
        XCTAssertEqual(rig.meeting(id)?.processingRequests?.first?.outcome?.result, .completed)
    }

    func testBehaviorPausingDuringTheCountdownPausesTheJob() async throws {
        let rig = try await rig(seconds: 60)
        let id = try await conversation(rig, "Pause", frequency: 440)
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        rig.state.pauseProcessing(id)
        try await rig.processed()
        XCTAssertTrue(rig.state.pausedIDs.contains(id))
        XCTAssertNil(rig.state.placements[id])
        XCTAssertTrue(rig.inference.summarized.isEmpty)
        XCTAssertEqual(rig.state.processingStatus(for: try XCTUnwrap(rig.meeting(id))), .requested(.paused))
    }

    // MARK: Never twice

    func testBehaviorAnotherDeviceHoldingTheSummaryMakesThisMacStandDown() async throws {
        let rig = try await rig(seconds: 60)
        let id = try await conversation(rig, "Stand down", frequency: 460)
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        // The phone chose the cloud while this Mac counted down; its claim arrives through sync.
        let phone = ProcessingRequest.Device.phone
        let request = ProcessingRequest(meetingID: id, mode: .summaryOnly, requestedBy: phone)
        let claimed = try XCTUnwrap(request.claimed(by: phone, at: Date()))
        rig.state.update(id) { $0.upsertProcessingRequest(claimed) }
        rig.state.chooseSummaryPlacement(.startNow, for: id)
        try await rig.processed()
        XCTAssertTrue(rig.inference.summarized.isEmpty, "The phone has it: not summarized here too")
        XCTAssertNotEqual(rig.meeting(id)?.status, .failed)
        XCTAssertNil(rig.meeting(id)?.summary)
        // What the Mac shows meanwhile: the phone at work.
        if case .processing(let progress) = rig.state.processingStatus(for: try XCTUnwrap(rig.meeting(id))) {
            XCTAssertEqual(progress.device, phone)
        } else { XCTFail("The phone's work shows") }
    }

    func testBehaviorASummaryAnotherDeviceWroteMeanwhileIsKept() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, seconds: 60)
        let id = try await conversation(rig, "Kept", frequency: 480)
        cloud.hold()
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        rig.state.chooseSummaryPlacement(.useCloud, for: id)
        try await waitUntil("the cloud to be asked") { cloud.isWaiting }
        // A summary from the phone lands through sync while the cloud works here.
        let phone = ProcessingRequest.Device.phone
        let theirs = MeetingSummary(title: "Call", overview: "From the phone", modelID: "gemma", createdAt: Date())
            .placed(.thisDevice, by: phone, inputs: [:])
        rig.state.update(id) { $0.setSummary(theirs) }
        cloud.release()
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.summary?.overview, "From the phone", "One summary per conversation")
        XCTAssertEqual(rig.meeting(id)?.status, .ready)
    }

    // MARK: A phone

    func testBehaviorAPhoneSeesTheCountdownAndChoosesTheCloud() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, seconds: 60)
        let phone = try await PhoneLinkRig.connect(rig.state)
        let id = try await conversation(rig, "From the phone", frequency: 500)
        rig.state.enqueue(id)
        try await countingDown(rig, id)
        try await waitUntil("the phone to hear the countdown") {
            phone.events.progress.contains { $0.meetingID == id && $0.phase == .summaryCountdown }
        }
        let countdown = try XCTUnwrap(phone.events.progress.last { $0.phase == .summaryCountdown }?.countdown)
        XCTAssertTrue(countdown.cloudOffered)
        XCTAssertGreaterThan(countdown.secondsLeft, 50)
        XCTAssertTrue(phone.events.peer?.capabilities.placesSummaries == true)
        try await phone.client.send(.summaryChoice(LinkSummaryChoice(meetingID: id, choice: .useCloud)), to: phone.macID)
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertTrue(rig.inference.summarized.isEmpty)
        try await waitUntil("the phone to hear the cloud") { phone.events.progress.contains { $0.cloudModel == "Claude Sonnet 5.5" } }
        await phone.tearDown(rig.state)
    }

    func testBehaviorCapabilitiesTravelInPresenceAndOverTheLink() async throws {
        let rig = try await rig(cloud: nil)
        let capabilities = rig.state.processingCapabilities
        XCTAssertTrue(capabilities.transcribes)
        XCTAssertTrue(capabilities.summarizes)
        XCTAssertEqual(capabilities.models?["summarization"], rig.state.summaryModel)
        XCTAssertEqual(capabilities.models?["transcription"], rig.state.transcriptionModel)
        rig.state.presenceChanged()
        XCTAssertEqual(rig.state.sync.replica.device?.capabilities, capabilities.presence)
        let phone = try await PhoneLinkRig.connect(rig.state)
        try await waitUntil("the phone to read them") { phone.events.peer?.capabilities.processing?.summarizes == true }
        XCTAssertEqual(phone.events.peer?.capabilities.processing?.models?["summarization"], rig.state.summaryModel)
        // Taking no work from other devices, it offers them nothing.
        rig.state.processSyncedAudio = false
        XCTAssertEqual(rig.state.sync.replica.device?.capabilities, ProcessingCapabilities.none.presence)
        try await waitUntil("the phone to hear it") { phone.events.peer?.capabilities.processing?.summarizes == false }
        // Without the summary model it doesn't summarize.
        rig.state.processSyncedAudio = true
        rig.state.installedModels.remove(rig.state.summaryModel)
        XCTAssertFalse(rig.state.processingCapabilities.summarizes)
        XCTAssertNil(rig.state.processingCapabilities.models?["summarization"])
        await phone.tearDown(rig.state)
    }
}
