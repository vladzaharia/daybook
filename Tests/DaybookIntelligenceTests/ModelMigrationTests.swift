import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Installs from before the model system (`Models/<legacy ID>/`) move into the store without a
/// download, verified, idempotently, and resumably.
final class ModelMigrationTests: XCTestCase {
    private var root: URL!

    override func setUp() { root = SyntheticModels.temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// A catalog whose toy revision was once installed as `toy-small`, laid out the way the old
    /// runtime's HubApi snapshots laid it out.
    private func legacyFixture(markerRevision: String? = nil) throws -> (catalog: ModelCatalog, contents: [String: Data]) {
        let (model, modelContents) = SyntheticModels.artifact("model", repository: "toy/models", revision: "rev-a", root: "toy_small",
                                                              files: [("toy_small/Encoder.bin", "encoder"), ("toy_small/config.json", "{}"),
                                                                      ("toy_small/Decoder.bin", "decoder")])
        let (tokenizer, tokenizerContents) = SyntheticModels.artifact("tokenizer", repository: "toy/tokenizer", revision: "tok-1",
                                                                      files: [("tokenizer.json", "{\"vocab\": 1}")])
        let revision = ModelRevisionEntry(id: "rev-a", releaseDate: "2026-01-01", artifacts: [model, tokenizer],
                                          legacy: ModelLegacyInstall(ids: ["toy-small"], artifactPaths: ["model": "models/toy/models",
                                                                                                        "tokenizer": "models/toy/tokenizer"]))
        let catalog = ModelCatalog(builtIn: SyntheticModels.manifest(revisions: [revision]))
        let legacy = root.appendingPathComponent("toy-small", isDirectory: true)
        var inventory: [String: Int64] = [:]
        for (artifact, base) in [(model, "models/toy/models"), (tokenizer, "models/toy/tokenizer")] {
            for file in artifact.files {
                let relative = "\(base)/\(file.path)"
                let url = legacy.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (modelContents.merging(tokenizerContents) { $1 })[FakeFetcher.key(artifact.repository, artifact.revision, file.path)]!.write(to: url)
                inventory[relative] = file.size
            }
        }
        // What HubApi and the old runtime left beside the weights.
        let cache = legacy.appendingPathComponent("models/toy/models/.cache/huggingface/download/toy_small/Encoder.bin.metadata")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("rev-a\netag\n0\n".utf8).write(to: cache)
        try Data("unused".utf8).write(to: legacy.appendingPathComponent("models/toy/tokenizer/README.md"))
        struct Marker: Encodable { let modelID: String; let revision: String; let modelPath: String; let tokenizerPath: String?; let files: [String: Int64] }
        try JSONEncoder().encode(Marker(modelID: "toy-small", revision: markerRevision ?? "rev-a", modelPath: "models/toy/models/toy_small",
                                        tokenizerPath: "models/toy/tokenizer", files: inventory))
            .write(to: legacy.appendingPathComponent("installed.json"))
        return (catalog, modelContents.merging(tokenizerContents) { $1 })
    }

    private func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    func testLegacyInstallsMoveIntoTheStoreWithoutDownloading() async throws {
        let (catalog, _) = try legacyFixture()
        let encoder = root.appendingPathComponent("toy-small/models/toy/models/toy_small/Encoder.bin")
        let before = try inode(encoder)
        let fetcher = FakeFetcher()   // serves nothing: a download attempt would fail
        let log = CallLog()
        let runtime = LocalIntelligenceRuntime(modelsDirectory: root, registry: ModelEngineRegistry([ToyTranscriptionEngine(log: log)]),
                                               builtIn: .init(manifest: SyntheticModels.manifest(revisions: catalog.models[0].variant.revisions)),
                                               fetcher: fetcher)
        let report = await runtime.prepare()
        XCTAssertEqual(report.migrated, ["toy-small": ModelInstallKey(engine: "toyEngine", family: "toy", variant: "small", revision: "rev-a")])
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(fetcher.calls, 0, "Nothing was downloaded")

        let installed = await runtime.installedModels()
        XCTAssertEqual(installed, ["toy/small"])
        let revision = root.appendingPathComponent("toyEngine/toy/small/rev-a")
        let moved = revision.appendingPathComponent("model/toy_small/Encoder.bin")
        XCTAssertEqual(try inode(moved), before, "Files were moved, not copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: revision.appendingPathComponent("tokenizer/tokenizer.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: revision.appendingPathComponent("tokenizer/README.md").path), "Leftovers go")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("toy-small").path))
        let receipt = try JSONDecoder.receipts.decode(ModelInstallReceipt.self, from: Data(contentsOf: revision.appendingPathComponent("receipt.json")))
        XCTAssertEqual(receipt.migratedFrom, "toy-small")

        // And it runs: the legacy ID still names the model.
        let result = try await runtime.transcribe(url: root.appendingPathComponent("unused.wav"), model: "toy-small")
        XCTAssertEqual(result.provenance?.revision, "rev-a")
        XCTAssertEqual(log.calls, ["load toy/small@rev-a", "transcribe toy/small"])
    }

    func testMigrationIsIdempotent() async throws {
        let (catalog, _) = try legacyFixture()
        let store = ModelStore(root: root)
        let first = await store.migrateLegacyInstalls(catalog: catalog)
        XCTAssertEqual(first.migrated.count, 1)
        let second = await store.migrateLegacyInstalls(catalog: catalog)
        XCTAssertTrue(second.isEmpty, "Nothing left to do")
        let inventory = await store.inventory()
        XCTAssertEqual(inventory.usableVariantKeys, ["toy/small"])

        // A stray legacy copy of an already-migrated revision is removed, not moved over it.
        _ = try legacyFixture()
        let third = await store.migrateLegacyInstalls(catalog: catalog)
        XCTAssertEqual(third.alreadyInstalled, ["toy-small"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("toy-small").path))
    }

    func testAnInterruptedMigrationResumes() async throws {
        let (catalog, _) = try legacyFixture()
        // As if the app quit after moving the folder and one file into the new layout.
        let work = root.appendingPathComponent(".staging/migrate-toy-small", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("toy-small"), to: work.appendingPathComponent("legacy"))
        let movedFile = work.appendingPathComponent("new/model/toy_small/Encoder.bin")
        try FileManager.default.createDirectory(at: movedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: work.appendingPathComponent("legacy/models/toy/models/toy_small/Encoder.bin"), to: movedFile)

        let store = ModelStore(root: root)
        let report = await store.migrateLegacyInstalls(catalog: catalog)
        XCTAssertEqual(report.migrated.keys.sorted(), ["toy-small"])
        let inventory = await store.inventory()
        XCTAssertEqual(inventory.resolvedRevisions, ["toy/small": "rev-a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testMismatchedLegacyFilesStayWhereTheyAre() async throws {
        let (catalog, _) = try legacyFixture()
        let decoder = root.appendingPathComponent("toy-small/models/toy/models/toy_small/Decoder.bin")
        try Data("DECODER".utf8).write(to: decoder)   // same length, different content
        let store = ModelStore(root: root)
        let report = await store.migrateLegacyInstalls(catalog: catalog)
        XCTAssertEqual(report.failed["toy-small"], "model/toy_small/Decoder.bin is missing or doesn’t match the catalog.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoder.path), "Nothing moved")
        let inventory = await store.inventory()
        XCTAssertTrue(inventory.revisions.isEmpty)
        let usage = await store.diskUsage()
        XCTAssertGreaterThan(usage.legacy["toy-small"] ?? 0, 0, "The old folder is counted so it can be removed")
        let removed = await store.removeLegacyLeftovers()
        XCTAssertEqual(removed, ["toy-small"])
    }

    func testIncompleteOrOtherRevisionLegacyFoldersAreLeftAlone() async throws {
        let (catalog, _) = try legacyFixture(markerRevision: "some-older-commit")
        let store = ModelStore(root: root)
        let report = await store.migrateLegacyInstalls(catalog: catalog)
        XCTAssertEqual(report.incomplete, ["toy-small"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("toy-small/installed.json").path))
    }

    func testTheBuiltInMigrationTableCoversEveryOldModel() throws {
        let catalog = ModelCatalog.builtIn
        let expected: [String: (key: String, paths: [String: String])] = [
            "whisper-base": ("whisper/base", ["model": "models/argmaxinc/whisperkit-coreml", "tokenizer": "models/openai/whisper-base"]),
            "whisper-small": ("whisper/small", ["model": "models/argmaxinc/whisperkit-coreml", "tokenizer": "models/openai/whisper-small"]),
            "whisper-large-turbo": ("whisper/large-v3-turbo", ["model": "models/argmaxinc/whisperkit-coreml", "tokenizer": "models/openai/whisper-large-v3-turbo"]),
            "speaker-community-1": ("community-1/offline", ["model": "speaker-diarization"]),
            "speaker-sortformer-v2.1-compact": ("sortformer-2.1/compact", ["model": "models/FluidInference/diar-streaming-sortformer-coreml"]),
            "speaker-sortformer-v2.1": ("sortformer-2.1/fp16", ["model": "models/FluidInference/diar-streaming-sortformer-coreml"]),
            "qwen-1.5b": ("qwen2.5/1.5b-4bit", ["model": "models/mlx-community/Qwen2.5-1.5B-Instruct-4bit"]),
            "qwen-3b": ("qwen2.5/3b-4bit", ["model": "models/mlx-community/Qwen2.5-3B-Instruct-4bit"]),
            "qwen-7b": ("qwen2.5/7b-4bit", ["model": "models/mlx-community/Qwen2.5-7B-Instruct-4bit"])]
        for (legacyID, entry) in expected {
            let found = try XCTUnwrap(catalog.legacyRevision(for: legacyID), legacyID)
            XCTAssertEqual(found.model.key, entry.key)
            XCTAssertEqual(found.revision.legacy?.artifactPaths, entry.paths, legacyID)
            XCTAssertEqual(Set(found.revision.artifacts.map(\.name)), Set(entry.paths.keys))
        }
    }
}
