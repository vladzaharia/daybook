import DaybookKit
import SwiftUI

/// Settings › Models: the models this iPhone runs, in the Mac model manager's terms but only what a
/// phone needs. Processing (docs/iphone.md, "Processing on this iPhone"): whether this iPhone
/// transcribes its own recordings, one Download for what that needs, and per role (transcription,
/// speakers, voice profiles, summaries) the model, its size and state, and Download, Cancel, or
/// Remove. Live (docs/iphone.md, "Live transcription"): the same for live captions' models. And
/// whether downloads may use cellular data.
struct ModelsSettingsScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var removing: CatalogModel?

    var body: some View {
        let models = model.models
        @Bindable var bindable = models
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Transcribe on This iPhone", isOn: $settings.processesOnThisIPhone)
                if !models.processingMissing.isEmpty {
                    Button {
                        for missing in models.processingMissing { models.download(missing) }
                    } label: {
                        LabeledContent("Download", value: ModelsSettingsScreen.size(models.processingMissingBytes))
                    }
                }
            } header: {
                Text("Processing")
            }
            ForEach(models.processingRoles, id: \.self) { role in
                roleSection(role, models: models)
            }
            if !models.missing.isEmpty {
                Section {
                    Button {
                        models.downloadMissing()
                    } label: {
                        LabeledContent("Download All", value: ModelsSettingsScreen.size(models.missingBytes))
                    }
                } header: {
                    Text("Live")
                }
            }
            ForEach(models.roles.filter(\.isLiveOnly), id: \.self) { role in
                roleSection(role, models: models)
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
        .onChange(of: settings.processesOnThisIPhone) { _, _ in model.processor.pickUp() }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { item in
            Button("Remove", role: .destructive) { Task { await models.remove(item) } }
        } message: { item in
            Text("Frees \(Self.size(item.approximateBytes)).")
        }
    }

    @ViewBuilder
    private func roleSection(_ role: ModelRole, models: PhoneModels) -> some View {
        if let chosen = models.choice(for: role) {
            Section {
                let options = models.options(for: role)
                if options.count > 1 {
                    Picker("Model", selection: Binding(get: { chosen.key }, set: { models.select($0, for: role) })) {
                        ForEach(options) { option in Text(option.name).tag(option.key) }
                    }
                }
                ModelRowView(catalogModel: chosen, status: models.status(of: chosen),
                             download: { models.download(chosen) }, cancel: { models.cancel(chosen) },
                             remove: { removing = chosen })
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

    static func title(_ role: ModelRole) -> String {
        switch role {
        case .transcription: return "Transcription"
        case .diarization: return "Speakers"
        case .summarization: return "Summaries"
        case .liveTranscription: return "Live Transcription"
        case .liveDiarization: return "Live Speakers"
        case .speakerEmbedding: return "Voice Profiles"
        default: return role.rawValue
        }
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// One model: its name and maker, its state, and the one thing to do with it now.
private struct ModelRowView: View {
    let catalogModel: CatalogModel
    let status: PhoneModels.Status
    let download: () -> Void
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(catalogModel.name)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                if case .downloading(let fraction) = status {
                    ProgressView(value: fraction).tint(PhoneStyle.accent)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let size = ModelsSettingsScreen.size(catalogModel.approximateBytes)
        let maker = catalogModel.maker.map { "\($0) · " } ?? ""
        switch status {
        case .notDownloaded: return "\(maker)\(size)"
        case .waitingForWiFi: return "Waiting for Wi‑Fi · \(size)"
        case .downloading(let fraction): return "Downloading · \(Int((fraction * 100).rounded(.down)))%"
        case .downloaded: return "\(maker)Downloaded"
        case .failed(let reason): return reason
        case .unavailable(let reason): return reason
        }
    }

    @ViewBuilder private var action: some View {
        switch status {
        case .notDownloaded, .failed:
            Button("Download", action: download).buttonStyle(.bordered)
        case .waitingForWiFi, .downloading:
            Button("Cancel", action: cancel).buttonStyle(.bordered)
        case .downloaded:
            Button("Remove", role: .destructive, action: remove).buttonStyle(.borderless)
        case .unavailable:
            EmptyView()
        }
    }
}
