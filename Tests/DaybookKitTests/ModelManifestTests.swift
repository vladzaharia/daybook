import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The manifest format, the built-in catalog it ships, and how forgiving reading is.
final class ModelManifestTests: XCTestCase {
    private let legacyIDs: Set<String> = ["whisper-base", "whisper-small", "whisper-large-turbo", "speaker-community-1",
                                          "speaker-sortformer-v2.1-compact", "speaker-sortformer-v2.1", "qwen-1.5b", "qwen-3b", "qwen-7b"]

    func testBuiltInCatalogModelsArePinnedWithDigests() throws {
        let catalog = ModelCatalog.builtIn
        XCTAssertTrue(catalog.warnings.isEmpty, "\(catalog.warnings)")
        // Family files load in file-name order.
        XCTAssertEqual(catalog.models.map(\.key), [
            "apple-foundation-models/system", "community-1/offline",
            "gemma-4/e2b-4bit", "gemma-4/e4b-4bit", "gemma-4/12b-4bit", "gemma-4/26b-a4b-qat-4bit", "gemma-4/31b-8bit",
            "nemotron-3-diarization/offline", "nemotron-3-diarization/compact", "parakeet/ultra", "parakeet/redux",
            "qwen2.5/1.5b-4bit", "qwen2.5/3b-4bit", "qwen2.5/7b-4bit", "qwen3.5/4b-4bit", "qwen3.5/9b-4bit", "qwen3.6/35b-a3b-4bit",
            "sortformer-2.1/compact", "sortformer-2.1/fp16", "whisper/base", "whisper/small", "whisper/large-v3-turbo"])
        XCTAssertEqual(Set(catalog.models.flatMap(\.legacyIDs)), legacyIDs)
        // The system model has nothing to download.
        let system = try XCTUnwrap(catalog.model("apple-foundation-models/system"))
        XCTAssertTrue(system.isSystemModel)
        XCTAssertTrue(system.variant.revisions.isEmpty)
        XCTAssertEqual(system.approximateBytes, 0)
        for model in catalog.models where !model.isSystemModel {
            let revision = try XCTUnwrap(model.latestRevision, model.key)
            XCTAssertEqual(revision.id.count, 40, "\(model.key) is pinned to a commit")
            XCTAssertNotNil(revision.releaseDate)
            for artifact in revision.artifacts {
                XCTAssertFalse(artifact.files.isEmpty)
                for file in artifact.files {
                    XCTAssertTrue(file.sha256 != nil || file.gitOID != nil, "\(model.key) \(file.path) has a digest")
                    XCTAssertGreaterThan(file.size, 0)
                }
            }
        }
        // The exact pins Daybook downloaded before the manifest existed.
        XCTAssertEqual(catalog.model("whisper-base")?.latestRevision?.artifacts.map(\.revision),
                       ["0f63a7800b00dd0226abd051b906c246e1907482", "e37978b90ca9030d5170a5c07aadb050351a65bb"])
        XCTAssertEqual(catalog.model("qwen-7b")?.latestRevision?.artifacts.first?.repository, "mlx-community/Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(catalog.model("speaker-community-1")?.latestRevision?.id, "df2625ac79a7ac6b65ad868fee6d80f320da4232")
        XCTAssertEqual(catalog.model("speaker-sortformer-v2.1-compact")?.engineOptions["precision"], "palettized")
        XCTAssertEqual(catalog.model("speaker-sortformer-v2.1")?.latestRevision?.artifacts.first?.root,
                       "v3/fp16/SortformerOffline_v2.1.mlmodelc")
        // Sizes come from the files now, not estimates.
        XCTAssertEqual(catalog.model("qwen2.5/7b-4bit")?.approximateBytes, 4_294_215_757)
        // The speech models FluidAudio 0.17.7 runs, pinned to FluidInference's conversions.
        let ultra = try XCTUnwrap(catalog.model("parakeet/ultra"))
        XCTAssertEqual(ultra.latestRevision?.artifacts.map(\.repository), ["FluidInference/parakeet-ultra-coreml"])
        XCTAssertEqual(ultra.latestRevision?.id, "95eaa59a39d4394f047a4dc5cce480388a60d1b6")
        XCTAssertEqual(ultra.engineOptions["version"], "ultra")
        XCTAssertEqual(ultra.approximateBytes, 632_162_964)
        XCTAssertEqual(catalog.model("parakeet/redux")?.engineOptions["version"], "redux")
        let nemotron = try XCTUnwrap(catalog.model("nemotron-3-diarization/offline"))
        XCTAssertEqual(nemotron.latestRevision?.id, "25a90f97f254428d4b30374b76af9c74fdee8327")
        XCTAssertEqual(nemotron.engineOptions["preset"], "offline")
        XCTAssertEqual(Set(nemotron.latestRevision?.artifacts.first?.files.map(\.path) ?? []).count, 5)
        XCTAssertTrue(nemotron.latestRevision?.artifacts.first?.files.contains { $0.path == "learnable_sil_emb.bin" } == true)
        XCTAssertEqual(catalog.model("nemotron-3-diarization/compact")?.engineOptions["preset"], "c128-split-w8a8")
        XCTAssertTrue(catalog.model("nemotron-3-diarization/compact")?.latestRevision?.artifacts.first?.files
            .contains { $0.path == "pre_encode_proj_t.bin" } == true)
        XCTAssertEqual(catalog.model("gemma-4/12b-4bit")?.latestRevision?.artifacts.first?.repository, "mlx-community/gemma-4-12B-it-4bit")
        XCTAssertEqual(catalog.model("gemma-4/26b-a4b-qat-4bit")?.latestRevision?.id, "0e3cbab38ce568cf6e23543010d08d03b731910c")
    }

    func testNewLanguageModelsNeedTheUpgradedEngineAndSupersedeQwen25() throws {
        let catalog = ModelCatalog.builtIn
        let added = catalog.models.filter { ["gemma-4", "qwen3.5", "qwen3.6"].contains($0.familyID) }
        XCTAssertEqual(added.count, 8)
        for model in added {
            XCTAssertEqual(model.variant.minimumEngineVersion, 2, model.key)
            XCTAssertEqual(model.capabilities.structuredOutput, true, model.key)
            XCTAssertGreaterThanOrEqual(model.capabilities.contextLength ?? 0, 131_072, model.key)
            XCTAssertNotNil(model.variant.recommendedMemoryGB, model.key)
            XCTAssertEqual(model.engineOptions["thinking"], "off", model.key)
            XCTAssertEqual(model.license?.id, "Apache-2.0", model.key)
            XCTAssertTrue(model.license?.allowsCommercialUse == true, model.key)
        }
        // An MLX engine before the upgrade offers none of them.
        let older = [ModelEngineDescriptor(id: .mlxLanguage, name: "MLX", version: 1, runtime: "mlx-swift-lm 2.29.3",
                                           roles: [.summarization], platforms: [.macOS])]
        XCTAssertEqual(catalog.model("gemma-4/12b-4bit")?.availability(engines: older, appVersion: nil, platform: .macOS).label,
                       "Needs a newer Daybook")
        // Qwen 2.5 stays, pointing to its replacement; 3B keeps its non-commercial license.
        XCTAssertEqual(catalog.model("qwen2.5/1.5b-4bit")?.variant.supersededBy, "gemma-4/e2b-4bit")
        XCTAssertEqual(catalog.model("qwen2.5/3b-4bit")?.variant.supersededBy, "gemma-4/e4b-4bit")
        XCTAssertEqual(catalog.model("qwen2.5/7b-4bit")?.variant.supersededBy, "gemma-4/12b-4bit")
        XCTAssertEqual(catalog.model("gemma-4/12b-4bit")?.variant.supersedes, ["qwen2.5/7b-4bit"])
        XCTAssertEqual(catalog.model("qwen2.5/3b-4bit")?.license?.allowsCommercialUse, false)
        for key in ["gemma-4/e2b-4bit", "gemma-4/e4b-4bit", "gemma-4/12b-4bit"] {
            let replaced = try XCTUnwrap(catalog.model(key)?.variant.supersedes.first)
            XCTAssertEqual(catalog.model(replaced)?.variant.supersededBy, key)
        }
    }

    func testBuiltInCapabilitiesReplaceModelIDChecks() {
        let catalog = ModelCatalog.builtIn
        XCTAssertEqual(catalog.model("community-1/offline")?.capabilities.voiceEmbeddings?.space, "fluid-community1-embedding-df2625ac79a7ac6b")
        XCTAssertEqual(catalog.model("community-1/offline")?.capabilities.expectedSpeakerCount, true)
        XCTAssertEqual(catalog.model("sortformer-2.1/fp16")?.capabilities.maxSpeakers, 4)
        XCTAssertNil(catalog.model("sortformer-2.1/compact")?.capabilities.voiceEmbeddings)
        XCTAssertEqual(catalog.model("whisper/base")?.capabilities.wordTimestamps, true)
        XCTAssertEqual(catalog.model("qwen2.5/1.5b-4bit")?.capabilities.contextLength, 32_768)
        XCTAssertTrue(ModelRouting.supportsVoiceMatching("speaker-community-1", catalog: catalog))
        XCTAssertFalse(ModelRouting.supportsVoiceMatching("sortformer-2.1/compact", catalog: catalog))
        XCTAssertFalse(ModelRouting.supportsExpectedSpeakerCount("sortformer-2.1/fp16", catalog: catalog))
        // Parakeet: 25 languages with word timings and confidences; Nemotron: 8 speakers, profiles from Community-1.
        let parakeet = catalog.model("parakeet/ultra")?.capabilities
        XCTAssertEqual(parakeet?.languages?.count, 25)
        XCTAssertEqual(parakeet?.wordTimestamps, true)
        XCTAssertEqual(parakeet?.wordConfidence, true)
        XCTAssertEqual(parakeet?.vocabularyPrompt, false)
        XCTAssertEqual(catalog.model("nemotron-3-diarization/offline")?.capabilities.maxSpeakers, 8)
        XCTAssertFalse(ModelRouting.supportsVoiceMatching("nemotron-3-diarization/offline", catalog: catalog))
        XCTAssertTrue(catalog.model("community-1/offline")?.serves(.speakerEmbedding) == true)
        XCTAssertEqual(catalog.models(for: .speakerEmbedding).map(\.key), ["community-1/offline"])
    }

    func testLicensesFollowTheModelCards() throws {
        let catalog = ModelCatalog.builtIn
        XCTAssertEqual(catalog.model("whisper/small")?.license?.id, "MIT")
        XCTAssertEqual(catalog.model("qwen2.5/1.5b-4bit")?.license?.id, "Apache-2.0")
        XCTAssertEqual(catalog.model("qwen2.5/7b-4bit")?.license?.allowsCommercialUse, true)
        let research = try XCTUnwrap(catalog.model("qwen2.5/3b-4bit")?.license)
        XCTAssertEqual(research.name, "Qwen Research License")
        XCTAssertFalse(research.allowsCommercialUse, "3B is research and non-commercial use only")
        XCTAssertEqual(catalog.model("community-1/offline")?.license?.id, "CC-BY-4.0")
        XCTAssertEqual(catalog.model("sortformer-2.1/fp16")?.license?.name, "NVIDIA Open Model License")
        XCTAssertEqual(catalog.model("gemma-4/31b-8bit")?.license?.url, "https://ai.google.dev/gemma/docs/gemma_4_license")
        XCTAssertEqual(catalog.model("qwen3.6/35b-a3b-4bit")?.license?.id, "Apache-2.0")
        XCTAssertTrue(catalog.model("sortformer-2.1/fp16")?.license?.attribution?.contains("Licensed by NVIDIA Corporation") == true)
        let parakeet = try XCTUnwrap(catalog.model("parakeet/ultra")?.license)
        XCTAssertEqual(parakeet.id, "CC-BY-4.0")
        XCTAssertTrue(parakeet.allowsCommercialUse)
        XCTAssertTrue(parakeet.attribution?.contains("moondream/parakeet-ultra") == true)
        XCTAssertTrue(parakeet.attribution?.contains("nvidia/parakeet-tdt-0.6b-v3") == true)
        XCTAssertTrue(parakeet.attribution?.contains("converted to Core ML") == true, "CC BY asks that changes be indicated")
        let nemotron = try XCTUnwrap(catalog.model("nemotron-3-diarization/offline")?.license)
        XCTAssertEqual(nemotron.id, "OpenMDW-1.1")
        XCTAssertTrue(nemotron.allowsCommercialUse)
        XCTAssertTrue(nemotron.attribution?.contains("NVIDIA") == true)
    }

    func testManifestRoundTripsThroughEncoding() throws {
        let original = try ModelCatalog.readBuiltInManifest().manifest
        let encoded = try ModelManifestReader.encode(original)
        let decoded = try ModelManifestReader.read(encoded)
        XCTAssertEqual(decoded.manifest, original)
        XCTAssertTrue(decoded.warnings.isEmpty)
        XCTAssertEqual(try ModelManifestReader.encode(decoded.manifest), encoded, "Encoding is stable")
    }

    func testUnknownFieldsAreIgnoredAtEveryLevel() throws {
        let json = """
        {"schemaVersion": 1, "futureTopLevel": {"a": 1},
         "families": [{"id": "toy", "name": "Toy", "engine": "whisperKit", "roles": ["transcription"], "mascot": "owl",
           "variants": [{"id": "tiny", "name": "Toy Tiny", "sparkle": true,
             "capabilities": {"wordTimestamps": true, "teleportation": "yes"},
             "revisions": [{"id": "abc123", "signature": "zzz",
               "artifacts": [{"name": "model", "repository": "toy/tiny", "revision": "abc123", "mirror": "x",
                 "files": [{"path": "a.bin", "size": 3, "sha256": "\(String(repeating: "a", count: 64))", "blake3": "q"}]}]}]}]}]}
        """
        let result = try ModelManifestReader.read(Data(json.utf8))
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        let catalog = ModelCatalog(builtIn: result.manifest)
        XCTAssertEqual(catalog.model("toy/tiny")?.capabilities.wordTimestamps, true)
        XCTAssertEqual(catalog.model("toy/tiny")?.latestRevision?.artifacts.first?.files.first?.size, 3)
    }

    func testCatalogFolderLoadsEachFamilyFileOnItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let families = folder.appendingPathComponent("Families", isDirectory: true)
        try FileManager.default.createDirectory(at: families, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"schemaVersion": 1, "catalogVersion": "test"}"#.utf8).write(to: folder.appendingPathComponent("Catalog.json"))
        func family(_ id: String, minimumReaderVersion: Int = 1) -> Data {
            Data("""
            {"schemaVersion": 1, "minimumReaderVersion": \(minimumReaderVersion),
             "families": [{"id": "\(id)", "name": "\(id)", "engine": "whisperKit", "roles": ["transcription"],
               "variants": [{"id": "base", "name": "Base"}]}]}
            """.utf8)
        }
        try family("beta").write(to: families.appendingPathComponent("beta.json"))
        try family("alpha").write(to: families.appendingPathComponent("alpha.json"))
        try family("future", minimumReaderVersion: 99).write(to: families.appendingPathComponent("future.json"))
        try family("alpha").write(to: families.appendingPathComponent("zz-copy.json"))
        try Data("not JSON".utf8).write(to: families.appendingPathComponent("broken.json"))
        try Data("ignored".utf8).write(to: families.appendingPathComponent("README.txt"))

        let result = try ModelCatalog.readManifestFolder(folder)
        XCTAssertEqual(result.manifest.catalogVersion, "test")
        XCTAssertEqual(result.manifest.families.map(\.id), ["alpha", "beta"], "File-name order; the unreadable, newer, and duplicate files are skipped")
        XCTAssertEqual(result.warnings.count, 3, "\(result.warnings)")
        XCTAssertTrue(result.warnings.contains { $0.contains("future.json") && $0.contains("newer Daybook") })
    }

    func testNewerSchemaDegradesGracefully() throws {
        let json = """
        {"schemaVersion": 4, "minimumReaderVersion": 1,
         "families": [
           {"id": "good", "name": "Good", "engine": "whisperKit", "roles": ["transcription"],
            "variants": [
              {"id": "kept", "name": "Kept", "capabilities": {"maxSpeakers": "eight", "wordTimestamps": true},
               "revisions": [{"id": "r1", "artifacts": [{"name": "model", "repository": "good/kept", "revision": "r1",
                              "files": [{"path": "a", "size": 1, "gitOID": "\(String(repeating: "b", count: 40))"}]}]}]},
              {"id": "../escape", "name": "Escape", "revisions": []},
              {"id": "noname"},
              {"id": "unsafe-file", "name": "Unsafe",
               "revisions": [{"id": "r1", "artifacts": [{"name": "model", "repository": "good/unsafe", "revision": "r1",
                              "files": [{"path": "../../outside", "size": 1}]}]}]}
            ]},
           {"id": "future", "name": "Future", "engine": "quantumEngine", "roles": ["telepathy"], "variants": [
              {"id": "one", "name": "Future One", "minimumEngineVersion": "two", "revisions": []}]},
           "not even an object"
         ]}
        """
        let result = try ModelManifestReader.read(Data(json.utf8))
        XCTAssertTrue(result.warnings.first?.contains("schema 4") == true)
        XCTAssertGreaterThanOrEqual(result.warnings.count, 4, "\(result.warnings)")
        let catalog = ModelCatalog(builtIn: result.manifest)
        XCTAssertEqual(catalog.models.map(\.key), ["good/kept", "good/unsafe-file", "future/one"])
        let kept = try XCTUnwrap(catalog.model("good/kept"))
        XCTAssertNil(kept.capabilities.maxSpeakers, "A field typed differently is dropped, not the variant")
        XCTAssertEqual(kept.capabilities.wordTimestamps, true)
        XCTAssertTrue(try XCTUnwrap(catalog.model("good/unsafe-file")).variant.revisions.isEmpty, "A revision with an unsafe path is skipped whole")
        // A minimum this build can't read counts as unmet: offered as needing a newer Daybook, never run.
        let engines = [ModelEngineDescriptor(id: "quantumEngine", name: "Q", version: 99, runtime: "Q", roles: ["telepathy"], platforms: [.macOS, .iOS])]
        XCTAssertEqual(catalog.model("future/one")?.availability(engines: engines, appVersion: nil).label, "Needs a newer Daybook")
    }

    func testManifestsThatNeedANewerReaderAreRefused() {
        let json = #"{"schemaVersion": 7, "minimumReaderVersion": 5, "families": []}"#
        XCTAssertThrowsError(try ModelManifestReader.read(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ModelManifestError, .needsNewerDaybook(minimumReaderVersion: 5))
        }
    }

    func testAvailabilityExplainsWhatThisBuildCantRun() {
        let engines = [ModelEngineDescriptor(id: .whisperKit, name: "WhisperKit", version: 1, runtime: "WhisperKit 0.18.0",
                                             roles: [.transcription], platforms: [.macOS]),
                       ModelEngineDescriptor(id: .mlxLanguage, name: "MLX", version: 1, runtime: "mlx-swift-lm 2.29.3",
                                             roles: [.summarization], platforms: [.macOS])]
        func model(engine: ModelEngineID, app: String? = nil, engineVersion: Int? = nil) -> CatalogModel {
            let manifest = ModelManifest(families: [ModelFamilyEntry(id: "f", name: "F", engine: engine, roles: [.transcription], variants: [
                ModelVariantEntry(id: "v", name: "V", minimumAppVersion: app, minimumEngineVersion: engineVersion)])])
            return ModelCatalog(builtIn: manifest).models[0]
        }
        XCTAssertEqual(model(engine: .whisperKit).availability(engines: engines, appVersion: ModelVersion("0.1.0"), platform: .macOS), .available)
        XCTAssertEqual(model(engine: .whisperKit, app: "2.0").availability(engines: engines, appVersion: ModelVersion("1.9.3"), platform: .macOS),
                       .needsNewerApp(minimum: "2.0"))
        XCTAssertEqual(model(engine: .whisperKit, app: "2.0").availability(engines: engines, appVersion: nil, platform: .macOS), .available,
                       "A development build satisfies every minimum")
        XCTAssertEqual(model(engine: .mlxLanguage, engineVersion: 2).availability(engines: engines, appVersion: nil, platform: .macOS),
                       .needsNewerEngine(.mlxLanguage, minimum: 2, current: 1))
        XCTAssertEqual(model(engine: .parakeet).availability(engines: engines, appVersion: nil, platform: .macOS), .unknownEngine(.parakeet))
        XCTAssertEqual(model(engine: .parakeet).availability(engines: engines, appVersion: nil).label, "Needs a newer Daybook")
        XCTAssertEqual(model(engine: .whisperKit).availability(engines: engines, appVersion: nil, platform: .iOS), .unsupportedPlatform(.iOS))
        XCTAssertEqual(ModelAvailability.unsupportedPlatform(.iOS).label, "Not available on iPhone")
        // A system engine that can't run right now says why, in its own words.
        let off = engines + [ModelEngineDescriptor(id: .appleFoundationModels, name: "Apple", version: 1, runtime: "Foundation Models",
                                                   roles: [.smallTasks], platforms: [.macOS], unavailableReason: "Turn on Apple Intelligence")]
        XCTAssertEqual(model(engine: .appleFoundationModels).availability(engines: off, appVersion: nil, platform: .macOS),
                       .unavailableOnDevice(reason: "Turn on Apple Intelligence"))
        XCTAssertEqual(model(engine: .appleFoundationModels).availability(engines: off, appVersion: nil, platform: .macOS).label,
                       "Turn on Apple Intelligence")
    }

    func testUserManifestAddsModelsAndRevisionsWithoutOverridingBuiltIns() throws {
        let builtIn = try ModelCatalog.readBuiltInManifest().manifest
        let newRevision = ModelRevisionEntry(id: "f00d", releaseDate: "2026-11-01", artifacts: [
            ModelArtifact(name: "model", repository: "mlx-community/Qwen2.5-7B-Instruct-4bit", revision: "f00d",
                          files: [ModelFile(path: "model.safetensors", size: 10, sha256: String(repeating: "c", count: 64))])])
        let user = ModelManifest(families: [
            ModelFamilyEntry(id: "qwen2.5", name: "Renamed", variants: [
                ModelVariantEntry(id: "7b-4bit", name: "Should not rename", revisions: [newRevision]),
                ModelVariantEntry(id: "14b-4bit", name: "Qwen 2.5 · 14B", engine: .mlxLanguage, roles: [.summarization])]),
            ModelFamilyEntry(id: "gemma-4", name: "Renamed", variants: [
                ModelVariantEntry(id: "12b-8bit", name: "Gemma 4 · 12B · 8-bit", engine: .mlxLanguage, roles: [.summarization])]),
            ModelFamilyEntry(id: "ministral-3", name: "Ministral 3", engine: .mlxLanguage, roles: [.summarization], variants: [
                ModelVariantEntry(id: "8b-4bit", name: "Ministral 3 · 8B")])])
        let catalog = ModelCatalog(builtIn: builtIn, user: user)
        let qwen = try XCTUnwrap(catalog.model("qwen2.5/7b-4bit"))
        XCTAssertEqual(qwen.name, "Qwen 2.5 · 7B", "Built-in metadata wins")
        XCTAssertEqual(qwen.origin, .builtIn)
        XCTAssertEqual(qwen.latestRevision?.id, "f00d", "An installed update is the newest revision")
        XCTAssertEqual(qwen.userRevisionIDs, ["f00d"])
        XCTAssertEqual(qwen.revisions.count, 2)
        XCTAssertEqual(catalog.model("qwen2.5/14b-4bit")?.origin, .addedByYou)
        XCTAssertEqual(catalog.model("gemma-4/12b-8bit")?.origin.label, "Added by you")
        XCTAssertEqual(catalog.model("gemma-4/12b-8bit")?.familyName, "Gemma 4", "Joining a built-in family keeps its name")
        XCTAssertEqual(catalog.model("gemma-4/12b-4bit")?.origin, .builtIn)
        XCTAssertEqual(catalog.model("ministral-3/8b-4bit")?.origin.label, "Added by you")
        XCTAssertEqual(catalog.models(for: .summarization).count, ModelCatalog.builtIn.models(for: .summarization).count + 3)
        XCTAssertEqual(catalog.presets, ModelCatalog.builtIn.presets, "Presets come from the built-in manifest only")
    }

    func testVersionsCompareNumerically() {
        XCTAssertLessThan(ModelVersion("0.9.12")!, ModelVersion("0.10")!)
        XCTAssertEqual(ModelVersion("1.4")!, ModelVersion("1.4.0")!)
        XCTAssertNil(ModelVersion("one"))
        XCTAssertEqual(ModelReference("whisper/base@abc").revision, "abc")
        XCTAssertEqual(ModelReference("whisper/base@abc").id, "whisper/base")
        XCTAssertNil(ModelReference("legacy@id").revision, "Only variant keys take an @revision")
    }
}
