import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Engines are pluggable: the registry, capability-driven routing, residency, and provenance, all
/// through `LocalIntelligenceRuntime` with stand-in engines and synthetic installs.
final class ModelEngineTests: XCTestCase {
    private var root: URL!

    override func setUp() { root = SyntheticModels.temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    // MARK: Stand-ins for engines that arrive next

    /// Nemotron-like (no voice profiles) or Community-1-like (with them) speaker detection.
    private struct ToyDiarizerEngine: ModelEngine {
        let id: ModelEngineID
        let space: String?
        let log: CallLog
        var descriptor: ModelEngineDescriptor {
            ModelEngineDescriptor(id: id, name: id.rawValue, version: 1, runtime: "Toy 1.0", roles: [.diarization], platforms: [.macOS, .iOS])
        }
        func validate(_ installation: ModelInstallation) throws {}
        func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
            throw ModelAdditionError.invalid(["Not in this test."])
        }
        func load(_ installation: ModelInstallation, role: ModelRole, progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
            log.add("load \(installation.key.variantKey)")
            return Diarizer(space: space, log: log)
        }
        final class Diarizer: Diarizing, @unchecked Sendable {
            let space: String?; let log: CallLog
            init(space: String?, log: CallLog) { self.space = space; self.log = log }
            func diarize(url: URL, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
                log.add("diarize")
                return SpeakerAnalysis(turns: [SpeakerTurn(speakerID: "0", start: 0, end: 1, confidence: 1)],
                                       embeddings: space == nil ? [:] : ["0": [0.6, 0.8]], embeddingModelID: space)
            }
            func unload() { log.add("unload diarizer") }
        }
    }

    /// WeSpeaker-like voice profiles for another model's turns.
    private struct ToyEmbedderEngine: ModelEngine {
        let log: CallLog
        var descriptor: ModelEngineDescriptor {
            ModelEngineDescriptor(id: "toyEmbedder", name: "Embedder", version: 1, runtime: "Toy 1.0", roles: [.speakerEmbedding], platforms: [.macOS])
        }
        func validate(_ installation: ModelInstallation) throws {}
        func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
            throw ModelAdditionError.invalid(["Not in this test."])
        }
        func load(_ installation: ModelInstallation, role: ModelRole, progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
            Embedder(space: installation.capabilities.voiceEmbeddings?.space ?? "", log: log)
        }
        final class Embedder: EmbeddingVoices, @unchecked Sendable {
            let space: String; let log: CallLog
            init(space: String, log: CallLog) { self.space = space; self.log = log }
            func embedVoices(url: URL, analysis: SpeakerAnalysis, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
                log.add("embed \(analysis.turns.count) turns")
                var result = analysis
                result.embeddings = Dictionary(uniqueKeysWithValues: Set(analysis.turns.map(\.speakerID)).map { ($0, [1, 0]) })
                result.embeddingModelID = space
                return result
            }
        }
    }

    /// An MLX-like summarizer: exclusive residency.
    private struct ToySummaryEngine: ModelEngine {
        let log: CallLog
        var descriptor: ModelEngineDescriptor {
            ModelEngineDescriptor(id: "toyLanguage", name: "Language", version: 3, runtime: "Toy LM 3.0", roles: [.summarization],
                                  platforms: [.macOS], residency: .exclusive)
        }
        func validate(_ installation: ModelInstallation) throws {}
        func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
            throw ModelAdditionError.invalid(["Not in this test."])
        }
        func load(_ installation: ModelInstallation, role: ModelRole, progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
            log.add("load \(installation.key.variantKey)")
            return Summarizer(log: log)
        }
        final class Summarizer: Summarizing, @unchecked Sendable {
            let log: CallLog
            init(log: CallLog) { self.log = log }
            func summarize(_ request: SummaryRequest, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
                log.add("summarize \(request.modelID)")
                return GeneratedMeetingNotes(summary: MeetingSummary(overview: "Shipping Friday", modelID: request.modelID),
                                             suggestedTerms: [], rawResponse: "{}", warnings: [])
            }
            func unload() { log.add("unload summarizer") }
        }
    }

    /// A family with one variant and one installed-able revision; returns the fetcher contents.
    private func family(_ id: String, engine: ModelEngineID, role: ModelRole, variant: String = "v1", name: String,
                        capabilities: ModelCapabilities = .init()) -> (ModelFamilyEntry, [String: Data]) {
        let (artifact, contents) = SyntheticModels.artifact("model", repository: "toy/\(id)", revision: "rev-\(id)",
                                                            files: [("weights.bin", "weights of \(id)")])
        let entry = ModelFamilyEntry(id: id, name: name, engine: engine, roles: [role], variants: [
            ModelVariantEntry(id: variant, name: name, capabilities: capabilities,
                              revisions: [ModelRevisionEntry(id: "rev-\(id)", releaseDate: "2026-10-01", artifacts: [artifact])])])
        return (entry, contents)
    }

    private func runtime(_ families: [(ModelFamilyEntry, [String: Data])], registry: ModelEngineRegistry) async throws -> LocalIntelligenceRuntime {
        let fetcher = FakeFetcher()
        for (_, contents) in families { fetcher.add(contents) }
        let runtime = LocalIntelligenceRuntime(modelsDirectory: root, registry: registry,
                                               builtIn: .init(manifest: ModelManifest(families: families.map(\.0))), fetcher: fetcher)
        for (family, _) in families {
            for variant in family.variants { try await runtime.download(modelID: "\(family.id)/\(variant.id)") }
        }
        return runtime
    }

    // MARK: Tests

    func testTheStandardRegistryDeclaresEachEngine() {
        let registry = ModelEngineRegistry.standard
        XCTAssertEqual(registry.descriptors.map(\.id), [.whisperKit, .community1, .sortformer, .mlxLanguage, .parakeet, .nemotronDiarizer,
                                                        .appleFoundationModels])
        XCTAssertEqual(registry.engine(.whisperKit)?.descriptor.roles, [.transcription])
        XCTAssertEqual(registry.engine(.community1)?.descriptor.roles, [.diarization, .speakerEmbedding])
        XCTAssertEqual(registry.engine(.parakeet)?.descriptor.roles, [.transcription])
        XCTAssertEqual(registry.engine(.nemotronDiarizer)?.descriptor.roles, [.diarization])
        XCTAssertEqual(registry.engine(.parakeet)?.descriptor.versionString, "1 (FluidAudio 0.17.7)")
        XCTAssertEqual(registry.engine(.nemotronDiarizer)?.descriptor.residency, .shared)
        XCTAssertEqual(registry.engine(.mlxLanguage)?.descriptor.residency, .exclusive)
        XCTAssertEqual(registry.engine(.sortformer)?.descriptor.residency, .shared)
        XCTAssertEqual(registry.engine(.whisperKit)?.descriptor.versionString, "2 (argmax-oss-swift 1.1.1)")
        XCTAssertEqual(registry.engine(.mlxLanguage)?.descriptor.versionString, "2 (mlx-swift-lm 3.32.3)")
        XCTAssertEqual(registry.engine(.appleFoundationModels)?.descriptor.roles, [.smallTasks])
        XCTAssertEqual(registry.engine(.appleFoundationModels)?.descriptor.residency, .system)
        XCTAssertTrue(registry.descriptors.allSatisfy { $0.platforms.contains(.macOS) })
        XCTAssertNil(registry.engine(.mlxAudio), "Qwen3-ASR arrives with its engine")
    }

    func testEveryBuiltInModelRunsOnARegisteredEngineThatServesItsRoles() {
        let registry = ModelEngineRegistry.standard
        for model in ModelCatalog.builtIn.models {
            let engine = registry.engine(model.engine)
            XCTAssertNotNil(engine, model.key)
            XCTAssertTrue(Set(model.roles).isSubset(of: engine?.descriptor.roles ?? []), model.key)
            XCTAssertEqual(model.availability(engines: registry.descriptors, appVersion: ModelVersion("0.1.0"), platform: .macOS), .available, model.key)
        }
    }

    func testAddingAnEngineIsOneTypeAndOneRegistration() async throws {
        let log = CallLog()
        let qwen = family("qwen3-asr", engine: .mlxAudio, role: .transcription, variant: "1.7b-8bit", name: "Qwen3-ASR",
                          capabilities: .init(wordTimestamps: true, wordConfidence: false, languages: ["en", "zh"]))
        // Before the engine exists, the manifest entry is listed but not offered.
        let catalog = ModelCatalog(builtIn: ModelManifest(families: [qwen.0]))
        XCTAssertEqual(catalog.models[0].availability(engines: ModelEngineRegistry.standard.descriptors, appVersion: nil).label, "Needs a newer Daybook")

        // One registration later, the same entry downloads, runs, and records itself — no pipeline edit.
        let registry = ModelEngineRegistry.standard.registering(ToyTranscriptionEngine(id: .mlxAudio, log: log))
        let runtime = try await runtime([qwen], registry: registry)
        let installed = await runtime.installedModels()
        XCTAssertEqual(installed, ["qwen3-asr/1.7b-8bit"])
        let engine = InferenceProcessingEngine(inference: runtime, configuration: .init(
            transcriptionModel: "qwen3-asr/1.7b-8bit", summaryModel: "unused", detectSpeakers: false, speakerModel: "unused",
            speakerOptions: .init(), fingerprint: "f", speakerMatchThreshold: 0.8, speakerMatchMargin: 0.05))
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.caf", fileName: "a.caf", duration: 1, sha256: "a")
        let output = try await engine.transcribe(TrackProcessingInput(meetingID: UUID(), track: track, audioURL: root.appendingPathComponent("a.caf"),
                                                                      mode: .newAudio), progress: { _ in })
        XCTAssertEqual(output.transcript.modelID, "qwen3-asr/1.7b-8bit")
        XCTAssertEqual(output.transcript.processingSettings?.model, ModelProvenance(
            family: "qwen3-asr", variant: "1.7b-8bit", revision: "rev-qwen3-asr", engine: "mlxAudio",
            engineVersion: "1 (Toy 1.0)", name: "Qwen3-ASR", repository: "toy/qwen3-asr"))
        XCTAssertEqual(log.calls, ["load qwen3-asr/1.7b-8bit@rev-qwen3-asr", "transcribe qwen3-asr/1.7b-8bit"])
    }

    func testVoiceProfilesAreRoutedByCapability() async throws {
        let log = CallLog()
        let nemotron = family("nemotron-3", engine: .nemotronDiarizer, role: .diarization, name: "Nemotron 3", capabilities: .init(maxSpeakers: 8))
        let community = family("community-like", engine: .community1, role: .diarization, name: "Community-like",
                               capabilities: .init(voiceEmbeddings: .init(space: "community-space", dimensions: 2)))
        let embedder = family("wespeaker", engine: "toyEmbedder", role: .speakerEmbedding, name: "WeSpeaker",
                              capabilities: .init(voiceEmbeddings: .init(space: "community-space", dimensions: 2)))
        let registry = ModelEngineRegistry([ToyDiarizerEngine(id: .nemotronDiarizer, space: nil, log: log),
                                            ToyDiarizerEngine(id: .community1, space: "community-space", log: log),
                                            ToyEmbedderEngine(log: log), ToyTranscriptionEngine(log: log)])
        let runtime = try await runtime([nemotron, community, embedder], registry: registry)
        let catalog = await runtime.catalog
        let selections = ModelSelections([.diarization: "nemotron-3/v1", .speakerEmbedding: "wespeaker/v1"])
        let routed = ModelRouting.voiceEmbedder(diarizer: "nemotron-3/v1", selections: selections, catalog: catalog,
                                                engines: runtime.engines, appVersion: nil)
        XCTAssertEqual(routed, "wespeaker/v1")

        let previous = TrackTranscript(trackID: UUID(), segments: [], modelID: "earlier",
                                       words: [TranscriptWord(text: " Hi", start: 0, end: 0.5, confidence: 1)])
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.caf", fileName: "a.caf", duration: 1, sha256: "a")
        func run(diarizer: String, embedder: String?) async throws -> TrackProcessingOutput {
            let engine = InferenceProcessingEngine(inference: runtime, configuration: .init(
                transcriptionModel: "unused", summaryModel: "unused", detectSpeakers: true, speakerModel: ModelReference(diarizer),
                voiceEmbeddingModel: embedder.map { ModelReference($0) }, speakerOptions: .init(), fingerprint: "f",
                speakerMatchThreshold: 0.8, speakerMatchMargin: 0.05))
            return try await engine.transcribe(TrackProcessingInput(meetingID: UUID(), track: track, audioURL: root.appendingPathComponent("a.caf"),
                                                                    mode: .speakerRefresh, previousTranscript: previous), progress: { _ in })
        }
        let withEmbedder = try await run(diarizer: "nemotron-3/v1", embedder: routed)
        XCTAssertEqual(withEmbedder.speakerEmbeddingModelID, "community-space")
        XCTAssertEqual(withEmbedder.speakers.first?.embedding, [1, 0])
        XCTAssertEqual(withEmbedder.speakers.first?.analysisSettings?.model?.variantKey, "nemotron-3/v1")
        XCTAssertEqual(withEmbedder.transcript.processingSettings?.parameters["voiceEmbeddingModel"], "wespeaker/v1")
        XCTAssertTrue(log.calls.contains("embed 1 turns"))

        let embedCalls = log.calls.filter { $0.hasPrefix("embed") }.count
        let direct = try await run(diarizer: "community-like/v1",
                                   embedder: ModelRouting.voiceEmbedder(diarizer: "community-like/v1", selections: selections, catalog: catalog,
                                                                        engines: runtime.engines, appVersion: nil))
        XCTAssertEqual(direct.speakers.first?.embedding, [0.6, 0.8], "The diarizer's own profiles are used")
        XCTAssertEqual(log.calls.filter { $0.hasPrefix("embed") }.count, embedCalls, "No embedding model ran")
    }

    func testExclusiveModelsReleaseOthersAndRolesAreChecked() async throws {
        let log = CallLog()
        let speech = family("toy", engine: "toyEngine", role: .transcription, name: "Toy Speech")
        let language = family("toy-lm", engine: "toyLanguage", role: .summarization, name: "Toy LM")
        let runtime = try await runtime([speech, language], registry: ModelEngineRegistry([ToyTranscriptionEngine(log: log), ToySummaryEngine(log: log)]))
        let audio = root.appendingPathComponent("a.caf")
        _ = try await runtime.transcribe(url: audio, model: "toy/v1")
        _ = try await runtime.transcribe(url: audio, model: "toy/v1")
        let notes = try await runtime.summarize(transcript: "Hello", notes: "", model: "toy-lm/v1")
        _ = try await runtime.transcribe(url: audio, model: "toy/v1")
        XCTAssertEqual(log.calls, [
            "load toy/v1@rev-toy", "transcribe toy/v1", "transcribe toy/v1",       // loaded once, reused
            "unload toy/v1", "load toy-lm/v1", "summarize toy-lm/v1",              // the exclusive model has the machine to itself
            "unload summarizer", "load toy/v1@rev-toy", "transcribe toy/v1"])      // and leaves when speech returns
        XCTAssertEqual(notes.provenance?.engineVersion, "3 (Toy LM 3.0)")

        do {
            _ = try await runtime.summarize(transcript: "Hello", notes: "", model: "toy/v1")
            XCTFail("A transcription model can't summarize")
        } catch LocalIntelligenceError.unsupportedRole(let model, _) { XCTAssertEqual(model, "toy/v1") }

        // A frozen revision that's gone fails rather than running another one.
        do {
            _ = try await runtime.transcribe(url: audio, model: ModelReference("toy/v1", revision: "rev-gone"))
            XCTFail("Processing never silently switches models")
        } catch LocalIntelligenceError.modelNotInstalled(let id) { XCTAssertEqual(id, "toy/v1") }

        // A loaded model can't be removed from under a job; removing releases it first.
        try await runtime.remove(modelID: "toy/v1")
        let installed = await runtime.installedModels()
        XCTAssertEqual(installed, ["toy-lm/v1"])
    }

    func testTheSystemModelNeitherReleasesNorIsReleased() async throws {
        let log = CallLog()
        let language = family("toy-lm", engine: "toyLanguage", role: .summarization, name: "Toy LM")
        let apple = try XCTUnwrap(try ModelCatalog.readBuiltInManifest().manifest.families.first { $0.id == "apple-foundation-models" })
        let engine = AppleFoundationModelsEngine(availability: { .available }) { _, _, _ in
            log.add("small tasks")
            return .init(title: "Title", kind: "general", terms: [])
        }
        let runtime = try await runtime([language, (apple, [:])], registry: ModelEngineRegistry([ToySummaryEngine(log: log), engine]))
        _ = try await runtime.summarize(transcript: "Hello", notes: "", model: "toy-lm/v1")
        _ = try await runtime.performSmallTasks(transcript: "Hello", notes: "", model: "apple-foundation-models/system")
        _ = try await runtime.summarize(transcript: "Hello", notes: "", model: "toy-lm/v1")
        XCTAssertEqual(log.calls, ["load toy-lm/v1", "summarize toy-lm/v1", "small tasks", "summarize toy-lm/v1"],
                       "The language model stays loaded around Apple's model, which holds none of Daybook's memory")
    }

    func testSummariesRecordTheExactModel() async throws {
        let log = CallLog()
        let language = family("toy-lm", engine: "toyLanguage", role: .summarization, name: "Toy LM")
        let runtime = try await runtime([language], registry: ModelEngineRegistry([ToySummaryEngine(log: log)]))
        let engine = InferenceProcessingEngine(inference: runtime, configuration: .init(
            transcriptionModel: "unused", summaryModel: ModelReference("toy-lm/v1", revision: "rev-toy-lm"), detectSpeakers: false,
            speakerModel: "unused", speakerOptions: .init(), fingerprint: "f", speakerMatchThreshold: 0.8, speakerMatchMargin: 0.05))
        let meeting = Meeting(title: "Standup", unifiedTranscript: [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "Ship Friday")])
        let output = try await engine.summarize(meeting, template: nil, vocabulary: [], progress: { _ in })
        XCTAssertEqual(output.summary.processingSettings?.modelID, "toy-lm/v1")
        XCTAssertEqual(output.summary.processingSettings?.model?.revision, "rev-toy-lm")
        XCTAssertEqual(output.summary.processingSettings?.model?.engine, "toyLanguage")
        XCTAssertEqual(output.summary.processingSettings?.model?.engineVersion, "3 (Toy LM 3.0)")
    }
}

/// A model the operating system provides (Apple Foundation Models) is an engine plus a manifest
/// entry with `systemProvided`: nothing to download, and the engine says whether this device has it.
final class SystemModelTests: XCTestCase {
    private struct SystemEngine: ModelEngine {
        let present: Bool
        let log: CallLog
        var descriptor: ModelEngineDescriptor {
            ModelEngineDescriptor(id: .appleFoundationModels, name: "Apple Foundation Models", version: 1, runtime: "FoundationModels (macOS 27)",
                                  roles: [.transcription], platforms: [.macOS, .iOS])
        }
        func validate(_ installation: ModelInstallation) throws {
            guard present else { throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey) }
        }
        func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
            throw ModelAdditionError.invalid(["Built into the system."])
        }
        func load(_ installation: ModelInstallation, role: ModelRole, progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
            ToyTranscriber(log: log, name: installation.key.variantKey)
        }
    }

    func testSystemModelsNeedNoDownloadAndAreOnlyOfferedWhereTheyExist() async throws {
        let root = SyntheticModels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = ModelManifest(families: [ModelFamilyEntry(
            id: "apple-foundation", name: "Apple Intelligence", engine: .appleFoundationModels, roles: [.transcription],
            variants: [ModelVariantEntry(id: "on-device", name: "On-device model", systemProvided: true)])])
        let log = CallLog()
        let fetcher = FakeFetcher()
        let runtime = LocalIntelligenceRuntime(modelsDirectory: root, registry: ModelEngineRegistry([SystemEngine(present: true, log: log)]),
                                               builtIn: .init(manifest: manifest), fetcher: fetcher)
        let installed = await runtime.installedModels()
        XCTAssertEqual(installed, ["apple-foundation/on-device"])
        try await runtime.download(modelID: "apple-foundation/on-device")
        XCTAssertEqual(fetcher.calls, 0)
        let result = try await runtime.transcribe(url: root.appendingPathComponent("a.caf"), model: "apple-foundation/on-device")
        XCTAssertEqual(result.provenance?.revision, "system")
        XCTAssertEqual(result.provenance?.engineVersion, "1 (FoundationModels (macOS 27))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Nothing was written")

        let elsewhere = LocalIntelligenceRuntime(modelsDirectory: root, registry: ModelEngineRegistry([SystemEngine(present: false, log: log)]),
                                                 builtIn: .init(manifest: manifest), fetcher: fetcher)
        let none = await elsewhere.installedModels()
        XCTAssertTrue(none.isEmpty, "A device without it doesn't offer it")
        do {
            _ = try await elsewhere.transcribe(url: root.appendingPathComponent("a.caf"), model: "apple-foundation/on-device")
            XCTFail("Not on this device")
        } catch LocalIntelligenceError.modelNotInstalled {}
    }
}
