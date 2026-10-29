import DaybookCaptions
import DaybookKit
@testable import DaybookLive
import DaybookModelStore
import DaybookTestSupport
import XCTest

/// What live captions run where: the catalog's defaults per platform, which installs count, which
/// captioner a capture gets from what's installed, and when the device backs off.
final class LiveModelsTests: XCTestCase {
    // MARK: The catalog

    func testTheiPhoneDefaultsAreStreamingModelsItCanRun() throws {
        let catalog = ModelCatalog.builtIn
        XCTAssertTrue(catalog.warnings.isEmpty, "\(catalog.warnings)")
        let engines = LiveEngines.descriptors
        let transcription = LiveModelChoices.defaults(for: .liveTranscription, platform: .iOS, tier: .compact, catalog: catalog, engines: engines)
        let speakers = LiveModelChoices.defaults(for: .liveDiarization, platform: .iOS, tier: .compact, catalog: catalog, engines: engines)
        let voices = LiveModelChoices.defaults(for: .speakerEmbedding, platform: .iOS, tier: .compact, catalog: catalog, engines: engines)
        XCTAssertEqual(transcription.first, "nemotron-3.5-asr-streaming/latin-1120ms")
        XCTAssertEqual(speakers, ["nemotron-3-diarization/live"])
        XCTAssertEqual(voices, ["community-1/offline"])
        for key in transcription + speakers + voices {
            let model = try XCTUnwrap(catalog.model(key))
            XCTAssertEqual(model.availability(engines: engines, platform: .iOS), .available, key)
            XCTAssertEqual(model.license?.allowsCommercialUse, true, key)
            XCTAssertNotNil(model.license?.attribution, key)
        }
        for key in transcription + speakers {
            let model = try XCTUnwrap(catalog.model(key))
            XCTAssertEqual(model.capabilities.streaming, true, "\(key) streams")
            XCTAssertLessThan(model.approximateBytes, 700_000_000, "\(key) is a phone-sized download")
        }
        // The voice-profile model is the Mac's, so profiles made there compare here.
        XCTAssertEqual(catalog.model(voices[0])?.capabilities.voiceEmbeddings?.space, "fluid-community1-embedding-df2625ac79a7ac6b")
    }

    func testLiveModelsStayOutOfProcessingAndPresets() throws {
        let catalog = ModelCatalog.builtIn
        let live = try XCTUnwrap(catalog.model("nemotron-3-diarization/live"))
        XCTAssertEqual(live.roles, [.liveDiarization], "never offered for a transcript's speakers")
        for quality in ModelQuality.allCases {
            let preset = ModelRecommendations.preset(quality, tier: .standard, catalog: catalog)
            XCTAssertNil(preset.choices[.liveTranscription])
            XCTAssertNil(preset.choices[.liveDiarization])
        }
        XCTAssertFalse(ModelRole.known.contains(.liveTranscription))
    }

    func testAStoredChoiceWinsAndDefaultsFillTheRest() {
        var stored = ModelSelections([.summarization: "gemma-4/12b-4bit"])
        stored[.liveTranscription] = "nemotron-3.5-asr-streaming/multilingual-2240ms"
        let filled = LiveModelChoices.addingDefaults(to: stored, platform: .macOS)
        XCTAssertEqual(filled[.liveTranscription], "nemotron-3.5-asr-streaming/multilingual-2240ms")
        XCTAssertEqual(filled[.liveDiarization], "nemotron-3-diarization/live")
        XCTAssertEqual(filled[.summarization], "gemma-4/12b-4bit", "other roles are untouched")
        XCTAssertEqual(LiveModelChoices.choice(for: .liveTranscription, selections: ModelSelections([.liveTranscription: "whisper/base"]),
                                               platform: .iOS),
                       "nemotron-3.5-asr-streaming/latin-1120ms", "a choice that can't serve the role falls back to the default")
    }

    func testPerPlatformChoicesOverrideTiers() throws {
        let table = ModelChoiceTable(roles: ["liveTranscription": ["a"]], tiers: ["compact": ["liveTranscription": ["b"]]],
                                     platforms: ["iOS": ["liveTranscription": ["c"]]])
        XCTAssertEqual(table.choices(for: .liveTranscription, tier: "compact", platform: .iOS), ["c"])
        XCTAssertEqual(table.choices(for: .liveTranscription, tier: "compact", platform: .macOS), ["b"])
        XCTAssertEqual(table.choices(for: .liveTranscription, tier: "large", platform: .macOS), ["a"])
        let manifest = ModelManifest(liveSelection: table)
        let read = try ModelManifestReader.read(ModelManifestReader.encode(manifest)).manifest
        XCTAssertEqual(read.liveSelection, table, "round trips")
    }

    func testMemoryGuardsKeepBigModelsOffSmallPhones() throws {
        let model = try XCTUnwrap(ModelCatalog.builtIn.model("nemotron-3.5-asr-streaming/latin-1120ms"))
        XCTAssertFalse(LiveModelChoices.fitsMemory(model, physicalMemory: 4 * 1_073_741_824), "a 4 GB iPhone")
        XCTAssertTrue(LiveModelChoices.fitsMemory(model, physicalMemory: 7_500_000_000), "an 8 GB iPhone reports a little less")
    }

    // MARK: Installs

    /// A verified-looking install of `key` with `files` under its model folder (synthetic, empty).
    private func install(_ key: String, files: [String], root: URL) throws -> ModelInstallation {
        let catalog = ModelCatalog.builtIn
        let model = try XCTUnwrap(catalog.model(key))
        let revision = try XCTUnwrap(model.latestRevision)
        let receipt = ModelInstallReceipt(model: model, revision: revision)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installation = ModelInstallation(receipt: receipt, directory: directory)
        for file in files {
            let url = installation.folder(for: "model").appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return installation
    }

    func testInstallsAreCheckedForWhatLoadingNeeds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveModelsTests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let latin = "nemotron-3.5-asr-streaming/latin-1120ms"
        let complete = try install(latin, files: ["encoder.mlmodelc/coremldata.bin", "decoder_joint.mlmodelc/coremldata.bin",
                                                  "metadata.json", "tokenizer.json"], root: root)
        XCTAssertNoThrow(try LiveEngines.validate(complete, role: .liveTranscription))
        XCTAssertTrue(complete.folder(for: "model").path.hasSuffix("model/latin/1120ms"), "loads from the bundle's own folder")
        let partial = try install(latin, files: ["metadata.json"], root: root)
        XCTAssertThrowsError(try LiveEngines.validate(partial, role: .liveTranscription))
        let speakers = try install("nemotron-3-diarization/live", files: [
            "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/coremldata.bin", "learnable_sil_emb.bin", "pre_encode_proj_t.bin"], root: root)
        XCTAssertNoThrow(try LiveEngines.validate(speakers, role: .liveDiarization))
        XCTAssertEqual(LiveEngines.role(of: speakers), .liveDiarization)
        let voices = try install("community-1/offline", files: WeSpeakerEmbedder.requiredFiles, root: root)
        XCTAssertNoThrow(try LiveEngines.validate(voices, role: .speakerEmbedding))
    }

    func testTheLanguageDecidesWhichInstalledRecognizerRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveModelsTests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = ["encoder.mlmodelc/coremldata.bin", "decoder_joint.mlmodelc/coremldata.bin", "metadata.json", "tokenizer.json"]
        let latin = try install("nemotron-3.5-asr-streaming/latin-1120ms", files: files, root: root)
        let multilingual = try install("nemotron-3.5-asr-streaming/multilingual-2240ms", files: files, root: root)
        let inventory = ModelInventory(revisions: [InstalledModelRevision(installation: latin, state: .ready),
                                                   InstalledModelRevision(installation: multilingual, state: .ready)])
        let choices: [ModelRole: String] = [.liveTranscription: latin.key.variantKey]
        let alternatives = [latin.key.variantKey, multilingual.key.variantKey]
        let english = LiveModelSet.resolve(choices, inventory: inventory, locale: Locale(identifier: "en_GB"), alternatives: alternatives)
        XCTAssertEqual(english.transcription?.key, latin.key)
        let japanese = LiveModelSet.resolve(choices, inventory: inventory, locale: Locale(identifier: "ja_JP"), alternatives: alternatives)
        XCTAssertEqual(japanese.transcription?.key, multilingual.key, "the other installed recognizer covers Japanese")
        let welsh = LiveModelSet.resolve(choices, inventory: inventory, locale: Locale(identifier: "cy_GB"), alternatives: alternatives)
        XCTAssertFalse(welsh.transcribes(Locale(identifier: "cy_GB")), "neither covers Welsh: the system's recognizer captions it")
        // What Settings can offer without the Speech framework: every installed recognizer's languages, once each.
        let languages = LiveModelSet.languages(of: alternatives, inventory: inventory)
        XCTAssertEqual(Array(languages.prefix(6)), ["en", "es", "fr", "it", "pt", "de"])
        XCTAssertTrue(languages.contains("ja"))
        XCTAssertEqual(languages.count, Set(languages).count)
        let latinOnly = ModelInventory(revisions: [InstalledModelRevision(installation: latin, state: .ready)])
        XCTAssertFalse(LiveModelSet.languages(of: alternatives, inventory: latinOnly).contains("ja"))
    }

    // MARK: Which captioner

    func testWithoutLiveModelsCapturesKeepTheSystemsCaptions() {
        let captioners = LiveCaptioners(host: LiveModelHost(idleRelease: .zero), policy: .mac)
        let system = ScriptedCaptioner(lines: [])
        let chosen = captioners.captioner(models: LiveModelSet(), locale: .current, backlog: 8, fallback: { system })
        XCTAssertTrue(chosen === system)
        XCTAssertNil(captioners.captioner(models: LiveModelSet(), locale: .current, backlog: 8, fallback: { nil }),
                     "no captions where the system has none and nothing is downloaded")
    }

    func testASpeakerModelAloneLabelsTheSystemsWords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveModelsTests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let speakers = try install("nemotron-3-diarization/live", files: [], root: root)
        let captioners = LiveCaptioners(host: LiveModelHost(idleRelease: .zero), policy: .iPhone)
        let chosen = captioners.captioner(models: LiveModelSet(diarization: speakers), locale: .current, backlog: 8,
                                          fallback: { ScriptedCaptioner(lines: []) })
        XCTAssertTrue(chosen is SpeakerLabelledCaptioner)
    }

    func testAModelThatWontLoadLeavesNothingHeld() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveModelsTests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let empty = try install("nemotron-3-diarization/live", files: [], root: root)
        let host = LiveModelHost(idleRelease: .zero)
        let use = LiveModelUse(host: host)
        do { _ = try await use.diarization(empty); XCTFail("an empty folder has no model") } catch {}
        await use.release()
        let loaded = await host.loadedCount
        XCTAssertEqual(loaded, 0)
    }

    // MARK: Backing off

    func testTheiPhoneShedsSpeakersBeforeWordsAndWordsOnlyWhenItMust() {
        let policy = LiveLoadPolicy.iPhone
        XCTAssertEqual(policy.level(for: LiveConditions()), .full)
        XCTAssertEqual(policy.level(for: LiveConditions(thermal: .fair)), .full)
        XCTAssertEqual(policy.level(for: LiveConditions(thermal: .serious)), .transcriptionOnly)
        XCTAssertEqual(policy.level(for: LiveConditions(lowPowerMode: true)), .transcriptionOnly)
        XCTAssertEqual(policy.level(for: LiveConditions(batteryLevel: 0.15)), .transcriptionOnly)
        XCTAssertEqual(policy.level(for: LiveConditions(batteryLevel: 0.15, isCharging: true)), .full, "plugged in")
        XCTAssertEqual(policy.level(for: LiveConditions(isVisible: false)), .reduced, "in a pocket: speakers go on, at a lower cadence")
        XCTAssertEqual(policy.level(for: LiveConditions(lowPowerMode: true, isVisible: false)), .transcriptionOnly)
        XCTAssertEqual(policy.level(for: LiveConditions(batteryLevel: 0.05)), .paused)
        XCTAssertEqual(policy.level(for: LiveConditions(thermal: .critical, isCharging: true)), .paused)
        XCTAssertEqual(LiveLoadPolicy.mac.level(for: LiveConditions(isVisible: false)), .full, "a Mac saves captions for the page")
    }

    func testFallingBehindShedsSpeakersUntilTheBacklogDrains() {
        let governor = LiveLoadGovernor(policy: .mac, interval: 0, conditions: { LiveConditions() })
        XCTAssertEqual(governor.level(backlog: 0.1), .full)
        XCTAssertEqual(governor.level(backlog: 0.6), .transcriptionOnly)
        XCTAssertEqual(governor.level(backlog: 0.3), .transcriptionOnly, "not until it's well under")
        XCTAssertEqual(governor.level(backlog: 0.1), .full)
    }
}
