import DaybookCore
import Foundation

// What Summary Templates and Vocabulary say about each item, once for both apps (docs/templates.md,
// docs/interface.md): a template's symbol, purpose, and whether it was edited; where a term is used, and
// what a search finds.

extension SummaryTemplate {
    /// Built-ins have their own symbol; the person's own templates are documents.
    public var systemImage: String {
        switch id {
        case "planning": return "calendar"
        case "retrospective": return "arrow.uturn.backward.circle"
        case "customer-discovery": return "binoculars"
        case "design-review": return "paintbrush.pointed"
        case "decision-memo": return "checkmark.seal"
        default: return isBuiltIn ? kind.systemImage : "doc.text"
        }
    }

    /// Its name as a list shows it: "Untitled Template" when it has none.
    public var displayName: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? TemplateWords.untitled : name
    }

    /// The first line of its instructions, which states what it's for ("Help someone remember a conversation
    /// and act on what was agreed."), without the built-ins' "Purpose: ". Empty when it has no instructions.
    public var purpose: String {
        let first = instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        let purpose = trimmed.hasPrefix("Purpose: ") ? String(trimmed.dropFirst("Purpose: ".count)) : trimmed
        return purpose.prefix(1).uppercased() + purpose.dropFirst()
    }

    /// The bundled original of a built-in; nil for the person's own.
    public var original: SummaryTemplate? { Self.builtIns.first { $0.id == id } }

    /// Whether its name, kind, or instructions differ from `original`. A saved copy identical to the original
    /// isn't edited, and the person's own templates never are.
    public func isEdited(comparedTo original: SummaryTemplate?) -> Bool {
        guard let original else { return false }
        return original.name != name || original.kind != kind || original.instructions != instructions
    }

    /// A built-in that differs from its bundled original (Edited, with Restore Original).
    public var isEdited: Bool { isEdited(comparedTo: original) }

    /// Whether `other` says something different: what saving compares, so a save that changes nothing isn't
    /// written (or synced).
    public func differs(from other: SummaryTemplate) -> Bool {
        name != other.name || kind != other.kind || instructions != other.instructions
    }

    /// A new template of the person's own, ready to edit.
    public static func untitled() -> SummaryTemplate {
        SummaryTemplate(name: TemplateWords.untitled, kind: .general, instructions: "")
    }

    /// The built-ins in their fixed order, then the person's own by name, as both apps list them.
    public static func sections(_ templates: [SummaryTemplate]) -> (builtIn: [SummaryTemplate], yours: [SummaryTemplate]) {
        let builtIn = templates.filter(\.isBuiltIn)
        let yours = templates.filter { !$0.isBuiltIn }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return (builtIn, yours)
    }
}

extension MeetingKind {
    /// A conversation kind's symbol: a template's, and the Used for picker's.
    public var systemImage: String {
        switch self {
        case .auto: return "text.bubble"
        case .general: return "person.3"
        case .oneOnOne: return "person.2"
        case .scrum: return "sunrise"
        case .therapy: return "heart.text.square"
        case .personal: return "house"
        case .interview: return "person.crop.rectangle"
        case .lecture: return "graduationcap"
        }
    }

    /// The kinds a template can be used for: every kind but Automatic.
    public static var templateKinds: [MeetingKind] { allCases.filter { $0 != .auto } }
}

/// Where a vocabulary term is used: in every conversation, only in the one it came from, or (a term from a
/// conversation that's gone) in none. A term proposed from a conversation is used there until the person
/// chooses All conversations (`GlossaryStore.terms(for:)`).
public enum TermScope: Equatable, Sendable {
    case all
    case conversation(Meeting.ID, title: String)
    case none

    /// "All conversations", "Only “Weekly product sync”", "No conversations".
    public var words: String {
        switch self {
        case .all: return VocabularyWords.allConversations
        case .conversation(_, let title): return VocabularyWords.only(title)
        case .none: return VocabularyWords.noConversations
        }
    }

    /// The conversation it's limited to, when there is one.
    public var conversationID: Meeting.ID? {
        if case .conversation(let id, _) = self { return id }
        return nil
    }

    /// Used in one conversation, or in none: deleting it is confirmed, since that conversation won't spell it
    /// this way when it's transcribed again.
    public var isLimited: Bool { self != .all }
}

extension GlossaryTerm {
    /// Where it's used, naming its conversation from `meetings`.
    public func scope(in meetings: [Meeting]) -> TermScope {
        if approved { return .all }
        guard let meeting = meetings.first(where: { sourceMeetingIDs.contains($0.id) }) else { return .none }
        return .conversation(meeting.id, title: meeting.title)
    }

    /// Whether Used In can change: only a term that came from a conversation can be limited to it.
    public var canChangeScope: Bool { !approved || !sourceMeetingIDs.isEmpty }

    /// Whether a search finds it: its spelling, its other spellings, or its meaning.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return term.localizedCaseInsensitiveContains(query)
            || definition.localizedCaseInsensitiveContains(query)
            || aliases.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Its other spellings as one field shows them: "day book, daybook".
    public var aliasesText: String { aliases.joined(separator: ", ") }

    /// Other spellings typed into one field, separated by commas, each once and without blanks.
    public static func aliases(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// A list's order: by spelling, as Finder sorts names.
    public static func sorted(_ terms: [GlossaryTerm]) -> [GlossaryTerm] {
        terms.sorted { $0.term.localizedStandardCompare($1.term) == .orderedAscending }
    }
}
