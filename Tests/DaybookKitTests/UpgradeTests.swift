import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// "Upgrade" (docs/multipoint.md, "Upgrade"): the ranks in the catalogs, the comparison of a conversation's models with
/// the best within reach, the margins, the weakest recording, unknown provenance, dismissals, the words on each device,
/// and the requests an accepted offer makes. Synthetic conversations; no models.
@MainActor
final class UpgradeTests: XCTestCase {
    private let studio = ProcessingRequest.Device(id: "studio-replica", name: "Studio Mac")
    private let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                    inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: nil, rank: 1)
    private let terra = CloudModel(provider: .openai, id: "gpt-6.1-terra", name: "GPT-6.1 Terra", tier: .economy,
                                   inputPrice: 1, outputPrice: 5, priceIsEstimated: false, contextTokens: nil, rank: 2)

    // MARK: Building conversations

    /// What a device runs: transcripts, speakers, and summaries with these models.
    private func capabilities(transcription: String? = nil, speakers: String? = nil, summary: String? = nil) -> ProcessingCapabilities {
        var models: [String: String] = [:]
        if let transcription { models["transcription"] = transcription }
        if let speakers { models["diarization"] = speakers }
        if let summary { models["summarization"] = summary }
        return ProcessingCapabilities(transcribes: transcription != nil, findsSpeakers: speakers != nil, summarizes: summary != nil, models: models)
    }

    private func mac(_ name: String = "Studio Mac", id: String = "studio-replica", transcription: String? = "parakeet/ultra",
                     speakers: String? = "nemotron-3-diarization/offline", summary: String? = "gemma-4/26b-a4b-qat-4bit") -> ProcessingMac {
        ProcessingMac(id: id, name: name, capabilities: capabilities(transcription: transcription, speakers: speakers, summary: summary))
    }

    /// A processed conversation: one recording per transcription model (each with its language), its speakers found
    /// with `speakers`, and a summary made with `summary`, placed as a device records it.
    private func conversation(transcription: [String?] = ["parakeet/redux"], languages: [String?]? = nil,
                              speakers: String? = "nemotron-3-diarization/compact", summary: String? = "gemma-4/e2b-4bit") -> Meeting {
        var meeting = Meeting(title: "Weekly", status: .ready)
        for (index, model) in transcription.enumerated() {
            let track = RecordingTrack(source: .microphone, relativePath: "Originals/\(index).m4a", fileName: "\(index).m4a", sha256: "\(index)")
            meeting.tracks.append(track)
            let run = UUID()
            meeting.transcripts.append(TrackTranscript(id: run, trackID: track.id,
                segments: [TranscriptSegment(trackID: track.id, start: 0, end: 2, text: "We ship on Friday.", speakerID: "\(run.uuidString):S1")],
                language: languages?[index] ?? "en", modelID: model ?? "",
                processingSettings: model.map { ProcessingSettings(modelID: $0) }))
            if let speakers {
                meeting.speakers.append(Speaker(id: "\(run.uuidString):S1", name: "", sourceTrackID: track.id,
                                                analysisSettings: ProcessingSettings(modelID: speakers)))
            }
            meeting.unifiedTranscript += meeting.transcripts.last!.segments
        }
        if let summary {
            let made = MeetingSummary(overview: "We ship on Friday.", modelID: summary, processingSettings: ProcessingSettings(modelID: summary))
            let place: SummaryPlace = UpgradeRanks.isCloud(summary) ? .cloud(sonnet) : .thisDevice
            meeting.summary = made.placed(place, by: ProcessingRequest.Device(id: "phone", name: "Vlad's iPhone"), inputs: meeting.modelsBehindTranscript)
        }
        return meeting
    }

    private func offer(_ meeting: Meeting, status: ProcessingStatus = .done, here: ProcessingCapabilities = .none,
                       ownRecordings: Bool = true, macs: [ProcessingMac] = [], cloud: CloudModel? = nil) -> UpgradeOffer? {
        Upgrades.offer(for: meeting, status: status, candidates: UpgradeCandidates(thisDevice: here, redoesRecordings: { _ in ownRecordings },
                                                                                 macs: macs, cloud: cloud))
    }

    // MARK: Ranks

    func testBehaviorEveryModelRanksEachStepItServesFromTheCatalog() throws {
        let catalog = ModelCatalog.builtIn
        let ranks = UpgradeRanks.builtIn
        XCTAssertTrue(catalog.warnings.isEmpty, "\(catalog.warnings)")
        // Every model that makes a transcript, speakers, voice profiles, or a summary is ranked for it.
        for model in catalog.models {
            for role in [ModelRole.transcription, .diarization, .speakerEmbedding, .summarization] where model.serves(role) {
                let quality = try XCTUnwrap(model.quality(for: role), "\(model.key) is ranked for \(role)")
                XCTAssertTrue((0...100).contains(quality))
            }
        }
        XCTAssertEqual(ranks.quality(of: "parakeet/ultra", for: .transcription), 90)
        XCTAssertEqual(ranks.quality(of: "parakeet/redux", for: .transcription), 80)
        XCTAssertEqual(ranks.quality(of: "whisper/large-v3-turbo", for: .transcription), 85)
        XCTAssertEqual(ranks.quality(of: "whisper-base", for: .transcription), 60, "A legacy ID reads as its variant")
        XCTAssertEqual(ranks.quality(of: "nemotron-3-diarization/offline", for: .diarization), 89)
        XCTAssertEqual(ranks.quality(of: "sortformer-2.1/fp16", for: .diarization), 79)
        XCTAssertEqual(ranks.quality(of: "community-1/offline", for: .diarization), 85)
        // Summaries share the cloud catalog's scale: the measured local ones match docs/cloud.md's table.
        XCTAssertEqual(ranks.quality(of: "gemma-4/26b-a4b-qat-4bit", for: .summarization), 90)
        XCTAssertEqual(ranks.quality(of: "gemma-4/e4b-4bit", for: .summarization), 53)
        XCTAssertEqual(ranks.quality(of: "anthropic/claude-sonnet-5-5", for: .summarization), 94)
        XCTAssertEqual(ranks.quality(of: "openai/gpt-6.1-terra", for: .summarization), 95)
        XCTAssertEqual(ranks.quality(of: "qwen2.5/1.5b-4bit", for: .summarization), 10, "A model retired from summaries keeps its rank for what it made")
        // A newer version of a measured family, or a dated snapshot, reads as the version measured; Luna was never measured.
        XCTAssertEqual(ranks.quality(of: "anthropic/claude-sonnet-6", for: .summarization), 94)
        XCTAssertEqual(ranks.quality(of: "anthropic/claude-sonnet-5-5-20261001", for: .summarization), 94)
        XCTAssertNil(ranks.quality(of: "openai/gpt-6-luna", for: .summarization))
        // Unknown, or a step the model doesn't do.
        XCTAssertNil(ranks.quality(of: "someone/their-model", for: .transcription))
        XCTAssertNil(ranks.quality(of: "parakeet/ultra", for: .summarization))
    }

    func testBehaviorRanksAreReadFromTheManifestAndSkippedWhenOutOfRange() throws {
        let json = """
            {"schemaVersion": 1, "minimumReaderVersion": 1, "families": [{"id": "x", "name": "X", "engine": "parakeet",
             "roles": ["transcription"], "variants": [{"id": "a", "name": "A", "quality": {"transcription": 77, "diarization": 140}, "revisions": []}]}]}
            """
        let manifest = try ModelManifestReader.read(Data(json.utf8)).manifest
        let model = try XCTUnwrap(ModelCatalog(builtIn: manifest).model("x/a"))
        XCTAssertEqual(model.quality(for: .transcription), 77)
        XCTAssertNil(model.quality(for: .diarization), "Outside 0–100 is dropped")
        let again = try ModelManifestReader.read(ModelManifestReader.encode(manifest)).manifest
        XCTAssertEqual(again, manifest, "Ranks round-trip")
    }

    // MARK: The comparison and its margins

    func testBehaviorAClearlyBetterTranscriptionModelOnAMacIsOffered() throws {
        let meeting = conversation(transcription: ["parakeet/redux"])
        let offer = try XCTUnwrap(offer(meeting, macs: [mac()]))
        XCTAssertEqual(offer.role, .transcription)
        XCTAssertEqual(offer.place, .mac(studio))
        XCTAssertEqual(offer.model, "parakeet/ultra")
        XCTAssertEqual(offer.current, "parakeet/redux")
        XCTAssertEqual(offer.line, "Upgrade transcript on Studio Mac")
    }

    func testBehaviorEachStepsMarginDecidesWhatIsClearlyBetter() {
        // Transcripts: Redux (80) to Ultra (90) clears 10; Whisper Large v3 Turbo (85) to Ultra doesn't.
        XCTAssertEqual(Upgrades.offer(.transcription, for: conversation(transcription: ["parakeet/redux"]),
                                      candidates: UpgradeCandidates(thisDevice: .none, macs: [mac()]))?.model, "parakeet/ultra")
        XCTAssertNil(Upgrades.offer(.transcription, for: conversation(transcription: ["whisper/large-v3-turbo"]),
                                    candidates: UpgradeCandidates(thisDevice: .none, macs: [mac()])))
        // Speakers: Sortformer (79) to Nemotron 3 (89) clears 10; Community-1 (85) to Nemotron 3 doesn't.
        XCTAssertEqual(Upgrades.offer(.diarization, for: conversation(speakers: "sortformer-2.1/fp16"),
                                      candidates: UpgradeCandidates(thisDevice: .none, macs: [mac()]))?.model, "nemotron-3-diarization/offline")
        XCTAssertNil(Upgrades.offer(.diarization, for: conversation(speakers: "community-1/offline"),
                                    candidates: UpgradeCandidates(thisDevice: .none, macs: [mac()])))
        // Summaries: E4B (53) to 26B A4B (90) clears 10; 26B A4B to the cloud's best (95) doesn't, nor Qwen 3.6 (87).
        XCTAssertEqual(Upgrades.offer(.summarization, for: conversation(summary: "gemma-4/e4b-4bit"),
                                      candidates: UpgradeCandidates(thisDevice: .none, macs: [mac()]))?.model, "gemma-4/26b-a4b-qat-4bit")
        XCTAssertNil(Upgrades.offer(.summarization, for: conversation(summary: "gemma-4/26b-a4b-qat-4bit"),
                                    candidates: UpgradeCandidates(thisDevice: .none, cloud: terra)))
        XCTAssertNil(Upgrades.offer(.summarization, for: conversation(summary: "qwen3.6/35b-a3b-4bit"),
                                    candidates: UpgradeCandidates(thisDevice: .none, cloud: terra)))
        XCTAssertEqual(Upgrades.offer(.summarization, for: conversation(summary: "gemma-4/12b-4bit"),
                                      candidates: UpgradeCandidates(thisDevice: .none, cloud: terra))?.model, "openai/gpt-6.1-terra")
    }

    func testBehaviorTheBestWithinReachWinsAndATieStaysNearest() throws {
        let meeting = conversation(transcription: ["parakeet/ultra"], speakers: "nemotron-3-diarization/offline", summary: "gemma-4/e4b-4bit")
        // The cloud (94) beats a Mac's 26B (90) for the summary.
        let cloud = try XCTUnwrap(offer(meeting, macs: [mac()], cloud: sonnet))
        XCTAssertEqual(cloud.place, .cloud(sonnet))
        XCTAssertEqual(cloud.model, "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(cloud.line, "Upgrade summary with Claude Sonnet 5.5")
        // This device and a Mac with the same model: this device.
        let here = try XCTUnwrap(offer(meeting, here: capabilities(summary: "gemma-4/26b-a4b-qat-4bit"), macs: [mac()]))
        XCTAssertEqual(here.place, .thisDevice)
        XCTAssertEqual(here.line, "Upgrade summary")
        // Two Macs: the better one.
        let laptop = mac("Vlad's MacBook Pro", id: "laptop", summary: "gemma-4/12b-4bit")
        XCTAssertEqual(offer(meeting, macs: [laptop, mac()])?.place, .mac(studio))
    }

    func testBehaviorTheWeakestRecordingsModelCounts() throws {
        // The Mac's microphone with Ultra and the iPhone's recording with Redux: the transcript is as good as Redux's.
        let mixed = conversation(transcription: ["parakeet/ultra", "parakeet/redux"])
        XCTAssertEqual(mixed.upgradeCurrent(.transcription)?.model, "parakeet/redux")
        XCTAssertEqual(offer(mixed, macs: [mac()])?.role, .transcription)
        // Both with Ultra: nothing to offer for the transcript.
        let both = conversation(transcription: ["parakeet/ultra", "parakeet/ultra"], speakers: "nemotron-3-diarization/offline",
                                summary: "gemma-4/26b-a4b-qat-4bit")
        XCTAssertNil(offer(both, macs: [mac()]))
    }

    func testBehaviorUnknownProvenanceOffersNothing() {
        // A recording with no recorded model, or one the catalogs don't rank: nothing for that step, the rest as usual.
        let unknown = conversation(transcription: ["parakeet/redux", nil])
        XCTAssertNil(unknown.upgradeCurrent(.transcription))
        XCTAssertNil(Upgrades.offer(.transcription, for: unknown, candidates: UpgradeCandidates(thisDevice: .none, macs: [mac()])))
        let added = conversation(transcription: ["someone/their-model"])
        XCTAssertNil(Upgrades.offer(.transcription, for: added, candidates: UpgradeCandidates(thisDevice: .none, macs: [mac()])))
        // No speaker runs (speakers off) and no summary: nothing to compare.
        XCTAssertNil(conversation(speakers: nil).upgradeCurrent(.diarization))
        XCTAssertNil(conversation(summary: nil).upgradeCurrent(.summarization))
        // A Mac from an earlier Daybook names no models: it offers nothing.
        let earlier = SummarizingMac.Connected(id: UUID(), name: "Old Mac", capabilities: ProcessingCapabilities(transcribes: true,
                                               findsSpeakers: true, summarizes: true), canProcess: true)
        XCTAssertTrue(ProcessingMac.reachable(connected: [earlier], presence: []).isEmpty)
    }

    func testBehaviorWorkUnderWayOrWaitingOffersNothing() {
        let meeting = conversation(transcription: ["parakeet/redux"])
        XCTAssertNotNil(offer(meeting, macs: [mac()]))
        let request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: studio)
        for status: ProcessingStatus in [.processing(.init(stage: .transcribing, fraction: 0.4)), .requested(.queued(position: 0, after: nil)),
                                         .requested(.device(request)), .transcribed, .recorded,
                                         .awaitingRecordings([AwaitedRecording(deviceName: "iPhone", deviceKind: "daybook.iphone", since: Date())])] {
            XCTAssertNil(offer(meeting, status: status, macs: [mac()]), "\(status)")
        }
    }

    func testBehaviorASummaryAnotherDeviceHoldsIsWorkUnderWay() throws {
        // An iPhone holds the summary while it counts down (a claimed Summarize request): every device reads it as work.
        var meeting = conversation(transcription: ["parakeet/redux"])
        var held = ProcessingRequest(meetingID: meeting.id, mode: .summaryOnly, requestedBy: ProcessingRequest.Device(id: "phone", name: "Vlad's iPhone"))
        held = try XCTUnwrap(held.claimed(by: held.requestedBy, at: Date()))
        meeting.upsertProcessingRequest(held)
        XCTAssertNil(offer(meeting, status: ProcessingStatus(meeting), macs: [mac()]))
    }

    func testBehaviorTheMostUpstreamStepIsOfferedSinceItRedoesTheRest() throws {
        let meeting = conversation(transcription: ["parakeet/redux"], speakers: "sortformer-2.1/fp16", summary: "gemma-4/e2b-4bit")
        XCTAssertEqual(offer(meeting, macs: [mac()], cloud: sonnet)?.role, .transcription)
        // Speakers next, then the summary, as each is already as good as can be.
        let speakers = conversation(transcription: ["parakeet/ultra"], speakers: "sortformer-2.1/fp16", summary: "gemma-4/e2b-4bit")
        XCTAssertEqual(offer(speakers, macs: [mac()], cloud: sonnet)?.role, .diarization)
        XCTAssertEqual(offer(speakers, macs: [mac()], cloud: sonnet)?.line, "Upgrade speakers on Studio Mac")
    }

    func testBehaviorAniPhoneRedoesOnlyItsOwnRecordingsAndSaysWhereTheBetterModelIs() throws {
        let meeting = conversation(transcription: ["parakeet/redux"])
        let iPhone = capabilities(transcription: "parakeet/ultra", speakers: "nemotron-3-diarization/offline")
        // Its own recording, and its own model is better: it does it.
        XCTAssertEqual(offer(meeting, here: iPhone, ownRecordings: true)?.line, "Upgrade transcript")
        // A Mac's recording: the iPhone can't redo it; Vlad's MacBook Pro can.
        let laptop = mac("Vlad's MacBook Pro", id: "laptop")
        XCTAssertEqual(offer(meeting, here: iPhone, ownRecordings: false, macs: [laptop])?.line, "Upgrade transcript on Vlad's MacBook Pro")
        // On that Mac, the same conversation reads "Upgrade transcript".
        XCTAssertEqual(offer(meeting, here: laptop.capabilities)?.line, "Upgrade transcript")
    }

    func testBehaviorATranscriptStaysWithAModelThatKnowsItsLanguage() {
        // Whisper wrote it because Parakeet doesn't cover Japanese: Parakeet isn't offered for it.
        let japanese = conversation(transcription: ["whisper/small"], languages: ["ja"])
        XCTAssertNil(Upgrades.offer(.transcription, for: japanese, candidates: UpgradeCandidates(thisDevice: .none, macs: [mac()])))
        // Whisper Large v3 Turbo covers it.
        let turbo = mac(transcription: "whisper/large-v3-turbo")
        XCTAssertEqual(Upgrades.offer(.transcription, for: japanese, candidates: UpgradeCandidates(thisDevice: .none, macs: [turbo]))?.model,
                       "whisper/large-v3-turbo")
    }

    // MARK: Dismissals

    func testBehaviorADismissedOfferStaysGoneUntilABetterModelArrives() throws {
        var meeting = conversation(transcription: ["parakeet/ultra"], speakers: "nemotron-3-diarization/offline", summary: "gemma-4/e2b-4bit")
        let laptop = mac("Vlad's MacBook Pro", id: "laptop", summary: "gemma-4/12b-4bit")
        let first = try XCTUnwrap(offer(meeting, macs: [laptop]))
        XCTAssertEqual(first.model, "gemma-4/12b-4bit")
        meeting.dismissUpgrade(role: first.role.rawValue, model: first.model, quality: first.quality)
        XCTAssertNil(offer(meeting, macs: [laptop]), "Dismissed")
        // A model no better (another Mac with the same 12B) stays dismissed too.
        XCTAssertNil(offer(meeting, macs: [mac("Other Mac", id: "other", summary: "gemma-4/12b-4bit")]))
        // A later, better one offers again.
        XCTAssertEqual(offer(meeting, macs: [laptop, mac()])?.model, "gemma-4/26b-a4b-qat-4bit")
        // Dismissing transcription's offer leaves the next step's.
        var transcript = conversation(transcription: ["parakeet/redux"], summary: "gemma-4/e4b-4bit")
        let upstream = try XCTUnwrap(offer(transcript, macs: [mac()]))
        transcript.dismissUpgrade(role: upstream.role.rawValue, model: upstream.model, quality: upstream.quality)
        XCTAssertEqual(offer(transcript, macs: [mac()])?.role, .summarization)
    }

    func testBehaviorDismissalsSyncAndTwoDevicesDismissingAtOnceAgree() throws {
        let base = conversation(summary: "gemma-4/e4b-4bit")
        var mac = base, phone = base
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        mac.dismissUpgrade(role: "summarization", model: "gemma-4/26b-a4b-qat-4bit", quality: 90, at: late)
        phone.dismissUpgrade(role: "summarization", model: "gemma-4/26b-a4b-qat-4bit", quality: 90, at: early)
        phone.dismissUpgrade(role: "transcription", model: "parakeet/ultra", quality: 90, at: late)
        let one = MeetingMerge.merge(base: base, local: mac, remote: phone)
        let other = MeetingMerge.merge(base: base, local: phone, remote: mac)
        XCTAssertEqual(one.meeting.upgradeDismissals, other.meeting.upgradeDismissals, "Either order, the same")
        XCTAssertTrue(one.warnings.isEmpty, "Never a conflict")
        XCTAssertEqual(one.meeting.upgradeDismissals?.map(\.id), ["summarization|gemma-4/26b-a4b-qat-4bit", "transcription|parakeet/ultra"])
        XCTAssertEqual(one.meeting.upgradeDismissals?.first?.dismissedAt, early, "The earlier dismissal of the same offer")
        XCTAssertFalse(one.meeting.revisions.contains { $0.field.hasPrefix("sync:") }, "Nothing kept in Version History")
        // Without a common ancestor (two devices made the conversation), the same.
        XCTAssertEqual(MeetingMerge.merge(base: nil, local: mac, remote: phone).meeting.upgradeDismissals, one.meeting.upgradeDismissals)
        // Kept through a save and a read.
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(one.meeting))
        XCTAssertEqual(decoded.upgradeDismissals, one.meeting.upgradeDismissals)
        XCTAssertNil(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(base)).upgradeDismissals, "None until the first")
    }

    // MARK: Accepting

    func testBehaviorAcceptingAsksTheDeviceWithTheBetterModel() async throws {
        let library = LibraryController(rootURL: makeTemporaryFolder("DaybookUpgrades"), sync: nil)
        try await library.load()
        let meeting = conversation(transcription: ["parakeet/redux"], speakers: "sortformer-2.1/fp16", summary: "gemma-4/e2b-4bit")
        library.add(meeting)
        let offer = try XCTUnwrap(offer(meeting, macs: [mac()]))
        let request = try XCTUnwrap(library.requestUpgrade(offer, in: meeting.id))
        XCTAssertEqual(request.mode, .fullRetranscription, "A better transcript: Transcribe Everything Again, which redoes the rest")
        XCTAssertEqual(request.upgrade, ProcessingRequest.Upgrade(role: "transcription", model: "parakeet/ultra", quality: 90, device: studio))
        XCTAssertEqual(library.requestUpgrade(offer, in: meeting.id)?.id, request.id, "Asked once")
        // The device named may carry it out, and so may one with a model at least as good; a weaker one may not.
        let upgrade = try XCTUnwrap(request.upgrade)
        XCTAssertTrue(upgrade.mayBeCarriedOut(by: studio, models: nil))
        XCTAssertTrue(upgrade.mayBeCarriedOut(by: ProcessingRequest.Device(id: "other", name: "Other Mac"), models: ["transcription": "parakeet/ultra"]))
        XCTAssertFalse(upgrade.mayBeCarriedOut(by: ProcessingRequest.Device(id: "old", name: "Old Mac"), models: ["transcription": "whisper/small"]))
        XCTAssertEqual(upgrade.waitingLine, "Waiting for Studio Mac to upgrade the transcript")
        // While it waits, nothing more is offered.
        let waiting = try XCTUnwrap(library.meeting(meeting.id))
        XCTAssertNil(self.offer(waiting, status: ProcessingStatus(waiting), macs: [mac()]))
        // Speakers: Identify Speakers Again; a summary on a Mac: Summarize Again; the cloud's isn't a request.
        XCTAssertEqual(UpgradeRole.diarization.mode, .speakerRefresh)
        XCTAssertEqual(UpgradeRole.summarization.mode, .summaryOnly)
        let cloud = UpgradeOffer(role: .summarization, place: .cloud(sonnet), model: "anthropic/claude-sonnet-5-5", quality: 94,
                                 current: "gemma-4/e2b-4bit", currentQuality: 25)
        XCTAssertNil(library.requestUpgrade(cloud, in: meeting.id))
        // This device's own: named as this device.
        let here = UpgradeOffer(role: .diarization, place: .thisDevice, model: "nemotron-3-diarization/offline", quality: 89,
                                current: "sortformer-2.1/fp16", currentQuality: 79)
        XCTAssertEqual(here.request(by: library.thisDevice).device, library.thisDevice)
    }

    func testBehaviorAniPhoneLeavesAnUpgradeItAskedOfAMacToTheMac() {
        let phone = ProcessingRequest.Device(id: "phone", name: "Vlad's iPhone")
        var meeting = conversation(transcription: ["parakeet/redux"])
        let device = OnDeviceProcessing.Device(identity: phone, capabilities: capabilities(transcription: "parakeet/ultra",
                                               speakers: "nemotron-3-diarization/offline"), owns: { _ in true })
        let ofTheMac = ProcessingRequest(meetingID: meeting.id, mode: .fullRetranscription, requestedBy: phone,
                                         upgrade: ProcessingRequest.Upgrade(role: "transcription", model: "parakeet/ultra", quality: 90, device: studio))
        let ofItself = ProcessingRequest(meetingID: meeting.id, mode: .fullRetranscription, requestedBy: phone,
                                         upgrade: ProcessingRequest.Upgrade(role: "transcription", model: "parakeet/ultra", quality: 90, device: phone))
        meeting.upsertProcessingRequest(ofTheMac)
        meeting.upsertProcessingRequest(ofItself)
        XCTAssertNil(OnDeviceProcessing.work(for: ofTheMac, in: meeting, device: device), "The Mac's to carry out")
        XCTAssertEqual(OnDeviceProcessing.work(for: ofItself, in: meeting, device: device), .transcribe(meeting.tracks.map(\.id)))
    }

    func testBehaviorAFinishedUpgradeNeverOffersTheSameAgain() throws {
        var meeting = conversation(transcription: ["parakeet/redux"], speakers: "nemotron-3-diarization/offline", summary: "gemma-4/26b-a4b-qat-4bit")
        let offer = try XCTUnwrap(offer(meeting, macs: [mac()]))
        XCTAssertEqual(offer.role, .transcription)
        // The Mac transcribed everything again with Ultra: its provenance is the offered model.
        let run = UUID(), track = meeting.tracks[0]
        meeting.transcripts.append(TrackTranscript(id: run, trackID: track.id, segments: [], language: "en", modelID: "parakeet/ultra",
                                                   createdAt: Date().addingTimeInterval(60), processingSettings: ProcessingSettings(modelID: "parakeet/ultra")))
        meeting.speakers.append(Speaker(id: "\(run.uuidString):S1", name: "", sourceTrackID: track.id,
                                        analysisSettings: ProcessingSettings(modelID: "nemotron-3-diarization/offline")))
        XCTAssertNil(self.offer(meeting, macs: [mac()]), "Nothing left to offer, here or anywhere")
    }

    func testBehaviorReachableMacsNameTheirModels() {
        let now = Date()
        var studio = KnownSyncDevice(id: "studio-replica", deviceClass: .mac, displayName: "Studio Mac", canProcess: true, lastSeen: now.addingTimeInterval(-60))
        studio.capabilities = SyncDeviceCapabilities(transcribes: true, findsSpeakers: true, summarizes: true, models: ["transcription": "parakeet/ultra"])
        var asleep = KnownSyncDevice(id: "asleep", deviceClass: .mac, displayName: "Asleep", canProcess: true, lastSeen: now.addingTimeInterval(-3_600))
        asleep.capabilities = studio.capabilities
        let connected = SummarizingMac.Connected(id: UUID(), syncDeviceID: "laptop", name: "Vlad's MacBook Pro",
                                                 capabilities: capabilities(transcription: "parakeet/ultra"), canProcess: true)
        let reachable = ProcessingMac.reachable(connected: [connected], presence: [studio, asleep], now: now)
        XCTAssertEqual(reachable.map(\.name), ["Vlad's MacBook Pro", "Studio Mac"], "Connected first; one asleep for an hour isn't reachable")
        XCTAssertEqual(reachable.last?.capabilities.models?["transcription"], "parakeet/ultra")
    }
}
