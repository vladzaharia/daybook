import DaybookKit
import DaybookTestSupport
import Foundation
import Network
import XCTest
@testable import DaybookModelStore

/// The iPhone's model downloads, against a local HTTP server (no real downloads): files at their
/// repository paths and verified by the store, a stopped download continuing where it stopped, a
/// server error failing cleanly, and what the background sessions are allowed to use.
final class BackgroundModelFetcherTests: XCTestCase {
    private var root: URL!
    private var hub: LocalHub!

    override func setUp() async throws {
        root = SyntheticModels.temporaryDirectory()
        hub = try await LocalHub.start()
    }

    override func tearDown() {
        hub.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// An ordinary session to the local server: a background session doesn't run in a test process,
    /// and every delegate path is the same.
    private func fetcher() -> BackgroundModelFetcher {
        BackgroundModelFetcher(identifier: "tests.\(UUID().uuidString)", base: hub.base, configuration: { _, _ in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            return configuration
        })
    }

    private func toy(_ files: [(String, String)]) -> (CatalogModel, [String: Data]) {
        let (artifact, contents) = SyntheticModels.artifact("model", repository: "toy/small", revision: "rev-a", root: "bundle", files: files)
        let catalog = ModelCatalog(builtIn: SyntheticModels.manifest(revisions: [ModelRevisionEntry(id: "rev-a", releaseDate: "2026-01-01", artifacts: [artifact])]))
        return (catalog.models[0], contents)
    }

    func testFilesArriveAtTheirRepositoryPathsAndTheStoreInstallsThem() async throws {
        let big = String(repeating: "weights ", count: 40_000)
        let (model, contents) = toy([("bundle/weights.bin", big), ("bundle/config.json", "{\"v\": 1}"), ("bundle/nested/vocab.txt", "vocab")])
        for (key, data) in contents { hub.serve(key, data) }
        let store = ModelStore(root: root)
        let fractions = CallLog()
        let installed = try await store.install(model, revision: model.revisions[0], fetcher: fetcher(),
                                                progress: { fraction, _ in fractions.add(String(format: "%.2f", fraction)) })
        XCTAssertTrue(installed.isReady, "every file matched its size and digest")
        let weights = installed.installation.folder(for: "model").appendingPathComponent("weights.bin")
        XCTAssertEqual(try Data(contentsOf: weights), Data(big.utf8))
        XCTAssertEqual(Set(hub.requests.map(\.path)), ["/toy/small/resolve/rev-a/bundle/weights.bin",
                                                         "/toy/small/resolve/rev-a/bundle/config.json",
                                                         "/toy/small/resolve/rev-a/bundle/nested/vocab.txt"],
                       "each file from the repository at the pinned commit")
        XCTAssertEqual(fractions.calls.last, "1.00")

        // A file already whole isn't fetched again.
        hub.clearRequests()
        let artifact = model.revisions[0].artifacts[0]
        let directory = root.appendingPathComponent("again", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        try Data(big.utf8).write(to: directory.appendingPathComponent("bundle/weights.bin"))
        _ = try await fetcher().fetch(artifact, into: directory, progress: { _ in })
        XCTAssertEqual(Set(hub.requests.map(\.path)), ["/toy/small/resolve/rev-a/bundle/config.json", "/toy/small/resolve/rev-a/bundle/nested/vocab.txt"])
    }

    func testAStoppedDownloadContinuesFromWhereItStopped() async throws {
        let bytes = Data((0..<2_000_000).map { UInt8($0 % 251) })
        let file = ModelFile(path: "encoder.bin", size: Int64(bytes.count), sha256: SyntheticModels.sha256(bytes))
        let artifact = ModelArtifact(name: "model", repository: "toy/encoder", revision: "rev-b", files: [file])
        hub.serve("toy/encoder@rev-b:encoder.bin", bytes)
        hub.throttle = (chunk: 16_384, milliseconds: 20)
        let directory = root.appendingPathComponent("partial", isDirectory: true)
        let fetcher = fetcher()
        let received = Progressed()
        let first = Task { try await fetcher.fetch(artifact, into: directory, progress: { received.set($0) }) }
        try await waitUntil("part of it arrived", timeout: 60) { received.value > 0 }
        first.cancel()
        do { _ = try await first.value; XCTFail("cancelled") } catch {}
        let destination = directory.appendingPathComponent("encoder.bin")
        try await waitUntil("what arrived is kept for next time") { FileManager.default.fileExists(atPath: BackgroundModelFetcher.resumeURL(destination).path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "no half file stands in for the whole")

        hub.throttle = nil
        hub.clearRequests()
        _ = try await fetcher.fetch(artifact, into: directory, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: destination), bytes, "the whole file, intact")
        let range = try XCTUnwrap(hub.requests.last?.range, "the second request asks only for the rest")
        let from = Int(range.dropFirst("bytes=".count).prefix { $0.isNumber }) ?? 0
        XCTAssertGreaterThan(from, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackgroundModelFetcher.resumeURL(destination).path))
    }

    func testAServerErrorFailsTheDownloadAndLeavesNothing() async throws {
        let file = ModelFile(path: "missing.bin", size: 10, sha256: String(repeating: "0", count: 64))
        let artifact = ModelArtifact(name: "model", repository: "toy/missing", revision: "rev-c", files: [file])
        let directory = root.appendingPathComponent("partial", isDirectory: true)
        do {
            _ = try await fetcher().fetch(artifact, into: directory, progress: { _ in })
            XCTFail("the server has no such file")
        } catch {
            XCTAssertEqual(error as? BackgroundModelFetcher.Failure, .http(404))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing.bin").path))
    }

    func testTheBackgroundSessionsAndWhatTheyMayUse() {
        let wifi = BackgroundModelFetcher.background("local.daybook.models.wifi", cellular: false)
        XCTAssertEqual(wifi.identifier, "local.daybook.models.wifi")
        XCTAssertFalse(wifi.allowsExpensiveNetworkAccess, "Wi‑Fi only: never cellular or a hotspot")
        XCTAssertFalse(wifi.allowsConstrainedNetworkAccess, "nor Low Data Mode")
        XCTAssertFalse(wifi.isDiscretionary, "the person asked: not left for the system to schedule")
        XCTAssertTrue(wifi.sessionSendsLaunchEvents, "finishing relaunches the app to install")
        let any = BackgroundModelFetcher.background("local.daybook.models.any", cellular: true)
        XCTAssertTrue(any.allowsExpensiveNetworkAccess)
        XCTAssertTrue(any.allowsConstrainedNetworkAccess)

        let fetcher = BackgroundModelFetcher()
        XCTAssertTrue(fetcher.handleEvents(for: "local.daybook.models.wifi", completion: {}))
        XCTAssertFalse(fetcher.handleEvents(for: "some.other.session", completion: {}), "another session's events aren't ours")
        XCTAssertEqual(BackgroundModelFetcher.url(for: ModelFile(path: "latin/1120ms/encoder.mlmodelc/weights/weight.bin", size: 1),
                                                  in: ModelArtifact(name: "model", repository: "FluidInference/Nemotron", revision: "1a41b7", files: []),
                                                  base: URL(string: "https://huggingface.co")!).absoluteString,
                       "https://huggingface.co/FluidInference/Nemotron/resolve/1a41b7/latin/1120ms/encoder.mlmodelc/weights/weight.bin")
    }

    func testADownloadInTheStoresPartialFolderNamesItsModel() {
        let store = ModelStore(root: root)
        let file = root.appendingPathComponent(".partial/nemotronStreaming/nemotron-3.5-asr-streaming/latin-1120ms/1a41b7/model/latin/encoder.bin")
        XCTAssertEqual(store.variantKey(downloading: file), "nemotron-3.5-asr-streaming/latin-1120ms")
        XCTAssertNil(store.variantKey(downloading: root.appendingPathComponent("nemotronStreaming/x/y/z/model/file")))
    }
}

/// The latest progress a fetch reported.
private final class Progressed: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction = 0.0
    func set(_ value: Double) { lock.withLock { fraction = max(fraction, value) } }
    var value: Double { lock.withLock { fraction } }
}

/// A small HTTP/1.1 server on the loopback interface, serving files at Hugging Face's
/// `/<repository>/resolve/<revision>/<path>` with an ETag and byte ranges, so `URLSession` can resume
/// a download; optionally slowly, so one can be stopped partway.
final class LocalHub: @unchecked Sendable {
    struct Request { var path: String; var range: String? }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-hub")
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var log: [Request] = []
    private var slow: (chunk: Int, every: DispatchTimeInterval)?
    let base: URL

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    static func start() async throws -> LocalHub {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.yield(listener.port?.rawValue)
            case .failed: ready.continuation.yield(nil)
            default: break
            }
        }
        let box = Box()
        listener.newConnectionHandler = { connection in box.hub?.accept(connection) }
        listener.start(queue: DispatchQueue(label: "local-hub-listener"))
        var port: UInt16?
        for await value in ready.stream { port = value; break }
        guard let port else { throw URLError(.cannotConnectToHost) }
        let hub = LocalHub(listener: listener, port: port)
        box.hub = hub
        return hub
    }

    private final class Box: @unchecked Sendable { weak var hub: LocalHub? }

    func stop() { listener.cancel() }

    /// Serves `data` for `key` ("repository@revision:path", as `FakeFetcher.key` writes it).
    func serve(_ key: String, _ data: Data) {
        guard let at = key.firstIndex(of: "@"), let colon = key[at...].firstIndex(of: ":") else { return }
        let repository = key[..<at], revision = key[key.index(after: at)..<colon], path = key[key.index(after: colon)...]
        lock.withLock { files["/\(repository)/resolve/\(revision)/\(path)"] = data }
    }

    /// Sends each body `chunk` bytes at a time, `milliseconds` apart; nil sends it at once.
    var throttle: (chunk: Int, milliseconds: Int)? {
        get { lock.withLock { slow.map { ($0.chunk, 0) } } }
        set { lock.withLock { slow = newValue.map { (chunk: $0.chunk, every: .milliseconds($0.milliseconds)) } } }
    }

    var requests: [Request] { lock.withLock { log } }
    func clearRequests() { lock.withLock { log = [] } }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if !complete, error == nil {
                self.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        let (data, slow) = lock.withLock { () -> (Data?, (chunk: Int, every: DispatchTimeInterval)?) in
            log.append(Request(path: path, range: range))
            return (files[path], self.slow)
        }
        guard let data else {
            send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), then: nil)
            return
        }
        var start = 0
        if let range, range.hasPrefix("bytes="), let from = Int(range.dropFirst("bytes=".count).prefix { $0.isNumber }), from < data.count {
            start = from
        }
        let body = data[start...]
        var header = start > 0 ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        header += "Content-Length: \(body.count)\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\n"
        header += "ETag: \"\(data.count)-\(data.prefix(16).map { String($0) }.joined())\"\r\nLast-Modified: Wed, 01 Jan 2026 00:00:00 GMT\r\n"
        if start > 0 { header += "Content-Range: bytes \(start)-\(data.count - 1)/\(data.count)\r\n" }
        header += "Connection: close\r\n\r\n"
        send(connection, Data(header.utf8), then: { [weak self] in self?.stream(connection, Data(body), slow: slow) })
    }

    private func stream(_ connection: NWConnection, _ body: Data, slow: (chunk: Int, every: DispatchTimeInterval)?) {
        guard let slow, body.count > slow.chunk else {
            send(connection, body, then: { connection.cancel() })
            return
        }
        send(connection, body.prefix(slow.chunk), then: { [weak self] in
            self?.queue.asyncAfter(deadline: .now() + slow.every) { self?.stream(connection, Data(body.dropFirst(slow.chunk)), slow: slow) }
        })
    }

    private func send(_ connection: NWConnection, _ data: Data, then: (() -> Void)?) {
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { connection.cancel(); return }
            then?()
        })
    }
}
