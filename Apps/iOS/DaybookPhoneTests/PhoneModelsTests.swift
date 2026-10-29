import DaybookCaptions
import DaybookKit
import DaybookLive
import DaybookModelStore
import XCTest
@testable import DaybookPhone

/// The iPhone's live models: its defaults, what a small phone can't run, downloads that wait for
/// Wi‑Fi, and captions that stay the system's until models are downloaded. Nothing is downloaded.
@MainActor
final class PhoneModelsTests: XCTestCase {
    /// Records what it was asked to fetch and fetches nothing.
    final class RecordingFetcher: ModelArtifactFetcher, @unchecked Sendable {
        struct Offline: Error, LocalizedError { var errorDescription: String? { "The Internet connection appears to be offline." } }
        private let lock = NSLock()
        private var asked: [String] = []
        var requests: [String] { lock.withLock { asked } }
        func fetch(_ artifact: ModelArtifact, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            lock.withLock { asked.append(artifact.repository) }
            throw Offline()
        }
    }

    /// A network the test switches between Wi‑Fi and cellular.
    final class ScriptedNetwork: @unchecked Sendable {
        private let lock = NSLock()
        private var current = SyncNetworkCondition.restricted
        private var handler: (@Sendable () -> Void)?
        var network: PhoneNetwork {
            PhoneNetwork(condition: { [self] in lock.withLock { current } }, onChange: { [self] handler in lock.withLock { self.handler = handler } })
        }
        func set(_ condition: SyncNetworkCondition) {
            let handler = lock.withLock { () -> (@Sendable () -> Void)? in current = condition; return self.handler }
            handler?()
        }
    }

    private func makeModels(network: PhoneNetwork, fetcher: any ModelArtifactFetcher = RecordingFetcher(),
                            memoryGB: UInt64 = 12) -> PhoneModels {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneModelsTests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "PhoneModelsTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return PhoneModels(root: root, defaults: UserDefaults(suiteName: suite)!, fetcher: fetcher, network: network,
                           physicalMemory: memoryGB * 1_073_741_824)
    }

    func testTheiPhoneStartsWithStreamingModelsAndTheMacsVoiceProfiles() {
        let models = makeModels(network: ScriptedNetwork().network)
        XCTAssertEqual(models.choice(for: .liveTranscription)?.key, "nemotron-3.5-asr-streaming/latin-1120ms")
        XCTAssertEqual(models.choice(for: .liveDiarization)?.key, "nemotron-3-diarization/live")
        XCTAssertEqual(models.choice(for: .speakerEmbedding)?.key, "community-1/offline")
        XCTAssertEqual(models.missing.count, 3)
        XCTAssertGreaterThan(models.missingBytes, 600_000_000)
        XCTAssertLessThan(models.missingBytes, 800_000_000, "everything live captions need, under 800 MB")
        XCTAssertTrue(models.options(for: .liveTranscription).count >= 2, "Latin and multilingual")
        for role in models.roles { XCTAssertEqual(models.choice(for: role).map(models.status(of:)), .notDownloaded) }
    }

    func testASmallPhoneDoesntOfferTheRecognizer() throws {
        let models = makeModels(network: ScriptedNetwork().network, memoryGB: 4)
        let recognizer = try XCTUnwrap(models.choice(for: .liveTranscription))
        XCTAssertEqual(models.status(of: recognizer), .unavailable("Needs an iPhone with more memory"))
        XCTAssertEqual(models.choice(for: .speakerEmbedding).map(models.status(of:)), .notDownloaded, "voice profiles are small")
        XCTAssertFalse(models.missing.contains { $0.key == recognizer.key })
    }

    func testDownloadsWaitForWiFiUnlessCellularIsAllowed() async throws {
        let scripted = ScriptedNetwork(), fetcher = RecordingFetcher()
        let models = makeModels(network: scripted.network, fetcher: fetcher)
        let speakers = try XCTUnwrap(models.choice(for: .liveDiarization))
        models.download(speakers)
        XCTAssertEqual(models.status(of: speakers), .waitingForWiFi)
        XCTAssertTrue(fetcher.requests.isEmpty, "nothing fetched over cellular")
        scripted.set(.unrestricted)
        try await waitUntil { !fetcher.requests.isEmpty }
        try await waitUntil { if case .failed = models.status(of: speakers) { return true } else { return false } }
        XCTAssertEqual(models.status(of: speakers), .failed("The Internet connection appears to be offline."))

        let voices = try XCTUnwrap(models.choice(for: .speakerEmbedding))
        scripted.set(.restricted)
        models.allowsCellular = true
        models.download(voices)
        try await waitUntil { fetcher.requests.count >= 2 }
    }

    func testWithoutDownloadedModelsCaptionsStayTheSystems() {
        let models = makeModels(network: ScriptedNetwork().network)
        let system = ScriptedCaptioner(lines: [])
        XCTAssertTrue(models.captioner(locale: Locale(identifier: "en_US"), fallback: { system }) === system)
        XCTAssertTrue(models.installedSet(for: Locale(identifier: "en_US")).isEmpty)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
