import DaybookCore
import DaybookKit
import Foundation

extension MeetingSynthesis {
    /// The cloud summary's action items carry the quote that shows each one, so they get the commitments pass's
    /// check against the transcript in the same reply (`CloudSynthesis.notes`).
    static let quotedActionGuidance = """
    Give each action item "evidence": an exact short quote from the recorded transcript that shows the commitment, the person
    saying they will do it or agreeing to it. Copy it word for word, without its timestamp, the speaker's name, or added words;
    the user's notes are never a quote. List each commitment once, as a task that reads on its own, never "it" or "that", and
    leave out anything later dropped or put on hold.
    """

    /// What each note adds, worked out before the summary is written. Told only to compare each note with the
    /// conversation while writing, Claude Sonnet 5.5 and Haiku 5.5 folded what only a note said into the summary
    /// as if it had been said (3 of 6 notes handled right on a three-hour meeting; docs/validation.md, 2026-10-31).
    static let noteFindingsGuidance = """
    Before the summary, fill "notes" with one entry for each NOTE (N1, N2, …), in order: "said", what the conversation says about
    the note's subject, in one short sentence ("" when it doesn't mention it); "adds", what the note says that no speaker said, in
    any words ("" when the conversation says it, however differently); "conflicts", where the note disagrees with what was said
    ("" when it doesn't). Then write the summary from those findings. Every fact in a note's "adds" goes in the section it relates
    to as the user's, in a sentence that starts "Your notes add" ("Your notes add that the quote is only valid until Jan 31."):
    written any other way, a fact only a note gives reads as something said in the conversation. A note whose "adds" is empty is
    written from the conversation without mentioning the note, and a conflict is mentioned as one.
    """

    static let noteFindingsShape = #""notes":[{"label":"N1","said":"What the conversation says about it","adds":"","conflicts":""}],"#
}

/// A cloud model's summary of one conversation (docs/cloud.md, "The summary"): the local pipeline's final prompt and
/// schema in one pass over the whole conversation (every catalog model's window holds a day of talk), with the
/// commitments that pass lists checked against the transcript as the commitments pass's are, and each note's
/// findings asked for before the summary. Photo captions stay on the device, so photos are placed by time afterwards.
public enum CloudSynthesis {
    /// The custom instructions' share of the prompt, as the local pipeline bounds them (700 tokens).
    static let templateTokens = 700

    public struct Prompt: Equatable, Sendable {
        public var instructions: String
        public var prompt: String
        public var schema: String
        /// The recorded transcript, for checking quotes.
        public var transcript: String
        /// The notes' text, for checking suggested terms.
        public var noteText: String
        public var warnings: [String]
        /// Whether the reply works out what each note adds.
        public var findsWhatNotesAdd: Bool
    }

    /// The request for `source`, with the template's kind and instructions and the vocabulary.
    public static func prompt(source: SummarySource, template: MeetingKind, glossary: [String], templateInstructions: String?,
                              provider: CloudProvider, catalog: CloudCatalog = .builtIn) -> Prompt {
        var warnings: [String] = []
        var custom = templateInstructions ?? ""
        let limit = Int(Double(templateTokens) * catalog.provider(provider).charactersPerToken)
        if custom.count > limit {
            custom = String(custom.prefix(limit))
            warnings.append("Only the first 700 tokens of the custom summary instructions were used.")
        }
        let structured = source.isStructured
        var evidence: [String: Any] = ["recorded_transcript": source.annotatedTranscript]
        if structured {
            if !source.anchors.isEmpty { evidence["user_notes_and_bookmarks"] = source.notesPayload }
        } else {
            evidence["written_user_context"] = source.notesText
            evidence["highlighted_evidence"] = source.highlightText ?? ""
        }
        let findings = structured && source.anchors.contains { $0.kind == .note && !$0.text.isEmpty }
        let prompt = MeetingSynthesis.finalPrompt(evidence: json(evidence), template: template,
                                                  glossary: glossary.prefix(80).map { String($0.prefix(200)) },
                                                  templateInstructions: custom, listsActions: true, quotesActions: true, findsWhatNotesAdd: findings)
        let noteText = structured ? source.anchors.map(\.text).joined(separator: "\n") : source.notesText
        return Prompt(instructions: MeetingSynthesis.instructions, prompt: prompt, schema: schema(template: template, noteFindings: findings),
                      transcript: source.transcript, noteText: noteText, warnings: warnings, findsWhatNotesAdd: findings)
    }

    /// The local summary schema (`MeetingSynthesis.summarySchema`) as the providers' structured outputs take it: plain
    /// strings, since their decoders escape quotes themselves, and no `maxItems`; each action item with its quote; and,
    /// with notes, their findings first, so they're written before the summary. Properties keep the local order.
    public static func schema(template: MeetingKind, noteFindings: Bool) -> String {
        let kinds = template == .auto ? MeetingKind.allCases.filter { $0 != .auto }.map(\.rawValue) : [template.rawValue]
        let text = #"{"type":"string"}"#
        let nullableText = #"{"anyOf":[{"type":"string"},{"type":"null"}]}"#
        var properties: [(String, String)] = []
        if noteFindings {
            properties.append(("notes", array(object([("label", text), ("said", text), ("adds", text), ("conflicts", text)]))))
        }
        properties += [
            ("kind", #"{"type":"string","enum":["# + kinds.map { "\"\($0)\"" }.joined(separator: ",") + "]}"),
            ("title", text), ("overview", text),
            ("sections", array(object([("heading", text), ("body", text)]))),
            ("actionItems", array(object([("text", text), ("owner", nullableText), ("evidence", text)]))),
            ("terms", array(text))
        ]
        return object(properties)
    }

    private static func array(_ items: String) -> String { #"{"type":"array","items":"# + items + "}" }

    /// An object schema whose properties are all required, in order.
    private static func object(_ properties: [(String, String)]) -> String {
        let fields = properties.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        let required = properties.map { "\"\($0.0)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"# + fields + #"},"required":["# + required + #"],"additionalProperties":false}"#
    }

    /// The summary in `reply`, read as a local one is (`MeetingSynthesis.parse`), with only the action items whose quotes
    /// are in the transcript, each with the owner its quote shows (`MeetingSynthesis.verifiedActions`).
    public static func notes(_ reply: String, prompt: Prompt, template: MeetingKind, modelID: String) -> GeneratedMeetingNotes {
        let parsed = MeetingSynthesis.parse(reply, requestedTemplate: template, modelID: modelID,
                                            source: prompt.transcript + "\n" + prompt.noteText, warnings: prompt.warnings)
        var summary = parsed.summary
        var warnings = parsed.warnings
        if prompt.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary.actionItems = []   // Nothing was said, so nothing can be shown to be agreed.
        } else if let quoted = quotedActions(reply), let verified = MeetingSynthesis.verifiedActions([quoted], source: prompt.transcript) {
            summary.actionItems = verified
        } else {
            warnings.append("The model could not validate task assignments against source quotes. Review the action items.")
        }
        return GeneratedMeetingNotes(summary: summary, suggestedTerms: parsed.suggestedTerms, rawResponse: reply, warnings: warnings)
    }

    /// The reply's action items as the commitments pass writes them (`{"actions":[{text, owner, evidence}]}`); nil when the
    /// reply isn't the JSON asked for.
    static func quotedActions(_ reply: String) -> String? {
        struct Reply: Decodable {
            struct Item: Decodable { var text: String; var owner: String?; var evidence: String? }
            var actionItems: [Item]
        }
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start <= end,
              let decoded = try? JSONDecoder().decode(Reply.self, from: Data(reply[start...end].utf8)) else { return nil }
        let actions: [[String: Any]] = decoded.actionItems.map { ["text": $0.text, "owner": $0.owner as Any? ?? NSNull(), "evidence": $0.evidence ?? ""] }
        return json(["actions": actions])
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
