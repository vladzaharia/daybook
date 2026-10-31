import DaybookCore
import DaybookKit
import Foundation
import MLXGuidedGeneration
import XCTest
@testable import DaybookIntelligence

/// What a long conversation's summary keeps: every part's topics, every commitment checked against
/// the words said, the owner who said "I'll", and whole sentences. A deterministic model records each
/// pass; the grammar checks use XGrammar itself, with no weights.
final class SummaryCompletenessTests: XCTestCase {
    /// One token per whitespace-separated word, decoded back to the same words; replies from a script.
    private final class WordModel: SynthesisModel, @unchecked Sendable {
        let supportsStructuredOutput: Bool
        private let lock = NSLock()
        private var vocabulary: [String] = [], index: [String: Int] = [:]
        private var _passes: [(prompt: String, maxTokens: Int, schema: String?)] = []
        var passes: [(prompt: String, maxTokens: Int, schema: String?)] { lock.withLock { _passes } }
        var reply: (String, Int) -> String = { _, _ in "{}" }

        init(structured: Bool = true) { supportsStructuredOutput = structured }

        func encode(_ text: String) async -> [Int] {
            lock.withLock {
                text.split(whereSeparator: \.isWhitespace).map { word in
                    let key = String(word)
                    if let found = index[key] { return found }
                    vocabulary.append(key); index[key] = vocabulary.count - 1
                    return vocabulary.count - 1
                }
            }
        }
        func decode(_ tokens: [Int]) async -> String { lock.withLock { tokens.map { vocabulary[$0] }.joined(separator: " ") } }
        func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
            lock.withLock { _passes.append((prompt, maxTokens, nil)) }
            return reply(prompt, maxTokens)
        }
        func respond(instructions: String, prompt: String, schema: String, maxTokens: Int) async throws -> String {
            lock.withLock { _passes.append((prompt, maxTokens, schema)) }
            return reply(prompt, maxTokens)
        }
    }

    private let track = UUID()

    /// A conversation of `count` routine passages with a few commitments among them: Ben's early on, an
    /// assignment in the middle, and Ravi's near the end.
    private func meeting(count: Int = 600) -> Meeting {
        var segments = (0..<count).map { index in
            TranscriptSegment(trackID: track, start: Double(index) * 6, end: Double(index) * 6 + 5,
                              text: "We went over routine item number \(index) for the quarterly review.", speakerID: index % 2 == 0 ? "mei" : "tomas")
        }
        segments[3] = TranscriptSegment(trackID: track, start: 18, end: 23, text: "Okay, I can look at that spinner this week.", speakerID: "ben")
        segments[count / 2] = TranscriptSegment(trackID: track, start: Double(count / 2) * 6, end: Double(count / 2) * 6 + 5,
                                                text: "Aisha, can you post the swap in the team channel?", speakerID: "mei")
        segments[count / 2 + 1] = TranscriptSegment(trackID: track, start: Double(count / 2 + 1) * 6, end: Double(count / 2 + 1) * 6 + 5,
                                                    text: "Sure, I'll post it today.", speakerID: "aisha")
        segments[count - 3] = TranscriptSegment(trackID: track, start: Double(count - 3) * 6, end: Double(count - 3) * 6 + 5,
                                                text: "Yes, I'll send the backfill numbers tonight.", speakerID: "ravi")
        var meeting = Meeting(title: "Weekly", speakers: ["mei": "Mei", "tomas": "Tomas", "ben": "Ben", "aisha": "Aisha", "ravi": "Ravi"]
            .map { Speaker(id: $0.key, name: $0.value) })
        meeting.unifiedTranscript = segments
        return meeting
    }

    private let summary = #"{"kind":"general","title":"Weekly","overview":"Routine review.","sections":[{"heading":"Review","body":"Routine items."}],"actionItems":[{"text":"Unchecked","owner":"Mei"}],"terms":[]}"#

    // MARK: Topics

    func testEveryPartOfALongConversationIsReadWithoutCuttingOneShort() async throws {
        let model = WordModel()
        let summary = self.summary
        model.reply = { prompt, maxTokens in
            if prompt.contains("Extract ALL explicit agreed tasks") { return #"{"actions":[]}"# }
            guard prompt.contains("Extract concise factual evidence") else { return summary }
            // A part with more to say than its limit: the reply runs into it, as a model's would.
            if prompt.contains("routine item number 10 for") && prompt.contains("routine item number 250 for") {
                return String(repeating: "topic ", count: maxTokens)
            }
            let first = prompt.range(of: #"routine item number (\d+) for"#, options: .regularExpression).map { String(prompt[$0]) } ?? "?"
            return "Evidence from \(first)."
        }
        _ = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: MeetingEvidence.summarySource(meeting()),
                                                template: .auto, glossary: [], progress: { _ in })
        let parts = model.passes.filter { $0.prompt.contains("Extract concise factual evidence") }
        XCTAssertGreaterThan(parts.count, 3, "The part whose reply was cut off is read again in halves")
        XCTAssertTrue(parts.allSatisfy { $0.prompt.contains("cover every topic") && $0.prompt.contains("however briefly") })
        XCTAssertTrue(parts.allSatisfy { $0.maxTokens == MeetingSynthesis.extractionWords(parts: 2) * 2 })
        // Each part starts between passages, never inside one.
        for part in parts {
            let content = try XCTUnwrap(part.prompt.range(of: #""content":""#).map { String(part.prompt[$0.upperBound...]) })
            XCTAssertTrue(content.hasPrefix("["), "A part starts at a passage's timestamp")
        }
        let final = try XCTUnwrap(model.passes.first { $0.prompt.contains("Write a concise summary") })
        XCTAssertFalse(final.prompt.contains("topic topic topic"), "The cut-off reply is replaced by its halves'")
        XCTAssertTrue(final.prompt.contains("Evidence from routine item number 0 for"))
        XCTAssertEqual(final.prompt.components(separatedBy: "Evidence from routine item number").count - 1, 3,
                       "The halves' evidence and the second part's reach the final pass")
        XCTAssertEqual(final.maxTokens, MeetingSynthesis.finalTokens)
        XCTAssertTrue(final.prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .contains("Cover every topic the evidence discusses, each in a section of its own or with closely related ones; never leave a topic out"))
    }

    func testAModelWithoutStructuredOutputStillListsActionsInTheSummary() async throws {
        let model = WordModel(structured: false)
        model.reply = { prompt, _ in prompt.contains("Extract ALL explicit agreed tasks") ? "Not JSON." : #"{"kind":"general","title":"T","overview":"O.","sections":[],"actionItems":[{"text":"Send the deck","owner":null}],"terms":[]}"# }
        let notes = try await MeetingSynthesis.generate(model: model, modelID: "qwen", source: MeetingEvidence.summarySource(meeting(count: 10)),
                                                        template: .auto, glossary: [], progress: { _ in })
        let final = try XCTUnwrap(model.passes.first { $0.prompt.contains("Write a concise summary") })
        XCTAssertTrue(final.prompt.contains("Include every explicitly assigned or agreed task in actionItems"),
                      "Free-form commitments may not parse, so the summary's own actions stay the fallback")
        XCTAssertEqual(notes.summary.actionItems.map(\.text), ["Send the deck"])
        XCTAssertTrue(notes.warnings.contains { $0.contains("could not validate") })
    }

    func testExtractionSharesTheFinalPassesEvidenceBetweenParts() {
        XCTAssertEqual(MeetingSynthesis.extractionWords(parts: 1), 900)
        XCTAssertEqual(MeetingSynthesis.extractionWords(parts: 2), 900)
        XCTAssertEqual(MeetingSynthesis.extractionWords(parts: 4), MeetingSynthesis.evidenceBudget * 55 / 100 / 4)
        XCTAssertEqual(MeetingSynthesis.extractionWords(parts: 20), 400)
    }

    // MARK: Commitments

    func testALongConversationsCommitmentsAreCheckedAgainstWhatWasSaid() async throws {
        let model = WordModel()
        let summary = self.summary
        model.reply = { prompt, _ in
            if prompt.contains("Extract concise factual evidence") { return "Routine items were reviewed; Ravi to send numbers." }
            guard prompt.contains("Extract ALL explicit agreed tasks") else { return summary }
            var actions: [String] = []
            // Quotes copied from this part of the transcript, and one paraphrase from evidence.
            if prompt.contains("I can look at that spinner") {
                actions.append(#"{"text":"Look at the spinner","owner":"Ben","evidence":"Okay, I can look at that spinner this week."}"#)
            }
            if prompt.contains("I'll post it today") {
                actions.append(#"{"text":"Post the swap in the team channel","owner":"Aisha","evidence":"Mei: Aisha, can you post the swap in the team channel? [30:06] Aisha: Sure, I'll post it today."}"#)
            }
            if prompt.contains("I'll send the backfill numbers") {
                actions.append(#"{"text":"Send the backfill numbers tonight","owner":null,"evidence":"Yes, I'll send the backfill numbers tonight."}"#)
                actions.append(#"{"text":"Send numbers","owner":"Ravi","evidence":"Ravi to send numbers"}"#)
            }
            return #"{"actions":["# + actions.joined(separator: ",") + "]}"
        }
        let notes = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: MeetingEvidence.summarySource(meeting()),
                                                        template: .auto, glossary: [], progress: { _ in })
        let checks = model.passes.filter { $0.prompt.contains("Extract ALL explicit agreed tasks") }
        XCTAssertGreaterThan(checks.count, 1, "A long transcript is checked in parts")
        XCTAssertTrue(checks.allSatisfy { $0.schema == MeetingSynthesis.actionSchema && $0.maxTokens == MeetingSynthesis.actionTokens })
        let final = try XCTUnwrap(model.passes.first { $0.prompt.contains("Write a concise summary") })
        XCTAssertEqual(final.schema, MeetingSynthesis.summarySchema(template: .auto, photoLabels: [], actions: false),
                       "The final pass leaves the actions to the commitments pass")
        XCTAssertTrue(final.prompt.contains("Leave actionItems empty") && final.prompt.contains(#""actionItems":[],"#))
        XCTAssertFalse(final.prompt.contains("Include every explicitly assigned or agreed task in actionItems"))
        XCTAssertTrue(checks.allSatisfy { $0.prompt.contains("recorded_transcript") && !$0.prompt.contains("evidence_notes") },
                      "Commitments are quoted from the words said, never from compressed evidence")
        XCTAssertTrue(checks.allSatisfy { !$0.prompt.contains("Routine items were reviewed") })
        XCTAssertEqual(notes.summary.actionItems.map(\.text), ["Look at the spinner", "Post the swap in the team channel", "Send the backfill numbers tonight"],
                       "Quotes from every part are found in the transcript; the paraphrase isn't, and the final pass's unchecked action is replaced")
        XCTAssertEqual(notes.summary.actionItems.map(\.owner), ["Ben", "Aisha", "Ravi"],
                       "An owner speaking for themselves, named in the quote, or not stated at all but saying \"I'll\"")
        XCTAssertFalse(notes.warnings.contains { $0.contains("could not validate") })
    }

    func testAPartsLastPassagesBeginTheNextSoAnAnswerKeepsItsRequest() async {
        let model = WordModel()
        let lines = (0..<20).map { "[00:\(String(format: "%02d", $0))] Mei: one two three four five six seven eight nine \($0)" }
        let parts = await MeetingSynthesis.transcriptParts(lines.joined(separator: "\n"), model: model, tokenLimit: 60)
        XCTAssertGreaterThan(parts.count, 3)
        for (earlier, later) in zip(parts, parts.dropFirst()) {
            XCTAssertEqual(Array(later.components(separatedBy: "\n").prefix(2)), Array(earlier.components(separatedBy: "\n").suffix(2)))
        }
        XCTAssertEqual(Set(parts.flatMap { $0.components(separatedBy: "\n") }), Set(lines), "Every passage, whole")
        let short = await MeetingSynthesis.transcriptParts("[00:01] Mei: Short.", model: model, tokenLimit: 60)
        XCTAssertEqual(short, ["[00:01] Mei: Short."])
        let empty = await MeetingSynthesis.transcriptParts(" \n", model: model, tokenLimit: 60)
        XCTAssertEqual(empty, [])
    }

    func testPartsComeOutEvenWithoutAScrapAtTheEnd() async {
        // Ten tokens a passage and parts of 110: filled to the limit, 55 passages left a last part of 7 (the
        // three-hour meeting's 12,000-token parts left one of 828 tokens).
        let model = WordModel()
        for count in [55, 30, 43, 71, 90] {
            let lines = (0..<count).map { String(format: "[%02d:%02d] Mei: one two three four five six seven %d", $0 / 60, $0 % 60, $0) }
            let parts = await MeetingSynthesis.transcriptParts(lines.joined(separator: "\n"), model: model, tokenLimit: 110)
            let sizes = parts.map { $0.split(whereSeparator: \.isWhitespace).count + $0.components(separatedBy: "\n").count }
            XCTAssertTrue(sizes.allSatisfy { $0 <= 110 }, "\(count): \(sizes)")
            XCTAssertGreaterThanOrEqual(Double(sizes.min() ?? 0), Double(sizes.max() ?? 0) * 0.75, "\(count): \(sizes)")
            // No more parts than full ones would take: eight new passages each after the first's ten.
            XCTAssertEqual(parts.count, 1 + (count - 10 + 7) / 8, "\(count)")
            XCTAssertEqual(Set(parts.flatMap { $0.components(separatedBy: "\n") }), Set(lines), "Every passage, whole")
        }
    }

    func testACommitmentRestatedLaterIsListedOnceInItsFirstWording() throws {
        // The three-hour meeting's recap, shortened: each person goes over what they took on, in other words.
        let transcript = """
        [00:01] Lena: I'll spend two days on a storage spike for iOS and report back next Thursday.
        [00:05] Oskar: Same for Android, two days, and I'll report back next Thursday too.
        [00:09] Lena: I'll fix the five flakiest iOS tests in the next sprint.
        [00:13] Lena: And I'll fix the five critical VoiceOver issues on iOS before the release.
        [00:17] Diego: I'll fix the content type on the CDN tomorrow morning and verify it with a fresh install.
        [00:21] Diego: I'll build the account deletion endpoint by February fourteenth.
        [00:25] Diego: I'll expose the refund status in the bookings API.
        [00:29] Diego: I'll add kill switches for checkout and search to the config service.
        [00:33] Lena: Yes, I'll remove Bugnet from the iOS app in five point seven.
        [00:37] Quinn: I'll fix the flaky iOS tests, and I'll fix the flaky Android tests.
        [00:41] Mei: Aisha, can you post the swap in the team channel?
        [00:45] Aisha: Sure, I'll post it today.
        [09:00] Nadia: Let's go around once more.
        [09:04] Lena: For me, the storage spike, and Bugnet in five point seven.
        [09:08] Diego: The CDN tomorrow morning. After that, the big three: account deletion, refund status, and the kill switches.
        [09:12] Oskar: The storage spike.
        """
        func action(_ text: String, _ owner: String, _ evidence: String) -> String { #"{"text":"\#(text)","owner":"\#(owner)","evidence":"\#(evidence)"}"# }
        // The recap's part comes first, to show the first wording wins wherever a reply lists it.
        let recap = #"{"actions":["# + [
            action("Complete the storage spike", "Lena", "For me, the storage spike"),
            action("Remove Bugnet in five point seven", "Lena", "and Bugnet in five point seven."),
            action("Fix the CDN tomorrow morning", "Diego", "The CDN tomorrow morning."),
            action("Complete account deletion, refund status, and the kill switches", "Diego", "the big three: account deletion, refund status, and the kill switches."),
            action("Complete the Android storage spike", "Oskar", "Oskar: The storage spike."),
            action("Post the on-call swap in the team channel today", "Aisha", "Sure, I'll post it today."),
        ].joined(separator: ",") + "]}"
        let first = #"{"actions":["# + [
            action("Spike storage for iOS and report back next Thursday", "Lena", "I'll spend two days on a storage spike for iOS and report back next Thursday."),
            action("Spike storage for Android and report back next Thursday", "Oskar", "Same for Android, two days, and I'll report back next Thursday too."),
            action("Fix the five flakiest iOS tests in the next sprint", "Lena", "I'll fix the five flakiest iOS tests in the next sprint."),
            action("Fix the five critical VoiceOver issues on iOS before the release", "Lena", "I'll fix the five critical VoiceOver issues on iOS before the release."),
            action("Fix the content type on the CDN tomorrow morning and verify it with a fresh install", "Diego", "I'll fix the content type on the CDN tomorrow morning"),
            action("Build the account deletion endpoint by February fourteenth", "Diego", "I'll build the account deletion endpoint by February fourteenth."),
            action("Expose the refund status in the bookings API", "Diego", "I'll expose the refund status in the bookings API."),
            action("Add kill switches for checkout and search to the config service", "Diego", "I'll add kill switches for checkout and search"),
            action("Remove Bugnet from the iOS app in 5.7", "Lena", "I'll remove Bugnet from the iOS app in five point seven."),
            action("Fix the flaky iOS tests", "Quinn", "I'll fix the flaky iOS tests"),
            action("Fix the flaky Android tests", "Quinn", "I'll fix the flaky Android tests."),
            action("Post the swap in the team channel", "Aisha", "Aisha, can you post the swap in the team channel? [00:45] Aisha: Sure, I'll post it today."),
        ].joined(separator: ",") + "]}"
        let actions = try XCTUnwrap(MeetingSynthesis.verifiedActions([recap, first], source: transcript))
        XCTAssertEqual(actions.map(\.text), [
            "Spike storage for iOS and report back next Thursday", "Spike storage for Android and report back next Thursday",
            "Fix the five flakiest iOS tests in the next sprint", "Fix the five critical VoiceOver issues on iOS before the release",
            "Fix the content type on the CDN tomorrow morning and verify it with a fresh install",
            "Build the account deletion endpoint by February fourteenth", "Expose the refund status in the bookings API",
            "Add kill switches for checkout and search to the config service", "Remove Bugnet from the iOS app in 5.7",
            "Fix the flaky iOS tests", "Fix the flaky Android tests", "Post the swap in the team channel",
        ], """
        In the order said: restatements, one summing up three, and the parts' overlap kept once in the first wording; \
        the same task for two people, two tasks that share "fix", "five", and "iOS", and two listed side by side all kept
        """)
        XCTAssertEqual(actions.map(\.owner), ["Lena", "Oskar", "Lena", "Lena", "Diego", "Diego", "Diego", "Diego", "Lena", "Quinn", "Quinn", "Aisha"])
        XCTAssertEqual(RestatedCommitments.words("Remove Bugnet in five point seven"), RestatedCommitments.words("Remove Bugnet in 5.7"))
        XCTAssertEqual(RestatedCommitments.words("Complete the stale flag list by Wednesday"), ["stale", "flag", "list"])
    }

    // MARK: Owners

    func testTheOwnerIsWhoeverTheQuoteShowsCommitting() throws {
        let transcript = """
        [00:01] Mei: Great, postmortem by Friday from Aisha.
        [00:05] Tomas: I'll write it, since most of it is the migration. Ravi, send me the numbers for the backfill.
        [00:09] Ravi: Yes, I'll send the line items today.
        [00:12] Mei: Tomas and I will write the pairing exercise.
        [00:15] Unknown speaker: I'll check the logs.
        [00:18] Ben: Can you send me the deck?
        [00:20] Ben: Tomorrow, if the review is done today.
        [00:21] Speaker 2: I can take the notes.
        [00:24] Sam: Yes, start a draft now, and send it to me two weeks before the deadline so I can give comments.
        """
        func owner(_ stated: String?, _ quote: String) throws -> String? {
            let owner = stated.map { "\"\($0)\"" } ?? "null"
            let reply = #"{"actions":[{"text":"Task","owner":"# + owner + #","evidence":""# + quote + #""}]}"#
            return try XCTUnwrap(MeetingSynthesis.verifiedActions(reply, source: transcript)?.first, quote).owner
        }
        XCTAssertEqual(try owner("Aisha", "postmortem by Friday from Aisha"), "Aisha", "Named in the quote")
        XCTAssertEqual(try owner("Ravi", "Yes, I'll send the line items today."), "Ravi", "The speaker saying \"I'll\"")
        XCTAssertEqual(try owner(nil, "Yes, I'll send the line items today."), "Ravi", "No owner stated: the speaker who said \"I'll\"")
        XCTAssertNil(try owner("Mei", "Yes, I'll send the line items today."), "Someone the quote doesn't show: no owner, never a swap")
        XCTAssertNil(try owner("Ben", "send it to me two weeks before the deadline so I can give comments."),
                     "Ben is asked, unnamed; Sam says \"I\" but isn't the one sending")
        XCTAssertNil(try owner(nil, "Ravi: Yes, I'll send the line items today. [00:12] Mei: Tomas and I"), "Two speakers say \"I\"")
        XCTAssertEqual(try owner("Ravi", "Ravi, send me the numbers for the backfill."), "Ravi", "Asked by name")
        XCTAssertNil(try owner(nil, "Ravi, send me the numbers for the backfill."), "Tomas says \"me\", but asks Ravi")
        XCTAssertEqual(try owner("Tomas and Mei", "Tomas and I will write the pairing exercise."), "Tomas and Mei",
                       "Each person named, or the speaker saying \"I\"")
        XCTAssertEqual(try owner("Tomas and Aisha", "I'll write it, since most of it is the migration."), "Tomas",
                       "Of the people stated, those the quote shows")
        XCTAssertNil(try owner("Ben", "I'll check the logs."), "No one knows who said it")
        XCTAssertNil(try owner(nil, "Can you send me the deck?"), "A request: Ben asks someone not named")
        XCTAssertNil(try owner("Mei", "Can you send me the deck?"), "Mei isn't named, and Ben asks")
        XCTAssertEqual(try owner("Ben", "Tomorrow, if the review is done today."), "Ben", "The stated owner is the speaker, naming no one else")
        XCTAssertNil(try owner("Tomas", "Ravi, send me the numbers for the backfill."), "Tomas speaks, but the task is Ravi's")
        XCTAssertEqual(try owner(nil, "Speaker 2: I can take the notes."), "Speaker 2", "A placeholder name follows the speaker when renamed")
        XCTAssertNil(try owner("Mei", "Great, postmortem by Friday from Aisha. [00:05] Tomas: I'll write it"),
                     "Two people speak in the quote, and Mei isn't named")
        // A quote in a curly apostrophe still matches the transcript's straight one.
        XCTAssertEqual(try owner(nil, "Yes, I\u{2019}ll send the line items today."), "Ravi")
        XCTAssertNil(MeetingSynthesis.verifiedActions(#"{"actions":[{"text":"Task","owner":"Ravi","evidence":"Ravi will send the line items"}]}"#,
                                                      source: transcript)?.first, "A paraphrase isn't a quote")
    }

    // MARK: Whole sentences

    /// The grammar the final pass is constrained to, over a vocabulary of single characters plus the two
    /// pieces a model writes around a quotation.
    private let vocabulary = (32...126).map { String(UnicodeScalar(UInt8($0))) } + [" \"", "\\\"", "</s>"]

    private func constraint(_ schema: String) throws -> GrammarConstraint {
        let tokenizer = try GrammarTokenizer(vocab: vocabulary, vocabType: .raw, eosTokenId: Int32(vocabulary.count - 1))
        return try GrammarConstraint(tokenizer: tokenizer, jsonSchema: schema)
    }

    private func write(_ text: String, to constraint: GrammarConstraint) throws {
        for character in text { _ = try constraint.commitToken(Int32(try XCTUnwrap(vocabulary.firstIndex(of: String(character))))) }
    }

    private func allows(_ piece: String, _ constraint: GrammarConstraint) throws -> Bool {
        let mask = try constraint.computeMask().mask, token = try XCTUnwrap(vocabulary.firstIndex(of: piece))
        return (UInt32(bitPattern: mask[token / 32]) >> UInt32(token % 32)) & 1 == 1
    }

    func testAQuotationMarkCantEndASectionMidSentence() throws {
        let opening = #"{"kind":"general","title":"Incident review","overview":"An outage on Tuesday.","sections":[{"heading":"Incident","body":"The root cause was a"#
        // Before: any string, and a quotation mark after "was a" ended the section there.
        let plain = try constraint(MeetingSynthesis.summarySchema(template: .auto).replacingOccurrences(of: MeetingSynthesis.prose, with: #"{"type":"string"}"#))
        try write(opening, to: plain)
        XCTAssertTrue(try allows(" \"", plain))

        let schema = MeetingSynthesis.summarySchema(template: .auto)
        let grammar = try constraint(schema)
        try write(opening, to: grammar)
        XCTAssertFalse(try allows(" \"", grammar), "A quotation opening after a space can't end the string")
        try write(" ", to: grammar)
        XCTAssertFalse(try allows("\"", grammar), "Nor can one after a space written on its own")
        XCTAssertTrue(try allows("\\\"", grammar), "The escaped quotation mark is left")
        try write(#"\"retry storm\"."#, to: grammar)
        XCTAssertTrue(try allows("\"", grammar), "A sentence that's finished can end the string")
        try write(#""}],"actionItems":[{"text":"Write the postmortem","owner":null}],"terms":[]}"#, to: grammar)
        XCTAssertTrue(try grammar.computeMask().isTerminated || allows("</s>", grammar), "The whole reply is accepted")

        // Text that ends with a closing quotation mark or a bracket still ends the string.
        for (value, accepted) in [(#"It was a \"retry storm\""#, true), ("Rollout (50%)", true), ("Ends with a ", false), ("Ends with a\\n", false), ("", false)] {
            XCTAssertEqual(value.range(of: "^" + MeetingSynthesis.prosePattern + "$", options: .regularExpression) != nil, accepted, value)
        }
        XCTAssertTrue(MeetingSynthesis.actionSchema.contains(MeetingSynthesis.prose), "Action text is prose too")

        // Left to the commitments pass, the final pass's actions can only be empty.
        let withoutActions = try constraint(MeetingSynthesis.summarySchema(template: .auto, photoLabels: [], actions: false))
        try write(#"{"kind":"general","title":"Incident review","overview":"An outage.","sections":[],"actionItems":["#, to: withoutActions)
        XCTAssertFalse(try allows("{", withoutActions))
        XCTAssertTrue(try allows("]", withoutActions))
    }

    func testASectionBrokenOffAndWrittenAgainIsKeptOnceWhole() async throws {
        let model = WordModel()
        model.reply = { prompt, _ in
            if prompt.contains("Extract ALL explicit agreed tasks") { return #"{"actions":[]}"# }
            // What a cut string looked like: the section stops, then is written again in full.
            return #"{"kind":"general","title":"Incident review","overview":"An outage.","sections":["#
                + #"{"heading":"API Incident Review","body":"The API failed for 42 minutes. The root cause was a "},"#
                + #"{"heading":"API Incident Review","body":"The API failed for 42 minutes. The root cause was a retry change that caused a \"retry storm\"."},"#
                + #"{"heading":"Migration","body":"Cutover moved to Saturday."}],"actionItems":[],"terms":[]}"#
        }
        let source = MeetingEvidence.summarySource(meeting(count: 10))
        let notes = try await MeetingSynthesis.generate(model: model, modelID: "gemma", source: source, template: .auto, glossary: [], progress: { _ in })
        XCTAssertEqual(notes.summary.sections.map(\.heading), ["API Incident Review", "Migration"])
        XCTAssertTrue(notes.summary.sections[0].body.hasSuffix(#"caused a "retry storm"."#))
        XCTAssertTrue(notes.summary.sections.allSatisfy { !($0.body.last?.isWhitespace ?? true) })
    }
}
