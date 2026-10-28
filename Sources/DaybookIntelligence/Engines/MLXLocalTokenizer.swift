import Foundation
import Hub
import MLXLMCommon
import Tokenizers

/// mlx-swift-lm 3.x takes its tokenizer through a protocol. This loads swift-transformers' tokenizer
/// (and the model's chat template) from an installed folder only: `HubApi` in offline mode reads the
/// files and never makes a request. The same mapping MLXHuggingFace's macros generate, without the
/// Hugging Face client those bring.
struct MLXLocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory, hubApi: HubApi(cache: nil, useOfflineMode: true))
        return MLXLocalTokenizer(upstream)
    }
}

/// swift-transformers' tokenizer as mlx-swift-lm's `Tokenizer`.
struct MLXLocalTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    // swift-transformers names it `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
