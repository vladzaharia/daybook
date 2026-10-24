import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// Selections by family and variant, presets from the manifest, fallbacks after removal, legacy
/// provenance, and acknowledgements.
final class ModelSelectionTests: XCTestCase {
    private let catalog = ModelCatalog.builtIn
    private let engines: [ModelEngineDescriptor] = [
        .init(id: .whisperKit, name: "WhisperKit", version: 1, runtime: "WhisperKit 0.18.0", roles: [.transcription], platforms: [.macOS, .iOS]),
        .init(id: .community1, name: "Community-1", version: 1, runtime: "FluidAudio 0.17.7", roles: [.diarization], platforms: [.macOS, .iOS]),
        .init(id: .sortformer, name: "Sortformer", version: 1, runtime: "FluidAudio 0.17.7", roles: [.diarization], platforms: [.macOS, .iOS]),
        .init(id: .mlxLanguage, name: "MLX", version: 1, runtime: "mlx-swift-lm 2.29.3", roles: [.summarization], platforms: [.macOS, .iOS],
              residency: .exclusive)]

    func testLegacyPreferencesMigrateToVariantKeys() {
        let defaults = ModelSelections([.transcription: "whisper/base", .diarization: "community-1/offline", .summarization: "qwen2.5/7b-4bit"])
        let migrated = ModelSelections.migrating(
            legacy: [.transcription: "whisper-large-turbo", .summarization: "qwen-3b", .diarization: "speaker-sortformer-v2.1-compact"],
            catalog: catalog, defaults: defaults)
        XCTAssertEqual(migrated[.transcription], "whisper/large-v3-turbo")
        XCTAssertEqual(migrated[.summarization], "qwen2.5/3b-4bit")
        XCTAssertEqual(migrated[.diarization], "sortformer-2.1/compact")

        let partial = ModelSelections.migrating(legacy: [.transcription: "my-own-model", .summarization: nil], catalog: catalog, defaults: defaults)
        XCTAssertEqual(partial[.transcription], "my-own-model", "An unknown ID is kept, never silently switched")
        XCTAssertEqual(partial[.summarization], "qwen2.5/7b-4bit", "A role with nothing stored takes the default")
        XCTAssertEqual(partial[.diarization], "community-1/offline")

        let data = try! JSONEncoder().encode(migrated)
        XCTAssertEqual(try JSONDecoder().decode(ModelSelections.self, from: data), migrated)
    }

    func testPresetsAndFirstLaunchChoicesComeFromTheManifest() {
        // Parakeet Ultra transcribes first in every preset; Nemotron 3 tells speakers apart in Balanced and
        // Detailed, with Community-1 making voice profiles; Quick keeps Community-1 (profiles in one pass).
        let quick = ModelRecommendations.preset(.quick, tier: .standard, catalog: catalog)
        XCTAssertEqual(quick.selections, ModelSelections([.transcription: "parakeet/ultra", .diarization: "community-1/offline",
                                                          .speakerEmbedding: "community-1/offline", .summarization: "gemma-4/e4b-4bit",
                                                          .smallTasks: "apple-foundation-models/system"]))
        XCTAssertEqual(quick.speakerQuality, "fast")
        let balanced = ModelRecommendations.preset(.balanced, tier: .compact, catalog: catalog)
        XCTAssertEqual(balanced.model(for: .transcription), "parakeet/ultra")
        XCTAssertEqual(balanced.choices[.diarization], ["nemotron-3-diarization/offline", "community-1/offline"])
        XCTAssertEqual(balanced.model(for: .summarization), "gemma-4/e4b-4bit")
        let detailed = ModelRecommendations.preset(.detailed, tier: .workstation, catalog: catalog)
        XCTAssertEqual(detailed.choices[.transcription], ["parakeet/ultra", "whisper/large-v3-turbo", "whisper/small", "whisper/base"])
        XCTAssertEqual(detailed.model(for: .speakerEmbedding), "community-1/offline")
        XCTAssertEqual(detailed.model(for: .summarization), "gemma-4/31b-8bit")
        XCTAssertEqual(ModelRecommendations.speech(for: .standard, quality: .detailed, catalog: catalog),
                       .init(transcription: "parakeet/ultra", diarization: "nemotron-3-diarization/offline"))
        // A build without the new engines falls back to the next choice.
        XCTAssertEqual(ModelRecommendations.preset(.detailed, catalog: catalog, engines: engines, appVersion: nil).model(for: .transcription),
                       "whisper/large-v3-turbo")
        XCTAssertEqual(ModelRecommendations.preset(.balanced, catalog: catalog, engines: engines, appVersion: nil).model(for: .diarization),
                       "community-1/offline")

        // Gemma 4 first on every tier: E2B/E4B on compact Macs, 12B on standard, 26B A4B on large, 31B for Detailed on workstations.
        let summaries = DeviceTier.allCases.map { tier in ModelQuality.allCases.map { ModelRecommendations.summary(for: tier, quality: $0, catalog: catalog) } }
        XCTAssertEqual(summaries, [
            ["gemma-4/e2b-4bit", "gemma-4/e4b-4bit", "gemma-4/e4b-4bit"],
            ["gemma-4/e4b-4bit", "gemma-4/12b-4bit", "gemma-4/12b-4bit"],
            ["gemma-4/e4b-4bit", "gemma-4/26b-a4b-qat-4bit", "gemma-4/26b-a4b-qat-4bit"],
            ["gemma-4/12b-4bit", "gemma-4/26b-a4b-qat-4bit", "gemma-4/31b-8bit"]])
        // Qwen 2.5 stays in every list, after the newer models, so an installed one can stand in.
        for tier in DeviceTier.allCases {
            for quality in ModelQuality.allCases {
                let choices = ModelRecommendations.preset(quality, tier: tier, catalog: catalog).choices[.summarization] ?? []
                XCTAssertTrue(choices.first?.hasPrefix("gemma-4/") == true, "\(tier) \(quality)")
                XCTAssertTrue(Set(["qwen2.5/1.5b-4bit", "qwen2.5/3b-4bit", "qwen2.5/7b-4bit"]).isSubset(of: choices), "\(tier) \(quality)")
                let firstOlder = choices.firstIndex { $0.hasPrefix("qwen2.5/") } ?? 0
                XCTAssertTrue(choices[..<firstOlder].allSatisfy { !$0.hasPrefix("qwen2.5/") })
                XCTAssertTrue(choices[firstOlder...].allSatisfy { $0.hasPrefix("qwen2.5/") }, "\(tier) \(quality): Qwen 2.5 comes last")
            }
        }

        XCTAssertEqual(ModelRecommendations.recommendedQuality(for: .compact, catalog: catalog), .quick)
        XCTAssertEqual(ModelRecommendations.recommendedQuality(for: .standard, catalog: catalog), .balanced)
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .standard, catalog: catalog)[.summarization], "gemma-4/12b-4bit")
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .compact, catalog: catalog)[.summarization], "gemma-4/e2b-4bit")
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .large, catalog: catalog)[.summarization], "gemma-4/26b-a4b-qat-4bit")
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .workstation, catalog: catalog)[.summarization], "gemma-4/26b-a4b-qat-4bit")
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .compact, catalog: catalog)[.transcription], "parakeet/ultra")
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .standard, catalog: catalog)[.diarization], "community-1/offline")
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .standard, catalog: catalog, engines: engines)[.transcription], "whisper/base")
        XCTAssertEqual(DeviceTier(memoryGB: 16), .standard)
        XCTAssertEqual(DeviceTier(memoryGB: 8), .compact)
    }

    func testSmallTasksStartWithAppleIntelligenceWhereItIsAvailable() {
        for tier in DeviceTier.allCases {
            XCTAssertEqual(ModelRecommendations.initialSelections(for: tier, catalog: catalog)[.smallTasks], "apple-foundation-models/system")
        }
        let apple = ModelEngineDescriptor(id: .appleFoundationModels, name: "Apple", version: 1, runtime: "Foundation Models",
                                          roles: [.smallTasks], platforms: [.macOS, .iOS])
        var off = apple
        off.unavailableReason = "Turn on Apple Intelligence"
        XCTAssertEqual(ModelRecommendations.initialSelections(for: .standard, catalog: catalog, engines: engines + [apple])[.smallTasks],
                       "apple-foundation-models/system")
        XCTAssertNil(ModelRecommendations.initialSelections(for: .standard, catalog: catalog, engines: engines + [off])[.smallTasks],
                     "Where it isn't available, nothing is selected and the summarizer keeps doing it")
        XCTAssertNil(ModelRecommendations.initialSelections(for: .standard, catalog: catalog, engines: engines)[.smallTasks],
                     "A build without the engine selects nothing")
    }

    func testPresetsPassOverModelsThisBuildCantRun() throws {
        XCTAssertEqual(ModelRecommendations.preset(.balanced, tier: .standard, catalog: catalog).model(for: .summarization), "gemma-4/12b-4bit",
                       "Without engines, every listed model counts")
        XCTAssertEqual(ModelRecommendations.preset(.balanced, tier: .standard, catalog: catalog, engines: engines, appVersion: nil)
                        .model(for: .summarization),
                       "qwen2.5/7b-4bit", "A build whose MLX engine is version 1 passes over Gemma 4 and Qwen 3.x to Qwen 2.5")
    }

    func testRemovingASelectedModelFallsBackToThePresetsNextInstalledChoice() {
        let detailed = ModelRecommendations.preset(.detailed, tier: .standard, catalog: catalog)
        let selections = detailed.selections
        let switched = selections.removing("parakeet/ultra", preset: detailed,
                                           installed: ["whisper/base", "whisper/small", "community-1/offline", "gemma-4/12b-4bit"])
        XCTAssertEqual(switched.selections[.transcription], "whisper/small")
        XCTAssertEqual(switched.changes, [.switched(role: .transcription, from: "parakeet/ultra", to: "whisper/small")])
        let speakers = selections.removing("nemotron-3-diarization/offline", preset: detailed, installed: ["community-1/offline"])
        XCTAssertEqual(speakers.selections[.diarization], "community-1/offline")
        XCTAssertEqual(switched.selections[.summarization], "gemma-4/12b-4bit", "Other roles keep their models")

        let waiting = selections.removing("gemma-4/12b-4bit", preset: detailed, installed: ["parakeet/ultra"])
        XCTAssertEqual(waiting.selections, selections, "Nothing installed can stand in: the choice stays and waits for a download")
        XCTAssertEqual(waiting.changes, [.needsDownload(role: .summarization, model: "gemma-4/12b-4bit")])

        // A Qwen 2.5 model installed before the upgrade still stands in.
        let older = selections.removing("gemma-4/12b-4bit", preset: detailed, installed: ["qwen2.5/7b-4bit"])
        XCTAssertEqual(older.changes, [.switched(role: .summarization, from: "gemma-4/12b-4bit", to: "qwen2.5/7b-4bit")])

        let unrelated = selections.removing("sortformer-2.1/fp16", preset: detailed, installed: [])
        XCTAssertTrue(unrelated.changes.isEmpty)
    }

    func testRoutingUsesCapabilitiesNotModelIDs() throws {
        var manifest = try ModelCatalog.readBuiltInManifest().manifest
        manifest.families.append(ModelFamilyEntry(id: "nemotron-3", name: "Nemotron 3 Diarization", engine: .nemotronDiarizer, roles: [.diarization],
                                                  variants: [ModelVariantEntry(id: "offline", name: "Nemotron 3", capabilities: .init(maxSpeakers: 8))]))
        manifest.families.append(ModelFamilyEntry(id: "wespeaker", name: "WeSpeaker", engine: .community1, roles: [.speakerEmbedding], variants: [
            ModelVariantEntry(id: "resnet34", name: "WeSpeaker ResNet34",
                              capabilities: .init(voiceEmbeddings: .init(space: "fluid-community1-embedding-df2625ac79a7ac6b", dimensions: 256)))]))
        let catalog = ModelCatalog(builtIn: manifest)
        let selections = ModelSelections([.diarization: "nemotron-3/offline", .speakerEmbedding: "wespeaker/resnet34"])
        let nemotron = engines + [ModelEngineDescriptor(id: .nemotronDiarizer, name: "Nemotron", version: 1, runtime: "FluidAudio 0.17.7",
                                                        roles: [.diarization], platforms: [.macOS])]
        XCTAssertEqual(ModelRouting.voiceEmbedder(diarizer: "nemotron-3/offline", selections: selections, catalog: catalog,
                                                  engines: nemotron, appVersion: nil), "wespeaker/resnet34",
                       "A diarizer without voice profiles gets them from the embedding model")
        XCTAssertNil(ModelRouting.voiceEmbedder(diarizer: "community-1/offline", selections: selections, catalog: catalog,
                                                engines: nemotron, appVersion: nil), "Community-1 embeds voices itself")
        XCTAssertNil(ModelRouting.voiceEmbedder(diarizer: "nemotron-3/offline", selections: ModelSelections([.diarization: "nemotron-3/offline"]),
                                                catalog: catalog, engines: nemotron, appVersion: nil))
        XCTAssertFalse(ModelRouting.supportsVoiceMatching("nemotron-3/offline", catalog: catalog))
    }

    func testLegacyProvenanceStillNamesOldResults() throws {
        XCTAssertEqual(catalog.name(for: "whisper-base"), "Whisper Base")
        XCTAssertEqual(catalog.name(for: "speaker-sortformer-v2.1-compact"), "Sortformer 2.1 · Compact")
        XCTAssertEqual(catalog.name(for: "qwen2.5/7b-4bit"), "Qwen 2.5 · 7B")
        let legacy = try XCTUnwrap(catalog.provenance(forStoredModelID: "qwen-7b"))
        XCTAssertEqual(legacy, ModelProvenance(family: "qwen2.5", variant: "7b-4bit", revision: "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed",
                                               engine: "mlxLanguage", engineVersion: "legacy", name: "Qwen 2.5 · 7B",
                                               repository: "mlx-community/Qwen2.5-7B-Instruct-4bit"))
        // An old meeting's stored settings: no provenance recorded, only the legacy ID.
        let stored = Data(#"{"modelID":"whisper-small","parameters":{"mode":"newAudio"},"createdAt":0}"#.utf8)
        let settings = try JSONDecoder().decode(ProcessingSettings.self, from: stored)
        XCTAssertNil(settings.model)
        XCTAssertEqual(catalog.provenance(of: settings, modelID: "whisper-small")?.variantKey, "whisper/small")
        XCTAssertEqual(catalog.provenance(of: settings, modelID: "whisper-small")?.revision, "0f63a7800b00dd0226abd051b906c246e1907482")

        // A model only another Mac knew is named by what its provenance recorded.
        let elsewhere = ModelProvenance(family: "gemma-4", variant: "12b-4bit", revision: "abc", engine: "mlxLanguage",
                                        engineVersion: "2 (mlx-swift-lm 3.32.3)", name: "Gemma 4 · 12B")
        XCTAssertEqual(catalog.name(for: "gemma-4/12b-4bit", provenance: elsewhere), "Gemma 4 · 12B")
        XCTAssertEqual(catalog.name(for: "unknown-model"), "unknown-model")
    }

    func testProvenanceRoundTripsAndToleratesDamage() throws {
        let provenance = ModelProvenance(family: "whisper", variant: "base", revision: "0f63", engine: "whisperKit",
                                         engineVersion: "1 (WhisperKit 0.18.0)", name: "Whisper Base", repository: "argmaxinc/whisperkit-coreml")
        let settings = ProcessingSettings(modelID: "whisper/base", parameters: ["mode": "newAudio"], createdAt: Date(timeIntervalSince1970: 5),
                                          model: provenance)
        let decoded = try JSONDecoder().decode(ProcessingSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        let legacyEncoding = try JSONEncoder().encode(ProcessingSettings(modelID: "x", createdAt: Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(String(decoding: legacyEncoding, as: UTF8.self).contains("model\""), "Results without provenance encode as before")
        let damaged = Data(#"{"modelID":"whisper/base","parameters":{},"createdAt":0,"model":{"family":7}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ProcessingSettings.self, from: damaged).model, "Damaged provenance never makes a meeting unreadable")
    }

    func testAcknowledgementsAreGeneratedFromTheManifests() {
        let list = ModelAcknowledgements.list(from: catalog)
        XCTAssertEqual(list.map(\.title), ["Apple Foundation Models", "Community-1", "Gemma 4", "Nemotron 3 Diarization", "Parakeet",
                                             "Qwen 2.5", "Qwen 2.5", "Qwen 3.5", "Qwen 3.6", "Sortformer 2.1", "Whisper"])
        XCTAssertEqual(list.first { $0.title == "Parakeet" }?.models, ["Parakeet Ultra", "Parakeet Redux"])
        XCTAssertEqual(list.first { $0.title == "Nemotron 3 Diarization" }?.licenseName, "OpenMDW License 1.1")
        XCTAssertTrue(list.first { $0.title == "Nemotron 3 Diarization" }?.attribution?.contains("third-party notices") == true)
        XCTAssertEqual(list.first { $0.title == "Gemma 4" }?.models.count, 5)
        XCTAssertEqual(list.first { $0.title == "Gemma 4" }?.licenseName, "Apache License 2.0")
        let qwen = list.filter { $0.title == "Qwen 2.5" }
        XCTAssertEqual(qwen.map(\.models), [["Qwen 2.5 · 1.5B", "Qwen 2.5 · 7B"], ["Qwen 2.5 · 3B"]])
        XCTAssertEqual(qwen.map(\.label), [nil, "Non-commercial"])
        XCTAssertTrue(list.first { $0.title == "Sortformer 2.1" }?.attribution?.contains("NVIDIA Open Model License") == true)
        XCTAssertEqual(list.first { $0.title == "Community-1" }?.licenseName, "CC BY 4.0 (scoped)")
        XCTAssertTrue(list.allSatisfy { !$0.licenseURL.isEmpty })

        let installed = ModelAcknowledgements.list(from: catalog, only: ["whisper/base", "qwen2.5/3b-4bit"])
        XCTAssertEqual(installed.map(\.title), ["Qwen 2.5", "Whisper"])
        XCTAssertTrue(ModelAcknowledgements.text(from: catalog, only: ["qwen2.5/3b-4bit"]).contains("Qwen Research License (Non-commercial)"))
    }
}
