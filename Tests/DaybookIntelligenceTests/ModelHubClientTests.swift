import Foundation
import XCTest
@testable import DaybookIntelligence

final class ModelHubClientTests: XCTestCase {
    func testMetadataLimitRejectsDeclaredAndUndeclaredOversizedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HuggingFaceHubClient(endpoint: URL(string: "https://hub.invalid")!, session: session)
        for path in ["declared", "chunked"] {
            do {
                _ = try await client.data(repository: "test/repo", revision: "test", path: path, maxBytes: 16)
                XCTFail("Accepted oversized \(path) response")
            } catch { XCTAssertEqual(error as? ModelHubError, .tooLarge(path)) }
        }
        let exact = try await client.data(repository: "test/repo", revision: "test", path: "exact", maxBytes: 16)
        XCTAssertEqual(exact, Data(repeating: 42, count: 16))
    }
}

extension ModelHubClientTests {
    /// A listed file with no checksum couldn't be verified after downloading, so the listing fails.
    func testAListedFileWithoutAChecksumIsRefused() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubTreeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HuggingFaceHubClient(endpoint: URL(string: "https://tree.invalid")!, session: session)
        let files = try await client.files(repository: "test/good", revision: "main", path: nil)
        XCTAssertEqual(files, [ModelHubFile(path: "config.json", size: 2, gitOID: String(repeating: "a", count: 40)),
                               ModelHubFile(path: "weights.bin", size: 9, sha256: String(repeating: "b", count: 64))])
        do {
            _ = try await client.files(repository: "test/bare", revision: "main", path: nil)
            XCTFail("Listed a file that can't be checked")
        } catch { XCTAssertEqual(error as? ModelHubError, .badResponse("weights.bin")) }
    }
}

/// Serves a tree listing: "good" has checksums for every file, "bare" lacks one.
private final class HubTreeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tree.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let checksum = url.path.contains("/good/")
            ? #""oid": "\#(String(repeating: "c", count: 40))", "lfs": {"oid": "\#(String(repeating: "b", count: 64))", "size": 9}"#
            : #""size": 9"#
        let body = #"[{"type": "file", "path": "config.json", "size": 2, "oid": "\#(String(repeating: "a", count: 40))"},"#
            + #" {"type": "directory", "path": "nested"}, {"type": "file", "path": "weights.bin", \#(checksum)}]"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HubResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "hub.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let declared = url.lastPathComponent == "declared"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: declared ? ["Content-Length": "1000000"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // No body for the oversized declared response: rejection must happen at the headers.
        if declared { client?.urlProtocolDidFinishLoading(self); return }
        client?.urlProtocol(self, didLoad: Data(repeating: 42, count: url.lastPathComponent == "exact" ? 16 : 32))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
