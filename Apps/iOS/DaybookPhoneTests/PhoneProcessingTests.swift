import DaybookCore
import DaybookKit
import DaybookLive
import DaybookModelStore
import Foundation
import XCTest
@testable import DaybookPhone

/// Processing this iPhone's own recordings (docs/iphone.md, "Processing on this iPhone"), with the
/// engines' fakes: claimed as it's filed, transcribed, fused, summarized here or handed to a Mac;
/// paused for a recording, heat, Low Power Mode, a low battery, and the screen; going on under the
/// system's continued-processing task, with its progress, until that expires; stopped when another
/// device takes the request; one conversation at a time. Nothing is downloaded.
@MainActor
final class PhoneProcessingTests: XCTestCase {
    /// Transcribes from a script: one passage, one speaker. Can be held mid-recording, as a long one is.
    final class ScriptedEngine: ProcessingEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var _transcribed: [UUID] = []
        private var _running = 0, _mostAtOnce = 0
        private var _holding = false, _waiting = false
        var transcribed: [UUID] { lock.withLock { _transcribed } }
        var mostAtOnce: Int { lock.withLock { _mostAtOnce } }
        var isWaiting: Bool { lock.withLock { _waiting } }
        func hold(_ on: Bool) { lock.withLock { _holding = on } }

        func transcribe(_ input: TrackProcessingInput, progress: @escaping ProcessingProgressHandler) async throws -> TrackProcessingOutput {
            lock.withLock { _running += 1; _mostAtOnce = max(_mostAtOnce, _running) }
            defer { lock.withLock { _running -= 1; _waiting = false } }
            progress(ProcessingProgress(fraction: 0.5, message: "Transcribing"))
            while lock.withLock({ _holding }) {
                lock.withLock { _waiting = true }
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            lock.withLock { _transcribed.append(input.track.id) }
            let run = UUID(), speaker = "\(run.uuidString):0"
            let words = TranscriptSegment(trackID: input.track.id, start: 0, end: 4, text: "Ship the beta on Friday.", speakerID: speaker)
            let transcript = TrackTranscript(id: run, trackID: input.track.id, segments: [words], language: "en", modelID: "parakeet/ultra",
                                             knownOffset: input.track.offset,
                                             processingSettings: ProcessingSettings(modelID: "parakeet/ultra", parameters: ["mode": input.mode.rawValue]))
            return TrackProcessingOutput(transcript: transcript, speakers: [Speaker(id: speaker, name: "", sourceTrackID: input.track.id)],
                                         duration: input.track.duration ?? 6)
        }

        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                       progress: @escaping ProcessingProgressHandler) async throws -> SummaryProcessingOutput {
            XCTFail("Summaries go through the local summarizer")
            throw CancellationError()
        }
    }

    /// The local summarizer seam, scripted.
    final class ScriptedSummarizer: LocalSummarizing, @unchecked Sendable {
        private let lock = NSLock()
        private var _summarized: [UUID] = []
        var summarized: [UUID] { lock.withLock { _summarized } }
        let model = "gemma-4/e4b-4bit"

        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                       progress: @escaping @Sendable (Double) -> Void) async throws -> SummaryProcessingOutput {
            lock.withLock { _summarized.append(meeting.id) }
            progress(0.5)
            var summary = MeetingSummary(title: "Beta on Friday", overview: "The beta ships Friday.", modelID: model)
            summary.processingSettings = ProcessingSettings(modelID: model, parameters: [:])
            return SummaryProcessingOutput(summary: summary, suggestedTerms: ["beta"])
        }
    }

    /// The system's continued-processing scheduler, scripted: it starts each task at once, or refuses.
    final class ScriptedScheduler: ContinuedProcessing.Scheduler {
        var refuses = false
        private(set) var submitted: [String] = []
        private(set) var tasks: [ScriptedTask] = []
        struct Refused: Error {}
        func submit(identifier: String, title: String, subtitle: String, launch: @escaping @MainActor (any ContinuedProcessing.Task) -> Void) throws {
            guard !refuses else { throw Refused() }
            submitted.append(identifier)
            let task = ScriptedTask()
            tasks.append(task)
            Task { @MainActor in launch(task) }
        }
    }

    final class ScriptedTask: ContinuedProcessing.Task {
        let progress = Progress(totalUnitCount: 0)
        var expirationHandler: (() -> Void)?
        private(set) var titles: [String] = []
        private(set) var completed: Bool?
        func update(title: String, subtitle: String) { titles.append(title) }
        func complete(success: Bool) { completed = success }
    }

    private struct Rig {
        let library: PhoneLibrary
        let processor: PhoneProcessor
        let engine: ScriptedEngine
        let summarizer: ScriptedSummarizer
        let scheduler: ScriptedScheduler
    }

    /// A library with a processor that can transcribe (and, with `summarizes`, summarize) here.
    private func rig(summarizes: Bool = true) async throws -> Rig {
        let library = PhoneLibrary(rootURL: try temporaryDirectory().appendingPathComponent("library"), installation: "INSTALL-1")
        try await library.reload()
        let engine = ScriptedEngine(), summarizer = ScriptedSummarizer(), scheduler = ScriptedScheduler()
        let capabilities = ProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: summarizes,
                                                  models: ["transcription": "parakeet/ultra"])
        let processor = PhoneProcessor(library: library.controller, services: PhoneProcessor.Services(
            engine: { engine }, summarizer: { summarizes ? summarizer : nil }, capabilities: { capabilities },
            owns: { [weak library] in library?.ownsTrack ?? { _ in false } },
            audio: { [weak library] track, id in
                guard let library else { throw CancellationError() }
                return try await library.audioURL(for: track, in: id)
            },
            release: {}), continued: ContinuedProcessing(scheduler: scheduler))
        library.processesHere = { [weak processor] in processor?.device }
        // Status lines read the app's processor; here, this one.
        let previous = PhoneProcessor.current
        PhoneProcessor.current = processor
        addTeardownBlock { @MainActor in PhoneProcessor.current = previous }
        return Rig(library: library, processor: processor, engine: engine, summarizer: summarizer, scheduler: scheduler)
    }

    /// Records a few seconds on synthetic audio and files it, as stopping a recording does.
    private func record(into library: PhoneLibrary, title: String = "Beta planning") async throws -> Meeting {
        let rig = RecorderRig()
        let id = UUID()
        try await rig.recorder.start(in: library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: title)
        rig.pump(3)
        return try await library.fileRecording(try await rig.stop()).meeting
    }

    private func request(_ rig: Rig, _ id: UUID) -> ProcessingRequest? { rig.library.controller.meeting(id)?.processingRequests?.first }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func outcome(_ rig: Rig, _ id: UUID) -> PhoneProcessor.Outcome? {
        rig.processor.lastOutcome?.meetingID == id ? rig.processor.lastOutcome?.outcome : nil
    }

    // MARK: Transcribed and summarized here

    func testBehaviorARecordingIsClaimedAsItsFiledThenTranscribedAndSummarizedHere() async throws {
        let rig = try await rig()
        let meeting = try await record(into: rig.library)
        let me = rig.library.controller.thisDevice
        let filed = try XCTUnwrap(request(rig, meeting.id))
        XCTAssertTrue(filed.isClaimed(by: me, at: Date()), "claimed in the save that filed it, before a Mac could see it")
        XCTAssertEqual(ProcessingStatus.phone(try XCTUnwrap(rig.library.controller.meeting(meeting.id))), .requested(.queued(position: 0, after: nil)))

        rig.processor.pickUp()
        try await waitUntil("the job to finish") { outcome(rig, meeting.id) == .completed }
        let done = try XCTUnwrap(rig.library.controller.meeting(meeting.id))
        XCTAssertEqual(rig.engine.transcribed, [meeting.tracks[0].id])
        XCTAssertEqual(done.transcripts.map(\.modelID), ["parakeet/ultra"], "the run records the model that made it")
        XCTAssertEqual(done.unifiedTranscript.map(\.text), ["Ship the beta on Friday."], "fused here: the last recording arrived here")
        XCTAssertEqual(done.summary?.overview, "The beta ships Friday.")
        XCTAssertEqual(done.summary?.processingSettings?.modelID, "gemma-4/e4b-4bit")
        XCTAssertEqual(done.status, .ready)
        XCTAssertEqual(done.processingRequests?.first?.outcome?.result, .completed)
        XCTAssertEqual(done.processingRequests?.first?.outcome?.device, me)
        XCTAssertEqual(ProcessingStatus.phone(done), .done)
        XCTAssertEqual(rig.library.controller.glossary.map(\.term), ["beta"], "its suggested terms, for approval")
    }

    func testBehaviorWithoutASummaryModelTheRequestGoesBackForAMac() async throws {
        let rig = try await rig(summarizes: false)
        let meeting = try await record(into: rig.library)
        rig.processor.pickUp()
        try await waitUntil("the job to finish") { outcome(rig, meeting.id) == .handedBack }
        let handed = try XCTUnwrap(rig.library.controller.meeting(meeting.id))
        XCTAssertEqual(handed.transcripts.count, 1, "transcribed here")
        XCTAssertFalse(handed.unifiedTranscript.isEmpty)
        XCTAssertNil(handed.summary)
        let open = try XCTUnwrap(handed.processingRequests?.first)
        XCTAssertTrue(open.isOpen)
        XCTAssertNil(open.activeClaim(at: Date()), "given back: a Mac that summarizes takes it")
        guard case .requested(.device) = ProcessingStatus.phone(handed) else { return XCTFail("waits for a Mac") }
        rig.processor.pickUp()
        XCTAssertNil(rig.processor.running, "never picked up again here")
    }

    func testBehaviorTranscribingEverythingAgainHereLeavesTheMacOnlyTheSummary() async throws {
        let rig = try await rig(summarizes: false)
        let meeting = try await record(into: rig.library)
        rig.processor.pickUp()
        try await waitUntil("the first pass") { outcome(rig, meeting.id) == .handedBack }
        rig.library.controller.update(meeting.id) { $0.setSummary(MeetingSummary(overview: "From a Mac", modelID: "gemma-4/26b-a4b-qat-4bit")) }
        try await Task.sleep(for: .milliseconds(5))
        let again = try XCTUnwrap(rig.library.controller.requestProcessing(meeting.id, mode: .fullRetranscription))
        rig.processor.pickUp()
        try await waitUntil("transcribing again") { rig.engine.transcribed.count == 2 && rig.processor.running == nil }
        let after = try XCTUnwrap(rig.library.controller.meeting(meeting.id))
        XCTAssertEqual(after.processingRequests?.first { $0.id == again.id }?.outcome?.result, .completed,
                       "done here: a Mac carrying it out would transcribe everything again")
        let summarize = try XCTUnwrap(after.openProcessingRequests.first { $0.mode == .summaryOnly }, "the summary is left for a Mac")
        XCTAssertNil(summarize.activeClaim(at: Date()))
        rig.processor.pickUp()
        XCTAssertNil(rig.processor.running)
        XCTAssertEqual(rig.engine.transcribed.count, 2)
    }

    func testBehaviorAnotherDevicesRecordingIsLeftToIt() async throws {
        let rig = try await rig()
        // A conversation a Mac recorded, synced here without a transcript; Transcribe asked from this iPhone.
        let id = rig.library.controller.newMeeting(title: "From the Mac")
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/mac.m4a", fileName: "mac.m4a", duration: 4, sha256: "mac")
        rig.library.controller.update(id) { $0.tracks = [track] }
        rig.library.controller.requestProcessing(id, mode: .newAudio)
        rig.processor.pickUp()
        XCTAssertNil(rig.processor.running)
        XCTAssertTrue(rig.engine.transcribed.isEmpty)
        XCTAssertNil(request(rig, id)?.activeClaim(at: Date()), "left for a Mac")
    }

    // MARK: Never in a recording's way, and backing off

    func testBehaviorARecordingPausesTheWorkWhichKeepsItsClaimAndResumes() async throws {
        let rig = try await rig()
        let meeting = try await record(into: rig.library)
        rig.engine.hold(true)
        rig.processor.pickUp()
        try await waitUntil("transcribing") { rig.engine.isWaiting }
        rig.processor.conditions.isRecording = true
        try await waitUntil("the pause") { outcome(rig, meeting.id) == .paused(.recording) }
        XCTAssertEqual(rig.processor.pause, .recording)
        XCTAssertTrue(request(rig, meeting.id)?.isClaimed(by: rig.library.controller.thisDevice, at: Date()) == true,
                      "kept: a Mac leaves it while this iPhone comes back to it")
        XCTAssertEqual(ProcessingStatus.phone(try XCTUnwrap(rig.library.controller.meeting(meeting.id))), .requested(.paused))
        rig.processor.pickUp()
        XCTAssertNil(rig.processor.running, "nothing starts while recording")

        rig.engine.hold(false)
        rig.processor.conditions.isRecording = false
        try await waitUntil("the job to finish") { outcome(rig, meeting.id) == .completed }
        XCTAssertEqual(rig.engine.transcribed.count, 1, "the stopped attempt added nothing")
        XCTAssertEqual(rig.library.controller.meeting(meeting.id)?.transcripts.count, 1)
    }

    func testBehaviorHeatLowPowerModeAndALowBatteryHoldTheWorkUntilTheyPass() async throws {
        let rig = try await rig()
        let meeting = try await record(into: rig.library)
        rig.processor.conditions.live = LiveConditions(thermal: .serious)
        rig.processor.pickUp()
        XCTAssertNil(rig.processor.running)
        XCTAssertEqual(rig.processor.pause, .heat)
        rig.processor.conditions.live = LiveConditions(lowPowerMode: true)
        XCTAssertEqual(rig.processor.pause, .lowPowerMode)
        rig.processor.conditions.live = LiveConditions(batteryLevel: 0.15, isCharging: false)
        XCTAssertEqual(rig.processor.pause, .lowBattery)
        rig.processor.conditions.live = LiveConditions(batteryLevel: 0.15, isCharging: true)
        try await waitUntil("the job to finish") { outcome(rig, meeting.id) == .completed }
        XCTAssertNil(rig.processor.pause)
    }

    // MARK: In the background

    func testBehaviorTheContinuedTaskShowsProgressCarriesTheWorkAndPausesItWhenItExpires() async throws {
        let rig = try await rig()
        let meeting = try await record(into: rig.library)
        rig.engine.hold(true)
        rig.processor.pickUp()
        try await waitUntil("transcribing") { rig.engine.isWaiting }
        try await waitUntil("the task") { rig.scheduler.tasks.first?.progress.completedUnitCount ?? 0 > 0 }
        let task = try XCTUnwrap(rig.scheduler.tasks.first)
        XCTAssertTrue(rig.scheduler.submitted.first?.hasPrefix("local.daybook.phone.processing.") == true)
        XCTAssertEqual(task.progress.totalUnitCount, ContinuedProcessing.units)
        XCTAssertEqual(task.progress.completedUnitCount, 500, "the work's own progress")
        XCTAssertEqual(task.titles.first, "Transcribing")

        // Out of sight, the task carries the work on.
        rig.processor.conditions.screen = .background
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(rig.processor.running)
        // The system ends the task: the work pauses, keeping its claim, until Daybook is back.
        task.expirationHandler?()
        try await waitUntil("the pause") { outcome(rig, meeting.id) == .paused(.background) }
        XCTAssertEqual(task.completed, false)
        XCTAssertTrue(request(rig, meeting.id)?.isClaimed(by: rig.library.controller.thisDevice, at: Date()) == true)

        rig.engine.hold(false)
        rig.processor.conditions.screen = .active
        try await waitUntil("the job to finish") { outcome(rig, meeting.id) == .completed }
        XCTAssertEqual(rig.scheduler.tasks.count, 2, "a new task for the work resumed on the screen")
        try await waitUntil("the second task to end") { rig.scheduler.tasks.last?.completed != nil }
        XCTAssertEqual(rig.scheduler.tasks.last?.completed, true)
    }

    func testBehaviorWithoutAContinuedTaskLeavingTheScreenPausesTheWork() async throws {
        let rig = try await rig()
        rig.scheduler.refuses = true
        let meeting = try await record(into: rig.library)
        rig.engine.hold(true)
        rig.processor.pickUp()
        try await waitUntil("transcribing") { rig.engine.isWaiting }
        rig.processor.conditions.screen = .background
        try await waitUntil("the pause") { outcome(rig, meeting.id) == .paused(.background) }
        rig.engine.hold(false)
        rig.processor.conditions.screen = .active
        try await waitUntil("the job to finish") { outcome(rig, meeting.id) == .completed }
    }

    func testBehaviorTheSummaryWaitsForTheScreen() async throws {
        let rig = try await rig()
        let meeting = try await record(into: rig.library)
        rig.engine.hold(true)
        rig.processor.pickUp()
        try await waitUntil("transcribing") { rig.engine.isWaiting }
        // Pulled down from the top: transcribing goes on, the summary (the graphics processor) waits.
        rig.processor.conditions.screen = .inactive
        rig.engine.hold(false)
        try await waitUntil("the pause") { outcome(rig, meeting.id) == .paused(.background) }
        XCTAssertEqual(rig.library.controller.meeting(meeting.id)?.transcripts.count, 1)
        XCTAssertTrue(rig.summarizer.summarized.isEmpty)
        rig.processor.conditions.screen = .active
        try await waitUntil("the job to finish") { outcome(rig, meeting.id) == .completed }
        XCTAssertEqual(rig.summarizer.summarized, [meeting.id])
        XCTAssertEqual(rig.engine.transcribed.count, 1, "not transcribed again for the summary")
    }

    // MARK: Claims

    func testBehaviorAnotherDeviceTakingTheRequestStopsTheWorkHere() async throws {
        let rig = try await rig()
        let meeting = try await record(into: rig.library)
        rig.engine.hold(true)
        rig.processor.pickUp()
        try await waitUntil("transcribing") { rig.engine.isWaiting }
        // A sync pass brings a Mac's newer claim (this iPhone's lease ran out while it was away).
        let mac = ProcessingRequest.Device(id: "studio-mac", name: "Studio Mac")
        var taken = try XCTUnwrap(request(rig, meeting.id))
        taken.claim = ProcessingRequest.Claim(device: mac, claimedAt: Date().addingTimeInterval(1), heartbeat: Date().addingTimeInterval(1),
                                              expiresAt: Date().addingTimeInterval(600))
        rig.library.controller.update(meeting.id) { $0.upsertProcessingRequest(taken) }
        rig.processor.reconcileClaims()
        try await waitUntil("the stop") { outcome(rig, meeting.id) == .lost }
        rig.engine.hold(false)
        let after = try XCTUnwrap(request(rig, meeting.id))
        XCTAssertTrue(after.isOpen)
        XCTAssertEqual(after.claim?.device, mac, "the Mac's, untouched")
        XCTAssertTrue(rig.library.controller.meeting(meeting.id)?.transcripts.isEmpty == true)
        XCTAssertFalse(rig.processor.paused.contains(meeting.id))
    }

    func testBehaviorOneConversationAtATime() async throws {
        let rig = try await rig()
        let first = try await record(into: rig.library, title: "First")
        let second = try await record(into: rig.library, title: "Second")
        rig.engine.hold(true)
        rig.processor.pickUp()
        try await waitUntil("transcribing") { rig.engine.isWaiting }
        let running = try XCTUnwrap(rig.processor.running?.meetingID)
        let waiting = running == first.id ? second.id : first.id
        XCTAssertEqual(ProcessingStatus.phone(try XCTUnwrap(rig.library.controller.meeting(waiting))),
                       .requested(.queued(position: 0, after: running)), "waiting its turn on this iPhone")
        rig.engine.hold(false)
        try await waitUntil("both") { rig.library.controller.meetings.allSatisfy { $0.summary != nil } }
        XCTAssertEqual(rig.engine.mostAtOnce, 1)
        XCTAssertEqual(Set(rig.summarizer.summarized), [first.id, second.id])
    }

    // MARK: Models and what they let this iPhone do

    func testBehaviorTheIPhonesModelsDecideWhatItCanDo() throws {
        let root = try temporaryDirectory()
        func models(_ gigabytes: Double, limit: UInt64? = nil) -> PhoneModels {
            PhoneModels(root: root.appendingPathComponent("Models-\(gigabytes)-\(UUID())"), defaults: makeTestDefaults("PhoneProcessingTests"),
                        fetcher: PhoneModelsTests.RecordingFetcher(), network: PhoneModelsTests.ScriptedNetwork().network,
                        physicalMemory: UInt64(gigabytes * 1e9), memoryLimit: limit, runsLanguageModels: true)
        }
        let small = models(3.9)
        XCTAssertEqual(small.choice(for: .transcription)?.key, "parakeet/redux")
        XCTAssertEqual(small.choice(for: .diarization)?.key, "nemotron-3-diarization/compact")
        XCTAssertNil(small.choice(for: .summarization))
        let large = models(12, limit: 8_400_000_000)
        XCTAssertEqual(large.choice(for: .transcription)?.key, "parakeet/ultra")
        XCTAssertEqual(large.choice(for: .diarization)?.key, "nemotron-3-diarization/offline")
        XCTAssertEqual(large.choice(for: .speakerEmbedding)?.key, "community-1/offline")
        XCTAssertEqual(large.choice(for: .summarization)?.key, "gemma-4/e4b-4bit")
        XCTAssertEqual(large.voiceEmbedder?.key, "community-1/offline", "Nemotron's turns get Community-1's voice profiles")
        XCTAssertEqual(models(12, limit: 5_400_000_000).choice(for: .summarization)?.key, "gemma-4/e2b-4bit", "without the larger limit")
        XCTAssertEqual(large.processingMissing.map(\.key), ["parakeet/ultra", "nemotron-3-diarization/offline", "community-1/offline"],
                       "the summary model is downloaded on its own")
        XCTAssertEqual(large.capabilities(enabled: true), ProcessingCapabilities(transcribes: false, findsSpeakers: false, summarizes: false),
                       "nothing downloaded, nothing to do")
        XCTAssertNil(large.processingEngine())
        XCTAssertNil(large.summarizer())
    }

    func testBehaviorDownloadedModelsLetItTranscribeAndSummarize() async throws {
        let root = try temporaryDirectory()
        let catalog = ModelCatalog.builtIn
        for key in ["parakeet/ultra", "nemotron-3-diarization/offline", "community-1/offline", "gemma-4/e4b-4bit"] {
            try installSynthetic(key, in: root, catalog: catalog)
        }
        let models = PhoneModels(root: root, defaults: makeTestDefaults("PhoneProcessingTests"), fetcher: PhoneModelsTests.RecordingFetcher(),
                                 network: PhoneModelsTests.ScriptedNetwork().network, physicalMemory: 12_000_000_000,
                                 memoryLimit: 8_400_000_000, runsLanguageModels: true)
        await models.refresh()
        let capabilities = models.capabilities(enabled: true)
        XCTAssertEqual(capabilities, ProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: true, models: [
            "transcription": "parakeet/ultra", "diarization": "nemotron-3-diarization/offline",
            "speakerEmbedding": "community-1/offline", "summarization": "gemma-4/e4b-4bit"]))
        XCTAssertEqual(models.capabilities(enabled: false), ProcessingCapabilities(transcribes: false, findsSpeakers: false, summarizes: false),
                       "Transcribe on This iPhone off: it all waits for a Mac")
        let engine = try XCTUnwrap(models.processingEngine())
        XCTAssertEqual(engine.configuration.transcriptionModel.id, "parakeet/ultra")
        XCTAssertEqual(engine.configuration.speakerModel.id, "nemotron-3-diarization/offline")
        XCTAssertEqual(engine.configuration.voiceEmbeddingModel?.id, "community-1/offline")
        XCTAssertEqual(models.summarizer()?.model, "gemma-4/e4b-4bit")
        // In the simulator, whose graphics MLX can't use, no summaries.
        let simulator = PhoneModels(root: root, defaults: makeTestDefaults("PhoneProcessingTests"), fetcher: PhoneModelsTests.RecordingFetcher(),
                                    network: PhoneModelsTests.ScriptedNetwork().network, physicalMemory: 12_000_000_000,
                                    memoryLimit: 8_400_000_000, runsLanguageModels: false)
        await simulator.refresh()
        XCTAssertFalse(simulator.capabilities(enabled: true).summarizes)
        XCTAssertTrue(simulator.capabilities(enabled: true).transcribes)
    }

    /// A verified-looking install: the receipt the store writes, and sparse files of the catalog's sizes.
    private func installSynthetic(_ key: String, in root: URL, catalog: ModelCatalog) throws {
        let model = try XCTUnwrap(catalog.model(key))
        let revision = try XCTUnwrap(model.latestRevision)
        let folder = root.appendingPathComponent("\(model.engine.rawValue)/\(model.familyID)/\(model.variant.id)/\(revision.id)")
        for artifact in revision.artifacts {
            for file in artifact.files {
                let url = folder.appendingPathComponent(artifact.name).appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(file.size))
                try handle.close()
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ModelInstallReceipt(model: model, revision: revision)).write(to: folder.appendingPathComponent(ModelInstallReceipt.fileName))
    }
}
