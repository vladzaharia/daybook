import DaybookCore
import DaybookKit
import Foundation

// The source data a summary's passes give the model, as typed values with their keys spelled once. They
// encode exactly as the dictionaries they replaced did: keys sorted, slashes left alone
// (`SynthesisPayloadTests` holds them to it), because the prompts are calibrated byte for byte against
// specific models (docs/validation.md).

/// Encodes the source data the passes give the model: keys sorted, slashes left alone.
enum SynthesisJSON {
    static func string<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Strings, arrays, booleans, and nulls always encode.
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The conversation as the passes read it: the transcript with the person's notes and bookmarks in it,
/// and either those notes and bookmarks (`SummarySource.isStructured`) or, for a source from strings,
/// the written notes and highlighted passages.
public struct SourcePayload: Encodable, Equatable, Sendable {
    var recordedTranscript: String
    var userNotesAndBookmarks: [NotePayload]?
    var writtenUserContext: String?
    var highlightedEvidence: String?

    enum CodingKeys: String, CodingKey {
        case recordedTranscript = "recorded_transcript"
        case userNotesAndBookmarks = "user_notes_and_bookmarks"
        case writtenUserContext = "written_user_context"
        case highlightedEvidence = "highlighted_evidence"
    }

    init(_ source: SummarySource) {
        recordedTranscript = source.annotatedTranscript
        if source.isStructured {
            let notes = NotePayload.all(source)
            userNotesAndBookmarks = notes.isEmpty ? nil : notes
        } else {
            writtenUserContext = source.notesText
            highlightedEvidence = source.highlightText ?? ""
        }
    }
}

/// One note or bookmark, for the model: label, kind, time (null when it has none), and text; a note
/// found to repeat what was said goes without its words. A bookmark on a recording that isn't lined up
/// also carries that recording's passages around it.
public struct NotePayload: Encodable, Equatable, Sendable {
    var label: String
    var kind: String
    var time: String?
    var text: String
    var repeatsWhatWasSaid: Bool
    var placement: String?
    var recording: String?
    var context: [String]

    enum CodingKeys: String, CodingKey {
        case label, kind, time, text, placement, recording, context
        case repeatsWhatWasSaid = "repeats_what_was_said"
    }

    init(_ anchor: SummarySource.Anchor) {
        label = anchor.label
        kind = anchor.kind.rawValue
        time = anchor.time.map { TimeLabel.format($0) }
        text = anchor.repeatsWhatWasSaid ? "" : anchor.text
        repeatsWhatWasSaid = anchor.repeatsWhatWasSaid
        placement = anchor.kind == .note && anchor.time == nil ? "written outside the recording" : nil
        recording = anchor.recording
        context = anchor.context
    }

    static func all(_ source: SummarySource) -> [NotePayload] { source.anchors.map(NotePayload.init) }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(kind, forKey: .kind)
        // Always present: null says the note has no place on the timeline.
        if let time { try container.encode(time, forKey: .time) } else { try container.encodeNil(forKey: .time) }
        try container.encode(text, forKey: .text)
        if repeatsWhatWasSaid { try container.encode(true, forKey: .repeatsWhatWasSaid) }
        try container.encodeIfPresent(placement, forKey: .placement)
        if let recording {
            try container.encode(recording, forKey: .recording)
            try container.encode(context, forKey: .context)
        }
    }
}

/// The notes and bookmarks alone, as they travel with every part of a long conversation.
struct NotesPayload: Encodable {
    var userNotesAndBookmarks: [NotePayload]
    enum CodingKeys: String, CodingKey { case userNotesAndBookmarks = "user_notes_and_bookmarks" }
}

/// One part of a long conversation, as an extraction pass reads it.
struct SourcePart: Encodable {
    /// What the part is from, by the key the whole source gives it.
    enum Kind: String, Encodable {
        case recordedTranscript = "recorded_transcript"
        case userNotesAndBookmarks = "user_notes_and_bookmarks"
        case writtenUserContext = "written_user_context"
        case highlightedEvidence = "highlighted_evidence"
    }

    var kind: Kind
    var content: String

    enum CodingKeys: String, CodingKey {
        case kind = "source_type"
        case content
    }
}

/// Evidence notes being compressed.
struct EvidenceNotes: Encodable {
    var evidenceNotes: String
    enum CodingKeys: String, CodingKey { case evidenceNotes = "evidence_notes" }
}

/// One note on the timeline with what was said around it, for the note check.
struct NoteCheckItem: Encodable, Equatable {
    var label: String
    var note: String
    var passagesAroundIt: String
    enum CodingKeys: String, CodingKey {
        case label, note
        case passagesAroundIt = "passages_around_it"
    }
}

/// The notes the note check compares.
struct NoteCheckRequest: Encodable {
    var notes: [NoteCheckItem]
}

/// What the final pass reads: the conversation itself when it fits, or what the extraction passes made of
/// a longer one.
public enum FinalEvidence: Encodable, Equatable, Sendable {
    case conversation(SourcePayload)
    case extracted(String)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .conversation(let payload): try payload.encode(to: encoder)
        case .extracted(let text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }
    }
}

/// The final pass's source data: the evidence and the vocabulary, with the notes and the passages near them
/// in a long conversation, and the photos.
struct FinalSource: Encodable {
    var evidence: FinalEvidence
    var glossarySpellings: [String]
    var userNotesAndBookmarks: [NotePayload]?
    var passagesNearNotesAndBookmarks: String?
    var photos: String?

    enum CodingKeys: String, CodingKey {
        case evidence
        case glossarySpellings = "glossary_spellings"
        case userNotesAndBookmarks = "user_notes_and_bookmarks"
        case passagesNearNotesAndBookmarks = "passages_near_notes_and_bookmarks"
        case photos
    }
}

/// A JSON Schema for a string matching `pattern`.
struct StringPatternSchema: Encodable {
    var type = "string"
    var pattern: String
}

/// A custom template's instructions, given beside the source data.
struct TemplatePreferences: Encodable {
    var templatePreferences: String
    enum CodingKeys: String, CodingKey { case templatePreferences = "template_preferences" }
}

/// One part of the recorded transcript, as a commitments pass reads it: the words as they were said,
/// without notes, so every quote can be checked against them.
struct TranscriptPart: Encodable {
    var recordedTranscript: String
    enum CodingKeys: String, CodingKey { case recordedTranscript = "recorded_transcript" }
}

/// Action items with their quotes, as the commitments pass writes them, so the cloud summary's are checked
/// the same way (`CloudSynthesis.quotedActions`).
struct QuotedActions: Encodable {
    struct Action: Encodable {
        var text: String
        var owner: String?
        var evidence: String

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            // Always present: null says no owner was stated.
            if let owner { try container.encode(owner, forKey: .owner) } else { try container.encodeNil(forKey: .owner) }
            try container.encode(evidence, forKey: .evidence)
        }

        enum CodingKeys: String, CodingKey { case text, owner, evidence }
    }

    var actions: [Action]
}
