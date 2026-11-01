import DaybookCore
import DaybookKit
import DaybookLink
import Foundation
import XCTest
@testable import DaybookPhone

/// "Upgrade" on the iPhone (docs/multipoint.md, "Upgrade"): the page's line in the iPhone's words, a Mac's better model
/// asked by name, this iPhone's own recordings redone by its processor with the summary counting down after, the cloud's
/// better summary started at once, and Dismiss. A temporary library, the processing fakes, presence records, and a
/// loopback link; no network, no models.
@MainActor
final class PhoneUpgradeTests: XCTestCase {
    private let studio = ProcessingRequest.Device(id: "studio-replica", name: "Vlad's MacBook Pro")

    @MainActor private struct Rig {
        let library: PhoneLibrary
        let processor: PhoneProcessor
        let placement: PhoneSummaryPlacement
        let upgrades: PhoneUpgrades
        let engine: PhoneProcessingTests.ScriptedEngine
        let summarizer: PhoneProcessingTests.ScriptedSummarizer
        let presence: PhoneSummaryPlacementTests.PresenceBox
        let clock: PhoneSummaryPlacementTests.ClockBox
        var controller: LibraryController { library.controller }
    }

    /// A library with this iPhone's processor (Parakeet Ultra and Nemotron 3, and a summary model) and its summary
    /// placement and upgrades wired as the app wires them, with an Anthropic key (`cloud`) or none.
    private func rig(cloud: PhoneSummaryPlacementTests.Cloud? = nil) async throws -> Rig {
        let library = PhoneLibrary(rootURL: try temporaryDirectory().appendingPathComponent("library"), installation: "INSTALL-1")
        try await library.reload()
        let engine = PhoneProcessingTests.ScriptedEngine(), summarizer = PhoneProcessingTests.ScriptedSummarizer()
        let capabilities = ProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: true,
                                                  models: ["transcription": "parakeet/ultra", "diarization": "nemotron-3-diarization/offline",
                                                           "summarization": "gemma-4/e4b-4bit"])
        let processor = PhoneProcessor(library: library.controller, services: PhoneProcessor.Services(
            engine: { engine }, summarizer: { summarizer }, capabilities: { capabilities },
            owns: { [weak library] in library?.ownsTrack ?? { _ in false } },
            audio: { [weak library] track, id in
                guard let library else { throw CancellationError() }
                return try await library.audioURL(for: track, in: id)
            },
            release: {}), continued: ContinuedProcessing(scheduler: nil))
        library.processesHere = { [weak processor] in processor?.device }
        let previous = PhoneProcessor.current
        PhoneProcessor.current = processor
        addTeardownBlock { @MainActor in PhoneProcessor.current = previous }
        let clock = PhoneSummaryPlacementTests.ClockBox(), presence = PhoneSummaryPlacementTests.PresenceBox()
        clock.now = Date()
        let link = PhoneLink(identity: PhoneLink.identity(installation: UUID().uuidString, name: "Test iPhone", libraryID: nil),
                             keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        let placement = PhoneSummaryPlacement(library: library.controller, link: link, presence: { presence.devices }, clock: { clock.now },
                                              runsTimer: false)
        placement.cloud = CloudSetup.demo(providers: cloud == nil ? [] : [.anthropic], defaults: makeTestDefaults("PhoneUpgradeTests"))
        if let cloud { placement.cloudSummarizer = cloud }
        placement.runHere = { [weak processor] id, request in processor?.summarizeHere(id, request: request) }
        placement.localSummarizer = summarizer
        processor.services.summaryDue = { [weak placement] id, templateID, askedFor in
            guard let placement else { return }
            if askedFor { placement.summarize(id, templateID: templateID) }
            else { Task { await placement.summaryIsDue(id, templateID: templateID) } }
        }
        let upgrades = PhoneUpgrades(library: library.controller, placement: placement, link: link, presence: { presence.devices },
                                     clock: { clock.now })
        upgrades.capabilities = { capabilities }
        upgrades.owns = { [weak library] in library?.ownsTrack ?? { _ in false } }
        upgrades.pickUp = { [weak processor] in processor?.pickUp() }
        return Rig(library: library, processor: processor, placement: placement, upgrades: upgrades, engine: engine, summarizer: summarizer,
                   presence: presence, clock: clock)
    }

    /// A conversation recorded on this iPhone and processed here, summary and all.
    private func processed(_ rig: Rig, title: String = "Beta planning") async throws -> UUID {
        let recorder = RecorderRig()
        let id = UUID()
        try await recorder.recorder.start(in: rig.library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: title)
        recorder.pump(3)
        let meeting = try await rig.library.fileRecording(try await recorder.stop()).meeting
        rig.processor.pickUp()
        try await waitUntil("processed here") { rig.controller.meeting(meeting.id)?.summary != nil && rig.processor.running == nil }
        // The placement's clock catches up with the work's.
        rig.clock.now = Date().addingTimeInterval(1)
        return meeting.id
    }

    /// As if other models had made the transcript (each run, with its speakers) or the summary.
    private func madeWith(_ rig: Rig, _ id: UUID, transcription: String? = nil, speakers: String? = nil, summary: String? = nil) {
        rig.controller.update(id) { meeting in
            for index in meeting.transcripts.indices {
                if let transcription {
                    meeting.transcripts[index].modelID = transcription
                    meeting.transcripts[index].processingSettings = ProcessingSettings(modelID: transcription)
                }
            }
            if let speakers {
                for index in meeting.speakers.indices { meeting.speakers[index].analysisSettings = ProcessingSettings(modelID: speakers) }
            }
            if let summary, var made = meeting.summary {
                made.modelID = summary
                made.processingSettings = ProcessingSettings(modelID: summary)
                meeting.summary = made.placed(.thisDevice, by: rig.controller.thisDevice, inputs: meeting.modelsBehindTranscript)
            }
        }
    }

    /// Vlad's MacBook Pro in the library's presence records, seen a minute ago, with the Mac's best models.
    private func macSeen(_ rig: Rig) {
        var device = KnownSyncDevice(id: studio.id, deviceClass: .mac, displayName: studio.name, canProcess: true, lastSeen: rig.clock.now.addingTimeInterval(-60))
        device.capabilities = SyncDeviceCapabilities(transcribes: true, findsSpeakers: true, summarizes: true,
                                                     models: ["transcription": "parakeet/ultra", "diarization": "nemotron-3-diarization/offline",
                                                              "summarization": "gemma-4/26b-a4b-qat-4bit"])
        rig.presence.devices = [device]
    }

    private func offer(_ rig: Rig, _ id: UUID) throws -> UpgradeOffer? {
        rig.upgrades.offer(for: try XCTUnwrap(rig.controller.meeting(id)), now: rig.clock.now)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Tests

    func testBehaviorAMacsBetterModelIsOfferedInTheIPhonesWordsAndAskedByName() async throws {
        let rig = try await rig()
        let id = try await processed(rig)
        madeWith(rig, id, speakers: "nemotron-3-diarization/offline", summary: "gemma-4/12b-4bit")
        XCTAssertNil(try offer(rig, id), "No Mac: this iPhone's E4B isn't better than a 12B summary")
        macSeen(rig)
        let offer = try XCTUnwrap(try offer(rig, id))
        XCTAssertEqual(offer.line, "Upgrade summary on Vlad's MacBook Pro")
        // The page's line, with Upgrade and Dismiss.
        let line = StatusPresentation.upgrade(offer)
        XCTAssertEqual(line.kind, .line)
        XCTAssertEqual(line.title, "Upgrade summary on Vlad's MacBook Pro")
        XCTAssertEqual(line.actions, [.upgrade(offer), .dismissUpgrade(offer)])
        await rig.upgrades.accept(offer, for: id)
        let asked = try XCTUnwrap(rig.controller.meeting(id)?.openProcessingRequests.first { $0.upgrade != nil })
        XCTAssertEqual(asked.mode, .summaryOnly)
        XCTAssertEqual(asked.upgrade?.device, studio, "Named: the Mac with the better model")
        XCTAssertNil(asked.claim, "Left for the Mac")
        XCTAssertNil(rig.placement.planners[id], "Nothing counts down here for it")
        rig.processor.pickUp()
        XCTAssertNil(rig.processor.running, "This iPhone never runs what it asked of a Mac")
        // The page says what it waits for, and offers nothing more meanwhile.
        let waiting = try XCTUnwrap(rig.controller.meeting(id))
        let status = ProcessingStatus.phone(waiting)
        XCTAssertEqual(StatusPresentation.page(status, meeting: waiting, sighting: nil)?.title, "Waiting for Vlad's MacBook Pro to upgrade the summary")
        XCTAssertEqual(StatusPresentation.row(status, meeting: waiting)?.text, "Waiting for Vlad's MacBook Pro to upgrade the summary")
        XCTAssertNil(StatusPresentation.placement(nil, run: nil, live: nil, status: status, cloudOffered: true), "Not Use the Cloud's line")
        XCTAssertNil(try self.offer(rig, id))
    }

    func testBehaviorThisIPhonesOwnRecordingIsRedoneHereAndItsSummaryCountsDown() async throws {
        let rig = try await rig(cloud: PhoneSummaryPlacementTests.Cloud(models: []))
        let id = try await waitingCountdownProcessed(rig)
        madeWith(rig, id, transcription: "parakeet/redux", speakers: "nemotron-3-diarization/offline")
        macSeen(rig)
        let offer = try XCTUnwrap(try offer(rig, id))
        XCTAssertEqual(offer.line, "Upgrade transcript", "Its own recording, and its own model is as good as the Mac's: here")
        let transcribed = rig.engine.transcribed.count
        await rig.upgrades.accept(offer, for: id)
        let asked = try XCTUnwrap(rig.controller.meeting(id)?.processingRequests?.first { $0.upgrade != nil })
        XCTAssertEqual(asked.mode, .fullRetranscription)
        XCTAssertEqual(asked.upgrade?.device, rig.controller.thisDevice)
        // Transcribed again here; the summary after it is due, so it counts down while the cloud is on offer.
        try await waitUntil("the summary's countdown") { rig.placement.planners[id]?.deadline != nil }
        XCTAssertEqual(rig.engine.transcribed.count, transcribed + 1)
        XCTAssertEqual(rig.controller.meeting(id)?.processingRequests?.first { $0.id == asked.id }?.outcome?.result, .completed)
        XCTAssertNil(try self.offer(rig, id), "Nothing offered while it counts down")
        rig.clock.now.addTimeInterval(15)
        rig.placement.placements.advance()
        try await waitUntil("the summary") { rig.summarizer.summarized.filter { $0 == id }.count == 2 }
        try await waitUntil("settled") { rig.processor.running == nil && rig.controller.meeting(id)?.openProcessingRequests.isEmpty == true }
        let done = try XCTUnwrap(rig.controller.meeting(id))
        XCTAssertEqual(done.upgradeCurrent(.transcription)?.model, "parakeet/ultra")
        // Never the same offer again: what's left is the summary, which the cloud does clearly better.
        XCTAssertEqual(try self.offer(rig, id)?.line, "Upgrade summary with Claude Sonnet 5.5")
    }

    func testBehaviorTheCloudsBetterSummaryStartsThereAtOnce() async throws {
        let cloud = PhoneSummaryPlacementTests.Cloud(models: [])
        let rig = try await rig(cloud: cloud)
        let id = try await waitingCountdownProcessed(rig)
        madeWith(rig, id, speakers: "nemotron-3-diarization/offline", summary: "gemma-4/e2b-4bit")
        let offer = try XCTUnwrap(try offer(rig, id))
        XCTAssertEqual(offer.line, "Upgrade summary with Claude Sonnet 5.5")
        await rig.upgrades.accept(offer, for: id)
        try await waitUntil("the cloud's summary") { rig.controller.meeting(id)?.summary?.cloudProvenance != nil }
        XCTAssertEqual(cloud.asked, [id])
        XCTAssertNil(rig.placement.planners[id]?.deadline, "No countdown")
        let done = try XCTUnwrap(rig.controller.meeting(id))
        XCTAssertEqual(done.summary?.modelsByRole["summarization"], "anthropic/claude-sonnet-5-5")
        XCTAssertNil(try self.offer(rig, id))
    }

    func testBehaviorDismissingPutsTheOfferAwayEverywhere() async throws {
        let rig = try await rig()
        let id = try await processed(rig)
        madeWith(rig, id, speakers: "nemotron-3-diarization/offline", summary: "gemma-4/12b-4bit")
        macSeen(rig)
        let offer = try XCTUnwrap(try offer(rig, id))
        rig.upgrades.dismiss(offer, for: id)
        XCTAssertNil(try self.offer(rig, id))
        XCTAssertEqual(rig.controller.meeting(id)?.upgradeDismissals?.map(\.id), ["summarization|gemma-4/26b-a4b-qat-4bit"],
                       "Kept on the conversation, which syncs")
    }

    /// Processed here with a cloud key: the first summary counts down, then runs here.
    private func waitingCountdownProcessed(_ rig: Rig) async throws -> UUID {
        let recorder = RecorderRig()
        let id = UUID()
        try await recorder.recorder.start(in: rig.library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: "Beta planning")
        recorder.pump(3)
        let meeting = try await rig.library.fileRecording(try await recorder.stop()).meeting
        rig.processor.pickUp()
        try await waitUntil("the countdown") { rig.placement.planners[meeting.id]?.deadline != nil }
        rig.clock.now.addTimeInterval(15)
        rig.placement.placements.advance()
        try await waitUntil("processed here") {
            rig.controller.meeting(meeting.id)?.summary != nil && rig.processor.running == nil
                && rig.controller.meeting(meeting.id)?.openProcessingRequests.isEmpty == true
        }
        return meeting.id
    }
}
