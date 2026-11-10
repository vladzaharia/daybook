import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// Settings › Models: the models this iPhone runs, drawn with the Mac's own rows (DaybookUI's model rows and sections)
/// but only what a phone needs. Processing (docs/iphone.md, "Processing on this iPhone"): whether this iPhone
/// transcribes its own recordings and one Download for what that needs; then per role (transcription, speakers,
/// voice profiles, summaries) the model, which is its own menu, with its state and Download or Cancel, and under
/// Transcription the library's language, the Mac's row too (DaybookUI's `TranscriptionLanguageSettings`). Live
/// (docs/iphone.md, "Live transcription"): the same for live captions' models. Model Library: what the models take
/// here, each with Remove. And whether downloads may use cellular data.
struct ModelsSettingsScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var removing: CatalogModel?

    var body: some View {
        let models = model.models
        @Bindable var bindable = models
        @Bindable var settings = model.settings
        Form {
            ModelProcessingSection(toggleTitle: "Transcribe on this iPhone", isOn: $settings.processesOnThisIPhone,
                                   download: models.processingDownload, downloadName: "Transcription and speakers",
                                   space: models.space,
                                   downloadAction: { models.downloadMissing(in: PhoneModels.transcribingRoles) },
                                   cancelAction: { models.cancelDownloads(in: PhoneModels.transcribingRoles) })
            // The voice-profile model comes with the speaker model: it isn't a choice of its own.
            ForEach(models.processingRoles.filter { $0 != .speakerEmbedding }, id: \.self) { role in
                roleSection(role, models: models)
            }
            if let live = models.liveDownload {
                Section {
                    ModelDownloadRow(live, name: "Live captions", space: models.space,
                                     download: { models.downloadMissing(in: models.roles) },
                                     cancel: { models.cancelDownloads(in: models.roles) })
                } header: {
                    Text("Live")
                }
            }
            ForEach(models.roles.filter(\.isLiveOnly), id: \.self) { role in
                roleSection(role, models: models)
            }
            ModelLibrarySection(total: models.bytesOnDisk) {
                ForEach(models.downloadedModels) { downloaded in
                    ModelListRow(name: downloaded.name, labels: ModelLabels.of(downloaded),
                                 detail: [downloaded.maker, ByteSize.format(downloaded.approximateBytes)].compactMap { $0 }.joined(separator: " · "),
                                 status: models.status(of: downloaded)) {
                        Button("Remove", role: .destructive) { removing = downloaded }
                            .buttonStyle(.borderless)
                            .foregroundStyle(DaybookPalette.Ink.error)
                            .fixedSize()
                    }
                }
            }
            Section {
                Toggle("Download over Cellular", isOn: $bindable.allowsCellular)
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .task { await models.refresh() }
        .onChange(of: settings.processesOnThisIPhone) { _, _ in model.processingChanged() }
        .confirmationDialog(removing.map { models.removal(of: $0).title } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { item in
            Button("Remove", role: .destructive) { Task { await models.remove(item) } }
        } message: { item in
            Text(models.removal(of: item).message)
        }
    }

    @ViewBuilder
    private func roleSection(_ role: ModelRole, models: PhoneModels) -> some View {
        if let choice = models.roleChoice(for: role) {
            Section {
                ModelRoleRow(label: nil, choice: choice, space: models.space, actions: ModelRowActions(
                    select: { models.select($0, for: role) },
                    download: { key in if let model = models.catalog.model(key) { models.downloadIfItFits(model) } },
                    cancel: { key in if let model = models.catalog.model(key) { models.cancel(model) } }))
                if role == .transcription {
                    TranscriptionLanguageSettings(language: language, catalog: models.catalog)
                }
            } header: {
                Text(Self.title(role))
            }
        } else if role == .summarization {
            // No summary model fits in the memory iOS gives Daybook on this iPhone: summaries are a Mac's.
            Section {
                Text("Needs an iPhone with more memory").foregroundStyle(.secondary)
            } header: {
                Text(Self.title(role))
            }
        }
    }

    /// The library's transcription language: a synced setting, so a change here changes what every device transcribes with.
    private var language: Binding<String?> {
        let library = model.library.controller
        return Binding(get: { library.transcriptionLanguage }, set: { library.setTranscriptionLanguage($0) })
    }

    /// A role as the iPhone's Settings heads it: the shared word, title-cased ("Voice Profiles").
    static func title(_ role: ModelRole) -> String { SettingsWords.titleCased(role.displayName) }

    /// A size, as both apps write it ("632 MB", "1.6 GB").
    static func size(_ bytes: Int64) -> String { ByteSize.format(bytes) }
}
