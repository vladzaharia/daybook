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

/// Asking across conversations: the one object the interface calls (docs/architecture.md, "Ask across conversations").
///
///     let engine = AskEngine(runtime: runtime, model: summaryModel)
///     engine.index.update(library, personal: .init(lock))            // off the main actor, once the library has loaded
///     let task = Task { try await engine.ask("What did Sam commit to last month?", scope: scope, in: library) { progress in … } }
///     task.cancel()                                                   // Cancel, Esc, a new question, closing the page
///
/// `ask` retrieves off the caller's actor, then answers on the summary model. When another job holds the runtime it
/// reports `.waiting` once and tries again until its turn comes. Each checked sentence is reported as it is kept, then
/// the answer returns; a cancelled question throws `CancellationError` and shows nothing it hadn't checked.
/// Nothing is written: not to a conversation, not to the library, and the question and answer aren't logged.
public final class AskEngine: Sendable {
    public let index: LibraryPassageIndex
    private let answerer: any QuestionAnswering
    private let budget: Int
    private let retryDelay: Duration

    /// - Parameters:
    ///   - budget: tokens of passages the model is given (`AskRetriever.budget`).
    ///   - retryDelay: how long a question waits between tries while the runtime is busy.
    public init(answerer: any QuestionAnswering, index: LibraryPassageIndex = LibraryPassageIndex(), budget: Int = AskRetriever.defaultBudget,
                retryDelay: Duration = .milliseconds(500)) {
        self.answerer = answerer; self.index = index; self.budget = budget; self.retryDelay = retryDelay
    }

    public convenience init(runtime: LocalIntelligenceRuntime, model: ModelReference, index: LibraryPassageIndex = LibraryPassageIndex()) {
        self.init(answerer: RuntimeQuestionAnswerer(runtime: runtime, model: model), index: index)
    }

    /// Answers `question` over the conversations `scope` allows.
    /// - Parameters:
    ///   - meetings: the library as it is now (what a sync or an edit changed is reindexed by content).
    ///   - vocabulary: the person's terms; people: names beyond the conversations' speakers (speaker profiles').
    ///   - progress: searching, waiting, loading, answering, and each kept sentence, in order; called from any thread.
    /// - Returns: the answer, which is `notFound` (with the closest conversations) when nothing is found, when the model
    ///   says the passages don't answer, or when no sentence's quote checks out.
    public func ask(_ question: String, scope: AskScope, in meetings: [Meeting], vocabulary: [GlossaryTerm] = [], people: [String] = [],
                    now: Date = Date(), calendar: Calendar = .current,
                    progress: @escaping @Sendable (AskProgress) -> Void = { _ in }) async throws -> AskReply {
        progress(.searching)
        var retriever = AskRetriever(index: index)
        retriever.budget = budget
        let retriever2 = retriever
        let retrieval = try await detachedWork(priority: .userInitiated) {
            try retriever2.retrieve(question, scope: scope, in: meetings, vocabulary: vocabulary, people: people, now: now, calendar: calendar)
        }
        guard let evidence = retrieval.evidence else {
            return AskReply(answer: AskAnswer(status: .notFound(.nothingFound), closest: retrieval.closest, query: retrieval.query))
        }
        var waiting = false
        while true {
            try Task.checkCancellation()
            do {
                return try await answerer.answer(evidence, closest: retrieval.closest, query: retrieval.query, progress: { update in
                    progress(update.fraction < 1 && update.message.hasPrefix("Loading") ? .loading(update.fraction) : .answering)
                }, sentence: { progress(.sentence($0)) })
            } catch LocalIntelligenceError.busy {
                if !waiting { waiting = true; progress(.waiting) }
                try await Task.sleep(for: retryDelay)
            }
        }
    }
}
