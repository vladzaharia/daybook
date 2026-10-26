import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Models leave memory when nothing uses them: after an idle delay, at once when memory is short
/// (after the job that holds them), never in the middle of one, and never a model the system holds.
final class RuntimeResidencyTests: XCTestCase {
    private var root: URL!

    override func setUp() { root = SyntheticModels.temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// A speech engine whose loading and transcribing can be held open, to act in the middle of them.
    private struct GatedEngine: ModelEngine {
        var residency: ModelResidency = .shared
        let log: CallLog
        let gate: Gate
        var descriptor: ModelEngineDescriptor {
            ModelEngineDescriptor(id: "toyEngine", name: "Toy", version: 1, runtime: "Toy 1.0", roles: [.transcription],
                                  platforms: [.macOS, .iOS], residency: residency)
        }
        func validate(_ installation: ModelInstallation) throws {}
        func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
            throw ModelAdditionError.invalid(["Not in this test."])
        }
        func load(_ installation: ModelInstallation, role: ModelRole, progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
            log.add("load \(installation.key.revision)")
            await gate.pass("load")
            return Model(log: log, gate: gate)
        }
        final class Model: Transcribing, @unchecked Sendable {
            let log: CallLog, gate: Gate
            init(log: CallLog, gate: Gate) { self.log = log; self.gate = gate }
            func transcribe(url: URL, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
                log.add("transcribe")
                await gate.pass("transcribe")
                return RecognitionResult(segments: [], language: "en", duration: 1)
            }
            func unload() { log.add("unload") }
        }
    }

    /// Holds the named step open until `open` is called; other steps pass straight through.
    actor Gate {
        private var held: String?
        private var waiting: CheckedContinuation<Void, Never>?
        private var arrived: [String: CheckedContinuation<Void, Never>] = [:]
        private var reached = Set<String>()
        init(holding step: String? = nil) { held = step }
        func pass(_ step: String) async {
            reached.insert(step)
            arrived.removeValue(forKey: step)?.resume()
            guard step == held else { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func reach(_ step: String) async {
            if reached.contains(step) { return }
            await withCheckedContinuation { arrived[step] = $0 }
        }
        func open() { held = nil; waiting?.resume(); waiting = nil }
    }

    private func runtime(engine: GatedEngine, revisions: [String] = ["rev-a"]) async throws -> LocalIntelligenceRuntime {
        let fetcher = FakeFetcher()
        var entries: [ModelRevisionEntry] = []
        for revision in revisions {
            let (artifact, contents) = SyntheticModels.artifact("model", repository: "toy/speech", revision: revision,
                                                                files: [("weights.bin", "weights \(revision)")])
            fetcher.add(contents)
            entries.append(ModelRevisionEntry(id: revision, releaseDate: "2026-10-0\(entries.count + 1)", artifacts: [artifact]))
        }
        let manifest = SyntheticModels.manifest(engine: "toyEngine", variant: "v1", revisions: entries.reversed())
        let runtime = LocalIntelligenceRuntime(modelsDirectory: root, registry: ModelEngineRegistry([engine]),
                                               builtIn: .init(manifest: manifest), fetcher: fetcher)
        for revision in revisions { try await runtime.download(modelID: "toy/v1@\(revision)") }
        return runtime
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testModelsAreReleasedOnceIdleAndKeptWhileWorkContinues() async throws {
        let log = CallLog()
        let runtime = try await runtime(engine: GatedEngine(log: log, gate: Gate()))
        await runtime.setIdleUnloadDelay(.milliseconds(300))
        let audio = root.appendingPathComponent("a.caf")
        _ = try await runtime.transcribe(url: audio, model: "toy/v1")
        _ = try await runtime.transcribe(url: audio, model: "toy/v1")
        XCTAssertEqual(log.calls, ["load rev-a", "transcribe", "transcribe"], "Back-to-back work keeps the model")
        try await waitUntil { log.calls.contains("unload") }
        XCTAssertEqual(log.calls.last, "unload")
        let holds = await runtime.holdsResidentModels
        XCTAssertFalse(holds)
        _ = try await runtime.transcribe(url: audio, model: "toy/v1")
        XCTAssertEqual(Array(log.calls.suffix(2)), ["load rev-a", "transcribe"], "The next job loads it again")
    }

    func testMemoryPressureReleasesAtOnceButNeverMidJob() async throws {
        let log = CallLog(), gate = Gate(holding: "transcribe")
        let runtime = try await runtime(engine: GatedEngine(log: log, gate: gate))
        let audio = root.appendingPathComponent("a.caf")
        let job = Task { try await runtime.transcribe(url: audio, model: "toy/v1") }
        await gate.reach("transcribe")
        await runtime.memoryPressureRaised()
        XCTAssertFalse(log.calls.contains("unload"), "Not while the job uses it")
        await gate.open()
        _ = try await job.value
        XCTAssertEqual(log.calls.last, "unload", "Released as soon as the job ended")

        _ = try await runtime.transcribe(url: audio, model: "toy/v1")
        await runtime.memoryPressureRaised()
        XCTAssertEqual(log.calls.last, "unload", "Idle: released at once")
    }

    func testModelsTheSystemHoldsStay() async throws {
        let log = CallLog()
        let runtime = try await runtime(engine: GatedEngine(residency: .system, log: log, gate: Gate()))
        await runtime.setIdleUnloadDelay(.milliseconds(20))
        _ = try await runtime.transcribe(url: root.appendingPathComponent("a.caf"), model: "toy/v1")
        await runtime.memoryPressureRaised()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(log.calls.contains("unload"))
    }
}
