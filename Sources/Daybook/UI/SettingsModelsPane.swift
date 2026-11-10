import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookUI
import SwiftUI

// MARK: - Models pane

/// Holds the Models pane's `ModelManager`, made the first time the pane draws and kept while it shows. A `@State`
/// initial value is built again each time the parent rebuilds the pane, and building a manager reads the catalog.
private final class ModelManagerSlot {
    private var made: ModelManager?

    @MainActor func manager(for state: AppState) -> ModelManager {
        if let made { return made }
        let manager = ModelManager(state: state)
        made = manager
        return manager
    }
}

/// The pages Settings › Models opens.
enum ModelsPage: String, Hashable {
    case transcription, speakers, summaries, library

    var title: String {
        switch self {
        case .transcription: "Transcription"
        case .speakers: "Speakers"
        case .summaries: "Summaries"
        case .library: "Model Library"
        }
    }
}

/// Settings › Models: the quality processing runs at, what it still needs to download, and whether this Mac transcribes
/// what other devices sync; then a page each for Transcription, Speakers, and Summaries (each role's model with the
/// settings that belong to it), and Model Library (what's on this Mac, updates, every model by family, adding a
/// model, and acknowledgements). Rendered from `ModelManagerSnapshot`, so the catalog decides which roles and models
/// appear. The role rows, the library's size, and its model rows are DaybookUI's, drawn as the iPhone draws them.
struct ModelSettings: View {
    @Bindable var state: AppState
    @State private var slot = ModelManagerSlot()
    @State private var path: [ModelsPage] = []
    /// Where Model Library scrolls to when it opens (`--model-demo`).
    @State private var libraryAnchor: ModelSettingsAnchor?
    @State private var showingVoiceMatching = false
    @State private var removal: ModelRemoval?
    @State private var details: ModelDetailsRequest?
    @State private var showingAddModel = false
    @State private var problemDetails: AppProblem?
    @State private var showingAcknowledgements = false

    init(state: AppState) {
        self.state = state
    }

    private var manager: ModelManager { slot.manager(for: state) }

    /// Why removing waits.
    static let busyHelp = "Available when downloads and processing finish"

    var body: some View {
        NavigationStack(path: $path) {
            ModelsOverview(state: state, manager: manager)
                .navigationTitle("Models")
                .navigationDestination(for: ModelsPage.self) { page in
                    Group {
                        switch page {
                        case .transcription: TranscriptionModelsPage(state: state, manager: manager)
                        case .speakers: SpeakerModelsPage(state: state, manager: manager, showingVoiceMatching: $showingVoiceMatching)
                        case .summaries: SummaryModelsPage(state: state, manager: manager)
                        case .library:
                            DownloadedModelsPage(state: state, manager: manager, anchor: $libraryAnchor, details: $details, removal: $removal,
                                                 showingAddModel: $showingAddModel, showingAcknowledgements: $showingAcknowledgements)
                        }
                    }
                    .navigationTitle(page.title)
                }
        }
        .task {
            await manager.refresh()
            await ModelSettingsDemo.apply(state: state, manager: manager, open: { path = [$0] }, scroll: { libraryAnchor = $0 },
                                          details: $details, removal: $removal, showingAddModel: $showingAddModel,
                                          showingAcknowledgements: $showingAcknowledgements, showingVoiceMatching: $showingVoiceMatching)
        }
        .onChange(of: state.installedModels) { _, _ in Task { await manager.refresh() } }
        .onChange(of: state.downloadingID) { _, _ in Task { await manager.refresh() } }
        .onChange(of: state.modelCatalog.models.count) { _, _ in Task { await manager.refresh() } }
        .sheet(isPresented: $showingVoiceMatching) { VoiceMatchingSheet(state: state) }
        .sheet(item: $details) { request in ModelDetailsSheet(state: state, manager: manager, key: request.key) }
        .sheet(isPresented: $showingAddModel) {
            AddModelSheet(manager: manager, initialText: ModelSettingsDemo.addText, checksImmediately: ModelSettingsDemo.addText.isEmpty == false)
        }
        .sheet(isPresented: $showingAcknowledgements) { ModelAcknowledgementsView(catalog: state.modelCatalog) }
        .modelRemovalAlert($removal, manager: manager)
        .alert(manager.problem?.title ?? "", isPresented: Binding(get: { manager.problem != nil }, set: { if !$0 { manager.problem = nil } }),
               presenting: manager.problem) { problem in
            Button("OK", role: .cancel) {}
            if problem.details != nil {
                Button("Details…") { problemDetails = problem; manager.problem = nil }
            }
        } message: { problem in Text(problem.message) }
        .sheet(item: $problemDetails) { ProblemDetailsSheet(problem: $0) }
    }
}

// MARK: Overview

/// The Models page itself: Quality, the row that downloads what the choices still need, Transcribe synced recordings,
/// then a row for each page, with what it's set to.
private struct ModelsOverview: View {
    @Bindable var state: AppState
    let manager: ModelManager

    var body: some View {
        let snapshot = manager.snapshot
        let choices = Dictionary(uniqueKeysWithValues: snapshot.roleChoices.map { ($0.role, $0) })
        Form {
            Section {
                qualityRow(snapshot)
                if let download = snapshot.downloadSummary(detectSpeakers: state.detectSpeakers) {
                    ModelDownloadRow(download, space: snapshot.space, download: { manager.downloadSelected() },
                                     cancel: { manager.cancelSelected() })
                }
            }
            Section {
                Toggle("Transcribe synced recordings on this Mac", isOn: $state.processSyncedAudio)
                    .controlSize(.regular)
            }
            Section {
                pageRow(.transcription, value: choices[.transcription]?.selectionName)
                pageRow(.speakers, value: state.detectSpeakers ? choices[.diarization]?.selectionName : "Off")
                pageRow(.summaries, value: choices[.summarization]?.selectionName)
            }
            Section {
                pageRow(.library, value: ModelSize.format(snapshot.storage.total))
            }
        }
        .formStyle(.grouped)
    }

    /// Quick, Balanced, or Detailed, with what it takes; Custom while the choices match none of them. A preset whose
    /// download wouldn't fit here says how much it needs.
    @ViewBuilder private func qualityRow(_ snapshot: ModelManagerSnapshot) -> some View {
        let presets = snapshot.presets
        let current = presets.first(where: \.isCurrent)
        LabeledContent {
            Picker("Quality", selection: Binding(get: { current?.id ?? "custom" }, set: { id in
                presets.first { $0.id == id }?.preset?.apply(to: state)
            })) {
                ForEach(presets) { summary in
                    Text(summary.isRecommended ? "\(summary.title) (Recommended)" : summary.title).tag(summary.id)
                }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("Quality")
            if let current {
                if let shortfall = snapshot.space.shortfall(current.missingBytes) {
                    Text(shortfall).foregroundStyle(Ink.warning)
                } else {
                    Text("\(ModelSize.format(current.bytes)) · \(current.memoryGB) GB memory").monospacedDigit()
                }
            }
        }
    }

    private func pageRow(_ page: ModelsPage, value: String?) -> some View {
        NavigationLink(value: page) {
            LabeledContent(page.title) {
                if let value { Text(value).lineLimit(1) }
            }
        }
    }
}

// MARK: Pages

/// A role's model, with Download, Cancel, or the choice of another.
private struct ModelRoleSetting: View {
    let choice: ModelRoleChoice
    let label: String
    let manager: ModelManager

    var body: some View {
        ModelRoleRow(label: label, choice: choice, space: manager.snapshot.space, actions: manager.rowActions(for: choice.role))
    }
}

/// Settings › Models › Transcription: the model, the language and the model for other languages, live captions' models
/// where this Mac has a choice of them, and the vocabulary every transcript and summary is given.
private struct TranscriptionModelsPage: View {
    let state: AppState
    let manager: ModelManager

    var body: some View {
        let choices = manager.snapshot.roleChoices
        Form {
            if let choice = choices.first(where: { $0.role == .transcription }) {
                Section {
                    ModelRoleSetting(choice: choice, label: "Model", manager: manager)
                    TranscriptionLanguageSettings(state: state, manager: manager)
                }
            }
            let live = choices.filter(\.role.isLiveOnly)
            if !live.isEmpty {
                Section("Live Captions") {
                    ForEach(live) { ModelRoleSetting(choice: $0, label: $0.title, manager: manager) }
                }
            }
            Section {
                VocabularySettingsRow(state: state)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › Models › Speakers: whether Daybook tells speakers apart and with which model, how carefully, how many,
/// whether it matches voices across recordings, and the speaker profiles. Every speaker model offered makes voice
/// profiles, itself or with the voice-profile model, which comes with it rather than as a choice of its own.
private struct SpeakerModelsPage: View {
    @Bindable var state: AppState
    let manager: ModelManager
    @Binding var showingVoiceMatching: Bool

    private var speakerModel: String { state.processingPreferences.speakerModelID }
    /// From capabilities in the catalog, not names: the speaker model's own voice profiles, or the voice-profile model's.
    private var supportsVoiceMatching: Bool { state.makesVoiceProfiles }
    private var supportsSpeakerCount: Bool { ModelRouting.supportsExpectedSpeakerCount(speakerModel, catalog: state.modelCatalog) }

    var body: some View {
        Form {
            Section {
                Toggle("Tell speakers apart", isOn: $state.detectSpeakers)
                    .controlSize(.regular)
            }
            Section {
                if let choice = manager.snapshot.roleChoices.first(where: { $0.role == .diarization }) {
                    ModelRoleSetting(choice: choice, label: "Model", manager: manager)
                }
                LabeledContent("Accuracy") {
                    Picker("Accuracy", selection: $state.processingPreferences.speakerOptions.quality) {
                        Text("Fast").tag(SpeakerQuality.fast)
                        Text("Balanced").tag(SpeakerQuality.balanced)
                        Text("Accurate").tag(SpeakerQuality.accurate)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if supportsSpeakerCount {
                    Picker("Number of speakers", selection: speakerCount) {
                        Text("Automatic").tag(0)
                        Divider()
                        ForEach(speakerCounts, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                // What the speaker model can't do isn't offered, rather than shown dimmed with an apology.
                if supportsVoiceMatching {
                    LabeledContent {
                        HStack(spacing: Space.s3) {
                            if state.processingPreferences.matchSpeakersAcrossSources {
                                Button("Adjust…") { showingVoiceMatching = true }
                            }
                            Toggle("Match voices across recordings", isOn: $state.processingPreferences.matchSpeakersAcrossSources)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.regular)
                        }
                    } label: {
                        Text("Match voices across recordings")
                    }
                }
            }
            .disabled(!state.detectSpeakers)
            Section {
                SpeakerProfilesSettingsRow(state: state)
            }
        }
        .formStyle(.grouped)
    }

    private var speakerCounts: [Int] {
        let stored = state.processingPreferences.speakerOptions.expectedSpeakerCount
        return Array(2...8) + (stored.map { (2...8).contains($0) ? [] : [$0] } ?? [])
    }

    private var speakerCount: Binding<Int> {
        Binding(get: { state.processingPreferences.speakerOptions.expectedSpeakerCount ?? 0 }, set: { value in
            state.processingPreferences.speakerOptions.expectedSpeakerCount = value == 0 ? nil : value
        })
    }
}

/// Settings › Models › Summaries: the summary model, the models for the smaller jobs around it (titles, photos), and
/// the templates summaries follow.
private struct SummaryModelsPage: View {
    let state: AppState
    let manager: ModelManager

    /// Roles with pages of their own; any other, live captions' aside, is one of a summary's smaller jobs.
    private static let elsewhere: Set<ModelRole> = [.transcription, .diarization, .speakerEmbedding, .summarization]

    var body: some View {
        let choices = manager.snapshot.roleChoices
        Form {
            if let choice = choices.first(where: { $0.role == .summarization }) {
                Section {
                    ModelRoleSetting(choice: choice, label: "Model", manager: manager)
                }
            }
            let others = choices.filter { !Self.elsewhere.contains($0.role) && !$0.role.isLiveOnly }
            if !others.isEmpty {
                Section {
                    ForEach(others) { ModelRoleSetting(choice: $0, label: $0.title, manager: manager) }
                }
            }
            Section {
                TemplatesSettingsRow(state: state)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › Models › Model Library: how much the models take here, what can go, updates, then every model by
/// family, with Add Model and the acknowledgements at the foot.
private struct DownloadedModelsPage: View {
    let state: AppState
    let manager: ModelManager
    @Binding var anchor: ModelSettingsAnchor?
    @Binding var details: ModelDetailsRequest?
    @Binding var removal: ModelRemoval?
    @Binding var showingAddModel: Bool
    @Binding var showingAcknowledgements: Bool

    var body: some View {
        let snapshot = manager.snapshot
        ScrollViewReader { proxy in
            Form {
                librarySection(snapshot)
                    .id(ModelSettingsAnchor.library)
                let families = snapshot.families
                ForEach(families) { family in
                    Section {
                        ForEach(family.rows) { row in
                            ModelLibraryRow(manager: manager, row: row,
                                            showDetails: { details = ModelDetailsRequest(key: row.id) },
                                            remove: { removal = $0 })
                        }
                    } header: {
                        Text(family.name)
                    } footer: {
                        if family.id == families.last?.id { libraryFooter }
                    }
                    .id(ModelSettingsAnchor.family(family.id))
                }
            }
            .formStyle(.grouped)
            .onChange(of: anchor, initial: true) { _, target in
                guard let target else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(target, anchor: .top)
                    anchor = nil
                }
            }
        }
    }

    @ViewBuilder private func librarySection(_ snapshot: ModelManagerSnapshot) -> some View {
        let storage = snapshot.storage
        ModelLibrarySection(total: storage.total, showsHeader: false) {
            Button("Show in Finder") { manager.showModelsFolder() }
        } rows: {
            if !storage.removableRevisions.isEmpty {
                LabeledContent {
                    Button("Remove") { Task { await manager.removeOldRevisions() } }
                        .disabled(!manager.canChangeFiles)
                        .help(manager.canChangeFiles ? "" : ModelSettings.busyHelp)
                } label: {
                    Text("Old revisions")
                    Text(ModelSize.format(storage.removableRevisionBytes)).monospacedDigit()
                }
            }
            if storage.oldDownloadBytes > 0 {
                LabeledContent {
                    Button("Remove") { Task { await manager.removeOldDownloads() } }
                        .disabled(!manager.canChangeFiles)
                        .help(manager.canChangeFiles ? "" : ModelSettings.busyHelp)
                } label: {
                    Text("Old downloads")
                    Text(ModelSize.format(storage.oldDownloadBytes)).monospacedDigit()
                }
            }
            // Nothing downloaded has nothing to update: models included with macOS update with it.
            if state.installedModels.contains(where: { state.modelCatalog.model($0)?.isSystemModel == false }) {
                LabeledContent {
                    HStack(spacing: Space.s2) {
                        if manager.updateCheck == .checking { ProgressView().controlSize(.small) }
                        Button("Check for Updates") { Task { await manager.checkForUpdates() } }
                            .disabled(manager.updateCheck == .checking)
                    }
                } label: {
                    Text("Updates")
                    if let line = updateLine(snapshot) {
                        Text(line).foregroundStyle(isUpdateProblem ? Ink.warning : .secondary)
                    }
                }
                .id(ModelSettingsAnchor.updates)
            }
            ForEach(snapshot.pendingUpdates, id: \.revision.id) { update in
                ModelUpdateRow(manager: manager, update: update)
                    .padding(.leading, Space.s5)
            }
        }
    }

    private var isUpdateProblem: Bool { if case .failed = manager.updateCheck { return true }; return false }

    private func updateLine(_ snapshot: ModelManagerSnapshot) -> String? {
        switch manager.updateCheck {
        case .never: return nil
        case .checking: return "Checking…"
        case .failed(let message): return message
        case .checked(let date):
            let count = snapshot.pendingUpdates.count
            let found = count == 0 ? "Up to date" : count == 1 ? "1 update" : "\(count) updates"
            return "\(found) · Checked \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

    private var libraryFooter: some View {
        HStack(spacing: Space.s2) {
            Spacer()
            Button("Acknowledgements…") { showingAcknowledgements = true }
            Button("Add Model…") { showingAddModel = true }
        }
        .padding(.top, Space.s2)
    }
}

/// Opens a model's details.
struct ModelDetailsRequest: Identifiable {
    let key: String
    var id: String { key }
}

/// Where Model Library can scroll to.
enum ModelSettingsAnchor: Hashable {
    case library, updates, family(String)
}

/// Advanced Speaker Settings: the two voice-matching thresholds, in plain words.
private struct VoiceMatchingSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Voice Matching").font(.headline)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("How alike two voices must be")
                Slider(value: $state.processingPreferences.speakerMatchThreshold, in: 0.65...0.95) {
                    Text("How alike two voices must be")
                } minimumValueLabel: {
                    Text("Looser")
                } maximumValueLabel: {
                    Text("Stricter")
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("How clearly the best match must win")
                Slider(value: $state.processingPreferences.speakerMatchMargin, in: 0...0.2) {
                    Text("How clearly the best match must win")
                } minimumValueLabel: {
                    Text("Smaller")
                } maximumValueLabel: {
                    Text("Larger")
                }
                .labelsHidden()
            }
            HStack {
                Button("Restore Defaults") {
                    state.processingPreferences.speakerMatchThreshold = 0.82
                    state.processingPreferences.speakerMatchMargin = 0.06
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s5)
        .frame(width: 420)
        .presentationSizing(.fitted)
    }
}

// MARK: - Demos

/// `--model-demo` steps that act on the pane (debug builds; see `ModelDemo`).
@MainActor
enum ModelSettingsDemo {
    private static var applied = false

    /// "add" opens Add Model on the scripted repository; "add:<owner/name>" on another, which the scripted Hugging Face
    /// doesn't have, to show what Add Model says when a check fails.
    static var addText: String {
        guard let repository = ModelDemo.value("add") else { return "" }
        return "https://huggingface.co/\(repository.isEmpty ? ModelDemo.addRepository : repository)"
    }

    static func apply(state: AppState, manager: ModelManager, open: (ModelsPage) -> Void, scroll: (ModelSettingsAnchor) -> Void,
                      details: Binding<ModelDetailsRequest?>, removal: Binding<ModelRemoval?>, showingAddModel: Binding<Bool>,
                      showingAcknowledgements: Binding<Bool>, showingVoiceMatching: Binding<Bool>) async {
        #if DEBUG
        guard ModelDemo.isRequested, !applied else { return }
        applied = true
        if let preset = ModelDemo.value("preset").flatMap(ModelPreset.init(rawValue:)) { preset.apply(to: state) }
        // "use:<role>=<key>" makes the choices Custom.
        if let use = ModelDemo.value("use"), let split = use.firstIndex(of: "=") {
            manager.use(String(use[use.index(after: split)...]), for: ModelRole(String(use[..<split])))
        }
        // "free:<bytes>": that much is free where models go, to show what a download that won't fit says.
        if let free = ModelDemo.value("free").flatMap(Int64.init) {
            manager.readSpace = { _ in ModelSpace(free: free) }
            await manager.refresh()
        }
        if let key = ModelDemo.value("downloading"), !key.isEmpty { state.downloadModels([key]) }
        // "failed:<key>": its download stopped on its own; "wifi:<key>": it's owed and waits for Wi‑Fi.
        if let key = ModelDemo.value("failed"), !key.isEmpty { state.demoDownloads([key], .failed) }
        if let key = ModelDemo.value("wifi"), !key.isEmpty { state.demoDownloads([key], .waitingForWiFi) }
        if ModelDemo.value("updates") != nil { await manager.checkForUpdates() }
        try? await Task.sleep(for: .milliseconds(300))
        // "page:<transcription|speakers|summaries|library>" opens a page; "scroll:…" opens Model Library there.
        if let page = ModelDemo.value("page").flatMap(ModelsPage.init(rawValue:)) { open(page) }
        switch ModelDemo.value("scroll") {
        case "library"?: open(.library); scroll(.library)
        case "updates"?: open(.library); scroll(.updates)
        case let value? where value.hasPrefix("family:"): open(.library); scroll(.family(String(value.dropFirst(7))))
        default: break
        }
        if let key = ModelDemo.value("details"), !key.isEmpty { details.wrappedValue = ModelDetailsRequest(key: key) }
        if let key = ModelDemo.value("remove"), !key.isEmpty { removal.wrappedValue = manager.removal(of: key) }
        if ModelDemo.value("add") != nil { showingAddModel.wrappedValue = true }
        if ModelDemo.value("acknowledgements") != nil { showingAcknowledgements.wrappedValue = true }
        // "voice-matching" opens the voice-matching thresholds, from Speakers.
        if ModelDemo.value("voice-matching") != nil { open(.speakers); showingVoiceMatching.wrappedValue = true }
        if ModelDemo.value("about") != nil { AboutPanel.show(catalog: state.modelCatalog) }
        #endif
    }
}
