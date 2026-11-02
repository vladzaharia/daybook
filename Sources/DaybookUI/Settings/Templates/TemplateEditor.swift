import DaybookDesign
import DaybookKit
import SwiftUI

/// One template's editor, opened from Summary Templates on the iPhone: it saves as you type, with no Save
/// button, as the Mac's window does. `route` and `push` open another editor (a copy).
public struct TemplateEditor<Route: Hashable>: View {
    private let library: LibraryController
    private let templateID: SummaryTemplate.ID
    private let route: (SummaryTemplate.ID) -> Route
    private let push: (Route) -> Void
    @State private var draft: SummaryTemplate?
    @State private var deleting: SummaryTemplate?
    @Environment(\.dismiss) private var dismiss

    public init(library: LibraryController, templateID: SummaryTemplate.ID,
                route: @escaping (SummaryTemplate.ID) -> Route, push: @escaping (Route) -> Void) {
        self.library = library
        self.templateID = templateID
        self.route = route
        self.push = push
    }

    private var templates: TemplateLibrary { TemplateLibrary(library: library) }

    public var body: some View {
        Group {
            if let draft, templates.template(templateID) != nil {
                TemplateForm(draft: Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }),
                             focusesName: draft.name.isEmpty && draft.instructions.isEmpty && !draft.isBuiltIn,
                             restore: { template in self.draft = templates.restore(template) },
                             duplicate: { template in
                                 templates.save(template)
                                 push(route(templates.duplicate(template).id))
                             },
                             delete: { deleting = $0 })
                    .navigationTitle(draft.displayName)
            } else if draft == nil, templates.template(templateID) != nil {
                Color.clear
            } else {
                ContentUnavailableView(TemplateWords.removed, systemImage: "doc.text")
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { if draft == nil { draft = templates.draft(templateID) } }
        .savingAsYouType(draft, to: templates)
        .confirmingTemplateDeletion($deleting) { template in
            draft = nil
            templates.delete(template)
            dismiss()
        }
    }
}

extension TemplateEditor where Route == SummaryTemplate.ID {
    public init(library: LibraryController, templateID: SummaryTemplate.ID) {
        self.init(library: library, templateID: templateID, route: { $0 }, push: { _ in })
    }
}

/// The fields of a template, bound to its draft: Name, Used for, and Instructions, then Edited with Restore
/// Original. The Mac lays them out as a form with a label column; the iPhone as grouped sections, with
/// Duplicate and Delete Template… under them (the Mac's are in its toolbar and the list's menu).
struct TemplateForm: View {
    @Binding var draft: SummaryTemplate
    var focusesName = false
    var restore: (SummaryTemplate) -> Void
    var duplicate: ((SummaryTemplate) -> Void)?
    var delete: ((SummaryTemplate) -> Void)?

    @FocusState private var nameFocused: Bool
    @FocusState private var instructionsFocused: Bool

    var body: some View {
        content
            .task {
                guard focusesName else { return }
                // After the editor is on screen, or the focus has nowhere to go.
                try? await Task.sleep(for: .milliseconds(50))
                nameFocused = true
            }
    }

    // MARK: The iPhone

    #if os(iOS)
    private var content: some View {
        Form {
            Section(TemplateWords.name.asSettingsLabel) {
                TextField(TemplateWords.name, text: $draft.name, prompt: Text(TemplateWords.untitled))
                    .focused($nameFocused)
            }
            Section {
                Picker(TemplateWords.usedFor.asSettingsLabel, selection: $draft.kind) {
                    ForEach(MeetingKind.templateKinds) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(TemplateWords.usedForHelp)
            }
            Section {
                TextEditor(text: $draft.instructions)
                    .font(.callout)
                    .frame(minHeight: 260)
                    // The editor insets its text; line it up with the rows' text.
                    .padding(.horizontal, -5)
                    .focused($instructionsFocused)
                    .accessibilityLabel(TemplateWords.instructions)
            } header: {
                Text(TemplateWords.instructions)
            } footer: {
                Text(TemplateWords.instructionsHelp)
            }
            if draft.isEdited {
                Section {
                    Button(TemplateWords.restoreOriginal) { restore(draft) }
                } footer: {
                    Text(TemplateWords.youEdited)
                }
            }
            if duplicate != nil || (delete != nil && !draft.isBuiltIn) {
                Section {
                    if let duplicate { Button(TemplateWords.duplicate) { duplicate(draft) } }
                    if let delete, !draft.isBuiltIn {
                        Button(TemplateWords.deleteTemplate, role: .destructive) { delete(draft) }
                    }
                }
            }
        }
    }
    #endif

    // MARK: The Mac

    #if os(macOS)
    /// The label column: wide enough for "Instructions", trailing-aligned like a macOS form.
    private static let labelWidth: CGFloat = 84
    /// How far the editor's first line sits below its border.
    private static let editorTextInset: CGFloat = 6

    /// A fixed label column, so the labels share a trailing edge and every field, the editor, and their help share one
    /// leading edge. (Rows of HStacks rather than a `Grid`, which can't give the editor the window's remaining height.)
    private var content: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            row {
                fieldLabel(TemplateWords.name)
                TextField(TemplateWords.name, text: $draft.name, prompt: Text(TemplateWords.untitled))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .focused($nameFocused)
            }
            row {
                fieldLabel(TemplateWords.usedFor)
                VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                    Picker(TemplateWords.usedFor, selection: $draft.kind) {
                        ForEach(MeetingKind.templateKinds) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    helpText(TemplateWords.usedForHelp)
                }
            }
            HStack(alignment: .top, spacing: DaybookSpacing.s3) {
                // Dropped to the editor's first line: its 6 pt inset plus the text view's own top inset.
                fieldLabel(TemplateWords.instructions).padding(.top, Self.editorTextInset)
                VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                    TextEditor(text: $draft.instructions)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .focused($instructionsFocused)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color(nsColor: .textBackgroundColor), in: DaybookRadius.shape(DaybookRadius.row))
                        .overlay {
                            DaybookRadius.shape(DaybookRadius.row)
                                .strokeBorder(instructionsFocused ? AnyShapeStyle(DaybookPalette.accent) : AnyShapeStyle(Color(nsColor: .separatorColor)),
                                              lineWidth: instructionsFocused ? 1.5 : 1)
                        }
                        .daybookMotion(DaybookMotion.hover, value: instructionsFocused)
                        .frame(minHeight: 240, maxHeight: .infinity)
                        .accessibilityLabel(TemplateWords.instructions)
                    helpText(TemplateWords.instructionsHelp)
                }
            }
            .padding(.top, DaybookSpacing.s1)
            if draft.isEdited {
                row {
                    Color.clear.frame(width: Self.labelWidth, height: 1)
                    HStack(alignment: .firstTextBaseline) {
                        Text(TemplateWords.youEdited).foregroundStyle(.secondary)
                        Spacer()
                        Button(TemplateWords.restoreOriginal) { restore(draft) }
                    }
                }
            }
        }
        .padding(DaybookSpacing.s5)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s3, content: content)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).frame(width: Self.labelWidth, alignment: .trailing)
    }

    /// Help under a field. Not `fixedSize`: the window's minimum size is measured at zero width, where a
    /// fixed-height paragraph would be one word per line and thousands of points tall.
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .layoutPriority(1)
    }
    #endif
}
