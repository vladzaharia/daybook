import Foundation
@testable import DaybookIntelligence

/// A `SynthesisModel` that answers from a script and records what it was asked, so a flow that talks to the summary
/// model runs without weights. A schema-constrained reply is recorded as "schema", a free-form one as "free".
final class ScriptedSynthesisModel: SynthesisModel, @unchecked Sendable {
    let supportsStructuredOutput: Bool
    var contextLength: Int?
    var structuredFails = false
    var reply: @Sendable (String) throws -> String
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _prompts: [String] = []
    private var _schemas: [String] = []

    var calls: [String] { lock.withLock { _calls } }
    var prompts: [String] { lock.withLock { _prompts } }
    var schemas: [String] { lock.withLock { _schemas } }

    init(structured: Bool = true, contextLength: Int? = nil, reply: @escaping @Sendable (String) throws -> String) {
        supportsStructuredOutput = structured; self.contextLength = contextLength; self.reply = reply
    }

    // One token per word is enough for window decisions.
    func encode(_ text: String) async -> [Int] { text.split(whereSeparator: \.isWhitespace).indices.map { $0 } }
    func decode(_ tokens: [Int]) async -> String { tokens.map { _ in "word" }.joined(separator: " ") }

    func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { _calls.append("free"); _prompts.append(prompt) }
        return try reply(prompt)
    }

    func respond(instructions: String, prompt: String, schema: String, maxTokens: Int) async throws -> String {
        lock.withLock { _calls.append("schema"); _prompts.append(prompt); _schemas.append(schema) }
        struct Incomplete: Error {}
        if structuredFails { throw Incomplete() }
        return try reply(prompt)
    }
}
