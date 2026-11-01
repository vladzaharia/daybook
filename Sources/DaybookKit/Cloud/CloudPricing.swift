import Foundation

/// What a cloud model charges, in USD per million tokens, with any higher rate a long prompt pays
/// (Claude Haiku 5.5 over 100K input tokens, OpenAI's models over 272K).
public struct CloudPrice: Codable, Equatable, Hashable, Sendable {
    public struct LongPrompt: Codable, Equatable, Hashable, Sendable {
        /// The rate applies to a prompt of more than this many tokens.
        public var aboveInputTokens: Int
        public var input: Double
        public var output: Double
    }

    public var input: Double
    public var output: Double
    public var longPrompts: [LongPrompt]

    public init(input: Double, output: Double, longPrompts: [LongPrompt] = []) {
        self.input = input; self.output = output; self.longPrompts = longPrompts
    }

    /// The rates a prompt of `inputTokens` pays.
    public func rates(inputTokens: Int) -> (input: Double, output: Double) {
        guard let tier = longPrompts.filter({ inputTokens > $0.aboveInputTokens }).max(by: { $0.aboveInputTokens < $1.aboveInputTokens }) else {
            return (input, output)
        }
        return (tier.input, tier.output)
    }

    /// In USD.
    public func cost(inputTokens: Int, outputTokens: Int) -> Double {
        let rates = rates(inputTokens: inputTokens)
        return (Double(inputTokens) * rates.input + Double(outputTokens) * rates.output) / 1_000_000
    }
}

/// One model in OpenRouter's list (`GET https://openrouter.ai/api/v1/models`), as far as Daybook reads it.
public struct OpenRouterModel: Codable, Equatable, Sendable {
    /// "anthropic/claude-sonnet-5.5", "openai/gpt-6.1-sol".
    public var id: String
    /// "Claude Sonnet 5.5": OpenRouter's name less its "Anthropic: " prefix.
    public var name: String?
    public var contextLength: Int?
    public var price: CloudPrice?
    public var maxOutputTokens: Int?
    /// The reasoning efforts the model takes ("low", "medium", "high", …); nil when OpenRouter doesn't say.
    public var efforts: [String]?
    public var structuredOutputs: Bool

    public init(id: String, name: String? = nil, contextLength: Int? = nil, price: CloudPrice? = nil, maxOutputTokens: Int? = nil,
                efforts: [String]? = nil, structuredOutputs: Bool = true) {
        self.id = id; self.name = name; self.contextLength = contextLength; self.price = price
        self.maxOutputTokens = maxOutputTokens; self.efforts = efforts; self.structuredOutputs = structuredOutputs
    }
}

/// Prices and limits by OpenRouter ID: OpenRouter's list when it could be fetched (kept for a day), over the
/// snapshot bundled with Daybook (`Resources/CloudPrices.json`). Only Anthropic's and OpenAI's models are
/// kept, and never the half-price ":batch" listings (summaries are wanted now).
public struct CloudPriceBook: Codable, Equatable, Sendable {
    public var models: [String: OpenRouterModel]
    /// When OpenRouter's list was fetched; nil for the bundled snapshot alone.
    public var fetchedAt: Date?

    public init(models: [String: OpenRouterModel] = [:], fetchedAt: Date? = nil) {
        self.models = models; self.fetchedAt = fetchedAt
    }

    public static let snapshot: CloudPriceBook = {
        guard let url = Bundle.module.url(forResource: "CloudPrices", withExtension: "json"), let data = try? Data(contentsOf: url),
              let book = try? CloudPriceBook(openRouterList: data, fetchedAt: nil) else {
            assertionFailure("The bundled cloud prices couldn't be read.")
            return CloudPriceBook()
        }
        return book
    }()

    /// From OpenRouter's response: `data[]` with prices as strings in USD per token.
    public init(openRouterList data: Data, fetchedAt: Date?) throws {
        let list = try JSONDecoder().decode(Listing.self, from: data)
        var models: [String: OpenRouterModel] = [:]
        for entry in list.data where (entry.id.hasPrefix("anthropic/") || entry.id.hasPrefix("openai/")) && !entry.id.contains(":") {
            models[entry.id] = entry.model
        }
        self.init(models: models, fetchedAt: fetchedAt)
    }

    /// This book's models over `older`'s.
    public func merged(over older: CloudPriceBook) -> CloudPriceBook {
        CloudPriceBook(models: older.models.merging(models) { _, new in new }, fetchedAt: fetchedAt ?? older.fetchedAt)
    }

    public subscript(id: String) -> OpenRouterModel? { models[id] }

    // MARK: OpenRouter's format

    private struct Listing: Decodable { var data: [Entry] }

    private struct Entry: Decodable {
        struct Pricing: Decodable {
            struct Override: Decodable {
                var min_prompt_tokens: Int?
                var prompt: String?
                var completion: String?
            }
            var prompt: String?
            var completion: String?
            var overrides: [Override]?
        }
        struct TopProvider: Decodable { var max_completion_tokens: Int? }
        struct Reasoning: Decodable { var supported_efforts: [String]? }

        var id: String
        var name: String?
        var context_length: Int?
        var pricing: Pricing?
        var top_provider: TopProvider?
        var reasoning: Reasoning?
        var supported_parameters: [String]?

        var model: OpenRouterModel {
            var price: CloudPrice?
            if let input = Self.perMillion(pricing?.prompt), let output = Self.perMillion(pricing?.completion) {
                let long = (pricing?.overrides ?? []).compactMap { override -> CloudPrice.LongPrompt? in
                    guard let above = override.min_prompt_tokens else { return nil }
                    return CloudPrice.LongPrompt(aboveInputTokens: above, input: Self.perMillion(override.prompt) ?? input,
                                                 output: Self.perMillion(override.completion) ?? output)
                }
                price = CloudPrice(input: input, output: output, longPrompts: long)
            }
            let shortName = name.map { name -> String in
                guard let colon = name.firstIndex(of: ":") else { return name }
                return name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return OpenRouterModel(id: id, name: shortName, contextLength: context_length, price: price,
                                   maxOutputTokens: top_provider?.max_completion_tokens, efforts: reasoning?.supported_efforts,
                                   structuredOutputs: supported_parameters.map { $0.contains("structured_outputs") } ?? true)
        }

        /// "0.000002" (USD per token) → 2 (USD per million), without binary rounding.
        static func perMillion(_ text: String?) -> Double? {
            guard let text, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return nil }
            return NSDecimalNumber(decimal: value * 1_000_000).doubleValue
        }
    }
}
