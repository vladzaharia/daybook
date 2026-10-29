import DaybookCore
import SwiftUI

/// Vocabulary (Direction A §5.15): names and terms Daybook spells correctly. A term proposed
/// from a conversation can stay with that conversation, or be used in all of them.
struct GlossaryView: View {
    @ObservedObject var state: AppState
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\GlossaryTerm.term, comparator: .localizedStandard)]
    /// A term being added; it joins the vocabulary once it has a name.
    @State private var draft: GlossaryTerm?
    @FocusState private var focus: TermField?

    private var rows: [GlossaryTerm] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var terms = state.glossary.filter { term in
            query.isEmpty || term.term.localizedCaseInsensitiveContains(query)
                || term.definition.localizedCaseInsensitiveContains(query)
                || term.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        .sorted(using: sortOrder)
        if let draft { terms.append(draft) }
        return terms
    }

    var body: some View {
        searchField(content)
            .toolbar {
                // Icon-only, as Summary Templates' New Template.
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Term", systemImage: "plus", action: addTerm)
                        .help("Add Term")
                }
            }
            .frame(minWidth: 520, minHeight: 320)
            #if DEBUG
            .task { VocabularyDemo.apply(to: state) }
            #endif
    }

    /// An empty vocabulary has nothing to search, so the field arrives with the first term. Adding one shows the table
    /// and the field together, so nothing is rebuilt while a term is being typed.
    @ViewBuilder private func searchField(_ content: some View) -> some View {
        if state.glossary.isEmpty && draft == nil {
            content
        } else {
            content.searchable(text: $search, placement: .toolbar, prompt: "Search Terms")
        }
    }

    @ViewBuilder private var content: some View {
        if state.glossary.isEmpty && draft == nil {
            // Add Term is in the toolbar; it isn't repeated here.
            ContentUnavailableView {
                Label("No Vocabulary Yet", systemImage: "character.book.closed")
            } description: {
                Text("Add names, acronyms, and terms so Daybook spells them correctly.")
            }
        } else {
            table
                .overlay {
                    if rows.isEmpty { ContentUnavailableView.search(text: search) }
                }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Term", value: \.term) { term in
                TermCell(value: term.term, prompt: term.id == draft?.id ? "New Term" : "", label: "Term",
                         field: .term(term.id), focus: $focus) { rename(term.id, to: $0) }
                    .fontWeight(.medium)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Meaning") { term in
                TermCell(value: term.definition, prompt: term.id == draft?.id ? "Meaning" : "", hoverPrompt: "Add meaning",
                         label: "Meaning", field: .meaning(term.id), focus: $focus, commit: { describe(term.id, as: $0) },
                         submit: { if term.id == rows.last?.id { addTerm() } })
            }
            .width(min: 140, ideal: 230)
            TableColumn("Used In") { term in
                UsedInCell(state: state, term: term) { approved in
                    var changed = term
                    changed.approved = approved
                    save(changed, replacing: term, actionName: "Change Where Term Is Used")
                }
            }
            .width(min: 130, ideal: 190)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let meeting = scopedConversation(id) {
                Button("Show Conversation") { show(meeting) }
                Divider()
            }
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Delete Term" : "Delete \(ids.count) Terms") { delete(ids) }
            }
        }
        .onDeleteCommand { delete(selection) }
        .onKeyPress(.return) {
            // Return on a selected row edits its term, as in Finder.
            guard focus == nil, selection.count == 1, let id = selection.first else { return .ignored }
            focus = .term(id)
            return .handled
        }
    }

    // MARK: Editing

    private func addTerm() {
        search = ""
        if draft == nil { draft = GlossaryTerm(term: "", approved: true) }
        guard let id = draft?.id else { return }
        selection = [id]
        Task { @MainActor in focus = .term(id) }
    }

    /// Returns the text the cell should show after committing.
    private func rename(_ id: UUID, to text: String) -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if var term = draft, term.id == id {
            guard !name.isEmpty else { draft = nil; return "" }
            term.term = name
            draft = nil
            save(term, replacing: nil, actionName: "Add Term")
            return name
        }
        guard let term = state.glossary.first(where: { $0.id == id }) else { return text }
        guard !name.isEmpty, name != term.term else { return term.term }
        var changed = term
        changed.term = name
        save(changed, replacing: term, actionName: "Rename Term")
        return name
    }

    private func describe(_ id: UUID, as text: String) -> String {
        let meaning = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft?.id == id { draft?.definition = meaning; return meaning }
        guard let term = state.glossary.first(where: { $0.id == id }), term.definition != meaning else { return meaning }
        var changed = term
        changed.definition = meaning
        save(changed, replacing: term, actionName: "Change Meaning")
        return meaning
    }

    private func save(_ term: GlossaryTerm, replacing old: GlossaryTerm?, actionName: String) {
        var term = term
        term.updatedAt = Date()
        state.saveGlossaryTerm(term)
        VocabularyUndo.registerRestore(old.map { [$0] } ?? [], removing: old == nil ? [term.id] : [], in: state, undoManager)
        undoManager?.setActionName(actionName)
    }

    private func delete(_ ids: Set<UUID>) {
        let removed = state.glossary.filter { ids.contains($0.id) }
        if let draft, ids.contains(draft.id) { self.draft = nil }
        guard !removed.isEmpty else { return }
        removed.forEach { state.removeGlossaryTerm($0.id) }
        selection.subtract(ids)
        VocabularyUndo.registerRestore(removed, removing: [], in: state, undoManager)
        undoManager?.setActionName(removed.count == 1 ? "Delete Term" : "Delete Terms")
    }

    // MARK: Conversations

    private func scopedConversation(_ id: UUID) -> Meeting? {
        guard let term = state.glossary.first(where: { $0.id == id }), !term.approved else { return nil }
        return state.meetings.first { term.sourceMeetingIDs.contains($0.id) }
    }

    private func show(_ meeting: Meeting) {
        state.place = .section(.all)
        state.selectedID = meeting.id
        openWindow(id: WindowID.library)
    }

    enum TermField: Hashable {
        case term(UUID), meaning(UUID)
    }
}

/// Undo and redo for vocabulary changes, which save immediately.
@MainActor
private enum VocabularyUndo {
    /// Registers an undo that saves `terms` as they were and removes `added`.
    static func registerRestore(_ terms: [GlossaryTerm], removing added: [UUID], in state: AppState, _ undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: state) { [weak undoManager] state in
            MainActor.assumeIsolated {
                let current = state.glossary.filter { term in terms.contains { $0.id == term.id } || added.contains(term.id) }
                let reAdded = terms.filter { term in !state.glossary.contains { $0.id == term.id } }.map(\.id)
                added.forEach(state.removeGlossaryTerm)
                terms.forEach(state.saveGlossaryTerm)
                registerRestore(current, removing: reAdded, in: state, undoManager)
            }
        }
    }
}

/// A table cell edited in place. It commits on Return and when focus leaves it.
private struct TermCell: View {
    let value: String
    let prompt: String
    /// Shown in place of an empty prompt while the pointer is over the cell.
    var hoverPrompt: String?
    let label: String
    let field: GlossaryView.TermField
    var focus: FocusState<GlossaryView.TermField?>.Binding
    let commit: (String) -> String
    let submit: () -> Void
    @State private var text: String
    @State private var hovering = false

    init(value: String, prompt: String, hoverPrompt: String? = nil, label: String, field: GlossaryView.TermField,
         focus: FocusState<GlossaryView.TermField?>.Binding,
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
    }
}

/// "All conversations", or "Only “Conversation”" for a term proposed from one conversation.
private struct UsedInCell: View {
    @ObservedObject var state: AppState
    let term: GlossaryTerm
    let change: (Bool) -> Void

    /// "Only “Weekly product sync”"; a proposed term whose conversation is gone isn't used anywhere.
    private var scope: String? {
        state.meetings.first(where: { term.sourceMeetingIDs.contains($0.id) }).map { "Only “\($0.title)”" }
    }

    var body: some View {
        if term.approved && term.sourceMeetingIDs.isEmpty {
            Text("All conversations").foregroundStyle(.secondary)
        } else {
            Menu {
                Picker("Used In", selection: Binding(get: { term.approved }, set: change)) {
                    Text("All conversations").tag(true)
                    Text(scope ?? "No conversations").tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 3) {
                    if term.approved {
                        Text("All conversations").foregroundStyle(.secondary)
                    } else if let scope {
                        Text(scope).foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("No conversations")
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(Ink.warning)
                    }
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
            .help(term.approved ? "All conversations" : scope ?? "Not used in any conversation. Choose All Conversations to use it everywhere.")
            .accessibilityLabel("Used In")
        }
    }
}

#if DEBUG
/// Debug-only: `--vocabulary-demo` fills an empty vocabulary with a few terms, one of them suggested from a conversation
/// and one from a conversation that's gone, for screenshots. Only with `--library`, whose library it writes to.
@MainActor
enum VocabularyDemo {
    static func apply(to state: AppState) {
        guard LaunchOptions.libraryURL != nil, CommandLine.arguments.contains("--vocabulary-demo"), state.glossary.isEmpty else { return }
        let meeting = state.meetings.first?.id ?? state.newMeeting(title: "Weekly product sync with the design and research teams", selecting: false)
        [GlossaryTerm(term: "Daybook", definition: "The app", approved: true),
         GlossaryTerm(term: "Soundcore Work", definition: "The recorder clipped to a lapel", approved: true),
         GlossaryTerm(term: "Parakeet", aliases: ["Parakeet Ultra"], definition: "", approved: true),
         GlossaryTerm(term: "Kubernetes", definition: "Container orchestration; also k8s", approved: false, sourceMeetingIDs: [meeting]),
         GlossaryTerm(term: "Ximena Oyelaran-Castellanos", definition: "", approved: false, sourceMeetingIDs: [UUID()])]
            .forEach(state.saveGlossaryTerm)
    }
}
#endif
