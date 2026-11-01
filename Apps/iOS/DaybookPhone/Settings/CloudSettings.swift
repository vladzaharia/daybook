import DaybookKit
import SwiftUI

/// Settings › Cloud (docs/cloud.md, "Settings"): each provider's key, then, once there is one, when summaries use the
/// cloud, the quality tier with what an hour costs, Recommended or a model, effort, and the countdown. The preferences
/// are this iPhone's own; keys are in iCloud Keychain, shared with the Mac.
struct CloudSettingsScreen: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let cloud = model.cloudSummaries
        Form {
            Section {
                ForEach(CloudProvider.allCases, id: \.self) { provider in
                    NavigationLink(value: SettingsRoute.cloudKey(provider.rawValue)) {
                        LabeledContent(CloudSettingsScreen.name(provider), value: cloud.keys[provider] ?? "Add Key")
                    }
                }
            } footer: {
                Text("Sends the transcript and notes, never audio.")
            }
            if cloud.isSetUp {
                CloudSummarySection(cloud: cloud)
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("Cloud")
        .navigationBarTitleDisplayMode(.inline)
        .task { await cloud.refresh() }
    }

    static func name(_ provider: CloudProvider) -> String { provider == .anthropic ? "Anthropic" : "OpenAI" }

    static func title(_ tier: CloudTier) -> String {
        switch tier {
        case .best: return "Best"
        case .balanced: return "Balanced"
        case .economy: return "Economy"
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

/// When summaries use the cloud, and which model: shown once a key is set.
private struct CloudSummarySection: View {
    @Bindable var cloud: CloudSetup

    var body: some View {
        Section {
            Picker("Use the Cloud", selection: $cloud.preferences.policy) {
                Text("Offer First").tag(CloudSummaryPreferences.Policy.ask)
                Text("Always").tag(CloudSummaryPreferences.Policy.always)
                Text("Never").tag(CloudSummaryPreferences.Policy.never)
            }
            if cloud.preferences.policy == .ask {
                Picker("Countdown", selection: $cloud.preferences.countdownSeconds) {
                    Text("15 Seconds").tag(15)
                    Text("30 Seconds").tag(30)
                }
            }
        } header: {
            Text("Summaries")
        }
        if cloud.preferences.policy != .never {
            Section {
                ForEach(CloudTier.allCases.filter { !cloud.offers(in: $0).isEmpty }, id: \.self) { tier in
                    tierRow(tier)
                }
                if cloud.offers.isEmpty {
                    Text(cloud.isRefreshing ? "Finding models…" : "No models").foregroundStyle(PhoneStyle.Ink.secondary)
                } else {
                    // The tier's row names what Recommended is.
                    Picker("Model", selection: Binding(get: { cloud.chosenModel }, set: { cloud.chosenModel = $0 })) {
                        Text("Recommended").tag(String?.none)
                        ForEach(cloud.offers(in: cloud.preferences.tier)) { offer in
                            Text(offer.model.name).tag(Optional(offer.id))
                        }
                    }
                    LabeledContent("Effort") {
                        Picker("Effort", selection: $cloud.preferences.effort) {
                            ForEach(cloud.efforts, id: \.self) { effort in Text(CloudSettingsScreen.title(effort)).tag(effort) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } header: {
                Text("Quality")
            } footer: {
                if cloud.chosenModel != nil, let resolved = cloud.resolved, let cost = CloudCost.perHour(cloud.costPerHour(resolved)) {
                    Text("\(resolved.model.name): \(cost.prefix(1).lowercased() + cost.dropFirst())\(resolved.model.priceIsEstimated ? " (estimated price)" : "")")
                }
            }
        }
    }

    /// A tier: its name, its recommended model and what an hour costs with it, and a checkmark when chosen.
    private func tierRow(_ tier: CloudTier) -> some View {
        let recommended = cloud.offers.recommended(tier)
        let chosen = cloud.preferences.tier == tier
        return Button { cloud.choose(tier) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CloudSettingsScreen.title(tier)).foregroundStyle(PhoneStyle.Ink.title)
                    if let recommended {
                        let cost = CloudCost.perHour(cloud.costPerHour(recommended)).map { " · \($0)" } ?? ""
                        Text(recommended.model.name + cost).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                    }
                }
                Spacer(minLength: 8)
                if chosen {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(PhoneStyle.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// One provider's key: added or replaced after the provider accepts it, or removed from every device.
struct CloudKeyScreen: View {
    let provider: CloudProvider
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var removing = false
    @State private var showingDetails = false

    init(provider: CloudProvider) {
        self.provider = provider
        #if DEBUG
        _text = State(initialValue: PhoneCloudDemo.typedKey ?? "")
        #else
        _text = State(initialValue: "")
        #endif
    }

    var body: some View {
        let cloud = model.cloudSummaries
        let saved = cloud.keys[provider]
        let checking = cloud.checks[provider] == .checking
        Form {
            if let saved {
                Section {
                    LabeledContent("Key", value: saved)
                }
            }
            Section {
                SecureField(saved == nil ? "Key" : "New Key", text: $text, prompt: Text(provider == .anthropic ? "sk-ant-…" : "sk-…"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(checking)
                    .onChange(of: text) { _, _ in cloud.clearCheck(for: provider) }
                    .onSubmit(add)
                Button(saved == nil ? "Add Key" : "Replace Key", action: add)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            } footer: {
                status(cloud.checks[provider])
            }
            if saved != nil {
                Section {
                    Button("Remove Key", role: .destructive) { removing = true }
                }
            }
        }
        .navigationTitle(CloudSettingsScreen.name(provider))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove the \(CloudSettingsScreen.name(provider)) key?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await cloud.removeKey(for: provider)
                    dismiss()
                }
            }
        } message: {
            Text("It’s removed from your other devices too.")
        }
    }

    @ViewBuilder private func status(_ check: CloudSetup.Check?) -> some View {
        switch check {
        case .checking?:
            HStack(spacing: 6) {
                ProgressView()
                Text("Checking…")
            }
        case .works?:
            Text("This key works")
        case .failed(let message, let details)?:
            VStack(alignment: .leading, spacing: 4) {
                Text(message).foregroundStyle(PhoneStyle.Ink.warning)
                if !details.isEmpty {
                    Button("Details") { showingDetails = true }
                        .buttonStyle(.borderless)
                        .pageSheet(isPresented: $showingDetails) { DetailsSheet(title: "Details", text: details) }
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func add() {
        let cloud = model.cloudSummaries
        guard cloud.checks[provider] != .checking, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await cloud.addKey(text, for: provider) {
                text = ""
                dismiss()
            }
        }
    }
}

#if DEBUG
/// `--cloud-demo none|anthropic|both|never|failed`: Settings › Cloud with in-memory keys and the catalog's models, never
/// reaching a provider or the keychain. `failed` opens Anthropic's key with a key the provider refused.
enum PhoneCloudDemo {
    static let state = LaunchOptions.value(after: "--cloud-demo", in: CommandLine.arguments)

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

    static var typedKey: String? { state == "failed" ? "sk-ant-api03-pasted-key" : nil }
}
#endif
