import Foundation

/// Where cloud requests go: the providers' APIs and OpenRouter's model list. Tests and the debug
/// `--cloud-check` point them at a local server.
public struct CloudEndpoints: Equatable, Sendable {
    public var anthropic: URL
    public var openai: URL
    public var openRouter: URL

    public init(anthropic: URL, openai: URL, openRouter: URL) {
        self.anthropic = anthropic; self.openai = openai; self.openRouter = openRouter
    }

    /// Every endpoint at one base URL.
    public init(base: URL) { self.init(anthropic: base, openai: base, openRouter: base) }

    public static let live = CloudEndpoints(anthropic: URL(string: "https://api.anthropic.com")!, openai: URL(string: "https://api.openai.com")!,
                                            openRouter: URL(string: "https://openrouter.ai/api")!)

    func base(_ provider: CloudProvider) -> URL { provider == .anthropic ? anthropic : openai }
}

/// One summary request: our instructions and prompt, and the JSON Schema the reply must follow.
public struct CloudRequest: Equatable, Sendable {
    public var provider: CloudProvider
    public var model: String
    /// For messages: "Claude Sonnet 5.5".
    public var modelName: String
    public var instructions: String
    public var prompt: String
    /// JSON Schema text, sent as written so its properties keep their order (the order a reply is written in);
    /// nil for a free-form reply.
    public var schema: String?
    public var maxOutputTokens: Int
    public var effort: CloudEffort
    /// Anthropic's server-side fallback on a refusal (`fallbacks: "default"`).
    public var refusalFallback: Bool

    public init(provider: CloudProvider, model: String, modelName: String, instructions: String, prompt: String, schema: String?,
                maxOutputTokens: Int, effort: CloudEffort, refusalFallback: Bool = false) {
        self.provider = provider; self.model = model; self.modelName = modelName; self.instructions = instructions; self.prompt = prompt
        self.schema = schema; self.maxOutputTokens = maxOutputTokens; self.effort = effort; self.refusalFallback = refusalFallback
    }
}

/// A finished reply: its text, the model that wrote it, and the tokens billed.
public struct CloudReply: Equatable, Sendable {
    public enum Stop: Equatable, Sendable {
        case complete
        /// It reached `maxOutputTokens` before it finished.
        case lengthCap
    }
    public var text: String
    /// The model the provider says wrote it (a refusal fallback can name another).
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var stop: Stop

    public init(text: String, model: String, inputTokens: Int, outputTokens: Int, stop: Stop) {
        self.text = text; self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.stop = stop
    }
}

/// The HTTP side of cloud summaries (docs/cloud.md, "Requests"): each provider's model list (which also checks a
/// key), OpenRouter's model list for prices (no key, nothing about the person), and a streamed reply. Rate limits,
/// an overloaded provider, and a broken connection are tried again, up to `attempts` times, waiting as long as the
/// provider asks (up to a minute) or 2 s, then 8 s.
public struct CloudClient: Sendable {
    public static let anthropicVersion = "2023-06-01"
    /// The beta that `fallbacks: "default"` needs.
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let schemaPlaceholder = "__DAYBOOK_SCHEMA__"

    public var session: URLSession
    public var endpoints: CloudEndpoints
    public var attempts = 3
    /// Waits between tries; tests make it instant.
    public var wait: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    public init(session: URLSession = CloudClient.sharedSession, endpoints: CloudEndpoints = .live) {
        self.session = session; self.endpoints = endpoints
    }

    /// Ephemeral, so nothing a request sends or receives is cached on disk. A reply can pause for minutes while the
    /// model reasons, so a request waits 5 minutes between bytes and an hour in all.
    public static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3_600
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: Model lists

    /// The models `key` reaches: Anthropic's `GET /v1/models` (every page) or OpenAI's. Also the key check:
    /// it throws `.badKey` when the provider doesn't accept the key.
    public func models(_ provider: CloudProvider, key: CloudAPIKey) async throws -> [CloudListedModel] {
        switch provider {
        case .anthropic:
            var models: [CloudListedModel] = []
            var after: String?
            repeat {
                var components = URLComponents(url: endpoints.anthropic.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
                let data = try await get(components.url!, provider: provider, key: key)
                let page: AnthropicModelPage
                do { page = try JSONDecoder().decode(AnthropicModelPage.self, from: data) }
                catch { throw CloudError.unreadable(provider, details: "The model list: \(error.localizedDescription)") }
                models += page.data.map(\.listed)
                after = page.has_more == true ? page.last_id : nil
            } while after != nil && models.count < 10_000
            return models
        case .openai:
            let data = try await get(endpoints.openai.appendingPathComponent("v1/models"), provider: provider, key: key)
            do { return try JSONDecoder().decode(OpenAIModelPage.self, from: data).data.map { CloudListedModel(id: $0.id) } }
            catch { throw CloudError.unreadable(provider, details: "The model list: \(error.localizedDescription)") }
        }
    }

    /// OpenRouter's model list, for prices and limits. It needs no key, and the request carries nothing about the
    /// person: no key, no cookies, a bare user agent.
    public func openRouterPrices(fetchedAt: Date) async throws -> CloudPriceBook {
        var request = URLRequest(url: endpoints.openRouter.appendingPathComponent("v1/models"))
        request.setValue("Daybook", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await open(request, provider: nil, model: nil)
        let data = try await collect(bytes, limit: 32 << 20)
        guard (200..<300).contains(response.statusCode) else {
            throw CloudError.rejected(.openai, details: "OpenRouter: HTTP \(response.statusCode)")
        }
        return try CloudPriceBook(openRouterList: data, fetchedAt: fetchedAt)
    }

    private func get(_ url: URL, provider: CloudProvider, key: CloudAPIKey) async throws -> Data {
        var request = URLRequest(url: url)
        authorize(&request, provider: provider, key: key)
        let (bytes, response) = try await open(request, provider: provider, model: nil)
        let data = try await collect(bytes, limit: 16 << 20)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, body: data, response: response, provider: provider, model: nil)
        }
        return data
    }

    private func authorize(_ request: inout URLRequest, provider: CloudProvider, key: CloudAPIKey) {
        switch provider {
        case .anthropic:
            request.setValue(key.secret, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openai:
            request.setValue("Bearer \(key.secret)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    // MARK: Replies

    /// A streamed reply to `request`. `received` hears how many characters of reply have arrived, as they do.
    /// A refusal throws `.refused`; a reply cut off at `maxOutputTokens` comes back with `.lengthCap`.
    public func respond(_ request: CloudRequest, key: CloudAPIKey,
                        received: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> CloudReply {
        var fallback = request.refusalFallback
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await respondOnce(request, fallback: fallback, key: key, received: received)
            } catch let error as CloudError {
                // An account the fallback beta isn't open to: the same request without it, once.
                if fallback, case .rejected(_, let details) = error,
                   details.localizedCaseInsensitiveContains("fallback") || details.localizedCaseInsensitiveContains("anthropic-beta") {
                    fallback = false
                    attempt -= 1
                    continue
                }
                guard attempt < attempts, let delay = error.retryDelay(attempt: attempt) else { throw error }
                try await wait(delay)
            }
        }
    }

    func body(_ request: CloudRequest, fallback: Bool) throws -> Data {
        var body: [String: Any]
        switch request.provider {
        case .anthropic:
            var output: [String: Any] = ["effort": request.effort.rawValue]
            if request.schema != nil { output["format"] = ["type": "json_schema", "schema": Self.schemaPlaceholder] }
            body = ["model": request.model, "max_tokens": request.maxOutputTokens, "stream": true,
                    "thinking": ["type": "adaptive"], "output_config": output, "system": request.instructions,
                    "messages": [["role": "user", "content": request.prompt]]]
            if fallback { body["fallbacks"] = "default" }
        case .openai:
            body = ["model": request.model, "instructions": request.instructions, "input": request.prompt,
                    "reasoning": ["effort": request.effort.rawValue], "max_output_tokens": request.maxOutputTokens,
                    "stream": true, "store": false]
            if request.schema != nil {
                body["text"] = ["format": ["type": "json_schema", "name": "conversation_summary", "strict": true, "schema": Self.schemaPlaceholder]]
            }
        }
        var text = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        if let schema = request.schema {
            text = text.replacingOccurrences(of: "\"\(Self.schemaPlaceholder)\"", with: schema)
        }
        return Data(text.utf8)
    }

    private func respondOnce(_ request: CloudRequest, fallback: Bool, key: CloudAPIKey,
                             received: @escaping @Sendable (Int) -> Void) async throws -> CloudReply {
        let path = request.provider == .anthropic ? "v1/messages" : "v1/responses"
        var http = URLRequest(url: endpoints.base(request.provider).appendingPathComponent(path))
        http.httpMethod = "POST"
        authorize(&http, provider: request.provider, key: key)
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if fallback && request.provider == .anthropic { http.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        http.httpBody = try body(request, fallback: fallback)
        let (bytes, response) = try await open(http, provider: request.provider, model: request.modelName)
        guard (200..<300).contains(response.statusCode) else {
            let data = try await collect(bytes, limit: 1 << 20)
            throw Self.error(status: response.statusCode, body: data, response: response, provider: request.provider, model: request.modelName)
        }
        var stream = StreamReader(provider: request.provider, model: request.model, modelName: request.modelName)
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                let before = stream.text.count
                try stream.read(event)
                if stream.text.count != before { received(stream.text.count) }
                if stream.finished { break }
            }
        } catch let error as URLError {
            throw Self.error(error, provider: request.provider)
        }
        return try stream.reply()
    }

    // MARK: Transport

    private func open(_ request: URLRequest, provider: CloudProvider?, model: String?) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CloudError.unreadable(provider ?? .openai, details: "Not an HTTP response.")
            }
            return (bytes, http)
        } catch let error as URLError {
            throw Self.error(error, provider: provider ?? .openai)
        }
    }

    private func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch let error as URLError {
            throw Self.error(error, provider: .openai)
        }
        return data
    }

    static func error(_ error: URLError, provider: CloudProvider) -> Error {
        let details = CloudError.scrubbed("\(error.localizedDescription) (URLError \(error.code.rawValue))")
        switch error.code {
        case .cancelled: return CancellationError()
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return CloudError.offline(details: details)
        default: return CloudError.connectionLost(provider, details: details)
        }
    }

    /// An HTTP error as a `CloudError`, from its status, the provider's error type and code, and its headers.
    static func error(status: Int, body: Data, response: HTTPURLResponse, provider: CloudProvider, model: String?) -> CloudError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let type = error?["type"] as? String ?? json?["type"] as? String
        let code = error?["code"] as? String
        let message = error?["message"] as? String ?? (json == nil ? String(decoding: body.prefix(400), as: UTF8.self) : nil)
        let requestID = response.value(forHTTPHeaderField: "request-id") ?? response.value(forHTTPHeaderField: "x-request-id")
            ?? json?["request_id"] as? String
        let details = CloudError.scrubbed(["HTTP \(status)", type, code, message, requestID.map { "request \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        if type == "billing_error" || code == "insufficient_quota" || status == 402 { return .noCredit(provider, details: details) }
        switch status {
        case 401: return .badKey(provider, details: details)
        case 403: return model.map { .modelUnavailable(provider, model: $0, details: details) } ?? .badKey(provider, details: details)
        case 404: return model.map { .modelUnavailable(provider, model: $0, details: details) } ?? .rejected(provider, details: details)
        case 429: return .rateLimited(provider, retryAfter: retryAfter(response), details: details)
        case 500..<600: return .busy(provider, details: details)
        default:
            if type == "overloaded_error" { return .busy(provider, details: details) }
            return .rejected(provider, details: details)
        }
    }

    /// How long the provider asked to wait: `retry-after-ms`, `retry-after` (seconds or a date), else the longer of
    /// OpenAI's rate-limit resets ("6m0s", "1s", "250ms").
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        if let ms = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init) { return ms / 1_000 }
        if let value = response.value(forHTTPHeaderField: "retry-after") {
            if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) { return seconds }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        let resets = ["x-ratelimit-reset-requests", "x-ratelimit-reset-tokens"].compactMap {
            response.value(forHTTPHeaderField: $0).flatMap(duration)
        }
        return resets.max()
    }

    /// "6m0s", "1s", "250ms", "1h2m3.5s" in seconds.
    static func duration(_ text: String) -> TimeInterval? {
        guard let pattern = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)(ms|h|m|s)"#) else { return nil }
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return nil }
        return matches.reduce(0) { total, match in
            guard let number = Range(match.range(at: 1), in: text).flatMap({ Double(text[$0]) }),
                  let unit = Range(match.range(at: 2), in: text).map({ String(text[$0]) }) else { return total }
            switch unit {
            case "ms": return total + number / 1_000
            case "h": return total + number * 3_600
            case "m": return total + number * 60
            default: return total + number
            }
        }
    }
}

// MARK: - Streams

/// Reads a reply's server-sent events, Anthropic's Messages or OpenAI's Responses, into its text, usage, and
/// how it stopped.
struct StreamReader {
    let provider: CloudProvider
    var model: String
    let modelName: String
    private(set) var text = ""
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var finished = false
    private var stop: CloudReply.Stop?
    private var refusal: (category: String?, words: String)?

    init(provider: CloudProvider, model: String, modelName: String) {
        self.provider = provider; self.model = model; self.modelName = modelName
    }

    mutating func read(_ event: [String: Any]) throws {
        switch provider {
        case .anthropic: try readAnthropic(event)
        case .openai: try readOpenAI(event)
        }
    }

    private mutating func readAnthropic(_ event: [String: Any]) throws {
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            if let name = message?["model"] as? String { model = name }
            if let usage = message?["usage"] as? [String: Any] { readAnthropicUsage(usage) }
        case "content_block_start":
            // A refusal fallback: the declined model's partial text is discarded, and the next model writes anew.
            if let block = event["content_block"] as? [String: Any], block["type"] as? String == "fallback" {
                text = ""
                if let to = block["to"] as? [String: Any], let name = to["model"] as? String { model = name }
            }
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let piece = delta["text"] as? String {
                text += piece
            }
        case "message_delta":
            if let usage = event["usage"] as? [String: Any] { readAnthropicUsage(usage) }
            let delta = event["delta"] as? [String: Any]
            switch delta?["stop_reason"] as? String {
            case "refusal"?:
                let details = (delta?["stop_details"] as? [String: Any]) ?? (event["stop_details"] as? [String: Any])
                refusal = (details?["category"] as? String, details?["explanation"] as? String ?? "")
            case "max_tokens"?: stop = .lengthCap
            case "model_context_window_exceeded"?:
                throw CloudError.tooLong(model: modelName, details: "stop_reason: model_context_window_exceeded")
            case .some: stop = .complete
            case nil: break
            }
        case "message_stop":
            finished = true
        case "error":
            let error = event["error"] as? [String: Any]
            throw Self.streamError(type: error?["type"] as? String, code: nil, message: error?["message"] as? String, provider: provider, model: modelName)
        default: break
        }
    }

    private mutating func readAnthropicUsage(_ usage: [String: Any]) {
        let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
        inputTokens = max(inputTokens, input)
        if let output = usage["output_tokens"] as? Int { outputTokens = max(outputTokens, output) }
    }

    private mutating func readOpenAI(_ event: [String: Any]) throws {
        switch event["type"] as? String {
        case "response.created"?, "response.in_progress"?:
            if let name = (event["response"] as? [String: Any])?["model"] as? String { model = name }
        case "response.output_text.delta"?:
            if let piece = event["delta"] as? String { text += piece }
        case "response.refusal.delta"?:
            refusal = (nil, (refusal?.words ?? "") + ((event["delta"] as? String) ?? ""))
        case "response.completed"?:
            let response = event["response"] as? [String: Any]
            readOpenAIResponse(response)
            if refusal == nil, let refused = Self.refusalWords(response) { refusal = (nil, refused) }
            stop = .complete
            finished = true
        case "response.incomplete"?:
            let response = event["response"] as? [String: Any]
            readOpenAIResponse(response)
            let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String
            if reason == "content_filter" { refusal = (reason, refusal?.words ?? "") } else { stop = .lengthCap }
            finished = true
        case "response.failed"?:
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            throw Self.streamError(type: nil, code: error?["code"] as? String, message: error?["message"] as? String, provider: provider, model: modelName)
        case "error"?:
            let error = (event["error"] as? [String: Any]) ?? event
            throw Self.streamError(type: error["type"] as? String, code: error["code"] as? String, message: error["message"] as? String,
                                   provider: provider, model: modelName)
        default: break
        }
    }

    private mutating func readOpenAIResponse(_ response: [String: Any]?) {
        if let name = response?["model"] as? String { model = name }
        if let usage = response?["usage"] as? [String: Any] {
            inputTokens = max(inputTokens, (usage["input_tokens"] as? Int) ?? 0)
            outputTokens = max(outputTokens, (usage["output_tokens"] as? Int) ?? 0)
        }
    }

    /// A refusal in a finished response's output, when the deltas didn't carry it.
    private static func refusalWords(_ response: [String: Any]?) -> String? {
        let items = (response?["output"] as? [[String: Any]]) ?? []
        for item in items {
            for content in (item["content"] as? [[String: Any]]) ?? [] where content["type"] as? String == "refusal" {
                return content["refusal"] as? String ?? ""
            }
        }
        return nil
    }

    static func streamError(type: String?, code: String?, message: String?, provider: CloudProvider, model: String) -> CloudError {
        let details = CloudError.scrubbed(["Stream error", type, code, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        switch type ?? code ?? "" {
        case "overloaded_error", "api_error", "server_error": return .busy(provider, details: details)
        case "rate_limit_error", "rate_limit_exceeded": return .rateLimited(provider, retryAfter: nil, details: details)
        case "insufficient_quota", "billing_error": return .noCredit(provider, details: details)
        case "authentication_error", "invalid_api_key": return .badKey(provider, details: details)
        case "not_found_error", "model_not_found": return .modelUnavailable(provider, model: model, details: details)
        default: return .rejected(provider, details: details)
        }
    }

    /// The reply, once the stream has ended. A stream that ended without saying how it stopped broke off.
    func reply() throws -> CloudReply {
        if let refusal {
            let details = ["Refused", refusal.category.map { "category: \($0)" }, refusal.words.isEmpty ? nil : refusal.words]
                .compactMap { $0 }.joined(separator: " · ")
            throw CloudError.refused(model: modelName, category: refusal.category, details: details)
        }
        guard let stop else {
            throw CloudError.connectionLost(provider, details: "The reply stopped before it finished.")
        }
        return CloudReply(text: text, model: model, inputTokens: inputTokens, outputTokens: outputTokens, stop: stop)
    }
}

// MARK: - Model list formats

private struct AnthropicModelPage: Decodable {
    struct Model: Decodable {
        var id: String
        var display_name: String?
        var max_input_tokens: Int?
        var max_tokens: Int?
        var capabilities: Capabilities?

        struct Capabilities: Decodable {
            struct Supported: Decodable { var supported: Bool? }
            struct Effort: Decodable {
                var supported: Bool?
                var low: Supported?, medium: Supported?, high: Supported?
            }
            var effort: Effort?
        }

        var listed: CloudListedModel {
            var efforts: [String]?
            if let effort = capabilities?.effort, effort.supported == true {
                efforts = [("low", effort.low), ("medium", effort.medium), ("high", effort.high)].compactMap { $0.1?.supported == true ? $0.0 : nil }
            }
            return CloudListedModel(id: id, displayName: display_name, maxInputTokens: max_input_tokens, maxOutputTokens: max_tokens, efforts: efforts)
        }
    }
    var data: [Model]
    var has_more: Bool?
    var last_id: String?
}

private struct OpenAIModelPage: Decodable {
    struct Model: Decodable { var id: String }
    var data: [Model]
}
