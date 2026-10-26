import DaybookCore
import DaybookIntelligence
import DaybookKit
import SwiftUI

// MARK: - Models pane

/// Settings › Models: the quality preset; each role's model with the settings that belong to it;
/// words and templates; then the model library (what's on this Mac, updates, every model by
/// family, adding a model, and acknowledgements). Rendered from `ModelManagerSnapshot`, so the
/// catalog decides which roles and models appear.
struct ModelSettings: View {
    @ObservedObject var state: AppState
    /// The pane is the download's progress view: it follows the download itself.
    @ObservedObject private var download: ActivityProgress
    @StateObject private var manager: ModelManager
    @Environment(\.openWindow) private var openWindow
    @State private var showingVoiceMatching = false
    @State private var removal: ModelRemoval?
    @State private var details: ModelDetailsRequest?
    @State private var showingAddModel = false
    @State private var problemDetails: AppProblem?
    @State private var showingAcknowledgements = false

    init(state: AppState) {
        self.state = state
        download = state.downloadActivity
        _manager = StateObject(wrappedValue: ModelManager(state: state))
    }

    /// Roles with sections of their own; any other role gets a section after Summaries.
    private static let placedRoles: Set<ModelRole> = [.transcription, .diarization, .speakerEmbedding, .summarization, .smallTasks]

    var body: some View {
        let snapshot = manager.snapshot
        let choices = Dictionary(uniqueKeysWithValues: snapshot.roleChoices.map { ($0.role, $0) })
        ScrollViewReader { proxy in
            Form {
                qualitySection(snapshot)
                transcriptionSection(choices[.transcription])
                speakersSection(choices)
                if choices[.summarization] != nil || choices[.smallTasks] != nil {
                    Section("Summaries") {
                        if let choice = choices[.summarization] { ModelChoiceRow(manager: manager, choice: choice, label: "Model") }
                        if let choice = choices[.smallTasks] { ModelChoiceRow(manager: manager, choice: choice, label: choice.title) }
                    }
                }
                ForEach(snapshot.roleChoices.filter { !Self.placedRoles.contains($0.role) }) { choice in
                    Section(choice.title) { ModelChoiceRow(manager: manager, choice: choice, label: "Model") }
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
                                              showingAddModel: $showingAddModel, showingAcknowledgements: $showingAcknowledgements)
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

    // MARK: Quality

    @ViewBuilder private func qualitySection(_ snapshot: ModelManagerSnapshot) -> some View {
        Section("Quality") {
            ForEach(snapshot.presets) { summary in
                ModelPresetRow(summary: summary) { summary.preset?.apply(to: state) }
            }
            downloadRow(snapshot)
        }
    }

    /// Speaks only when the chosen models aren't all on this Mac.
    @ViewBuilder private func downloadRow(_ snapshot: ModelManagerSnapshot) -> some View {
        let keys = snapshot.choiceRoles.filter { $0 != .diarization || state.detectSpeakers }.compactMap { state.modelSelections[$0] }
        let downloadable = keys.filter { state.modelCatalog.model($0)?.isSystemModel == false }
        if ModelSize.isDownloading(downloadable, in: state) {
            let total = ModelSize.bytes(downloadable, in: state.modelCatalog), done = ModelSize.downloaded(downloadable, in: state)
            HStack(spacing: Space.s3) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.brand(width: nil))
                    .accessibilityLabel("Downloading models")
                Text(ModelSize.progress(done, of: total))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button("Cancel") { manager.cancelDownloads() }
            }
        } else if !manager.missingSelected.isEmpty {
            let missing = manager.missingSelected
            LabeledContent {
                Button("Download \(ModelSize.format(ModelSize.bytes(missing, in: state.modelCatalog)))") { manager.downloadSelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(DaybookStyle.prominentFill)
            } label: {
                Text(missing.count == Set(downloadable).count ? "Not downloaded yet" : "Partly downloaded")
                Text(missing.map { state.modelCatalog.model($0).map { ModelSize.shortName($0, in: state.modelCatalog) } ?? $0 }
                    .joined(separator: ", "))
            }
        }
    }

    // MARK: Roles

    @ViewBuilder private func transcriptionSection(_ choice: ModelRoleChoice?) -> some View {
        if let choice {
            Section(choice.title) {
                ModelChoiceRow(manager: manager, choice: choice, label: "Model")
                TranscriptionLanguageSettings(state: state)
            }
        }
    }

    private var speakerModel: String { state.processingPreferences.speakerModelID }
    /// From the speaker model's capabilities in the catalog, not its name.
    private var supportsVoiceMatching: Bool { ModelRouting.supportsVoiceMatching(speakerModel, catalog: state.modelCatalog) }
    private var supportsSpeakerCount: Bool { ModelRouting.supportsExpectedSpeakerCount(speakerModel, catalog: state.modelCatalog) }

    @ViewBuilder private func speakersSection(_ choices: [ModelRole: ModelRoleChoice]) -> some View {
        Section("Speakers") {
            Toggle("Tell speakers apart", isOn: $state.detectSpeakers)
                .controlSize(.regular)
            Group {
                if let choice = choices[.diarization] { ModelChoiceRow(manager: manager, choice: choice, label: "Model") }
                if let choice = choices[.speakerEmbedding] { ModelChoiceRow(manager: manager, choice: choice, label: choice.title) }
                Toggle(isOn: $state.processingPreferences.matchSpeakersAcrossSources) {
                    Text("Match voices across recordings")
                    Text(supportsVoiceMatching
                         ? "Keeps each person’s name when a conversation has more than one recording."
                         : "Not available with this model.")
                }
                .controlSize(.regular)
                .disabled(!supportsVoiceMatching)
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
                Picker(selection: speakerCount) {
                    Text("Automatic").tag(0)
                    Divider()
                    ForEach(speakerCounts, id: \.self) { Text("\($0)").tag($0) }
                } label: {
                    Text("Number of speakers")
                    if !supportsSpeakerCount { Text("Not available with this model.") }
                }
                .disabled(!supportsSpeakerCount)
                LabeledContent("Voice matching") {
                    Button("Adjust…") { showingVoiceMatching = true }
                }
                .disabled(!supportsVoiceMatching)
            }
            .padding(.leading, Space.s5)
            .disabled(!state.detectSpeakers)
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

    private var vocabularyCount: String {
        switch state.glossary.count {
        case 0: return "No terms yet"
        case 1: return "1 term"
        case let count: return "\(count) terms"
        }
    }

    private var templateCount: String {
        let yours = state.templates.filter { !$0.isBuiltIn }.count
        let builtIn = "\(SummaryTemplate.builtIns.count) built-in"
        return yours == 0 ? builtIn : "\(builtIn), \(yours) yours"
    }

    // MARK: Library

    @ViewBuilder private func librarySection(_ snapshot: ModelManagerSnapshot) -> some View {
        let storage = snapshot.storage
        Section("Model Library") {
            LabeledContent {
                HStack(spacing: Space.s3) {
                    Text(ModelSize.format(storage.total)).monospacedDigit().foregroundStyle(.secondary)
                    Button("Show in Finder") { manager.showModelsFolder() }
                }
            } label: {
                Text("Downloaded models")
            }
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
            LabeledContent {
                HStack(spacing: Space.s2) {
                    if manager.updateCheck == .checking { ProgressView().controlSize(.small) }
                    Button("Check for Updates") { Task { await manager.checkForUpdates() } }
                        .disabled(manager.updateCheck == .checking || state.installedModels.isEmpty)
                }
            } label: {
                Text("Updates")
                if let line = updateLine(snapshot) {
                    Text(line).foregroundStyle(isUpdateProblem ? Ink.warning : .secondary)
                }
            }
            .id(ModelSettingsAnchor.updates)
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
    @ObservedObject var state: AppState
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

    static var addText: String {
        ModelDemo.value("add") != nil ? "https://huggingface.co/\(ModelDemo.addRepository)" : ""
    }

    static func apply(state: AppState, manager: ModelManager, proxy: ScrollViewProxy, details: Binding<ModelDetailsRequest?>,
                      removal: Binding<ModelRemoval?>, showingAddModel: Binding<Bool>, showingAcknowledgements: Binding<Bool>) async {
        #if DEBUG
        guard ModelDemo.isRequested, !applied else { return }
        applied = true
        if let preset = ModelDemo.value("preset").flatMap(ModelPreset.init(rawValue:)) { preset.apply(to: state) }
        // "use:<role>=<key>" makes the choices Custom.
        if let use = ModelDemo.value("use"), let split = use.firstIndex(of: "=") {
            manager.use(String(use[use.index(after: split)...]), for: ModelRole(String(use[..<split])))
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
        if ModelDemo.value("about") != nil { AboutPanel.show(catalog: state.modelCatalog) }
        #endif
    }
}
