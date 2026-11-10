import DaybookIntelligence
import DaybookKit
import DaybookUI
import SwiftUI

/// Settings › Models › Transcription's Other languages row, under the library's language (DaybookUI's
/// `TranscriptionLanguageSettings`): the model for languages the selected one doesn't cover. It's this Mac's
/// (`ProcessingPreferences.otherLanguagesModelID`), because it names a model this Mac downloads. Speech routing fills it
/// in; the model manager places it.
struct OtherLanguagesSetting: View {
    let state: AppState
    let manager: ModelManager

    var body: some View {
        if showsOtherLanguages, let other = otherLanguagesModel {
            // A model row like the ones above (DaybookUI's): its state under the label, what to do, then the pop-up.
            ActivityReader {
                let snapshot = manager.snapshot
                ModelRoleRow(label: "Other languages",
                             choice: snapshot.choice(for: .transcription, selection: other, among: otherChoices),
                             space: snapshot.space, pickerTitle: "Other languages model",
                             actions: ModelRowActions(select: { otherLanguages.wrappedValue = $0 },
                                                      download: { manager.download($0) }, cancel: { manager.cancel($0) }))
            }
        }
    }

    private var catalog: ModelCatalog { state.modelCatalog }
    private var selectedLanguages: [String]? { catalog.model(state.transcriptionModel)?.capabilities.languages }

    /// Shown when some speech can go to another model: Automatic with a model that covers only some
    /// languages, or a chosen language the selected model doesn't cover.
    private var showsOtherLanguages: Bool {
        guard !TranscriptionLanguages.coversEverything(selectedLanguages) else { return false }
        guard let chosen = state.transcriptionLanguage else { return true }
        return !TranscriptionLanguages.covers(selectedLanguages, chosen)
    }

    private var otherLanguagesModel: String? {
        TranscriptionRouting.otherLanguagesModel(selected: state.transcriptionModel, chosen: state.processingPreferences.otherLanguagesModelID,
                                                 catalog: catalog, engines: state.runtime.engines, installed: state.installedModels)
    }

    /// Transcription models this Mac can run that cover languages the selected one doesn't.
    private var otherChoices: [CatalogModel] {
        catalog.models(for: .transcription).filter { model in
            model.key != catalog.model(state.transcriptionModel)?.key
                && model.availability(engines: state.runtime.engines).isAvailable
                && TranscriptionRouting.route(selected: state.transcriptionModel, language: nil, otherLanguages: model.key,
                                              catalog: catalog).fallback != nil
        }
    }

    private var otherLanguages: Binding<String> {
        Binding(get: { otherLanguagesModel ?? "" },
                set: { state.processingPreferences.otherLanguagesModelID = $0.isEmpty ? nil : $0 })
    }
}
