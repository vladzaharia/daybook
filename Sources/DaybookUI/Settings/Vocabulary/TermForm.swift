import DaybookDesign
import DaybookKit
import SwiftUI

/// Add Term and Edit Term: a term's spelling, the other spellings the transcript might use, what it means, and
/// (for a term from a conversation) where it's used, then Delete Term. Cancel with changes asks before they go,
/// and the sheet can't be swiped away with them.
public struct TermForm: View {
    private let library: LibraryController
    private let original: GlossaryTerm
    private let isNew: Bool
    @State private var term: GlossaryTerm
    @State private var aliases: String
    @State private var confirmingDiscard = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    public init(library: LibraryController, editing: TermEditing) {
        self.library = library
        original = editing.term
        isNew = editing.isNew
        _term = State(initialValue: editing.term)
        _aliases = State(initialValue: editing.term.aliasesText)
    }

    private var editor: VocabularyEditor { VocabularyEditor(library: library, undoManager: undoManager) }

    /// The term as it would be saved.
    private var edited: GlossaryTerm {
        var value = term
        value.term = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
        value.definition = term.definition.trimmingCharacters(in: .whitespacesAndNewlines)
        value.aliases = GlossaryTerm.aliases(from: aliases)
        return value
    }

    /// Something typed that Cancel or a swipe would lose.
    var hasChanges: Bool {
        let value = edited
        return value.term != original.term || value.definition != original.definition || value.aliases != original.aliases
            || value.approved != original.approved
    }

    public var body: some View {
        Form {
            Section(VocabularyWords.term.asSettingsLabel) {
                TextField(VocabularyWords.spelledAs, text: $term.term)
                    .touchKeyboard(capitalization: .never)
            }
            Section {
                // Short, so it fits a page of the open iPhone Duo; the footer says the rest.
                TextField(VocabularyWords.otherSpellings, text: $aliases)
                    .touchKeyboard(capitalization: .never)
            } header: {
                Text(VocabularyWords.alsoHeardAs.asSettingsLabel)
            } footer: {
                Text(VocabularyWords.otherSpellingsFooter)
            }
            Section(VocabularyWords.meaning.asSettingsLabel) {
                TextField(VocabularyWords.meaning, text: $term.definition, prompt: Text(VocabularyWords.optional), axis: .vertical)
                    .lineLimit(2...5)
            }
            if term.canChangeScope {
                Section {
                    Picker(VocabularyWords.usedIn.asSettingsLabel, selection: $term.approved) {
                        Text(VocabularyWords.allConversations).tag(true)
                        Text(editor.limitedScope(of: term).words).tag(false)
                    }
                }
            }
            if !isNew {
                Section {
                    let limited = editor.scope(of: original).isLimited
                    Button(limited ? VocabularyWords.deleteTermConfirming : VocabularyWords.deleteTerm, role: .destructive) {
                        if limited { confirmingDelete = true } else { delete() }
                    }
                }
            }
        }
        .navigationTitle(isNew ? VocabularyWords.addTerm : VocabularyWords.editTerm)
        .touchInlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { if hasChanges { confirmingDiscard = true } else { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(edited.term.isEmpty || !hasChanges)
            }
        }
        .guardingDismissal(hasChanges)
        .confirmationDialog("", isPresented: $confirmingDiscard, titleVisibility: .hidden) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) { }
        }
        .confirmationDialog(VocabularyWords.deleteTitle([original]), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(VocabularyWords.deleteTerm, role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let consequence = editor.deleteConsequence([original.id]) { Text(consequence) }
        }
    }

    private func save() {
        let value = edited
        guard !value.term.isEmpty else { return }
        if isNew {
            editor.add(value)
        } else {
            // Only what the person changed, onto the term as the library has it now.
            editor.save(value, openedAs: original)
        }
        dismiss()
    }

    private func delete() {
        editor.delete([original.id])
        dismiss()
    }
}

/// Whether a sheet a Settings screen shows has changes that dismissing it would lose: such a sheet can't be swiped
/// away, and the iPhone's card on the open Duo's right page (which a sheet would be there) reads it too, so its
/// own drag and the VoiceOver escape leave it be. The form's Cancel asks first.
public struct DismissalGuardKey: PreferenceKey {
    public static let defaultValue = false
    public static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// Keeps the sheet this is in from being dismissed by a swipe (or the Duo card's drag or escape) while
    /// `guarded`.
    public func guardingDismissal(_ guarded: Bool) -> some View {
        interactiveDismissDisabled(guarded)
            .preference(key: DismissalGuardKey.self, value: guarded)
    }
}
