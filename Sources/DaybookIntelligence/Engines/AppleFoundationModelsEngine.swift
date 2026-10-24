import DaybookCore
import DaybookKit
import Foundation
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
/// (4,096 on 26). It never writes the summary itself.
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

    let availability: @Sendable () -> SystemAvailability
    let generator: Generator?
    let contextSize: @Sendable () -> Int

    /// - Parameters:
    ///   - availability: nil reads `SystemLanguageModel.default.availability`.
    ///   - contextSize: tokens of context; nil reads the system model's.
    ///   - generator: nil uses the system model.
    public init(availability: (@Sendable () -> SystemAvailability)? = nil, contextSize: (@Sendable () -> Int)? = nil,
                generator: Generator? = nil) {
        self.availability = availability ?? Self.systemAvailability
        self.contextSize = contextSize ?? Self.systemContextSize
        self.generator = generator
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
        return AppleSmallTasksModel(generator: generator ?? Self.systemGenerator, contextSize: contextSize())
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
}

/// A value recomputed once it's older than `lifetime` seconds.
final class RecentValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let lifetime: TimeInterval
    private var stored: (value: Value, at: Date)?

    init(lifetime: TimeInterval) { self.lifetime = lifetime }

    func value(_ compute: () -> Value) -> Value {
        lock.withLock {
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
    /// The excerpt's share of the context, in characters: what's left after the instructions, the
    /// prompt's own text, the schema, and the answer, at a conservative three characters per token.
    let characterBudget: Int

    init(generator: @escaping AppleFoundationModelsEngine.Generator, contextSize: Int) {
        self.generator = generator
        characterBudget = max(1_000, (contextSize - 1_600) * 3)
    }

    func performSmallTasks(_ request: SmallTaskRequest, progress: @escaping IntelligenceProgressHandler) async throws -> SmallTaskResult {
        try Task.checkCancellation()
        progress(.init(0, "Reading the conversation"))
        var budget = characterBudget
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
