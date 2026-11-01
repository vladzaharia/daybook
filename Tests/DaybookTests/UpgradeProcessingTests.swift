import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// "Upgrade" on the Mac (docs/multipoint.md, "Upgrade"): the offer on a conversation's page, the work it starts here, on
/// another Mac, or in the cloud, every later step done again with the person's corrections kept, and no offer once the
/// better model has done it. Fake inference and a fake cloud; no models, no network.
@MainActor
final class UpgradeProcessingTests: XCTestCase {
    private let studio = ProcessingRequest.Device(id: "studio-replica", name: "Studio Mac")

    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self)
        rig.state.requestTiming = RequestTiming(lease: 600, renewInterval: .milliseconds(40))
        rig.state.transcriptionModel = "parakeet/ultra"
        rig.state.summaryModel = "gemma-4/12b-4bit"
        rig.state.installedModels = [rig.state.transcriptionModel, rig.state.summaryModel, rig.state.processingPreferences.speakerModelID]
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    /// Settings › Cloud with an in-memory Anthropic key, and a cloud that answers at once.
    private func withCloud(_ rig: MultiSourceRig, seconds: Int = 15) -> FakeCloud {
        var preferences = CloudSummaryPreferences()
        preferences.countdownSeconds = seconds
        rig.state.cloud = CloudSetup.demo(providers: [.anthropic], preferences: preferences, defaults: makeTestDefaults("UpgradeProcessingTests"))
        let cloud = FakeCloud()
        rig.state.cloudSummarizer = cloud
        return cloud
    }

    /// A conversation recorded and processed on this Mac, its one speaker with a voice.
    private func processed(_ rig: MultiSourceRig, _ title: String, frequency: Double) async throws -> UUID {
        let audio = try rig.audio("\(title).wav", frequency: frequency)
        try rig.inference.voice(audio, [1, 0, 0])
        let id = try await rig.waitingConversation(title, audio: audio, script: [(0, "We ship on Friday."), (5, "Dana owns the launch notes.")])
        rig.state.enqueue(id)
        try await rig.processed(id)
        return id
    }

    /// As if another device's models had made its transcript or summary.
    private func madeWith(_ rig: MultiSourceRig, _ id: UUID, transcription: String? = nil, summary: String? = nil) {
        rig.state.update(id) { meeting in
            if let transcription {
                for index in meeting.transcripts.indices {
                    meeting.transcripts[index].modelID = transcription
                    meeting.transcripts[index].processingSettings = ProcessingSettings(modelID: transcription)
                }
            }
            if let summary, var made = meeting.summary {
                made.modelID = summary
                made.processingSettings = ProcessingSettings(modelID: summary)
                meeting.summary = made.placed(.thisDevice, by: ProcessingRequest.Device(id: "phone", name: "Vlad's iPhone"),
                                              inputs: meeting.modelsBehindTranscript)
            }
        }
    }

    private func offer(_ rig: MultiSourceRig, _ id: UUID) throws -> UpgradeOffer? {
        rig.state.upgradeOffer(for: try XCTUnwrap(rig.meeting(id)))
    }

    /// Studio Mac in the library's presence records, seen a minute ago, with Parakeet Ultra.
    private func studioMac(_ rig: MultiSourceRig) {
        var device = KnownSyncDevice(id: studio.id, deviceClass: .mac, displayName: studio.name, canProcess: true, lastSeen: Date().addingTimeInterval(-60))
        device.capabilities = SyncDeviceCapabilities(transcribes: true, findsSpeakers: true, summarizes: true,
                                                     models: ["transcription": "parakeet/ultra", "diarization": "community-1/offline",
                                                              "summarization": "gemma-4/12b-4bit"])
        rig.state.syncDevices = [device]
    }

    // MARK: On this Mac

    func testBehaviorThisMacRedoesAWeakerTranscriptAndEveryStepAfterItKeepingCorrections() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "Weekly", frequency: 300)
        XCTAssertNil(try offer(rig, id), "Made with this Mac's own models: nothing better")
        madeWith(rig, id, transcription: "parakeet/redux")
        // What the person corrected: a speaker's name and a passage's words.
        let before = try XCTUnwrap(rig.meeting(id))
        let first = try XCTUnwrap(before.unifiedTranscript.first)
        let speaker = try XCTUnwrap(first.speakerID)
        rig.state.update(id) { meeting in
            meeting.renameSpeaker(id: speaker, name: "Dana")
            meeting.correctSegment(id: first.id, text: "We ship on Thursday.")
        }
        let offer = try XCTUnwrap(try offer(rig, id))
        XCTAssertEqual(offer.role, .transcription)
        XCTAssertEqual(offer.place, .thisDevice)
        XCTAssertEqual(offer.line, "Upgrade transcript")
        let transcribed = rig.inference.transcribed.count, summarized = rig.inference.summarized.count
        rig.state.acceptUpgrade(offer, for: id)
        try await rig.processed(id)
        let upgraded = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(rig.inference.transcribed.count, transcribed + 1, "Transcribed again")
        XCTAssertEqual(rig.inference.summarized.count, summarized + 1, "and summarized again")
        XCTAssertEqual(upgraded.upgradeCurrent(.transcription)?.model, "parakeet/ultra")
        XCTAssertEqual(upgraded.summary?.modelsByRole["transcription"], "parakeet/ultra", "The summary read the better transcript")
        // The corrections are kept, and the earlier summary is in Version History.
        let passage = try XCTUnwrap(upgraded.unifiedTranscript.first { $0.text.contains("ship") })
        XCTAssertTrue(passage.text.contains("Thursday"), passage.text)
        XCTAssertEqual(upgraded.speakers.first { $0.id == passage.speakerID }?.name, "Dana")
        XCTAssertGreaterThanOrEqual(upgraded.revisions.filter { $0.field == "summary" }.count, 2)
        XCTAssertTrue(upgraded.revisions.contains { $0.field == "speaker:\(speaker)" })
        XCTAssertNil(rig.state.upgradeOffer(for: upgraded), "Done: never the same offer again")
    }

    func testBehaviorAnUpgradesSummaryCountsDownAsADueOneDoes() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "Countdown", frequency: 320)
        _ = withCloud(rig, seconds: 1)
        madeWith(rig, id, transcription: "parakeet/redux")
        let offer = try XCTUnwrap(try offer(rig, id))
        XCTAssertEqual(offer.role, .transcription, "The most upstream step, though the cloud could write a better summary")
        rig.state.acceptUpgrade(offer, for: id)
        try await waitUntil("the summary's countdown") { rig.state.placements[id]?.deadline != nil }
        XCTAssertEqual(rig.state.placements[id]?.actions, [.useCloud, .startNow])
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.summary?.modelsByRole["summarization"], "gemma-4/12b-4bit", "The countdown ran out: here")
    }

    func testBehaviorACloudUpgradeSummarizesThereAtOnce() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "Cloud", frequency: 340)
        let cloud = withCloud(rig)
        madeWith(rig, id, summary: "gemma-4/e2b-4bit")
        let offer = try XCTUnwrap(try offer(rig, id))
        XCTAssertEqual(offer.line, "Upgrade summary with Claude Sonnet 5.5")
        var counted = false
        let watch = rig.state.placements.$planners.sink { planners in if planners[id]?.deadline != nil { counted = true } }
        defer { watch.cancel() }
        let transcribed = rig.inference.transcribed.count
        rig.state.acceptUpgrade(offer, for: id)
        try await rig.processed(id)
        XCTAssertFalse(counted, "The person chose the cloud: no countdown")
        XCTAssertEqual(cloud.summarized, [id])
        XCTAssertEqual(rig.inference.transcribed.count, transcribed, "Only the summary")
        let upgraded = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(upgraded.summary?.modelsByRole["summarization"], "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(upgraded.summary?.origin.cloudModel, "Claude Sonnet 5.5")
        XCTAssertNil(rig.state.upgradeOffer(for: upgraded))
    }

    func testBehaviorDismissingHidesTheOfferForGood() async throws {
        let rig = try await rig()
        let id = try await processed(rig, "Dismiss", frequency: 360)
        madeWith(rig, id, transcription: "parakeet/redux")
        let offer = try XCTUnwrap(try offer(rig, id))
        rig.state.dismissUpgrade(offer, for: id)
        XCTAssertNil(try self.offer(rig, id))
        XCTAssertEqual(rig.meeting(id)?.upgradeDismissals?.map(\.id), ["transcription|parakeet/ultra"])
    }

    // MARK: Another Mac

    func testBehaviorABetterModelOnAnotherMacIsAskedOfItAndWaitsForIt() async throws {
        let rig = try await rig()
        rig.state.processSyncedAudio = true
        rig.state.transcriptionModel = "whisper/base"
        rig.state.installedModels.formUnion(["whisper/base"])
        let id = try await processed(rig, "Elsewhere", frequency: 380)
        studioMac(rig)
        let offer = try XCTUnwrap(try offer(rig, id))
        XCTAssertEqual(offer.line, "Upgrade transcript on Studio Mac")
        rig.state.acceptUpgrade(offer, for: id)
        let request = try XCTUnwrap(rig.meeting(id)?.openProcessingRequests.first)
        XCTAssertEqual(request.mode, .fullRetranscription)
        XCTAssertEqual(request.upgrade?.device, studio)
        XCTAssertEqual(request.upgrade?.model, "parakeet/ultra")
        // This Mac's Whisper Base isn't as good: it leaves the request to Studio Mac.
        rig.state.pickUpRequests()
        XCTAssertTrue(rig.state.processingQueue.isEmpty && rig.state.processingID == nil)
        let waiting = try XCTUnwrap(rig.meeting(id))
        guard case .requested(.device(let asked)) = rig.state.processingStatus(for: waiting) else { return XCTFail("Waits for Studio Mac") }
        XCTAssertEqual(asked.upgrade?.waitingLine, "Waiting for Studio Mac to upgrade the transcript")
        XCTAssertNil(rig.state.upgradeOffer(for: waiting), "Nothing more is offered while it waits")
        // Studio Mac never comes; this Mac gets Parakeet Ultra, as good as asked: it carries the upgrade out instead.
        rig.state.transcriptionModel = "parakeet/ultra"
        rig.state.pickUpRequests()
        try await rig.processed(id)
        let upgraded = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(upgraded.processingRequests?.first?.outcome?.result, .completed)
        XCTAssertEqual(upgraded.upgradeCurrent(.transcription)?.model, "parakeet/ultra")
        XCTAssertNil(rig.state.upgradeOffer(for: upgraded))
    }

    func testBehaviorAnUpgradeAnotherDeviceAskedOfThisMacIsCarriedOut() async throws {
        let rig = try await rig()
        rig.state.processSyncedAudio = true
        let id = try await processed(rig, "Asked", frequency: 400)
        madeWith(rig, id, transcription: "parakeet/redux")
        // An iPhone asked this Mac by name.
        let request = ProcessingRequest(meetingID: id, mode: .fullRetranscription, requestedBy: .phone,
                                        upgrade: ProcessingRequest.Upgrade(role: "transcription", model: "parakeet/ultra", quality: 90,
                                                                           device: rig.state.library.thisDevice))
        rig.state.update(id) { $0.upsertProcessingRequest(request) }
        rig.state.pickUpRequests()
        try await rig.processed(id)
        let upgraded = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(upgraded.processingRequests?.first?.outcome?.result, .completed)
        XCTAssertEqual(upgraded.processingRequests?.first?.outcome?.device, rig.state.library.thisDevice)
        XCTAssertEqual(upgraded.upgradeCurrent(.transcription)?.model, "parakeet/ultra")
        // One that asks for better than this Mac has, of another Mac, is left alone.
        let better = ProcessingRequest(meetingID: id, mode: .speakerRefresh, requestedBy: .phone,
                                       upgrade: ProcessingRequest.Upgrade(role: "diarization", model: "nemotron-3-diarization/offline", quality: 89,
                                                                          device: studio))
        rig.state.update(id) { $0.upsertProcessingRequest(better) }
        rig.state.pickUpRequests()
        XCTAssertTrue(rig.state.processingQueue.isEmpty && rig.state.processingID == nil)
        XCTAssertNil(rig.meeting(id)?.processingRequests?.first { $0.id == better.id }?.claim)
    }
}
