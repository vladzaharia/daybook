import DaybookDesign
import DaybookKit
import SwiftUI

/// Summary Templates on both apps (docs/templates.md): Built-in in its fixed order and Yours by name, each with
/// its symbol and what it's for, and an editor that saves as you type. On the Mac it's a window, the list
/// beside the editor; on the iPhone (and a page of the open Duo) a list whose rows push the editor.
///
/// `route` is how the iPhone's Settings names a template's editor in its navigation path, and `push` opens one
/// (a new template, a copy); the Mac's window selects instead and needs neither.
public struct TemplatesScreen<Route: Hashable>: View {
    private let library: LibraryController
    private let route: (SummaryTemplate.ID) -> Route
    private let push: (Route) -> Void

    @State private var deleting: SummaryTemplate?
    #if os(macOS)
    @State private var selectedID: SummaryTemplate.ID?
    /// The selected template as it's being edited, so its row shows a new name or Edited as it's typed.
    @State private var draft: SummaryTemplate?
    /// A template just made (New Template, Duplicate), whose name takes the focus.
    @State private var naming: SummaryTemplate.ID?
    #endif

    public init(library: LibraryController, route: @escaping (SummaryTemplate.ID) -> Route, push: @escaping (Route) -> Void) {
        self.library = library
        self.route = route
        self.push = push
    }

    private var templates: TemplateLibrary { TemplateLibrary(library: library) }

    public var body: some View {
        content
            .confirmingTemplateDeletion($deleting) { template in delete(template) }
            #if DEBUG
            .task(id: library.isLoaded) { TemplatesDemo.apply(to: library) }
            #endif
    }

    // MARK: Compact: the iPhone

    #if os(iOS)
    private var content: some View {
        let sections = templates.sections
        return List {
            Section(TemplateWords.builtIn) {
                ForEach(sections.builtIn) { template in
                    NavigationLink(value: route(template.id)) { TemplateRow(template: template) }
                        .contextMenu { menu(for: template) }
                }
            }
            if !sections.yours.isEmpty {
                Section(TemplateWords.yours) {
                    ForEach(sections.yours) { template in
                        NavigationLink(value: route(template.id)) { TemplateRow(template: template) }
                            .contextMenu { menu(for: template) }
                            .swipeActions {
                                // The same confirmation as Delete Template…, never a delete in one gesture.
                                Button(TemplateWords.delete, systemImage: "trash") { deleting = template }
                                    .tint(DaybookPalette.Ink.error)
                            }
                    }
                }
            }
        }
        .navigationTitle(TemplateWords.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { push(route(templates.newTemplate().id)) } label: { Image(systemName: "plus") }
                    .accessibilityLabel(TemplateWords.newTemplate)
            }
        }
    }

    @ViewBuilder private func menu(for template: SummaryTemplate) -> some View {
        Button(TemplateWords.duplicate, systemImage: "plus.square.on.square") { push(route(templates.duplicate(template).id)) }
        if template.isEdited {
            Button(TemplateWords.restoreOriginal, systemImage: "arrow.uturn.backward") { templates.restore(template) }
        }
        if !template.isBuiltIn {
            Button(TemplateWords.deleteTemplate, systemImage: "trash", role: .destructive) { deleting = template }
        }
    }

    private func delete(_ template: SummaryTemplate) { templates.delete(template) }
    #endif

    // MARK: Wide: the Mac's window

    #if os(macOS)
    private var content: some View {
        NavigationSplitView {
            let sections = templates.sections
            List(selection: $selectedID) {
                Section(TemplateWords.builtIn) { ForEach(sections.builtIn) { row($0) } }
                if !sections.yours.isEmpty { Section(TemplateWords.yours) { ForEach(sections.yours) { row($0) } } }
            }
            .contextMenu(forSelectionType: SummaryTemplate.ID.self) { ids in
                if ids.count == 1, let id = ids.first, let template = templates.template(id) { menu(for: shown(template)) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { select(templates.newTemplate().id, naming: true) } label: {
                            Label(TemplateWords.newTemplate, systemImage: "plus")
                        }
                        .help(TemplateWords.newTemplate)
                        moreMenu
                    }
                }
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { if selectedID == nil { selectedID = templates.sections.builtIn.first?.id } }
        .onChange(of: selectedID, initial: true) { old, new in
            if let draft, draft.id == old { templates.save(draft) }
            draft = new.flatMap(templates.draft)
        }
        .savingAsYouType(draft, to: templates)
    }

    private func row(_ template: SummaryTemplate) -> some View {
        TemplateRow(template: shown(template)).tag(template.id)
    }

    /// A row's template, or the draft while it's the one being edited.
    private func shown(_ template: SummaryTemplate) -> SummaryTemplate {
        guard let draft, draft.id == template.id else { return template }
        return draft
    }

    @ViewBuilder private var detail: some View {
        if let draft, templates.template(draft.id) != nil {
            TemplateForm(draft: Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }),
                         focusesName: naming == draft.id, restore: { restore($0) })
                .id(draft.id)
        } else {
            ContentUnavailableView(TemplateWords.noneSelected, systemImage: "doc.text")
        }
    }

    @ViewBuilder private func menu(for template: SummaryTemplate) -> some View {
        Button(TemplateWords.duplicate) { duplicate(template) }
        if template.isEdited || !template.isBuiltIn { Divider() }
        if template.isEdited { Button(TemplateWords.restoreOriginal) { restore(template) } }
        if !template.isBuiltIn { Button(TemplateWords.deleteTemplate) { deleting = template } }
    }

    private var moreMenu: some View {
        Menu {
            Button(TemplateWords.duplicate) { if let draft { duplicate(draft) } }
                .disabled(draft == nil)
            Divider()
            Button(TemplateWords.restoreOriginal) { if let draft { restore(draft) } }
                .disabled(draft?.isEdited != true)
            Button(TemplateWords.deleteTemplate) { deleting = draft }
                .disabled(draft?.isBuiltIn != false)
        } label: {
            Label(TemplateWords.more, systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help(TemplateWords.more)
    }

    private func duplicate(_ template: SummaryTemplate) {
        if let draft { templates.save(draft) }
        select(templates.duplicate(template).id, naming: true)
    }

    private func restore(_ template: SummaryTemplate) {
        let original = templates.restore(template)
        if draft?.id == template.id { draft = original }
    }

    private func delete(_ template: SummaryTemplate) {
        if draft?.id == template.id { draft = nil }
        templates.delete(template)
        if selectedID == template.id { selectedID = templates.sections.builtIn.first?.id }
    }

    private func select(_ id: SummaryTemplate.ID, naming: Bool) {
        self.naming = naming ? id : nil
        selectedID = id
    }
    #endif
}

extension TemplatesScreen where Route == SummaryTemplate.ID {
    /// The Mac's window, which selects a template rather than pushing its editor.
    public init(library: LibraryController) {
        self.init(library: library, route: { $0 }, push: { _ in })
    }
}

/// One template in the list: its symbol, its name with Edited when a built-in was changed, and what it's for.
struct TemplateRow: View {
    let template: SummaryTemplate
    @Environment(\.daybookDensity) private var density

    var body: some View {
        let edited = template.isEdited
        Group {
            if density == .touch {
                HStack(spacing: SettingsMetrics.gap) {
                    SettingsTile(systemImage: template.systemImage)
                    words(edited: edited)
                }
            } else {
                // The sidebar colours the symbol and the words, and turns them white when the row is selected.
                Label {
                    words(edited: edited)
                } icon: {
                    // Fitted to one box, so wide symbols (three people) keep the names in a column.
                    Image(systemName: template.systemImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 15)
                }
                .labelStyle(SidebarRowLabelStyle())
            }
        }
        .daybookMotion(DaybookMotion.state, value: edited)
        .accessibilityElement(children: .combine)
    }

    private func words(edited: Bool) -> some View {
        let touch = density == .touch
        return VStack(alignment: .leading, spacing: touch ? 3 : 1) {
            HStack(spacing: touch ? 8 : 6) {
                Text(template.displayName)
                    .foregroundStyle(touch ? AnyShapeStyle(DaybookPalette.Ink.title) : AnyShapeStyle(.primary))
                    .lineLimit(touch ? 2 : 1)
                if edited {
                    EditedMark()
                        .daybookTransition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            let purpose = template.purpose
            if !purpose.isEmpty {
                Text(purpose)
                    .font(touch ? .footnote : .system(size: 11))
                    .foregroundStyle(touch ? AnyShapeStyle(DaybookPalette.Ink.secondary) : AnyShapeStyle(.secondary))
                    .lineLimit(touch ? 2 : 1)
            }
        }
        .padding(.vertical, touch ? 2 : 1)
    }
}

/// The symbol in a column of its own, beside the words, as the Mac's sidebars draw their rows (the system's own
/// sidebar label sets a selected row's words in semibold, which a two-line row doesn't want).
private struct SidebarRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.frame(width: 20, alignment: .center)
            configuration.title
        }
    }
}

/// "Edited": a fact about a built-in, not an action, so neutral. In the Mac's sidebar it keeps the system's
/// colours, which turn with the row's selection.
struct EditedMark: View {
    @Environment(\.daybookDensity) private var density

    var body: some View {
        if density == .touch {
            DaybookChip(TemplateWords.edited, kind: .fact)
        } else {
            Text(TemplateWords.edited)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: DaybookRadius.chip)
                .fixedSize()
        }
    }
}
