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

/// Settings › Models: processing (synced recordings, the quality preset, and what's left to download); each role's
/// model with the settings that belong to it; words and templates; then the model library (what's on this Mac,
/// updates, every model by family, adding a model, and acknowledgements). Rendered from `ModelManagerSnapshot`, so the
/// catalog decides which roles and models appear. Processing, the role rows, the library's size, and its model rows are
/// DaybookUI's, drawn as the iPhone draws them.
struct ModelSettings: View {
    @Bindable var state: AppState
    @State private var slot = ModelManagerSlot()
    @Environment(\.openWindow) private var openWindow
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

    /// Roles with sections of their own; any other role gets a section after Summaries.
    private static let placedRoles: Set<ModelRole> = [.transcription, .diarization, .speakerEmbedding, .summarization, .smallTasks]

    var body: some View {
        let snapshot = manager.snapshot
        let choices = Dictionary(uniqueKeysWithValues: snapshot.roleChoices.map { ($0.role, $0) })
        ScrollViewReader { proxy in
            Form {
                processingSection(snapshot)
                transcriptionSection(choices[.transcription], space: snapshot.space)
                speakersSection(choices, space: snapshot.space)
                if choices[.summarization] != nil || choices[.smallTasks] != nil {
                    Section("Summaries") {
                        if let choice = choices[.summarization] { roleRow(choice, label: "Model", space: snapshot.space) }
                        if let choice = choices[.smallTasks] { roleRow(choice, label: choice.title, space: snapshot.space) }
                    }
                }
                ForEach(snapshot.roleChoices.filter { !Self.placedRoles.contains($0.role) }) { choice in
                    Section(choice.title) { roleRow(choice, label: "Model", space: snapshot.space) }
                }
                wordsSection
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
            .task {
                await manager.refresh()
                await ModelSettingsDemo.apply(state: state, manager: manager, proxy: proxy, details: $details, removal: $removal,
                                              showingAddModel: $showingAddModel, showingAcknowledgements: $showingAcknowledgements,
                                              showingVoiceMatching: $showingVoiceMatching)
            }
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

    // MARK: Processing

    /// Whether this Mac transcribes what other devices sync to it, the quality presets, and the row that downloads what
    /// the choices still need (DaybookUI's, as the iPhone's). A preset whose download wouldn't fit here says how much it
    /// needs.
    private func processingSection(_ snapshot: ModelManagerSnapshot) -> some View {
        ModelProcessingSection(toggleTitle: "Transcribe synced recordings on this Mac", isOn: $state.processSyncedAudio,
                               download: snapshot.downloadSummary(detectSpeakers: state.detectSpeakers), space: snapshot.space,
                               downloadAction: { manager.downloadSelected() }, cancelAction: { manager.cancelDownloads() }) {
            ForEach(snapshot.presets) { summary in
                ModelQualityRow(summary.option, note: summary.isCurrent ? nil : snapshot.space.shortfall(summary.missingBytes)
                    .map { ModelLine($0, needsAttention: true) }) { summary.preset?.apply(to: state) }
            }
        }
    }

    // MARK: Roles

    private func roleRow(_ choice: ModelRoleChoice, label: String, space: ModelSpace) -> some View {
        ModelRoleRow(label: label, choice: choice, space: space, actions: manager.rowActions(for: choice.role))
    }

    @ViewBuilder private func transcriptionSection(_ choice: ModelRoleChoice?, space: ModelSpace) -> some View {
        if let choice {
            Section(choice.title) {
                roleRow(choice, label: "Model", space: space)
                TranscriptionLanguageSettings(state: state, manager: manager)
            }
        }
    }

    private var speakerModel: String { state.processingPreferences.speakerModelID }
    /// From capabilities in the catalog, not names: the speaker model's own voice profiles, or the voice-profile model's.
    private var supportsVoiceMatching: Bool { state.makesVoiceProfiles }
    private var supportsSpeakerCount: Bool { ModelRouting.supportsExpectedSpeakerCount(speakerModel, catalog: state.modelCatalog) }

    @ViewBuilder private func speakersSection(_ choices: [ModelRole: ModelRoleChoice], space: ModelSpace) -> some View {
        Section("Speakers") {
            Toggle("Tell speakers apart", isOn: $state.detectSpeakers)
                .controlSize(.regular)
            Group {
                if let choice = choices[.diarization] { roleRow(choice, label: "Model", space: space) }
                if let choice = choices[.speakerEmbedding] { roleRow(choice, label: choice.title, space: space) }
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
            }
            .padding(.leading, Space.s5)
            .disabled(!state.detectSpeakers)
            SpeakerProfilesSettingsRow(state: state)
        }
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

    // MARK: Words and templates

    private var wordsSection: some View {
        Section("Words and Templates") {
            LabeledContent {
                Button("Edit…") { openWindow(id: WindowID.vocabulary) }
            } label: {
                Text("Vocabulary")
                Text(vocabularyCount)
            }
            LabeledContent {
                Button("Edit…") { openWindow(id: WindowID.templates) }
            } label: {
                Text("Summary templates")
                Text(templateCount)
            }
        }
    }

    /// "12 terms · 3 suggested", as the iPhone counts them (`SettingsWords`).
    private var vocabularyCount: String { SettingsWords.vocabulary(state.glossary) }

    /// "12 built-in, 2 yours".
    private var templateCount: String { SettingsWords.templates(state.templates) }

    // MARK: Library

    @ViewBuilder private func librarySection(_ snapshot: ModelManagerSnapshot) -> some View {
        let storage = snapshot.storage
        ModelLibrarySection(total: storage.total) {
            Button("Show in Finder") { manager.showModelsFolder() }
        } rows: {
            if !storage.removableRevisions.isEmpty {
                LabeledContent {
                    Button("Remove") { Task { await manager.removeOldRevisions() } }
                        .disabled(!manager.canChangeFiles)
                        .help(manager.canChangeFiles ? "" : Self.busyHelp)
                } label: {
                    Text("Old revisions")
                    Text(ModelSize.format(storage.removableRevisionBytes)).monospacedDigit()
                }
            }
            if storage.oldDownloadBytes > 0 {
                LabeledContent {
                    Button("Remove") { Task { await manager.removeOldDownloads() } }
                        .disabled(!manager.canChangeFiles)
                        .help(manager.canChangeFiles ? "" : Self.busyHelp)
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

    /// Why removing waits.
    static let busyHelp = "Available when downloads and processing finish"

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

/// Where the pane can scroll to.
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

    static func apply(state: AppState, manager: ModelManager, proxy: ScrollViewProxy, details: Binding<ModelDetailsRequest?>,
                      removal: Binding<ModelRemoval?>, showingAddModel: Binding<Bool>, showingAcknowledgements: Binding<Bool>,
                      showingVoiceMatching: Binding<Bool>) async {
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
        if ModelDemo.value("updates") != nil { await manager.checkForUpdates() }
        try? await Task.sleep(for: .milliseconds(300))
        switch ModelDemo.value("scroll") {
        case "library"?: proxy.scrollTo(ModelSettingsAnchor.library, anchor: .top)
        case "updates"?: proxy.scrollTo(ModelSettingsAnchor.updates, anchor: .top)
        case let value? where value.hasPrefix("family:"): proxy.scrollTo(ModelSettingsAnchor.family(String(value.dropFirst(7))), anchor: .top)
        default: break
        }
        if let key = ModelDemo.value("details"), !key.isEmpty { details.wrappedValue = ModelDetailsRequest(key: key) }
        if let key = ModelDemo.value("remove"), !key.isEmpty { removal.wrappedValue = manager.removal(of: key) }
        if ModelDemo.value("add") != nil { showingAddModel.wrappedValue = true }
        if ModelDemo.value("acknowledgements") != nil { showingAcknowledgements.wrappedValue = true }
        // "voice-matching" opens the voice-matching thresholds.
        if ModelDemo.value("voice-matching") != nil { showingVoiceMatching.wrappedValue = true }
        if ModelDemo.value("about") != nil { AboutPanel.show(catalog: state.modelCatalog) }
        #endif
    }
}
