import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

#if DEBUG
/// Debug only: `Daybook --ask-eval <questions.json> --fixture <library.json> [--summary-model <key>] [--models <folder>]
/// [--split tune|held|all] [--output <run.json>]` asks Ask's evaluation questions of the synthetic evaluation library
/// (Tests/DaybookKitTests/AskEvaluation) with the installed summary model, the way the search field's question would:
/// retrieval, the answering step, the quote check. It prints each question's outcome and the counts: answered correctly,
/// wrongly, or not found, and how many sentences the quote check dropped (docs/validation.md, "Ask across conversations").
/// It downloads nothing: a model that isn't installed ends the run. The library is built in memory and never touches
/// a real library (`--fixture`, not `--library`, which opens one).
enum AskEvaluationRun {
    static func run(arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let index = arguments.firstIndex(of: "--ask-eval"), index + 1 < arguments.count, let fixture = value("--fixture") else {
            print("Usage: Daybook --ask-eval <questions.json> --fixture <library.json> [--summary-model <key>] [--models <folder>] [--split tune|held|all] [--output <run.json>]")
            return 2
        }
        let expand = { (path: String) in URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let library: AskEvaluation.Library
        do { library = try AskEvaluation.load(library: expand(fixture), questions: expand(arguments[index + 1])) }
        catch {
            print("The evaluation files couldn’t be read: \(error.localizedDescription)")
            return 1
        }
        let catalog = ModelCatalog.builtIn
        let initial = ModelRecommendations.initialSelections(catalog: catalog)
        let summaryModel = (value("--summary-model") ?? initial[.summarization]).map { catalog.model($0)?.key ?? $0 } ?? ""
        let models = value("--models").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppState.libraryURL.appendingPathComponent("Models", isDirectory: true)
        let runtime = LocalIntelligenceRuntime(modelsDirectory: models)
        await runtime.prepare()
        guard await runtime.installedModels().contains(summaryModel) else {
            print("The summary model \(summaryModel) isn’t installed in \(models.path). Nothing is downloaded: install it in Daybook first, or name another with --summary-model.")
            return 1
        }
        let split = value("--split") ?? "all"
        let questions = library.questions.filter { split == "all" || $0.split == split }
        let engine = AskEngine(runtime: runtime, model: ModelReference(summaryModel))
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        print("Model \(summaryModel); \(questions.count) questions (\(split)); load average \(String(format: "%.1f", load[0]))")
        var rows: [[String: Any]] = []
        var counts: [String: [AskEvaluation.Outcome: Int]] = [:]
        var dropped = 0
        for question in questions {
            let started = Date()
            let scope = AskEvaluation.scope(of: question, in: library, locked: question.personal)
            let outcome: AskEvaluation.Outcome
            var text = "", seconds = 0.0, droppedHere = 0, tokens = 0
            do {
                let reply = try await engine.ask(question.text, scope: scope, in: library.meetings, now: library.today, calendar: library.calendar)
                seconds = Date().timeIntervalSince(started)
                outcome = AskEvaluation.outcome(of: reply.answer, for: question)
                text = reply.answer.isNotFound ? AskWords.notFound : reply.answer.sentences.map(\.text).joined(separator: " ")
                droppedHere = reply.answer.dropped
                tokens = reply.statistics?.generatedTokens ?? 0
            } catch {
                print("\(question.id) failed: \(error.localizedDescription)")
                return 1
            }
            dropped += droppedHere
            counts[question.split, default: [:]][outcome, default: 0] += 1
            print(String(format: "%@ %@ %.1fs dropped %d: %@", question.id, outcome.rawValue, seconds, droppedHere, question.text))
            rows.append(["id": question.id, "split": question.split, "category": question.category, "question": question.text,
                         "outcome": outcome.rawValue, "answer": text, "dropped": droppedHere, "seconds": seconds, "generatedTokens": tokens])
        }
        for (name, outcomes) in counts.sorted(by: { $0.key < $1.key }) {
            let line = AskEvaluation.Outcome.allCases.map { "\($0.rawValue) \(outcomes[$0] ?? 0)" }.joined(separator: ", ")
            print("\(name): \(line)")
        }
        print("Sentences the quote check dropped: \(dropped)")
        if let output = value("--output") {
            let run: [String: Any] = ["model": summaryModel, "load": load[0], "split": split, "dropped": dropped, "questions": rows]
            do {
                try JSONSerialization.data(withJSONObject: run, options: [.prettyPrinted, .sortedKeys]).write(to: expand(output))
                print("Run written to \(output)")
            } catch {
                print("The run couldn’t be written: \(error.localizedDescription)")
                return 1
            }
        }
        return 0
    }
}
#endif
