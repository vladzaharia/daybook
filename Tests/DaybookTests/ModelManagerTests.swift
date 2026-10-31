import DaybookCore
@testable import DaybookIntelligence
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// The model manager (Settings › Models): status, presets and Custom, the generic catalog (a
/// made-up engine, family, and role appear with no code), removal confirmations and fallbacks, and
/// the update and add flows against a scripted Hugging Face. Nothing is downloaded: installs are
/// synthetic receipts and sparse files in temporary libraries.
@MainActor
final class ModelManagerTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: A synthetic catalog

    private static let mit = ModelLicense(id: "MIT", name: "MIT License", url: "https://example.com/mit", allowsCommercialUse: true)
    private static let research = ModelLicense(id: "Research", name: "Research License", url: "https://example.com/r", allowsCommercialUse: false)

    private static func revision(_ id: String, repository: String, bytes: Int64, date: String = "2026-01-01") -> ModelRevisionEntry {
        ModelRevisionEntry(id: id, releaseDate: date, artifacts: [ModelArtifact(
            name: "model", repository: repository, revision: id, include: ["*"],
            files: [ModelFile(path: "weights.bin", size: bytes, sha256: String(repeating: "a", count: 64))])])
    }

    /// Whisper-like models on a real engine, a made-up "holo" engine serving a made-up "translation"
    /// role, a model on an engine this build doesn't have, an iPhone-only engine, and a system model.
    private static func catalog(user: ModelManifest? = nil) -> ModelCatalog {
        let builtIn = ModelManifest(
            families: [
                ModelFamilyEntry(id: "whisp", name: "Whisp", maker: "Acme", engine: .whisperKit, roles: [.transcription], license: mit, variants: [
                    ModelVariantEntry(id: "tiny", name: "Whisp Tiny", capabilities: .init(wordTimestamps: true, languages: ["*"]),
                                      revisions: [revision("t1", repository: "acme/whisp", bytes: 100_000_000)]),
                    ModelVariantEntry(id: "big", name: "Whisp Big", license: research, recommendedMemoryGB: 16,
                                      revisions: [revision("b1", repository: "acme/whisp-big", bytes: 1_600_000_000)])
                ]),
                ModelFamilyEntry(id: "babel", name: "Babel", maker: "Tower", engine: "holoEngine", roles: ["translation"], license: mit, variants: [
                    ModelVariantEntry(id: "one", name: "Babel One", capabilities: .init(languages: ["en", "fr", "de"]),
                                      revisions: [revision("o1", repository: "tower/babel", bytes: 50_000_000)]),
                    ModelVariantEntry(id: "future", name: "Babel Future", minimumEngineVersion: 9,
                                      revisions: [revision("f1", repository: "tower/babel-future", bytes: 70_000_000)])
                ]),
                ModelFamilyEntry(id: "ghost", name: "Ghost", engine: "notYetAnEngine", roles: [.transcription], license: mit, variants: [
                    ModelVariantEntry(id: "v1", name: "Ghost", revisions: [revision("g1", repository: "x/ghost", bytes: 10_000_000)])
                ]),
                ModelFamilyEntry(id: "pocket", name: "Pocket", engine: "phoneOnly", roles: [.transcription], license: mit, variants: [
                    ModelVariantEntry(id: "v1", name: "Pocket", revisions: [revision("p1", repository: "x/pocket", bytes: 10_000_000)])
                ]),
                ModelFamilyEntry(id: "os", name: "System Helper", maker: "Apple", engine: "osEngine", roles: [.smallTasks], license: mit, variants: [
                    ModelVariantEntry(id: "default", name: "System Helper", systemProvided: true)
                ])
            ],
            presets: [
                ModelPresetEntry(id: "quick", speakerQuality: "fast", choices: .init(roles: ["transcription": ["whisp/tiny"], "smallTasks": ["os/default"]])),
                ModelPresetEntry(id: "balanced", speakerQuality: "balanced", choices: .init(roles: ["transcription": ["whisp/big", "whisp/tiny"]])),
                ModelPresetEntry(id: "detailed", speakerQuality: "accurate", choices: .init(roles: ["transcription": ["whisp/big", "whisp/tiny"]]))
            ],
            recommendedPreset: .init(default: "balanced", tiers: ["compact": "quick"]))
        return ModelCatalog(builtIn: builtIn, user: user)
    }

    private static let engines: [ModelEngineDescriptor] = [
        ModelEngineDescriptor(id: .whisperKit, name: "WhisperKit", version: 1, runtime: "WhisperKit", roles: [.transcription], platforms: [.macOS, .iOS]),
        ModelEngineDescriptor(id: "holoEngine", name: "Holo", version: 1, runtime: "Holo 1.0", roles: ["translation"], platforms: [.macOS]),
        ModelEngineDescriptor(id: "phoneOnly", name: "Phone", version: 1, runtime: "Phone 1.0", roles: [.transcription], platforms: [.iOS]),
        ModelEngineDescriptor(id: "osEngine", name: "OS", version: 1, runtime: "macOS", roles: [.smallTasks], platforms: [.macOS])
    ]

    private func makeSnapshot(installed: Set<String> = [], selections: [ModelRole: String] = [:], user: ModelManifest? = nil) -> ModelManagerSnapshot {
        ModelManagerSnapshot(catalog: Self.catalog(user: user), engines: Self.engines, appVersion: nil, platform: .macOS, tier: .standard,
                             installed: installed, selections: ModelSelections(selections))
    }

    // MARK: Status

    func testStatusIsDerivedFromInstallsDownloadsUpdatesAndAvailability() throws {
        var snapshot = makeSnapshot(installed: ["whisp/tiny", "os/default"], selections: [.transcription: "whisp/tiny"])
        let catalog = snapshot.catalog
        func status(_ key: String) -> ModelStatus { snapshot.status(of: catalog.model(key)!) }

        XCTAssertEqual(status("whisp/tiny"), .inUse)
        XCTAssertEqual(status("whisp/big"), .notDownloaded)
        XCTAssertEqual(status("babel/one"), .notDownloaded)
        XCTAssertEqual(status("babel/future"), .unavailable("Needs a newer Daybook"), "Its engine is too old here")
        XCTAssertEqual(status("ghost/v1"), .unavailable("Needs a newer Daybook"), "No engine with that ID in this build")
        XCTAssertEqual(status("pocket/v1"), .unavailable("Not available on this Mac"))
        XCTAssertEqual(status("os/default"), .builtIn, "System models have nothing to download")
        XCTAssertEqual(ModelStatus.builtIn.label, "Included with macOS")

        snapshot.selections[.transcription] = "whisp/big"
        XCTAssertEqual(status("whisp/tiny"), .downloaded)
        snapshot.selections[.smallTasks] = "os/default"
        XCTAssertEqual(status("os/default"), .inUse)
        snapshot.installed.remove("os/default")
        XCTAssertEqual(status("os/default"), .unavailable("Not available on this Mac"), "The system doesn't provide it here")

        // Downloads and the queue, by key or "key@revision".
        snapshot.downloading = "whisp/big@b1"
        snapshot.downloadFraction = 0.4
        snapshot.pending = ["babel/one"]
        XCTAssertEqual(status("whisp/big"), .downloading(0.4))
        XCTAssertEqual(status("whisp/big").label, "Downloading · 40%")
        XCTAssertEqual(status("babel/one"), .waiting)

        // An update found for an installed model, until its revision is installed.
        let model = try XCTUnwrap(catalog.model("whisp/tiny"))
        let newer = Self.revision("t2", repository: "acme/whisp", bytes: 101_000_000, date: "2026-03-01")
        snapshot.updates = [ModelUpdate(model: "whisp/tiny", name: "Whisp Tiny", currentRevision: "t1", revision: newer,
                                        publishedAt: Date(timeIntervalSince1970: 1_772_323_200), changedFiles: ["model/weights.bin"])]
        XCTAssertEqual(status("whisp/tiny"), .updateAvailable)
        XCTAssertEqual(snapshot.row(model).update?.revision.id, "t2")
        XCTAssertEqual(ModelUpdateRow.detail(snapshot.updates[0]), "101 MB · \(Date(timeIntervalSince1970: 1_772_323_200).formatted(date: .abbreviated, time: .omitted)) · 1 file changed")
        snapshot.inventory = ModelInventory(revisions: [installed(model, newer)])
        XCTAssertEqual(snapshot.pendingUpdates, [], "Installed updates aren't offered again")
        XCTAssertEqual(status("whisp/tiny"), .downloaded)

        // Files that went missing since they were checked.
        snapshot.installed.remove("whisp/tiny")
        snapshot.inventory = ModelInventory(revisions: [installed(model, newer, damaged: true)])
        XCTAssertEqual(status("whisp/tiny"), .damaged)
        XCTAssertTrue(snapshot.row(model).canDownload)
    }

    func testLabelsComeFromLicensesAndOrigin() throws {
        let user = ModelManifest(families: [ModelFamilyEntry(id: "whisp", name: "Whisp", engine: .whisperKit, roles: [.transcription], variants: [
            ModelVariantEntry(id: "mine", name: "Whisp Mine", license: Self.mit, revisions: [Self.revision("m1", repository: "me/whisp", bytes: 5_000_000)])
        ])])
        let snapshot = makeSnapshot(user: user)
        XCTAssertEqual(snapshot.row(snapshot.catalog.model("whisp/big")!).labels, ["Non-commercial"])
        XCTAssertEqual(snapshot.row(snapshot.catalog.model("whisp/tiny")!).labels, [])
        let mine = snapshot.row(snapshot.catalog.model("whisp/mine")!)
        XCTAssertEqual(mine.labels, ["Added by you"])
        XCTAssertTrue(mine.isAddedByYou)
        XCTAssertEqual(snapshot.families.first { $0.id == "whisp" }?.rows.map(\.id), ["whisp/tiny", "whisp/big", "whisp/mine"],
                       "An added variant joins its family, after the built-in ones")
    }

    func testAModelThatServesNoRoleIsListedOnlyWhileItsHereToRemove() throws {
        // Qwen 2.5 1.5B since it stopped writing summaries: nothing to download or use, only to remove.
        let user = ModelManifest(families: [ModelFamilyEntry(id: "whisp", name: "Whisp", engine: .whisperKit, roles: [.transcription], variants: [
            ModelVariantEntry(id: "old", name: "Whisp Old", roles: [], license: Self.mit,
                              revisions: [Self.revision("o1", repository: "acme/whisp-old", bytes: 9_000_000)])
        ])])
        let absent = makeSnapshot(user: user)
        XCTAssertEqual(absent.families.first { $0.id == "whisp" }?.rows.map(\.id), ["whisp/tiny", "whisp/big"])
        XCTAssertFalse(absent.roleChoices.flatMap(\.options).contains { $0.key == "whisp/old" })
        let here = makeSnapshot(installed: ["whisp/old"], user: user)
        let row = try XCTUnwrap(here.families.first { $0.id == "whisp" }?.rows.first { $0.id == "whisp/old" })
        XCTAssertEqual(row.status, .downloaded)
        XCTAssertTrue(row.usableRoles.isEmpty)
        XCTAssertFalse(row.canUse)
    }

    // MARK: Generic catalog

    func testAMadeUpEngineFamilyAndRoleAppearWithoutCode() throws {
        let snapshot = makeSnapshot(installed: ["babel/one", "os/default"], selections: [.transcription: "whisp/tiny"])

        // Roles: the known ones that can run here, then the made-up role its engine serves.
        XCTAssertEqual(snapshot.choiceRoles, [.transcription, .smallTasks, "translation"])
        let translation = try XCTUnwrap(snapshot.roleChoices.first { $0.role == "translation" })
        XCTAssertEqual(translation.title, "Translation")
        XCTAssertEqual(translation.options.map(\.key), ["babel/one", "babel/future"])
        XCTAssertEqual(translation.options.map(\.isEnabled), [true, false], "Models that can't run here are listed, disabled")
        XCTAssertEqual(translation.options.map(\.detail), ["Downloaded", "Needs a newer Daybook"])
        let transcription = try XCTUnwrap(snapshot.roleChoices.first { $0.role == .transcription })
        XCTAssertEqual(transcription.options.map(\.key), ["whisp/tiny", "whisp/big", "ghost/v1", "pocket/v1"])
        XCTAssertEqual(transcription.options.map(\.detail), ["100 MB", "1.6 GB · Non-commercial", "Needs a newer Daybook", "Not available on this Mac"])
        XCTAssertEqual(snapshot.roleChoices.first { $0.role == .smallTasks }?.options.first?.detail, "Included with macOS")

        // The library: every family, pipeline order first, made-up ones included.
        XCTAssertEqual(snapshot.families.map(\.name), ["Ghost", "Pocket", "Whisp", "System Helper", "Babel"])
        let babel = try XCTUnwrap(snapshot.families.first { $0.id == "babel" })
        XCTAssertEqual(babel.rows.map(\.status), [.downloaded, .unavailable("Needs a newer Daybook")])
        XCTAssertEqual(babel.rows.first?.usableRoles, ["translation"])
        XCTAssertEqual(babel.rows.first?.subtitle, "Tower · 50 MB")
        XCTAssertEqual(snapshot.row(snapshot.catalog.model("os/default")!).subtitle, "Apple", "No size for a system model")

        // A role no engine here serves is listed in the library but never offered as a choice.
        var unknown = snapshot
        unknown.engines = Self.engines.filter { $0.id != "holoEngine" }
        XCTAssertFalse(unknown.choiceRoles.contains("translation"))
        XCTAssertNotNil(unknown.families.first { $0.id == "babel" })
        XCTAssertEqual(ModelRole("speakerEmbedding").title, "Voice profiles")
        XCTAssertEqual(ModelRole.words("imageCaptions"), "Image captions")
        XCTAssertEqual(ModelRole.words("image_captions"), "Image captions")
    }

    // MARK: Presets

    func testChoosingAPresetSetsEveryRoleItNamesAndChangesReadAsCustom() throws {
        let catalog = Self.catalog()
        var selections = ModelSelections([.transcription: "whisp/tiny", .smallTasks: "os/default", "translation": "babel/one"])
        XCTAssertTrue(ModelPreset.quick.matches(selections, speakerQuality: .fast, catalog: catalog, engines: Self.engines),
                      "Every role the preset names; others don't matter")
        XCTAssertFalse(ModelPreset.quick.matches(selections, speakerQuality: .accurate, catalog: catalog, engines: Self.engines),
                       "The speaker effort is part of the preset")
        selections[.smallTasks] = nil
        XCTAssertFalse(ModelPreset.quick.matches(selections, speakerQuality: .fast, catalog: catalog, engines: Self.engines))

        var snapshot = makeSnapshot(installed: ["whisp/tiny", "os/default"], selections: [.transcription: "whisp/tiny", .smallTasks: "os/default"])
        snapshot.speakerQuality = .fast
        XCTAssertEqual(snapshot.presets.map(\.title), ["Quick", "Balanced", "Detailed"])
        XCTAssertEqual(snapshot.presets.filter(\.isCurrent).map(\.title), ["Quick"])
        XCTAssertEqual(snapshot.presets.filter(\.isRecommended).map(\.title), ["Balanced"], "This tier's recommendation")
        XCTAssertEqual(snapshot.presets[0].names, ["Whisp Tiny", "System Helper"])
        XCTAssertEqual(snapshot.presets[0].bytes, 100_000_000, "System models download nothing")
        XCTAssertEqual(snapshot.presets[1].memoryGB, 16)

        snapshot.selections[.transcription] = "whisp/big"
        snapshot.speakerQuality = .balanced
        XCTAssertEqual(snapshot.presets.filter(\.isCurrent).map(\.title), ["Balanced"], "Balanced names only transcription")
        snapshot.speakerQuality = .fast
        XCTAssertEqual(snapshot.presets.map(\.title), ["Quick", "Balanced", "Detailed", "Custom"])
        XCTAssertEqual(snapshot.presets.last?.isCurrent, true)
        XCTAssertEqual(snapshot.presets.last?.keys, ["whisp/big", "os/default"])
    }

    func testAModelWithTwoRolesIsListedOnceInItsPreset() {
        let manifest = ModelManifest(
            families: [
                ModelFamilyEntry(id: "duet", name: "Duet", engine: "duetEngine", roles: [.diarization, .speakerEmbedding], license: Self.mit, variants: [
                    ModelVariantEntry(id: "v1", name: "Duet", revisions: [Self.revision("d1", repository: "x/duet", bytes: 30_000_000)])
                ])
            ],
            presets: [
                ModelPresetEntry(id: "quick", speakerQuality: "fast",
                                 choices: .init(roles: ["diarization": ["duet/v1"], "speakerEmbedding": ["duet/v1"]]))
            ])
        let engines = [ModelEngineDescriptor(id: "duetEngine", name: "Duet", version: 1, runtime: "Duet 1.0",
                                             roles: [.diarization, .speakerEmbedding], platforms: [.macOS])]
        let snapshot = ModelManagerSnapshot(catalog: ModelCatalog(builtIn: manifest, user: nil), engines: engines, appVersion: nil,
                                            platform: .macOS, tier: .standard, installed: [], selections: ModelSelections([:]))
        let quick = snapshot.presets.first { $0.preset == .quick }
        XCTAssertEqual(quick?.names, ["Duet"], "One model finding speakers and making voice profiles is named once")
        XCTAssertEqual(quick?.keys, ["duet/v1"])
        XCTAssertEqual(quick?.bytes, 30_000_000)
    }

    func testPresetsOnTheAppStateReadAsCustomOnceAModelChanges() throws {
        let state = AppState(libraryURL: try library(), defaults: defaults())
        ModelPreset.quick.apply(to: state)
        XCTAssertEqual(ModelPreset.current(in: state), .quick)
        XCTAssertEqual(state.processingPreferences.speakerOptions.quality, .fast)
        let manager = ModelManager(state: state, hubClient: ScriptedHub(), requestDownload: { _ in })
        XCTAssertEqual(manager.snapshot.presets.filter(\.isCurrent).map(\.title), ["Quick"])

        manager.use("whisper/small", for: .transcription)
        XCTAssertEqual(state.transcriptionModel, "whisper/small")
        XCTAssertNil(ModelPreset.current(in: state))
        XCTAssertEqual(manager.snapshot.presets.last?.title, "Custom")
        XCTAssertEqual(manager.snapshot.choice(for: .transcription).status, .notDownloaded, "Chosen anyway; it waits for a download")
        XCTAssertTrue(manager.missingSelected.contains("whisper/small"))

        manager.use("sortformer-2.1/compact", for: .diarization)
        XCTAssertEqual(state.processingPreferences.speakerModelID, "sortformer-2.1/compact", "The speaker choice stays in step")
        ModelPreset.quick.apply(to: state)
        XCTAssertEqual(ModelPreset.current(in: state), .quick)
    }

    // MARK: Removal

    func testRemovalConfirmationsSayWhatHappensToEachRole() throws {
        let catalog = Self.catalog()
        let preset = ModelRecommendations.preset(.balanced, catalog: catalog, engines: Self.engines)
        var snapshot = makeSnapshot(installed: ["whisp/tiny", "whisp/big"], selections: [.transcription: "whisp/big"])
        snapshot.diskUsage = ModelDiskUsage(installed: [ModelInstallKey(engine: "whisperKit", family: "whisp", variant: "big", revision: "b1"): 1_600_000_000],
                                            partial: [:], legacy: [:])

        let switching = snapshot.removal(of: catalog.model("whisp/big")!, removesEntry: false, preset: preset)
        XCTAssertEqual(switching.title, "Remove Whisp Big?")
        XCTAssertEqual(switching.message, "Frees 1.6 GB. Transcription will use Whisp Tiny.")
        XCTAssertEqual(switching.selections[.transcription], "whisp/tiny")

        snapshot.installed = ["whisp/big"]
        let waiting = snapshot.removal(of: catalog.model("whisp/big")!, removesEntry: false, preset: preset)
        XCTAssertEqual(waiting.message, "Frees 1.6 GB. Transcription will wait until you download it again.")
        XCTAssertEqual(waiting.selections[.transcription], "whisp/big", "Never switched silently")

        snapshot.installed = ["whisp/tiny", "whisp/big"]
        let unused = snapshot.removal(of: catalog.model("whisp/tiny")!, removesEntry: false, preset: preset)
        XCTAssertEqual(unused.message, "Frees 100 MB. You can download it again at any time.")

        // A model the person added, removed from Daybook while chosen: the preset's model stands in.
        let user = ModelManifest(families: [ModelFamilyEntry(id: "whisp", name: "Whisp", engine: .whisperKit, roles: [.transcription], variants: [
            ModelVariantEntry(id: "mine", name: "Whisp Mine", license: Self.mit, revisions: [Self.revision("m1", repository: "me/whisp", bytes: 5_000_000)])
        ])])
        var added = makeSnapshot(installed: ["whisp/mine"], selections: [.transcription: "whisp/mine"], user: user)
        added.installed = ["whisp/mine"]
        let entry = added.removal(of: added.catalog.model("whisp/mine")!, removesEntry: true, preset: preset)
        XCTAssertEqual(entry.title, "Remove Whisp Mine from Daybook?")
        XCTAssertEqual(entry.message, "Frees 5 MB. Transcription will use Whisp Big, once it’s downloaded.")
        XCTAssertEqual(entry.selections[.transcription], "whisp/big")
    }

    func testRemovingASelectedModelFallsBackToTheNextInstalledChoice() async throws {
        let root = try library()
        let state = AppState(libraryURL: root, defaults: defaults())
        ModelPreset.balanced.apply(to: state)
        // Balanced lists Parakeet first; choose a later entry so a fallback inside its list is left.
        state.modelSelections[.transcription] = "whisper/small"
        try installSynthetic(["whisper/small", "whisper/base"], in: root, catalog: state.modelCatalog)
        await state.refreshInstalledModels()
        XCTAssertTrue(state.installedModels.isSuperset(of: ["whisper/small", "whisper/base"]))
        let manager = ModelManager(state: state, hubClient: ScriptedHub(), requestDownload: { _ in })
        await manager.refresh()
        XCTAssertEqual(manager.snapshot.row(for: "whisper/small")?.status, .inUse)
        XCTAssertGreaterThanOrEqual(manager.snapshot.row(for: "whisper/small")?.bytesOnDisk ?? 0, state.modelCatalog.model("whisper/small")?.approximateBytes ?? 1)

        let removal = try XCTUnwrap(manager.removal(of: "whisper/small"))
        XCTAssertEqual(removal.message, "Frees 489 MB. Transcription will use Whisper Base.")
        await manager.confirm(removal)
        try await waitUntil("Whisper Small to be removed", state: { "installed \(state.installedModels.sorted())" }) {
            !state.installedModels.contains("whisper/small")
        }
        try await waitUntil("transcription to fall back to Whisper Base", state: { "\(state.transcriptionModel)" }) {
            state.transcriptionModel == "whisper/base"
        }
        XCTAssertEqual(state.notice, "Transcription now uses Whisper Base.")
        await manager.refresh()
        XCTAssertEqual(manager.snapshot.row(for: "whisper/small")?.status, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Models/whisperKit/whisper/small").path))
    }

    func testOldRevisionsAreOfferedForRemovalUnlessSomethingProtectsThem() async throws {
        let root = try library()
        let state = AppState(libraryURL: root, defaults: defaults())
        try installSynthetic(["whisper/base"], in: root, catalog: state.modelCatalog)
        try installSynthetic(["whisper/base"], in: root, catalog: state.modelCatalog, revisionID: "older", releaseDate: "2025-01-01")
        await state.refreshInstalledModels()
        let manager = ModelManager(state: state, hubClient: ScriptedHub(), requestDownload: { _ in })
        await manager.refresh()
        let storage = manager.snapshot.storage
        XCTAssertEqual(storage.removableRevisions.map(\.revision), ["older"])
        XCTAssertGreaterThan(storage.removableRevisionBytes, 100_000_000)
        XCTAssertGreaterThan(storage.total, storage.removableRevisionBytes)

        await manager.removeOldRevisions()
        XCTAssertEqual(manager.snapshot.storage.removableRevisions, [])
        XCTAssertEqual(manager.inventory.revisions(of: "whisper/base").count, 1)
    }

    // MARK: Updates

    func testCheckingForUpdatesShowsWhatChangedAndInstallingQueuesTheNewRevision() async throws {
        let root = try library()
        let state = AppState(libraryURL: root, defaults: defaults())
        try installSynthetic(["whisper/small"], in: root, catalog: state.modelCatalog)
        await state.refreshInstalledModels()
        let hub = ScriptedHub(catalog: state.modelCatalog, updating: "whisper/small")
        var requested: [String] = []
        let manager = ModelManager(state: state, hubClient: hub, requestDownload: { requested += $0 })
        await manager.refresh()
        XCTAssertEqual(manager.updateCheck, .never, "Nothing is checked until the person asks")

        await manager.checkForUpdates()
        guard case .checked = manager.updateCheck else { return XCTFail("\(manager.updateCheck)") }
        let update = try XCTUnwrap(manager.snapshot.pendingUpdates.first)
        XCTAssertEqual(manager.snapshot.pendingUpdates.count, 1)
        XCTAssertEqual(update.model, "whisper/small")
        XCTAssertEqual(update.changedFiles.count, 2)
        XCTAssertEqual(update.publishedAt, ScriptedHub.published)
        XCTAssertEqual(manager.snapshot.row(for: "whisper/small")?.status, .updateAvailable)
        XCTAssertTrue(ModelUpdateRow.detail(update).hasSuffix("2 files changed"))

        await manager.install(update)
        XCTAssertEqual(requested, ["whisper/small@\(ScriptedHub.newCommit)"], "Queued with the app's other downloads")
        XCTAssertEqual(state.modelCatalog.model("whisper/small")?.userRevisionIDs, [ScriptedHub.newCommit])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Models/UserModels.json").path))
        XCTAssertEqual(state.modelCatalog.model("whisper/small")?.latestRevision?.id, ScriptedHub.newCommit)
    }

    func testAnUpdateCheckThatCantReachHuggingFaceSaysSo() async throws {
        let root = try library()
        let state = AppState(libraryURL: root, defaults: defaults())
        try installSynthetic(["whisper/base"], in: root, catalog: state.modelCatalog)
        await state.refreshInstalledModels()
        let hub = ScriptedHub()
        hub.offline = true
        let manager = ModelManager(state: state, hubClient: hub, requestDownload: { _ in })
        await manager.checkForUpdates()
        XCTAssertEqual(manager.updateCheck, .failed("Couldn’t reach Hugging Face. Check your connection and try again."))
    }

    // MARK: Adding

    func testAddingShowsTheProposalThenAddsExactlyThatAndDownloadsIt() async throws {
        let root = try library()
        let state = AppState(libraryURL: root, defaults: defaults())
        let hub = ScriptedHub()
        hub.publishLanguageModel("someone/Tiny-Qwen-4bit", commit: "c0ffee")
        var requested: [String] = []
        let manager = ModelManager(state: state, hubClient: hub, requestDownload: { requested += $0 })

        let input = try XCTUnwrap(ModelRepositoryInput("https://huggingface.co/someone/Tiny-Qwen-4bit"))
        let preview = try await manager.preview(input)
        XCTAssertEqual(preview.commit.id, "c0ffee")
        XCTAssertEqual(preview.license.name, "Apache License 2.0")
        XCTAssertTrue(preview.license.allowsCommercialUse)
        let candidate = try XCTUnwrap(preview.candidates.first)
        XCTAssertEqual(preview.candidates.count, 1)
        XCTAssertEqual(candidate.engine.id, .mlxLanguage)
        XCTAssertEqual(candidate.role, .summarization)
        XCTAssertEqual(candidate.files.map(\.path), ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        XCTAssertEqual(candidate.bytes, candidate.files.reduce(0) { $0 + $1.size })
        XCTAssertNil(candidate.duplicateOf)
        XCTAssertTrue(preview.rejections.contains { $0.engine.id == .whisperKit }, "Every engine was asked")
        XCTAssertTrue(AddModelSheet.grouped(preview.rejections).allSatisfy { !$0.reasons.isEmpty })
        XCTAssertNil(state.modelCatalog.models.first { $0.origin == .addedByYou }, "Nothing is written before confirming")

        let added = try await manager.add(candidate, from: preview, name: "Tiny Qwen", input: input)
        XCTAssertEqual(added.origin, .addedByYou)
        XCTAssertEqual(added.latestRevision?.id, "c0ffee")
        XCTAssertEqual(requested, [added.key])
        XCTAssertEqual(manager.snapshot.row(for: added.key)?.labels, ["Added by you"])
        XCTAssertEqual(manager.snapshot.choice(for: .summarization).options.last?.key, added.key)

        // Checking the same repository again finds it's already there.
        let again = try await manager.preview(input)
        XCTAssertEqual(again.candidates.first?.duplicateOf, "Tiny Qwen")

        // Removing it from Daybook, while chosen, moves Summaries to the preset's model.
        manager.use(added.key, for: .summarization)
        let removal = try XCTUnwrap(manager.removal(of: added.key, removesEntry: true))
        XCTAssertTrue(removal.removesEntry)
        await manager.confirm(removal)
        XCTAssertNil(state.modelCatalog.model(added.key))
        XCTAssertNotEqual(state.summaryModel, added.key)
        XCTAssertNotNil(state.modelCatalog.model(state.summaryModel))
    }

    func testAddingExplainsWhatWentWrong() async throws {
        let state = AppState(libraryURL: try library(), defaults: defaults())
        let hub = ScriptedHub()
        let manager = ModelManager(state: state, hubClient: hub, requestDownload: { _ in })

        do {
            _ = try await manager.preview(ModelRepositoryInput(repository: "nobody/nothing"))
            XCTFail("Not found")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Hugging Face has no “nobody/nothing”. Check the name, and that the repository is public.")
        }
        hub.publishLanguageModel("someone/gated", commit: "g1", gated: true)
        do {
            _ = try await manager.preview(ModelRepositoryInput(repository: "someone/gated"))
            XCTFail("Gated")
        } catch {
            XCTAssertEqual(error.localizedDescription, "someone/gated requires accepting its terms on Hugging Face, so Daybook can’t download it.")
            XCTAssertNil((error as? ModelAdditionProblem)?.details)
        }
        // The system's own words go behind Details.
        let other = ModelAdditionProblem(CocoaError(.fileWriteOutOfSpace), input: ModelRepositoryInput(repository: "someone/big"))
        XCTAssertEqual(other.message, "Couldn’t add “someone/big”. Try again.")
        XCTAssertEqual(other.details, CocoaError(.fileWriteOutOfSpace).localizedDescription)
        hub.set("someone/notes", commit: "n1", files: ["README.md": "hello"])
        let preview = try await manager.preview(ModelRepositoryInput(repository: "someone/notes"))
        XCTAssertTrue(preview.candidates.isEmpty)
        XCTAssertEqual(Set(preview.rejections.map(\.engine.id)), Set(state.runtime.engines.map(\.id)), "Each engine says why not")
        hub.offline = true
        do {
            _ = try await manager.preview(ModelRepositoryInput(repository: "someone/notes"))
            XCTFail("Offline")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Couldn’t reach Hugging Face. Check your connection and try again.")
        }
    }

    func testRepositoryInputAcceptsNamesAndLinks() {
        XCTAssertEqual(ModelRepositoryInput("mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
                       ModelRepositoryInput(repository: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"))
        XCTAssertEqual(ModelRepositoryInput(" https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-tiny \n"),
                       ModelRepositoryInput(repository: "argmaxinc/whisperkit-coreml", revision: "main", folder: "openai_whisper-tiny"))
        XCTAssertEqual(ModelRepositoryInput("hf.co/owner/name/tree/dev"), ModelRepositoryInput(repository: "owner/name", revision: "dev"))
        XCTAssertEqual(ModelRepositoryInput("huggingface.co/owner/name?library=mlx"), ModelRepositoryInput(repository: "owner/name"))
        XCTAssertNil(ModelRepositoryInput("just-a-name"))
        XCTAssertNil(ModelRepositoryInput("owner/name/extra"))
        XCTAssertNil(ModelRepositoryInput("../etc"))
        XCTAssertEqual(ModelRepositoryInput("mlx-community/Qwen2.5-0.5B-Instruct-4bit")?.suggestedName, "Qwen2.5 0.5B Instruct 4bit")
    }

    // MARK: Details

    func testDetailsDescribeCapabilitiesAndResultsInPlainWords() throws {
        XCTAssertEqual(ModelCapabilities(wordTimestamps: true, wordConfidence: true, languages: ["*"], vocabularyPrompt: true).descriptions,
                       ["Word timings", "Word confidence", "Many languages", "Uses your vocabulary"])
        XCTAssertEqual(ModelCapabilities(languages: Array(repeating: "en", count: 25), maxSpeakers: 8).descriptions, ["25 languages", "Up to 8 speakers"])
        XCTAssertEqual(ModelCapabilities(voiceEmbeddings: VoiceEmbeddingSpace(space: "s"), expectedSpeakerCount: true).descriptions,
                       ["Voice profiles", "Expected number of speakers"])
        XCTAssertEqual(ModelCapabilities(contextLength: 32_768, structuredOutput: true).descriptions, ["32K context", "Structured output"])

        let catalog = ModelCatalog.builtIn
        let qwen = try XCTUnwrap(catalog.model("qwen2.5/7b-4bit"))
        let provenance = ModelProvenance(family: "qwen2.5", variant: "7b-4bit", revision: "r", engine: "mlxLanguage", engineVersion: "1")
        let meetings = [
            Meeting(transcripts: [TrackTranscript(trackID: UUID(), segments: [], modelID: "whisper-small")],
                    summary: MeetingSummary(overview: "", modelID: "qwen2.5/7b-4bit",
                                            processingSettings: ProcessingSettings(modelID: "qwen2.5/7b-4bit", model: provenance))),
            Meeting(transcripts: [TrackTranscript(trackID: UUID(), segments: [], modelID: "whisper-small"),
                                  TrackTranscript(trackID: UUID(), segments: [], modelID: "whisper-small")]),
            Meeting(summary: MeetingSummary(overview: "", modelID: "someone/gone"))
        ]
        XCTAssertEqual(catalog.resultCounts(in: meetings), ["whisper/small": 2, "qwen2.5/7b-4bit": 1, "someone/gone": 1],
                       "Counted once per conversation, legacy IDs and unlisted models included")
        XCTAssertNil(ModelDetailsSheet.unnamedFamily(qwen), "The title names the family and the variant")
        XCTAssertNil(ModelDetailsSheet.unnamedFamily(catalog.model("whisper/small")!))
        XCTAssertEqual(ModelDetailsSheet.unnamedFamily(catalog.model("nemotron-3-diarization/offline")!), "Nemotron 3 Diarization")
        XCTAssertEqual(ModelDetailsSheet.results(1), "1 conversation")
    }

    func testAcknowledgementsCreditEveryModelInTheAboutPanel() {
        let credits = AboutPanel.credits(.builtIn).string
        for entry in ModelAcknowledgements.list(from: .builtIn) {
            XCTAssertTrue(credits.contains(entry.title))
            XCTAssertTrue(credits.contains(entry.licenseName))
            if let attribution = entry.attribution { XCTAssertTrue(credits.contains(attribution)) }
        }
        XCTAssertTrue(credits.contains("Non-commercial"))
        XCTAssertEqual(credits.components(separatedBy: "Apple Vision").count - 1, 1, "A family of one model isn't named twice")
    }

    // MARK: Helpers

    private func library() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookModelManager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func defaults() -> UserDefaults {
        makeTestDefaults("local.daybook.tests.manager")
    }

    private func installed(_ model: CatalogModel, _ revision: ModelRevisionEntry, damaged: Bool = false) -> InstalledModelRevision {
        let receipt = ModelInstallReceipt(model: model, revision: revision)
        return InstalledModelRevision(installation: ModelInstallation(receipt: receipt, directory: URL(fileURLWithPath: "/nonexistent")),
                                      state: damaged ? .damaged("model/weights.bin") : .ready)
    }

    /// A verified-looking install: the receipt the store writes, and sparse files of the catalog's sizes.
    private func installSynthetic(_ keys: [String], in root: URL, catalog: ModelCatalog, revisionID: String? = nil,
                                  releaseDate: String? = nil) throws {
        for key in keys {
            let model = try XCTUnwrap(catalog.model(key))
            var revision = try XCTUnwrap(model.latestRevision)
            if let revisionID { revision.id = revisionID }
            if let releaseDate { revision.releaseDate = releaseDate }
            let folder = root.appendingPathComponent("Models/\(model.engine.rawValue)/\(model.familyID)/\(model.variant.id)/\(revision.id)")
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
            try JSONEncoder.receipts.encode(ModelInstallReceipt(model: model, revision: revision))
                .write(to: folder.appendingPathComponent(ModelInstallReceipt.fileName))
        }
    }
}

/// Hugging Face, scripted: the catalog's repositories at their pinned commits (one of them with a
/// newer commit where two files changed), and repositories a test publishes.
private final class ScriptedHub: ModelHubClient, @unchecked Sendable {
    static let newCommit = "feedbeef"
    static let published = Date(timeIntervalSince1970: 1_790_000_000)

    private let lock = NSLock()
    private var repositories: [String: (commit: ModelHubCommit, files: [ModelHubFile], data: [String: Data], info: ModelHubRepositoryInfo)] = [:]
    private let catalog: ModelCatalog?
    private let updating: String?
    private var _offline = false
    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    init(catalog: ModelCatalog? = nil, updating: String? = nil) { self.catalog = catalog; self.updating = updating }

    private var updatedArtifact: ModelArtifact? { updating.flatMap { catalog?.model($0) }?.latestRevision?.artifacts.first }

    func set(_ repository: String, commit: String, files: [String: String], license: String? = "apache-2.0", gated: Bool = false) {
        let listing = files.keys.sorted().map { path -> ModelHubFile in
            let data = Data(files[path]!.utf8)
            return path.hasSuffix(".json") ? ModelHubFile(path: path, size: Int64(data.count), gitOID: String(repeating: "1", count: 40))
                : ModelHubFile(path: path, size: Int64(data.count), sha256: String(repeating: "2", count: 64))
        }
        lock.withLock {
            repositories[repository] = (ModelHubCommit(id: commit, date: Self.published, title: "Upload"), listing,
                                        files.mapValues { Data($0.utf8) }, ModelHubRepositoryInfo(license: license, gated: gated))
        }
    }

    /// An MLX language model small enough for the pinned mlx-swift-lm to instantiate.
    func publishLanguageModel(_ repository: String, commit: String, gated: Bool = false) {
        set(repository, commit: commit, files: [
            "config.json": #"{"model_type": "qwen2", "hidden_size": 8, "num_hidden_layers": 1, "intermediate_size": 16, "num_attention_heads": 2, "num_key_value_heads": 1, "rms_norm_eps": 1e-6, "vocab_size": 32, "max_position_embeddings": 4096, "tie_word_embeddings": true}"#,
            "model.safetensors": "weights", "tokenizer.json": "{}", "tokenizer_config.json": "{}", "README.md": "not fetched"], gated: gated)
    }

    private func check() throws { if offline { throw URLError(.notConnectedToInternet) } }

    func commit(repository: String, reference: String) async throws -> ModelHubCommit {
        try check()
        if let published = lock.withLock({ repositories[repository] }) { return published.commit }
        if let artifact = updatedArtifact, artifact.repository == repository { return ModelHubCommit(id: Self.newCommit, date: Self.published, title: "Fix") }
        guard let pinned = artifacts(repository).first?.revision else { throw ModelHubError.notFound(repository) }
        return ModelHubCommit(id: pinned)
    }

    func files(repository: String, revision: String, path: String?) async throws -> [ModelHubFile] {
        try check()
        var files: [ModelHubFile]
        if let published = lock.withLock({ repositories[repository] }) {
            files = published.files
        } else {
            var seen = Set<String>()
            files = artifacts(repository).flatMap(\.files).filter { seen.insert($0.path).inserted }
                .map { ModelHubFile(path: $0.path, size: $0.size, sha256: $0.sha256, gitOID: $0.gitOID) }
            if revision == Self.newCommit, let artifact = updatedArtifact {
                let changed = Set(artifact.files.prefix(2).map(\.path))
                files = files.map { changed.contains($0.path) ? ModelHubFile(path: $0.path, size: $0.size + 1, sha256: String(repeating: "e", count: 64)) : $0 }
            }
        }
        guard let path else { return files }
        return files.filter { $0.path.hasPrefix(path + "/") }
    }

    func data(repository: String, revision: String, path: String, maxBytes: Int) async throws -> Data {
        try check()
        guard let data = lock.withLock({ repositories[repository]?.data[path] }) else { throw ModelHubError.notFound(path) }
        return data
    }

    func info(repository: String) async throws -> ModelHubRepositoryInfo {
        try check()
        return lock.withLock { repositories[repository]?.info } ?? ModelHubRepositoryInfo()
    }

    private func artifacts(_ repository: String) -> [ModelArtifact] {
        (catalog?.models ?? []).flatMap { $0.variant.revisions.flatMap(\.artifacts) }.filter { $0.repository == repository }
    }
}
