import DaybookDesign
import DaybookKit
import SwiftUI

/// A term being added or edited in its form (the iPhone's Add Term and Edit Term).
public struct TermEditing: Identifiable, Equatable {
    public var term: GlossaryTerm
    public var isNew: Bool
    public var id: GlossaryTerm.ID { term.id }

    public init(term: GlossaryTerm, isNew: Bool) {
        self.term = term
        self.isNew = isNew
    }

    /// Add Term: a new term, used in every conversation.
    public static func adding() -> TermEditing { TermEditing(term: GlossaryTerm(term: "", approved: true), isNew: true) }
}

/// Vocabulary on both apps: names and words Daybook spells your way. A term from a conversation (a correction,
/// a summary's suggestion) is used in that conversation until you choose All conversations, the same on both.
/// Search covers a term's spelling, other spellings, and meaning; every change saves at once and can be undone.
/// On the Mac it's a window with a table edited in place; on the iPhone a list whose terms open their form.
///
/// `editing` lets the iPhone present the form its own way (a card on the open Duo's right page); without it the
/// screen presents it as a sheet. `showConversation` opens a term's conversation (the Mac's Show Conversation).
public struct VocabularyScreen: View {
    private let library: LibraryController
    private let editingBinding: Binding<TermEditing?>?
    private let showConversation: ((Meeting.ID) -> Void)?

    @State private var search = ""
    @State private var ownEditing: TermEditing?
    /// Terms waiting on Delete's confirmation.
    @State private var deleting: Set<GlossaryTerm.ID> = []
    @Environment(\.undoManager) private var undoManager
    #if os(macOS)
    @State private var selection = Set<GlossaryTerm.ID>()
    @State private var sortOrder = [KeyPathComparator(\GlossaryTerm.term, comparator: .localizedStandard)]
    /// A term being added in the table; it joins the vocabulary once it has a name.
    @State private var draft: GlossaryTerm?
    @FocusState private var focus: TermField?
    #endif

    public init(library: LibraryController, editing: Binding<TermEditing?>? = nil, showConversation: ((Meeting.ID) -> Void)? = nil) {
        self.library = library
        editingBinding = editing
        self.showConversation = showConversation
    }

    private var editor: VocabularyEditor { VocabularyEditor(library: library, undoManager: undoManager) }
    private var editing: Binding<TermEditing?> { editingBinding ?? $ownEditing }
    private var isEmpty: Bool { library.glossary.isEmpty }

    public var body: some View {
        content
            .confirmationDialog(VocabularyWords.deleteTitle(library.glossary.filter { deleting.contains($0.id) }),
                                isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                                titleVisibility: .visible) {
                Button(VocabularyWords.deleteTerms(deleting.count), role: .destructive) { delete(deleting) }
                Button("Cancel", role: .cancel) { }
            } message: {
                if let consequence = editor.deleteConsequence(deleting) { Text(consequence) }
            }
            .sheet(item: editingBinding == nil ? $ownEditing : .constant(nil)) { editing in
                NavigationStack { TermForm(library: library, editing: editing) }
            }
            #if DEBUG
            .task(id: library.isLoaded) { VocabularyDemo.apply(to: library) }
            #endif
    }

    /// Delete: at once (undoably) for terms used everywhere; asked first when one is limited to a conversation.
    private func requestDelete(_ ids: Set<GlossaryTerm.ID>) {
        #if os(macOS)
        if let draft, ids.contains(draft.id) { self.draft = nil }
        #endif
        guard !ids.isEmpty else { return }
        if editor.deletingAsks(ids) { deleting = ids } else { delete(ids) }
    }

    private func delete(_ ids: Set<GlossaryTerm.ID>) {
        editor.delete(ids)
        #if os(macOS)
        selection.subtract(ids)
        #endif
        deleting = []
    }

    private var emptyState: some View {
        DaybookEmptyState(title: VocabularyWords.emptyTitle, image: .symbol("character.book.closed"), message: VocabularyWords.emptyMessage)
    }

    // MARK: Compact: the iPhone

    #if os(iOS)
    private var content: some View {
        let rows = editor.rows(matching: search)
        return List {
            if isEmpty {
                // Add Term is the bar's +, so it isn't offered twice.
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DaybookSpacing.s6)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(rows) { term in
                        let scope = editor.scope(of: term)
                        Button { editing.wrappedValue = TermEditing(term: term, isNew: false) } label: {
                            TermRow(term: term, scope: scope)
                        }
                        .contextMenu { menu(for: term, scope: scope) }
                        .swipeActions {
                            Button(VocabularyWords.deleteTerm, systemImage: "trash") { requestDelete([term.id]) }
                                .tint(DaybookPalette.Ink.error)
                        }
                    }
                }
            }
        }
        .overlay {
            if !isEmpty && rows.isEmpty { ContentUnavailableView.search(text: search) }
        }
        // Searching needs something to search.
        .modifier(SearchableWhen(isOn: !isEmpty, text: $search, prompt: VocabularyWords.searchPrompt))
        .navigationTitle(VocabularyWords.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing.wrappedValue = .adding() } label: { Image(systemName: "plus") }
                    .accessibilityLabel(VocabularyWords.addTerm)
            }
        }
    }

    @ViewBuilder private func menu(for term: GlossaryTerm, scope: TermScope) -> some View {
        if term.canChangeScope {
            Picker(SettingsWords.titleCased(VocabularyWords.usedIn),
                   selection: Binding(get: { term.approved }, set: { editor.use(term.id, everywhere: $0) })) {
                Text(VocabularyWords.allConversations).tag(true)
                Text(editor.limitedScope(of: term).words).tag(false)
            }
        }
        if let id = scope.conversationID, let showConversation {
            Button(VocabularyWords.showConversation, systemImage: "doc.text") { showConversation(id) }
        }
        Button(scope.isLimited ? VocabularyWords.deleteTermConfirming : VocabularyWords.deleteTerm, systemImage: "trash", role: .destructive) {
            requestDelete([term.id])
        }
    }
    #endif

    // MARK: Wide: the Mac's window

    #if os(macOS)
    enum TermField: Hashable {
        case term(GlossaryTerm.ID), aliases(GlossaryTerm.ID), meaning(GlossaryTerm.ID)
    }

    private var rows: [GlossaryTerm] {
        var terms = library.glossary.filter { $0.matches(search) }.sorted(using: sortOrder)
        if let draft { terms.append(draft) }
        return terms
    }

    private var content: some View {
        searchField(table)
            .toolbar {
                // Icon-only, as Summary Templates' New Template.
                ToolbarItem(placement: .primaryAction) {
                    Button(VocabularyWords.addTerm, systemImage: "plus", action: addTerm)
                        .help(VocabularyWords.addTerm)
                }
            }
            // Four columns at their ideal widths, with the table's spacing, fit the narrowest window.
            .frame(minWidth: 640, minHeight: 320)
    }

    /// An empty vocabulary has nothing to search, so the field arrives with the first term. Adding one shows the table
    /// and the field together, so nothing is rebuilt while a term is being typed.
    @ViewBuilder private func searchField(_ content: some View) -> some View {
        if isEmpty && draft == nil {
            content
        } else {
            content.searchable(text: $search, placement: .toolbar, prompt: VocabularyWords.searchPrompt)
        }
    }

    @ViewBuilder private var table: some View {
        if isEmpty && draft == nil {
            // Add Term is in the toolbar; it isn't repeated here.
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(SettingsWords.titleCased(VocabularyWords.term), value: \.term) { term in
                    TermCell(value: term.term, prompt: term.id == draft?.id ? VocabularyWords.newTerm : "", label: VocabularyWords.term,
                             field: .term(term.id), focus: $focus) { rename(term.id, to: $0) }
                        .fontWeight(.medium)
                }
                .width(min: 100, ideal: 140)
                TableColumn(SettingsWords.titleCased(VocabularyWords.alsoHeardAs)) { term in
                    TermCell(value: term.aliasesText, prompt: term.id == draft?.id ? VocabularyWords.otherSpellings : "",
                             hoverPrompt: VocabularyWords.addSpellings, label: SettingsWords.titleCased(VocabularyWords.alsoHeardAs),
                             field: .aliases(term.id), focus: $focus) { respell(term.id, as: $0) }
                }
                .width(min: 90, ideal: 120)
                TableColumn(SettingsWords.titleCased(VocabularyWords.meaning)) { term in
                    TermCell(value: term.definition, prompt: term.id == draft?.id ? VocabularyWords.meaning : "",
                             hoverPrompt: VocabularyWords.addMeaning, label: VocabularyWords.meaning, field: .meaning(term.id), focus: $focus,
                             commit: { describe(term.id, as: $0) }, submit: { if term.id == rows.last?.id { addTerm() } })
                }
                .width(min: 120, ideal: 170)
                TableColumn(SettingsWords.titleCased(VocabularyWords.usedIn)) { term in
                    UsedInCell(term: term, scope: editor.scope(of: term), limited: editor.limitedScope(of: term)) { everywhere in
                        editor.use(term.id, everywhere: everywhere)
                    }
                }
                .width(min: 110, ideal: 140)
            }
            .overlay {
                if rows.isEmpty { ContentUnavailableView.search(text: search) }
            }
            .contextMenu(forSelectionType: GlossaryTerm.ID.self) { ids in
                if ids.count == 1, let id = ids.first, let term = editor.term(id), let conversation = editor.scope(of: term).conversationID,
                   let showConversation {
                    Button(VocabularyWords.showConversation) { showConversation(conversation) }
                    Divider()
                }
                if !ids.isEmpty {
                    let terms = VocabularyWords.deleteTerms(ids.count)
                    Button(editor.deletingAsks(ids) ? terms + "…" : terms) { requestDelete(ids) }
                }
            }
            .onDeleteCommand { requestDelete(selection) }
            .onKeyPress(.return) {
                // Return on a selected row edits its term, as in Finder.
                guard focus == nil, selection.count == 1, let id = selection.first else { return .ignored }
                focus = .term(id)
                return .handled
            }
        }
    }

    private func addTerm() {
        search = ""
        if draft == nil { draft = GlossaryTerm(term: "", approved: true) }
        guard let id = draft?.id else { return }
        selection = [id]
        Task { @MainActor in focus = .term(id) }
    }

    /// Returns the text the cell should show after committing.
    private func rename(_ id: GlossaryTerm.ID, to text: String) -> String {
        if let term = draft, term.id == id {
            draft = nil
            var named = term
            named.term = text
            return editor.add(named)
        }
        return editor.rename(id, to: text)
    }

    private func describe(_ id: GlossaryTerm.ID, as text: String) -> String {
        if draft?.id == id {
            let meaning = text.trimmingCharacters(in: .whitespacesAndNewlines)
            draft?.definition = meaning
            return meaning
        }
        return editor.describe(id, as: text)
    }

    private func respell(_ id: GlossaryTerm.ID, as text: String) -> String {
        if draft?.id == id {
            draft?.aliases = GlossaryTerm.aliases(from: text)
            return draft?.aliasesText ?? ""
        }
        return editor.respell(id, as: text)
    }
    #endif
}

#if os(macOS)
/// A table cell edited in place. It commits on Return and when focus leaves it.
private struct TermCell: View {
    let value: String
    let prompt: String
    /// Shown in place of an empty prompt while the pointer is over the cell.
    var hoverPrompt: String?
    let label: String
    let field: VocabularyScreen.TermField
    var focus: FocusState<VocabularyScreen.TermField?>.Binding
    let commit: (String) -> String
    let submit: () -> Void
    @State private var text: String
    @State private var hovering = false

    init(value: String, prompt: String, hoverPrompt: String? = nil, label: String, field: VocabularyScreen.TermField,
         focus: FocusState<VocabularyScreen.TermField?>.Binding,
         commit: @escaping (String) -> String, submit: @escaping () -> Void = { }) {
        self.value = value; self.prompt = prompt; self.hoverPrompt = hoverPrompt; self.label = label; self.field = field
        self.focus = focus; self.commit = commit; self.submit = submit
        _text = State(initialValue: value)
    }

    private var shownPrompt: String {
        guard prompt.isEmpty, let hoverPrompt, hovering || focus.wrappedValue == field else { return prompt }
        return hoverPrompt
    }

    var body: some View {
        TextField(label, text: $text, prompt: Text(shownPrompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .focused(focus, equals: field)
            .onChange(of: value) { _, new in text = new }
            .onSubmit { text = commit(text); submit() }
            .onChange(of: focus.wrappedValue) { old, new in
                if old == field && new != field { text = commit(text) }
            }
            .help(text)
    }
}

/// "All conversations", or "Only “Conversation”" for a term from one conversation, with a menu to change it.
private struct UsedInCell: View {
    let term: GlossaryTerm
    let scope: TermScope
    /// What the menu offers besides All conversations.
    let limited: TermScope
    let change: (Bool) -> Void

    var body: some View {
        if !term.canChangeScope {
            Text(VocabularyWords.allConversations).foregroundStyle(.secondary)
        } else {
            Menu {
                Picker(SettingsWords.titleCased(VocabularyWords.usedIn), selection: Binding(get: { term.approved }, set: change)) {
                    Text(VocabularyWords.allConversations).tag(true)
                    Text(limited.words).tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 3) {
                    ScopeLabel(scope: scope)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help(scope == .none ? VocabularyWords.noConversationsHelp : scope.words)
            .accessibilityLabel(SettingsWords.titleCased(VocabularyWords.usedIn))
            .accessibilityValue(scope.words)
        }
    }
}
#endif

/// Where a term is used, in its row: secondary, or warning ink with the glyph for a term whose conversation
/// is gone.
struct ScopeLabel: View {
    let scope: TermScope
    @Environment(\.daybookDensity) private var density

    var body: some View {
        if scope == .none {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(scope.words)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(density == .touch ? .caption2 : .system(size: 10))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(DaybookPalette.Ink.warning)
        } else {
            Text(scope.words).foregroundStyle(density == .touch ? AnyShapeStyle(DaybookPalette.Ink.secondary) : AnyShapeStyle(.secondary))
        }
    }
}

/// A term in the iPhone's list: its spelling, its other spellings and meaning, and where it's used when that
/// isn't every conversation.
struct TermRow: View {
    let term: GlossaryTerm
    let scope: TermScope

    var body: some View {
        // Explicit inks: the row is a button's label, and a list tints those (`.primary` would turn teal).
        VStack(alignment: .leading, spacing: 2) {
            Text(term.term).foregroundStyle(DaybookPalette.Ink.title)
            let detail = [term.aliases.isEmpty ? nil : "\(VocabularyWords.alsoHeardAs) \(term.aliasesText)",
                          term.definition.isEmpty ? nil : term.definition].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(DaybookPalette.Ink.secondary).lineLimit(2)
            }
            if scope.isLimited {
                ScopeLabel(scope: scope).font(.footnote)
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// `.searchable` only while there's something to search.
struct SearchableWhen: ViewModifier {
    let isOn: Bool
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        if isOn {
            content.searchable(text: $text, prompt: prompt)
        } else {
            content
        }
    }
}
