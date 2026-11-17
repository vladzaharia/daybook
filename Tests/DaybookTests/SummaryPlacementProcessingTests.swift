import DaybookCore
import DaybookDesign
import DaybookIntelligence
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

    /// What a summary says, from the conversation as it read it.
    var overview: @Sendable (Meeting) -> String = { _ in "From the cloud" }
    /// Every summary throws this, when set, as the provider would.
    var failure: (any Error & Sendable)? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    private var _failure: (any Error & Sendable)?

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
        if let failure { throw failure }
        lock.withLock { _summarized.append(meeting.id) }
        await withCheckedContinuation { continuation in
            let held = lock.withLock { () -> Bool in if _held { waiting.append(continuation) }; return _held }
            if !held { continuation.resume() }
        }
        progress(1)
        return MeetingSummary(title: "Call", overview: overview(meeting), modelID: model.id)
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
        // A Mac the summary model fits, whatever runs the tests (CI's runners have 7 GB).
        rig.state.physicalMemory = 64 << 30
        var preferences = CloudSummaryPreferences()
        preferences.policy = policy
        preferences.countdownSeconds = seconds
        // Settings › Cloud as the app has it: an in-memory Anthropic key (or none) and the catalog's models.
        rig.state.cloud = CloudSetup.demo(providers: cloud == nil ? [] : [.anthropic], preferences: preferences,
                                          defaults: makeTestDefaults("SummaryPlacementProcessingTests"))
        if let cloud { rig.state.cloudSummarizer = cloud }
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    private func conversation(_ rig: MultiSourceRig, _ title: String, frequency: Double) async throws -> UUID {
        let audio = try rig.audio("\(title).wav", frequency: frequency)
        return try await rig.waitingConversation(title, audio: audio, script: [(0, "We ship on Friday.")])
    }

    /// A conversation of a thousand passages: far longer than Gemma 4 E4B reads in one pass.
    private func longConversation(_ rig: MultiSourceRig, _ title: String, frequency: Double) async throws -> UUID {
        let audio = try rig.audio("\(title).wav", frequency: frequency)
        let script = (0..<1_000).map { (Double($0) * 5, "We went over item number \($0) of the quarterly planning review.") }
        return try await rig.waitingConversation(title, audio: audio, script: script)
    }

    /// This Mac summarizes with Gemma 4 E4B, which the cloud's Claude Sonnet 5.5 ranks clearly above (53 against 94).
    private func smallModel(_ rig: MultiSourceRig) {
        rig.state.summaryModel = "gemma-4/e4b-4bit"
        rig.state.installedModels.insert("gemma-4/e4b-4bit")
    }

    private func countingDown(_ rig: MultiSourceRig, _ id: UUID) async throws {
        try await waitUntil("the countdown") { rig.state.placements[id]?.deadline != nil }
    }

    // MARK: On this Mac

    func testBehaviorTheNoCountdownCheckSeesOneThatEndsInTheTurnItBegan() {
        let placements = SummaryPlacements(options: SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: FakeCloud.sonnet),
                                           preferences: CloudSummaryPreferences(), waitsForMacs: false, runsTimer: false)
        var told: [UUID] = []
        placements.onChange = { told.append($0) }
        let id = UUID()
        let counted = CountdownSeen(placements, for: id)
        placements.begin(id)
        XCTAssertNotNil(placements[id]?.deadline, "A cloud on offer: a countdown")
        placements.end(id)
        XCTAssertTrue(counted.happened, "Begun and ended in one turn, it still counts")
        XCTAssertEqual(told, [id, id], "What heard each change before still does")
        counted.cancel()
        placements.begin(UUID())
        XCTAssertEqual(told.count, 3, "Cancelled, the handler is the one it was")
    }

    func testBehaviorWithoutAKeyTheSummaryStartsAtOnceAsBefore() async throws {
        let rig = try await rig(cloud: nil)
        let id = try await conversation(rig, "No key", frequency: 300)
        let counted = CountdownSeen(rig.state.placements, for: id)
        defer { counted.cancel() }
        rig.state.processor.enqueue(id)
        try await rig.processed(id)
        XCTAssertFalse(counted.happened, "Nothing to choose: no countdown")
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
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        let planner = try XCTUnwrap(rig.state.placements[id])
        XCTAssertEqual(planner.line(at: Date(), thisDevice: AppState.thisDeviceWords), SummaryPlacementWords.countdown(on: AppState.thisDeviceWords, seconds: 1))
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
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        let meeting = try XCTUnwrap(rig.meeting(id))
        let row = try XCTUnwrap(MacRowStatus.make(rig.state, meeting))
        XCTAssertEqual(row.kind, .waiting)
        XCTAssertNotNil(row.countdownUntil, "The row counts down")
        XCTAssertEqual(row.text?.hasPrefix(SummaryPlacementWords.phrase), true)
        // VM-16: the list's subtitle counts down to the same moment, on the same ticks, so the two say the same number.
        let until = try XCTUnwrap(row.countdownUntil)
        XCTAssertEqual(MacListSubtitle.countdown(rig.state), until, "the subtitle ticks on the row's deadline")
        let tick = CountdownPhase.tick(before: until, at: Date())
        for offset in [0.0, 1, 2.5, 7] {
            let moment = tick.addingTimeInterval(offset)
            XCTAssertEqual(MacListSubtitle.text(rig.state, results: 0, at: moment), row.text(at: moment), "\(offset) s on")
        }
        let chip = FloatingStatus.workChip(FloatingStatusInputs.conversation(meeting, state: rig.state), words: rig.state.statusWords, models: nil)
        XCTAssertNotNil(chip?.countdownUntil, "Floating Notes shows the countdown")
        XCTAssertNotNil(rig.state.placements[id]?.cloud, "with Use the Cloud in its menu")
        XCTAssertNotNil(rig.state.placementProgress(id)?.countdown, "and so do phones")
        rig.state.chooseSummaryPlacement(.startNow, for: id)
        try await rig.processed(id)
        XCTAssertNil(MacRowStatus.make(rig.state, try XCTUnwrap(rig.meeting(id)))?.countdownUntil)
    }

    func testBehaviorStartNowSkipsTheRestOfTheCountdown() async throws {
        let rig = try await rig(seconds: 30)
        let id = try await conversation(rig, "Start now", frequency: 340)
        rig.state.processor.enqueue(id)
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
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        rig.state.chooseSummaryPlacement(.useCloud, for: id)
        try await waitUntil("the cloud to be asked") { cloud.isWaiting }
        XCTAssertEqual(rig.state.placements[id]?.line(at: Date(), thisDevice: AppState.thisDeviceWords), SummaryPlacementWords.inCloud("Claude Sonnet 5.5"))
        cloud.release()
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertTrue(rig.inference.summarized.isEmpty, "Not here too")
        let summary = try XCTUnwrap(rig.meeting(id)?.summary)
        XCTAssertEqual(summary.overview, "From the cloud")
        XCTAssertEqual(summary.origin.cloudModel, "Claude Sonnet 5.5")
        XCTAssertEqual(summary.origin.deviceID, rig.state.library.thisDevice.id, "Sent by this Mac")
        XCTAssertEqual(summary.modelsByRole["summarization"], "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(summary.cloudProvenance?.model, "claude-sonnet-5-5", "Named the way the cloud names it")
        XCTAssertEqual(summary.cloudProvenance?.sentBy, rig.state.library.thisDevice.name)
        XCTAssertEqual(summary.origin.colophon(thisDeviceID: rig.state.library.thisDevice.id, thisDevice: "this Mac", unknown: "this Mac"),
                       "Summarized with Claude Sonnet 5.5")
        XCTAssertEqual(summary.cloudReason, .chosen, "Use the Cloud, in its provenance")
    }

    func testBehaviorTheRealCloudSummaryCarriesItsProvenanceAndWhereItRan() async throws {
        // Settings › Cloud as on a Mac with an Anthropic key, against a fake Anthropic: the summarizer is the app's own.
        let server = FakeCloudServer()
        let reply = #"{"kind":"general","title":"Call","overview":"We ship on Friday.","sections":[],"actionItems":[],"terms":["Friday"]}"#
        server.handle { request in
            switch request.path {
            case "/v1/models" where request.header("x-api-key") != nil:
                return .json(["data": [["id": "claude-sonnet-5-5", "max_input_tokens": 1_000_000, "max_tokens": 128_000]]])
            case "/v1/messages": return .anthropicReply([reply], inputTokens: 9_800, outputTokens: 2_900)
            default: return .failure(.cannotFindHost)
            }
        }
        var client = CloudClient(session: server.session, endpoints: CloudEndpoints(base: server.base))
        client.wait = { _ in }
        let rig = try await rig(cloud: nil, seconds: 30)
        let key = try XCTUnwrap(CloudAPIKey("sk-ant-api03-TESTtestTESTtestTESTtest-gDAA"))
        var preferences = CloudSummaryPreferences()
        preferences.countdownSeconds = 30
        let defaults = makeTestDefaults("SummaryPlacementProcessingTests")
        preferences.save(to: defaults)
        let setup = CloudSetup(keys: MemoryCloudKeyStore([.anthropic: key]), client: client, defaults: defaults)
        await setup.refresh()
        rig.state.cloud = setup
        XCTAssertEqual(rig.state.summaryOptions.cloud?.name, "Claude Sonnet 5.5", "What Settings › Cloud resolves to")

        let id = try await conversation(rig, "Real cloud", frequency: 365)
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        XCTAssertEqual(rig.state.placements[id]?.actions, [.useCloud, .startNow])
        rig.state.chooseSummaryPlacement(.useCloud, for: id)
        try await rig.processed(id)
        XCTAssertTrue(rig.inference.summarized.isEmpty)
        XCTAssertEqual(server.requests.filter { $0.path == "/v1/messages" }.count, 1)
        let summary = try XCTUnwrap(rig.meeting(id)?.summary)
        XCTAssertEqual(summary.overview, "We ship on Friday.")
        // The cloud's provenance.
        let cloud = try XCTUnwrap(summary.cloudProvenance)
        XCTAssertEqual(cloud.model, "claude-sonnet-5-5")
        XCTAssertEqual(cloud.effort, .xhigh, "Summaries ask for Extra High until the person chooses another level")
        XCTAssertEqual(cloud.inputTokens, 9_800)
        XCTAssertEqual(cloud.outputTokens, 2_900)
        XCTAssertNotNil(cloud.estimatedCost)
        XCTAssertEqual(cloud.sentBy, ProcessingRequest.Device.currentName)
        // Where it ran, the same summary.
        XCTAssertEqual(summary.origin.deviceID, rig.state.library.thisDevice.id)
        XCTAssertEqual(summary.origin.cloudModel, "Claude Sonnet 5.5")
        XCTAssertEqual(summary.processingSettings?.parameters["place"], "cloud")
        XCTAssertEqual(summary.modelsByRole["summarization"], "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(summary.modelsByRole["transcription"], rig.state.transcriptionModel)
        XCTAssertEqual(summary.origin.colophon(thisDeviceID: rig.state.library.thisDevice.id, thisDevice: "this Mac", unknown: "this Mac"),
                       "Summarized with Claude Sonnet 5.5")
        XCTAssertNotNil(cloud.usage)
        // What it suggests for the vocabulary, as a local summary's.
        XCTAssertTrue(rig.state.glossary.contains { $0.term == "Friday" }, "\(rig.state.glossary.map(\.term))")
    }

    func testBehaviorSettingsChangesReachACountdownAtOnce() async throws {
        let rig = try await rig(cloud: nil, seconds: 30)
        XCTAssertNil(rig.state.summaryOptions.cloud, "No key: nothing to offer")
        // A key is added in Settings › Cloud.
        let cloud = CloudSetup.demo(providers: [.anthropic], defaults: makeTestDefaults("SummaryPlacementProcessingTests"))
        rig.state.cloud = cloud
        rig.state.cloudSummarizer = FakeCloud()
        cloud.preferences.countdownSeconds = 30
        let first = try await conversation(rig, "Key removed", frequency: 370)
        rig.state.processor.enqueue(first)
        try await countingDown(rig, first)
        // The key is removed while it counts down: there's nothing to choose any more, so it starts here now.
        await cloud.removeKey(for: .anthropic)
        try await rig.processed(first)
        XCTAssertEqual(rig.inference.summarized.count, 1)
        XCTAssertNil(rig.state.summaryOptions.cloud)

        // Never chosen mid-countdown does the same.
        let again = CloudSetup.demo(providers: [.anthropic], defaults: makeTestDefaults("SummaryPlacementProcessingTests"))
        again.preferences.countdownSeconds = 30
        rig.state.cloud = again
        let second = try await conversation(rig, "Never chosen", frequency: 375)
        rig.state.processor.enqueue(second)
        try await countingDown(rig, second)
        again.preferences.policy = .never
        try await rig.processed(second)
        XCTAssertEqual(rig.inference.summarized.count, 2)
    }

    func testBehaviorAlwaysUsesTheCloudWithoutACountdown() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .always)
        let id = try await conversation(rig, "Always", frequency: 380)
        rig.state.processor.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertTrue(rig.inference.summarized.isEmpty)
        XCTAssertEqual(rig.meeting(id)?.summary?.cloudReason, .always)
    }

    /// A Personal conversation is never sent to the cloud on its own: under Always it counts down as Offer First does,
    /// and Use the Cloud is the person's choice for that one conversation.
    func testBehaviorAConversationKeptOffTheCloudIsNeverSentWhateverAsks() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .always, seconds: 30)
        // Filed in Personal, under Always: no countdown, no cloud, summarized here.
        let filed = try await conversation(rig, "Filed in Personal", frequency: 345)
        rig.state.library.update(filed) { $0.placement = .personal }
        let counted = CountdownSeen(rig.state.placements, for: filed)
        defer { counted.cancel() }
        rig.state.processor.enqueue(filed)
        try await rig.processed(filed)
        XCTAssertFalse(counted.happened, "Nothing to offer: no countdown")
        XCTAssertTrue(cloud.summarized.isEmpty, "Never sent")
        XCTAssertEqual(rig.inference.summarized.count, 1, "Summarized here")
        // Use the Cloud, from anywhere (a phone, a stale button), and the cloud's upgrade path do nothing for it.
        XCTAssertFalse(rig.state.cloudOnOffer(for: try XCTUnwrap(rig.meeting(filed))))
        rig.state.summarizeInCloud(filed)
        XCTAssertFalse(rig.state.processor.queue.isQueued(filed))
        // A Use the Cloud queued before the conversation moved to Personal runs here instead.
        let moved = try await conversation(rig, "Moved after queueing", frequency: 355)
        // Both in one turn: the job reaches its summary step only after the move.
        rig.state.processor.enqueue(moved, summarizesInCloud: true)
        rig.state.library.update(moved) { $0.placement = .personal }
        try await rig.processed(moved)
        XCTAssertTrue(cloud.summarized.isEmpty, "Still never sent")
        XCTAssertEqual(rig.inference.summarized.count, 2)
        // The person lets Personal go to the cloud: Always sends it.
        var preferences = rig.state.cloud.preferences
        preferences.placements.set(.personal, allowed: true)
        rig.state.cloud.preferences = preferences
        let allowed = try await conversation(rig, "Personal allowed", frequency: 365)
        rig.state.library.update(allowed) { $0.kind = .therapy }
        rig.state.processor.enqueue(allowed)
        try await rig.processed(allowed)
        XCTAssertEqual(cloud.summarized, [allowed])
    }

    func testBehaviorAConversationMovedOffTheCloudMidCountdownIsSummarizedHere() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .ask, seconds: 30)
        let id = try await conversation(rig, "Moved mid-countdown", frequency: 375)
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        XCTAssertEqual(rig.state.placements[id]?.actions, [.useCloud, .startNow])
        rig.state.library.update(id) { $0.placement = .personal }
        try await rig.processed(id)
        XCTAssertTrue(cloud.summarized.isEmpty)
        XCTAssertEqual(rig.inference.summarized.count, 1, "Its countdown lost the cloud and started here")
        // Work kept off the cloud in Settings mid-countdown: the same.
        let work = try await conversation(rig, "Work switched off", frequency: 385)
        rig.state.library.update(work) { $0.placement = .work }
        rig.state.processor.enqueue(work)
        try await countingDown(rig, work)
        var preferences = rig.state.cloud.preferences
        preferences.placements.set(.work, allowed: false)
        rig.state.cloud.preferences = preferences
        try await rig.processed(work)
        XCTAssertTrue(cloud.summarized.isEmpty)
        XCTAssertEqual(rig.inference.summarized.count, 2)
    }

    // MARK: When the cloud would do better

    func testBehaviorALongConversationCountsDownToTheCloudUnderOfferFirst() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .ask, seconds: 1)
        smallModel(rig)
        let id = try await longConversation(rig, "Offsite", frequency: 395)
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        let planner = try XCTUnwrap(rig.state.placements[id])
        guard case .countingDown(.cloud(let model), _) = planner.phase else { return XCTFail("\(planner.phase)") }
        XCTAssertEqual(model.id, "claude-sonnet-5-5", "Settings › Cloud's model")
        XCTAssertEqual(planner.actions, [.startNow, .useLocal])
        XCTAssertTrue(cloud.summarized.isEmpty, "Never sent without its countdown")
        // A phone hears that it ends in the cloud.
        XCTAssertEqual(rig.state.placementProgress(id)?.cloudModel, "Claude Sonnet 5.5")
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertTrue(rig.inference.summarized.isEmpty)
        XCTAssertEqual(rig.meeting(id)?.summary?.cloudReason, .longConversation)
    }

    func testBehaviorDontUseTheCloudKeepsALongConversationHereAndAShortOneNeverCountsDownToIt() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .ask, seconds: 30)
        smallModel(rig)
        let id = try await longConversation(rig, "Kept here", frequency: 405)
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        rig.state.phoneChoseSummaryPlacement(LinkSummaryChoice(meetingID: id, choice: .useLocal))
        try await rig.processed(id)
        XCTAssertTrue(cloud.summarized.isEmpty)
        XCTAssertEqual(rig.inference.summarized.count, 1, "Here, as it would have been")
        // A short one reads whole here: its countdown ends here, with Use the Cloud.
        let short = try await conversation(rig, "Short", frequency: 415)
        rig.state.processor.enqueue(short)
        try await countingDown(rig, short)
        XCTAssertEqual(rig.state.placements[short]?.actions, [.useCloud, .startNow])
        rig.state.chooseSummaryPlacement(.startNow, for: short)
        try await rig.processed(short)
        XCTAssertTrue(cloud.summarized.isEmpty)
        // Filed in Personal, a long one never counts down to the cloud.
        let personal = try await longConversation(rig, "Personal offsite", frequency: 425)
        rig.state.library.update(personal) { $0.placement = .personal }
        rig.state.processor.enqueue(personal)
        try await rig.processed(personal)
        XCTAssertTrue(cloud.summarized.isEmpty)
        XCTAssertEqual(rig.inference.summarized.count, 3)
    }

    func testBehaviorASummaryThatFailsHereTriesTheCloudBeforeTheJobFails() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .ask, seconds: 1)
        rig.inference.failSummaries(with: LocalIntelligenceError.promptTooLong(needed: 9_000, window: 8_192))
        let id = try await conversation(rig, "Fails here", frequency: 435)
        rig.state.processor.enqueue(id)
        // The countdown to this Mac runs out, the summary fails, and Offer First counts down again, to the cloud.
        try await waitUntil("the countdown to the cloud") { rig.state.placements[id]?.conversation.localFailed == true }
        XCTAssertEqual(rig.state.placements[id]?.actions, [.startNow, .useLocal])
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertEqual(rig.meeting(id)?.status, .ready)
        XCTAssertEqual(rig.meeting(id)?.summary?.cloudReason, .localFailed)

        // Declined: the job fails with what went wrong here.
        let declined = try await conversation(rig, "Declined", frequency: 445)
        rig.state.processor.enqueue(declined)
        try await waitUntil("the second countdown to the cloud") { rig.state.placements[declined]?.conversation.localFailed == true }
        rig.state.chooseSummaryPlacement(.useLocal, for: declined)
        try await rig.processed(declined)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertEqual(rig.meeting(declined)?.status, .failed)
        XCTAssertTrue(rig.meeting(declined)?.errorMessage?.contains("can’t read this conversation") == true,
                      rig.meeting(declined)?.errorMessage ?? "no message")

        // Kept off the cloud: it fails with no countdown at all.
        let personal = try await conversation(rig, "Personal fails", frequency: 455)
        rig.state.library.update(personal) { $0.placement = .personal }
        rig.state.processor.enqueue(personal)
        try await rig.processed(personal)
        XCTAssertEqual(rig.meeting(personal)?.status, .failed)
        XCTAssertEqual(cloud.summarized, [id])
    }

    func testBehaviorDeclinedForTheCloudAFailureHereDoesntBringItBack() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .ask, seconds: 30)
        smallModel(rig)
        rig.inference.failSummaries(with: LocalIntelligenceError.promptTooLong(needed: 9_000, window: 8_192))
        let id = try await longConversation(rig, "Declined then failed", frequency: 475)
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        rig.state.chooseSummaryPlacement(.useLocal, for: id)
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.status, .failed, "The failure here stands")
        XCTAssertTrue(cloud.summarized.isEmpty, "The person declined the cloud for it")
    }

    func testBehaviorAConversationLongerThanTheCloudModelCanReadIsSummarizedHere() async throws {
        let cloud = FakeCloud()
        cloud.failure = CloudError.inputTooLong(model: "Claude Sonnet 5.5", details: "About 2,000,000 tokens in a window of 1,000,000")
        let rig = try await rig(cloud: cloud, policy: .always)
        let id = try await conversation(rig, "Too long for the cloud", frequency: 465)
        rig.state.processor.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(rig.inference.summarized.count, 1, "Nothing was sent; summarized here")
        XCTAssertEqual(rig.meeting(id)?.status, .ready)
        XCTAssertTrue(rig.meeting(id)?.errorMessage?.contains("longer than Claude Sonnet 5.5 can read") == true)
    }

    /// A speaker named while the summary is being written: the name follows into it, as into a summary already there,
    /// and nothing is summarized twice. Notes written meanwhile still summarize it again.
    func testBehaviorANameGivenWhileSummarizingFollowsIntoTheSummaryWithoutAnother() async throws {
        let cloud = FakeCloud()
        cloud.overview = { meeting in "\(meeting.speakers.first?.name ?? "No one") ships on Friday." }
        let rig = try await rig(cloud: cloud, policy: .always)
        let id = try await conversation(rig, "Names", frequency: 390)
        cloud.hold()
        rig.state.processor.enqueue(id)
        try await waitUntil("the cloud to be asked") { cloud.isWaiting }
        let speaker = try XCTUnwrap(rig.meeting(id)?.speakers.first)
        XCTAssertEqual(speaker.name, "Speaker 1")
        rig.state.library.renameSpeaker(speaker.id, to: "Priya", in: id)
        cloud.release()
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id], "Written once")
        XCTAssertEqual(rig.meeting(id)?.summary?.overview, "Priya ships on Friday.")
        XCTAssertEqual(rig.meeting(id)?.revisions.filter { $0.field == "summary" }.count, 1, "One summary in Version History")

        cloud.hold()
        rig.state.processor.enqueue(id, mode: .summaryOnly)
        try await waitUntil("the cloud to be asked again") { cloud.isWaiting }
        rig.state.library.update(id) { $0.notes = "Bring the deck" }
        cloud.release()
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id, id, id], "The notes changed meanwhile: summarized again")
    }

    func testBehaviorSummarizeOnThisMacRunsHereUnderAlwaysOnceAndOnlyThatOnce() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .always)
        let id = try await conversation(rig, "Here", frequency: 385)
        rig.state.processor.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id], "Always: the cloud")
        rig.state.summarizeHere(id)
        XCTAssertNil(rig.state.placements[id], "Placed only when its summary step starts")
        try await waitUntil("the summary here") { rig.inference.summarized.count == 1 }
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id], "Not the cloud this time")
        XCTAssertNil(rig.meeting(id)?.summary?.origin.cloudModel)
        XCTAssertNil(rig.state.placements[id], "Ended with its step")
        // The next Summarize follows the preferences again.
        rig.state.processor.enqueue(id, mode: .summaryOnly)
        try await waitUntil("the cloud again") { cloud.summarized.count == 2 }
        try await rig.processed(id)
        XCTAssertEqual(rig.inference.summarized.count, 1)
    }

    func testBehaviorNeverKeepsTheKeyAndSummarizesHereAtOnce() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .never)
        let id = try await conversation(rig, "Never", frequency: 390)
        rig.state.processor.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(rig.inference.summarized.count, 1)
        XCTAssertTrue(cloud.summarized.isEmpty)
    }

    func testBehaviorSummarizeAgainStartsAtOnce() async throws {
        let rig = try await rig(seconds: 30)
        let id = try await conversation(rig, "Again", frequency: 400)
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        rig.state.chooseSummaryPlacement(.startNow, for: id)
        try await rig.processed(id)
        let counted = CountdownSeen(rig.state.placements, for: id)
        defer { counted.cancel() }
        rig.state.processor.enqueue(id, mode: .summaryOnly)
        try await waitUntil("the second summary") { rig.inference.summarized.count == 2 }
        try await rig.processed(id)
        XCTAssertFalse(counted.happened, "The person asked: no countdown")
    }

    func testBehaviorAPhonesSummaryRequestStartsAtOnce() async throws {
        let rig = try await rig(seconds: 30)
        let id = try await conversation(rig, "Phone asks", frequency: 420)
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        rig.state.chooseSummaryPlacement(.startNow, for: id)
        try await rig.processed(id)
        // The phone counted down already (or the person asked there): this Mac starts at once.
        rig.state.library.requestProcessing(id, mode: .summaryOnly, by: .phone)
        let counted = CountdownSeen(rig.state.placements, for: id)
        defer { counted.cancel() }
        rig.state.pickUpRequests()
        try await rig.processed(id)
        XCTAssertFalse(counted.happened)
        XCTAssertEqual(rig.inference.summarized.count, 2)
        XCTAssertEqual(rig.meeting(id)?.processingRequests?.first?.outcome?.result, .completed)
    }

    func testBehaviorAPhonesRequestJoiningACountdownStartsItNow() async throws {
        let rig = try await rig(seconds: 60)
        let id = try await conversation(rig, "Joining", frequency: 430)
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        // The phone's own countdown for this conversation ran out and sent the request: no second wait.
        rig.state.library.requestProcessing(id, mode: .summaryOnly, by: .phone)
        rig.state.pickUpRequests()
        try await rig.processed(id)
        XCTAssertEqual(rig.inference.summarized.count, 1, "One summary, carrying the phone's request")
        XCTAssertEqual(rig.meeting(id)?.processingRequests?.first?.outcome?.result, .completed)
    }

    func testBehaviorAPhonesRequestTakenWhileTranscribingStartsItsSummaryAtOnce() async throws {
        let rig = try await rig(seconds: 60)
        let audio = try rig.audio("Transcribing.wav", frequency: 435)
        let id = try await rig.waitingConversation("Transcribing", audio: audio, script: [(0, "We ship on Friday.")])
        try rig.inference.block(audio)
        rig.state.processor.enqueue(id)
        try await waitUntil("transcribing") { rig.inference.isWaiting(on: audio) }
        rig.state.library.requestProcessing(id, mode: .summaryOnly, by: .phone)
        rig.state.pickUpRequests()
        XCTAssertNil(rig.state.placements[id], "Nothing placed before the summary is due")
        let counted = CountdownSeen(rig.state.placements, for: id)
        defer { counted.cancel() }
        try rig.inference.unblock(audio)
        try await rig.processed(id)
        XCTAssertFalse(counted.happened, "The phone asked for its summary")
        XCTAssertEqual(rig.inference.summarized.count, 1)
        XCTAssertNil(rig.state.placements[id])
    }

    func testBehaviorPausingDuringTheCountdownPausesTheJob() async throws {
        let rig = try await rig(seconds: 60)
        let id = try await conversation(rig, "Pause", frequency: 440)
        rig.state.processor.enqueue(id)
        try await countingDown(rig, id)
        rig.state.pauseProcessing(id)
        try await rig.processed()
        XCTAssertTrue(rig.state.processor.queue.paused.contains(id))
        XCTAssertNil(rig.state.placements[id])
        XCTAssertTrue(rig.inference.summarized.isEmpty)
        XCTAssertEqual(rig.state.processingStatus(for: try XCTUnwrap(rig.meeting(id))), .requested(.paused))
    }

    // MARK: Never twice

    func testBehaviorAnotherDeviceHoldingTheSummaryMakesThisMacStandDown() async throws {
        let rig = try await rig(seconds: 60)
        let id = try await conversation(rig, "Stand down", frequency: 460)
        rig.state.processor.enqueue(id)
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
        rig.state.processor.enqueue(id)
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

    func testBehaviorAMacArrivingLateLeavesAPhonesCloudSummaryAlone() async throws {
        let rig = try await rig(cloud: nil)
        let id = try await conversation(rig, "Late", frequency: 470)
        rig.state.processor.enqueue(id, mode: .newAudio)
        try await rig.processed(id)
        let before = rig.inference.summarized.count
        // The phone chose the cloud while no Mac was around: it holds the Summarize request it made.
        let phone = ProcessingRequest.Device.phone
        let request = ProcessingRequest(meetingID: id, mode: .summaryOnly, requestedBy: phone)
        let held = try XCTUnwrap(request.claimed(by: phone, at: Date())?.renewed(by: phone, at: Date(), stage: .summarizing))
        rig.state.update(id) { $0.upsertProcessingRequest(held) }
        // This Mac comes back and looks for work.
        rig.state.pickUpRequests()
        try await rig.processed()
        XCTAssertEqual(rig.inference.summarized.count, before, "Not summarized here too")
        guard case .processing(let progress) = rig.state.processingStatus(for: try XCTUnwrap(rig.meeting(id))) else { return XCTFail("The phone's work") }
        XCTAssertEqual(progress.stage, .summarizing)
        XCTAssertEqual(progress.device, phone)
        // The phone's summary arrives with its request finished: nothing is left to do here.
        let summary = MeetingSummary(title: "Late", overview: "From the cloud", modelID: FakeCloud.sonnet.id).placed(.cloud(FakeCloud.sonnet), by: phone, inputs: [:])
        rig.state.update(id) { meeting in
            meeting.setSummary(summary)
            meeting.upsertProcessingRequest(held.completed(by: phone, at: Date())!)
        }
        rig.state.pickUpRequests()
        try await rig.processed()
        XCTAssertEqual(rig.inference.summarized.count, before)
        XCTAssertEqual(rig.state.processingStatus(for: try XCTUnwrap(rig.meeting(id))), .done)
    }

    func testBehaviorASummaryAPhoneHeldAndNeverCameBackForIsTakenOver() async throws {
        let rig = try await rig(cloud: nil)
        let id = try await conversation(rig, "Stranded", frequency: 475)
        rig.state.processor.enqueue(id, mode: .newAudio)
        try await rig.processed(id)
        rig.state.update(id) { $0.summary = nil }
        let before = rig.inference.summarized.count
        // The phone wrote down a Summarize request and held it through its countdown, then was never seen again:
        // its claim ran out an hour ago.
        let phone = ProcessingRequest.Device.phone
        let past = Date().addingTimeInterval(-3_600)
        var held = ProcessingRequest(meetingID: id, mode: .summaryOnly, requestedBy: phone, createdAt: past)
        held.claim = ProcessingRequest.Claim(device: phone, claimedAt: past, heartbeat: past, expiresAt: past.addingTimeInterval(ProcessingRequest.defaultLease),
                                             stage: .summarizing)
        rig.state.update(id) { $0.upsertProcessingRequest(held) }
        XCTAssertFalse(rig.state.isHeldElsewhere(id))
        rig.state.pickUpRequests()
        try await rig.processed(id)
        XCTAssertEqual(rig.inference.summarized.count, before + 1, "This Mac took it over and summarized it")
        let request = try XCTUnwrap(rig.meeting(id)?.processingRequests?.first { $0.id == held.id })
        XCTAssertEqual(request.outcome?.result, .completed)
        XCTAssertEqual(request.outcome?.device, rig.state.library.thisDevice)
        XCTAssertNotNil(rig.meeting(id)?.summary)
    }

    // MARK: A phone

    func testBehaviorAPhoneSeesTheCountdownAndChoosesTheCloud() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, seconds: 60)
        let phone = try await PhoneLinkRig.connect(rig.state)
        let id = try await conversation(rig, "From the phone", frequency: 500)
        rig.state.processor.enqueue(id)
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

    // MARK: Transcript first (uxf-01, uxf-03)

    /// Under Always with a key, no summary model is needed on this Mac at all: the transcript is made here and the
    /// summary goes to the cloud, with nothing waiting for a download.
    func testBehaviorUnderAlwaysTheCloudSummarizesWithNoSummaryModelHere() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, policy: .always)
        rig.state.installedModels.remove(rig.state.summaryModel)
        XCTAssertFalse(rig.state.summaryOptions.thisDeviceCanSummarize, "No summary model here")
        let id = try await conversation(rig, "Always, no model", frequency: 385)
        XCTAssertFalse(rig.state.summaryWaitsForModel(try XCTUnwrap(rig.meeting(id))), "The cloud takes it at once")
        rig.state.processor.enqueue(id)
        XCTAssertTrue(rig.state.processor.queue.awaitingModels.isEmpty, "Nothing waits for the summary model")
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertTrue(rig.inference.summarized.isEmpty)
        XCTAssertTrue(rig.state.processor.queue.awaitingSummaryModel.isEmpty)
        XCTAssertEqual(rig.meeting(id)?.summary?.origin.cloudModel, "Claude Sonnet 5.5")

        // A Personal conversation isn't sent on its own: it waits for the model here, with Use the Cloud.
        let personal = try await conversation(rig, "Personal, no model", frequency: 395)
        rig.state.library.update(personal) { $0.placement = .personal }
        rig.state.processor.enqueue(personal)
        try await rig.processed(personal)
        XCTAssertEqual(rig.state.processor.queue.awaitingSummaryModel, [personal])
        XCTAssertEqual(cloud.summarized, [id], "Never sent on its own")
    }

    /// Offer First with a key and no summary model: the transcript is done and the summary waits for the model, the page
    /// saying so with Use the Cloud, which sends it there now (from the page or a phone).
    func testBehaviorASummaryWaitingForTheModelOffersUseTheCloud() async throws {
        let cloud = FakeCloud()
        let rig = try await rig(cloud: cloud, seconds: 30)
        rig.state.installedModels.remove(rig.state.summaryModel)
        let id = try await conversation(rig, "Waiting for the model", frequency: 405)
        rig.state.processor.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(rig.state.processor.queue.awaitingSummaryModel, [id], "No countdown holds the queue: it waits for the model")
        XCTAssertNil(rig.state.placements[id])
        let meeting = try XCTUnwrap(rig.meeting(id))
        let status = rig.state.processingStatus(for: meeting)
        XCTAssertEqual(status, .transcribed)
        // The page as the Mac draws it, while the summary model downloads.
        var inputs = ConversationStatusPresentation.Inputs(words: rig.state.statusWords,
                                                           local: .mac(summarizes: false, models: .downloading(done: 385, total: 1_000)))
        inputs.summaryWaitsForModel = rig.state.summaryWaitsForModel(meeting)
        inputs.placement.cloudOffered = rig.state.cloudOnOffer
        XCTAssertEqual(ConversationStatusPresentation.page(status, meeting: meeting, inputs: inputs),
                       ConversationStatusPresentation(kind: .line, symbol: "clock", title: "Waiting to summarize after the download · 38%",
                                                      progress: 0.385, actions: [.placement(.useCloud)]))
        let shown = FloatingStatusInputs.conversation(meeting, state: rig.state)
        XCTAssertEqual(shown.ready, false)
        XCTAssertNil(shown.summaryWaits, "Nothing downloading: no wait to name")

        rig.state.chooseSummaryPlacement(.useCloud, for: id)
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertTrue(rig.inference.summarized.isEmpty)
        XCTAssertTrue(rig.state.processor.queue.awaitingSummaryModel.isEmpty)
        XCTAssertFalse(rig.state.processor.queue.isOwed(id))
    }
}
