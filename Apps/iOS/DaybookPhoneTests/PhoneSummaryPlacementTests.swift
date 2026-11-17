import DaybookKit
import DaybookLink
import SwiftUI
import XCTest
@testable import DaybookPhone

/// Where the iPhone's summaries run (docs/multipoint.md, "Where summaries run"; docs/iphone.md): the same
/// planner as the Mac's, sending a summary to a reachable Mac after a countdown, waiting for one with Use the
/// Cloud, running it in the cloud or, through the processor, on a local summarizer with a claim, a Mac's
/// countdown shown here with the choice sent to it, and the default happening when the app leaves the screen.
/// Settings › Cloud is the app's `CloudSetup` with an in-memory key. A temporary library, a fake cloud and
/// summarizer, presence records, and a loopback Mac; no network, no models.
@MainActor
final class PhoneSummaryPlacementTests: XCTestCase {
    private let studioID = UUID()
    private let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                    inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)

    /// A cloud the tests control.
    final class Cloud: CloudSummarizing, @unchecked Sendable {
        let models: [CloudModel]
        private let lock = NSLock()
        private var _asked: [UUID] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var held = false
        /// What a summary says, from the conversation as it read it.
        var overview: @Sendable (Meeting) -> String = { _ in "From the cloud" }
        /// Every summary throws this, when set, as the provider would.
        var failure: (any Error & Sendable)? {
            get { lock.withLock { _failure } }
            set { lock.withLock { _failure = newValue } }
        }
        private var _failure: (any Error & Sendable)?
        init(models: [CloudModel]) { self.models = models }
        var asked: [UUID] { lock.withLock { _asked } }
        var isWaiting: Bool { lock.withLock { gate != nil } }
        func hold() { lock.withLock { held = true } }
        func release() { let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in held = false; defer { self.gate = nil }; return self.gate }; gate?.resume() }
        func availableModels(refresh: Bool) async -> [CloudModel] { models }
        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel, effort: CloudEffort,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
            lock.withLock { _asked.append(meeting.id) }
            if let failure { throw failure }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let wait = lock.withLock { () -> Bool in if held { gate = continuation }; return held }
                    if !wait { continuation.resume() }
                }
            } onCancel: { [weak self] in self?.release() }
            try Task.checkCancellation()
            return MeetingSummary(title: meeting.title, overview: overview(meeting), modelID: model.id)
        }
    }

    /// This iPhone's own summarizer, standing in for the iPhone's processing models.
    struct Local: LocalSummarizing {
        let model = "gemma-4/e2b-4bit"
        var canSummarize = true
        /// Every summary throws this, when set, as a model that runs out of room would.
        var failure: LocalFailure?
        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                       progress: @escaping @Sendable (Double) -> Void) async throws -> SummaryProcessingOutput {
            if let failure { throw failure }
            return SummaryProcessingOutput(summary: MeetingSummary(title: meeting.title, overview: "From this iPhone", modelID: model))
        }
    }

    struct LocalFailure: LocalizedError, Equatable {
        var errorDescription: String? { "The summary model couldn’t read this conversation." }
    }

    @MainActor private struct Rig {
        let library: LibraryController
        let link: PhoneLink
        let placement: PhoneSummaryPlacement
        let presence: PresenceBox
        let clock: ClockBox
        /// Runs the summaries placed on this iPhone, as the app's does.
        let processor: PhoneProcessor?

        /// Settings › Cloud.
        var cloud: CloudSetup { placement.cloud! }
    }

    final class PresenceBox { var devices: [KnownSyncDevice] = [] }
    final class ClockBox { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func rig(cloud: Cloud? = nil, local: (any LocalSummarizing)? = nil, macSeen: Bool = true, link: PhoneLink? = nil) async throws -> Rig {
        let library = LibraryController(rootURL: try temporaryDirectory("placement-\(UUID().uuidString)"), sync: nil)
        try await library.load()
        let link = link ?? PhoneLink(identity: PhoneLink.identity(installation: UUID().uuidString, name: "Test iPhone", libraryID: nil),
                                     keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        let presence = PresenceBox(), clock = ClockBox()
        let placement = PhoneSummaryPlacement(library: library, link: link, presence: { presence.devices }, clock: { clock.now }, runsTimer: false, appIsActive: { true })
        if macSeen { presence.devices = [studio(at: clock.now)] }
        // Settings › Cloud: an Anthropic key with the catalog's models when there's a cloud, none otherwise.
        placement.cloud = CloudSetup.demo(providers: cloud == nil ? [] : [.anthropic], defaults: makeTestDefaults("PhoneSummaryPlacementTests"))
        if let cloud {
            placement.cloudSummarizer = cloud
            XCTAssertEqual(placement.cloudOffer?.name, "Claude Sonnet 5.5", "Balanced's recommendation")
        }
        // A local summarizer runs through the processor, as in the app.
        var processor: PhoneProcessor?
        if let local {
            let made = PhoneProcessor(library: library, services: PhoneProcessor.Services(
                engine: { nil }, summarizer: { local },
                capabilities: { ProcessingCapabilities(transcribes: false, findsSpeakers: false, summarizes: local.canSummarize) },
                owns: { { _ in false } }, audio: { _, _ in throw CancellationError() }, release: {}),
                continued: ContinuedProcessing(scheduler: nil))
            placement.runHere = { [weak made] id, request in made?.summarizeHere(id, request: request) }
            // As the app wires it: a summary that fails here may try the cloud first.
            made.services.summaryFailed = { [weak placement] id, request, reason, kind in
                placement?.localSummaryFailed(id, request: request, reason: reason, kind: kind) ?? false
            }
            processor = made
        }
        placement.localSummarizer = local
        placement.refresh()
        return Rig(library: library, link: link, placement: placement, presence: presence, clock: clock, processor: processor)
    }

    /// A Mac that summarizes, seen through sync at `date`, with the summary model it says it runs.
    private func studio(at date: Date, summarizes: Bool = true, model: String? = nil) -> KnownSyncDevice {
        var device = KnownSyncDevice(id: studioID.uuidString, deviceClass: .mac, displayName: "Studio Mac", canProcess: true, lastSeen: date)
        device.capabilities = SyncDeviceCapabilities(transcribes: true, findsSpeakers: true, summarizes: summarizes,
                                                     models: model.map { [ModelRole.summarization.rawValue: $0] })
        return device
    }

    /// A conversation of a thousand passages with this iPhone's transcript and no summary: far longer than Gemma 4 E2B
    /// reads in one pass.
    private func long(_ library: LibraryController, _ title: String = "Offsite") -> UUID {
        let id = transcribed(library, title)
        library.update(id) { meeting in
            let track = meeting.tracks[0].id
            meeting.unifiedTranscript = (0..<1_000).map {
                TranscriptSegment(trackID: track, start: Double($0) * 5, end: Double($0) * 5 + 4,
                                  text: "We went over item number \($0) of the quarterly planning review.")
            }
        }
        return id
    }

    /// A conversation with this iPhone's transcript and no summary.
    private func transcribed(_ library: LibraryController, _ title: String = "Walk and talk") -> UUID {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", sha256: UUID().uuidString)
        var meeting = Meeting(title: title, tracks: [track], status: .imported)
        let words = TranscriptSegment(trackID: track.id, start: 0, end: 2, text: "Ship it Friday.")
        meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [words], modelID: "parakeet/v3")]
        meeting.unifiedTranscript = [words]
        library.add(meeting)
        return meeting.id
    }

    private func summaryRequests(_ library: LibraryController, _ id: UUID) -> [ProcessingRequest] {
        (library.meeting(id)?.processingRequests ?? []).filter { $0.mode == .summaryOnly }
    }

    /// What this iPhone's page and row draw (`SummaryPage`, `PhoneRowStatus`): the shared presentation, with where the
    /// summary runs, a Mac's live progress over the link, and whether the cloud is on offer.
    private func inputs(_ rig: Rig, _ id: UUID, live: LiveProgress? = nil, cloudOffered: Bool = false) -> ConversationStatusPresentation.Inputs {
        var inputs = ConversationStatusPresentation.Inputs(words: .iPhone(id: rig.library.thisDevice.id), local: .iPhone())
        inputs.placement = .init(planner: rig.placement.planners[id], run: rig.placement.runs[id], cloudOffered: cloudOffered)
        inputs.link = live.map(ConversationStatusPresentation.LinkWork.init(live:))
        return inputs
    }

    private func pageStatus(_ rig: Rig, _ id: UUID, _ status: ProcessingStatus, live: LiveProgress? = nil, cloudOffered: Bool = false,
                            now: Date? = nil) throws -> ConversationStatusPresentation? {
        ConversationStatusPresentation.page(status, meeting: try XCTUnwrap(rig.library.meeting(id)),
                                            inputs: inputs(rig, id, live: live, cloudOffered: cloudOffered), now: now ?? rig.clock.now)
    }

    private func rowStatus(_ rig: Rig, _ id: UUID, _ status: ProcessingStatus, live: LiveProgress? = nil, now: Date? = nil) throws -> ConversationRowStatus? {
        ConversationStatusPresentation.row(status, meeting: try XCTUnwrap(rig.library.meeting(id)), inputs: inputs(rig, id, live: live),
                                           now: now ?? rig.clock.now)
    }

    // MARK: To a Mac

    func testBehaviorADueSummaryCountsDownToAReachableMacThenSendsIt() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        let planner = try XCTUnwrap(rig.placement.planners[id])
        XCTAssertEqual(planner.line(at: rig.clock.now, thisDevice: PhoneSummaryPlacement.thisDeviceWords),
                       SummaryPlacementWords.countdown(on: "Studio Mac", seconds: 15))
        XCTAssertEqual(planner.actions, [.useCloud, .startNow])
        // Written down before the countdown, and held here so no Mac takes it while it counts down.
        // (Claims are read from their fields: the tests share a clock that starts at the same moment.)
        let held = try XCTUnwrap(summaryRequests(rig.library, id).first)
        XCTAssertEqual(held.claim?.device, rig.library.thisDevice)
        XCTAssertEqual(held.claim?.expiresAt, rig.clock.now.addingTimeInterval(ProcessingRequest.defaultLease))
        XCTAssertEqual(held.claim?.stage, .summarizing)
        rig.clock.now.addTimeInterval(15)
        rig.placement.placements.advance()
        XCTAssertNil(rig.placement.planners[id])
        let sent = try XCTUnwrap(summaryRequests(rig.library, id).first)
        XCTAssertEqual(sent.id, held.id, "The same request")
        XCTAssertEqual(sent.claim?.lease, 0, "Given back, for the Mac to claim")
        XCTAssertEqual(summaryRequests(rig.library, id).count, 1)
        XCTAssertEqual(try pageStatus(rig, id, ProcessingStatus(try XCTUnwrap(rig.library.meeting(id)), now: rig.clock.now))?.title,
                       "Waiting for your Mac to summarize", "Its first summary")
    }

    func testBehaviorWithoutAKeyItGoesToTheMacAtOnce() async throws {
        let rig = try await rig()
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertNil(rig.placement.planners[id], "Nothing to choose: no countdown")
        XCTAssertEqual(summaryRequests(rig.library, id).count, 1)
        // With no Mac reachable either, it waits for one through the library, as before.
        rig.presence.devices = []
        let other = transcribed(rig.library, "Second")
        await rig.placement.summaryIsDue(other)
        XCTAssertEqual(summaryRequests(rig.library, other).count, 1)
    }

    func testBehaviorWithNoMacItWaitsWithTheCloudOfferedThenCountsDownWhenOneArrives() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]), macSeen: false)
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertEqual(rig.placement.planners[id]?.phase, .waitingForMac)
        let page = try XCTUnwrap(try pageStatus(rig, id, .transcribed, cloudOffered: true))
        XCTAssertEqual(page.title, SummaryPlacementWords.waitingForMac)
        XCTAssertEqual(page.actions, [.placement(.useCloud)])
        let held = try XCTUnwrap(summaryRequests(rig.library, id).first)
        XCTAssertEqual(held.claim?.device, rig.library.thisDevice, "Held: a Mac arriving counts down first")
        XCTAssertEqual(held.claim?.lease, ProcessingRequest.defaultLease)
        // A Mac syncs again (or connects): a fresh countdown, then it's sent. Meanwhile the hold was renewed.
        rig.clock.now.addTimeInterval(300)
        rig.presence.devices = [studio(at: rig.clock.now)]
        rig.placement.refresh()
        XCTAssertEqual(summaryRequests(rig.library, id).first?.claim?.heartbeat, rig.clock.now, "Renewed while it waits")
        XCTAssertEqual(rig.placement.planners[id]?.deadline, rig.clock.now.addingTimeInterval(15))
        rig.placement.perform(.startNow, for: id)
        XCTAssertEqual(summaryRequests(rig.library, id).count, 1)
        XCTAssertEqual(summaryRequests(rig.library, id).first?.claim?.lease, 0, "Given back to the Mac")
    }

    func testBehaviorAMacGoingAwayMidCountdownLeavesItWaiting() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        // Past the 25 minutes presence counts for (`KnownSyncDevice.presenceWindow`).
        rig.clock.now.addTimeInterval(26 * 60)
        rig.placement.refresh()
        XCTAssertEqual(rig.placement.planners[id]?.phase, .waitingForMac, "Its presence is too old to count on")
    }

    // MARK: The cloud

    func testBehaviorUseTheCloudRunsItHereWithAClaimAndRecordsWhereItRan() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, macSeen: false)
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        cloud.hold()
        rig.placement.perform(.useCloud, for: id)
        try await waitUntil("the cloud to be asked") { cloud.isWaiting }
        XCTAssertEqual(rig.placement.runs[id], rig.placement.cloudOffer.map(SummaryPlace.cloud))
        // Held by this iPhone: no Mac takes it meanwhile, and Macs read it as summarizing here.
        let claimed = try XCTUnwrap(summaryRequests(rig.library, id).first)
        XCTAssertEqual(claimed.claim?.device, rig.library.thisDevice)
        XCTAssertEqual(claimed.claim?.stage, .summarizing)
        let running = try XCTUnwrap(try pageStatus(rig, id, .transcribed, cloudOffered: true))
        XCTAssertEqual(running.title, SummaryPlacementWords.inCloud("Claude Sonnet 5.5"))
        XCTAssertEqual(running.actions, [.stopSummary])
        cloud.release()
        try await waitUntil("the summary") { rig.library.meeting(id)?.summary != nil }
        let summary = try XCTUnwrap(rig.library.meeting(id)?.summary)
        XCTAssertEqual(summary.overview, "From the cloud")
        XCTAssertEqual(summary.origin.cloudModel, "Claude Sonnet 5.5")
        XCTAssertEqual(summary.origin.deviceID, rig.library.thisDevice.id)
        XCTAssertEqual(summary.origin.colophon(thisDeviceID: rig.library.thisDevice.id, thisDevice: "this iPhone", unknown: "your Mac"),
                       "Summarized with Claude Sonnet 5.5")
        XCTAssertEqual(summaryRequests(rig.library, id).first?.outcome?.result, .completed)
        XCTAssertNil(rig.placement.runs[id])
        XCTAssertEqual(ProcessingStatus(try XCTUnwrap(rig.library.meeting(id))), .done)
    }

    // MARK: Kept off the cloud

    func testBehaviorAConversationKeptOffTheCloudIsNeverSentFromThisIPhone() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, macSeen: false)
        var preferences = rig.cloud.preferences
        preferences.policy = .always
        rig.cloud.preferences = preferences
        // Filed in Personal, under Always, with no Mac: no countdown, no cloud; it waits for a Mac through the library.
        let personal = transcribed(rig.library, "Session")
        rig.library.update(personal) { $0.placement = .personal }
        await rig.placement.summaryIsDue(personal)
        XCTAssertNil(rig.placement.cloudOffer(for: personal))
        XCTAssertNil(rig.placement.planners[personal])
        XCTAssertTrue(cloud.asked.isEmpty)
        let waiting = try XCTUnwrap(summaryRequests(rig.library, personal).first)
        XCTAssertEqual(waiting.claim?.lease ?? 0, 0, "Left to a Mac")
        // Use the Cloud for its waiting request, from anywhere, does nothing; the page doesn't offer it.
        rig.placement.perform(.useCloud, for: personal)
        XCTAssertTrue(cloud.asked.isEmpty)
        let meeting = try XCTUnwrap(rig.library.meeting(personal))
        let page = try XCTUnwrap(try pageStatus(rig, personal, ProcessingStatus(meeting), cloudOffered: rig.placement.cloudOffer(for: personal) != nil))
        XCTAssertFalse(page.actions.contains(.placement(.useCloud)))
        // The upgrade to the cloud isn't offered for it either.
        XCTAssertNil(Upgrades.offer(.summarization, for: meeting, candidates: UpgradeCandidates(
            thisDevice: .none, cloud: rig.placement.cloudOffer, cloudPlacements: rig.placement.preferences.placements)))
        // Work under Always goes to the cloud at once.
        let work = transcribed(rig.library, "Standup")
        rig.library.update(work) { $0.placement = .work }
        await rig.placement.summaryIsDue(work)
        try await waitUntil("the cloud to be asked") { cloud.asked == [work] }
        // With Personal let go in Settings, it goes too.
        preferences.placements.set(.personal, allowed: true)
        rig.cloud.preferences = preferences
        let allowed = transcribed(rig.library, "Allowed")
        rig.library.update(allowed) { $0.placement = .personal }
        await rig.placement.summaryIsDue(allowed)
        try await waitUntil("the cloud to be asked again") { cloud.asked == [work, allowed] }
    }

    func testBehaviorAConversationMovedOffTheCloudMidCountdownGoesToTheMac() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud)
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertEqual(rig.placement.planners[id]?.actions, [.useCloud, .startNow])
        rig.library.update(id) { $0.placement = .personal }
        rig.placement.refresh()
        XCTAssertNil(rig.placement.planners[id], "Nothing left to choose: it goes to the Mac now")
        XCTAssertEqual(summaryRequests(rig.library, id).first?.claim?.lease, 0, "Given back, for the Mac")
        XCTAssertTrue(cloud.asked.isEmpty)
        // Use the Cloud chosen before this iPhone heard of the move: the last check before sending keeps it here.
        let raced = transcribed(rig.library, "Raced")
        await rig.placement.summaryIsDue(raced)
        rig.library.update(raced) { $0.placement = .personal }
        rig.placement.perform(.useCloud, for: raced)
        XCTAssertTrue(cloud.asked.isEmpty, "Never sent")
        XCTAssertNil(rig.placement.runs[raced])
        XCTAssertEqual(summaryRequests(rig.library, raced).first?.claim?.lease, 0, "To the Mac instead")
    }

    func testBehaviorSummarizeWithNoMacLeavesTheRequestAndUseTheCloudTakesItBack() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, macSeen: false)
        let id = transcribed(rig.library)
        rig.placement.summarize(id)
        XCTAssertNil(rig.placement.planners[id])
        let waiting = try XCTUnwrap(rig.placement.waitingSummaryRequest(id), "Asked for: it waits for a Mac in the library")
        let meeting = try XCTUnwrap(rig.library.meeting(id))
        let page = try XCTUnwrap(try pageStatus(rig, id, ProcessingStatus(meeting), cloudOffered: true))
        XCTAssertEqual(page.title, SummaryPlacementWords.waitingForMac)
        XCTAssertEqual(page.actions, [.placement(.useCloud), .cancelRequest(waiting.id)], "this iPhone asked: it can take it back")
        let plain = try XCTUnwrap(try pageStatus(rig, id, ProcessingStatus(meeting), cloudOffered: false))
        XCTAssertEqual(plain.title, "Waiting for your Mac to summarize", "Without the cloud it reads as before")
        XCTAssertEqual(plain.actions, [.cancelRequest(waiting.id)])
        rig.placement.perform(.useCloud, for: id)
        try await waitUntil("the summary") { rig.library.meeting(id)?.summary != nil }
        XCTAssertEqual(cloud.asked, [id])
        XCTAssertEqual(summaryRequests(rig.library, id).map(\.id), [waiting.id], "The same request, claimed here and finished")
        XCTAssertEqual(summaryRequests(rig.library, id).first?.outcome?.device, rig.library.thisDevice)
        XCTAssertEqual(rig.library.meeting(id)?.summary?.cloudReason, .chosen, "Why it went, in its provenance")
    }

    func testBehaviorAlwaysSendsItToTheCloudWithoutACountdown() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud)
        rig.cloud.preferences.policy = .always
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        try await waitUntil("the summary") { rig.library.meeting(id)?.summary != nil }
        XCTAssertEqual(cloud.asked, [id])
    }

    /// A speaker named while the cloud writes the summary: the name follows into it, as into a summary already there.
    func testBehaviorANameGivenWhileTheCloudSummarizesFollowsIntoTheSummary() async throws {
        let cloud = Cloud(models: [sonnet])
        cloud.overview = { meeting in "\(meeting.speakers.first?.name ?? "No one") ships on Friday." }
        let rig = try await rig(cloud: cloud)
        rig.cloud.preferences.policy = .always
        let id = transcribed(rig.library)
        rig.library.update(id) { $0.speakers = [Speaker(id: "run:S1", name: "Speaker 1")] }
        cloud.hold()
        await rig.placement.summaryIsDue(id)
        try await waitUntil("the cloud to be asked") { cloud.isWaiting }
        rig.library.renameSpeaker("run:S1", to: "Priya", in: id)
        cloud.release()
        try await waitUntil("the summary") { rig.library.meeting(id)?.summary != nil }
        XCTAssertEqual(rig.library.meeting(id)?.summary?.overview, "Priya ships on Friday.")
        XCTAssertEqual(cloud.asked, [id], "Written once")
    }

    // MARK: When the cloud would do better

    func testBehaviorALongConversationCountsDownToTheCloudAndDontUseTheCloudKeepsItHere() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, local: Local())
        let id = long(rig.library)
        await rig.placement.summaryIsDue(id)
        let planner = try XCTUnwrap(rig.placement.planners[id])
        guard case .countingDown(.cloud(let model), _) = planner.phase else { return XCTFail("\(planner.phase)") }
        XCTAssertEqual(model.id, "claude-sonnet-5-5")
        XCTAssertEqual(planner.actions, [.startNow, .useLocal])
        XCTAssertEqual(planner.line(at: rig.clock.now, thisDevice: PhoneSummaryPlacement.thisDeviceWords),
                       "Summarizing with Claude Sonnet 5.5 in 15 s")
        XCTAssertTrue(cloud.asked.isEmpty, "Never sent without its countdown")
        rig.clock.now.addTimeInterval(15)
        rig.placement.placements.advance()
        try await waitUntil("the summary") { rig.library.meeting(id)?.summary != nil }
        XCTAssertEqual(cloud.asked, [id])
        XCTAssertEqual(rig.library.meeting(id)?.summary?.cloudReason, .longConversation)
        // Don't Use the Cloud: this iPhone's summarizer, as it would have been.
        let kept = long(rig.library, "Kept here")
        await rig.placement.summaryIsDue(kept)
        rig.placement.perform(.useLocal, for: kept)
        try await waitUntil("the summary here") { rig.library.meeting(kept)?.summary?.overview == "From this iPhone" }
        XCTAssertEqual(cloud.asked, [id])
    }

    func testBehaviorALongConversationForTheMacsModelCountsDownToTheCloudAndDontUseTheCloudSendsItToTheMac() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud)
        rig.presence.devices = [studio(at: rig.clock.now, model: "gemma-4/e4b-4bit")]
        rig.placement.refresh()
        let id = long(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertEqual(rig.placement.planners[id]?.actions, [.startNow, .useLocal], "E4B on the Mac: 53 against 94")
        rig.placement.perform(.useLocal, for: id)
        XCTAssertNil(rig.placement.planners[id])
        XCTAssertEqual(summaryRequests(rig.library, id).first?.claim?.lease, 0, "Given back, for the Mac")
        XCTAssertTrue(cloud.asked.isEmpty)
        // The Mac's 26B (90 against 94) reads it as well as the cloud: a countdown to the Mac, with Use the Cloud.
        rig.presence.devices = [studio(at: rig.clock.now, model: "gemma-4/26b-a4b-qat-4bit")]
        rig.placement.refresh()
        let other = long(rig.library, "Second")
        await rig.placement.summaryIsDue(other)
        XCTAssertEqual(rig.placement.planners[other]?.actions, [.useCloud, .startNow])
    }

    func testBehaviorASummaryThatFailsHereTriesTheCloudBeforeItsRequestFails() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, local: Local(failure: LocalFailure()), macSeen: false)
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        rig.placement.perform(.startNow, for: id)
        // It fails here, and Offer First counts down again, to the cloud.
        try await waitUntil("the countdown to the cloud") { rig.placement.planners[id]?.conversation.localFailed == true }
        XCTAssertEqual(rig.placement.planners[id]?.actions, [.startNow, .useLocal])
        XCTAssertNil(summaryRequests(rig.library, id).first?.outcome, "Not failed while the cloud is tried")
        rig.placement.perform(.startNow, for: id)
        try await waitUntil("the cloud's summary") { rig.library.meeting(id)?.summary != nil }
        XCTAssertEqual(cloud.asked, [id])
        XCTAssertEqual(rig.library.meeting(id)?.summary?.cloudReason, .localFailed)
        XCTAssertEqual(summaryRequests(rig.library, id).first?.outcome?.result, .completed)
        // Declined: the request fails with what went wrong here.
        let declined = transcribed(rig.library, "Declined")
        await rig.placement.summaryIsDue(declined)
        rig.placement.perform(.startNow, for: declined)
        try await waitUntil("the second countdown to the cloud") { rig.placement.planners[declined]?.conversation.localFailed == true }
        rig.placement.perform(.useLocal, for: declined)
        try await waitUntil("the request to fail") { summaryRequests(rig.library, declined).first?.outcome != nil }
        XCTAssertEqual(summaryRequests(rig.library, declined).first?.outcome?.result, .failed)
        XCTAssertEqual(cloud.asked, [id])
        // Kept off the cloud: it fails with nothing to try.
        let personal = transcribed(rig.library, "Personal")
        rig.library.update(personal) { $0.placement = .personal }
        await rig.placement.summaryIsDue(personal)
        try await waitUntil("the Personal request to fail") { summaryRequests(rig.library, personal).first?.outcome != nil }
        XCTAssertEqual(summaryRequests(rig.library, personal).first?.outcome?.result, .failed)
        XCTAssertEqual(cloud.asked, [id])
    }

    func testBehaviorAFailureHereNeverHandsItBackAndForthWithTheCloud() async throws {
        // Declined the cloud for a long conversation, then failed here: the request fails, no cloud.
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, local: Local(failure: LocalFailure()), macSeen: false)
        let declined = long(rig.library)
        await rig.placement.summaryIsDue(declined)
        rig.placement.perform(.useLocal, for: declined)
        try await waitUntil("the request to fail") { summaryRequests(rig.library, declined).first?.outcome != nil }
        XCTAssertEqual(summaryRequests(rig.library, declined).first?.outcome?.result, .failed)
        XCTAssertTrue(cloud.asked.isEmpty)
        XCTAssertNil(rig.placement.planners[declined])
        // Failed here, then too long for the cloud: the request fails with what went wrong here, once.
        cloud.failure = CloudError.inputTooLong(model: "Claude Sonnet 5.5", details: "")
        let id = transcribed(rig.library, "Too long everywhere")
        await rig.placement.summaryIsDue(id)
        rig.placement.perform(.startNow, for: id)
        try await waitUntil("the countdown to the cloud") { rig.placement.planners[id]?.conversation.localFailed == true }
        rig.placement.perform(.startNow, for: id)
        try await waitUntil("the request to fail") { summaryRequests(rig.library, id).first?.outcome != nil }
        let outcome = try XCTUnwrap(summaryRequests(rig.library, id).first?.outcome)
        XCTAssertEqual(outcome.result, .failed)
        XCTAssertNil(rig.placement.planners[id], "Nothing left to try")
        XCTAssertEqual(cloud.asked.filter { $0 == id }.count, 1, "Tried in the cloud once")
    }

    func testBehaviorAwayFromTheScreenNoCountdownToTheCloudBegins() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, local: Local())
        rig.placement.leftForeground()
        let id = long(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertNil(rig.placement.planners[id], "Nothing counts down out of sight")
        try await waitUntil("the summary here") { rig.library.meeting(id)?.summary?.overview == "From this iPhone" }
        XCTAssertTrue(cloud.asked.isEmpty, "Where it would have run without the cloud")
        rig.placement.cameToForeground()
        let next = long(rig.library, "On the screen")
        await rig.placement.summaryIsDue(next)
        XCTAssertEqual(rig.placement.planners[next]?.actions, [.startNow, .useLocal])
    }

    func testBehaviorABackgroundLaunchNeverCountsDownToTheCloud() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud)
        // Gemma 4 E4B on the Mac: a long conversation would count down to the cloud (53 against 94).
        let macs = [studio(at: rig.clock.now, model: "gemma-4/e4b-4bit")]
        rig.presence.devices = macs
        rig.placement.refresh()
        let id = long(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertEqual(rig.placement.planners[id]?.endsInCloud, true)
        XCTAssertNotNil(summaryRequests(rig.library, id).first, "Held when Daybook stopped")
        // iOS relaunches Daybook in the background: no scene phase has said so yet.
        var active = false
        let relaunched = PhoneSummaryPlacement(library: rig.library, link: rig.link, presence: { macs }, clock: { rig.clock.now }, runsTimer: false,
                                               appIsActive: { active })
        relaunched.cloud = CloudSetup.demo(providers: [.anthropic], defaults: makeTestDefaults("PhoneSummaryPlacementTests"))
        relaunched.cloudSummarizer = cloud
        XCTAssertFalse(relaunched.isOnScreen)
        XCTAssertFalse(relaunched.placements.countdownsAreSeen)
        await relaunched.resumeHeldSummaries()
        XCTAssertNil(relaunched.planners[id], "Nothing counts down out of sight")
        XCTAssertTrue(cloud.asked.isEmpty, "Never sent")
        XCTAssertEqual(summaryRequests(rig.library, id).first?.claim?.lease, 0, "Given back, for the Mac it would have gone to")
        // In front, a countdown to the cloud may begin; inactive (Control Center), it goes where it would have run.
        active = true
        relaunched.refresh()
        XCTAssertTrue(relaunched.isOnScreen)
        let next = long(rig.library, "In front")
        await relaunched.summaryIsDue(next)
        XCTAssertEqual(relaunched.planners[next]?.actions, [.startNow, .useLocal])
        relaunched.becameInactive()
        XCTAssertNil(relaunched.planners[next], "Sent to the Mac")
        XCTAssertTrue(cloud.asked.isEmpty)
    }

    // MARK: This iPhone's own summarizer

    func testBehaviorWithItsOwnSummarizerItCountsDownHereAndOffersWaitForAMac() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]), local: Local())
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        let planner = try XCTUnwrap(rig.placement.planners[id])
        XCTAssertEqual(planner.line(at: rig.clock.now, thisDevice: PhoneSummaryPlacement.thisDeviceWords),
                       SummaryPlacementWords.countdown(on: PhoneSummaryPlacement.thisDeviceWords, seconds: 15))
        XCTAssertEqual(planner.actions, [.useCloud, .startNow, .waitForMac])
        rig.placement.perform(.startNow, for: id)
        // The processor saves the summary, then finishes the request once the suggested terms are in.
        try await waitUntil("the summary, and its request finished") {
            rig.library.meeting(id)?.summary != nil && summaryRequests(rig.library, id).first?.outcome != nil
        }
        XCTAssertNil(rig.placement.runs[id], "the processor's work: its status says it")
        let summary = try XCTUnwrap(rig.library.meeting(id)?.summary)
        XCTAssertEqual(summary.overview, "From this iPhone")
        XCTAssertEqual(summaryRequests(rig.library, id).first?.outcome?.result, .completed, "on the request claimed for it")
        XCTAssertEqual(summary.origin.colophon(thisDeviceID: rig.library.thisDevice.id, thisDevice: "this iPhone", unknown: "your Mac"),
                       "Summarized on this iPhone")

        // Wait for a Mac passes over this iPhone: the reachable Mac gets it.
        let other = transcribed(rig.library, "Second")
        await rig.placement.summaryIsDue(other)
        rig.placement.perform(.waitForMac, for: other)
        XCTAssertEqual(summaryRequests(rig.library, other).count, 1)
        XCTAssertNil(rig.library.meeting(other)?.summary)
    }

    // MARK: Never twice

    func testBehaviorAMacAlreadyOnItKeepsIt() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let id = transcribed(rig.library)
        let mac = ProcessingRequest.Device(id: studioID.uuidString, name: "Studio Mac")
        let request = ProcessingRequest(meetingID: id, mode: .newAudio, requestedBy: rig.library.thisDevice)
        rig.library.update(id) { $0.upsertProcessingRequest(request.claimed(by: mac, at: rig.clock.now)!) }
        await rig.placement.summaryIsDue(id)
        XCTAssertNil(rig.placement.planners[id], "The Mac's work ends with a summary: no countdown here")
        XCTAssertNil(rig.library.claimSummary(id))
    }

    func testBehaviorAMacClaimingItDuringTheCountdownEndsItHere() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertNotNil(rig.placement.planners[id])
        // Through sync: a Mac took a request for it (its own countdown ran out first).
        let mac = ProcessingRequest.Device(id: studioID.uuidString, name: "Studio Mac")
        let request = ProcessingRequest(meetingID: id, mode: .summaryOnly, requestedBy: mac)
        rig.library.update(id) { $0.upsertProcessingRequest(request.claimed(by: mac, at: rig.clock.now)!) }
        rig.placement.syncApplied()
        XCTAssertNil(rig.placement.planners[id])
        let requests = summaryRequests(rig.library, id)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.filter { ($0.claim?.lease ?? 0) > 0 }.compactMap(\.claim?.device), [mac],
                       "The one it held is given back; the Mac's carries the work")
    }

    func testBehaviorLosingTheClaimInAMergeStopsTheCloudHere() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, macSeen: false)
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        cloud.hold()
        rig.placement.perform(.useCloud, for: id)
        try await waitUntil("the cloud to be asked") { cloud.isWaiting }
        // A Mac claimed the same request at the same moment, and its claim won the merge.
        var mine = try XCTUnwrap(summaryRequests(rig.library, id).first)
        let mac = ProcessingRequest.Device(id: studioID.uuidString, name: "Studio Mac")
        mine.claim = ProcessingRequest.Claim(device: mac, claimedAt: rig.clock.now.addingTimeInterval(1), heartbeat: rig.clock.now.addingTimeInterval(1),
                                             expiresAt: rig.clock.now.addingTimeInterval(600))
        rig.library.update(id) { $0.upsertProcessingRequest(mine) }
        rig.placement.syncApplied()
        try await waitUntil("it to stop") { rig.placement.runs[id] == nil }
        XCTAssertNil(rig.library.meeting(id)?.summary, "The Mac writes the one summary")
        XCTAssertNil(summaryRequests(rig.library, id).first?.outcome)
    }

    // MARK: Never stranded

    func testBehaviorASummaryHeldWhenDaybookStoppedIsPlacedAgainAtLaunch() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, macSeen: false)
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertEqual(rig.placement.planners[id]?.phase, .waitingForMac)
        let held = try XCTUnwrap(summaryRequests(rig.library, id).first)
        // A second conversation whose hold a Mac took over meanwhile (this iPhone stayed away past its lease).
        let taken = transcribed(rig.library, "Taken over")
        await rig.placement.summaryIsDue(taken)
        let mac = ProcessingRequest.Device(id: studioID.uuidString, name: "Studio Mac")
        var takenOver = try XCTUnwrap(summaryRequests(rig.library, taken).first)
        takenOver.claim = ProcessingRequest.Claim(device: mac, claimedAt: rig.clock.now.addingTimeInterval(1), heartbeat: rig.clock.now.addingTimeInterval(1),
                                                  expiresAt: rig.clock.now.addingTimeInterval(600))
        rig.library.update(taken) { $0.upsertProcessingRequest(takenOver) }

        // Daybook is killed: everything in memory goes. The next launch finds what it held.
        let relaunched = PhoneSummaryPlacement(library: rig.library, link: rig.link, presence: { [] }, clock: { rig.clock.now }, runsTimer: false, appIsActive: { true })
        relaunched.cloud = CloudSetup.demo(providers: [.anthropic], defaults: makeTestDefaults("PhoneSummaryPlacementTests"))
        relaunched.cloudSummarizer = cloud
        XCTAssertEqual(relaunched.heldRequest(id)?.id, held.id)
        XCTAssertNil(relaunched.heldRequest(taken), "The Mac has that one")
        await relaunched.resumeHeldSummaries()
        XCTAssertEqual(relaunched.planners[id]?.phase, .waitingForMac, "Placed again: Use the Cloud, or a Mac when one comes")
        XCTAssertNil(relaunched.planners[taken])
        relaunched.perform(.useCloud, for: id)
        try await waitUntil("the summary") { rig.library.meeting(id)?.summary != nil }
        XCTAssertEqual(cloud.asked, [id])
        XCTAssertEqual(summaryRequests(rig.library, id).map(\.id), [held.id], "On the request it held")
        XCTAssertEqual(summaryRequests(rig.library, id).first?.outcome?.result, .completed)
        XCTAssertEqual(summaryRequests(rig.library, taken).first?.claim?.device, mac, "Left to the Mac")
    }

    func testBehaviorASummaryHeldHereGoesToAMacIfThisIPhoneNeverComesBack() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertNotNil(rig.placement.planners[id]?.deadline)
        let held = try XCTUnwrap(summaryRequests(rig.library, id).first)
        // A Mac that first sees the hold as the countdown starts leaves it while its lease lasts, then may take it.
        let mac = ProcessingRequest.Device(id: studioID.uuidString, name: "Studio Mac")
        let macsView = ClaimObservations()
        XCTAssertFalse(held.isClaimable(by: mac, at: rig.clock.now, observations: macsView))
        XCTAssertFalse(held.isClaimable(by: mac, at: rig.clock.now.addingTimeInterval(ProcessingRequest.defaultLease - 1), observations: macsView))
        let takenOver = try XCTUnwrap(held.claimed(by: mac, at: rig.clock.now.addingTimeInterval(ProcessingRequest.defaultLease + 1), observations: macsView),
                                      "The iPhone never came back: the Mac takes it")
        XCTAssertEqual(takenOver.mode, .summaryOnly)
        XCTAssertEqual(takenOver.requestedBy, rig.library.thisDevice)
    }

    // MARK: The background

    func testBehaviorLeavingTheScreenStartsEachCountdownsDefault() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let counting = transcribed(rig.library, "Counting")
        await rig.placement.summaryIsDue(counting)
        XCTAssertNotNil(rig.placement.planners[counting]?.deadline)
        rig.placement.leftForeground()
        XCTAssertNil(rig.placement.planners[counting])
        XCTAssertEqual(summaryRequests(rig.library, counting).count, 1, "The countdown's default: the Mac")
        // Waiting for a Mac (back on the screen, then away again): left to one through the library.
        rig.placement.cameToForeground()
        rig.presence.devices = []
        rig.placement.refresh()
        let waiting = transcribed(rig.library, "Waiting")
        await rig.placement.summaryIsDue(waiting)
        XCTAssertEqual(rig.placement.planners[waiting]?.phase, .waitingForMac)
        rig.placement.leftForeground()
        XCTAssertTrue(rig.placement.planners.isEmpty)
        XCTAssertEqual(summaryRequests(rig.library, waiting).count, 1)
    }

    // MARK: A Mac's countdown

    func testBehaviorAMacsCountdownShowsHereAndTheChoiceGoesToIt() async throws {
        let macID = UUID()
        let store = MemoryLinkKeyStore()
        let service = LinkService(identity: LinkIdentity(deviceID: macID, name: "Studio Mac", deviceClass: .mac, appVersion: "2.0", canProcess: true,
                                                         features: [LinkCapabilities.summaryPlacementFeature],
                                                         processing: LinkProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: true,
                                                                                                models: ["summarization": "gemma-4/e4b"])),
                                  keyStore: store, configuration: .loopback())
        try await service.start()
        addTeardownBlock { await service.stop() }
        let listening = await service.port
        let port = try XCTUnwrap(listening)
        let choices = Choices(service.events())
        let link = PhoneLink(identity: PhoneLink.identity(installation: UUID().uuidString, name: "Test iPhone", libraryID: nil),
                             keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        addTeardownBlock { await link.setActivity(.background) }
        let rig = try await rig(cloud: Cloud(models: [sonnet]), macSeen: false, link: link)
        await link.start()
        let code = await service.beginPairing()
        _ = try await link.pair(with: LinkEndpoint(host: "127.0.0.1", port: port), code: code.digits)
        // Connected, and its capabilities in: the connection's state can arrive before the message that carries them.
        try await waitUntil("connected") { link.macs.first.map { $0.isConnected && $0.appVersion != nil } == true }
        let mac = try XCTUnwrap(link.macs.first)
        XCTAssertEqual(mac.processing?.models?["summarization"], "gemma-4/e4b", "What it summarizes with, from its capabilities")
        XCTAssertTrue(mac.placesSummaries)
        rig.placement.refresh()
        XCTAssertEqual(rig.placement.reachableMacs.map(\.name), ["Studio Mac"], "Connected now")

        let id = transcribed(rig.library)
        await rig.placement.summaryIsDue(id)
        XCTAssertNotNil(rig.placement.planners[id])
        try await service.send(.processingProgress(LinkProcessingProgress(meetingID: id, phase: .summaryCountdown, macName: "Studio Mac",
                                                                          countdown: LinkSummaryCountdown(secondsLeft: 12, cloudOffered: true))))
        try await waitUntil("the Mac's countdown") { link.liveProgress[id]?.isCountingDown == true }
        XCTAssertNil(rig.placement.planners[id], "Two countdowns for one conversation: the Mac's is the one")
        let live = try XCTUnwrap(rig.placement.live(id))
        let page = try XCTUnwrap(try pageStatus(rig, id, .transcribed, live: live, cloudOffered: true, now: live.receivedAt.addingTimeInterval(2)))
        XCTAssertEqual(page.title, SummaryPlacementWords.countdown(on: "Studio Mac", seconds: 10))
        XCTAssertEqual(page.actions, [.placement(.useCloud), .placement(.startNow)])
        XCTAssertEqual(try rowStatus(rig, id, .transcribed, live: live, now: live.receivedAt)?.text, SummaryPlacementWords.countdown(seconds: 12))
        rig.placement.perform(.useCloud, for: id)
        try await waitUntil("the choice at the Mac") { choices.received.contains { $0.meetingID == id && $0.choice == .useCloud } }
        XCTAssertTrue(summaryRequests(rig.library, id).allSatisfy { ($0.claim?.lease ?? 0) == 0 }, "The Mac runs it; nothing is held here")
    }

    // MARK: The status sheet

    func testBehaviorTheStatusSheetShowsCountdownsAndChoices() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let counting = UUID(), waiting = UUID(), asked = UUID()
        var options = SummaryOptions(thisDeviceCanSummarize: false, reachableMacs: [(id: studioID, name: "Studio Mac")], cloud: sonnet)
        let toMac = SummaryPlacementPlanner(options: options, preferences: CloudSummaryPreferences(), at: now, waitsForMacs: true)
        options = SummaryOptions(thisDeviceCanSummarize: false, reachableMacs: [], cloud: sonnet)
        let forMac = SummaryPlacementPlanner(options: options, preferences: CloudSummaryPreferences(), at: now, waitsForMacs: true)
        var request = ProcessingRequest(meetingID: asked, mode: .summaryOnly, requestedBy: ProcessingRequest.Device(id: "me", name: "Test iPhone"))
        request.createdAt = now
        var askedMeeting = Meeting(id: asked, title: "Asked")
        askedMeeting.processingRequests = [request]
        let meetings = [Meeting(id: counting, title: "Counting"), Meeting(id: waiting, title: "Waiting"), askedMeeting]
        let queue = StatusOverviewModel.queue(meetings: meetings, liveProgress: [:], words: .iPhone(id: "me"), planners: [counting: toMac, waiting: forMac],
                                              cloudOffered: { _ in true }, now: now)
        let byTitle = Dictionary(uniqueKeysWithValues: queue.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Counting"]?.line(under: nil, at: now.addingTimeInterval(3)), SummaryPlacementWords.countdown(on: "Studio Mac", seconds: 12))
        XCTAssertEqual(byTitle["Counting"]?.line(under: "Studio Mac", at: now.addingTimeInterval(3)), SummaryPlacementWords.countdown(seconds: 12),
                       "Under that Mac")
        XCTAssertEqual(byTitle["Counting"]?.actions, [.useCloud, .startNow])
        XCTAssertEqual(byTitle["Waiting"]?.line, SummaryPlacementWords.waitingForMac)
        XCTAssertEqual(byTitle["Waiting"]?.actions, [.useCloud])
        XCTAssertEqual(byTitle["Asked"]?.line, SummaryPlacementWords.waitingForMac)
        XCTAssertEqual(byTitle["Asked"]?.actions, [.useCloud])
        let withoutCloud = StatusOverviewModel.queue(meetings: [askedMeeting], liveProgress: [:], words: .iPhone(id: "me"), now: now)
        XCTAssertEqual(withoutCloud.first?.line, "Waiting")
        XCTAssertEqual(withoutCloud.first?.actions, [])
    }

    /// What a Mac's link heard from the phone.
    final class Choices: @unchecked Sendable {
        private let lock = NSLock()
        private var choices: [LinkSummaryChoice] = []
        private var task: Task<Void, Never>?
        init(_ stream: AsyncStream<LinkEvent>) {
            task = Task { [weak self] in
                for await event in stream {
                    if case .received(.summaryChoice(let choice), _) = event { self?.lock.withLock { self?.choices.append(choice) } }
                }
            }
        }
        deinit { task?.cancel() }
        var received: [LinkSummaryChoice] { lock.withLock { choices } }
    }
}
