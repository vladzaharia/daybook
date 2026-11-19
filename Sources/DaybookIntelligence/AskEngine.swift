import DaybookCore
import DaybookKit
import Foundation

/// A loaded model that answers questions over passages (the summary model serves it: `MLXSummarizer` conforms, so
/// a question after a summary doesn't load again).
public protocol AnsweringQuestions: LoadedModel {
    func answer(_ evidence: AskEvidence, closest: [UUID], query: AskQuery?, progress: @escaping IntelligenceProgressHandler,
                sentence: @escaping @Sendable (AskSentence) -> Void) async throws -> AskReply
}

/// An answer, with how the model made it.
public struct AskReply: Sendable, Equatable {
    public var answer: AskAnswer
    /// Tokens and timings of the answering pass; nil when no model ran.
    public var statistics: GenerationStatistics?
    /// The exact model; nil when no model ran.
    public var provenance: ModelProvenance?

    public init(answer: AskAnswer, statistics: GenerationStatistics? = nil, provenance: ModelProvenance? = nil) {
        self.answer = answer; self.statistics = statistics; self.provenance = provenance
    }
}

extension LocalIntelligenceRuntime {
    /// Answers a question over `evidence` with the summary model `model` (role `.summarization`, so the model the
    /// summary step loaded serves it). One operation at a time: while another runs this throws
    /// `LocalIntelligenceError.busy` (`AskEngine` waits and retries).
    public func answer(_ evidence: AskEvidence, closest: [UUID] = [], query: AskQuery? = nil, model: ModelReference,
                       progress: @escaping IntelligenceProgressHandler = { _ in },
                       sentence: @escaping @Sendable (AskSentence) -> Void = { _ in }) async throws -> AskReply {
        try await withModel(model, role: .summarization, message: "Loading language model locally", progress: progress) { loaded, provenance in
            guard let answerer = loaded as? any AnsweringQuestions else {
                throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "answers")
            }
            try Task.checkCancellation()
            var reply = try await answerer.answer(evidence, closest: closest, query: query, progress: progress, sentence: sentence)
            reply.provenance = provenance
            return reply
        }
    }
}

/// What `AskEngine` answers with: the runtime's summary model, or a test's.
public protocol QuestionAnswering: Sendable {
    func answer(_ evidence: AskEvidence, closest: [UUID], query: AskQuery, progress: @escaping IntelligenceProgressHandler,
                sentence: @escaping @Sendable (AskSentence) -> Void) async throws -> AskReply
}

/// The installed summary model, through the runtime.
public struct RuntimeQuestionAnswerer: QuestionAnswering {
    public let runtime: LocalIntelligenceRuntime
    public let model: ModelReference

    public init(runtime: LocalIntelligenceRuntime, model: ModelReference) { self.runtime = runtime; self.model = model }

    public func answer(_ evidence: AskEvidence, closest: [UUID], query: AskQuery, progress: @escaping IntelligenceProgressHandler,
                       sentence: @escaping @Sendable (AskSentence) -> Void) async throws -> AskReply {
        try await runtime.answer(evidence, closest: closest, query: query, model: model, progress: progress, sentence: sentence)
    }
}

/// Why a question ended without an answer or a cancellation.
public enum AskError: LocalizedError, Equatable {
    /// Another job held the model for longer than the engine waits (`AskEngine.defaultWaitLimit`).
    case waitedTooLong

    public var errorDescription: String? {
        switch self {
        case .waitedTooLong: return "Another job is still using the model. Try asking again when it has finished."
        }
    }
}

/// Asking across conversations: the one object the interface calls (docs/architecture.md, "Ask across conversations").
///
///     let engine = AskEngine(runtime: runtime, model: summaryModel)
///     engine.index.update(library, personal: .init(lock))            // off the main actor, once the library has loaded
///     let task = Task { try await engine.ask("What did Sam commit to last month?", scope: scope, in: library,
///                                            personal: { await MainActor.run { AskScope.Personal(lock) } }) { progress in … } }
///     task.cancel()                                                   // Cancel, Esc, a new question, closing the page, and the lock locking
///
/// `ask` retrieves off the caller's actor, then answers on the summary model. When another job holds the runtime it
/// reports `.waiting` on every try and tries again until its turn comes, up to `waitLimit`, then throws
/// `AskError.waitedTooLong`. A cancelled question throws `CancellationError` and shows nothing it hadn't checked.
/// Nothing is written: not to a conversation, not to the library, and the question and answer aren't logged.
///
/// The Personal lock: pass `personal` to read the lock's and Focus's state now. The engine reads it again immediately
/// before the evidence goes to the model, and again before it returns; when Personal is no longer allowed it reads the
/// library again without it (an answer made from Personal passages is never returned). Sentences are reported only once
/// the answer is safe to return, so none shown came from a conversation that locked meanwhile. The caller must still
/// cancel the question and hide a page showing an answer when the lock locks: the engine can't take back what it returned.
public final class AskEngine: Sendable {
    /// How long a question waits behind a running job before it gives up.
    public static let defaultWaitLimit: Duration = .seconds(300)

    public let index: LibraryPassageIndex
    private let answerer: any QuestionAnswering
    private let budget: Int
    private let retryDelay: Duration
    private let waitLimit: Duration

    /// - Parameters:
    ///   - budget: tokens of passages the model is given (`AskRetriever.budget`).
    ///   - retryDelay: how long a question waits between tries while the runtime is busy.
    ///   - waitLimit: how long a question waits in all.
    public init(answerer: any QuestionAnswering, index: LibraryPassageIndex = LibraryPassageIndex(), budget: Int = AskRetriever.defaultBudget,
                retryDelay: Duration = .milliseconds(500), waitLimit: Duration = AskEngine.defaultWaitLimit) {
        self.answerer = answerer; self.index = index; self.budget = budget; self.retryDelay = retryDelay; self.waitLimit = waitLimit
    }

    public convenience init(runtime: LocalIntelligenceRuntime, model: ModelReference, index: LibraryPassageIndex = LibraryPassageIndex()) {
        self.init(answerer: RuntimeQuestionAnswerer(runtime: runtime, model: model), index: index)
    }

    private final class Sentences: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [AskSentence] = []
        func add(_ sentence: AskSentence) { lock.withLock { kept.append(sentence) } }
        var all: [AskSentence] { lock.withLock { kept } }
    }

    /// Answers `question` over the conversations `scope` allows.
    /// - Parameters:
    ///   - meetings: the library as it is now (what a sync or an edit changed is reindexed by content).
    ///   - vocabulary: the person's terms; people: names beyond the conversations' speakers (speaker profiles').
    ///   - personal: what the Personal lock and Focus allow now; see the type's note. Nil trusts `scope.personal`.
    ///   - progress: searching, waiting, loading, answering, and each kept sentence, in order; called from any thread.
    /// - Returns: the answer, which is `notFound` (with the closest conversations) when nothing is found, when the model
    ///   says the passages don't answer, or when no sentence's quote checks out.
    /// - Throws: `CancellationError`, `AskError.waitedTooLong`, and what the model throws.
    public func ask(_ question: String, scope: AskScope, in meetings: [Meeting], vocabulary: [GlossaryTerm] = [], people: [String] = [],
                    now: Date = Date(), calendar: Calendar = .current, personal: (@Sendable () async -> AskScope.Personal)? = nil,
                    progress: @escaping @Sendable (AskProgress) -> Void = { _ in }) async throws -> AskReply {
        progress(.searching)
        var retriever = AskRetriever(index: index)
        retriever.budget = budget
        let configured = retriever
        func retrieve(_ scope: AskScope) async throws -> AskRetrieval {
            try await detachedWork(priority: .userInitiated) {
                try configured.retrieve(question, scope: scope, in: meetings, vocabulary: vocabulary, people: people, now: now, calendar: calendar)
            }
        }
        let personalIDs = Set(meetings.filter { $0.effectivePlacement == .personal }.map(\.id))
        var scope = scope
        var retrieval = try await retrieve(scope)
        var waitStarted: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            // Immediately before the evidence goes to the model.
            if let personal {
                let current = await personal()
                if current != scope.personal { scope.personal = current; retrieval = try await retrieve(scope) }
            }
            guard let evidence = retrieval.evidence else {
                return AskReply(answer: AskAnswer(status: .notFound(.nothingFound), closest: retrieval.closest, query: retrieval.query))
            }
            let sentences = Sentences()
            do {
                let reply = try await answerer.answer(evidence, closest: retrieval.closest, query: retrieval.query, progress: { update in
                    progress(update.fraction < 1 && update.message.hasPrefix("Loading") ? .loading(update.fraction) : .answering)
                }, sentence: { sentences.add($0) })
                // And again before it is returned.
                if let personal {
                    let current = await personal()
                    if current != scope.personal {
                        scope.personal = current
                        if !current.allowsPersonal, evidence.conversations.contains(where: { personalIDs.contains($0.meetingID) }) {
                            retrieval = try await retrieve(scope)
                            continue
                        }
                    }
                }
                for sentence in sentences.all { progress(.sentence(sentence)) }
                return reply
            } catch LocalIntelligenceError.busy {
                let started = waitStarted ?? ContinuousClock.now
                waitStarted = started
                if started.duration(to: .now) >= waitLimit { throw AskError.waitedTooLong }
                progress(.waiting)
                try await Task.sleep(for: retryDelay)
            }
        }
    }
}
