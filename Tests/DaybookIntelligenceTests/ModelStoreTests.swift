import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// The store: verified, atomic, resumable installs; revisions side by side; garbage collection.
final class ModelStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() { root = SyntheticModels.temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// A toy variant with one revision per entry in `revisions` (ID, release date, file text).
    private func toy(_ revisions: [(id: String, date: String, text: String)]) -> (CatalogModel, FakeFetcher) {
        let fetcher = FakeFetcher()
        var entries: [ModelRevisionEntry] = []
        for revision in revisions {
            let (artifact, contents) = SyntheticModels.artifact(
                "model", repository: "toy/small", revision: revision.id, root: "bundle",
                files: [("bundle/weights.bin", "weights \(revision.text)"), ("bundle/config.json", "{\"v\": \"\(revision.text)\"}"),
                        ("bundle/nested/vocab.txt", "vocab \(revision.text)")])
            let (tokenizer, tokenizerContents) = SyntheticModels.artifact(
                "tokenizer", repository: "toy/tokenizer", revision: "t-\(revision.id)", files: [("tokenizer.json", "{\"t\": 1}")])
            fetcher.add(contents); fetcher.add(tokenizerContents)
            entries.append(ModelRevisionEntry(id: revision.id, releaseDate: revision.date, artifacts: [artifact, tokenizer]))
        }
        let catalog = ModelCatalog(builtIn: SyntheticModels.manifest(revisions: entries))
        return (catalog.models[0], fetcher)
    }

    private func contents(of url: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).map { String($0.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1)) }.sorted()
    }

    func testInstallVerifiesEveryFileAndAppearsInOneStep() async throws {
        let (model, fetcher) = toy([("rev-a", "2026-01-01", "a")])
        let store = ModelStore(root: root)
        let messages = CallLog()
        let installed = try await store.install(model, revision: model.revisions[0], fetcher: fetcher,
                                                validate: { installation in
            XCTAssertTrue(installation.directory.path.contains("/.staging/"), "The engine checks the install before it's placed")
            XCTAssertTrue(FileManager.default.fileExists(atPath: installation.folder(for: "model").appendingPathComponent("weights.bin").path))
        }, progress: { _, message in messages.add(message) })
        XCTAssertTrue(installed.isReady)
        XCTAssertEqual(installed.key.description, "toyEngine/toy/small/rev-a")
        XCTAssertEqual(installed.installation.directory.standardizedFileURL, root.appendingPathComponent("toyEngine/toy/small/rev-a").standardizedFileURL)
        XCTAssertEqual(contents(of: installed.installation.directory), [
            "model", "model/bundle", "model/bundle/config.json", "model/bundle/nested", "model/bundle/nested/vocab.txt",
            "model/bundle/weights.bin", "receipt.json", "tokenizer", "tokenizer/tokenizer.json"])
        XCTAssertEqual(installed.installation.folder(for: "model").lastPathComponent, "bundle")
        XCTAssertEqual(messages.calls.first, "Downloading Toy Small")
        XCTAssertTrue(messages.calls.contains("Downloading tokenizer"))
        XCTAssertEqual(messages.calls.last, "Toy Small is ready for offline use")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".partial/toyEngine").path), "No partial download is left")
        XCTAssertTrue(contents(of: root.appendingPathComponent(".staging")).isEmpty)
        let inventory = await store.inventory()
        XCTAssertEqual(inventory.usableVariantKeys, ["toy/small"])
        XCTAssertEqual(inventory.resolvedRevisions, ["toy/small": "rev-a"])

        // Installing again downloads nothing.
        let calls = fetcher.calls
        _ = try await store.install(model, revision: model.revisions[0], fetcher: fetcher)
        XCTAssertEqual(fetcher.calls, calls)
    }

    func testAFileThatFailsVerificationInstallsNothingAndIsFetchedAgain() async throws {
        let (model, fetcher) = toy([("rev-a", "2026-01-01", "a")])
        let store = ModelStore(root: root)
        fetcher.corrupt = ["bundle/weights.bin"]
        do {
            _ = try await store.install(model, revision: model.revisions[0], fetcher: fetcher)
            XCTFail("A corrupted file must not install")
        } catch let error as ModelStoreError {
            XCTAssertEqual(error, .verificationFailed(model: "Toy Small", file: "bundle/weights.bin"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("toyEngine/toy/small/rev-a").path))
        let inventory = await store.inventory()
        XCTAssertTrue(inventory.revisions.isEmpty)

        fetcher.corrupt = []
        let before = fetcher.written.count
        _ = try await store.install(model, revision: model.revisions[0], fetcher: fetcher)
        XCTAssertEqual(Array(fetcher.written.dropFirst(before)), ["bundle/weights.bin"], "Only the bad file downloads again")
    }

    func testAFailedEngineCheckLeavesNoInstall() async throws {
        let (model, fetcher) = toy([("rev-a", "2026-01-01", "a")])
        let store = ModelStore(root: root)
        struct Refused: Error {}
        do {
            _ = try await store.install(model, revision: model.revisions[0], fetcher: fetcher, validate: { _ in throw Refused() })
            XCTFail("The engine refused it")
        } catch is Refused {}
        let inventory = await store.inventory()
        XCTAssertTrue(inventory.revisions.isEmpty)
        XCTAssertTrue(contents(of: root.appendingPathComponent(".staging")).isEmpty)
    }

    func testAnInterruptedDownloadResumes() async throws {
        let (model, fetcher) = toy([("rev-a", "2026-01-01", "a")])
        let store = ModelStore(root: root)
        fetcher.failAfter = 2
        do {
            _ = try await store.install(model, revision: model.revisions[0], fetcher: fetcher)
            XCTFail("Interrupted")
        } catch is CancellationError {}
        XCTAssertEqual(fetcher.written.count, 2)
        let usage = await store.diskUsage()
        XCTAssertGreaterThan(usage.partial["toy/small"] ?? 0, 0, "The partial download is kept and counted")

        fetcher.failAfter = nil
        _ = try await store.install(model, revision: model.revisions[0], fetcher: fetcher)
        XCTAssertEqual(fetcher.written.count, 4, "The second attempt fetched only what was missing")
        XCTAssertEqual(Set(fetcher.written).count, 4)
    }

    func testAnUpdateInstallsBesideTheOldRevisionWhichStaysWhileInUse() async throws {
        let (model, fetcher) = toy([("rev-a", "2026-01-01", "a"), ("rev-b", "2026-03-01", "b")])
        let store = ModelStore(root: root)
        let old = model.revision("rev-a")!, new = model.revision("rev-b")!
        XCTAssertEqual(model.latestRevision?.id, "rev-b")

        let first = try await store.install(model, revision: old, fetcher: fetcher)
        var inventory = await store.inventory()
        XCTAssertEqual(inventory.resolve("toy/small")?.key.revision, "rev-a")

        // A job froze rev-a and is running.
        let lease = await store.lease([first.key])
        try await store.install(model, revision: new, fetcher: fetcher)
        inventory = await store.inventory()
        XCTAssertEqual(inventory.resolve("toy/small")?.key.revision, "rev-b", "The selection switched once rev-b verified")
        XCTAssertEqual(inventory.resolve("toy/small", revision: "rev-a")?.key.revision, "rev-a", "The job's frozen revision still resolves")
        XCTAssertEqual(inventory.revisions(of: "toy/small").map(\.key.revision), ["rev-b", "rev-a"])

        var removed = await store.collectGarbage(protecting: [])
        XCTAssertTrue(removed.isEmpty, "A revision in use is never collected")
        await store.endLease(lease)

        // Queued work protects it too, and so does a pin.
        removed = await store.collectGarbage(protecting: [first.key])
        XCTAssertTrue(removed.isEmpty)
        await store.setPinned(first.key, true)
        removed = await store.collectGarbage(protecting: [])
        XCTAssertTrue(removed.isEmpty, "Pinned revisions stay")
        await store.setPinned(first.key, false)

        removed = await store.collectGarbage(protecting: [])
        XCTAssertEqual(removed, [first.key])
        inventory = await store.inventory()
        XCTAssertEqual(inventory.revisions.map(\.key.revision), ["rev-b"], "The newest ready revision is always kept")
        removed = await store.collectGarbage(protecting: [])
        XCTAssertTrue(removed.isEmpty)
    }

    func testADamagedRevisionIsNotUsedAndTheOlderOneIsKept() async throws {
        let (model, fetcher) = toy([("rev-a", "2026-01-01", "a"), ("rev-b", "2026-03-01", "b")])
        let store = ModelStore(root: root)
        try await store.install(model, revision: model.revision("rev-a")!, fetcher: fetcher)
        let newer = try await store.install(model, revision: model.revision("rev-b")!, fetcher: fetcher)
        try Data("x".utf8).write(to: newer.installation.folder(for: "model").appendingPathComponent("weights.bin"))
        var inventory = await store.inventory()
        XCTAssertEqual(inventory.revisions(of: "toy/small").first?.state, .damaged("model/bundle/weights.bin"))
        XCTAssertEqual(inventory.resolve("toy/small")?.key.revision, "rev-a", "Selections fall back to the verified revision")

        let removed = await store.collectGarbage(protecting: [])
        XCTAssertEqual(removed.map(\.revision), ["rev-b"], "The damaged revision goes; the working one stays")
        inventory = await store.inventory()
        XCTAssertEqual(inventory.resolvedRevisions, ["toy/small": "rev-a"])
    }

    func testRemovingAVariantRemovesItsRevisionsAndPartialDownloadUnlessInUse() async throws {
        let (model, fetcher) = toy([("rev-a", "2026-01-01", "a"), ("rev-b", "2026-03-01", "b")])
        let store = ModelStore(root: root)
        let installed = try await store.install(model, revision: model.revision("rev-a")!, fetcher: fetcher)
        fetcher.failAfter = 1
        _ = try? await store.install(model, revision: model.revision("rev-b")!, fetcher: fetcher)
        var usage = await store.diskUsage()
        XCTAssertEqual(usage.installed[installed.key], installed.installation.receipt.totalBytes + Int64(try Data(contentsOf: installed.installation.directory.appendingPathComponent("receipt.json")).count))
        XCTAssertGreaterThan(usage.bytes(for: "toy/small"), usage.installed[installed.key]!)

        let lease = await store.lease([installed.key])
        do {
            try await store.remove(variantKey: "toy/small")
            XCTFail("A model in use can't be removed")
        } catch let error as ModelStoreError { XCTAssertEqual(error, .inUse("toy/small")) }
        await store.endLease(lease)

        let removed = try await store.remove(variantKey: "toy/small")
        XCTAssertEqual(removed, [installed.key])
        usage = await store.diskUsage()
        XCTAssertEqual(usage.total, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("toyEngine").path), "Empty folders are pruned")
    }
}
