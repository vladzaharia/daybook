import DaybookCore
import SwiftUI

struct TemplatesView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var draft = SummaryTemplate.builtIns[0]

    private var catalog: [SummaryTemplate] { SummaryTemplate.catalog(templates: state.templates) }
    private var hasChanges: Bool {
        guard let saved = catalog.first(where: { $0.id == draft.id }) else { return true }
        return saved.name != draft.name || saved.kind != draft.kind || saved.instructions != draft.instructions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your note formats").font(.system(size: 25, weight: .medium, design: .serif))
                    Text("Choose the purpose, detail, and shape of your notes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { saveDraft(); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: Binding(get: { selectedID }, set: { choose($0) })) {
                        ForEach(catalog) { template in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.name).font(.callout.weight(.medium))
                                Text(template.isBuiltIn ? template.kind.title : "Custom · \(template.kind.title)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(template.id)
                        }
                    }.listStyle(.sidebar)
                    Divider()
                    HStack {
                        Button { createTemplate() } label: { Label("New", systemImage: "plus") }
                        Spacer()
                        Button { duplicateTemplate() } label: { Image(systemName: "doc.on.doc") }
                            .help("Duplicate this template")
                    }.buttonStyle(.borderless).padding(12)
                }.frame(minWidth: 190, idealWidth: 220, maxWidth: 270)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        TextField("Template name", text: $draft.name)
                            .font(.title2.weight(.semibold)).textFieldStyle(.plain)
                        if hasChanges { Text("Edited").font(.caption).foregroundStyle(.secondary) }
                    }
                    Picker("Conversation type", selection: $draft.kind) {
                        ForEach(MeetingKind.allCases.filter { $0 != .auto }) { kind in Text(kind.title).tag(kind) }
                    }.frame(maxWidth: 300)
                    Text("Describe the purpose, length, tone, and sections you want. Mention which details deserve extra attention.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $draft.instructions)
                        .font(.system(size: 14)).lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary, lineWidth: 1))
                        .accessibilityLabel("Summary template instructions")
                    Text("Choose this format in a conversation, then refresh its summary. Your original notes and transcript stay available.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if draft.isBuiltIn {
                            Button("Reset to original") { resetTemplate() }
                                .disabled(!state.templates.contains(where: { $0.id == draft.id }) && !hasChanges)
                        } else {
                            Button("Remove template", role: .destructive) { removeTemplate() }
                        }
                        Spacer()
                        Button("Save") { saveDraft() }.buttonStyle(.borderedProminent)
                            .disabled(!hasChanges).keyboardShortcut("s", modifiers: .command)
                    }
                }.padding(22).frame(minWidth: 430)
            }
        }
        .frame(minWidth: 700, minHeight: 540)
        .tint(Color(red: 0.22, green: 0.43, blue: 0.38))
        .onAppear { if selectedID == nil { choose(catalog.first?.id) } }
        .onDisappear { saveDraft() }
    }

    private func choose(_ id: String?) {
        if selectedID != nil { saveDraft() }
        selectedID = id
        if let selected = catalog.first(where: { $0.id == id }) { draft = selected }
    }

    private func saveDraft() {
        guard selectedID != nil, hasChanges else { return }
        var saved = draft
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.name.isEmpty { saved.name = "Untitled template" }
        saved.updatedAt = Date()
        state.saveTemplate(saved)
        draft = saved
    }

    private func createTemplate() {
        saveDraft()
        let created = SummaryTemplate(name: "New template", instructions: "Purpose: describe what you want to remember.\nStyle: describe the level of detail and tone.\nSections: list the headings and what belongs in each.")
        state.saveTemplate(created)
        selectedID = created.id; draft = created
    }

    private func duplicateTemplate() {
        saveDraft()
        let duplicate = draft.duplicated()
        state.saveTemplate(duplicate)
        selectedID = duplicate.id; draft = duplicate
    }

    private func resetTemplate() {
        let id = draft.id
        state.removeTemplate(id)
        if let original = SummaryTemplate.builtIns.first(where: { $0.id == id }) { draft = original }
    }

    private func removeTemplate() {
        let id = draft.id
        state.removeTemplate(id)
        selectedID = SummaryTemplate.builtIns[0].id
        draft = SummaryTemplate.resolved(id: selectedID, kind: .general, templates: state.templates)
    }
}
