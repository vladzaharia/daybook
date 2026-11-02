import DaybookKit
import DaybookUI
import SwiftUI

/// Settings › Cloud (docs/cloud.md, "Settings"): DaybookUI's `CloudSettingsForm`, which the Mac's Settings › Cloud shows
/// too, with the key editor in a page sheet. The preferences are this iPhone's own; keys are in iCloud Keychain,
/// shared with the Mac.
struct CloudSettingsScreen: View {
    @Environment(PhoneAppModel.self) private var model
    @State private var editing: KeyEditing?

    /// The provider whose key the sheet adds, replaces, or removes.
    struct KeyEditing: Identifiable {
        let provider: CloudProvider
        var id: String { provider.rawValue }
    }

    var body: some View {
        let cloud = model.cloudSummaries
        Form {
            CloudSettingsForm(cloud: cloud) { editing = KeyEditing(provider: $0) }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("Cloud")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await cloud.refresh()
            #if DEBUG
            if editing == nil { editing = PhoneCloudDemo.sheet.map(KeyEditing.init(provider:)) }
            #endif
        }
        .pageSheet(item: $editing) { editing in
            CloudKeyEditor(cloud: cloud, provider: editing.provider, typed: Self.typed) { self.editing = nil }
        }
    }

    /// What the key field holds when it opens: the demos' refused key, else nothing.
    static var typed: String {
        #if DEBUG
        PhoneCloudDemo.typedKey ?? ""
        #else
        ""
        #endif
    }

    static func name(_ provider: CloudProvider) -> String { SettingsWords.provider(provider) }
    static func title(_ tier: CloudTier) -> String { SettingsWords.tier(tier) }
    static func title(_ effort: CloudEffort) -> String { SettingsWords.effort(effort) }
}

/// One provider's key, pushed (`SettingsRoute.cloudKey`): the same editor the Cloud screen opens in a sheet, with its
/// action in the bar and Back to leave.
struct CloudKeyScreen: View {
    let provider: CloudProvider
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CloudKeyEditor(cloud: model.cloudSummaries, provider: provider, typed: CloudSettingsScreen.typed) { dismiss() }
            .settingsFormPushed()
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

    /// The key editor `failed` opens over Settings › Cloud.
    static var sheet: CloudProvider? { state == "failed" ? .anthropic : nil }

    static var typedKey: String? { state == "failed" ? "sk-ant-api03-pasted-key" : nil }
}
#endif
