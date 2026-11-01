import DaybookCore
import DaybookKit
import SwiftUI

// MARK: - Cloud pane

/// Settings › Cloud (docs/cloud.md, "Settings"): each provider's key, then, once there is one, when summaries use the
/// cloud, the tier with what an hour costs, Recommended or a model, effort, and the countdown. Preferences are this Mac's
/// own; keys are in iCloud Keychain, shared with the iPhone.
struct CloudSettings: View {
    let cloud: CloudSetup
    @State private var editing: KeyEditing?
    @State private var removing: CloudProvider?

    /// The provider whose key the sheet adds or replaces.
    struct KeyEditing: Identifiable {
        let provider: CloudProvider
        var id: String { provider.rawValue }
    }

    init(state: AppState) { cloud = state.cloud }

    var body: some View {
        Form {
            Section {
                ForEach(CloudProvider.allCases, id: \.self) { provider in
                    CloudKeyRow(cloud: cloud, provider: provider, edit: { editing = KeyEditing(provider: provider) }, remove: { removing = provider })
                }
            } header: {
                Text("Keys")
            } footer: {
                SettingsFooter("Sends the transcript and notes, never audio.")
            }
            if cloud.isSetUp {
                CloudSummarySettings(cloud: cloud)
            }
        }
        .formStyle(.grouped)
        .task {
            await cloud.refresh()
            #if DEBUG
            editing = CloudSettingsDemo.sheet.map(KeyEditing.init(provider:))
            #endif
        }
        .sheet(item: $editing) { editing in CloudKeySheet(cloud: cloud, provider: editing.provider) }
        .alert(removing.map { "Remove the \(CloudKeyRow.name($0)) key?" } ?? "",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { provider in
            Button("Remove", role: .destructive) { Task { await cloud.removeKey(for: provider) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It’s removed from your other devices too.")
        }
    }
}

/// A provider's key: its masked form with Replace and Remove, or Add Key.
private struct CloudKeyRow: View {
    let cloud: CloudSetup
    let provider: CloudProvider
    let edit: () -> Void
    let remove: () -> Void

    static func name(_ provider: CloudProvider) -> String { provider == .anthropic ? "Anthropic" : "OpenAI" }

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.s2) {
                if cloud.keys[provider] != nil {
                    Button("Replace…", action: edit)
                    Button("Remove…", action: remove)
                } else {
                    Button("Add Key…", action: edit)
                }
            }
        } label: {
            Text(Self.name(provider))
            if let masked = cloud.keys[provider] {
                if cloud.checks[provider] == .works {
                    Text("\(masked) · This key works")
                } else {
                    Text(masked)
                }
            }
        }
    }
}

/// Adds or replaces a key: it's checked with the provider before it's kept.
private struct CloudKeySheet: View {
    let cloud: CloudSetup
    let provider: CloudProvider
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(cloud: CloudSetup, provider: CloudProvider) {
        self.cloud = cloud
        self.provider = provider
        #if DEBUG
        _text = State(initialValue: CloudSettingsDemo.typedKey ?? "")
        #else
        _text = State(initialValue: "")
        #endif
    }

    private var replacing: Bool { cloud.keys[provider] != nil }
    private var checking: Bool { cloud.checks[provider] == .checking }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("\(replacing ? "Replace" : "Add") \(CloudKeyRow.name(provider)) Key").font(.headline)
            SecureField("Key", text: $text, prompt: Text(provider == .anthropic ? "sk-ant-…" : "sk-…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                .onChange(of: text) { _, _ in cloud.clearCheck(for: provider) }
                .disabled(checking)
            if checking {
                HStack(spacing: Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            } else if case .failed(let message, let details) = cloud.checks[provider] {
                ProblemLine(text: message, details: details.isEmpty ? nil : details)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    cloud.clearCheck(for: provider)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(replacing ? "Replace" : "Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            }
        }
        .padding(Space.s5)
        .frame(width: 420)
    }

    private func add() {
        guard !checking, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await cloud.addKey(text, for: provider) { dismiss() }
        }
    }
}

/// When summaries use the cloud, and which model: shown once a key is set.
private struct CloudSummarySettings: View {
    @Bindable var cloud: CloudSetup

    var body: some View {
        Section("Summaries") {
            Picker("Use the cloud", selection: $cloud.preferences.policy) {
                Text("Offer First").tag(CloudSummaryPreferences.Policy.ask)
                Text("Always").tag(CloudSummaryPreferences.Policy.always)
                Text("Never").tag(CloudSummaryPreferences.Policy.never)
            }
            if cloud.preferences.policy == .ask {
                Picker("Countdown", selection: $cloud.preferences.countdownSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                }
            }
        }
        if cloud.preferences.policy != .never {
            Section("Quality") {
                ForEach(CloudTier.allCases.filter { !cloud.offers(in: $0).isEmpty }, id: \.self) { tier in
                    CloudTierRow(cloud: cloud, tier: tier)
                }
                if cloud.offers.isEmpty {
                    Text(cloud.isRefreshing ? "Finding models…" : "No models").foregroundStyle(.secondary)
                } else {
                    modelPicker
                    LabeledContent("Effort") {
                        Picker("Effort", selection: $cloud.preferences.effort) {
                            ForEach(cloud.efforts, id: \.self) { effort in Text(Self.title(effort)).tag(effort) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }

    private var modelPicker: some View {
        let recommended = cloud.offers.recommended(cloud.preferences.tier)
        return LabeledContent {
            Picker("Model", selection: Binding(get: { cloud.chosenModel }, set: { cloud.chosenModel = $0 })) {
                Text(recommended.map { "Recommended (\($0.model.name))" } ?? "Recommended").tag(String?.none)
                Divider()
                ForEach(cloud.offers(in: cloud.preferences.tier)) { offer in
                    Text(offer.model.name).tag(Optional(offer.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("Model")
            // A chosen model's cost; the tier's row already says what its recommendation costs.
            if cloud.chosenModel != nil, let resolved = cloud.resolved, let cost = CloudCost.perHour(cloud.costPerHour(resolved)) {
                Text(resolved.model.priceIsEstimated ? "\(cost) · estimated price" : cost)
            }
        }
    }

    static func title(_ effort: CloudEffort) -> String {
        switch effort {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// A tier as a radio row: its name, its recommended model, and what an hour of conversation costs with it.
private struct CloudTierRow: View {
    let cloud: CloudSetup
    let tier: CloudTier

    static func title(_ tier: CloudTier) -> String {
        switch tier {
        case .best: return "Best"
        case .balanced: return "Balanced"
        case .economy: return "Economy"
        }
    }

    var body: some View {
        let chosen = cloud.preferences.tier == tier
        let recommended = cloud.offers.recommended(tier)
        Button { cloud.choose(tier) } label: {
            HStack(alignment: .center, spacing: Space.s3) {
                PresetRadio(isOn: chosen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(tier)).foregroundStyle(.primary)
                    if let recommended {
                        Text(recommended.model.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: Space.s2)
                if let recommended, let cost = CloudCost.perHour(cloud.costPerHour(recommended)) {
                    Text(cost).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
    }
}

#if DEBUG
/// `--cloud-demo none|anthropic|both|never|failed` (with `--open-settings cloud`): Settings › Cloud with in-memory keys and
/// the catalog's models, never reaching a provider. `failed` opens the Add Key sheet with a key the provider refused.
enum CloudSettingsDemo {
    static let state = LaunchOptions.value(after: "--cloud-demo")

    @MainActor static func setup(defaults: UserDefaults) -> CloudSetup? {
        guard let state else { return nil }
        var preferences = CloudSummaryPreferences()
        if state == "never" { preferences.policy = .never }
        let providers: [CloudProvider] = switch state {
        case "none", "failed": []
        case "anthropic": [.anthropic]
        default: [.anthropic, .openai]
        }
        let checks: [CloudProvider: CloudSetup.Check] = state == "failed"
            ? [.anthropic: .failed(message: "Anthropic didn’t accept this key.", details: "HTTP 401 · authentication_error · invalid x-api-key")] : [:]
        return CloudSetup.demo(providers: providers, preferences: preferences, defaults: defaults, checks: checks)
    }

    static var sheet: CloudProvider? { state == "failed" ? .anthropic : nil }

    /// `--cloud-demo summary` (with `--library-demo`): the demo's summarized conversation as Claude Sonnet 5.5 wrote it.
    @MainActor static func apply(to state: AppState) {
        guard self.state == "summary" else { return }
        Task { @MainActor in
            await LibraryDemo.seeding?.value
            guard let id = state.meetings.first(where: { $0.title == LibraryDemo.ready })?.id else { return }
            let provenance = CloudProvenance(provider: .anthropic, model: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", effort: .medium,
                                             inputTokens: 9_800, outputTokens: 2_900, estimatedCost: 0.049, sentBy: "Demo Mac")
            state.update(id) { meeting in
                meeting.summary?.modelID = provenance.modelID
                meeting.summary?.processingSettings = ProcessingSettings(modelID: provenance.modelID, parameters: provenance.parameters,
                                                                         model: provenance.modelProvenance)
            }
        }
    }
    static var typedKey: String? { state == "failed" ? "sk-ant-api03-pasted-key" : nil }
}
#endif
