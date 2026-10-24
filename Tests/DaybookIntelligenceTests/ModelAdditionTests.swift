import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Adding models from Hugging Face (each engine checks what it can run) and the opt-in update
/// flow, against a scripted hub. Nothing touches the network.
final class ModelAdditionTests: XCTestCase {
    private var root: URL!
    private let hub = FakeHubClient()

    override func setUp() { root = SyntheticModels.temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// A Qwen2-architecture config small enough to instantiate.
    private let tinyQwenConfig = """
    {"model_type": "qwen2", "hidden_size": 8, "num_hidden_layers": 1, "intermediate_size": 16, "num_attention_heads": 2,
     "num_key_value_heads": 1, "rms_norm_eps": 1e-6, "vocab_size": 32, "max_position_embeddings": 4096, "tie_word_embeddings": true}
    """

    private func runtime(fetcher: FakeFetcher = FakeFetcher()) -> LocalIntelligenceRuntime {
        LocalIntelligenceRuntime(modelsDirectory: root, fetcher: fetcher)
    }

    func testAnMLXModelIsCheckedForArchitectureWeightsAndTokenizer() async throws {
        hub.publish("someone/Tiny-Qwen-4bit", commit: "c0ffee", title: "Upload", files: [
            "config.json": tinyQwenConfig, "model.safetensors": "weights", "tokenizer.json": "{}", "tokenizer_config.json": "{}",
            "README.md": "not fetched"], license: "apache-2.0")
        let runtime = runtime()
        let added = try await runtime.addModel(ModelAdditionRequest(repository: "someone/Tiny-Qwen-4bit", role: .summarization,
                                                                    engine: .mlxLanguage, variantName: "Tiny Qwen · 4-bit"), client: hub)
        XCTAssertEqual(added.key, "tiny-qwen-4bit/tiny-qwen-4-bit")
        XCTAssertEqual(added.origin.label, "Added by you")
        XCTAssertEqual(added.engineOptions["architecture"], "qwen2")
        XCTAssertEqual(added.capabilities.contextLength, 4096)
        XCTAssertEqual(added.license?.allowsCommercialUse, true)
        XCTAssertEqual(added.latestRevision?.id, "c0ffee")
        XCTAssertEqual(added.latestRevision?.artifacts.first?.files.map(\.path),
                       ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        XCTAssertEqual(added.variant.minimumEngineVersion, 2, "Entries record the engine version that checked them")
        XCTAssertEqual(added.capabilities.structuredOutput, true, "Guided generation works with any MLX model")

        // Persisted in the person's manifest and read back by the next launch.
        let manifest = try ModelManifestReader.read(Data(contentsOf: root.appendingPathComponent("UserModels.json"))).manifest
        XCTAssertEqual(manifest.families.map(\.id), ["tiny-qwen-4bit"])
        let relaunched = LocalIntelligenceRuntime(modelsDirectory: root)
        let catalog = await relaunched.catalog
        XCTAssertEqual(catalog.model(added.key)?.origin, .addedByYou)
        XCTAssertEqual(catalog.models.count, ModelCatalog.builtIn.models.count + 1)

        // The same files again are refused as a duplicate.
        do {
            _ = try await runtime.addModel(ModelAdditionRequest(repository: "someone/Tiny-Qwen-4bit", role: .summarization,
                                                                engine: .mlxLanguage, variantName: "Again"), client: hub)
            XCTFail("Duplicate")
        } catch ModelAdditionError.duplicate(let name) { XCTAssertEqual(name, "Tiny Qwen · 4-bit") }

        try await runtime.removeAddedModel(added.key)
        let after = await runtime.catalog
        XCTAssertNil(after.model(added.key))
    }

    func testAnMLXModelThisVersionCantRunIsRefusedWithReasons() async throws {
        hub.publish("someone/Future-4bit", commit: "f1", files: [
            "config.json": #"{"model_type": "gemma9_unified"}"#, "model.safetensors": "w", "tokenizer_config.json": "{}"])
        do {
            _ = try await runtime().addModel(ModelAdditionRequest(repository: "someone/Future-4bit", role: .summarization,
                                                                  engine: .mlxLanguage, variantName: "Future"), client: hub)
            XCTFail("Unsupported architecture")
        } catch ModelAdditionError.invalid(let reasons) {
            XCTAssertEqual(reasons, ["Its tokenizer (tokenizer.json) is missing.",
                                     "Its architecture (gemma9_unified) doesn’t run in this version of Daybook."])
        }
        hub.publish("someone/Not-MLX", commit: "f2", files: ["config.json": tinyQwenConfig, "pytorch_model.bin": "w",
                                                             "tokenizer.json": "{}", "tokenizer_config.json": "{}"])
        do {
            _ = try await runtime().addModel(ModelAdditionRequest(repository: "someone/Not-MLX", role: .summarization,
                                                                  engine: .mlxLanguage, variantName: "Not MLX"), client: hub)
            XCTFail("No safetensors")
        } catch ModelAdditionError.invalid(let reasons) {
            XCTAssertEqual(reasons, ["It has no .safetensors weights, so it isn’t an MLX conversion."])
        }
    }

    func testAWhisperKitModelNeedsItsCoreMLBundlesAndATokenizer() async throws {
        var files: [String: String] = [:]
        for bundle in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] {
            files["openai_whisper-tiny/\(bundle).mlmodelc/coremldata.bin"] = "\(bundle) data"
            files["openai_whisper-tiny/\(bundle).mlmodelc/weights/weight.bin"] = "\(bundle) weights"
        }
        files["openai_whisper-tiny/config.json"] = "{}"
        files["other_model/AudioEncoder.mlmodelc/coremldata.bin"] = "not included"
        hub.publish("argmaxinc/whisperkit-coreml", commit: "w1", files: files, license: "mit")
        hub.publish("openai/whisper-tiny", commit: "t1", files: ["tokenizer.json": "{}", "tokenizer_config.json": "{}",
                                                                "special_tokens_map.json": "{}", "model.safetensors": "unused"])
        let added = try await runtime().addModel(ModelAdditionRequest(
            repository: "argmaxinc/whisperkit-coreml", role: .transcription, engine: .whisperKit, variantName: "Whisper Tiny",
            familyID: "whisper", options: ["subdirectory": "openai_whisper-tiny", "tokenizerRepository": "openai/whisper-tiny"]), client: hub)
        XCTAssertEqual(added.key, "whisper/whisper-tiny")
        XCTAssertEqual(added.familyName, "Whisper", "Joins the existing family")
        let artifacts = try XCTUnwrap(added.latestRevision?.artifacts)
        XCTAssertEqual(artifacts.map(\.name), ["model", "tokenizer"])
        XCTAssertEqual(artifacts[0].root, "openai_whisper-tiny")
        XCTAssertEqual(artifacts[0].files.count, 7)
        XCTAssertEqual(artifacts[1].repository, "openai/whisper-tiny")
        XCTAssertEqual(artifacts[1].revision, "t1")
        XCTAssertEqual(artifacts[1].files.map(\.path), ["special_tokens_map.json", "tokenizer.json", "tokenizer_config.json"])
        XCTAssertEqual(added.capabilities.wordTimestamps, true)

        files.removeValue(forKey: "openai_whisper-tiny/TextDecoder.mlmodelc/coremldata.bin")
        files.removeValue(forKey: "openai_whisper-tiny/TextDecoder.mlmodelc/weights/weight.bin")
        hub.publish("argmaxinc/whisperkit-coreml", commit: "w2", files: files)
        do {
            _ = try await runtime().addModel(ModelAdditionRequest(
                repository: "argmaxinc/whisperkit-coreml", revision: "w2", role: .transcription, engine: .whisperKit, variantName: "Broken",
                options: ["subdirectory": "openai_whisper-tiny", "tokenizerRepository": "openai/whisper-tiny"]), client: hub)
            XCTFail("Missing decoder")
        } catch ModelAdditionError.invalid(let reasons) {
            XCTAssertEqual(reasons, ["openai_whisper-tiny/TextDecoder.mlmodelc is missing, so this isn’t a WhisperKit Core ML model."])
        }
    }

    func testSpeakerModelsNeedTheirCoreMLFiles() async throws {
        var community: [String: String] = ["plda-parameters.json": "{}"]
        for bundle in ["Segmentation", "FBank", "Embedding", "PldaRho"] { community["\(bundle).mlmodelc/coremldata.bin"] = bundle }
        hub.publish("someone/diarization-coreml", commit: "d1", files: community, license: "cc-by-4.0")
        let runtime = runtime()
        let added = try await runtime.addModel(ModelAdditionRequest(repository: "someone/diarization-coreml", role: .diarization,
                                                                    engine: .community1, variantName: "Community-1 retrained"), client: hub)
        XCTAssertEqual(added.capabilities.voiceEmbeddings?.space, "community1-someone-diarization-coreml-d1",
                       "A different conversion is a different voice space: profiles never mix")

        community.removeValue(forKey: "plda-parameters.json")
        hub.publish("someone/incomplete-coreml", commit: "d2", files: community)
        do {
            _ = try await runtime.addModel(ModelAdditionRequest(repository: "someone/incomplete-coreml", role: .diarization,
                                                                engine: .community1, variantName: "Incomplete"), client: hub)
            XCTFail("No PLDA")
        } catch ModelAdditionError.invalid(let reasons) { XCTAssertEqual(reasons, ["plda-parameters.json is missing."]) }

        hub.publish("someone/sortformer-coreml", commit: "s1", files: [
            "v4/fp16/Sortformer.mlmodelc/coremldata.bin": "c", "v4/fp16/Sortformer.mlmodelc/model.mil": "m",
            "v4/fp16/Sortformer.mlmodelc/weights/weight.bin": "w"])
        let sortformer = try await runtime.addModel(ModelAdditionRequest(
            repository: "someone/sortformer-coreml", role: .diarization, engine: .sortformer, variantName: "Sortformer 4",
            options: ["subdirectory": "v4/fp16/Sortformer.mlmodelc"]), client: hub)
        XCTAssertEqual(sortformer.engineOptions["precision"], "fp16")
        XCTAssertEqual(sortformer.capabilities.maxSpeakers, 4)
        do {
            _ = try await runtime.addModel(ModelAdditionRequest(repository: "someone/sortformer-coreml", role: .diarization,
                                                                engine: .sortformer, variantName: "No bundle"), client: hub)
            XCTFail("No subdirectory")
        } catch ModelAdditionError.invalid(let reasons) {
            XCTAssertEqual(reasons, ["Name the Sortformer bundle to use (a folder ending in .mlmodelc)."])
        }
    }

    func testGatedUnknownOrMismatchedAdditionsAreRefused() async throws {
        hub.publish("someone/gated", commit: "g1", files: ["config.json": tinyQwenConfig], gated: true)
        let runtime = runtime()
        do {
            _ = try await runtime.addModel(ModelAdditionRequest(repository: "someone/gated", role: .summarization, engine: .mlxLanguage,
                                                                variantName: "Gated"), client: hub)
            XCTFail("Gated")
        } catch ModelAdditionError.gated(let repository) { XCTAssertEqual(repository, "someone/gated") }
        do {
            _ = try await runtime.addModel(ModelAdditionRequest(repository: "someone/x", role: .transcription, engine: .mlxAudio,
                                                                variantName: "Qwen3-ASR"), client: hub)
            XCTFail("No engine yet")
        } catch ModelAdditionError.unknownEngine(let engine) { XCTAssertEqual(engine, .mlxAudio) }
        do {
            _ = try await runtime.addModel(ModelAdditionRequest(repository: "someone/x", role: .transcription, engine: .mlxLanguage,
                                                                variantName: "Wrong role"), client: hub)
            XCTFail("MLX language models don't transcribe")
        } catch ModelAdditionError.unsupportedRole(let role, _) { XCTAssertEqual(role, .transcription) }
    }

    func testAnUpdateIsFoundOnlyWhenTheVariantsFilesChanged() async throws {
        // A toy built-in model tracking "toy/models" main, its files under "small/".
        hub.publish("toy/models", commit: "rev-a", date: Date(timeIntervalSince1970: 1_767_225_600), files: [
            "small/weights.bin": "weights a", "small/config.json": "{}", "large/weights.bin": "large a"])
        let current = ModelRevisionEntry(id: "rev-a", releaseDate: "2026-01-01", artifacts: [
            ModelArtifact(name: "model", repository: "toy/models", revision: "rev-a", include: ["small/*"], root: "small",
                          files: try await hub.files(repository: "toy/models", revision: "rev-a", path: "small").map(\.manifestFile))])
        let builtIn = SyntheticModels.manifest(revisions: [current])
        let fetcher = FakeFetcher(hub.contents("toy/models", commit: "rev-a"))
        let log = CallLog()
        let runtime = LocalIntelligenceRuntime(modelsDirectory: root, registry: ModelEngineRegistry([ToyTranscriptionEngine(log: log)]),
                                               builtIn: .init(manifest: builtIn), fetcher: fetcher)
        try await runtime.download(modelID: "toy/small")

        // Main moved, but only another model's files changed: no update.
        hub.publish("toy/models", commit: "rev-b", files: ["small/weights.bin": "weights a", "small/config.json": "{}", "large/weights.bin": "large b"])
        var updates = await runtime.checkForUpdates(client: hub)
        XCTAssertTrue(updates.isEmpty)

        // This variant's weights changed: an update, with what changed, its size, and its date.
        let published = Date(timeIntervalSince1970: 1_780_000_000)
        hub.publish("toy/models", commit: "rev-c", date: published, title: "Requantize small",
                    files: ["small/weights.bin": "weights c!", "small/config.json": "{}", "large/weights.bin": "large b"])
        updates = await runtime.checkForUpdates(client: hub)
        let update = try XCTUnwrap(updates.first)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(update.model, "toy/small")
        XCTAssertEqual(update.currentRevision, "rev-a")
        XCTAssertEqual(update.revision.id, "rev-c")
        XCTAssertEqual(update.revision.summary, "Requantize small")
        XCTAssertEqual(update.publishedAt, published)
        XCTAssertEqual(update.changedFiles, ["model/small/weights.bin"])
        XCTAssertEqual(update.downloadBytes, Int64("weights c!".utf8.count + "{}".utf8.count))
        XCTAssertEqual(update.revision.artifacts.first?.root, "small")

        // A job froze rev-a and is running when the person installs the update.
        _ = try await runtime.transcribe(url: root.appendingPathComponent("a.caf"), model: ModelReference("toy/small", revision: "rev-a"))
        fetcher.add(hub.contents("toy/models", commit: "rev-c"))
        try await runtime.installUpdate(update)
        let inventory = await runtime.inventory()
        XCTAssertEqual(inventory.resolvedRevisions, ["toy/small": "rev-c"], "Selections switch once the new revision is verified")
        XCTAssertEqual(inventory.revisions(of: "toy/small").map(\.key.revision), ["rev-c", "rev-a"], "Installed beside the old one")
        let catalog = await runtime.catalog
        XCTAssertEqual(catalog.model("toy/small")?.userRevisionIDs, ["rev-c"])

        var removed = await runtime.collectGarbage(protecting: [ModelReference("toy/small", revision: "rev-a")])
        XCTAssertTrue(removed.isEmpty, "A queued job's revision is kept")
        removed = await runtime.collectGarbage(protecting: [])
        XCTAssertTrue(removed.isEmpty, "The loaded revision is in use")
        _ = try await runtime.transcribe(url: root.appendingPathComponent("a.caf"), model: "toy/small")
        removed = await runtime.collectGarbage(protecting: ["toy/small"])
        XCTAssertEqual(removed.map(\.revision), ["rev-a"], "Once nothing uses it, the old revision goes")
        XCTAssertEqual(log.calls, ["load toy/small@rev-a", "transcribe toy/small", "unload toy/small", "load toy/small@rev-c", "transcribe toy/small"])
    }

    func testUpdateCheckFollowsTheArtifactsListingRoot() {
        XCTAssertEqual(ModelUpdateChecker.listingRoot(["openai_whisper-base/*"]), "openai_whisper-base")
        XCTAssertEqual(ModelUpdateChecker.listingRoot(["v3/fp16/SortformerOffline_v2.1.mlmodelc/*"]), "v3/fp16/SortformerOffline_v2.1.mlmodelc")
        XCTAssertNil(ModelUpdateChecker.listingRoot(["*.safetensors", "*.json"]))
        XCTAssertNil(ModelUpdateChecker.listingRoot(["Segmentation.mlmodelc/*", "plda-parameters.json"]))
        XCTAssertEqual(HubSnapshotFetcher.literalGlob("a[1]/b*.bin"), "a\\[1\\]/b\\*.bin")
        XCTAssertTrue(ModelGlob.matches("openai_whisper-base/*", "openai_whisper-base/AudioEncoder.mlmodelc/weights/weight.bin"))
    }
}
