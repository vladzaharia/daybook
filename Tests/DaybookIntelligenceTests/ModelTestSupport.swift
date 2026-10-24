import CryptoKit
import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Synthetic models for store, migration, engine, and update tests: tiny files with real digests,
/// so nothing is ever downloaded.
enum SyntheticModels {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func gitOID(_ data: Data) -> String {
        Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
    }

    /// A file entry and its bytes. Large-file style (SHA-256) or small-file style (git blob ID).
    static func file(_ path: String, _ text: String, lfs: Bool = true) -> (ModelFile, Data) {
        let data = Data(text.utf8)
        return (ModelFile(path: path, size: Int64(data.count), sha256: lfs ? sha256(data) : nil, gitOID: lfs ? nil : gitOID(data)), data)
    }

    /// An artifact plus the bytes a fake fetcher serves for it.
    static func artifact(_ name: String, repository: String, revision: String, root: String? = nil,
                         files: [(String, String)], include: [String]? = nil) -> (ModelArtifact, [String: Data]) {
        var entries: [ModelFile] = []
        var contents: [String: Data] = [:]
        for (index, item) in files.enumerated() {
            let (entry, data) = file(item.0, item.1, lfs: index % 2 == 0)
            entries.append(entry)
            contents[FakeFetcher.key(repository, revision, item.0)] = data
        }
        return (ModelArtifact(name: name, repository: repository, revision: revision, include: include ?? [(root.map { $0 + "/" } ?? "") + "*"],
                              root: root, files: entries), contents)
    }

    /// One family with one variant and the given revisions.
    static func manifest(family: String = "toy", engine: ModelEngineID = "toyEngine", roles: [ModelRole] = [.transcription],
                         variant: String = "small", name: String = "Toy Small", revisions: [ModelRevisionEntry],
                         capabilities: ModelCapabilities = .init(), minimumEngineVersion: Int? = nil,
                         license: ModelLicense? = ModelLicense(id: "MIT", name: "MIT License", url: "https://example.com/license", allowsCommercialUse: true)) -> ModelManifest {
        ModelManifest(families: [ModelFamilyEntry(
            id: family, name: "Toy", engine: engine, roles: roles, license: license,
            variants: [ModelVariantEntry(id: variant, name: name, capabilities: capabilities,
                                         minimumEngineVersion: minimumEngineVersion, revisions: revisions)])])
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("daybook-models-\(UUID().uuidString)", isDirectory: true)
        return url
    }
}

/// Serves synthetic files as if downloading them. Files already in the directory are kept, as
/// HubApi resumes; `failAfter` simulates an interrupted download.
final class FakeFetcher: ModelArtifactFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _contents: [String: Data]
    private var _written: [String] = []
    private var _calls = 0
    var corrupt: Set<String> {
        get { lock.withLock { _corrupt } }
        set { lock.withLock { _corrupt = newValue } }
    }
    private var _corrupt: Set<String> = []
    var failAfter: Int? {
        get { lock.withLock { _failAfter } }
        set { lock.withLock { _failAfter = newValue } }
    }
    private var _failAfter: Int?

    init(_ contents: [String: Data] = [:]) { _contents = contents }

    static func key(_ repository: String, _ revision: String, _ path: String) -> String { "\(repository)@\(revision):\(path)" }

    func add(_ contents: [String: Data]) { lock.withLock { _contents.merge(contents) { $1 } } }
    var written: [String] { lock.withLock { _written } }
    var calls: Int { lock.withLock { _calls } }

    func fetch(_ artifact: ModelArtifact, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lock.withLock { _calls += 1 }
        let root = directory.appendingPathComponent("models/\(artifact.repository)", isDirectory: true)
        var writtenNow = 0
        for (index, file) in artifact.files.enumerated() {
            let url = root.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            if let limit = failAfter, writtenNow >= limit { throw CancellationError() }
            let key = Self.key(artifact.repository, artifact.revision, file.path)
            guard var data = lock.withLock({ _contents[key] }) else { throw URLError(.fileDoesNotExist) }
            if corrupt.contains(file.path) { data = Data(repeating: 0x21, count: data.count) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            lock.withLock { _written.append(file.path) }
            writtenNow += 1
            progress(Double(index + 1) / Double(artifact.files.count))
        }
        return root
    }
}

/// A transcription engine standing in for a new one (Parakeet): one type, one registration.
struct ToyTranscriptionEngine: ModelEngine {
    var id: ModelEngineID = "toyEngine"
    var residency: ModelResidency = .shared
    var version = 1
    let log: CallLog

    var descriptor: ModelEngineDescriptor {
        ModelEngineDescriptor(id: id, name: "Toy", version: version, runtime: "Toy 1.0", roles: [.transcription],
                              platforms: [.macOS, .iOS], residency: residency)
    }

    func validate(_ installation: ModelInstallation) throws {
        guard let first = installation.artifact("model")?.files.first,
              FileManager.default.fileExists(atPath: installation.url(for: first, in: "model").path) else {
            throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey)
        }
    }

    func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        ModelAdditionProposal(artifacts: [try repository.artifact("model", include: ["*"])])
    }

    func load(_ installation: ModelInstallation, role: ModelRole, progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        log.add("load \(installation.key.variantKey)@\(installation.key.revision)")
        return ToyTranscriber(log: log, name: installation.key.variantKey)
    }
}

final class ToyTranscriber: Transcribing, @unchecked Sendable {
    let log: CallLog
    let name: String
    init(log: CallLog, name: String) { self.log = log; self.name = name }
    func transcribe(url: URL, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        log.add("transcribe \(name)")
        let word = RecognizedWord(text: " Hello", start: 0, end: 0.5, confidence: 0.9)
        return RecognitionResult(segments: [RecognizedSegment(start: 0, end: 0.5, text: " Hello", confidence: 0.9, words: [word])],
                                 language: "en", duration: 1)
    }
    func unload() { log.add("unload \(name)") }
}

/// A thread-safe record of what fakes were asked to do.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var calls: [String] { lock.withLock { entries } }
}

/// Hugging Face, scripted: repositories with commits, files, small file contents, and card info.
final class FakeHubClient: ModelHubClient, @unchecked Sendable {
    struct Repository {
        var head: ModelHubCommit
        var files: [String: [ModelHubFile]] = [:]
        var data: [String: Data] = [:]
        var info = ModelHubRepositoryInfo(license: "apache-2.0")
    }
    private let lock = NSLock()
    private var repositories: [String: Repository] = [:]
    private var _requests: [String] = []
    var requests: [String] { lock.withLock { _requests } }

    func set(_ name: String, _ repository: Repository) { lock.withLock { repositories[name] = repository } }

    /// Adds files (with digests computed from their content) at a commit, making it the head.
    func publish(_ name: String, commit: String, date: Date = Date(), title: String = "Update", files: [String: String],
                 license: String? = "apache-2.0", gated: Bool = false) {
        lock.withLock {
            var repository = repositories[name] ?? Repository(head: ModelHubCommit(id: commit))
            repository.head = ModelHubCommit(id: commit, date: date, title: title)
            repository.files[commit] = files.keys.sorted().map { path in
                let data = Data(files[path]!.utf8)
                return path.hasSuffix(".json")
                    ? ModelHubFile(path: path, size: Int64(data.count), gitOID: SyntheticModels.gitOID(data))
                    : ModelHubFile(path: path, size: Int64(data.count), sha256: SyntheticModels.sha256(data))
            }
            for (path, text) in files { repository.data["\(commit):\(path)"] = Data(text.utf8) }
            repository.info = ModelHubRepositoryInfo(license: license, gated: gated)
            repositories[name] = repository
        }
    }

    /// What a fetcher would download for `repository` at `commit`.
    func contents(_ name: String, commit: String) -> [String: Data] {
        lock.withLock {
            var result: [String: Data] = [:]
            for (key, data) in repositories[name]?.data ?? [:] where key.hasPrefix(commit + ":") {
                result[FakeFetcher.key(name, commit, String(key.dropFirst(commit.count + 1)))] = data
            }
            return result
        }
    }

    func commit(repository: String, reference: String) async throws -> ModelHubCommit {
        try lock.withLock {
            _requests.append("commit \(repository) \(reference)")
            guard let repo = repositories[repository] else { throw ModelHubError.notFound(repository) }
            if reference == "main" || reference == repo.head.id { return repo.head }
            guard repo.files[reference] != nil else { throw ModelHubError.notFound(reference) }
            return ModelHubCommit(id: reference)
        }
    }

    func files(repository: String, revision: String, path: String?) async throws -> [ModelHubFile] {
        try lock.withLock {
            _requests.append("files \(repository) \(revision) \(path ?? "")")
            guard let files = repositories[repository]?.files[revision] else { throw ModelHubError.notFound(repository) }
            guard let path else { return files }
            return files.filter { $0.path.hasPrefix(path + "/") }
        }
    }

    func data(repository: String, revision: String, path: String, maxBytes: Int) async throws -> Data {
        try lock.withLock {
            _requests.append("data \(repository) \(path)")
            guard let data = repositories[repository]?.data["\(revision):\(path)"] else { throw ModelHubError.notFound(path) }
            guard data.count <= maxBytes else { throw ModelHubError.tooLarge(path) }
            return data
        }
    }

    func info(repository: String) async throws -> ModelHubRepositoryInfo {
        try lock.withLock {
            guard let info = repositories[repository]?.info else { throw ModelHubError.notFound(repository) }
            return info
        }
    }
}
