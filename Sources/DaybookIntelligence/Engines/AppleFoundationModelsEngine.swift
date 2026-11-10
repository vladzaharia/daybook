import DaybookCore
import DaybookKit
import Foundation
import Synchronization
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model through the Foundation Models framework: macOS 26 or iOS 26
/// and later, on a device with Apple Intelligence turned on. There is nothing to download, so its
/// catalog variants are `systemProvided`; whether this device has the model is decided each time
/// (`descriptor.unavailableReason`, `validate`), because Apple Intelligence can be turned on or off
/// while Daybook runs.
///
/// It serves `smallTasks` only: a title, the meeting kind, and vocabulary suggestions, generated
/// with `@Generable` from a bounded excerpt, because the model's context is 8,192 tokens on macOS 27
/// (4,096 on 26). From 26.4 the model counts the prompt's tokens itself, so the excerpt fills the
/// context; before, it's sized by an estimate. It never writes the summary itself.
public struct AppleFoundationModelsEngine: ModelEngine {
    /// Whether the system model can run here.
    public enum SystemAvailability: Equatable, Sendable {
        case available
        /// macOS 15, or iOS before 26: no Foundation Models.
        case needsNewerSystem
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        /// Apple Intelligence is on but its model is still downloading or preparing.
        case modelNotReady

        /// The availability label: a status or the fix, in a few words.
        public var reason: String? {
            switch self {
            case .available: return nil
            case .needsNewerSystem: return ModelPlatform.current == .iOS ? "Needs iOS 26 or later" : "Needs macOS 26 or later"
            case .deviceNotEligible: return ModelPlatform.current == .iOS ? "Not available on this iPhone" : "Not available on this Mac"
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence"
            case .modelNotReady: return "Apple Intelligence isn’t ready yet"
            }
        }
    }

    /// The model's raw answers to one small-tasks prompt.
    public struct Answer: Sendable, Equatable {
        public var title: String
        public var kind: String
        public var terms: [String]
        public init(title: String, kind: String, terms: [String]) { self.title = title; self.kind = kind; self.terms = terms }
    }

    /// Runs one prompt: instructions, the prompt, and whether to ask for a kind. Tests inject one;
    /// the default calls the system model with guided generation.
    public typealias Generator = @Sendable (_ instructions: String, _ prompt: String, _ asksForKind: Bool) async throws -> Answer

    /// Counts one prompt's tokens as the model reads them: the instructions, the prompt, and the answer's schema (with
    /// a kind or without). Tests inject one; the system model's counts from macOS and iOS 26.4.
    public typealias TokenCounter = @Sendable (_ instructions: String, _ prompt: String, _ asksForKind: Bool) async throws -> Int

    let availability: @Sendable () -> SystemAvailability
    let generator: Generator?
    let contextSize: @Sendable () -> Int
    let tokenCounter: TokenCounter?

    /// - Parameters:
    ///   - availability: nil reads `SystemLanguageModel.default.availability`.
    ///   - contextSize: tokens of context; nil reads the system model's.
    ///   - tokenCounter: nil counts with the system model where it can (26.4) and `generator` is the system's too;
    ///     without one, the excerpt is sized by an estimate.
    ///   - generator: nil uses the system model.
    public init(availability: (@Sendable () -> SystemAvailability)? = nil, contextSize: (@Sendable () -> Int)? = nil,
                tokenCounter: TokenCounter? = nil, generator: Generator? = nil) {
        self.availability = availability ?? Self.systemAvailability
        self.contextSize = contextSize ?? Self.systemContextSize
        self.generator = generator
        self.tokenCounter = tokenCounter ?? (generator == nil ? Self.systemTokenCounter : nil)
    }

    public var descriptor: ModelEngineDescriptor {
        ModelEngineDescriptor(id: .appleFoundationModels, name: "Apple Foundation Models", version: 1, runtime: Self.runtime,
                              roles: [.smallTasks], platforms: [.macOS, .iOS], residency: .system,
                              unavailableReason: availability().reason)
    }

    /// The system's model changes with the OS, so provenance records the OS version.
    static var runtime: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let system = ModelPlatform.current == .iOS ? "iOS" : "macOS"
        return "Foundation Models, \(system) \(version.majorVersion).\(version.minorVersion)"
    }

    /// Only system installs (no files), and only while the system model is available.
    public func validate(_ installation: ModelInstallation) throws {
        guard installation.receipt.artifacts.isEmpty else { throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey) }
        if let reason = availability().reason {
            throw LocalIntelligenceError.unavailable(model: installation.key.variantKey, reason: reason)
        }
    }

    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        throw ModelAdditionError.invalid(["Apple’s model is part of the system, so there’s nothing to add."])
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        try validate(installation)
        return AppleSmallTasksModel(generator: generator ?? Self.systemGenerator, contextSize: contextSize(), tokens: tokenCounter)
    }

    // MARK: The system model

    /// Read at most every few seconds: the interface asks for every model row it draws.
    static let systemAvailability: @Sendable () -> SystemAvailability = { availabilityCache.value(readSystemAvailability) }
    private static let availabilityCache = RecentValue<SystemAvailability>(lifetime: 5)

    private static func readSystemAvailability() -> SystemAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady): return .modelNotReady
            case .unavailable: return .deviceNotEligible
            }
        }
        #endif
        return .needsNewerSystem
    }

    static let systemContextSize: @Sendable () -> Int = {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return 4_096
    }

    static let systemGenerator: Generator = { instructions, prompt, asksForKind in
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            // Meeting notes are content transformation; the permissive guardrails avoid refusing
            // ordinary conversations, and a refusal still throws, which leaves today's behaviour.
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400)
            if asksForKind {
                let answer = try await session.respond(to: prompt, generating: LabelsWithKind.self, options: options).content
                return Answer(title: answer.title, kind: answer.kind, terms: answer.terms)
            }
            let answer = try await session.respond(to: prompt, generating: Labels.self, options: options).content
            return Answer(title: answer.title, kind: "", terms: answer.terms)
        }
        #endif
        throw LocalIntelligenceError.unavailable(model: "apple-foundation-models", reason: SystemAvailability.needsNewerSystem.reason ?? "")
    }

    /// The system model's own count (`SystemLanguageModel.tokenCount(for:)`), from macOS and iOS 26.4; nil before.
    static var systemTokenCounter: TokenCounter? {
        #if canImport(FoundationModels)
        if #available(macOS 26.4, iOS 26.4, *) {
            return { instructions, prompt, asksForKind in
                let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
                let schema = asksForKind ? LabelsWithKind.generationSchema : Labels.generationSchema
                let framing = try await model.tokenCount(for: Instructions(instructions)) + model.tokenCount(for: schema)
                return try await framing + model.tokenCount(for: prompt)
            }
        }
        #endif
        return nil
    }
}

/// A value recomputed once it's older than `lifetime` seconds.
final class RecentValue<Value: Sendable>: Sendable {
    private let lifetime: TimeInterval
    private let stored = Mutex<(value: Value, at: Date)?>(nil)

    init(lifetime: TimeInterval) { self.lifetime = lifetime }

    func value(_ compute: () -> Value) -> Value {
        let lifetime = self.lifetime
        return stored.withLock { stored in
            if let stored, Date().timeIntervalSince(stored.at) < lifetime { return stored.value }
            let value = compute()
            stored = (value, Date())
            return value
        }
    }
}

/// The loaded system model: a fresh session per request over a bounded excerpt.
final class AppleSmallTasksModel: PerformingSmallTasks, @unchecked Sendable {
    let generator: AppleFoundationModelsEngine.Generator
    /// The excerpt's share of the context, in characters, where the model can't count: what's left after the
    /// instructions, the prompt's own text, the schema, and the answer, at a conservative three characters per token.
    let characterBudget: Int
    let contextSize: Int
    /// The model's own count (26.4), which sizes the excerpt to fill the context instead.
    let tokens: AppleFoundationModelsEngine.TokenCounter?
    /// The answer's room (`maximumResponseTokens`), and a little for the session's own framing.
    static let answerTokens = 400
    static let slackTokens = 64

    init(generator: @escaping AppleFoundationModelsEngine.Generator, contextSize: Int,
         tokens: AppleFoundationModelsEngine.TokenCounter? = nil) {
        self.generator = generator
        self.contextSize = contextSize
        self.tokens = tokens
        characterBudget = max(1_000, (contextSize - 1_600) * 3)
    }

    func performSmallTasks(_ request: SmallTaskRequest, progress: @escaping IntelligenceProgressHandler) async throws -> SmallTaskResult {
        try Task.checkCancellation()
        progress(.init(0, "Reading the conversation"))
        var budget = characterBudget
        // Counted, the excerpt fills the context in one request; a count that fails leaves the estimate.
        if let tokens, let measured = try? await measuredBudget(request, tokens: tokens) { budget = measured }
        try Task.checkCancellation()
        var answer: AppleFoundationModelsEngine.Answer?
        // Token counts vary by language; on an over-long prompt, try once more with half the excerpt.
        for attempt in 0..<2 where answer == nil {
            do {
                answer = try await generator(SmallTasks.instructions, SmallTasks.prompt(request, characterBudget: budget), request.template == .auto)
            } catch is CancellationError {
                throw CancellationError()
            } catch where attempt == 0 && Self.isContextOverflow(error) {
                budget /= 2
            }
        }
        try Task.checkCancellation()
        guard let answer else { throw LocalIntelligenceError.emptyResponse }
        return SmallTasks.result(title: answer.title, kind: answer.kind, terms: answer.terms, request: request)
    }

    /// The largest excerpt, in characters, whose prompt the model counts as fitting with room for the answer: the
    /// whole conversation when it fits; else sized from what its text costs per token, and corrected once by the count
    /// of that excerpt. Nil when even an empty excerpt leaves no room, so the estimate decides.
    func measuredBudget(_ request: SmallTaskRequest, tokens: AppleFoundationModelsEngine.TokenCounter) async throws -> Int? {
        let asksForKind = request.template == .auto
        func count(_ budget: Int) async throws -> Int {
            try await tokens(SmallTasks.instructions, SmallTasks.prompt(request, characterBudget: budget), asksForKind)
        }
        let room = contextSize - Self.answerTokens - Self.slackTokens
        let characters = request.transcript.count + request.notes.count
        // Large enough that neither the transcript's share nor the notes' cuts anything.
        let whole = max(request.transcript.count * 5 / 4, request.notes.count * 5) + 1
        let all = try await count(whole)
        if all <= room { return whole }
        let framing = try await count(0)
        guard framing < room, all > framing else { return nil }
        let perToken = Double(characters) / Double(all - framing)
        let budget = Int(Double(room - framing) * perToken)
        // Whole lines and the notes' share make the first size approximate: one correction, either way.
        let first = try await count(budget)
        let corrected = Int(Double(budget) * Double(room - framing) / Double(max(1, first - framing)) * 0.98)
        if first > room { return corrected > 0 ? corrected : nil }
        if corrected > budget, try await count(corrected) <= room { return corrected }
        return budget
    }

    static func isContextOverflow(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *), let error = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = error { return true }
        #endif
        return error as? SmallTaskError == .contextTooLong
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct LabelsWithKind {
    @Guide(description: "A short, specific title of at most eight words naming the main topic")
    var title: String
    @Guide(description: "The kind of conversation", .anyOf(MeetingKind.allCases.filter { $0 != .auto }.map(\.rawValue)))
    var kind: String
    @Guide(description: "Distinctive names, acronyms, or specialist terms that appear in the excerpt", .maximumCount(12))
    var terms: [String]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable
struct Labels {
    @Guide(description: "A short, specific title of at most eight words naming the main topic")
    var title: String
    @Guide(description: "Distinctive names, acronyms, or specialist terms that appear in the excerpt", .maximumCount(12))
    var terms: [String]
}
#endif
