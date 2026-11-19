#if DEBUG
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// Debug-only: the answer page with a scripted answer over the demo library, so it can be captured without a summary
/// model (docs/validation.md, "Ask across conversations: the Mac interface"):
///
///     --library-demo --ask-demo answered|partial|notfound|waiting|failed
///
/// The question is typed into the search field and asked as the person would: retrieval runs over the demo library, and a
/// scripted answerer (`AskEngine(answerer:)`) writes the answer from the passages it was given. `waiting` leaves this
/// Mac's "Roadmap review" running, so the question waits behind it; `failed` ends the answer in an error. Nothing here loads a model or reaches a network.
@MainActor
enum AskDemo {
    enum Scenario: String { case answered, partial, notfound, waiting, failed }

    static let scenario = LaunchOptions.value(after: "--ask-demo").flatMap(Scenario.init(rawValue:))

    struct Failure: Error {}

    /// Writes an answer from the passages retrieval gave it: the sentences below, each citing the passage it names.
    struct Answerer: QuestionAnswering {
        let scenario: Scenario

        func answer(_ evidence: AskEvidence, closest: [UUID], query: AskQuery, progress: @escaping IntelligenceProgressHandler,
                    sentence emit: @escaping @Sendable (AskSentence) -> Void) async throws -> AskReply {
            if scenario == .failed { throw Failure() }
            let ids = evidence.conversations.map(\.meetingID)
            if scenario == .notfound {
                return AskReply(answer: AskAnswer(status: .notFound(.modelSaidSo), closest: ids, query: query))
            }
            var sentences: [AskSentence] = []
            let wanted: [(String, String)] = [
                ("Priya took the release notes, including the Markdown export.", "Release notes are on me."),
                ("Daniel offered to review them too.", "I can review the release notes too."),
                ("The team held the 14th as the beta date, with the sync conflict fix as the gate.", "make the conflict fix the gate"),
            ]
            for (text, quote) in wanted.prefix(scenario == .partial ? 2 : 3) {
                for conversation in evidence.conversations {
                    guard let passage = conversation.passages.first(where: { $0.text.contains(quote) }) else { continue }
                    let citation = AskCitation(kind: .passage, meetingID: conversation.meetingID, conversationTitle: conversation.title,
                                               date: conversation.date, segmentID: passage.segmentID, time: passage.time,
                                               speaker: passage.speaker, text: passage.text)
                    let made = AskSentence(text: text, citations: [citation], quote: quote)
                    sentences.append(made)
                    emit(made)
                    break
                }
            }
            let provenance = ModelProvenance(family: "gemma-4", variant: "12b", revision: "demo", engine: "mlxLanguage", engineVersion: "demo",
                                             name: "Gemma 4 12B")
            return AskReply(answer: AskAnswer(status: scenario == .partial ? .partial : .answered, sentences: sentences, closest: ids,
                                              query: query), provenance: provenance)
        }
    }

    static var question: String {
        switch scenario {
        case .notfound: "Who is paying for the release party?"
        default: "Who is writing the release notes for the beta?"
        }
    }

    /// Asks the scenario's question once the demo library is in: the search field holds it, and the answer shows.
    static func apply(to state: AppState) {
        guard let scenario else { return }
        state.ask = state.makeAskController(engine: { index in
            AskEngine(answerer: Answerer(scenario: scenario), index: index)
        })
        // The demo's Mac has a job running; only the waiting scenario keeps it.
        if scenario != .waiting { state.processor.queue.runningID = nil }
        if scenario == .waiting, let id = state.meetings.first(where: { $0.title == LibraryDemo.transcribing })?.id {
            state.processor.queue.runningID = id
        }
        state.window.searchText = question
        state.window.place = .section(.all)
        state.ask.ask(question)
    }
}
#endif
