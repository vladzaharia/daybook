import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Constrained JSON output for summaries, and the free-form fallback, through a scripted model:
/// no weights are loaded.
final class StructuredOutputTests: XCTestCase {
    /// Answers each pass from a script. A schema-constrained reply is recorded as "schema", a
    /// free-form one as "free", in order.
    private final class ScriptedModel: SynthesisModel, @unchecked Sendable {
        let supportsStructuredOutput: Bool
        var structuredFails = false
        var structuredReply: (String) -> String = { _ in "{}" }
        var freeReply: (String) -> String = { _ in "{}" }
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }

        init(structured: Bool) { supportsStructuredOutput = structured }

        // One token per word is enough for chunking decisions.
        func encode(_ text: String) async -> [Int] { text.split(whereSeparator: \.isWhitespace).indices.map { $0 } }
        func decode(_ tokens: [Int]) async -> String { tokens.map { _ in "word" }.joined(separator: " ") }

        func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
            lock.withLock { _calls.append("free") }
            return freeReply(prompt)
        }

        func respond(instructions: String, prompt: String, schema: String, maxTokens: Int) async throws -> String {
            lock.withLock { _calls.append("schema") }
            struct Incomplete: Error {}
            if structuredFails { throw Incomplete() }
            return structuredReply(schema)
        }
    }

    private let transcript = "[0:01] Alex: I will send the onboarding checklist to Priya by Friday.\n[0:09] Sam: Daybook ships next week."
    private let summaryJSON = #"{"kind":"planning","title":"Checklist and launch","overview":"Alex will send the checklist. Daybook ships next week.","sections":[{"heading":"Decisions","body":"Ship next week."}],"actionItems":[{"text":"Send the checklist","owner":"Alex"}],"terms":["Daybook","Priya"]}"#
    private let actionsJSON = #"{"actions":[{"text":"Send the onboarding checklist to Priya by Friday","owner":"Alex","evidence":"Alex: I will send the onboarding checklist to Priya by Friday."}]}"#

    private func generate(_ model: ScriptedModel, template: MeetingKind = .auto) async throws -> GeneratedMeetingNotes {
        try await MeetingSynthesis.generate(model: model, modelID: "gemma-4/12b-4bit", transcript: transcript, notes: "",
                                            template: template, glossary: [], progress: { _ in })
    }

    func testTheSummarySchemaDescribesWhatParsingReads() throws {
        let schema = MeetingSynthesis.summarySchema(template: .auto)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "object")
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        XCTAssertEqual(object["required"] as? [String], ["kind", "title", "overview", "sections", "actionItems", "terms"])
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        let kind = try XCTUnwrap(properties["kind"] as? [String: Any])
        XCTAssertEqual(kind["enum"] as? [String], MeetingKind.allCases.filter { $0 != .auto }.map(\.rawValue),
                       "Automatic lets the model choose any kind but auto")
        let actions = try XCTUnwrap((properties["actionItems"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(actions["required"] as? [String], ["text", "owner"])
        let owner = try XCTUnwrap((actions["properties"] as? [String: Any])?["owner"] as? [String: Any])
        XCTAssertEqual((owner["anyOf"] as? [[String: String]])?.compactMap { $0["type"] }, ["string", "null"], "An owner may be null")
        // Properties appear in the order the prompt asks for them, which is the order they're written.
        let order = ["\"kind\"", "\"title\"", "\"overview\"", "\"sections\"", "\"actionItems\"", "\"terms\""].compactMap { schema.range(of: $0)?.lowerBound }
        XCTAssertEqual(order, order.sorted())

        let chosen = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(MeetingSynthesis.summarySchema(template: .therapy).utf8)) as? [String: Any])
        XCTAssertEqual(((chosen["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String], ["therapy"],
                       "A chosen kind is the only one allowed")
    }

    func testTheActionSchemaDescribesWhatVerificationReads() throws {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(MeetingSynthesis.actionSchema.utf8)) as? [String: Any])
        XCTAssertEqual(object["required"] as? [String], ["actions"])
        let item = try XCTUnwrap(((object["properties"] as? [String: Any])?["actions"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(item["required"] as? [String], ["text", "owner", "evidence"])
        // A reply in that shape is what verifiedActions accepts.
        XCTAssertEqual(MeetingSynthesis.verifiedActions(actionsJSON, source: transcript)?.first?.owner, "Alex")
    }

    func testAModelWithStructuredOutputIsConstrainedForTheFinalAndActionPasses() async throws {
        let model = ScriptedModel(structured: true)
        model.structuredReply = { [summaryJSON, actionsJSON] schema in schema.contains("\"actions\"") ? actionsJSON : summaryJSON }
        let notes = try await generate(model)
        XCTAssertEqual(model.calls, ["schema", "schema"], "Both passes are constrained; nothing runs free-form")
        XCTAssertEqual(notes.summary.title, "Checklist and launch")
        XCTAssertEqual(notes.summary.kind, .general, "An unknown kind still reads as general")
        XCTAssertEqual(notes.summary.actionItems.map(\.owner), ["Alex"])
        XCTAssertEqual(notes.suggestedTerms, ["Daybook", "Priya"])
        XCTAssertFalse(notes.warnings.contains { $0.contains("free-form") })
    }

    func testFailedConstrainedGenerationFallsBackToTodaysParsing() async throws {
        let model = ScriptedModel(structured: true)
        model.structuredFails = true
        model.freeReply = { [summaryJSON, actionsJSON] prompt in
            prompt.contains("Extract ALL explicit agreed tasks") ? "Here you go:\n" + actionsJSON : "```json\n" + summaryJSON + "\n```"
        }
        let notes = try await generate(model)
        XCTAssertEqual(model.calls, ["schema", "free", "schema", "free"])
        XCTAssertEqual(notes.summary.title, "Checklist and launch", "The free-form reply is parsed as before")
        XCTAssertEqual(notes.summary.actionItems.first?.text, "Send the onboarding checklist to Priya by Friday")
    }

    func testAConstrainedReplyThatIsntJSONAlsoFallsBack() async throws {
        let model = ScriptedModel(structured: true)
        model.structuredReply = { _ in "{\"kind\": \"gener" }
        model.freeReply = { [summaryJSON, actionsJSON] prompt in prompt.contains("Extract ALL explicit agreed tasks") ? actionsJSON : summaryJSON }
        let notes = try await generate(model)
        XCTAssertEqual(model.calls, ["schema", "free", "schema", "free"])
        XCTAssertEqual(notes.summary.overview, "Alex will send the checklist. Daybook ships next week.")
    }

    func testWithoutStructuredOutputOnlyFreeFormRuns() async throws {
        let model = ScriptedModel(structured: false)
        model.freeReply = { _ in "The team talked about shipping." }
        let notes = try await generate(model, template: .scrum)
        XCTAssertEqual(model.calls, ["free", "free"])
        XCTAssertEqual(notes.summary.kind, .scrum)
        XCTAssertEqual(notes.summary.overview, "The team talked about shipping.")
        XCTAssertTrue(notes.warnings.contains { $0.contains("free-form") }, "Unstructured replies are kept and flagged, as before")
    }

    func testAnOwnerSpelledAsNullIsNoOwner() {
        let reply = #"{"kind":"general","title":"T","overview":"Plans for Friday.","sections":[],"actionItems":[{"text":"Ship it","owner":"null"},{"text":"Test it","owner":" Sam "}],"terms":[]}"#
        XCTAssertEqual(MeetingSynthesis.parse(reply, requestedTemplate: .auto, modelID: "m", source: "").summary.actionItems.map(\.owner), [nil, "Sam"])
        let actions = #"{"actions":[{"text":"Ship the prototype","owner":"null","evidence":"We agreed to ship the prototype on Friday"}]}"#
        XCTAssertEqual(MeetingSynthesis.verifiedActions(actions, source: "We agreed to ship the prototype on Friday. Null results.")?.first?.owner, nil)
    }

    func testThoughtBlocksAreRemovedFromReplies() {
        XCTAssertEqual(MeetingSynthesis.removingThoughts("<|channel>thought\n<channel|>{\"a\":1}"), "{\"a\":1}")
        XCTAssertEqual(MeetingSynthesis.removingThoughts("<think>\nhmm\n</think>\n\nNotes"), "Notes")
        XCTAssertEqual(MeetingSynthesis.removingThoughts("Notes <think>cut off"), "Notes")
        XCTAssertEqual(MeetingSynthesis.removingThoughts("</think>Notes"), "Notes")
        XCTAssertEqual(MeetingSynthesis.removingThoughts("Plain notes"), "Plain notes")
    }

    func testTheThinkingOptionSetsTheChatTemplateFlag() {
        XCTAssertEqual(MLXLanguageEngine.chatTemplateContext(engineOptions: ["thinking": "off"])?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(MLXLanguageEngine.chatTemplateContext(engineOptions: ["thinking": "on"])?["enable_thinking"] as? Bool, true)
        XCTAssertNil(MLXLanguageEngine.chatTemplateContext(engineOptions: ["architecture": "qwen2"]), "Qwen 2.5 has no thinking flag")
    }

    func testEnginesRecordTheUpgradedRuntimes() {
        XCTAssertEqual(MLXLanguageEngine().descriptor.versionString, "3 (mlx-swift-lm 3.32.3)")
        XCTAssertEqual(WhisperKitEngine().descriptor.versionString, "2 (argmax-oss-swift 1.1.1)")
    }

    func testEveryBuiltInLanguageModelsArchitectureIsRegistered() async throws {
        let models = ModelCatalog.builtIn.models.filter { $0.engine == .mlxLanguage }
        XCTAssertGreaterThanOrEqual(models.count, 9)
        for model in models {
            let architecture = try XCTUnwrap(model.engineOptions["architecture"], model.key)
            let registered = await MLXLanguageEngine.registers(architecture)
            XCTAssertTrue(registered, "\(model.key): \(architecture)")
            let required = model.variant.minimumEngineVersion ?? 1
            XCTAssertLessThanOrEqual(required, MLXLanguageEngine().descriptor.version, model.key)
        }
        let unknown = await MLXLanguageEngine.registers("gemma9_unified")
        XCTAssertFalse(unknown)
    }
}
