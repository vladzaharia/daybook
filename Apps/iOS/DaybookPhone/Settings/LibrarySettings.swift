import DaybookKit
import DaybookUI
import SwiftUI

// Summary Templates and Vocabulary are DaybookUI's screens, the Mac's windows as Settings screens. They edit
// through `LibraryController`, so they sync like any library setting and both apps use them when they
// transcribe and summarize.

/// Summary Templates: each row pushes its template's editor (`SettingsRoute.template`), and New Template
/// pushes a new one's.
struct TemplatesPage: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.settingsPush) private var push

    var body: some View {
        TemplatesScreen(library: model.library.controller, route: SettingsRoute.template, push: push.callAsFunction)
    }
}

/// One template's editor, which saves as you type.
struct TemplateEditorPage: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.settingsPush) private var push
    let templateID: String

    var body: some View {
        TemplateEditor(library: model.library.controller, templateID: templateID, route: SettingsRoute.template, push: push.callAsFunction)
    }
}

/// Vocabulary: a term's form is a sheet in the hand and, open, a card on the right page (`pageSheet`).
struct VocabularyPage: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var editing: TermEditing?

    var body: some View {
        let library = model.library.controller
        VocabularyScreen(library: library, editing: $editing)
            .pageSheet(item: $editing) { editing in
                NavigationStack { TermForm(library: library, editing: editing) }
            }
            .task {
                // `--open-settings add-term` (debug), for screenshots: Add Term showing.
                guard model.options.openSettings == "add-term", editing == nil else { return }
                try? await Task.sleep(for: .milliseconds(800))
                editing = .adding()
            }
    }
}
