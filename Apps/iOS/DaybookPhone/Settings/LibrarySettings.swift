import DaybookKit
import SwiftUI

// MARK: Templates

/// Summary Templates: the built-in formats and your own, edited through `LibraryController`, so
/// they sync like any library setting and the Mac summarizes with them.
struct TemplatesScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var newTemplate: SummaryTemplate?

    var body: some View {
        let controller = model.library.controller
        let _ = model.library.revision
        let edited = Set(controller.metadata.templates.compactMap(\.value).map(\.id))
        List {
            Section {
                ForEach(controller.templates) { template in
                    NavigationLink(value: SettingsRoute.template(template.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(template.name).foregroundStyle(PhoneStyle.Ink.title)
                                if template.isBuiltIn, edited.contains(template.id) {
                                    // A fact about it, not an action: neutral, not the accent.
                                    Text("Edited")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(PhoneStyle.quietFill, in: Capsule())
                                        .foregroundStyle(PhoneStyle.Ink.secondary)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            Text(Self.purpose(template)).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                    .swipeActions {
                        if !template.isBuiltIn {
                            Button(role: .destructive) { controller.removeTemplate(template.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("Summary Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newTemplate = SummaryTemplate(name: "", kind: .general, instructions: "")
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("New Template")
            }
        }
        .pageSheet(item: $newTemplate) { template in
            NavigationStack { TemplateForm(template: template, isNew: true) }
        }
    }

    /// The first line of the instructions, which states the template's purpose.
    static func purpose(_ template: SummaryTemplate) -> String {
        let first = template.instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let purpose = first.hasPrefix("Purpose: ") ? String(first.dropFirst("Purpose: ".count)) : first
        return purpose.prefix(1).uppercased() + purpose.dropFirst()
    }
}

/// One template, opened from the list.
struct TemplateEditor: View {
    @Environment(PhoneAppModel.self) private var model
    let templateID: String

    var body: some View {
        if let template = model.library.controller.templates.first(where: { $0.id == templateID }) {
            TemplateForm(template: template, isNew: false)
        } else {
            ContentUnavailableView("Template Removed", systemImage: "doc.text")
        }
    }
}

private struct TemplateForm: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SummaryTemplate
    let isNew: Bool
    private let original: SummaryTemplate

    init(template: SummaryTemplate, isNew: Bool) {
        _draft = State(initialValue: template)
        original = template
        self.isNew = isNew
    }

    var body: some View {
        let controller = model.library.controller
        let builtIn = SummaryTemplate.builtIns.first { $0.id == draft.id }
        Form {
            Section("Name") {
                TextField("Template name", text: $draft.name)
            }
            Section {
                Picker("Used For", selection: $draft.kind) {
                    ForEach(MeetingKind.allCases.filter { $0 != .auto }) { Text($0.title).tag($0) }
                }
            }
            Section {
                TextEditor(text: $draft.instructions)
                    .font(.callout)
                    .frame(minHeight: 260)
                    // The editor insets its text; line it up with the rows' text.
                    .padding(.horizontal, -5)
            } header: {
                Text("Instructions")
            } footer: {
                Text("Start with the purpose, then the sections to use.")
            }
            if !isNew {
                Section {
                    Button("Duplicate") {
                        controller.saveTemplate(draft.duplicated())
                        dismiss()
                    }
                    if let builtIn, builtIn != draft || controller.metadata.templates.contains(where: { $0.id == draft.id && $0.value != nil }) {
                        Button("Restore Original") {
                            controller.removeTemplate(draft.id)
                            draft = builtIn
                        }
                    }
                    if builtIn == nil {
                        Button("Delete Template", role: .destructive) {
                            controller.removeTemplate(draft.id)
                            dismiss()
                        }
                    }
                }
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle(isNew ? "New Template" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    controller.saveTemplate(draft)
                    dismiss()
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (!isNew && draft == original))
            }
        }
    }
}

// MARK: Vocabulary

/// Vocabulary: names and terms the Mac should spell your way when it transcribes, through
/// `LibraryController`'s glossary, which syncs as library metadata.
struct VocabularyScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var editing: GlossaryTerm?
    @State private var search = ""

    var body: some View {
        let controller = model.library.controller
        let _ = model.library.revision
        let terms = controller.glossary.filter { search.isEmpty || $0.term.localizedCaseInsensitiveContains(search)
            || $0.aliases.contains { $0.localizedCaseInsensitiveContains(search) } }
        let approved = terms.filter(\.approved).sorted { $0.term.localizedStandardCompare($1.term) == .orderedAscending }
        let proposed = terms.filter { !$0.approved }.sorted { $0.occurrences > $1.occurrences }
        List {
            if approved.isEmpty && proposed.isEmpty {
                // Add Term is the bar's +, so it isn't offered twice.
                ContentUnavailableView {
                    Label("No Terms Yet", systemImage: "character.book.closed")
                } description: {
                    Text("Add names, products, and words to spell your way.")
                }
                .listRowBackground(Color.clear)
            }
            if !approved.isEmpty {
                Section("Terms") {
                    ForEach(approved) { term in
                        Button { editing = term } label: { TermRow(term: term) }
                            .swipeActions {
                                Button(role: .destructive) { controller.removeGlossaryTerm(term.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
            }
            if !proposed.isEmpty {
                Section {
                    ForEach(proposed) { term in
                        HStack {
                            Button { editing = term } label: { TermRow(term: term) }
                            Spacer()
                            Button("Add") {
                                var value = term
                                value.approved = true
                                value.updatedAt = Date()
                                controller.saveGlossaryTerm(value)
                            }
                            .buttonStyle(.bordered)
                            .tint(PhoneStyle.accent)
                        }
                        .swipeActions {
                            Button(role: .destructive) { controller.removeGlossaryTerm(term.id) } label: { Label("Dismiss", systemImage: "xmark") }
                        }
                    }
                } header: {
                    Text("Suggested")
                }
            }
        }
        // Searching needs something to search.
        .modifier(SearchableWhen(isOn: !controller.glossary.isEmpty, text: $search, prompt: "Search vocabulary"))
        .settingsScrollEnd()
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = GlossaryTerm(term: "", approved: true) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Term")
            }
        }
        .pageSheet(item: $editing) { term in
            NavigationStack { TermForm(term: term) }
        }
        .task {
            // `--open-settings add-term` (debug), for screenshots: Add Term showing.
            guard model.options.openSettings == "add-term", editing == nil else { return }
            try? await Task.sleep(for: .milliseconds(800))
            editing = GlossaryTerm(term: "", approved: true)
        }
    }
}

private struct TermRow: View {
    let term: GlossaryTerm

    var body: some View {
        // Explicit inks: the row is a button's label, and a list tints those (`.primary` would turn teal).
        VStack(alignment: .leading, spacing: 2) {
            Text(term.term).foregroundStyle(PhoneStyle.Ink.title)
            let detail = [term.aliases.isEmpty ? nil : "Also heard as " + term.aliases.joined(separator: ", "),
                          term.definition.isEmpty ? nil : term.definition].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary).lineLimit(2) }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

private struct TermForm: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var term: GlossaryTerm
    @State private var aliases: String
    private let isNew: Bool

    init(term: GlossaryTerm) {
        _term = State(initialValue: term)
        _aliases = State(initialValue: term.aliases.joined(separator: ", "))
        isNew = term.term.isEmpty
    }

    var body: some View {
        Form {
            Section("Term") {
                TextField("Spelled as", text: $term.term)
                    .textInputAutocapitalization(.never)
            }
            Section {
                TextField("Other spellings, separated by commas", text: $aliases)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Also Heard As")
            } footer: {
                Text("Misspellings the transcript might use, such as \u{201C}day book\u{201D} for Daybook.")
            }
            Section("What It Means") {
                TextField("Optional", text: $term.definition, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
        .navigationTitle(isNew ? "Add Term" : "Edit Term")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    term.term = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
                    term.aliases = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    term.approved = true
                    term.updatedAt = Date()
                    model.library.controller.saveGlossaryTerm(term)
                    dismiss()
                }
                .disabled(term.term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// `.searchable` only while there's something to search.
private struct SearchableWhen: ViewModifier {
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
