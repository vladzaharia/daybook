import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Cloud requests against a fake server (no network): model lists and key checks, each provider's request as sent,
/// their streams read, and every way a request fails as a plain message with Details.
final class CloudClientTests: XCTestCase {
    private let anthropicKey = CloudAPIKey("sk-ant-api03-TESTtestTESTtestTESTtest-gDAA")!
    private let openAIKey = CloudAPIKey("sk-proj-TESTtestTESTtestTESTtest-x9Qa")!

    private final class Waits: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TimeInterval] = []
        var all: [TimeInterval] { lock.withLock { values } }
        func add(_ value: TimeInterval) { lock.withLock { values.append(value) } }
    }

    private func client(_ server: FakeCloudServer, waits: Waits = Waits()) -> CloudClient {
        var client = CloudClient(session: server.session, endpoints: CloudEndpoints(base: server.base))
        client.wait = { waits.add($0) }
        return client
    }

    private func request(_ provider: CloudProvider, fallback: Bool = false, schema: String? = #"{"type":"object","properties":{"title":{"type":"string"},"overview":{"type":"string"}},"required":["title","overview"],"additionalProperties":false}"#) -> CloudRequest {
        CloudRequest(provider: provider, model: provider == .anthropic ? "claude-sonnet-5-5" : "gpt-6.1-sol",
                     modelName: provider == .anthropic ? "Claude Sonnet 5.5" : "GPT-6.1 Sol", instructions: "Be faithful.",
                     prompt: "Summarize: \"quoted\" words.", schema: schema, maxOutputTokens: 24_000, effort: .medium, refusalFallback: fallback)
    }

    private func key(_ provider: CloudProvider) -> CloudAPIKey { provider == .anthropic ? anthropicKey : openAIKey }

    // MARK: Model lists and key checks

    func testBehaviorAnthropicModelListReadsEveryPageWithItsLimitsAndEfforts() async throws {
        let server = FakeCloudServer()
        server.handle { request in
            if request.query?.contains("after_id=page-1-last") == true {
                return .json(["data": [["type": "model", "id": "claude-haiku-5-5", "display_name": "Claude Haiku 5.5"]], "has_more": false])
            }
            return .json(["data": [["type": "model", "id": "claude-sonnet-5-5", "display_name": "Claude Sonnet 5.5", "max_input_tokens": 1_000_000,
                                    "max_tokens": 128_000,
                                    "capabilities": ["effort": ["supported": true, "low": ["supported": true], "medium": ["supported": true],
                                                                "high": ["supported": true], "max": ["supported": true]]]]],
                          "has_more": true, "last_id": "page-1-last"])
        }
        let models = try await client(server).models(.anthropic, key: anthropicKey)
        XCTAssertEqual(models.map(\.id), ["claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(models[0].maxInputTokens, 1_000_000)
        XCTAssertEqual(models[0].maxOutputTokens, 128_000)
        XCTAssertEqual(models[0].efforts, ["low", "medium", "high"])
        XCTAssertNil(models[1].efforts)
        let first = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(first.path, "/v1/models")
        XCTAssertEqual(first.header("x-api-key"), anthropicKey.secret)
        XCTAssertEqual(first.header("anthropic-version"), "2023-06-01")
        XCTAssertNil(first.header("Authorization"))
        XCTAssertEqual(server.requests.count, 2)
    }

    func testBehaviorOpenAIModelListUsesTheBearerKey() async throws {
        let server = FakeCloudServer()
        server.handle { _ in .json(["object": "list", "data": [["id": "gpt-6.1-sol", "object": "model"], ["id": "whisper-1", "object": "model"]]]) }
        let models = try await client(server).models(.openai, key: openAIKey)
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol", "whisper-1"])
        XCTAssertEqual(server.requests.first?.header("Authorization"), "Bearer \(openAIKey.secret)")
        XCTAssertNil(server.requests.first?.header("x-api-key"))
    }

    func testBehaviorAKeyTheProviderRefusesSaysSoPlainlyWithoutTheKey() async throws {
        let server = FakeCloudServer()
        server.handle { _ in
            .json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"], "request_id": "req_123"], status: 401)
        }
        do {
            _ = try await client(server).models(.anthropic, key: anthropicKey)
            XCTFail("A refused key throws")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "Anthropic didn’t accept this key.")
            XCTAssertEqual(error.details, "HTTP 401 · authentication_error · invalid x-api-key · request req_123")
            XCTAssertFalse(error.details.contains(anthropicKey.secret))
        }
        server.handle { _ in
            .json(["error": ["message": "Incorrect API key provided: sk-proj-TESTtest****x9Qa.", "type": "invalid_request_error",
                             "code": "invalid_api_key"]], status: 401)
        }
        do {
            _ = try await client(server).models(.openai, key: openAIKey)
            XCTFail("A refused key throws")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "OpenAI didn’t accept this key.")
            XCTAssertTrue(error.details.contains("sk-proj-…x9Qa"), error.details)
        }
    }

    func testBehaviorOpenRouterListCarriesNothingAboutThePersonAndKeepsOnlyTheProvidersModels() async throws {
        let server = FakeCloudServer()
        server.handle { _ in
            .json(["data": [
                ["id": "anthropic/claude-sonnet-5.5", "name": "Anthropic: Claude Sonnet 5.5", "context_length": 1_000_000,
                 "pricing": ["prompt": "0.000002", "completion": "0.00001"], "top_provider": ["max_completion_tokens": 128_000],
                 "reasoning": ["supported_efforts": ["high", "medium", "low"]], "supported_parameters": ["structured_outputs"]],
                ["id": "anthropic/claude-sonnet-5.5:batch", "pricing": ["prompt": "0.000001", "completion": "0.000005"]],
                ["id": "openai/gpt-6.1-sol", "name": "OpenAI: GPT-6.1 Sol",
                 "pricing": ["prompt": "0.000002", "completion": "0.00001",
                             "overrides": [["min_prompt_tokens": 272_000, "prompt": "0.000004", "completion": "0.000015"]]]],
                ["id": "google/gemini-9", "pricing": ["prompt": "0.000001", "completion": "0.000002"]]
            ]])
        }
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let book = try await client(server).openRouterPrices(fetchedAt: fetched)
        XCTAssertEqual(book.fetchedAt, fetched)
        XCTAssertEqual(Set(book.models.keys), ["anthropic/claude-sonnet-5.5", "openai/gpt-6.1-sol"])
        XCTAssertEqual(book["anthropic/claude-sonnet-5.5"], OpenRouterModel(id: "anthropic/claude-sonnet-5.5", name: "Claude Sonnet 5.5",
                                                                            contextLength: 1_000_000, price: CloudPrice(input: 2, output: 10),
                                                                            maxOutputTokens: 128_000, efforts: ["high", "medium", "low"]))
        XCTAssertEqual(book["openai/gpt-6.1-sol"]?.price?.longPrompts, [CloudPrice.LongPrompt(aboveInputTokens: 272_000, input: 4, output: 15)])
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/v1/models")
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.header("Authorization"))
        XCTAssertNil(request.header("x-api-key"))
        XCTAssertNil(request.header("Cookie"))
        XCTAssertEqual(request.header("User-Agent"), "Daybook")
        XCTAssertTrue(request.body.isEmpty)
    }

    // MARK: Requests as sent

    func testBehaviorAnthropicRequestStreamsWithAdaptiveThinkingEffortAndTheSchemaInItsOrder() async throws {
        let server = FakeCloudServer()
        server.handle { _ in .anthropicReply(["{\"title\":\"T\",", "\"overview\":\"O\"}"]) }
        _ = try await client(server).respond(request(.anthropic), key: anthropicKey)
        let sent = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(sent.path, "/v1/messages")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.header("x-api-key"), anthropicKey.secret)
        XCTAssertNil(sent.header("anthropic-beta"))
        let body = try XCTUnwrap(sent.json)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 24_000)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "Be faithful.")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "medium")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["schema"] as? [String: Any])?["required"] as? [String], ["title", "overview"])
        XCTAssertTrue(sent.text.contains(#""properties":{"title":{"type":"string"},"overview":{"type":"string"}}"#), "The schema keeps its order")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "Summarize: \"quoted\" words.")
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(body["temperature"])
    }

    func testBehaviorAnthropicRefusalFallbackIsAskedForAndDroppedWhereTheAccountCantUseIt() async throws {
        let server = FakeCloudServer()
        server.handle { request in
            if request.json?["fallbacks"] != nil {
                return .json(["type": "error", "error": ["type": "invalid_request_error",
                                                         "message": "Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header."]],
                             status: 400)
            }
            return .anthropicReply(["{}"])
        }
        let reply = try await client(server).respond(request(.anthropic, fallback: true), key: anthropicKey)
        XCTAssertEqual(reply.text, "{}")
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(server.requests[0].json?["fallbacks"] as? String, "default")
        XCTAssertEqual(server.requests[0].header("anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertNil(server.requests[1].json?["fallbacks"])
        XCTAssertNil(server.requests[1].header("anthropic-beta"))
    }

    func testBehaviorOpenAIRequestStreamsUnstoredWithEffortAndAStrictSchema() async throws {
        let server = FakeCloudServer()
        server.handle { _ in .openAIReply(["{}"]) }
        _ = try await client(server).respond(request(.openai), key: openAIKey)
        let sent = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(sent.path, "/v1/responses")
        XCTAssertEqual(sent.header("Authorization"), "Bearer \(openAIKey.secret)")
        let body = try XCTUnwrap(sent.json)
        XCTAssertEqual(body["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(body["instructions"] as? String, "Be faithful.")
        XCTAssertEqual(body["input"] as? String, "Summarize: \"quoted\" words.")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 24_000)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false, "The conversation isn't kept on OpenAI's side")
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertNotNil(format["name"] as? String)
        XCTAssertNotNil(format["schema"] as? [String: Any])

        _ = try await client(server).respond(request(.openai, schema: nil), key: openAIKey)
        XCTAssertNil(server.requests.last?.json?["text"], "Free-form without a schema")
    }

    // MARK: Streams

    func testBehaviorStreamsGiveTheTextTheModelAndTheTokens() async throws {
        let server = FakeCloudServer()
        server.handle { _ in .anthropicReply(["{\"title\":", "\"Launch\"}"], model: "claude-sonnet-5-5", inputTokens: 21_000, outputTokens: 4_800) }
        let counts = Waits()
        var reply = try await client(server).respond(request(.anthropic), key: anthropicKey) { counts.add(TimeInterval($0)) }
        XCTAssertEqual(reply, CloudReply(text: "{\"title\":\"Launch\"}", model: "claude-sonnet-5-5", inputTokens: 21_000, outputTokens: 4_800, stop: .complete))
        XCTAssertEqual(counts.all, [9, 18], "Characters as they arrive")

        server.handle { _ in .openAIReply(["{\"a\":", "1}"], model: "gpt-6.1-sol-2026-09-29", inputTokens: 14_000, outputTokens: 5_200) }
        reply = try await client(server).respond(request(.openai), key: openAIKey)
        XCTAssertEqual(reply, CloudReply(text: "{\"a\":1}", model: "gpt-6.1-sol-2026-09-29", inputTokens: 14_000, outputTokens: 5_200, stop: .complete))
    }

    func testBehaviorAReplyCutOffAtItsLimitSaysSo() async throws {
        let server = FakeCloudServer()
        server.handle { _ in .anthropicReply(["{\"title\":\"Lau"], stop: "max_tokens") }
        let anthropic = try await client(server).respond(request(.anthropic), key: anthropicKey)
        XCTAssertEqual(anthropic.stop, .lengthCap)
        server.handle { _ in .openAIReply(["{\"title\":\"Lau"], incomplete: "max_output_tokens") }
        let openAI = try await client(server).respond(request(.openai), key: openAIKey)
        XCTAssertEqual(openAI.stop, .lengthCap)
    }

    func testBehaviorARefusalIsAPlainErrorWithItsReasonInDetails() async throws {
        let server = FakeCloudServer()
        server.handle { _ in .anthropicReply([], stop: "refusal", stopDetails: ["type": "refusal", "category": "cyber", "explanation": "Declined."]) }
        do {
            _ = try await client(server).respond(request(.anthropic), key: anthropicKey)
            XCTFail("A refusal throws")
        } catch let error as CloudError {
            XCTAssertEqual(error, .refused(model: "Claude Sonnet 5.5", category: "cyber", details: "Refused · category: cyber · Declined."))
            XCTAssertEqual(error.message, "Claude Sonnet 5.5 declined to summarize this conversation.")
        }
        XCTAssertEqual(server.requests.count, 1, "A refusal isn't tried again")
        server.handle { _ in .openAIReply([], refusal: "I can't help with that.") }
        do {
            _ = try await client(server).respond(request(.openai), key: openAIKey)
            XCTFail("A refusal throws")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "GPT-6.1 Sol declined to summarize this conversation.")
            XCTAssertTrue(error.details.contains("I can't help with that."))
        }
    }

    func testBehaviorAFallbackModelsReplyReplacesTheDeclinedPartAndNamesItsModel() async throws {
        let server = FakeCloudServer()
        server.handle { _ in
            .anthropicReply(["{\"title\":\"Fallback\"}"], prefix: [
                ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
                ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "{\"tit"]],
                ["type": "content_block_start", "index": 2, "content_block": ["type": "fallback", "from": ["model": "claude-sonnet-5-5"],
                                                                              "to": ["model": "claude-opus-4-8"]]]
            ])
        }
        let reply = try await client(server).respond(request(.anthropic, fallback: true), key: anthropicKey)
        XCTAssertEqual(reply.text, "{\"title\":\"Fallback\"}")
        XCTAssertEqual(reply.model, "claude-opus-4-8")
    }

    // MARK: Failures

    func testBehaviorARateLimitWaitsAsLongAsAskedThenTriesAgain() async throws {
        let server = FakeCloudServer()
        let waits = Waits()
        server.handle { request in
            server.requests.count == 1
                ? .json(["type": "error", "error": ["type": "rate_limit_error", "message": "Slow down"]], status: 429, headers: ["retry-after": "3"])
                : .anthropicReply(["{}"])
        }
        let reply = try await client(server, waits: waits).respond(request(.anthropic), key: anthropicKey)
        XCTAssertEqual(reply.text, "{}")
        XCTAssertEqual(waits.all, [3])
    }

    func testBehaviorARateLimitLongerThanAMinuteIsNotWaitedFor() async throws {
        let server = FakeCloudServer()
        let waits = Waits()
        server.handle { _ in
            .json(["error": ["message": "Rate limit reached", "type": "requests", "code": "rate_limit_exceeded"]], status: 429,
                  headers: ["x-ratelimit-reset-tokens": "6m0s"])
        }
        do {
            _ = try await client(server, waits: waits).respond(request(.openai), key: openAIKey)
            XCTFail("Throws")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "OpenAI is limiting requests from this key. Try again in a minute.")
            guard case .rateLimited(_, let after, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(after, 360)
        }
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(waits.all, [])
    }

    func testBehaviorOutOfCreditIsNotTriedAgain() async throws {
        let server = FakeCloudServer()
        server.handle { _ in
            .json(["error": ["message": "You exceeded your current quota.", "type": "insufficient_quota", "code": "insufficient_quota"]], status: 429)
        }
        do {
            _ = try await client(server).respond(request(.openai), key: openAIKey)
            XCTFail("Throws")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "Your OpenAI account is out of credit.")
        }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testBehaviorAnOverloadedProviderIsTriedAgainWithBackoff() async throws {
        let server = FakeCloudServer()
        let waits = Waits()
        server.handle { _ in
            server.requests.count < 3
                ? .events([["type": "message_start", "message": ["model": "claude-sonnet-5-5", "usage": ["input_tokens": 10]]],
                           ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]])
                : .anthropicReply(["{}"])
        }
        let reply = try await client(server, waits: waits).respond(request(.anthropic), key: anthropicKey)
        XCTAssertEqual(reply.text, "{}")
        XCTAssertEqual(waits.all, [2, 8])

        server.handle { _ in .json(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]], status: 529) }
        do {
            _ = try await client(server).respond(request(.anthropic), key: anthropicKey)
            XCTFail("Throws after three tries")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "Anthropic is busy. Try again in a few minutes.")
            XCTAssertTrue(error.details.hasPrefix("HTTP 529 · overloaded_error · Overloaded"))
        }
        XCTAssertEqual(server.requests.count, 6)
    }

    func testBehaviorOfflineFailsAtOnceAndADroppedConnectionIsTriedAgain() async throws {
        let server = FakeCloudServer()
        server.handle { _ in .failure(.notConnectedToInternet) }
        do {
            _ = try await client(server).respond(request(.anthropic), key: anthropicKey)
            XCTFail("Throws")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "You’re offline.")
        }
        XCTAssertEqual(server.requests.count, 1)

        let dropped = FakeCloudServer()
        dropped.handle { _ in
            dropped.requests.count == 1
                ? .events([["type": "message_start", "message": ["model": "claude-sonnet-5-5"]]], failure: URLError(.networkConnectionLost))
                : .anthropicReply(["{}"])
        }
        let reply = try await client(dropped).respond(request(.anthropic), key: anthropicKey)
        XCTAssertEqual(reply.text, "{}")
        XCTAssertEqual(dropped.requests.count, 2)

        let cut = FakeCloudServer()
        cut.handle { _ in .events([["type": "message_start", "message": ["model": "claude-sonnet-5-5"]]]) }
        do {
            _ = try await client(cut).respond(request(.anthropic), key: anthropicKey)
            XCTFail("A stream that ends without stopping broke off")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "The connection to Anthropic was lost.")
        }
        XCTAssertEqual(cut.requests.count, 3)
    }

    func testBehaviorAModelTheKeyCantUseSaysWhich() async throws {
        let server = FakeCloudServer()
        server.handle { _ in .json(["type": "error", "error": ["type": "not_found_error", "message": "model: claude-sonnet-5-5"]], status: 404) }
        do {
            _ = try await client(server).respond(request(.anthropic), key: anthropicKey)
            XCTFail("Throws")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "This key can’t use Claude Sonnet 5.5.")
        }
    }

    func testBehaviorRetryAfterReadsEveryFormProvidersUse() throws {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 429, httpVersion: nil, headerFields: headers)!
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CloudClient.retryAfter(response(["retry-after-ms": "1500"]), now: now), 1.5)
        XCTAssertEqual(CloudClient.retryAfter(response(["retry-after": "12"]), now: now), 12)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let eight = try XCTUnwrap(formatter.date(from: "Fri, 15 Jan 2027 08:00:00 GMT"))
        XCTAssertEqual(CloudClient.retryAfter(response(["retry-after": "Fri, 15 Jan 2027 08:00:30 GMT"]), now: eight), 30)
        XCTAssertEqual(CloudClient.retryAfter(response(["x-ratelimit-reset-requests": "1s", "x-ratelimit-reset-tokens": "6m0s"]), now: now), 360)
        XCTAssertEqual(CloudClient.duration("250ms"), 0.25)
        XCTAssertEqual(CloudClient.duration("1h2m3.5s"), 3_723.5)
        XCTAssertNil(CloudClient.retryAfter(response([:]), now: now))
    }
}
