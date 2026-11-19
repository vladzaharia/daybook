import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation
import Observation

/// Asking across conversations, on this Mac: one question at a time, from the search field to the answer page
/// (docs/architecture.md, "Ask across conversations"; docs/interface.md, "Asking a question").
///
/// The question and its answer live here while the page is open and go when it closes: nothing is kept, written, or
/// logged. A new question cancels the one running; Cancel, Escape, clearing the field, and closing the window close the
/// page and cancel it. While a question is open it holds the processing queue (`MacProcessor.holdForAsk`): it goes
/// ahead of jobs that wait and behind the one that runs, and no job starts while it answers, so the model is never
/// asked for by two at once.
///
/// What the Personal lock hides is never shown: when it locks, or a Focus hides Personal (`personalHidden`), the index
/// drops its Personal conversations, a question that could cite one is cancelled, and an answer that cites one is
/// cleared, not dimmed.
@MainActor
@Observable
final class AskController {
    /// What the controller needs of the app, so a test can give it a library, a lock, and a queue of its own.
    struct Dependencies {
        /// The engine for the installed summary model; nil while that model isn't downloaded.
        var engine: @MainActor (LibraryPassageIndex) -> AskEngine?
        var meetings: @MainActor () -> [Meeting]
        var vocabulary: @MainActor () -> [GlossaryTerm]
        /// Names beyond the conversations' speakers: the speaker profiles'.
        var people: @MainActor () -> [String]
        /// The search field's scope and tokens, with the Personal lock and Focus as they are now, and the scope's name.
        var scope: @MainActor () -> (scope: AskScope, name: String)
        /// What the lock and a Focus allow now.
        var personal: @MainActor () -> AskScope.Personal
        /// Whether a conversation is Personal now.
        var isPersonal: @MainActor (UUID) -> Bool
        /// A job of the processing queue runs, and its conversation's title.
        var isJobRunning: @MainActor () -> Bool
        var jobName: @MainActor () -> String?
        /// Holds and releases the processing queue (`MacProcessor`); balanced for every question.
        var holdQueue: @MainActor () -> Void
        var releaseQueue: @MainActor () -> Void
        /// The name of the model that answered, for the colophon.
        var modelName: @MainActor (ModelProvenance?) -> String?
    }

    /// Where the question is.
    enum Stage: Equatable {
        case searching
        /// Waiting behind a job; its conversation's title.
        case waiting(String?)
        case loading(Double)
        case answering
        case answered
        /// The summary model isn't on this Mac.
        case needsModel
        /// It couldn't be answered (the model failed, or the wait ran out); asking again is the fix.
        case failed
        /// Personal was hidden while it was open and the answer cited, or could have cited, a Personal conversation.
        case hidden
    }

    private let dependencies: Dependencies
    let index: LibraryPassageIndex
    /// How often a question behind a job looks whether it has ended.
    var pollInterval: Duration = .milliseconds(200)

    /// The question on the page; nil when none is open.
    private(set) var question: String?
    private(set) var scope: AskScope?
    /// The scope's name, for the page's reading line: "All Conversations".
    private(set) var scopeName = ""
    private(set) var stage: Stage = .searching
    /// The checked sentences so far, in order.
    private(set) var sentences: [AskSentence] = []
    /// The finished answer, with how the model made it.
    private(set) var reply: AskReply?
    /// The page is on the detail column. A question stays open behind a conversation the person opened from it.
    private(set) var isShown = false

    private var task: Task<Void, Never>?
    private var generation = 0
    private var indexTask: Task<Void, Never>?

    init(index: LibraryPassageIndex = LibraryPassageIndex(), dependencies: Dependencies) {
        self.index = index
        self.dependencies = dependencies
    }

    /// A question is open: running, or answered.
    var isOpen: Bool { question != nil }
    /// A question is running now.
    var isRunning: Bool { task != nil }

    // MARK: Asking

    /// Asks `text` of the scope as it is now. The same question in the same scope that is already open is shown, not asked
    /// again; any other cancels the one running.
    func ask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let (scope, name) = dependencies.scope()
        if text == question, scope == self.scope, stage != .failed, stage != .hidden, stage != .needsModel { isShown = true; return }
        begin(text, scope: scope, name: name)
    }

    /// Asks the open question again, as the lock and the search field are now.
    func askAgain() {
        guard let question else { return }
        let (scope, name) = dependencies.scope()
        begin(question, scope: scope, name: name)
    }

    private func begin(_ text: String, scope: AskScope, name: String) {
        task?.cancel()
        generation += 1
        let mine = generation
        question = text; self.scope = scope; scopeName = name
        stage = .searching; sentences = []; reply = nil; isShown = true
        guard let engine = dependencies.engine(index) else {
            task = nil
            stage = .needsModel
            return
        }
        dependencies.holdQueue()
        let meetings = dependencies.meetings(), vocabulary = dependencies.vocabulary(), people = dependencies.people()
        // Only one hold lives for a question however it ends: finished, cancelled, or failed.
        task = Task { [weak self] in
            await self?.run(engine, text: text, scope: scope, meetings: meetings, vocabulary: vocabulary, people: people, generation: mine)
        }
    }

    private func run(_ engine: AskEngine, text: String, scope: AskScope, meetings: [Meeting], vocabulary: [GlossaryTerm],
                     people: [String], generation mine: Int) async {
        defer {
            dependencies.releaseQueue()
            if generation == mine { task = nil }
        }
        do {
            // Behind the job that runs: it has the model.
            if dependencies.isJobRunning() {
                setStage(.waiting(dependencies.jobName()), mine)
                while dependencies.isJobRunning() {
                    try await Task.sleep(for: pollInterval)
                }
                setStage(.searching, mine)
            }
            try Task.checkCancellation()
            let (stream, continuation) = AsyncStream.makeStream(of: AskProgress.self)
            let consumer = Task { @MainActor [weak self] in
                for await progress in stream { self?.apply(progress, mine) }
            }
            let result: AskReply
            do {
                result = try await engine.ask(text, scope: scope, in: meetings, vocabulary: vocabulary, people: people,
                                              progress: { continuation.yield($0) })
            } catch {
                continuation.finish()
                await consumer.value
                throw error
            }
            continuation.finish()
            await consumer.value
            try Task.checkCancellation()
            guard generation == mine else { return }
            reply = result
            sentences = result.answer.sentences
            stage = .answered
            // Personal went away while it was written: nothing that cites it shows.
            if dependencies.personal() != .included, citesPersonal { clear() }
        } catch is CancellationError {
            return
        } catch {
            if generation == mine { stage = .failed }
        }
    }

    private func setStage(_ next: Stage, _ mine: Int) { if generation == mine { stage = next } }

    private func apply(_ progress: AskProgress, _ mine: Int) {
        guard generation == mine, stage != .hidden else { return }
        switch progress {
        case .searching: stage = .searching
        case .waiting: stage = .waiting(dependencies.jobName())
        case .loading(let fraction): stage = .loading(fraction)
        case .answering: stage = .answering
        case .sentence(let sentence): sentences.append(sentence); stage = .answering
        }
    }

    // MARK: Closing

    /// Cancel, Escape, clearing the field, closing the window: the page goes and so does the question, running or answered.
    func close() {
        task?.cancel()
        task = nil
        generation += 1
        question = nil; scope = nil; scopeName = ""; sentences = []; reply = nil
        stage = .searching; isShown = false
    }

    /// The person opened a conversation from the page: the conversation shows, and the question stays open.
    func leavePage() { isShown = false }

    /// Shows the open question's page again (its row at the top of the search results).
    func showPage() { if isOpen { isShown = true } }

    // MARK: Personal

    /// The Personal lock locked, or a Focus hid Personal. Whatever the index held of Personal goes; a question that could
    /// cite a Personal conversation is cancelled; an answer that cites one, or lists one among the closest, is cleared.
    func personalHidden() {
        index.dropPersonal()
        // An update that was running may have read a Personal conversation again: a new one, after it, drops it.
        reindex(after: indexTask)
        guard isOpen else { return }
        if task != nil, scope?.personal == .included {
            task?.cancel()
            task = nil
            generation += 1
            clear()
        } else if citesPersonal {
            clear()
        }
    }

    /// Every conversation the answer cites or lists as closest, Personal now.
    private var citesPersonal: Bool {
        let cited = sentences.flatMap(\.citations).map(\.meetingID) + (reply?.answer.closest ?? [])
        return cited.contains(where: dependencies.isPersonal)
    }

    /// Nothing of the answer shows: the question stays, with Ask Again.
    private func clear() {
        sentences = []; reply = nil; stage = .hidden
    }

    // MARK: The index

    /// Brings the index in step with the library, off the main actor: after it loads, when a conversation changes, and
    /// when the lock unlocks. Never written to disk.
    func refreshIndex() {
        reindex(after: indexTask, debounce: true)
    }

    private func reindex(after previous: Task<Void, Never>?, debounce: Bool = false) {
        previous?.cancel()
        let meetings = dependencies.meetings(), personal = dependencies.personal()
        indexTask = Task.detached(priority: .utility) { [index] in
            await previous?.value
            if debounce {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
            index.update(meetings, personal: personal)
        }
    }

    /// The model's name for the colophon.
    var modelName: String? { dependencies.modelName(reply?.provenance) }
}
