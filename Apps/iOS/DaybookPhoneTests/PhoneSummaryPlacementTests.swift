import DaybookKit
import DaybookLink
import SwiftUI
import XCTest
@testable import DaybookPhone

/// Where the iPhone's summaries run (docs/multipoint.md, "Where summaries run"; docs/iphone.md): the same
/// planner as the Mac's, sending a summary to a reachable Mac after a countdown, waiting for one with Use the
/// Cloud, running it in the cloud or on a local summarizer with a claim, a Mac's countdown shown here with the
/// choice sent to it, and the default happening when the app leaves the screen. A temporary library, a fake
/// cloud and summarizer, presence records, and a loopback Mac; no network, no models.
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
        init(models: [CloudModel]) { self.models = models }
        var asked: [UUID] { lock.withLock { _asked } }
        var isWaiting: Bool { lock.withLock { gate != nil } }
        func hold() { lock.withLock { held = true } }
        func release() { let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in held = false; defer { self.gate = nil }; return self.gate }; gate?.resume() }
        func availableModels(refresh: Bool) async -> [CloudModel] { models }
        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel, effort: CloudEffort,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
            lock.withLock { _asked.append(meeting.id) }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let wait = lock.withLock { () -> Bool in if held { gate = continuation }; return held }
                    if !wait { continuation.resume() }
                }
            } onCancel: { [weak self] in self?.release() }
            try Task.checkCancellation()
            return MeetingSummary(title: meeting.title, overview: "From the cloud", modelID: model.id)
        }
    }

    /// This iPhone's own summarizer, standing in for the iPhone's processing models.
    struct Local: LocalSummarizing {
        var canSummarize = true
        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                       progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
            MeetingSummary(title: meeting.title, overview: "From this iPhone", modelID: "gemma-4/e2b")
        }
    }

    private struct Rig {
        let library: LibraryController
        let link: PhoneLink
        let placement: PhoneSummaryPlacement
        let presence: PresenceBox
        let clock: ClockBox
    }

    final class PresenceBox { var devices: [KnownSyncDevice] = [] }
    final class ClockBox { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func rig(cloud: Cloud? = nil, local: (any LocalSummarizing)? = nil, macSeen: Bool = true, link: PhoneLink? = nil) async throws -> Rig {
        let library = LibraryController(rootURL: try temporaryDirectory("placement-\(UUID().uuidString)"), sync: nil)
        try await library.load()
        let link = link ?? PhoneLink(identity: PhoneLink.identity(installation: UUID().uuidString, name: "Test iPhone", libraryID: nil),
                                     keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        let presence = PresenceBox(), clock = ClockBox()
        let placement = PhoneSummaryPlacement(library: library, link: link, presence: { presence.devices },
                                              defaults: makeTestDefaults("PhoneSummaryPlacementTests"), clock: { clock.now }, runsTimer: false)
        if macSeen { presence.devices = [studio(at: clock.now)] }
        placement.localSummarizer = local
        if let cloud {
            placement.cloudSummarizer = cloud
            try await waitUntil("the cloud's models") { placement.cloudOffer != nil }
        }
        placement.refresh()
        return Rig(library: library, link: link, placement: placement, presence: presence, clock: clock)
    }

    /// A Mac that summarizes, seen through sync at `date`.
    private func studio(at date: Date, summarizes: Bool = true) -> KnownSyncDevice {
        var device = KnownSyncDevice(id: studioID.uuidString, deviceClass: .mac, displayName: "Studio Mac", canProcess: true, lastSeen: date)
        device.capabilities = SyncDeviceCapabilities(transcribes: true, findsSpeakers: true, summarizes: summarizes)
        return device
    }

    /// A conversation with this iPhone's transcript and no summary.
    private func transcribed(_ library: LibraryController, _ title: String = "Walk and talk") -> UUID {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", sha256: UUID().uuidString)
        var meeting = Meeting(title: title, tracks: [track], status: .imported)
        meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [TranscriptSegment(trackID: track.id, start: 0, end: 2, text: "Ship it Friday.")],
                                               modelID: "parakeet/v3")]
        library.add(meeting)
        return meeting.id
    }

    private func summaryRequests(_ library: LibraryController, _ id: UUID) -> [ProcessingRequest] {
        (library.meeting(id)?.processingRequests ?? []).filter { $0.mode == .summaryOnly }
    }

    // MARK: To a Mac

    func testBehaviorADueSummaryCountsDownToAReachableMacThenSendsIt() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
        let planner = try XCTUnwrap(rig.placement.planners[id])
        XCTAssertEqual(planner.line(at: rig.clock.now, thisDevice: PhoneSummaryPlacement.thisDeviceWords), "Summarizing on Studio Mac in 15 s")
        XCTAssertEqual(planner.actions, [.useCloud, .startNow])
        XCTAssertTrue(summaryRequests(rig.library, id).isEmpty, "Nothing sent while it counts down")
        rig.clock.now.addTimeInterval(15)
        rig.placement.placements.advance()
        XCTAssertNil(rig.placement.planners[id])
        let sent = try XCTUnwrap(summaryRequests(rig.library, id).first)
        XCTAssertNil(sent.claim, "Sent as a Summarize request, for the Mac to claim")
        XCTAssertEqual(StatusPresentation.page(ProcessingStatus(try XCTUnwrap(rig.library.meeting(id))), meeting: try XCTUnwrap(rig.library.meeting(id)),
                                               sighting: nil)?.title, "Waiting for your Mac to summarize again")
    }

    func testBehaviorWithoutAKeyItGoesToTheMacAtOnce() async throws {
        let rig = try await rig()
        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
        XCTAssertNil(rig.placement.planners[id], "Nothing to choose: no countdown")
        XCTAssertEqual(summaryRequests(rig.library, id).count, 1)
        // With no Mac reachable either, it waits for one through the library, as before.
        rig.presence.devices = []
        let other = transcribed(rig.library, "Second")
        rig.placement.summaryIsDue(other)
        XCTAssertEqual(summaryRequests(rig.library, other).count, 1)
    }

    func testBehaviorWithNoMacItWaitsWithTheCloudOfferedThenCountsDownWhenOneArrives() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]), macSeen: false)
        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
        XCTAssertEqual(rig.placement.planners[id]?.phase, .waitingForMac)
        let page = try XCTUnwrap(StatusPresentation.placement(rig.placement.planners[id], run: nil, live: nil, status: .transcribed,
                                                              cloudOffered: true, sighting: nil, now: rig.clock.now))
        XCTAssertEqual(page.title, "Waiting for a Mac to summarize")
        XCTAssertEqual(page.actions, [.placement(.useCloud)])
        XCTAssertTrue(summaryRequests(rig.library, id).isEmpty, "Not sent: a Mac arriving counts down first")
        // A Mac syncs again (or connects): a fresh countdown, then it's sent.
        rig.clock.now.addTimeInterval(300)
        rig.presence.devices = [studio(at: rig.clock.now)]
        rig.placement.refresh()
        XCTAssertEqual(rig.placement.planners[id]?.deadline, rig.clock.now.addingTimeInterval(15))
        rig.placement.perform(.startNow, for: id)
        XCTAssertEqual(summaryRequests(rig.library, id).count, 1)
    }

    func testBehaviorAMacGoingAwayMidCountdownLeavesItWaiting() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
        rig.clock.now.addTimeInterval(20 * 60)
        rig.placement.refresh()
        XCTAssertEqual(rig.placement.planners[id]?.phase, .waitingForMac, "Its presence is too old to count on")
    }

    // MARK: The cloud

    func testBehaviorUseTheCloudRunsItHereWithAClaimAndRecordsWhereItRan() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, macSeen: false)
        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
        cloud.hold()
        rig.placement.perform(.useCloud, for: id)
        try await waitUntil("the cloud to be asked") { cloud.isWaiting }
        XCTAssertEqual(rig.placement.runs[id], .cloud(sonnet))
        // Held by this iPhone: no Mac takes it meanwhile, and Macs read it as summarizing here.
        let claimed = try XCTUnwrap(summaryRequests(rig.library, id).first)
        XCTAssertEqual(claimed.claim?.device, rig.library.thisDevice)
        XCTAssertEqual(claimed.claim?.stage, .summarizing)
        let running = try XCTUnwrap(StatusPresentation.placement(nil, run: rig.placement.runs[id], live: nil, status: .transcribed, cloudOffered: true))
        XCTAssertEqual(running.title, "Summarizing with Claude Sonnet 5.5")
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

    func testBehaviorSummarizeWithNoMacLeavesTheRequestAndUseTheCloudTakesItBack() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, macSeen: false)
        let id = transcribed(rig.library)
        rig.placement.summarize(id)
        XCTAssertNil(rig.placement.planners[id])
        let waiting = try XCTUnwrap(rig.placement.waitingSummaryRequest(id), "Asked for: it waits for a Mac in the library")
        let meeting = try XCTUnwrap(rig.library.meeting(id))
        let page = try XCTUnwrap(StatusPresentation.placement(nil, run: nil, live: nil, status: ProcessingStatus(meeting), cloudOffered: true))
        XCTAssertEqual(page.title, "Waiting for a Mac to summarize")
        XCTAssertEqual(page.actions, [.placement(.useCloud)])
        XCTAssertNil(StatusPresentation.placement(nil, run: nil, live: nil, status: ProcessingStatus(meeting), cloudOffered: false),
                     "Without the cloud it reads as before")
        rig.placement.perform(.useCloud, for: id)
        try await waitUntil("the summary") { rig.library.meeting(id)?.summary != nil }
        XCTAssertEqual(cloud.asked, [id])
        XCTAssertEqual(summaryRequests(rig.library, id).map(\.id), [waiting.id], "The same request, claimed here and finished")
        XCTAssertEqual(summaryRequests(rig.library, id).first?.outcome?.device, rig.library.thisDevice)
    }

    func testBehaviorAlwaysSendsItToTheCloudWithoutACountdown() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud)
        var preferences = rig.placement.preferences
        preferences.policy = .always
        rig.placement.preferences = preferences
        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
        try await waitUntil("the summary") { rig.library.meeting(id)?.summary != nil }
        XCTAssertEqual(cloud.asked, [id])
    }

    // MARK: This iPhone's own summarizer

    func testBehaviorWithItsOwnSummarizerItCountsDownHereAndOffersWaitForAMac() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]), local: Local())
        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
        let planner = try XCTUnwrap(rig.placement.planners[id])
        XCTAssertEqual(planner.line(at: rig.clock.now, thisDevice: PhoneSummaryPlacement.thisDeviceWords), "Summarizing on this iPhone in 15 s")
        XCTAssertEqual(planner.actions, [.useCloud, .startNow, .waitForMac])
        rig.placement.perform(.startNow, for: id)
        try await waitUntil("the summary") { rig.library.meeting(id)?.summary != nil }
        let summary = try XCTUnwrap(rig.library.meeting(id)?.summary)
        XCTAssertEqual(summary.overview, "From this iPhone")
        XCTAssertEqual(summary.origin.colophon(thisDeviceID: rig.library.thisDevice.id, thisDevice: "this iPhone", unknown: "your Mac"),
                       "Summarized on this iPhone")

        // Wait for a Mac passes over this iPhone: the reachable Mac gets it.
        let other = transcribed(rig.library, "Second")
        rig.placement.summaryIsDue(other)
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
        rig.placement.summaryIsDue(id)
        XCTAssertNil(rig.placement.planners[id], "The Mac's work ends with a summary: no countdown here")
        XCTAssertNil(rig.library.claimSummary(id))
    }

    func testBehaviorAMacClaimingItDuringTheCountdownEndsItHere() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
        XCTAssertNotNil(rig.placement.planners[id])
        // Through sync: a Mac took a request for it (its own countdown ran out first).
        let mac = ProcessingRequest.Device(id: studioID.uuidString, name: "Studio Mac")
        let request = ProcessingRequest(meetingID: id, mode: .summaryOnly, requestedBy: mac)
        rig.library.update(id) { $0.upsertProcessingRequest(request.claimed(by: mac, at: rig.clock.now)!) }
        rig.placement.syncApplied()
        XCTAssertNil(rig.placement.planners[id])
        XCTAssertEqual(summaryRequests(rig.library, id).count, 1, "No second request")
    }

    func testBehaviorLosingTheClaimInAMergeStopsTheCloudHere() async throws {
        let cloud = Cloud(models: [sonnet])
        let rig = try await rig(cloud: cloud, macSeen: false)
        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
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

    // MARK: The background

    func testBehaviorLeavingTheScreenStartsEachCountdownsDefault() async throws {
        let rig = try await rig(cloud: Cloud(models: [sonnet]))
        let counting = transcribed(rig.library, "Counting")
        rig.placement.summaryIsDue(counting)
        XCTAssertNotNil(rig.placement.planners[counting]?.deadline)
        rig.placement.leftForeground()
        XCTAssertNil(rig.placement.planners[counting])
        XCTAssertEqual(summaryRequests(rig.library, counting).count, 1, "The countdown's default: the Mac")
        // Waiting for a Mac: left to one through the library.
        rig.presence.devices = []
        rig.placement.refresh()
        let waiting = transcribed(rig.library, "Waiting")
        rig.placement.summaryIsDue(waiting)
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
        try await waitUntil("connected") { link.macs.first?.isConnected == true }
        let mac = try XCTUnwrap(link.macs.first)
        XCTAssertEqual(mac.processing?.models?["summarization"], "gemma-4/e4b", "What it summarizes with, from its capabilities")
        XCTAssertTrue(mac.placesSummaries)
        rig.placement.refresh()
        XCTAssertEqual(rig.placement.reachableMacs.map(\.name), ["Studio Mac"], "Connected now")

        let id = transcribed(rig.library)
        rig.placement.summaryIsDue(id)
        XCTAssertNotNil(rig.placement.planners[id])
        try await service.send(.processingProgress(LinkProcessingProgress(meetingID: id, phase: .summaryCountdown, macName: "Studio Mac",
                                                                          countdown: LinkSummaryCountdown(secondsLeft: 12, cloudOffered: true))))
        try await waitUntil("the Mac's countdown") { link.liveProgress[id]?.isCountingDown == true }
        XCTAssertNil(rig.placement.planners[id], "Two countdowns for one conversation: the Mac's is the one")
        let live = try XCTUnwrap(rig.placement.live(id))
        let page = try XCTUnwrap(StatusPresentation.placement(nil, run: nil, live: live, status: .transcribed, cloudOffered: true,
                                                              now: live.receivedAt.addingTimeInterval(2)))
        XCTAssertEqual(page.title, "Summarizing on Studio Mac in 10 s")
        XCTAssertEqual(page.actions, [.placement(.useCloud), .placement(.startNow)])
        XCTAssertEqual(StatusPresentation.placementRow(nil, run: nil, live: live, now: live.receivedAt)?.text, "Summarizing in 12 s")
        rig.placement.perform(.useCloud, for: id)
        try await waitUntil("the choice at the Mac") { choices.received.contains { $0.meetingID == id && $0.choice == .useCloud } }
        XCTAssertTrue(summaryRequests(rig.library, id).isEmpty, "The Mac runs it; nothing is claimed here")
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
        let queue = StatusSheetModel.queue(meetings: meetings, liveProgress: [:], thisDevice: "me", planners: [counting: toMac, waiting: forMac],
                                           cloudOffered: true, now: now)
        let byTitle = Dictionary(uniqueKeysWithValues: queue.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Counting"]?.line(under: nil, at: now.addingTimeInterval(3)), "Summarizing on Studio Mac in 12 s")
        XCTAssertEqual(byTitle["Counting"]?.line(under: "Studio Mac", at: now.addingTimeInterval(3)), "Summarizing in 12 s", "Under that Mac")
        XCTAssertEqual(byTitle["Counting"]?.actions, [.useCloud, .startNow])
        XCTAssertEqual(byTitle["Waiting"]?.line, "Waiting for a Mac to summarize")
        XCTAssertEqual(byTitle["Waiting"]?.actions, [.useCloud])
        XCTAssertEqual(byTitle["Asked"]?.line, "Waiting for a Mac to summarize")
        XCTAssertEqual(byTitle["Asked"]?.actions, [.useCloud])
        let withoutCloud = StatusSheetModel.queue(meetings: [askedMeeting], liveProgress: [:], thisDevice: "me", now: now)
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
