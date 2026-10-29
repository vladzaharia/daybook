import DaybookIntelligence
import DaybookKit
import SwiftUI

/// The transcription language rows in Settings › Models, placed under the transcription model:
/// the language, and the model for languages the selected one doesn't cover. Speech routing fills
/// them in; the model manager places them.
struct TranscriptionLanguageSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Picker("Language", selection: language) {
            Text("Automatic").tag("")
            Divider()
            ForEach(languages, id: \.self) { code in
                Text(TranscriptionLanguages.name(code)).tag(code)
            }
        }
        if showsOtherLanguages, let other = otherLanguagesModel {
            // Laid out like the model rows above: what to do, then the pop-up; its state under the label.
            LabeledContent {
                HStack(spacing: Space.s2) {
                    action(other)
                    Picker("Other languages", selection: otherLanguages) {
                        ForEach(otherChoices) { model in Text(model.name).tag(model.key) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } label: {
                Text("Other languages")
                ActivityReader(download: state.downloadActivity) {
                    if let line = statusLine(other) { Text(line).monospacedDigit() }
                }
            }
        }
    }

    // MARK: Language

    private var catalog: ModelCatalog { state.modelCatalog }
    private var selectedLanguages: [String]? { catalog.model(state.transcriptionModel)?.capabilities.languages }

    /// Every language a transcription model here covers, plus the stored choice.
    private var languages: [String] {
        var codes = TranscriptionLanguages.choices(in: catalog, engines: state.runtime.engines)
        if let stored = state.processingPreferences.transcriptionLanguage, !codes.contains(stored) { codes.append(stored) }
        return codes
    }

    private var language: Binding<String> {
        Binding(get: { state.processingPreferences.transcriptionLanguage ?? "" },
                set: { state.processingPreferences.transcriptionLanguage = $0.isEmpty ? nil : $0 })
    }

    // MARK: Other languages

    /// Shown when some speech can go to another model: Automatic with a model that covers only some
    /// languages, or a chosen language the selected model doesn't cover.
    private var showsOtherLanguages: Bool {
        guard !TranscriptionLanguages.coversEverything(selectedLanguages) else { return false }
        guard let chosen = state.processingPreferences.transcriptionLanguage else { return true }
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

    /// Silent when the model is here, as on the model rows.
    private func statusLine(_ key: String) -> String? {
        if state.downloadingID == key {
            return "Downloading · \(Int((min(max(state.downloadProgress.fraction, 0), 1) * 100).rounded(.down)))%"
        }
        if state.pendingDownloads.contains(key) { return "Waiting to download" }
        guard !state.installedModels.contains(key) else { return nil }
        return "Not downloaded · \(ModelSize.format(catalog.model(key)?.approximateBytes ?? 0))"
    }

    @ViewBuilder private func action(_ key: String) -> some View {
        if state.downloadingID == key {
            Button("Cancel") { state.cancelDownload() }
        } else if state.pendingDownloads.contains(key) {
            Button("Cancel") { state.removePendingDownload(key) }
        } else if !state.installedModels.contains(key) {
            Button("Download") { state.downloadModels([key]) }
                .disabled(state.processingID != nil)
        }
    }
}
