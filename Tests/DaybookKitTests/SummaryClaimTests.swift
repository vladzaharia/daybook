import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// One summary per conversation, wherever it runs (docs/multipoint.md, "Where summaries run"): a device claims
/// the summary through a request before it summarizes here or in the cloud, stands down while another device
/// holds one, keeps a summary that arrived from elsewhere while it worked, and records where its summary ran
/// and the models behind it. Also which Macs a summary can go to now.
@MainActor
final class SummaryClaimTests: XCTestCase {
    private var root: URL!
    private let mac = ProcessingRequest.Device(id: "mac-replica", name: "Studio Mac")
    private let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                    inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: nil, rank: 1)

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookSummaryClaims")
    }

    private func open() async throws -> LibraryController {
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        return library
    }

    /// A conversation with a transcript and no summary, as a Mac or this device leaves it.
    private func transcribed(_ library: LibraryController) -> UUID {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", sha256: "a")
        let run = UUID()
        var meeting = Meeting(title: "Planning", tracks: [track], status: .imported)
        meeting.transcripts = [TrackTranscript(id: run, trackID: track.id, segments: [TranscriptSegment(trackID: track.id, start: 0, end: 2,
                                                text: "Ship on Friday.", speakerID: "\(run.uuidString):S1")],
                                               modelID: "parakeet/v3",
                                               processingSettings: ProcessingSettings(modelID: "parakeet/v3"))]
        meeting.speakers = [Speaker(id: "\(run.uuidString):S1", name: "Speaker 1", sourceTrackID: track.id,
                                    analysisSettings: ProcessingSettings(modelID: "community-1/offline"))]
        library.add(meeting)
        return meeting.id
    }

    func testBehaviorClaimingASummaryMakesARequestNoMacTakes() async throws {
        let library = try await open()
        let id = transcribed(library)
        let claimed = try XCTUnwrap(library.claimSummary(id))
        XCTAssertEqual(claimed.mode, .summaryOnly)
        XCTAssertEqual(claimed.requestedBy, library.thisDevice)
        XCTAssertEqual(claimed.claim?.device, library.thisDevice)
        let meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertFalse(try XCTUnwrap(meeting.processingRequests?.first).isClaimable(by: mac, at: Date()), "A Mac leaves it alone")
        XCTAssertEqual(meeting.summaryHolder(excluding: mac.id), library.thisDevice, "and stands down for it")
    }

    func testBehaviorAWaitingSummarizeRequestIsTakenRatherThanASecondMade() async throws {
        let library = try await open()
        let id = transcribed(library)
        let asked = try XCTUnwrap(library.requestProcessing(id, mode: .summaryOnly))
        let claimed = try XCTUnwrap(library.claimSummary(id))
        XCTAssertEqual(claimed.id, asked.id, "Use the Cloud on a request waiting for a Mac takes that request")
        XCTAssertEqual(library.meeting(id)?.processingRequests?.count, 1)
    }

    func testBehaviorAnotherDeviceHoldingItMeansStandingDown() async throws {
        let library = try await open()
        let id = transcribed(library)
        let request = ProcessingRequest(meetingID: id, mode: .newAudio, requestedBy: library.thisDevice)
        library.update(id) { $0.upsertProcessingRequest(request.claimed(by: self.mac, at: Date())!) }
        XCTAssertNil(library.claimSummary(id), "A Mac is working on it, and its work ends with a summary")
        XCTAssertEqual(library.meeting(id)?.summaryHolder(excluding: library.thisDevice.id), mac)
    }

    func testBehaviorASummaryIsAppliedWithWhereItRanUnlessAnotherArrivedFirst() async throws {
        let library = try await open()
        let id = transcribed(library)
        let started = Date()
        let summary = MeetingSummary(title: "Planning", overview: "From the cloud", modelID: sonnet.id)
        XCTAssertTrue(library.applyPlacedSummary(summary, to: id, place: .cloud(sonnet), started: started))
        let applied = try XCTUnwrap(library.meeting(id)?.summary)
        XCTAssertEqual(applied.origin, SummaryOrigin(deviceID: library.thisDevice.id, deviceName: library.thisDevice.name, cloudModel: "Claude Sonnet 5.5"))
        XCTAssertEqual(applied.modelsByRole, ["transcription": "parakeet/v3", "diarization": "community-1/offline",
                                              "summarization": "anthropic/claude-sonnet-5-5"])
        XCTAssertEqual(applied.processingSettings?.parameters["cloudProvider"], "anthropic")
        XCTAssertEqual(applied.processingSettings?.parameters["cloudModel"], "claude-sonnet-5-5", "The provider's model ID, as the cloud writes it")
        XCTAssertEqual(library.meeting(id)?.status, .ready)

        // The Mac's summary lands after this device began another: the Mac's is kept.
        let second = Date()
        let theirs = MeetingSummary(title: "Planning", overview: "From the Mac", modelID: "gemma-4/e4b", createdAt: second.addingTimeInterval(1))
            .placed(.thisDevice, by: mac, inputs: [:])
        library.update(id) { $0.setSummary(theirs) }
        XCTAssertFalse(library.applyPlacedSummary(MeetingSummary(overview: "Mine", modelID: sonnet.id), to: id, place: .cloud(sonnet), started: second))
        XCTAssertEqual(library.meeting(id)?.summary?.overview, "From the Mac")
    }

    func testBehaviorThisDevicesOwnEarlierSummaryIsNoReasonToStop() async throws {
        let library = try await open()
        let id = transcribed(library)
        let started = Date()
        let mine = MeetingSummary(overview: "First", modelID: sonnet.id, createdAt: started.addingTimeInterval(1))
            .placed(.cloud(sonnet), by: library.thisDevice, inputs: [:])
        library.update(id) { $0.setSummary(mine) }
        XCTAssertTrue(library.applyPlacedSummary(MeetingSummary(overview: "Second", modelID: sonnet.id), to: id, place: .cloud(sonnet), started: started))
        XCTAssertEqual(library.meeting(id)?.summary?.overview, "Second")
    }

    func testBehaviorTheColophonSaysWhereItRan() {
        let here = SummaryOrigin(deviceID: "me", deviceName: "Pocket iPhone")
        XCTAssertEqual(here.colophon(thisDeviceID: "me", thisDevice: "this iPhone", unknown: "your Mac"), "Summarized on this iPhone")
        let mac = SummaryOrigin(deviceID: "mac", deviceName: "Vlad’s MacBook Pro")
        XCTAssertEqual(mac.colophon(thisDeviceID: "me", thisDevice: "this iPhone", unknown: "your Mac"), "Summarized on Vlad’s MacBook Pro")
        let cloud = SummaryOrigin(deviceID: "mac", deviceName: "Studio Mac", cloudModel: "Claude Sonnet 5.5")
        XCTAssertEqual(cloud.colophon(thisDeviceID: "me", thisDevice: "this iPhone", unknown: "your Mac"), "Summarized with Claude Sonnet 5.5")
        XCTAssertEqual(SummaryOrigin().colophon(thisDeviceID: "me", thisDevice: "this Mac", unknown: "this Mac"), "Summarized on this Mac",
                       "Summaries from before it was recorded were made on a Mac")
        XCTAssertEqual(MeetingSummary(overview: "Old").origin, SummaryOrigin())
    }

    // MARK: One provenance for a cloud summary

    /// A cloud summary as `CloudSummarizer` writes it: the model's provenance (engine "cloud"), the effort, tokens, cost,
    /// and the device that sent it.
    private func fromTheCloud(sentBy: String? = "Pocket iPhone") -> MeetingSummary {
        let provenance = CloudProvenance(provider: .anthropic, model: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", effort: .high,
                                         inputTokens: 9_800, outputTokens: 2_900, estimatedCost: 0.0486, sentBy: sentBy)
        var summary = MeetingSummary(title: "Planning", overview: "From the cloud", modelID: provenance.modelID)
        var parameters = provenance.parameters
        parameters["templateID"] = "auto"
        summary.processingSettings = ProcessingSettings(modelID: provenance.modelID, parameters: parameters, model: provenance.modelProvenance)
        return summary
    }

    func testBehaviorAPlacedCloudSummaryKeepsTheCloudsProvenanceAndAddsWhereItRan() async throws {
        let library = try await open()
        let id = transcribed(library)
        XCTAssertTrue(library.applyPlacedSummary(fromTheCloud(), to: id, place: .cloud(sonnet), started: Date()))
        let applied = try XCTUnwrap(library.meeting(id)?.summary)
        // The cloud's.
        let cloud = try XCTUnwrap(applied.cloudProvenance)
        XCTAssertEqual(cloud.model, "claude-sonnet-5-5")
        XCTAssertEqual(cloud.effort, .high)
        XCTAssertEqual(cloud.inputTokens, 9_800)
        XCTAssertEqual(cloud.outputTokens, 2_900)
        XCTAssertEqual(cloud.estimatedCost ?? 0, 0.0486, accuracy: 1e-9)
        XCTAssertEqual(cloud.sentBy, "Pocket iPhone", "The cloud's own word for who sent it stays")
        XCTAssertEqual(applied.modelID, "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(applied.processingSettings?.parameters["templateID"], "auto")
        // The placement's.
        XCTAssertEqual(applied.origin, SummaryOrigin(deviceID: library.thisDevice.id, deviceName: library.thisDevice.name, cloudModel: "Claude Sonnet 5.5"))
        XCTAssertEqual(applied.processingSettings?.parameters["place"], "cloud")
        XCTAssertEqual(applied.modelsByRole["summarization"], "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(applied.origin.colophon(thisDeviceID: library.thisDevice.id, thisDevice: "this iPhone", unknown: "your Mac"),
                       "Summarized with Claude Sonnet 5.5")
    }

    func testBehaviorACloudSummaryWithoutTheCloudsProvenanceGetsTheModelItWasSentTo() {
        let device = ProcessingRequest.Device(id: "me", name: "Pocket iPhone")
        let placed = MeetingSummary(overview: "From a stand-in", modelID: "").placed(.cloud(sonnet), by: device, inputs: [:])
        let cloud = placed.cloudProvenance
        XCTAssertEqual(cloud?.provider, .anthropic)
        XCTAssertEqual(cloud?.model, "claude-sonnet-5-5")
        XCTAssertEqual(cloud?.name, "Claude Sonnet 5.5")
        XCTAssertEqual(cloud?.sentBy, "Pocket iPhone")
        XCTAssertNil(cloud?.usage, "Nothing it used is known")
        XCTAssertEqual(placed.modelID, "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(placed.origin.cloudModel, "Claude Sonnet 5.5")
        XCTAssertEqual(placed.processingSettings?.parameters["cloudModel"], "claude-sonnet-5-5")
    }

    func testBehaviorACloudSummaryMadeWithoutThePlacementStillSaysWhichModel() {
        // `--cloud-check`, or a summary written before the placement: no device, but the cloud's provenance.
        let summary = fromTheCloud(sentBy: nil)
        XCTAssertEqual(summary.origin, SummaryOrigin(cloudModel: "Claude Sonnet 5.5"))
        XCTAssertTrue(summary.isFromCloud)
        XCTAssertEqual(summary.origin.colophon(thisDeviceID: "mac", thisDevice: "this Mac", unknown: "this Mac"), "Summarized with Claude Sonnet 5.5")
        XCTAssertEqual(summary.cloudProvenance?.usage, "\(12_700.formatted()) tokens · $0.05")
        var estimated = summary
        estimated.processingSettings?.parameters["priceIsEstimated"] = "true"
        XCTAssertEqual(estimated.cloudProvenance?.usage, "\(12_700.formatted()) tokens · about $0.05")
        // A local summary is no cloud's.
        let local = MeetingSummary(overview: "Here", modelID: "gemma-4/e4b-4bit").placed(.thisDevice, by: mac, inputs: [:])
        XCTAssertNil(local.cloudProvenance)
        XCTAssertNil(local.origin.cloudModel)
        XCTAssertFalse(local.isFromCloud)
    }

    // MARK: Reachable Macs

    func testBehaviorReachableMacsAreConnectedOrRecentlySeenAndSummarize() {
        let now = Date()
        let studio = UUID(), laptop = UUID(), older = UUID(), stale = UUID(), transcriber = UUID()
        let summarizes = ProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: true)
        let connected = [
            SummarizingMac.Connected(id: studio, syncDeviceID: studio.uuidString, name: "Studio Mac", capabilities: summarizes, canProcess: true),
            SummarizingMac.Connected(id: transcriber, name: "Mini", capabilities: ProcessingCapabilities(transcribes: true, findsSpeakers: false,
                                                                                                        summarizes: false), canProcess: false)
        ]
        var presence = [
            KnownSyncDevice(id: studio.uuidString, deviceClass: .mac, displayName: "Studio Mac", canProcess: true, lastSeen: now),
            KnownSyncDevice(id: laptop.uuidString, deviceClass: .mac, displayName: "Vlad’s MacBook Pro", canProcess: false,
                            lastSeen: now.addingTimeInterval(-60)),
            // An earlier Daybook says only that it processes.
            KnownSyncDevice(id: older.uuidString, deviceClass: .mac, displayName: "Old iMac", canProcess: true, lastSeen: now.addingTimeInterval(-120)),
            KnownSyncDevice(id: stale.uuidString, deviceClass: .mac, displayName: "Asleep", canProcess: true, lastSeen: now.addingTimeInterval(-3_600)),
            KnownSyncDevice(id: "phone", deviceClass: .phone, displayName: "iPhone", canProcess: true, lastSeen: now)
        ]
        presence[1].capabilities = SyncDeviceCapabilities(transcribes: false, findsSpeakers: false, summarizes: true)
        let macs = SummarizingMac.reachable(connected: connected, presence: presence, now: now)
        XCTAssertEqual(macs.map(\.name), ["Studio Mac", "Vlad’s MacBook Pro", "Old iMac"],
                       "Connected first, each once; one that doesn't summarize, one long unseen, and the iPhone aren't")
        XCTAssertEqual(macs.first?.id, studio)
        let options = SummaryOptions(thisDeviceCanSummarize: false, macs: macs, cloud: sonnet)
        XCTAssertEqual(options.reachableMacs.map(\.id), [studio, laptop, older])
    }

    func testBehaviorCapabilitiesConvertBetweenTheLinkAndPresence() {
        let capabilities = ProcessingCapabilities(transcribes: true, findsSpeakers: false, summarizes: true, models: ["summarization": "gemma-4/e4b"])
        XCTAssertEqual(ProcessingCapabilities(capabilities.link), capabilities)
        XCTAssertEqual(ProcessingCapabilities(capabilities.presence), capabilities)
        XCTAssertEqual(ProcessingCapabilities.none, ProcessingCapabilities(transcribes: false, findsSpeakers: false, summarizes: false))
    }
}
