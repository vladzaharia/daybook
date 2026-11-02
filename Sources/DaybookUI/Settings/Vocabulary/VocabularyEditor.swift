import DaybookKit
import Foundation

/// What Vocabulary does to the library's terms, on both apps: each change saves at once through
/// `LibraryController` (so it syncs) and can be undone, from Edit › Undo on the Mac and by shaking the iPhone.
@MainActor
public struct VocabularyEditor {
    public let library: LibraryController
    public let undoManager: UndoManager?

    public init(library: LibraryController, undoManager: UndoManager?) {
        self.library = library
        self.undoManager = undoManager
    }

    public func term(_ id: GlossaryTerm.ID) -> GlossaryTerm? { library.glossary.first { $0.id == id } }

    /// The terms a search finds (spelling, other spellings, meaning), by spelling.
    public func rows(matching query: String) -> [GlossaryTerm] {
        GlossaryTerm.sorted(library.glossary.filter { $0.matches(query) })
    }

    /// Where a term is used, naming its conversation.
    public func scope(of term: GlossaryTerm) -> TermScope { term.scope(in: library.meetings) }

    /// What Used In offers for a term limited to a conversation: that conversation (or none, when it's gone).
    public func limitedScope(of term: GlossaryTerm) -> TermScope {
        var limited = term
        limited.approved = false
        return limited.scope(in: library.meetings)
    }

    // MARK: Changes

    /// Saves a new term or an edit. `old` is the term as it was, nil for a new one; the undo puts it back.
    public func save(_ term: GlossaryTerm, replacing old: GlossaryTerm?, actionName: String) {
        var term = term
        term.updatedAt = Date()
        library.saveGlossaryTerm(term)
        registerRestore(old.map { [$0] } ?? [], removing: old == nil ? [term.id] : [])
        undoManager?.setActionName(actionName)
    }

    /// A new term's spelling: it joins the vocabulary, used in every conversation. Returns the spelling saved,
    /// or "" when there's none (nothing is added).
    @discardableResult
    public func add(_ term: GlossaryTerm) -> String {
        var term = term
        term.term = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.term.isEmpty else { return "" }
        save(term, replacing: nil, actionName: VocabularyWords.undoAdd)
        return term.term
    }

    /// Renames a term. Returns the spelling it shows afterwards: the old one for a blank name.
    @discardableResult
    public func rename(_ id: GlossaryTerm.ID, to text: String) -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let term = term(id) else { return text }
        guard !name.isEmpty, name != term.term else { return term.term }
        var changed = term
        changed.term = name
        save(changed, replacing: term, actionName: VocabularyWords.undoRename)
        return name
    }

    /// Changes what a term means. Returns the meaning it shows afterwards.
    @discardableResult
    public func describe(_ id: GlossaryTerm.ID, as text: String) -> String {
        let meaning = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let term = term(id), term.definition != meaning else { return meaning }
        var changed = term
        changed.definition = meaning
        save(changed, replacing: term, actionName: VocabularyWords.undoMeaning)
        return meaning
    }

    /// Changes a term's other spellings, typed as one field separated by commas. Returns the field as it
    /// reads afterwards.
    @discardableResult
    public func respell(_ id: GlossaryTerm.ID, as text: String) -> String {
        let aliases = GlossaryTerm.aliases(from: text)
        guard let term = term(id) else { return text }
        guard term.aliases != aliases else { return term.aliasesText }
        var changed = term
        changed.aliases = aliases
        save(changed, replacing: term, actionName: VocabularyWords.undoSpellings)
        return changed.aliasesText
    }

    /// Used In: every conversation, or only the one the term came from.
    public func use(_ id: GlossaryTerm.ID, everywhere: Bool) {
        guard let term = term(id), term.approved != everywhere, term.canChangeScope || everywhere else { return }
        var changed = term
        changed.approved = everywhere
        save(changed, replacing: term, actionName: VocabularyWords.undoScope)
    }

    /// Whether deleting these asks first: one is used only in a conversation (or none), which won't spell it
    /// this way when it's transcribed again.
    public func deletingAsks(_ ids: Set<GlossaryTerm.ID>) -> Bool {
        library.glossary.contains { ids.contains($0.id) && scope(of: $0).isLimited }
    }

    /// The confirmation's sentence for deleting these: what their conversations lose.
    public func deleteConsequence(_ ids: Set<GlossaryTerm.ID>) -> String? {
        VocabularyWords.deleteConsequence(library.glossary.filter { ids.contains($0.id) }.map(scope(of:)))
    }

    public func delete(_ ids: Set<GlossaryTerm.ID>) {
        let removed = library.glossary.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        removed.forEach { library.removeGlossaryTerm($0.id) }
        registerRestore(removed, removing: [])
        undoManager?.setActionName(VocabularyWords.undoDelete(removed.count))
    }

    // MARK: Undo

    /// Registers an undo that saves `terms` as they were and removes `added`; its own undo is the redo.
    private func registerRestore(_ terms: [GlossaryTerm], removing added: [GlossaryTerm.ID]) {
        Self.registerRestore(terms, removing: added, in: library, undoManager)
    }

    private static func registerRestore(_ terms: [GlossaryTerm], removing added: [GlossaryTerm.ID], in library: LibraryController,
                                        _ undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: library) { [weak undoManager] library in
            MainActor.assumeIsolated {
                let current = library.glossary.filter { term in terms.contains { $0.id == term.id } || added.contains(term.id) }
                let reAdded = terms.filter { term in !library.glossary.contains { $0.id == term.id } }.map(\.id)
                added.forEach(library.removeGlossaryTerm)
                terms.forEach(library.saveGlossaryTerm)
                registerRestore(current, removing: reAdded, in: library, undoManager)
            }
        }
    }
}
