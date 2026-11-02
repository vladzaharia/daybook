import DaybookKit
import SwiftUI

/// What Summary Templates does to the library's templates, on both apps: every change goes to
/// `LibraryController`, so it syncs like any library setting.
@MainActor
public struct TemplateLibrary {
    public let library: LibraryController

    public init(library: LibraryController) { self.library = library }

    /// The templates in the lists' order: the built-ins, then yours by name.
    public var sections: (builtIn: [SummaryTemplate], yours: [SummaryTemplate]) { SummaryTemplate.sections(library.templates) }

    public func template(_ id: SummaryTemplate.ID) -> SummaryTemplate? { library.templates.first { $0.id == id } }

    /// A template as its editor starts: a new one's name is empty, with "Untitled Template" as the prompt, so
    /// typing names it.
    public func draft(_ id: SummaryTemplate.ID) -> SummaryTemplate? {
        guard var template = template(id) else { return nil }
        if !template.isBuiltIn, template.name == TemplateWords.untitled { template.name = "" }
        return template
    }

    /// Saves an editor's draft when it says something the library's copy doesn't. A blank name is saved as
    /// "Untitled Template". A template deleted meanwhile (here or on another device) isn't brought back.
    @discardableResult
    public func save(_ draft: SummaryTemplate) -> Bool {
        var value = draft
        value.name = draft.displayName
        guard let saved = template(value.id), saved.differs(from: value) else { return false }
        library.saveTemplate(value)
        return true
    }

    /// New Template: an untitled template of your own, saved at once, so its editor saves as you type.
    @discardableResult
    public func newTemplate() -> SummaryTemplate {
        let template = SummaryTemplate.untitled()
        library.saveTemplate(template)
        return template
    }

    /// A copy of `template` under a new identity, named as the original is shown.
    @discardableResult
    public func duplicate(_ template: SummaryTemplate) -> SummaryTemplate {
        var source = template
        source.name = template.displayName
        let copy = source.duplicated()
        library.saveTemplate(copy)
        return copy
    }

    /// Puts a built-in back as it was bundled; returns the original.
    @discardableResult
    public func restore(_ template: SummaryTemplate) -> SummaryTemplate? {
        library.removeTemplate(template.id)
        return self.template(template.id)
    }

    /// Deletes one of your own. Conversations that used it switch to Automatic (`SummaryTemplate.resolved`).
    public func delete(_ template: SummaryTemplate) {
        guard !template.isBuiltIn else { return }
        library.removeTemplate(template.id)
    }
}

extension View {
    /// Saves an editor's draft 500 ms after the last change, and when the editor goes away, so there's no
    /// Save button on either app.
    func savingAsYouType(_ draft: SummaryTemplate?, to templates: TemplateLibrary) -> some View {
        task(id: draft) {
            guard let draft else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            templates.save(draft)
        }
        .onDisappear { if let draft { templates.save(draft) } }
    }

    /// Delete Template…'s confirmation, the same on both apps: the template's name and what happens to the
    /// conversations that used it.
    func confirmingTemplateDeletion(_ deleting: Binding<SummaryTemplate?>, delete: @escaping (SummaryTemplate) -> Void) -> some View {
        confirmationDialog(deleting.wrappedValue.map(TemplateWords.deleteTitle) ?? "",
                           isPresented: Binding(get: { deleting.wrappedValue != nil }, set: { if !$0 { deleting.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: deleting.wrappedValue) { template in
            Button(TemplateWords.delete, role: .destructive) { delete(template) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text(TemplateWords.deleteConsequence)
        }
    }
}
