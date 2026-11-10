import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// This Mac's model downloads (`ProcessingQueue`, owed downloads; uxf-07): what was asked for stays owed across a quit,
/// goes on at the next launch and when the network comes back, over Wi‑Fi only unless the person presses Download; a
/// failure stops the chain, says so in place, and is an alert only for a download the person's press started. A scripted
/// fetch and network, temporary libraries: nothing reaches the network.
@MainActor
final class ModelDownloadQueueTests: XCTestCase {
    /// Fetches as told: one at a time, each succeeding, failing, or waiting until it's cancelled.
    @MainActor final class Fetches {
        var calls: [String] = []
        var failing: Set<String> = []
        var holding: Set<String> = []

        func fetch(_ id: String, _ progress: IntelligenceProgressHandler) async throws {
            calls.append(id)
            if failing.contains(id) { throw URLError(.notConnectedToInternet) }
            if holding.contains(id) { try await Task.sleep(for: .seconds(600)) }
        }
    }

    /// The network as a test says it is, and the watcher Daybook gave it.
    @MainActor final class Network {
        var condition = SyncNetworkCondition.unrestricted
        var changed: (@MainActor @Sendable (SyncNetworkCondition) -> Void)?

        var downloads: DownloadNetwork {
            DownloadNetwork(condition: { [unowned self] in self.condition }, watch: { [unowned self] in self.changed = $0 })
        }

        func become(_ condition: SyncNetworkCondition) {
            self.condition = condition
            changed?(condition)
        }
    }

    private let transcription = "parakeet/ultra", summaries = "gemma-4/12b-4bit"

    private func state(in root: URL, fetches: Fetches, network: Network) -> AppState {
        let state = AppState(libraryURL: root, defaults: makeTestDefaults("local.daybook.tests.downloads"))
        state.processor.queue.fetchModel = { [fetches] id, progress in try await fetches.fetch(id, progress) }
        state.processor.queue.network = network.downloads
        return state
    }

    private func idle(_ state: AppState) async throws {
        try await waitUntil("the downloads to stop") { state.processor.queue.downloadingID == nil && state.processor.queue.downloadTask == nil }
    }

    /// What `local-downloads.json` holds once every write is on disk.
    private func saved(_ root: URL) throws -> [String] {
        ProcessingQueue.drainWrites()
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("local-downloads.json")))
    }

    func testBehaviorWhatsAskedForIsOwedUntilItsHere() async throws {
        let root = makeTemporaryFolder("DaybookDownloads"), fetches = Fetches(), network = Network()
        fetches.holding = [transcription]
        let state = state(in: root, fetches: fetches, network: network)
        state.downloadModels([transcription, summaries])
        try await waitUntil("the first download") { fetches.calls == [self.transcription] }
        XCTAssertEqual(state.processor.queue.owedDownloads, [transcription, summaries])
        XCTAssertEqual(try saved(root), [transcription, summaries], "kept beside the owed work")
        guard case .downloading(_, let total)? = state.modelDownloadState else { return XCTFail("one figure over the whole set") }
        XCTAssertEqual(total, ModelSize.bytes([transcription, summaries], in: state.modelCatalog))

        state.cancelDownload()
        try await idle(state)
        XCTAssertEqual(state.processor.queue.owedDownloads, [], "the person's Cancel settles everything")
        XCTAssertEqual(state.processor.queue.pendingDownloads, [])
        XCTAssertEqual(fetches.calls, [transcription], "nothing follows a Cancel")
        XCTAssertEqual(state.notice, "Download canceled.")
        XCTAssertEqual(try saved(root), [])
    }

    func testBehaviorTheDownloadsGoOnOneAfterAnotherAndAreSettledAsTheyArrive() async throws {
        let root = makeTemporaryFolder("DaybookDownloads"), fetches = Fetches(), network = Network()
        let state = state(in: root, fetches: fetches, network: network)
        state.downloadModels([transcription, summaries])
        try await waitUntil("both downloads") { fetches.calls == [self.transcription, self.summaries] && state.processor.queue.downloadingID == nil }
        try await idle(state)
        XCTAssertEqual(state.processor.queue.owedDownloads, [])
        XCTAssertEqual(try saved(root), [])
        XCTAssertNil(state.modelDownloadState, "nothing to say")
        XCTAssertNil(state.problem)
    }

    /// A download that fails on its own doesn't run on into the next, says so in place, writes to the log, and raises no
    /// alert; the rest stays owed for Try Again.
    func testBehaviorAFailureStopsTheChainAndRaisesNoAlertForWorkOnItsOwn() async throws {
        let root = makeTemporaryFolder("DaybookDownloads"), fetches = Fetches(), network = Network()
        fetches.failing = [transcription]
        let state = state(in: root, fetches: fetches, network: network)
        state.downloadModels([transcription, summaries], asked: false)
        try await idle(state)
        XCTAssertEqual(fetches.calls, [transcription], "the next one doesn't start")
        XCTAssertNil(state.problem, "work on its own writes to the log")
        XCTAssertEqual(state.processor.queue.owedDownloads, [transcription, summaries])
        XCTAssertNotNil(state.processor.queue.downloadFailures[transcription])
        XCTAssertEqual(state.modelDownloadState,
                       .failed(model: state.shortModelName(transcription), bytes: ModelSize.bytes([transcription, summaries], in: state.modelCatalog)))
        XCTAssertEqual(ProcessingWords.modelDownloadLine(try XCTUnwrap(state.modelDownloadState)), "Couldn’t download \(state.shortModelName(transcription))")

        // Try Again: what stopped and what was to follow.
        fetches.failing = []
        state.downloadModels([transcription])
        try await waitUntil("both downloads") { fetches.calls == [self.transcription, self.transcription, self.summaries] }
        try await idle(state)
        XCTAssertEqual(state.processor.queue.owedDownloads, [])
        XCTAssertTrue(state.processor.queue.downloadFailures.isEmpty)
    }

    func testBehaviorAFailureOfADownloadThePersonJustPressedIsAnAlertToo() async throws {
        let root = makeTemporaryFolder("DaybookDownloads"), fetches = Fetches(), network = Network()
        fetches.failing = [transcription]
        let state = state(in: root, fetches: fetches, network: network)
        state.downloadModels([transcription, summaries])
        try await idle(state)
        XCTAssertEqual(state.problem?.title, "Couldn’t Download \(state.shortModelName(transcription))")
        XCTAssertEqual(fetches.calls, [transcription])
    }

    /// Quitting stops a download and leaves it owed; the next launch takes it up again over Wi‑Fi, waits on a restricted
    /// network ("Waiting for Wi‑Fi"), and goes on when the network comes back.
    func testBehaviorOwedDownloadsGoOnAtTheNextLaunchAndWaitForWiFi() async throws {
        let root = makeTemporaryFolder("DaybookDownloads"), fetches = Fetches(), network = Network()
        fetches.holding = [transcription]
        let first = state(in: root, fetches: fetches, network: network)
        first.downloadModels([transcription, summaries])
        try await waitUntil("the first download") { fetches.calls == [self.transcription] }
        first.cancelProcessing()
        try await idle(first)
        XCTAssertEqual(first.processor.queue.owedDownloads, [transcription, summaries], "quitting leaves them owed")
        XCTAssertNil(first.notice, "a quit isn't the person's Cancel")
        XCTAssertEqual(try saved(root), [transcription, summaries])

        let later = Fetches(), restricted = Network()
        restricted.condition = .restricted
        let next = state(in: root, fetches: later, network: restricted)
        next.processor.queue.loadOwedWork()
        next.resumeOwedWork()
        XCTAssertEqual(later.calls, [], "a hotspot or Low Data Mode: nothing goes on by itself")
        XCTAssertEqual(next.modelDownloadState, .waitingForWiFi(bytes: ModelSize.bytes([transcription, summaries], in: next.modelCatalog)))
        XCTAssertEqual(next.downloadsWaitingForWiFi, [transcription, summaries])

        restricted.become(.unrestricted)
        try await waitUntil("both downloads") { later.calls == [self.transcription, self.summaries] }
        try await idle(next)
        XCTAssertEqual(next.processor.queue.owedDownloads, [])
        XCTAssertFalse(next.processor.queue.downloadsWaitForWiFi)
    }

    func testBehaviorTheNetworkComingBackTriesAgainWhatStopped() async throws {
        let root = makeTemporaryFolder("DaybookDownloads"), fetches = Fetches(), network = Network()
        fetches.failing = [transcription]
        let state = state(in: root, fetches: fetches, network: network)
        state.downloadModels([transcription], asked: false)
        try await idle(state)
        XCTAssertEqual(state.processor.queue.downloadFailures.keys.sorted(), [transcription])
        network.become(.restricted)
        XCTAssertEqual(fetches.calls, [transcription], "offline: it waits")
        fetches.failing = []
        network.become(.unrestricted)
        try await waitUntil("the second try") { fetches.calls == [self.transcription, self.transcription] }
        try await idle(state)
        XCTAssertEqual(state.processor.queue.owedDownloads, [])
        XCTAssertTrue(state.processor.queue.downloadFailures.isEmpty)
    }

    /// The person presses Download on a restricted network: it goes on now, and so does whatever else was owed.
    func testBehaviorThePersonsDownloadGoesOnOverAnyNetwork() async throws {
        let root = makeTemporaryFolder("DaybookDownloads"), fetches = Fetches(), network = Network()
        network.condition = .restricted
        let state = state(in: root, fetches: fetches, network: network)
        state.demoDownloads([summaries], .waitingForWiFi)
        XCTAssertEqual(state.modelDownloadState, .waitingForWiFi(bytes: ModelSize.bytes([summaries], in: state.modelCatalog)))
        state.downloadModels([transcription])
        try await waitUntil("both downloads") { fetches.calls == [self.transcription, self.summaries] }
        try await idle(state)
        XCTAssertEqual(state.processor.queue.owedDownloads, [])
    }

    func testBehaviorCancellingOneWaitingModelSettlesOnlyIt() {
        let root = makeTemporaryFolder("DaybookDownloads"), fetches = Fetches(), network = Network()
        let state = state(in: root, fetches: fetches, network: network)
        state.demoDownloads([transcription, summaries], .waitingForWiFi)
        state.removePendingDownload(summaries)
        XCTAssertEqual(state.processor.queue.owedDownloads, [transcription])
        XCTAssertTrue(state.processor.queue.downloadsWaitForWiFi)
        state.removePendingDownload(transcription)
        XCTAssertEqual(state.processor.queue.owedDownloads, [])
        XCTAssertFalse(state.processor.queue.downloadsWaitForWiFi, "nothing left to wait")
        XCTAssertNil(state.modelDownloadState)
    }
}
