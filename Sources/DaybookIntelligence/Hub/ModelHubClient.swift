import DaybookKit
import Foundation

/// A commit on Hugging Face.
public struct ModelHubCommit: Codable, Hashable, Sendable {
    public var id: String
    public var date: Date?
    public var title: String?
    public init(id: String, date: Date? = nil, title: String? = nil) { self.id = id; self.date = date; self.title = title }
}

/// One file in a repository listing, with what the store needs to verify it.
public struct ModelHubFile: Codable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    /// SHA-256 of the content, for LFS files.
    public var sha256: String?
    /// The git blob ID, for small files.
    public var gitOID: String?
    public init(path: String, size: Int64, sha256: String? = nil, gitOID: String? = nil) {
        self.path = path; self.size = size; self.sha256 = sha256; self.gitOID = gitOID
    }

    public var manifestFile: ModelFile { ModelFile(path: path, size: size, sha256: sha256, gitOID: gitOID) }
}

/// What a repository declares about itself.
public struct ModelHubRepositoryInfo: Codable, Hashable, Sendable {
    /// The card's license identifier ("apache-2.0", "other").
    public var license: String?
    /// The card's license name, for "other" licenses ("qwen-research").
    public var licenseName: String?
    public var licenseURL: String?
    /// Gated repositories need an account and accepted terms; Daybook doesn't download those.
    public var gated: Bool
    public init(license: String? = nil, licenseName: String? = nil, licenseURL: String? = nil, gated: Bool = false) {
        self.license = license; self.licenseName = licenseName; self.licenseURL = licenseURL; self.gated = gated
    }
}

/// Read-only Hugging Face metadata, for update checks and adding models. Never used to download
/// weights (that's `ModelArtifactFetcher`), and never called unless the person asks: checking for
/// updates is opt-in. Tests inject a fake.
public protocol ModelHubClient: Sendable {
    /// The commit a branch or commit reference names now.
    func commit(repository: String, reference: String) async throws -> ModelHubCommit
    /// Files at a commit, under `path` (nil for the whole repository), with sizes and digests.
    func files(repository: String, revision: String, path: String?) async throws -> [ModelHubFile]
    /// A small file's content (a config, a tokenizer config), refused above `maxBytes`.
    func data(repository: String, revision: String, path: String, maxBytes: Int) async throws -> Data
    func info(repository: String) async throws -> ModelHubRepositoryInfo
}

public enum ModelHubError: LocalizedError, Equatable {
    case notFound(String)
    case tooLarge(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): return "Hugging Face has no \(what)."
        case .tooLarge(let path): return "\(path) is too large to inspect."
        case .badResponse(let what): return "Hugging Face sent an unexpected reply for \(what)."
        }
    }
}

/// The live client: huggingface.co's public JSON API, without credentials.
public struct HuggingFaceHubClient: ModelHubClient {
    public var endpoint: URL
    public var session: URLSession

    public init(endpoint: URL = URL(string: "https://huggingface.co")!, session: URLSession = .shared) {
        self.endpoint = endpoint; self.session = session
    }

    public func commit(repository: String, reference: String) async throws -> ModelHubCommit {
        struct Commit: Decodable { let id: String; let title: String?; let date: String? }
        let url = api(repository, "commits", reference)
        let (commits, _): ([Commit], _) = try await get(url, as: [Commit].self)
        guard let first = commits.first else { throw ModelHubError.notFound("commit \(reference) in \(repository)") }
        return ModelHubCommit(id: first.id, date: first.date.flatMap(Self.date), title: first.title)
    }

    public func files(repository: String, revision: String, path: String?) async throws -> [ModelHubFile] {
        struct Entry: Decodable {
            struct LFS: Decodable { let oid: String; let size: Int64 }
            let type: String; let path: String; let size: Int64?; let oid: String?; let lfs: LFS?
        }
        var components = URLComponents(url: api(repository, "tree", revision, path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        var next: URL? = components.url
        var result: [ModelHubFile] = []
        while let url = next {
            let (entries, response) = try await get(url, as: [Entry].self)
            result += entries.filter { $0.type == "file" }.map { entry in
                entry.lfs.map { ModelHubFile(path: entry.path, size: $0.size, sha256: $0.oid) }
                    ?? ModelHubFile(path: entry.path, size: entry.size ?? 0, gitOID: entry.oid)
            }
            next = Self.nextPage(response)
        }
        return result
    }

    public func data(repository: String, revision: String, path: String, maxBytes: Int) async throws -> Data {
        var url = endpoint.appendingPathComponent(repository).appendingPathComponent("resolve").appendingPathComponent(revision)
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ModelHubError.notFound(path) }
        guard data.count <= maxBytes else { throw ModelHubError.tooLarge(path) }
        return data
    }

    public func info(repository: String) async throws -> ModelHubRepositoryInfo {
        struct Card: Decodable { let license: String?; let license_name: String?; let license_link: String? }
        struct Info: Decodable {
            let cardData: Card?; let gated: Gated?
            enum Gated: Decodable {
                case flag(Bool), mode(String)
                init(from decoder: Decoder) throws {
                    let value = try decoder.singleValueContainer()
                    if let flag = try? value.decode(Bool.self) { self = .flag(flag) } else { self = .mode(try value.decode(String.self)) }
                }
                var isGated: Bool { if case .flag(let flag) = self { return flag }; return true }
            }
        }
        let (info, _) = try await get(endpoint.appendingPathComponent("api/models").appendingPathComponent(repository), as: Info.self)
        return ModelHubRepositoryInfo(license: info.cardData?.license, licenseName: info.cardData?.license_name,
                                      licenseURL: info.cardData?.license_link, gated: info.gated?.isGated ?? false)
    }

    // MARK: Helpers

    private func api(_ repository: String, _ kind: String, _ revision: String, _ path: String? = nil) -> URL {
        var url = endpoint.appendingPathComponent("api/models").appendingPathComponent(repository)
            .appendingPathComponent(kind).appendingPathComponent(revision)
        for component in (path ?? "").split(separator: "/") { url.appendPathComponent(String(component)) }
        return url
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> (T, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelHubError.badResponse(url.path) }
        guard http.statusCode == 200 else { throw ModelHubError.notFound(url.path) }
        do { return (try JSONDecoder().decode(T.self, from: data), http) }
        catch { throw ModelHubError.badResponse(url.path) }
    }

    static func nextPage(_ response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            if let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end {
                return URL(string: String(part[part.index(after: start)..<end]))
            }
        }
        return nil
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
