import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI

// MARK: - Cloud pane

/// Settings › Cloud (docs/cloud.md, "Settings"): DaybookUI's `CloudSettingsForm`, which the iPhone's Settings › Cloud
/// shows too, with the key editor in a 420 pt sheet. Preferences are this Mac's own; keys are in iCloud Keychain,
/// shared with the iPhone.
struct CloudSettings: View {
    let cloud: CloudSetup
    @State private var editing: KeyEditing?

    /// The provider whose key the sheet adds, replaces, or removes.
    struct KeyEditing: Identifiable {
        let provider: CloudProvider
        var id: String { provider.rawValue }
    }

    init(state: AppState) { cloud = state.cloud }

    var body: some View {
        Form {
            CloudSettingsForm(cloud: cloud) { editing = KeyEditing(provider: $0) }
        }
        .formStyle(.grouped)
        .task {
            await cloud.refresh()
            #if DEBUG
            editing = CloudSettingsDemo.sheet.map(KeyEditing.init(provider:))
            #endif
        }
        .sheet(item: $editing) { editing in
            CloudKeyEditor(cloud: cloud, provider: editing.provider, typed: typed) { self.editing = nil }
        }
    }

    private var typed: String {
        #if DEBUG
        CloudSettingsDemo.typedKey ?? ""
        #else
        ""
        #endif
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
