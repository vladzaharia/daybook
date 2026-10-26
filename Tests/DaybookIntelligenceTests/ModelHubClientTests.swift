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
