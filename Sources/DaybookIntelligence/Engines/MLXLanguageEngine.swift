import DaybookCore
import DaybookKit
import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Language models on the GPU through mlx-swift-lm. Any MLX conversion whose `config.json`
/// `model_type` this mlx-swift-lm registers can run: a new family of an existing architecture is
/// only a manifest entry. Exclusive: loading it releases the speech models, and loading any other
/// model releases it, because both would not fit beside each other on smaller Macs.
///
/// Version 2 (mlx-swift-lm 3.32.3) adds Gemma 4 (`gemma4`, `gemma4_unified`) and Qwen 3.5/3.6
/// (`qwen3_5`, `qwen3_5_moe`), constrained JSON output for variants that declare
/// `structuredOutput`, and the `thinking` engine option. Version 3 serves `imageDescription` too:
/// a variant that declares the role (and `imageInput`) is loaded through MLXVLM to caption photos
/// (`MLXVisionDescriber`), from the same install that writes summaries.
public struct MLXLanguageEngine: ModelEngine {
    /// Whether this mlx-swift-lm can build a model from a `config.json`. The default asks
    /// `LLMTypeRegistry` whether it registers the architecture, then instantiates it from the
    /// configuration (arrays are lazy, so no weights are allocated).
    public typealias ArchitectureCheck = @Sendable (_ modelType: String, _ configuration: Data) async -> Bool

    let supportsArchitecture: ArchitectureCheck

    public init(supportsArchitecture: ArchitectureCheck? = nil) {
        self.supportsArchitecture = supportsArchitecture ?? { modelType, configuration in
            guard await Self.registers(modelType) else { return false }
            return (try? await LLMTypeRegistry.shared.createModel(configuration: configuration, modelType: modelType)) != nil
        }
    }

    /// Whether the pinned mlx-swift-lm's `LLMTypeRegistry` has an architecture ("gemma4", "qwen3_5").
    public static func registers(_ modelType: String) async -> Bool {
        await LLMTypeRegistry.shared.contains(modelType)
    }

    public let descriptor = ModelEngineDescriptor(
        id: .mlxLanguage, name: "MLX language models", version: 3, runtime: "mlx-swift-lm 3.32.3",
        roles: [.summarization, .imageDescription], platforms: [.macOS, .iOS], residency: .exclusive)

    /// The files the summary pipeline has always fetched for an MLX model.
    public static let include = ["*.safetensors", "*.json", "*.jinja"]

    /// `engineOptions["thinking"] == "off"`: the chat template's `enable_thinking` flag is set to false
    /// (Qwen 3.x reasons by default; Gemma 4 only when asked). Any thought block that still appears is
    /// removed from replies (`MeetingSynthesis.removingThoughts`).
    public static func chatTemplateContext(engineOptions: [String: String]) -> [String: any Sendable]? {
        switch engineOptions["thinking"]?.lowercased() {
        case "off": return ["enable_thinking": false]
        case "on": return ["enable_thinking": true]
        default: return nil
        }
    }

    public func validate(_ installation: ModelInstallation) throws {
        try require(["config.json", "tokenizer_config.json"], in: "model", of: installation)
        let files = installation.artifact("model")?.files.map(\.path) ?? []
        guard files.contains(where: { $0.hasSuffix(".safetensors") }),
              files.contains("tokenizer.json") || files.contains("tokenizer.model") else {
            throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey)
        }
    }

    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        var problems: [String] = []
        if repository.files(matching: ["*.safetensors"]).isEmpty { problems.append("It has no .safetensors weights, so it isn’t an MLX conversion.") }
        if !repository.contains("tokenizer.json") { problems.append("Its tokenizer (tokenizer.json) is missing.") }
        if !repository.contains("tokenizer_config.json") { problems.append("Its tokenizer_config.json is missing.") }
        guard repository.contains("config.json") else { throw ModelAdditionError.invalid(problems + ["Its config.json is missing."]) }
        let data = try await repository.data("config.json")
        let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let modelType = config?["model_type"] as? String else {
            throw ModelAdditionError.invalid(problems + ["Its config.json doesn’t name an architecture (model_type)."])
        }
        let describesPhotos = request.role == .imageDescription
        if describesPhotos {
            // Photos need a vision-language model: MLXVLM's architecture and an image processor.
            if !repository.contains("processor_config.json") && !repository.contains("preprocessor_config.json") {
                problems.append("It has no image processor (processor_config.json), so it can’t read photos.")
            }
            if await !VLMTypeRegistry.shared.contains(modelType) {
                problems.append("Its architecture (\(modelType)) can’t read photos in this version of Daybook.")
            }
        } else if await !supportsArchitecture(modelType, data) {
            problems.append("Its architecture (\(modelType)) doesn’t run in this version of Daybook.")
        }
        guard problems.isEmpty else { throw ModelAdditionError.invalid(problems) }
        let model = try repository.artifact("model", include: Self.include)
        let weights = model.files.filter { $0.path.hasSuffix(".safetensors") }.reduce(Int64(0)) { $0 + $1.size }
        let memory = [8, 16, 24, 32, 48, 64, 96, 128].first { Double($0) * 1e9 >= Double(weights) * 1.6 } ?? 192
        // Multimodal conversions (Gemma 4, Qwen 3.5) keep the language model's settings in text_config.
        let text = config?["text_config"] as? [String: Any]
        let context = (config?["max_position_embeddings"] as? Int) ?? (text?["max_position_embeddings"] as? Int)
        return ModelAdditionProposal(
            artifacts: [model],
            capabilities: ModelCapabilities(contextLength: context, structuredOutput: true, imageInput: describesPhotos ? true : nil),
            engineOptions: ["architecture": modelType], recommendedMemoryGB: memory)
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        if role == .imageDescription {
            // The catalog says which variants serve the role (`LocalIntelligenceRuntime.resolve`); an
            // install made before photos has the same files, so its receipt isn't consulted.
            return try await MLXVisionDescriber.load(from: installation.folder(for: "model"), engineOptions: installation.engineOptions)
        }
        Memory.cacheLimit = 256 * 1_024 * 1_024
        let started = Date()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: installation.folder(for: "model"), using: MLXLocalTokenizerLoader())
        return MLXSummarizer(container: container, structuredOutput: installation.capabilities.structuredOutput == true,
                             chatTemplateContext: Self.chatTemplateContext(engineOptions: installation.engineOptions),
                             loadSeconds: Date().timeIntervalSince(started))
    }
}

/// A loaded MLX language model.
final class MLXSummarizer: Summarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var model: MLXSynthesisModel?
    private let loadSeconds: Double

    init(container: ModelContainer, structuredOutput: Bool, chatTemplateContext: [String: any Sendable]?, loadSeconds: Double) {
        model = MLXSynthesisModel(container: container, supportsStructuredOutput: structuredOutput,
                                  chatTemplateContext: chatTemplateContext)
        self.loadSeconds = loadSeconds
    }

    func summarize(_ request: SummaryRequest, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
        guard let model = lock.withLock({ model }) else { throw LocalIntelligenceError.modelNotInstalled(request.modelID) }
        model.resetStatistics()
        var notes = try await MeetingSynthesis.generate(model: model, modelID: request.modelID, transcript: request.transcript,
                                                        notes: request.notes, template: request.template, glossary: request.glossary,
                                                        templateInstructions: request.templateInstructions,
                                                        highlightEvidence: request.highlightEvidence, photos: request.photos,
                                                        progress: progress)
        var statistics = model.statistics
        statistics.loadSeconds = loadSeconds
        notes.statistics = statistics
        return notes
    }

    /// Drops the weights, then the MLX allocator's cache, which otherwise keeps freed buffers.
    func unload() {
        lock.withLock { model = nil }
        Memory.clearCache()
    }
}

/// `SynthesisModel` over an MLX container: fresh chat sessions for free-form replies, and
/// mlx-swift-lm's XGrammar-backed guided generation for schema-constrained ones.
final class MLXSynthesisModel: SynthesisModel, @unchecked Sendable {
    let container: ModelContainer
    let supportsStructuredOutput: Bool
    /// Chat-template variables, such as `enable_thinking: false`.
    let chatTemplateContext: [String: any Sendable]?
    private let lock = NSLock()
    /// What guided generation needs from the tokenizer, built on first use (each is a full pass over
    /// the vocabulary): XGrammar's view of it, and the logit biases that close JSON near the token
    /// limit and keep whitespace runs short.
    private var grammar: Grammar?
    private var _statistics = GenerationStatistics()
    var statistics: GenerationStatistics { lock.withLock { _statistics } }
    func resetStatistics() { lock.withLock { _statistics = GenerationStatistics() } }

    init(container: ModelContainer, supportsStructuredOutput: Bool, chatTemplateContext: [String: any Sendable]?) {
        self.container = container
        self.supportsStructuredOutput = supportsStructuredOutput
        self.chatTemplateContext = chatTemplateContext
    }

    func encode(_ text: String) async -> [Int] { await container.encode(text) }
    func decode(_ tokens: [Int]) async -> String { await container.decode(tokenIds: tokens) }

    func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        let session = ChatSession(container, instructions: instructions,
                                  generateParameters: .init(maxTokens: maxTokens, temperature: 0, repetitionPenalty: 1.05,
                                                            repetitionContextSize: 64, prefill: .init(stepSize: 256)),
                                  additionalContext: chatTemplateContext)
        var response = ""
        for try await event in session.streamDetails(to: prompt) {
            try Task.checkCancellation()
            switch event {
            case .chunk(let piece): response += piece
            case .info(let info):
                lock.withLock {
                    _statistics.passes += 1
                    _statistics.promptTokens += info.promptTokenCount
                    _statistics.promptSeconds += info.promptTime
                    _statistics.generatedTokens += info.generationTokenCount
                    _statistics.generationSeconds += info.generateTime
                }
            default: break
            }
        }
        try Task.checkCancellation()
        return MeetingSynthesis.removingThoughts(response)
    }

    func respond(instructions: String, prompt: String, schema: String, maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        let context = chatTemplateContext.map(TemplateContext.init)
        return try await container.perform(values: context) { model, values in
            let tokenizer = model.tokenizer
            let grammar = try self.grammar(for: tokenizer)
            // No fast-forward: re-encoding the grammar's forced text splits it into tokens the model
            // wouldn't have chosen, and on Gemma 4 E2B that derailed it (text leaking into strings,
            // runs to the token limit). Masking alone kept its own output (docs/validation.md).
            let constraint = try GrammarConstraint(tokenizer: grammar.tokenizer, jsonSchema: schema, fastForward: false)
            let input = try await model.processor.prepare(
                input: UserInput(chat: [.system(instructions), .user(prompt)], additionalContext: values?.values))
            var output = ""
            let started = Date()
            let generated = try GuidedGenerationLoop.run(
                input: input, context: model, constraint: constraint, maxTokens: maxTokens,
                vocabSize: grammar.tokenizer.vocabSize, closingBias: grammar.closingBias,
                whitespaceBias: grammar.whitespaceBias, whitespaceTokenIDs: grammar.whitespaceTokens,
                prefill: .init(stepSize: 256)
            ) { delta in
                output += delta
                return !Task.isCancelled
            }
            try Task.checkCancellation()
            let promptTokens = input.text.tokens.size
            self.lock.withLock {
                self._statistics.passes += 1
                self._statistics.constrainedPasses += 1
                self._statistics.constrainedTokens += promptTokens + generated
                self._statistics.constrainedSeconds += Date().timeIntervalSince(started)
            }
            return output
        }
    }

    private func grammar(for tokenizer: any MLXLMCommon.Tokenizer) throws -> Grammar {
        try lock.withLock {
            if let grammar { return grammar }
            let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let whitespace = WhitespaceTokenBias.compute(tokenizer: tokenizer)
            let made = Grammar(
                tokenizer: try GrammarTokenizer(vocab: vocabulary.vocab, vocabType: vocabulary.vocabType,
                                                eosTokenId: Int32(tokenizer.eosTokenId ?? 0)),
                closingBias: ClosingTokenBias.compute(tokenizer: tokenizer, eosTokenId: tokenizer.eosTokenId),
                whitespaceBias: whitespace.bias, whitespaceTokens: whitespace.tokenIDs)
            grammar = made
            return made
        }
    }

    private struct Grammar: @unchecked Sendable {
        let tokenizer: GrammarTokenizer
        let closingBias: MLXArray
        let whitespaceBias: MLXArray
        let whitespaceTokens: Set<Int>
    }

    /// Chat-template variables carried into the container's isolation.
    private struct TemplateContext: @unchecked Sendable {
        let values: [String: any Sendable]
    }
}
