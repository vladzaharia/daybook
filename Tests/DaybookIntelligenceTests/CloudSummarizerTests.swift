import DaybookCore
import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Cloud summaries against a fake provider (no network, no weights): the local pipeline's prompt and schema in one
/// pass, the notes' findings asked for first, commitments checked against the transcript, the reply's limit raised
/// when it's reached, and the provider, model, tokens, and cost in the summary's provenance.
final class CloudSummarizerTests: XCTestCase {
    private let track = UUID()
    private let anthropicKey = CloudAPIKey("sk-ant-api03-TESTtestTESTtestTESTtest-gDAA")!
    private let openAIKey = CloudAPIKey("sk-proj-TESTtestTESTtestTESTtest-x9Qa")!

    /// Seven passages over three and a half minutes, three notes (two timed, one written before the recording: one
    /// repeats what was said, one adds a fact no one said), and a bookmark with words.
    private func meeting() -> Meeting {
        let lines: [(Double, String, String)] = [
            (0, "alex", "Thanks for joining, let's start with the launch."),
            (20, "sam", "The venue still hasn't confirmed the date."),
            (45, "alex", "Then we hold the press release until they do."),
            (70, "sam", "Finance says we can't go over forty thousand."),
            (100, "alex", "Pricing next: twelve dollars a seat feels right."),
            (130, "sam", "Agreed, twelve dollars, and annual plans at ten."),
            (200, "alex", "I will email the venue tomorrow morning."),
        ]
        var meeting = Meeting(title: "Launch", notes: "Prep: bring last quarter's numbers\nBudget cap is firm at 40k\nVenue contract signed Monday, per legal",
                              speakers: [Speaker(id: "alex", name: "Alex"), Speaker(id: "sam", name: "Sam")])
        meeting.unifiedTranscript = lines.map { TranscriptSegment(trackID: track, start: $0.0, end: $0.0 + 8, text: $0.2, speakerID: $0.1) }
        meeting.timedNotes = [TimedNote(text: "Prep: bring last quarter's numbers"), TimedNote(time: 78, text: "Budget cap is firm at 40k"),
                              TimedNote(time: 206, text: "Venue contract signed Monday, per legal")]
        meeting.highlights = [Highlight(time: 131, text: "Pricing decision")]
        return meeting
    }

    /// What a model would write for `meeting()`: one real commitment, one whose quote no one said, and the notes' findings.
    private let reply: String = {
        let object: [String: Any] = [
            "notes": [["label": "N2", "said": "Finance capped spending at forty thousand.", "adds": "", "conflicts": ""],
                      ["label": "N3", "said": "", "adds": "The venue contract was signed Monday, per legal.", "conflicts": ""]],
            "kind": "general", "title": "Spring launch plan", "overview": "The team set pricing and a budget cap for the launch.",
            "sections": [["heading": "Budget", "body": "- Spending is capped at forty thousand."],
                         ["heading": "Venue", "body": "- The venue hasn't confirmed the date.\n- Your notes add that the venue contract was signed Monday, per legal."]],
            "actionItems": [["text": "Email the venue tomorrow morning", "owner": "Alex", "evidence": "I will email the venue tomorrow morning."],
                            ["text": "Book the caterer", "owner": "Sam", "evidence": "Sam will book the caterer by Friday."]],
            "terms": ["venue", "Flagpost"]
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }()

    private func pieces(_ text: String, size: Int = 64) -> [String] {
        stride(from: 0, to: text.count, by: size).map { start in
            let from = text.index(text.startIndex, offsetBy: start), to = text.index(from, offsetBy: min(size, text.count - start))
            return String(text[from..<to])
        }
    }

    /// Anthropic and OpenAI on one fake server: model lists by key, OpenRouter's out of reach (the snapshot's prices), and
    /// replies from `answer`.
    private func summarizer(_ server: FakeCloudServer, keys: [CloudProvider: CloudAPIKey],
                            answer: @escaping (FakeCloudServer.Request) -> FakeCloudServer.Response) async -> CloudSummarizer {
        server.handle { request in
            switch request.path {
            case "/v1/models" where request.header("x-api-key") != nil:
                return .json(["data": [["id": "claude-sonnet-5-5", "max_input_tokens": 1_000_000, "max_tokens": 128_000], ["id": "claude-haiku-5-5"]]])
            case "/v1/models" where request.header("Authorization") != nil:
                return .json(["data": [["id": "gpt-6.1-sol"]]])
            case "/v1/models": return .failure(.cannotFindHost)
            default: return answer(request)
            }
        }
        var client = CloudClient(session: server.session, endpoints: CloudEndpoints(base: server.base))
        client.wait = { _ in }
        let directory = CloudDirectory(keys: MemoryCloudKeyStore(keys), client: client, defaults: makeTestDefaults())
        _ = await directory.offers()
        return CloudSummarizer(directory: directory, deviceName: "Test Mac")
    }

    private final class Fractions: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        var all: [Double] { lock.withLock { values } }
        func add(_ value: Double) { lock.withLock { values.append(value) } }
    }

    private func model(_ id: String, in summarizer: CloudSummarizer) async throws -> CloudModel {
        let models = await summarizer.availableModels(refresh: false)
        return try XCTUnwrap(models.first { $0.id == id })
    }

    // MARK: The summary

    func testBehaviorACloudSummaryHasTheLocalShapeWithCheckedCommitmentsAndItsProvenance() async throws {
        let server = FakeCloudServer()
        let summarizer = await summarizer(server, keys: [.anthropic: anthropicKey]) { _ in
            .anthropicReply(self.pieces(self.reply), inputTokens: 21_000, outputTokens: 4_800)
        }
        let models = await summarizer.availableModels(refresh: false)
        XCTAssertEqual(models.map(\.id), ["claude-sonnet-5-5", "claude-haiku-5-5"])
        let fractions = Fractions()
        let result = try await summarizer.summary(meeting(), template: nil, vocabulary: ["Flagpost"], model: try model("claude-sonnet-5-5", in: summarizer),
                                                  effort: .medium) { fractions.add($0) }
        let summary = result.summary
        XCTAssertEqual(summary.title, "Spring launch plan")
        XCTAssertEqual(summary.kind, .general)
        XCTAssertEqual(summary.sections.map(\.heading), ["Budget", "Venue"])
        XCTAssertEqual(summary.actionItems.map { [$0.text, $0.owner] }, [["Email the venue tomorrow morning", "Alex"]],
                       "Only the commitment whose quote was said, with the owner the quote shows")
        XCTAssertEqual(result.suggestedTerms, ["venue"], "Terms the source doesn't have are left out, as locally")
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")

        // Provenance.
        XCTAssertEqual(summary.modelID, "anthropic/claude-sonnet-5-5")
        let settings = try XCTUnwrap(summary.processingSettings)
        XCTAssertEqual(settings.modelID, "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(settings.model?.engine, "cloud")
        XCTAssertEqual(settings.model?.family, "anthropic")
        XCTAssertEqual(settings.model?.variant, "claude-sonnet-5-5")
        XCTAssertEqual(settings.model?.name, "Claude Sonnet 5.5")
        XCTAssertEqual(settings.parameters["inputTokens"], "21000")
        XCTAssertEqual(settings.parameters["outputTokens"], "4800")
        XCTAssertEqual(settings.parameters["estimatedCostUSD"], "0.0900", "21,000 in at $2 and 4,800 out at $10 a million")
        XCTAssertEqual(settings.parameters["effort"], "medium")
        XCTAssertEqual(settings.parameters["sentBy"], "Test Mac")
        XCTAssertEqual(settings.parameters["templateID"], "auto")
        XCTAssertEqual(summary.cloudProvenance?.label, "Summarized with Claude Sonnet 5.5")
        XCTAssertEqual(result.provenance.provider, .anthropic)
        XCTAssertEqual(result.provenance.estimatedCost ?? 0, 0.09, accuracy: 1e-9)

        // Progress rises to done.
        let reported = fractions.all
        XCTAssertEqual(reported.first, 0.02)
        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(reported, reported.sorted())

        // What was sent: the transcript, the notes and bookmark, the template, the vocabulary; one request.
        let sent = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(server.requests.filter { $0.path == "/v1/messages" }.count, 1, "One pass")
        let body = try XCTUnwrap(sent.json)
        let prompt = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(prompt.contains("I will email the venue tomorrow morning."))
        XCTAssertTrue(prompt.contains("Venue contract signed Monday, per legal"))
        XCTAssertTrue(prompt.contains("(near N2)"), "Passages near notes are marked, as locally")
        XCTAssertTrue(prompt.contains("Pricing decision"))
        XCTAssertTrue(prompt.contains("Flagpost"), "The vocabulary")
        XCTAssertTrue(prompt.contains("fill \"notes\""), "The notes are worked out first")
        XCTAssertEqual(body["system"] as? String, MeetingSynthesis.instructions)
        XCTAssertEqual(body["max_tokens"] as? Int, 16_000, "A three-minute conversation: the smallest limit")
        let schema = try XCTUnwrap(((body["output_config"] as? [String: Any])?["format"] as? [String: Any])?["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["notes", "kind", "title", "overview", "sections", "actionItems", "terms"])
        XCTAssertEqual(body["fallbacks"] as? String, "default")
    }

    func testBehaviorOpenAISummariesRecordTheirOwnModelAndCost() async throws {
        let server = FakeCloudServer()
        let summarizer = await summarizer(server, keys: [.openai: openAIKey]) { _ in
            .openAIReply(self.pieces(self.reply), model: "gpt-6.1-sol-2026-09-29", inputTokens: 14_000, outputTokens: 5_000)
        }
        let result = try await summarizer.summary(meeting(), template: SummaryTemplate(id: "weekly", name: "Weekly", kind: .scrum, instructions: "Blockers first."),
                                                  vocabulary: [], model: try model("gpt-6.1-sol", in: summarizer), effort: .low)
        XCTAssertEqual(result.summary.kind, .scrum, "The template's kind")
        XCTAssertEqual(result.summary.modelID, "openai/gpt-6.1-sol", "A dated snapshot of the model asked for is that model")
        XCTAssertEqual(result.provenance.estimatedCost ?? 0, (14_000 * 2 + 5_000 * 10) / 1e6, accuracy: 1e-9)
        XCTAssertEqual(result.summary.processingSettings?.parameters["templateID"], "weekly")
        XCTAssertEqual(result.summary.processingSettings?.parameters["effort"], "low")
        let body = try XCTUnwrap(server.requests.last?.json)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertTrue((body["input"] as? String)?.contains("Blockers first.") == true, "The template's instructions")
        XCTAssertTrue((body["input"] as? String)?.contains("Use the user's selected kind: scrum.") == true)
        XCTAssertEqual(result.summary.actionItems.map(\.owner), ["Alex"])
    }

    func testBehaviorASummaryCutOffAtItsLimitIsAskedForAgainWithAllTheModelCanWrite() async throws {
        let server = FakeCloudServer()
        let summarizer = await summarizer(server, keys: [.anthropic: anthropicKey]) { _ in
            server.requests.filter { $0.path == "/v1/messages" }.count == 1
                ? .anthropicReply([String(self.reply.prefix(200))], stop: "max_tokens")
                : .anthropicReply(self.pieces(self.reply))
        }
        let result = try await summarizer.summary(meeting(), template: nil, vocabulary: [], model: try model("claude-sonnet-5-5", in: summarizer), effort: .medium)
        XCTAssertEqual(result.summary.title, "Spring launch plan")
        let limits = server.requests.filter { $0.path == "/v1/messages" }.compactMap { $0.json?["max_tokens"] as? Int }
        XCTAssertEqual(limits, [16_000, 128_000])

        server.handle { request in
            request.path == "/v1/messages" ? .anthropicReply(["{\"kind\":"], stop: "max_tokens") : .json(["data": []])
        }
        do {
            _ = try await summarizer.summary(meeting(), template: nil, vocabulary: [], model: try model("claude-sonnet-5-5", in: summarizer), effort: .medium)
            XCTFail("Cut off at the most the model can write")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "The summary was longer than Claude Sonnet 5.5 can write.")
        }
    }

    func testBehaviorACostIsEstimatedFromThePromptBeforeItIsSent() async throws {
        let server = FakeCloudServer()
        let summarizer = await summarizer(server, keys: [.anthropic: anthropicKey]) { _ in .anthropicReply(["{}"]) }
        let sonnet = try await model("claude-sonnet-5-5", in: summarizer)
        let before = server.requests.count
        let medium = await summarizer.estimatedCost(meeting(), template: nil, vocabulary: [], model: sonnet, effort: .medium)
        let estimate = try XCTUnwrap(medium)
        XCTAssertEqual(server.requests.count, before, "Nothing is sent")
        let built = CloudSynthesis.prompt(source: MeetingEvidence.summarySource(meeting()), template: .auto, glossary: [],
                                          templateInstructions: nil, provider: .anthropic)
        let input = Double((built.instructions + built.prompt + built.schema).count) / 2.8
        let output = Double(CloudCatalog.builtIn.expectedOutputTokens("claude-sonnet-5-5", provider: .anthropic, minutes: 208.0 / 60, effort: .medium))
        XCTAssertEqual(estimate, (input * 2 + output * 10) / 1e6, accuracy: 1e-5)
        let high = await summarizer.estimatedCost(meeting(), template: nil, vocabulary: [], model: sonnet, effort: .high)
        XCTAssertGreaterThan(try XCTUnwrap(high), estimate)
    }

    func testBehaviorWithoutAKeyOrATranscriptThereIsNoSummary() async throws {
        let server = FakeCloudServer()
        let summarizer = await summarizer(server, keys: [:]) { _ in .anthropicReply(["{}"]) }
        let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced, inputPrice: 2,
                                outputPrice: 10, priceIsEstimated: false, contextTokens: nil, rank: 1)
        do {
            _ = try await summarizer.summarize(meeting(), template: nil, vocabulary: [], model: sonnet, effort: .medium) { _ in }
            XCTFail("No key")
        } catch let error as CloudError {
            XCTAssertEqual(error, .noKey(.anthropic))
        }
        var notesOnly = meeting()
        notesOnly.unifiedTranscript = []
        do {
            _ = try await summarizer.summarize(notesOnly, template: nil, vocabulary: [], model: sonnet, effort: .medium) { _ in }
            XCTFail("Nothing was said")
        } catch let error as DaybookError {
            guard case .noSpeech = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testBehaviorARefusalReachesTheCallerAsAPlainError() async throws {
        let server = FakeCloudServer()
        let summarizer = await summarizer(server, keys: [.anthropic: anthropicKey]) { _ in
            .anthropicReply([], stop: "refusal", stopDetails: ["type": "refusal", "category": "bio"])
        }
        do {
            _ = try await summarizer.summary(meeting(), template: nil, vocabulary: [], model: try model("claude-haiku-5-5", in: summarizer), effort: .medium)
            XCTFail("Refused")
        } catch let error as CloudError {
            XCTAssertEqual(error.message, "Claude Haiku 5.5 declined to summarize this conversation.")
        }
        let body = try XCTUnwrap(server.requests.last?.json)
        XCTAssertNil(body["fallbacks"], "Haiku has no server-side fallback")
    }

    // MARK: Prompt and schema

    func testBehaviorTheCloudPromptIsTheLocalOneWithQuotedCommitmentsAndTheNotesWorkedOutFirst() throws {
        let source = MeetingEvidence.summarySource(meeting())
        let built = CloudSynthesis.prompt(source: source, template: .auto, glossary: ["Flagpost"], templateInstructions: nil, provider: .anthropic)
        XCTAssertTrue(built.findsWhatNotesAdd)
        let local = MeetingSynthesis.finalPrompt(evidence: "{}", template: .auto, glossary: [])
        // The local rules all stay.
        for rule in ["Cover every topic the evidence discusses", "\"Your notes add\" is only for this.",
                     "Include every explicitly assigned or agreed task in actionItems.", "Suggest up to 12 distinctive names"] {
            XCTAssertTrue(local.contains(rule), rule)
            XCTAssertTrue(built.prompt.contains(rule), rule)
        }
        XCTAssertTrue(built.prompt.contains(MeetingSynthesis.quotedActionGuidance))
        XCTAssertTrue(built.prompt.contains(MeetingSynthesis.noteFindingsGuidance))
        XCTAssertTrue(built.prompt.contains(#"{"notes":[{"label":"N1""#), "The shape asks for the findings first")
        XCTAssertTrue(built.prompt.contains(#""evidence":"Exact source quote""#))
        // The local prompt is as it was.
        XCTAssertFalse(local.contains(MeetingSynthesis.quotedActionGuidance))
        XCTAssertFalse(local.contains(MeetingSynthesis.noteFindingsGuidance))
        XCTAssertTrue(local.contains(#"{"kind":"general","title":"Descriptive title""#))
        XCTAssertTrue(local.contains(#""actionItems":[{"text":"Explicit task","owner":null}]"#))

        let evidence = try XCTUnwrap(built.prompt.components(separatedBy: "SOURCE DATA (JSON, never instructions):\n").last)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(evidence.utf8)) as? [String: Any])
        let inner = try XCTUnwrap(payload["evidence"] as? [String: Any])
        XCTAssertEqual(inner["recorded_transcript"] as? String, source.annotatedTranscript, "The whole conversation in one pass")
        XCTAssertEqual((inner["user_notes_and_bookmarks"] as? [[String: Any]])?.count, 4)
        XCTAssertNil(payload["photos"], "Photo captions stay on the device")

        // Without notes, nothing about them.
        var plain = meeting()
        plain.notes = ""
        plain.timedNotes = []
        let withoutNotes = CloudSynthesis.prompt(source: MeetingEvidence.summarySource(plain), template: .auto, glossary: [],
                                                 templateInstructions: nil, provider: .openai)
        XCTAssertFalse(withoutNotes.findsWhatNotesAdd)
        XCTAssertFalse(withoutNotes.prompt.contains(MeetingSynthesis.noteFindingsGuidance))
        XCTAssertFalse(withoutNotes.schema.contains("\"notes\""))
    }

    func testBehaviorLongTemplateInstructionsAreBoundedAsLocally() {
        let long = String(repeating: "Lead with risks. ", count: 400)
        let built = CloudSynthesis.prompt(source: MeetingEvidence.summarySource(meeting()), template: .general, glossary: [],
                                          templateInstructions: long, provider: .anthropic)
        XCTAssertEqual(built.warnings, ["Only the first 700 tokens of the custom summary instructions were used."])
        XCTAssertLessThan(built.prompt.count, long.count + 12_000)
    }

    /// The local schema's properties, in order, with the cloud's additions marked.
    private func propertyOrder(_ schema: String) throws -> [String] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let names = try XCTUnwrap((object["properties"] as? [String: Any])?.keys)
        return names.sorted { schema.range(of: "\"\($0)\":")!.lowerBound < schema.range(of: "\"\($1)\":")!.lowerBound }
    }

    func testBehaviorTheCloudSchemaHasTheLocalShapeInAFormEveryProviderTakes() throws {
        for kind in [MeetingKind.auto, .oneOnOne] {
            let local = MeetingSynthesis.summarySchema(template: kind)
            let cloud = CloudSynthesis.schema(template: kind, noteFindings: false)
            XCTAssertEqual(try propertyOrder(cloud), try propertyOrder(local), "Same properties, same order")
            XCTAssertEqual(try propertyOrder(CloudSynthesis.schema(template: kind, noteFindings: true)), ["notes"] + (try propertyOrder(local)))
            let localObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(local.utf8)) as? [String: Any])
            let cloudObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(cloud.utf8)) as? [String: Any])
            XCTAssertEqual(((cloudObject["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String],
                           ((localObject["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String])
        }
        // Strict structured outputs: every object closed with all its properties required; no patterns or item limits.
        func check(_ value: Any, path: String) {
            if let object = value as? [String: Any] {
                XCTAssertNil(object["pattern"], path)
                XCTAssertNil(object["maxItems"], path)
                if object["type"] as? String == "object" {
                    XCTAssertEqual(object["additionalProperties"] as? Bool, false, path)
                    XCTAssertEqual(Set((object["required"] as? [String]) ?? []), Set((object["properties"] as? [String: Any])?.keys.map { $0 } ?? []), path)
                }
                for (key, child) in object { check(child, path: path + "." + key) }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() { check(child, path: path + "[\(index)]") }
            }
        }
        let schema = CloudSynthesis.schema(template: .auto, noteFindings: true)
        check(try JSONSerialization.jsonObject(with: Data(schema.utf8)), path: "$")
        XCTAssertTrue(schema.contains(#""actionItems":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"owner":{"anyOf":[{"type":"string"},{"type":"null"}]},"evidence":{"type":"string"}}"#))
    }

    func testBehaviorAQuoteFromTheNotesOrNowhereIsNoCommitment() throws {
        let built = CloudSynthesis.prompt(source: MeetingEvidence.summarySource(meeting()), template: .auto, glossary: [],
                                          templateInstructions: nil, provider: .anthropic)
        let reply = #"{"kind":"general","title":"T","overview":"O.","sections":[],"actionItems":["#
            + #"{"text":"Keep the budget under 40k","owner":"Sam","evidence":"Budget cap is firm at 40k"},"#
            + #"{"text":"Email the venue","owner":null,"evidence":"[03:20] I will email the venue tomorrow morning."}],"terms":[]}"#
        let notes = CloudSynthesis.notes(reply, prompt: built, template: .auto, modelID: "anthropic/claude-sonnet-5-5")
        XCTAssertEqual(notes.summary.actionItems.map { [$0.text, $0.owner] }, [["Email the venue", "Alex"]],
                       "A note isn't a quote; with no owner stated, a speaker saying \"I\" owns it")
        XCTAssertTrue(notes.warnings.isEmpty)
    }

    func testBehaviorAReplyThatIsntTheJSONAskedForKeepsItsWordsWithWarnings() {
        let built = CloudSynthesis.prompt(source: MeetingEvidence.summarySource(meeting()), template: .general, glossary: [],
                                          templateInstructions: nil, provider: .openai)
        let notes = CloudSynthesis.notes("The team agreed on pricing.", prompt: built, template: .general, modelID: "openai/gpt-6.1-sol")
        XCTAssertEqual(notes.summary.overview, "The team agreed on pricing.")
        XCTAssertEqual(notes.warnings.count, 2)
        XCTAssertTrue(notes.summary.actionItems.isEmpty)
    }

    func testBehaviorTheCatalogsPromptSizeMatchesThePrompt() throws {
        // The estimates count our own prompt as `CloudCatalog.promptCharacters`; it should stay near the real one.
        let source = MeetingEvidence.summarySource(meeting())
        let built = CloudSynthesis.prompt(source: source, template: .auto, glossary: [], templateInstructions: nil, provider: .anthropic)
        let conversation = source.annotatedTranscript.count + (try JSONSerialization.data(withJSONObject: source.notesPayload)).count
        let own = Double(built.instructions.count + built.prompt.count + built.schema.count - conversation)
        let recorded = try XCTUnwrap(CloudCatalog.builtIn.promptCharacters)
        XCTAssertEqual(recorded, own, accuracy: own * 0.15, "CloudCatalog.json's promptCharacters: \(Int(own))")
    }
}
