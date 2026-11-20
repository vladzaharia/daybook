import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Summarize Again's menu on the Mac (docs/cloud.md, "When the cloud is chosen"): what it offers at the app level, the
/// cloud row sending as Use the Cloud does and only while the conversation still qualifies, and a summary made with
/// another installed model for that run only. Fake inference, a fake cloud, a fake provider server; no network.
@MainActor
final class SummarizeAgainProcessingTests: XCTestCase {
    private let other = "gemma-4/e2b-4bit"

    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self)
        rig.state.physicalMemory = 64 << 30
        rig.state.transcriptionModel = "parakeet/ultra"
        rig.state.summaryModel = "gemma-4/12b-4bit"
        rig.state.installedModels = [rig.state.transcriptionModel, rig.state.summaryModel, rig.state.processingPreferences.speakerModelID]
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    /// Settings › Cloud with an in-memory Anthropic key and a fake cloud.
    private func withCloud(_ rig: MultiSourceRig, policy: CloudSummaryPreferences.Policy = .ask) -> FakeCloud {
        var preferences = CloudSummaryPreferences()
        preferences.policy = policy
        rig.state.cloud = CloudSetup.demo(providers: [.anthropic], preferences: preferences, defaults: makeTestDefaults("SummarizeAgainProcessingTests"))
        let cloud = FakeCloud()
        rig.state.cloudSummarizer = cloud
        return cloud
    }

    /// A conversation recorded and summarized on this Mac, before any cloud is set.
    private func processed(_ rig: MultiSourceRig, _ title: String, frequency: Double) async throws -> UUID {
        let audio = try rig.audio("\(title).wav", frequency: frequency)
        let id = try await rig.waitingConversation(title, audio: audio, script: [(0, "We ship on Friday."), (5, "Dana owns the notes.")])
        rig.state.processor.enqueue(id)
        try await rig.processed(id)
        return id
    }

    private func cloudRow(_ rig: MultiSourceRig, _ id: UUID) throws -> SummarizeAgainChoice? {
        rig.state.summarizeAgainChoices(for: try XCTUnwrap(rig.meeting(id))).first { if case .cloud = $0.place { true } else { false } }
    }

    /// Another conversation keeps the queue busy, so a job queued now waits and the conversation can change before it runs.
    private func busy(_ rig: MultiSourceRig) async throws -> (UUID, URL) {
        let audio = try rig.audio("Busy.wav", frequency: 455)
        let busy = try await rig.waitingConversation("Busy", audio: audio, script: [(0, "Hello there.")])
        try rig.inference.block(audio)
        rig.state.processor.enqueue(busy)
        try await waitUntil("the other conversation to be transcribing") { rig.inference.isWaiting(on: audio) }
        return (busy, audio)
    }

    // MARK: What the menu offers

    func testBehaviorTheCloudRowIsOfferedOnlyInsideThePrivacyRule() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "Gated", frequency: 300)
        XCTAssertNil(try cloudRow(rig, id), "No key")
        _ = withCloud(rig)
        XCTAssertEqual(try cloudRow(rig, id)?.title, "With Claude Sonnet 5.5")
        XCTAssertEqual(rig.state.summarizeAgainChoices(for: try XCTUnwrap(rig.meeting(id))).map(\.title), ["With Gemma 4 · 12B", "With Claude Sonnet 5.5"], "this device's model first")

        var preferences = rig.state.cloud.preferences
        preferences.policy = .never
        rig.state.cloud.preferences = preferences
        XCTAssertNil(try cloudRow(rig, id), "Never")
        preferences.policy = .ask
        rig.state.cloud.preferences = preferences
        XCTAssertNotNil(try cloudRow(rig, id))

        preferences.placements.set(.work, allowed: false)
        rig.state.cloud.preferences = preferences
        rig.state.library.update(id) { $0.placement = .work }
        XCTAssertNil(try cloudRow(rig, id), "Work's switch is off")
        preferences.placements.set(.work, allowed: true)
        rig.state.cloud.preferences = preferences

        rig.state.library.update(id) { $0.placement = .personal }
        XCTAssertNil(try cloudRow(rig, id), "Personal is off by default")
        preferences.placements.set(.personal, allowed: true)
        rig.state.cloud.preferences = preferences
        XCTAssertNotNil(try cloudRow(rig, id))

        preferences.placements = try JSONDecoder().decode(CloudPlacements.self, from: Data("[1]".utf8))
        rig.state.cloud.preferences = preferences
        XCTAssertNil(try cloudRow(rig, id), "A placement setting this version can't read never goes")
    }

    func testBehaviorTheListHoldsOnlyWhatIsInstalledAndFits() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "Installed", frequency: 305)
        let meeting = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(rig.state.summarizeAgainChoices(for: meeting).count, 1, "One way: no menu")
        rig.state.installedModels.insert(other)
        let ids = rig.state.summarizeAgainChoices(for: meeting).map(\.place)
        XCTAssertEqual(ids.first, .thisDevice(model: "gemma-4/12b-4bit"), "The one Summarize Again uses comes first")
        XCTAssertTrue(ids.contains(.thisDevice(model: other)))
        rig.state.physicalMemory = 1 << 30
        XCTAssertTrue(rig.state.summarizeAgainChoices(for: meeting).isEmpty, "None fits")
    }

    // MARK: Sending

    func testBehaviorChoosingTheCloudQueuesWhatUseTheCloudQueues() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "Queued", frequency: 310)
        _ = withCloud(rig)
        let (busy, audio) = try await busy(rig)
        let choice = try XCTUnwrap(try cloudRow(rig, id))
        rig.state.summarizeAgain(id, as: choice)
        let chosen = try XCTUnwrap(rig.state.processor.queue.jobs.first { $0.meetingID == id })
        rig.state.cancelQueued(id)
        rig.state.summarizeInCloud(id)
        let useTheCloud = try XCTUnwrap(rig.state.processor.queue.jobs.first { $0.meetingID == id })
        XCTAssertEqual(chosen.mode, .summaryOnly)
        XCTAssertTrue(chosen.summarizesInCloud)
        XCTAssertEqual([chosen.mode, useTheCloud.mode], [.summaryOnly, .summaryOnly])
        XCTAssertEqual(chosen.summarizesInCloud, useTheCloud.summarizesInCloud)
        XCTAssertEqual(chosen.summaryModelID, useTheCloud.summaryModelID)
        XCTAssertEqual(chosen.templateID, useTheCloud.templateID)
        XCTAssertNil(chosen.upgrade)
        rig.state.cancelQueued(id)
        try rig.inference.unblock(audio)
        try await rig.processed(busy)
    }

    func testBehaviorTheCloudSummaryIsMadeThereAsThePersonsChoice() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "There", frequency: 315)
        let cloud = withCloud(rig)
        let summarized = rig.inference.summarized.count
        rig.state.summarizeAgain(id, as: try XCTUnwrap(try cloudRow(rig, id)))
        try await rig.processed(id)
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertEqual(rig.inference.summarized.count, summarized, "Not here")
        XCTAssertEqual(rig.meeting(id)?.summary?.origin.cloudModel, "Claude Sonnet 5.5")
        XCTAssertEqual(rig.meeting(id)?.summary?.cloudReason, .chosen)
        XCTAssertGreaterThanOrEqual(rig.meeting(id)?.revisions.filter { $0.field == "summary" }.count ?? 0, 2, "The old summary stays in Version History")
    }

    /// Chosen, then the conversation stops qualifying before the job sends: nothing is sent, and it runs here.
    private func stopsQualifying(_ name: String, frequency: Double, change: @MainActor (MultiSourceRig, UUID) async -> Void) async throws {
        let rig = try await rig()
        let id = try await processed(rig, name, frequency: frequency)
        let cloud = withCloud(rig)
        rig.state.library.update(id) { $0.placement = .work }
        let (busy, audio) = try await busy(rig)
        rig.state.summarizeAgain(id, as: try XCTUnwrap(try cloudRow(rig, id)))
        XCTAssertTrue(rig.state.processor.queue.isQueued(id), name)
        await change(rig, id)
        let summarized = rig.inference.summarized.count
        try rig.inference.unblock(audio)
        try await rig.processed(busy)
        try await rig.processed(id)
        XCTAssertTrue(cloud.summarized.isEmpty, "\(name): never sent")
        XCTAssertEqual(rig.inference.summarized.count, summarized + 2, "\(name): summarized here (and the busy one)")
    }

    func testBehaviorAConversationMovedToPersonalBeforeTheSendRunsHere() async throws {
        try await stopsQualifying("Moved", frequency: 320) { rig, id in rig.state.library.update(id) { $0.placement = .personal } }
    }

    func testBehaviorAPlacementSwitchTurnedOffBeforeTheSendRunsHere() async throws {
        try await stopsQualifying("Switched", frequency: 325) { rig, _ in
            var preferences = rig.state.cloud.preferences
            preferences.placements.set(.work, allowed: false)
            rig.state.cloud.preferences = preferences
        }
    }

    func testBehaviorNeverSetBeforeTheSendRunsHere() async throws {
        try await stopsQualifying("Never", frequency: 330) { rig, _ in
            var preferences = rig.state.cloud.preferences
            preferences.policy = .never
            rig.state.cloud.preferences = preferences
        }
    }

    func testBehaviorTheKeyRemovedBeforeTheSendRunsHere() async throws {
        try await stopsQualifying("Key", frequency: 335) { rig, _ in await rig.state.cloud.removeKey(for: .anthropic) }
    }

    func testBehaviorTheRequestIsTheOneACloudUpgradeSends() async throws {
        let server = FakeCloudServer()
        let reply = #"{"kind":"general","title":"Call","overview":"We ship on Friday.","sections":[],"actionItems":[],"terms":["Friday"]}"#
        server.handle { request in
            switch request.path {
            case "/v1/models" where request.header("x-api-key") != nil:
                return .json(["data": [["id": "claude-sonnet-5-5", "max_input_tokens": 1_000_000, "max_tokens": 128_000]]])
            case "/v1/messages": return .anthropicReply([reply], inputTokens: 100, outputTokens: 50)
            default: return .failure(.cannotFindHost)
            }
        }
        var client = CloudClient(session: server.session, endpoints: CloudEndpoints(base: server.base))
        client.wait = { _ in }
        let rig = try await rig()
        let id = try await processed(rig, "Same request", frequency: 340)
        let defaults = makeTestDefaults("SummarizeAgainProcessingTests")
        CloudSummaryPreferences().save(to: defaults)
        let key = try XCTUnwrap(CloudAPIKey("sk-ant-api03-TESTtestTESTtestTESTtest-gDAA"))
        let setup = CloudSetup(keys: MemoryCloudKeyStore([.anthropic: key]), client: client, defaults: defaults)
        await setup.refresh()
        rig.state.cloud = setup

        rig.state.summarizeAgain(id, as: try XCTUnwrap(try cloudRow(rig, id)))
        try await rig.processed(id)
        // The first summary's suggested term joined the vocabulary, which every request carries: the same vocabulary for both.
        rig.state.glossary.map(\.id).forEach(rig.state.removeGlossaryTerm)
        // The conversation as a cloud Upgrade finds it: written by a weaker model.
        rig.state.update(id) { meeting in
            guard var made = meeting.summary else { return }
            made.modelID = other
            made.processingSettings = ProcessingSettings(modelID: other)
            meeting.summary = made.placed(.thisDevice, by: ProcessingRequest.Device(id: "phone", name: "Vlad's iPhone"), inputs: meeting.modelsBehindTranscript)
        }
        let offer = try XCTUnwrap(rig.state.upgradeOffer(for: try XCTUnwrap(rig.meeting(id))))
        XCTAssertEqual(offer.line, "Upgrade summary with Claude Sonnet 5.5")
        rig.state.acceptUpgrade(offer, for: id)
        try await rig.processed(id)
        let bodies = server.requests.filter { $0.path == "/v1/messages" }.map(\.body)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last, "Byte for byte the same request")
    }

    // MARK: Another model for this run

    func testBehaviorASummaryMadeWithAnotherInstalledModelLeavesTheChosenOneAlone() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "Another", frequency: 345)
        rig.state.installedModels.insert(other)
        let chosen = rig.state.summaryModel
        rig.state.summarizeAgain(id, as: SummarizeAgainChoice(place: .thisDevice(model: other), title: "With Gemma 4 E2B"))
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.summary?.modelsByRole["summarization"], other)
        XCTAssertEqual(rig.state.summaryModel, chosen, "Settings keeps its choice")
        rig.state.processor.enqueue(id, mode: .summaryOnly)
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.summary?.modelsByRole["summarization"], chosen, "The next plain Summarize Again is as before")
    }

    func testBehaviorAModelThatWentBeforeTheRunFallsBackToTheChosenOne() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "Gone", frequency: 350)
        let chosen = rig.state.summaryModel
        // Not installed: no download, no failure.
        rig.state.processor.enqueue(id, mode: .summaryOnly, summaryModelID: other)
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.summary?.modelsByRole["summarization"], chosen)
        XCTAssertTrue(rig.state.processor.queue.awaitingModels.isEmpty)
        // Installed, but this Mac no longer has the memory for it.
        rig.state.installedModels.insert(other)
        rig.state.physicalMemory = 1 << 30
        XCTAssertEqual(rig.state.makeJob(meetingID: id, mode: .summaryOnly, summaryModelID: other).summaryModelID, chosen)
    }
}
