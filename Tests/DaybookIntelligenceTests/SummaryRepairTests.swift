import DaybookCore
import Foundation
import XCTest
@testable import DaybookIntelligence

/// What the summary keeps when a smaller model's reply goes wrong: a reply stuck repeating itself is
/// stopped and cut back, a JSON reply broken off partway keeps its complete sections and commitments, and
/// a section written as a list of bullets still reads as one. The replies are the real ones from Gemma 4
/// 12B and E2B and Qwen 2.5 7B (docs/validation.md), shortened.
final class SummaryRepairTests: XCTestCase {
    /// Feeds `text` to a guard in pieces of `size` characters, as a model streams it; the characters fed
    /// before it noticed a loop, or nil.
    private func noticed(_ text: String, size: Int = 5) -> (guard: MeetingSynthesis.RepetitionGuard, fed: Int)? {
        var repetition = MeetingSynthesis.RepetitionGuard(), fed = 0
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(size)
            rest = rest.dropFirst(size)
            fed += piece.count
            if repetition.append(String(piece)) { return (repetition, fed) }
        }
        return nil
    }

    // MARK: Loops

    func testAReplyRepeatingASentenceIsStoppedAndCutBackToOneRepeat() throws {
        let start = #"{"kind":"general","title":"Spring Launch","overview":"The team met.","sections":[{"heading":"Budget and Pricing","body":"The team agreed to a budget of $40,000. \n\nNote: Your notes question if the launch date is May 12. \n\n"#
        let unit = #"Note: The group agreed on the pricing structure. \n\n"#
        let found = try XCTUnwrap(noticed(start + String(repeating: unit, count: 200)))
        XCTAssertLessThan(found.fed, start.count + unit.count * 6, "Stopped within a few repeats, not at the token limit")
        XCTAssertEqual(found.guard.loop, unit.utf8.count)
        let trimmed = found.guard.trimmed
        XCTAssertTrue(trimmed.hasPrefix(start + unit), "What came before and a whole repeat are kept")
        XCTAssertLessThanOrEqual(trimmed.count, start.count + 2 * unit.count)
    }

    func testEmptyThoughtBlocksOneAfterAnotherAreALoop() throws {
        // Gemma 4 12B, free-form, answered a part of the weekly with nothing else for 1,800 tokens.
        let found = try XCTUnwrap(noticed(String(repeating: "<|channel>thought\n<channel|>", count: 100)))
        XCTAssertEqual(MeetingSynthesis.removingThoughts(found.guard.trimmed), "")
    }

    func testOrdinarySummariesAndCommitmentsAreNotTakenForLoops() {
        let summary = #"{"kind":"general","title":"Spring Launch Planning","overview":"The team set the budget, pricing, and date.","sections":[{"heading":"Pricing","body":"The team decided:\n- Monthly: $12 per seat\n- Annual: $10 per seat\n- Free tier: Capped at three seats\n- Paid tier: Above three seats"},{"heading":"Ownership","body":"- Marcus: Campaign\n- Leo: Beta signup page\n- Priya: Launch FAQ\n- Dana: Line items"}],"actionItems":[],"terms":["Priya","Marcus","Dana","Leo"]}"#
        XCTAssertNil(noticed(summary))
        let item = { (task: String, owner: String, quote: String) in #"{"text":"\#(task)","owner":"\#(owner)","evidence":"\#(quote)"},"# }
        let actions = #"{"actions":["#
            + item("Take the local setup and the database section of the onboarding docs", "Tomas", "I'll take the local setup and the database section.")
            + item("Take the deployment and on-call section of the onboarding docs", "Aisha", "I'll take deployment and on-call.")
            + item("Take the frontend and the design system section of the onboarding docs", "Ben", "Frontend and the design system, for me.")
            + item("Take the data pipeline section of the onboarding docs", "Ravi", "And I'll do the data pipeline section.")
            + #"{"text":"Make a tracking issue","owner":"Mei","evidence":"I'll make a tracking issue."}]}"#
        XCTAssertNil(noticed(actions))
        // A separator line is short of a loop.
        XCTAssertNil(noticed("## Incident\n----------\n- Retry storm\n## Migration\n----------\n- Saturday cutover"))
    }

    // MARK: Broken-off replies

    func testALoopInTheTermsKeepsEverySectionAndTheTermsBeforeIt() throws {
        // Gemma 4 E2B's final pass on the weekly: every section, then "hit rate","read load" to the limit.
        let reply = #"{"kind":"general","title":"Weekly","overview":"Incident and migration.","sections":[{"heading":"Incident","body":"A retry storm."},{"heading":"Caching","body":"The TTL is now 90 seconds."}],"actionItems":[],"terms":["TTL","hit rate","read load","hit rate","read load","hit rate","read load","hit rate","read load","hit rate","read load""#
        var repetition = MeetingSynthesis.RepetitionGuard()
        XCTAssertTrue(repetition.append(reply))
        let salvaged = try XCTUnwrap(MeetingSynthesis.salvagedJSON(repetition.trimmed))
        let result = MeetingSynthesis.parse(salvaged, requestedTemplate: .auto, modelID: "gemma", source: "TTL hit rate read load")
        XCTAssertEqual(result.summary.sections.map(\.heading), ["Incident", "Caching"])
        XCTAssertEqual(result.suggestedTerms, ["TTL", "hit rate", "read load"])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testASummaryBrokenOffMidSectionKeepsItsCompleteSections() {
        // A free-form reply that ran into its token limit.
        let reply = #"Here are the notes: {"kind":"general","title":"Weekly","overview":"Incident and migration.","sections":[{"heading":"Incident","body":"A retry storm, \"rolled back\" at 2:50."},{"heading":"Migration","body":"Saturday at 2 a.m. [read-only]"},{"heading":"Frontend","body":"The settings page shipped to ten perc"#
        let result = MeetingSynthesis.parse(reply, requestedTemplate: .auto, modelID: "qwen", source: "")
        XCTAssertEqual(result.summary.sections.map(\.heading), ["Incident", "Migration"])
        XCTAssertEqual(result.summary.sections.first?.body, #"A retry storm, "rolled back" at 2:50."#)
        XCTAssertTrue(result.warnings.isEmpty, "Read as a summary, not as free-form notes")
    }

    func testNothingIsSalvagedWithoutACompleteElement() {
        // Gemma 4 12B's launch summary looped inside its first section: the caller runs the pass free-form.
        XCTAssertNil(MeetingSynthesis.salvagedJSON(#"{"kind":"general","title":"Launch","overview":"The team met.","sections":[{"heading":"Budget","body":"The team agreed. Note: The group agreed on the pricing structure. "#))
        XCTAssertNil(MeetingSynthesis.salvagedJSON(#"{"actions":[]}"#), "A reply that parses needs nothing")
        XCTAssertNil(MeetingSynthesis.salvagedJSON("No JSON at all."))
    }

    func testACommitmentsReplyBrokenOffKeepsItsCompleteCommitments() throws {
        // Gemma 4 E2B repeated one commitment until the limit; the loop is cut back to one.
        let item = #"{"text":"Fix the checkout test flakiness","owner":"Ben","evidence":"I'll fix that as part of the change."},"#
        let reply = #"{"actions":[{"text":"Send the backfill numbers to Tomas","owner":"Ravi","evidence":"Will do, I'll send them tonight."},"#
            + String(repeating: item, count: 30) + #"{"text":"Fix the checkout"#
        var repetition = MeetingSynthesis.RepetitionGuard()
        XCTAssertTrue(repetition.append(reply))
        let source = "[01:00] Ravi: Will do, I'll send them tonight.\n[02:00] Ben: Yes, the checkout test fails about one run in ten. I'll fix that as part of the change."
        let salvaged = try XCTUnwrap(MeetingSynthesis.salvagedJSON(repetition.trimmed))
        let actions = try XCTUnwrap(MeetingSynthesis.verifiedActions(salvaged, source: source))
        XCTAssertEqual(actions.map(\.text), ["Send the backfill numbers to Tomas", "Fix the checkout test flakiness"])
        XCTAssertEqual(actions.map(\.owner), ["Ravi", "Ben"])
        // The reply as it came, cut off at the limit, keeps the same complete commitments.
        XCTAssertEqual(MeetingSynthesis.verifiedActions(reply, source: source)?.map(\.text), ["Send the backfill numbers to Tomas", "Fix the checkout test flakiness"])
    }

    // MARK: Brief commitments

    /// Writes a summary and no commitments, recording each prompt and its limit; a word is a token.
    private final class BriefModel: SynthesisModel, @unchecked Sendable {
        let supportsStructuredOutput = true, briefCommitments: Bool, contextLength: Int?, outputTokens: Int?
        /// Extraction and compression write all they may, as the 26B came close to doing.
        var verbose = false
        private let lock = NSLock()
        private var _passes: [(prompt: String, maxTokens: Int)] = []
        var prompts: [String] { lock.withLock { _passes.map(\.prompt) } }
        var passes: [(prompt: String, maxTokens: Int)] { lock.withLock { _passes } }
        init(brief: Bool = false, context: Int? = nil, output: Int? = nil) { briefCommitments = brief; contextLength = context; outputTokens = output }
        private var vocabulary: [String] = [], index: [String: Int] = [:]
        func encode(_ text: String) async -> [Int] {
            lock.withLock {
                text.split(whereSeparator: \.isWhitespace).map { word in
                    if let found = index[String(word)] { return found }
                    vocabulary.append(String(word)); index[String(word)] = vocabulary.count - 1
                    return vocabulary.count - 1
                }
            }
        }
        func decode(_ tokens: [Int]) async -> String { lock.withLock { tokens.map { vocabulary[$0] }.joined(separator: " ") } }
        func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String { try await respond(instructions: instructions, prompt: prompt, schema: "", maxTokens: maxTokens) }
        func respond(instructions: String, prompt: String, schema: String, maxTokens: Int) async throws -> String {
            lock.withLock { _passes.append((prompt, maxTokens)) }
            if prompt.hasPrefix("Extract ALL") { return #"{"actions":[]}"# }
            if prompt.hasPrefix("Extract concise") || prompt.hasPrefix("Compress") {
                return verbose ? String(repeating: "evidence ", count: maxTokens) : "Evidence."
            }
            return #"{"kind":"general","title":"T","overview":"O.","sections":[],"actionItems":[],"terms":[]}"#
        }
    }

    /// A conversation of `count` passages of 14 words each.
    private func transcript(_ count: Int) -> String {
        (0..<count).map { String(format: "[%02d:%02d] Mei: We went over routine item number %d for the quarterly review today.", $0 / 60, $0 % 60, $0) }
            .joined(separator: "\n")
    }

    // MARK: Budgets

    func testALargeContextWindowReadsALongConversationInFewerLongerPasses() async throws {
        let long = transcript(2_200)   // About 33,000 tokens.
        let small = BriefModel(), large = BriefModel(context: 262_144)
        for model in [small, large] {
            _ = try await MeetingSynthesis.generate(model: model, modelID: "m", transcript: long, notes: "", template: .auto, glossary: [], progress: { _ in })
        }
        let parts = { (model: BriefModel) in model.passes.filter { $0.prompt.hasPrefix("Extract concise") } }
        let commitments = { (model: BriefModel) in model.passes.filter { $0.prompt.hasPrefix("Extract ALL") } }
        XCTAssertGreaterThanOrEqual(parts(small).count, 7, "Parts of 4,800 tokens")
        XCTAssertTrue(parts(small).allSatisfy { $0.maxTokens == MeetingSynthesis.extractionWords(parts: parts(small).count) * 2 })
        XCTAssertEqual(parts(large).count, 3, "Longer than the final pass's 24,000 tokens: parts of 12,000")
        XCTAssertTrue(parts(large).allSatisfy { $0.prompt.contains("Use at most 2250 words") })
        XCTAssertEqual(commitments(large).count, commitments(small).count, "Commitments in parts of 5,400 tokens either way")
        XCTAssertTrue(large.passes.allSatisfy { $0.maxTokens == 16_384 }, "Every pass may write 16,384 tokens; it stops when it's done")
        XCTAssertEqual(small.passes.last?.maxTokens, MeetingSynthesis.actionTokens)
        XCTAssertFalse(large.passes.contains { $0.prompt.hasPrefix("Compress") }, "The parts' evidence fits the final pass")
    }

    func testAMeetingTheEvidenceBudgetHoldsIsReadAsBefore() async throws {
        // The weekly's size: parts of 4,800 tokens and 900 words each, as the 26B was tuned on.
        let weekly = transcript(500)
        let small = BriefModel(), large = BriefModel(context: 262_144)
        for model in [small, large] {
            _ = try await MeetingSynthesis.generate(model: model, modelID: "m", transcript: weekly, notes: "", template: .auto, glossary: [], progress: { _ in })
        }
        let prompts = { (model: BriefModel) in model.passes.map(\.prompt) }
        XCTAssertEqual(prompts(large), prompts(small), "The same passes, only allowed to write more")
        XCTAssertTrue(prompts(large).contains { $0.contains("Use at most 900 words") })
    }

    func testCompressionShrinksTheEvidenceEvenWhenTheModelWritesAllItMay() async throws {
        let model = BriefModel()
        model.verbose = true
        _ = try await MeetingSynthesis.generate(model: model, modelID: "m", transcript: transcript(700), notes: "", template: .auto, glossary: [],
                                                progress: { _ in })
        let rounds = model.passes.filter { $0.prompt.hasPrefix("Compress") }
        XCTAssertFalse(rounds.isEmpty)
        for pass in rounds {
            let notes = try XCTUnwrap(pass.prompt.range(of: #"{"evidence_notes":""#).map { pass.prompt[$0.upperBound...] })
            let reading = notes.split(whereSeparator: \.isWhitespace).count
            XCTAssertLessThanOrEqual(pass.maxTokens, max(64, reading / 2), "At most half what it reads")
        }
        let final = try XCTUnwrap(model.passes.first { $0.prompt.hasPrefix("Write a concise summary") })
        XCTAssertLessThanOrEqual(final.prompt.components(separatedBy: "evidence ").count - 1, MeetingSynthesis.evidenceBudget)
    }

    func testAPassNeverAsksForMoreThanTheWindowHolds() async throws {
        // An 8,192-token window with a 5,000-token conversation: the final pass may write what's left.
        let model = BriefModel(context: 8_192)
        _ = try await MeetingSynthesis.generate(model: model, modelID: "m", transcript: transcript(350), notes: "", template: .auto, glossary: [], progress: { _ in })
        let final = try XCTUnwrap(model.passes.first { $0.prompt.hasPrefix("Write a concise summary") })
        let promptTokens = (MeetingSynthesis.instructions + final.prompt).split(whereSeparator: \.isWhitespace).count
        XCTAssertEqual(final.maxTokens, 8_192 - promptTokens - 1_024)
        XCTAssertLessThan(final.maxTokens, MeetingSynthesis.finalTokens)
    }

    func testBudgetsFollowTheContextWindowAndTheCatalogsLimit() {
        XCTAssertEqual(MeetingSynthesis.Budget(contextLength: nil), .standard)
        XCTAssertEqual(MeetingSynthesis.Budget(contextLength: 8_192), .standard)
        let qwen = MeetingSynthesis.Budget(contextLength: 32_768), gemma = MeetingSynthesis.Budget(contextLength: 262_144)
        XCTAssertEqual([qwen.evidence, qwen.longPart, qwen.output], [12_000, 8_000, 16_384])
        XCTAssertEqual([gemma.evidence, gemma.longPart, gemma.output], [24_000, 12_000, 16_384])
        XCTAssertEqual([gemma.part(transcript: 30_000), gemma.part(transcript: 10_000), qwen.part(transcript: 13_000)], [12_000, 4_800, 8_000])
        XCTAssertEqual(MeetingSynthesis.Budget(contextLength: 262_144, outputTokens: 8_192).output, 8_192)
        XCTAssertEqual(MeetingSynthesis.Budget(contextLength: 262_144, outputTokens: 99_999).output, 16_384)
        // Compression writes at most half what it reads, so every round shrinks the evidence.
        XCTAssertEqual(gemma.compressionTokens(words: 2_250, reading: 12_000), 6_000)
        XCTAssertEqual(gemma.compressionTokens(words: 400, reading: 3_000), 1_500)
        XCTAssertEqual(MeetingSynthesis.Budget.standard.compressionTokens(words: 600, reading: 4_800), 1_200)
        XCTAssertEqual(MeetingSynthesis.Budget.standard.compressionTokens(words: 900, reading: 1_341), 670)
        XCTAssertEqual(gemma.words(parts: 4, reading: 12_000), 2_250)
        XCTAssertEqual(gemma.words(parts: 2, reading: 4_800), 900)
        XCTAssertEqual(gemma.words(parts: 40, reading: 12_000), 400)
    }

    func testAModelMarkedBriefGetsTheShorterCommitmentsPrompt() async throws {
        let transcript = "[00:01] Mina: I'll send the agenda tomorrow."
        for brief in [false, true] {
            let model = BriefModel(brief: brief)
            _ = try await MeetingSynthesis.generate(model: model, modelID: "m", transcript: transcript, notes: "", template: .auto, glossary: [],
                                                    progress: { _ in })
            let commitments = try XCTUnwrap(model.prompts.last { $0.hasPrefix("Extract ALL") })
            XCTAssertEqual(commitments, try MeetingSynthesis.commitmentsPrompt(transcript, parts: 1, brief: brief))
        }
    }

    // MARK: Shapes

    func testNotesAndPassagesPastedWithTheirMarkersAreLeftOut() throws {
        // Gemma 4 E2B's customer interview: the notes and the passages near them, copied with their markers.
        let body = "- The export takes about twenty minutes.\n- The summary goes to a Notion page.\n\n(near N1) Exports ~20 min each, run daily\n\n(near N2) Stack: Notion + Google Sheets"
        let marked = "(near B1) Pricing objection\n[02:05] (near B1) Elena: We looked at one last year.\n[02:10] NOTE N3, written by the user (not spoken): Renewal is in March\nBOOKMARK B2, marked by the user"
        let payload: [String: Any] = ["kind": "interview", "title": "Discovery", "overview": "Elena described reporting.", "actionItems": [], "terms": [],
                                      "sections": [["heading": "Workflow", "body": body], ["heading": "Pricing", "body": "Elena found $300 a month too much (near B1)."],
                                                   ["heading": "Moments", "body": marked]]]
        let reply = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let sections = MeetingSynthesis.parse(reply, requestedTemplate: .interview, modelID: "gemma", source: "").summary.sections
        XCTAssertEqual(sections.map(\.heading), ["Workflow", "Pricing"], "A section of nothing but markers is left out")
        XCTAssertEqual(sections.map(\.body), ["- The export takes about twenty minutes.\n- The summary goes to a Notion page.",
                                              "Elena found $300 a month too much."])
        // Prose that mentions a note keeps it.
        XCTAssertEqual(MeetingSynthesis.withoutMarkers("Your notes add that the renewal is in March."), "Your notes add that the renewal is in March.")
    }

    func testSectionBulletsWrittenAsAListBecomeBullets() {
        // Qwen 2.5 7B, free-form, wrote half its sections' bodies as arrays; the whole reply used to land in
        // the overview as raw JSON.
        let reply = #"{"kind":"interview","title":"Shipment Reporting","overview":"Elena and Raj described their reporting.","sections":[{"heading":"Workflow","body":["Every morning someone exports the shipments.","- The export takes about 20 minutes.",""]},{"heading":"Next Steps","body":"Jordan will send a pilot proposal by Friday."}],"actionItems":[{"text":"Send a pilot proposal","owner":"Jordan"}],"terms":[]}"#
        let result = MeetingSynthesis.parse(reply, requestedTemplate: .auto, modelID: "qwen", source: "")
        XCTAssertEqual(result.summary.overview, "Elena and Raj described their reporting.")
        XCTAssertEqual(result.summary.sections.map(\.body), ["- Every morning someone exports the shipments.\n- The export takes about 20 minutes.",
                                                             "Jordan will send a pilot proposal by Friday."])
        XCTAssertTrue(result.warnings.isEmpty)
    }
}
