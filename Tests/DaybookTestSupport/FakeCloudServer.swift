import Foundation

/// Anthropic, OpenAI, and OpenRouter in the test process, answering through a URLProtocol, so cloud requests run
/// without the network. Each server has a host of its own (`base`) and a session that reaches only it; it records
/// every request and answers with `handler`. Ordinary tests never reach a real provider.
public final class FakeCloudServer: @unchecked Sendable {
    public struct Request {
        public var method: String
        public var path: String
        public var query: String?
        public var headers: [String: String]
        public var body: Data

        public func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The body as JSON.
        public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        public var text: String { String(decoding: body, as: UTF8.self) }
    }

    public struct Response {
        public var status: Int
        public var headers: [String: String]
        /// Delivered one at a time, as a stream arrives.
        public var chunks: [Data]
        /// Fails the request after the chunks: a dropped connection.
        public var failure: URLError?

        public init(status: Int = 200, headers: [String: String] = [:], chunks: [Data] = [], failure: URLError? = nil) {
            self.status = status; self.headers = headers; self.chunks = chunks; self.failure = failure
        }

        public static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Response(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, chunks: [data])
        }

        /// Server-sent events, one chunk each: `event: <type>` and `data: <json>`.
        public static func events(_ events: [[String: Any]], headers: [String: String] = [:], failure: URLError? = nil) -> Response {
            let chunks = events.map { event -> Data in
                let data = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
                return Data("event: \((event["type"] as? String) ?? "message")\ndata: ".utf8) + data + Data("\n\n".utf8)
            }
            return Response(status: 200, headers: headers.merging(["Content-Type": "text/event-stream"]) { a, _ in a }, chunks: chunks, failure: failure)
        }

        public static func failure(_ code: URLError.Code) -> Response { Response(failure: URLError(code)) }
    }

    public let base: URL
    public let session: URLSession
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var handler: (Request) -> Response = { _ in Response(status: 404) }

    public init() {
        let host = "\(UUID().uuidString.lowercased()).cloud.test"
        base = URL(string: "https://\(host)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeCloudProtocol.self]
        session = URLSession(configuration: configuration)
        FakeCloudProtocol.register(self, host: host)
    }

    deinit { FakeCloudProtocol.unregister(host: base.host ?? "") }

    /// Answers every request from now on.
    public func handle(_ handler: @escaping (Request) -> Response) { lock.withLock { self.handler = handler } }

    public var requests: [Request] { lock.withLock { recorded } }

    /// Records the request, then answers it; the handler can read `requests`, this one included.
    fileprivate func answer(_ request: Request) -> Response {
        let handler = lock.withLock {
            recorded.append(request)
            return self.handler
        }
        return handler(request)
    }
}

private final class FakeCloudProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: FakeCloudServer] = [:]

    static func register(_ server: FakeCloudServer, host: String) { lock.withLock { servers[host] = server } }
    static func unregister(host: String) { lock.withLock { _ = servers.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".cloud.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.lock.withLock({ Self.servers[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let recorded = FakeCloudServer.Request(method: request.httpMethod ?? "GET", path: url.path, query: url.query,
                                               headers: request.allHTTPHeaderFields ?? [:], body: body)
        let response = server.answer(recorded)
        if response.chunks.isEmpty, response.status == 200, let failure = response.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if let failure = response.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

extension FakeCloudServer.Response {
    /// Anthropic's Messages stream for a reply of `text`'s pieces: a thinking block, then the text.
    public static func anthropicReply(_ text: [String], model: String = "claude-sonnet-5-5", inputTokens: Int = 1_200, outputTokens: Int = 340,
                                      stop: String = "end_turn", stopDetails: [String: Any]? = nil, prefix: [[String: Any]] = []) -> Self {
        var events: [[String: Any]] = [
            ["type": "message_start", "message": ["id": "msg_test", "type": "message", "role": "assistant", "model": model, "content": [],
                                                   "usage": ["input_tokens": inputTokens, "output_tokens": 1]]],
            ["type": "ping"],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": ""]],
            ["type": "content_block_stop", "index": 0]
        ] + prefix
        events.append(["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]])
        events += text.map { ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": $0]] }
        events.append(["type": "content_block_stop", "index": 1])
        var delta: [String: Any] = ["stop_reason": stop]
        if let stopDetails { delta["stop_details"] = stopDetails }
        events.append(["type": "message_delta", "delta": delta, "usage": ["output_tokens": outputTokens]])
        events.append(["type": "message_stop"])
        return .events(events)
    }

    /// OpenAI's Responses stream for a reply of `text`'s pieces, ending `completed` (or `incomplete`, with `incomplete`'s reason).
    public static func openAIReply(_ text: [String], model: String = "gpt-6.1-sol", inputTokens: Int = 900, outputTokens: Int = 280,
                                   incomplete: String? = nil, refusal: String? = nil) -> Self {
        var events: [[String: Any]] = [["type": "response.created", "sequence_number": 0,
                                        "response": ["id": "resp_test", "model": model, "status": "in_progress"]]]
        events += text.map { ["type": "response.output_text.delta", "item_id": "msg_test", "output_index": 1, "content_index": 0, "delta": $0] }
        if let refusal { events.append(["type": "response.refusal.delta", "item_id": "msg_test", "output_index": 1, "content_index": 0, "delta": refusal]) }
        var response: [String: Any] = ["id": "resp_test", "model": model, "status": incomplete == nil ? "completed" : "incomplete",
                                       "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens,
                                                 "output_tokens_details": ["reasoning_tokens": 40]]]
        if let incomplete { response["incomplete_details"] = ["reason": incomplete] }
        events.append(["type": incomplete == nil ? "response.completed" : "response.incomplete", "response": response])
        return .events(events)
    }
}
