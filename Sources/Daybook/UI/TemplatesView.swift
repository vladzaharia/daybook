import DaybookCore
import SwiftUI

/// Summary Templates (Direction A §5.16): the built-in templates in a fixed order, the person's
/// own, and an editor that saves as they type.
struct TemplatesView: View {
    @ObservedObject var state: AppState
    @State private var selectedID: String?
    @State private var draft: SummaryTemplate?
    @State private var deleting: SummaryTemplate?
    @FocusState private var nameFocused: Bool
    @FocusState private var instructionsFocused: Bool

    private var builtIns: [SummaryTemplate] { state.templates.filter(\.isBuiltIn) }
    private var yours: [SummaryTemplate] {
        state.templates.filter { !$0.isBuiltIn }.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
    }
    private static let kinds = MeetingKind.allCases.filter { $0 != .auto }
    /// The label column: wide enough for "Instructions", trailing-aligned like a macOS form.
    private static let labelWidth: CGFloat = 84

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("Built-in") { ForEach(builtIns) { row($0) } }
                if !yours.isEmpty { Section("Yours") { ForEach(yours) { row($0) } } }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, ids.count == 1, let template = state.templates.first(where: { $0.id == id }) {
                    Button("Duplicate") { duplicate(template) }
                    if isEdited(template) || !template.isBuiltIn { Divider() }
                    if isEdited(template) { Button("Restore Original") { restore(template) } }
                    if !template.isBuiltIn { Button("Delete Template…") { deleting = template } }
                }
            }
            .labelStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: newTemplate) { Label("New Template", systemImage: "plus") }
                            .help("New Template")
                        moreMenu
                    }
                }
        }
        .frame(minWidth: 640, minHeight: 440)
        #if DEBUG
        .task { TemplatesDemo.apply(to: state) }
        #endif
        .onAppear { if selectedID == nil { selectedID = builtIns.first?.id } }
        .onChange(of: selectedID, initial: true) { old, new in
            if let draft, draft.id == old { save(draft) }
            draft = state.templates.first { $0.id == new }
        }
        .task(id: draft) {
            guard let draft else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save(draft)
        }
        .onDisappear { if let draft { save(draft) } }
        .alert("Delete “\(deleting.map(displayName) ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { template in
            Button("Delete", role: .destructive) { delete(template) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Conversations that used it switch to Automatic.")
        }
    }

    private func row(_ template: SummaryTemplate) -> some View {
        let shown = template.id == draft?.id ? draft ?? template : template
        return Label {
            HStack {
                Text(displayName(shown)).lineLimit(1)
                Spacer(minLength: Space.s2)
                if isEdited(shown) {
                    Text("Edited")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        } icon: {
            // Fitted to one box so wide symbols (three people) keep the titles in a column.
            Image(systemName: shown.systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 15)
        }
        .motion(Motion.state, value: isEdited(shown))
        .tag(template.id)
    }

    @ViewBuilder private var detail: some View {
        if let draft {
            editor(draft)
        } else {
            ContentUnavailableView("No Template Selected", systemImage: "doc.text")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Duplicate") { if let draft { duplicate(draft) } }
                .disabled(draft == nil)
            Divider()
            Button("Restore Original") { if let draft { restore(draft) } }
                .disabled(draft.map(isEdited) != true)
            Button("Delete Template…") { deleting = draft }
                .disabled(draft?.isBuiltIn != false)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
    }

    // MARK: Editor

    /// §4.16: a fixed label column, so the labels share a trailing edge and every field, the editor,
    /// and their help share one leading edge. (Rows of HStacks rather than a `Grid`, which can't give
    /// the editor the window's remaining height.)
    private func editor(_ template: SummaryTemplate) -> some View {
        let binding = Binding(get: { draft ?? template }, set: { draft = $0 })
        return VStack(alignment: .leading, spacing: Space.s3) {
            row {
                fieldLabel("Name")
                TextField("Name", text: binding.name, prompt: Text("Untitled Template"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .focused($nameFocused)
            }
            row {
                fieldLabel("Used for")
                VStack(alignment: .leading, spacing: Space.s2) {
                    Picker("Used for", selection: binding.kind) {
                        ForEach(Self.kinds) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    helpText("Chosen automatically for this kind of conversation.")
                }
            }
            HStack(alignment: .top, spacing: Space.s3) {
                // Dropped to the editor's first line: its 6 pt inset plus the text view's own top inset.
                fieldLabel("Instructions").padding(.top, Self.editorTextInset)
                VStack(alignment: .leading, spacing: Space.s2) {
                    TextEditor(text: binding.instructions)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .focused($instructionsFocused)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(instructionsFocused ? AnyShapeStyle(DaybookStyle.accent) : AnyShapeStyle(Color(nsColor: .separatorColor)),
                                              lineWidth: instructionsFocused ? 1.5 : 1)
                        }
                        .motion(Motion.hover, value: instructionsFocused)
                        .frame(minHeight: 240, maxHeight: .infinity)
                        .accessibilityLabel("Instructions")
                    helpText("Describe the purpose, the sections you want, and the tone.")
                }
            }
            .padding(.top, Space.s1)
            if isEdited(draft ?? template) {
                row {
                    Color.clear.frame(width: Self.labelWidth, height: 1)
                    HStack(alignment: .firstTextBaseline) {
                        Text("You edited this template.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Original") { restore(draft ?? template) }
                    }
                }
            }
        }
        .padding(Space.s5)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    /// How far the editor's first line sits below its border.
    private static let editorTextInset: CGFloat = 6

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3, content: content)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).frame(width: Self.labelWidth, alignment: .trailing)
    }

    /// Help under a field. Not `fixedSize`: the window's minimum size is measured at zero width,
    /// where a fixed-height paragraph would be one word per line and thousands of points tall.
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .layoutPriority(1)
    }

    // MARK: Actions

    private func displayName(_ template: SummaryTemplate) -> String {
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Template" : name
    }

    /// A built-in whose name, kind, or instructions differ from the original.
    private func isEdited(_ template: SummaryTemplate) -> Bool {
        guard let original = SummaryTemplate.builtIns.first(where: { $0.id == template.id }) else { return false }
        return original.name != template.name || original.kind != template.kind || original.instructions != template.instructions
    }

    /// Saves the draft when it differs from the library's copy. Saving is automatic, so there is no Save button.
    private func save(_ template: SummaryTemplate) {
        var value = template
        value.name = displayName(template)
        guard let saved = state.templates.first(where: { $0.id == value.id }) else { return }
        guard saved.name != value.name || saved.kind != value.kind || saved.instructions != value.instructions else { return }
        state.saveTemplate(value)
    }

    private func newTemplate() {
        let template = SummaryTemplate(name: "Untitled Template", instructions: "")
        state.saveTemplate(template)
        select(template.id, focusName: true)
    }

    private func duplicate(_ template: SummaryTemplate) {
        if let draft { save(draft) }
        var source = template
        source.name = displayName(template)
        let copy = source.duplicated()
        state.saveTemplate(copy)
        select(copy.id, focusName: true)
    }

    private func restore(_ template: SummaryTemplate) {
        state.removeTemplate(template.id)
        if draft?.id == template.id { draft = state.templates.first { $0.id == template.id } }
    }

    private func delete(_ template: SummaryTemplate) {
        if draft?.id == template.id { draft = nil }
        state.removeTemplate(template.id)
        if selectedID == template.id { selectedID = builtIns.first?.id }
    }

    private func select(_ id: String, focusName: Bool) {
        selectedID = id
        guard focusName else { return }
        Task { @MainActor in nameFocused = true }
    }
}

#if DEBUG
/// Debug-only: `--templates-demo` adds templates of your own (one with a long name) and edits a built-in, for
/// screenshots. Only with `--library`, whose library it writes to.
@MainActor
enum TemplatesDemo {
    static func apply(to state: AppState) {
        guard LaunchOptions.libraryURL != nil, CommandLine.arguments.contains("--templates-demo"),
              state.templates.allSatisfy(\.isBuiltIn) else { return }
        state.saveTemplate(SummaryTemplate(name: "Board update", kind: .general, instructions: "Lead with the numbers, then risks and asks."))
        state.saveTemplate(SummaryTemplate(name: "Quarterly customer advisory council debrief and follow-ups", kind: .interview,
                                           instructions: "Group feedback by theme. Quote customers where they're specific."))
        state.saveTemplate(SummaryTemplate(name: "", kind: .general, instructions: ""))
        if var edited = state.templates.first(where: \.isBuiltIn) {
            edited.instructions += " Keep it under a page."
            state.saveTemplate(edited)
        }
    }
}
#endif
