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

    /// A template as its editor starts, with the library's copy it was taken from.
    public func draft(_ id: SummaryTemplate.ID) -> TemplateDraft? { template(id).map(TemplateDraft.init) }

    /// Saves what the person changed in an editor's draft onto the library's copy as it is now, and catches the
    /// draft up with what was saved. Only the fields they changed are written, so a draft they haven't touched
    /// writes (and syncs) nothing, and an edit synced from another device while the editor was open isn't
    /// reverted. A blank name is saved as "Untitled Template". A template deleted meanwhile (here or on another
    /// device) isn't brought back.
    @discardableResult
    public func save(_ draft: inout TemplateDraft) -> Bool {
        guard let current = template(draft.id) else { return false }
        let value = draft.applied(to: current)
        guard value.differs(from: current) else { return false }
        library.saveTemplate(value)
        draft.catchUp(to: template(draft.id) ?? value)
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

/// An editor's copy of a template, and the library's copy it was taken from (its base): what the person changed
/// is where the two differ. Saving writes only that, and a change that comes from sync shows up in the rest.
public struct TemplateDraft: Equatable {
    /// The template as the editor shows it: a new one's name is empty, with "Untitled Template" as the prompt,
    /// so typing names it.
    public var template: SummaryTemplate
    /// The library's copy when the draft was taken, or when it last caught up with the library.
    public private(set) var base: SummaryTemplate

    public init(_ saved: SummaryTemplate) {
        template = Self.editing(saved)
        base = saved
    }

    public var id: SummaryTemplate.ID { template.id }

    /// Whether the person changed the name since the base: it differs from the name the editor started with, so
    /// a template saved without a name (shown as "Untitled Template") isn't renamed by being opened.
    private var renamed: Bool { template.name != Self.editing(base).name }

    /// `current` with what the person changed since the base, and nothing else.
    func applied(to current: SummaryTemplate) -> SummaryTemplate {
        var value = current
        if renamed { value.name = template.displayName }
        if template.kind != base.kind { value.kind = template.kind }
        if template.instructions != base.instructions { value.instructions = template.instructions }
        return value
    }

    /// Takes in the library's copy as it is now: what the person hasn't changed follows it, and what they have
    /// stays as typed. Returns whether the draft changed.
    @discardableResult
    public mutating func catchUp(to current: SummaryTemplate) -> Bool {
        guard current.id == id, current != base else { return false }
        var caught = Self.editing(current)
        if renamed { caught.name = template.name }
        if template.kind != base.kind { caught.kind = template.kind }
        if template.instructions != base.instructions { caught.instructions = template.instructions }
        template = caught
        base = current
        return true
    }

    private static func editing(_ saved: SummaryTemplate) -> SummaryTemplate {
        var template = saved
        if !template.isBuiltIn, template.name == TemplateWords.untitled { template.name = "" }
        return template
    }
}

extension View {
    /// Saves an editor's draft 500 ms after the last change, and when the editor goes away, so there's no
    /// Save button on either app. Meanwhile the draft follows the library, so an edit synced from another
    /// device shows in the editor wherever the person hasn't typed.
    func savingAsYouType(_ draft: Binding<TemplateDraft?>, to templates: TemplateLibrary) -> some View {
        onChange(of: draft.wrappedValue.flatMap { templates.template($0.id) }) { _, current in
            if let current, var caught = draft.wrappedValue, caught.catchUp(to: current) { draft.wrappedValue = caught }
        }
        .task(id: draft.wrappedValue) {
            guard draft.wrappedValue != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, var saving = draft.wrappedValue else { return }
            if templates.save(&saving) { draft.wrappedValue = saving }
        }
        .onDisappear { if var saving = draft.wrappedValue { templates.save(&saving) } }
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
