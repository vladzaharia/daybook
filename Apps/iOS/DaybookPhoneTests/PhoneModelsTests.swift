import DaybookCaptions
import DaybookKit
import DaybookLive
import DaybookModelStore
import Synchronization
import UIKit
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

    /// Holds each fetch until the test lets it go, then fails it as offline.
    final class HeldFetcher: ModelArtifactFetcher {
        private let state = Mutex<(held: [CheckedContinuation<Void, Never>], released: Bool)>(([], false))
        var isHolding: Bool { state.withLock { !$0.held.isEmpty } }

        func fetch(_ artifact: ModelArtifact, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            await withCheckedContinuation { continuation in
                let released = state.withLock { state in
                    if !state.released { state.held.append(continuation) }
                    return state.released
                }
                if released { continuation.resume() }
            }
            throw RecordingFetcher.Offline()
        }

        func release() {
            let held = state.withLock { state in
                state.released = true
                defer { state.held = [] }
                return state.held
            }
            for continuation in held { continuation.resume() }
        }
    }

    /// Background time that's granted at once and runs out when the test says so.
    final class FakeBackgroundTime: BackgroundTime {
        private var next = 1
        private var expirations: [Int: @MainActor @Sendable () -> Void] = [:]
        private(set) var begun: [String] = []
        private(set) var ended: [Int] = []

        func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int? {
            begun.append(name)
            defer { next += 1 }
            expirations[next] = expired
            return next
        }

        func end(_ assertion: Int) {
            ended.append(assertion)
            expirations[assertion] = nil
        }

        /// The time is up for every assertion still held.
        func expire() {
            for expired in expirations.sorted(by: { $0.key < $1.key }).map(\.value) { expired() }
        }
    }

    private func makeModels(network: PhoneNetwork, fetcher: any ModelArtifactFetcher = RecordingFetcher(),
                            memoryGB: UInt64 = 12, backgroundTime: (any BackgroundTime)? = nil) -> PhoneModels {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneModelsTests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PhoneModels(root: root, defaults: makeTestDefaults("PhoneModelsTests"), fetcher: fetcher, network: network,
                           physicalMemory: memoryGB * 1_073_741_824, backgroundTime: backgroundTime ?? FakeBackgroundTime())
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

    func testADownloadEndsItsBackgroundTimeOnceItStops() async throws {
        let scripted = ScriptedNetwork(), time = FakeBackgroundTime()
        scripted.set(.unrestricted)
        let models = makeModels(network: scripted.network, backgroundTime: time)
        let speakers = try XCTUnwrap(models.choice(for: .liveDiarization))
        models.download(speakers)
        XCTAssertEqual(time.begun, ["Daybook model download"])
        try await waitUntil { if case .failed = models.status(of: speakers) { return true } else { return false } }
        XCTAssertEqual(time.ended, [1])
    }

    func testADownloadOutlastingItsBackgroundTimeEndsItThenAndNotAgain() async throws {
        let scripted = ScriptedNetwork(), fetcher = HeldFetcher(), time = FakeBackgroundTime()
        scripted.set(.unrestricted)
        let models = makeModels(network: scripted.network, fetcher: fetcher, backgroundTime: time)
        let speakers = try XCTUnwrap(models.choice(for: .liveDiarization))
        models.download(speakers)
        try await waitUntil { fetcher.isHolding }
        time.expire()
        XCTAssertEqual(time.ended, [1], "held past its time, iOS would end the app instead of suspending it")
        XCTAssertTrue(models.status(of: speakers).isTransferring, "the download carries on")
        fetcher.release()
        try await waitUntil { if case .failed = models.status(of: speakers) { return true } else { return false } }
        XCTAssertEqual(time.ended, [1])
    }

    func testADownloadCarriesOnAfterARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneModelsTests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "PhoneModelsTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let scripted = ScriptedNetwork(), fetcher = RecordingFetcher()
        scripted.set(.unrestricted)
        // The last run asked for the speaker model and iOS ended it before it finished.
        defaults.set(["nemotron-3-diarization/live"], forKey: PhoneModels.Keys.downloading)
        let models = PhoneModels(root: root, defaults: defaults, fetcher: fetcher, network: scripted.network,
                                 physicalMemory: 12 * 1_073_741_824)
        try await waitUntil { !fetcher.requests.isEmpty }
        XCTAssertEqual(fetcher.requests, ["FluidInference/nemotron-3-diarization-coreml"], "picked up again at launch")
        try await waitUntil { (defaults.stringArray(forKey: PhoneModels.Keys.downloading) ?? []).isEmpty }
        let speakers = try XCTUnwrap(models.choice(for: .liveDiarization))
        XCTAssertEqual(models.status(of: speakers), .failed("The Internet connection appears to be offline."),
                       "a download that failed is shown, and not started again at the next launch")

        // Asked for again, then cancelled: also not carried over.
        scripted.set(.restricted)
        models.download(speakers)
        XCTAssertEqual(defaults.stringArray(forKey: PhoneModels.Keys.downloading), ["nemotron-3-diarization/live"])
        models.cancel(speakers)
        XCTAssertEqual(defaults.stringArray(forKey: PhoneModels.Keys.downloading), [])
    }

    func testAnotherSessionsEventsAreFinishedAtOnce() {
        var finished = false
        PhoneAppDelegate().application(UIApplication.shared, handleEventsForBackgroundURLSession: "some.other.session") { finished = true }
        XCTAssertTrue(finished, "nothing waits on a session that isn't the models'")
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
