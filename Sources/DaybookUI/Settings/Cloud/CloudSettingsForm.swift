import DaybookDesign
import DaybookKit
import SwiftUI

// Settings › Cloud, the same on both apps (docs/cloud.md, "Settings"): each provider's key, then, once there is one,
// when summaries use the cloud, the tier with what an hour costs, Recommended or a model, and effort. Labels are in
// sentence case on the Mac and title case on the iPhone (`SettingsWords.titleCased`).

/// Settings › Cloud's sections. Each app hosts them in its own form and presents the key editor (`CloudKeyEditor`)
/// its own way: the Mac's 420 pt sheet, the iPhone's page sheet.
public struct CloudSettingsForm: View {
    private let cloud: CloudSetup
    private let edit: @MainActor (CloudProvider) -> Void
    @State private var removing: CloudProvider?

    /// - Parameter edit: Opens the key editor for a provider.
    public init(cloud: CloudSetup, edit: @escaping @MainActor (CloudProvider) -> Void) {
        self.cloud = cloud
        self.edit = edit
    }

    public var body: some View {
        Section {
            ForEach(CloudProvider.allCases, id: \.self) { provider in
                CloudKeyRow(cloud: cloud, provider: provider, edit: { edit(provider) }, remove: { removing = provider })
            }
        } header: {
            Text("Keys")
        } footer: {
            SettingsFooter(CloudSettingsForm.footer)
        }
        .cloudKeyRemoval($removing, cloud: cloud)
        if cloud.isSetUp {
            CloudSummarySections(cloud: cloud)
        }
    }

    /// The pane's one footer line.
    public static let footer = "Sends the transcript, notes, and vocabulary, never audio."

    /// Removing a key: what it means for the other devices.
    public static let removalMessage = "It’s removed from your other devices too."

    public static func removalTitle(_ provider: CloudProvider) -> String { "Remove the \(SettingsWords.provider(provider)) key?" }
}

/// A provider's key. Where the row has the room (the Mac's 600 pt pane), its masked key and "This key works" over
/// Replace… and Remove… beside it, or Add Key…; else its name with the masked key or "Add Key", opening the editor,
/// where Remove Key… is.
public struct CloudKeyRow: View {
    private let cloud: CloudSetup
    private let provider: CloudProvider
    private let edit: @MainActor () -> Void
    private let remove: @MainActor () -> Void
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(cloud: CloudSetup, provider: CloudProvider, edit: @escaping @MainActor () -> Void, remove: @escaping @MainActor () -> Void) {
        self.cloud = cloud
        self.provider = provider
        self.edit = edit
        self.remove = remove
    }

    private var masked: String? { cloud.keys[provider] }

    /// Under the name: the masked key, and whether it was just checked.
    private var keyLine: String? {
        guard let masked else { return nil }
        return cloud.checks[provider] == .works ? "\(masked) · This key works" : masked
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            if density != .touch { wide }
            compact
        }
    }

    /// The Mac's row: what the key is, and its actions beside it.
    private var wide: some View {
        HStack(alignment: .center, spacing: DaybookSpacing.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsWords.provider(provider)).foregroundStyle(.primary)
                if let keyLine {
                    Text(keyLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            .fixedSize()
            Spacer(minLength: DaybookSpacing.s4)
            HStack(spacing: DaybookSpacing.s2) {
                if masked != nil {
                    Button("Replace…", action: edit)
                    Button("Remove…", action: remove)
                } else {
                    Button("Add Key…", action: edit)
                }
            }
            .fixedSize()
        }
    }

    /// The compact row: the name with its key or "Add Key", the whole row opening the editor. The name stays whole: the
    /// key gives way first, and at the accessibility sizes it goes under the name.
    private var compact: some View {
        Button(action: edit) {
            HStack(spacing: DaybookSpacing.s2) {
                let stacked = typeSize.isAccessibilitySize
                let layout = stacked
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(spacing: DaybookSpacing.s2))
                layout {
                    Text(SettingsWords.provider(provider)).foregroundStyle(DaybookPalette.Ink.title)
                        .lineLimit(1)
                        .fixedSize(horizontal: !stacked, vertical: false)
                        .layoutPriority(1)
                    if !stacked { Spacer(minLength: DaybookSpacing.s2) }
                    Text(masked ?? "Add Key")
                        .foregroundStyle(masked == nil ? DaybookPalette.Ink.link : DaybookPalette.Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if stacked { Spacer(minLength: DaybookSpacing.s2) }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(masked == nil ? "Adds a key" : "Replaces or removes the key")
    }
}

/// Adds, replaces, or removes a provider's key. A key is checked with the provider before it's kept; a refused one
/// is a ProblemLine. Leaving the editor, even while a key is being checked, keeps nothing it didn't keep already and
/// forgets a refusal, so none stays under an empty field.
public struct CloudKeyEditor: View {
    private let cloud: CloudSetup
    private let provider: CloudProvider
    private let done: @MainActor () -> Void
    @State private var text: String
    @State private var removing: CloudProvider?
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - typed: What's in the field when it opens (the demos' refused key).
    ///   - done: Closes the editor: after Cancel, a key kept, or one removed.
    public init(cloud: CloudSetup, provider: CloudProvider, typed: String = "", done: @escaping @MainActor () -> Void) {
        self.cloud = cloud
        self.provider = provider
        self.done = done
        _text = State(initialValue: typed)
    }

    private var replacing: Bool { cloud.keys[provider] != nil }
    private var checking: Bool { cloud.checks[provider] == .checking }
    private var typed: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var body: some View {
        SettingsFormSheet(title: "\(replacing ? "Replace" : "Add") \(SettingsWords.provider(provider)) Key",
                          cancel: .init("Cancel", perform: done),
                          confirm: .init(replacing ? "Replace" : "Add", isEnabled: typed && !checking, perform: add)) {
            Section {
                SecureField(density == .touch ? (replacing ? "New Key" : "Key") : "Key", text: $text,
                            prompt: Text(provider == .anthropic ? "sk-ant-…" : "sk-…"))
                    .touchKeyboard(capitalization: .never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .onChange(of: text) { _, _ in cloud.clearCheck(for: provider) }
                    .disabled(checking)
                status
            }
            if replacing {
                Section {
                    Button("Remove Key…", role: .destructive) { removing = provider }
                        .disabled(checking)
                }
            }
        }
        .cloudKeyRemoval($removing, cloud: cloud) { done() }
        // Closed however it closes (Cancel, a swipe, Back): a check under way or refused goes with it.
        .onDisappear { Self.leave(cloud, provider) }
    }

    @ViewBuilder private var status: some View {
        switch cloud.checks[provider] {
        case .checking?:
            HStack(spacing: DaybookSpacing.s2) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .failed(let message, let details)?:
            ProblemLine(text: message, details: details.isEmpty ? nil : details)
        case .works?, nil:
            EmptyView()
        }
    }

    private func add() {
        guard !checking, typed else { return }
        Task {
            if await cloud.addKey(text, for: provider) {
                text = ""
                done()
            }
        }
    }

    /// Leaving the editor: a check under way is dropped, and a refusal isn't kept for a key that isn't there. A key
    /// just kept stays "This key works" on its row.
    @MainActor
    public static func leave(_ cloud: CloudSetup, _ provider: CloudProvider) {
        cloud.leaveCheck(for: provider)
    }
}

/// When summaries use the cloud, and which model: shown once a key is set.
public struct CloudSummarySections: View {
    @Bindable private var cloud: CloudSetup
    @Environment(\.daybookDensity) private var density

    public init(cloud: CloudSetup) { self.cloud = cloud }

    private func label(_ sentence: String) -> String { density == .touch ? SettingsWords.titleCased(sentence) : sentence }

    public var body: some View {
        Section("Summaries") {
            Picker(label("Use the cloud"), selection: $cloud.preferences.policy) {
                ForEach([CloudSummaryPreferences.Policy.ask, .always, .never], id: \.self) { policy in
                    Text(label(SettingsWords.policy(policy))).tag(policy)
                }
            }
            if cloud.preferences.policy == .ask {
                Picker(label("Countdown"), selection: $cloud.preferences.countdownSeconds) {
                    ForEach([15, 30], id: \.self) { seconds in Text(label(SettingsWords.seconds(seconds))).tag(seconds) }
                }
            }
        }
        if cloud.preferences.policy != .never {
            Section("Quality") {
                ForEach(CloudTier.allCases.filter { !cloud.offers(in: $0).isEmpty }, id: \.self) { tier in
                    CloudTierRow(cloud: cloud, tier: tier)
                }
                if cloud.offers.isEmpty {
                    Text(cloud.isRefreshing ? "Finding models…" : "No models").foregroundStyle(DaybookPalette.Ink.secondary)
                } else {
                    CloudModelPicker(cloud: cloud)
                    LabeledContent(label("Effort")) {
                        Picker(label("Effort"), selection: $cloud.preferences.effort) {
                            ForEach(cloud.efforts, id: \.self) { effort in Text(SettingsWords.effort(effort)).tag(effort) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }
}

/// A tier as a choice: a radio on the Mac and a checkmark on the iPhone, as each platform marks one; its name and its
/// recommended model; and what an hour of conversation costs with it, in a column of its own when there's room, else
/// under the model.
public struct CloudTierRow: View {
    private let cloud: CloudSetup
    private let tier: CloudTier

    public init(cloud: CloudSetup, tier: CloudTier) {
        self.cloud = cloud
        self.tier = tier
    }

    public var body: some View {
        let chosen = cloud.preferences.tier == tier
        let recommended = cloud.offers.recommended(tier)
        let cost = recommended.flatMap { CloudCost.perHour(cloud.costPerHour($0)) }
        Button { cloud.choose(tier) } label: {
            HStack(alignment: .center, spacing: DaybookSpacing.s3) {
                #if os(macOS)
                CloudTierRadio(isOn: chosen)
                #endif
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DaybookSpacing.s2) {
                        names(recommended)
                        Spacer(minLength: DaybookSpacing.s2)
                        if let cost {
                            Text(cost).font(.subheadline).foregroundStyle(DaybookPalette.Ink.secondary).monospacedDigit().fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        names(recommended)
                        if let cost { Text(cost).font(.footnote).foregroundStyle(DaybookPalette.Ink.secondary).monospacedDigit() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                #if os(iOS)
                if chosen {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(DaybookPalette.accent)
                } else {
                    Image(systemName: "checkmark").fontWeight(.semibold).hidden()
                }
                #endif
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
    }

    private func names(_ recommended: CloudOffer?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SettingsWords.tier(tier)).foregroundStyle(DaybookPalette.Ink.title)
            if let recommended {
                Text(recommended.model.name).font(.subheadline).foregroundStyle(DaybookPalette.Ink.secondary).lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

#if os(macOS)
/// A radio as the Mac's grouped forms draw one: filled with the prominent fill when chosen.
private struct CloudTierRadio: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().fill(isOn ? DaybookPalette.prominentFill : Color(nsColor: .controlColor))
            if isOn {
                Circle().fill(.white).frame(width: 6, height: 6)
            } else {
                Circle().strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}
#endif

/// Recommended or one of the tier's models; a chosen model's cost under it (the tier's row already says what its
/// recommendation costs). Where the row is narrow (the iPhone), the choice beside the label is "Recommended" or the
/// model's name, as the tier's row above says which model Recommended is.
public struct CloudModelPicker: View {
    private let cloud: CloudSetup
    @Environment(\.daybookDensity) private var density

    public init(cloud: CloudSetup) { self.cloud = cloud }

    /// "Recommended (Claude Sonnet 5.5)".
    public static func recommendedTitle(_ offer: CloudOffer?) -> String {
        offer.map { "Recommended (\($0.model.name))" } ?? "Recommended"
    }

    /// The choice beside the label on the iPhone: "Recommended", or the chosen model's name ("Claude Opus 5.5").
    public static func currentTitle(_ cloud: CloudSetup) -> String {
        cloud.chosenModel.flatMap { id in cloud.offers.first { $0.id == id }?.model.name } ?? "Recommended"
    }

    /// A chosen model's cost: "About $0.32 an hour", with "estimated price" where its price is a guess.
    public static func chosenCost(_ cloud: CloudSetup) -> String? {
        guard cloud.chosenModel != nil, let resolved = cloud.resolved, let cost = CloudCost.perHour(cloud.costPerHour(resolved)) else { return nil }
        return resolved.model.priceIsEstimated ? "\(cost) · estimated price" : cost
    }

    public var body: some View {
        #if os(macOS)
        LabeledContent {
            picker.labelsHidden().fixedSize()
        } label: {
            label
        }
        #else
        // The choice beside the label, never under it: a short one, as the list's picker row doesn't shorten a long
        // one but puts it under the label. The label wraps its cost before it gives up room.
        HStack(spacing: DaybookSpacing.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model").foregroundStyle(DaybookPalette.Ink.title)
                if let cost = Self.chosenCost(cloud) {
                    Text(cost).font(.subheadline).foregroundStyle(DaybookPalette.Ink.secondary)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Picker(selection: selection) {
                choices
            } label: {
                label
            } currentValueLabel: {
                Text(Self.currentTitle(cloud)).lineLimit(1)
            }
            .labelsHidden()
        }
        #endif
    }

    private var selection: Binding<CloudModel.ID?> { Binding(get: { cloud.chosenModel }, set: { cloud.chosenModel = $0 }) }

    @ViewBuilder private var choices: some View {
        Text(Self.recommendedTitle(cloud.offers.recommended(cloud.preferences.tier))).tag(String?.none)
        Divider()
        ForEach(cloud.offers(in: cloud.preferences.tier)) { offer in
            Text(offer.model.name).tag(Optional(offer.id))
        }
    }

    private var picker: some View {
        Picker(selection: selection) { choices } label: { label }
    }

    @ViewBuilder private var label: some View {
        Text("Model")
        if let cost = Self.chosenCost(cloud) { Text(cost) }
    }
}

extension View {
    /// Asks before a key is removed: an alert on the Mac, a confirmation dialog on the iPhone. `removed` follows once
    /// it's gone.
    fileprivate func cloudKeyRemoval(_ provider: Binding<CloudProvider?>, cloud: CloudSetup,
                                     removed: @escaping @MainActor () -> Void = {}) -> some View {
        let shown = Binding(get: { provider.wrappedValue != nil }, set: { if !$0 { provider.wrappedValue = nil } })
        let presenting = provider.wrappedValue
        let title = presenting.map(CloudSettingsForm.removalTitle) ?? ""
        #if os(macOS)
        return alert(title, isPresented: shown, presenting: presenting) { provider in
            Button("Remove", role: .destructive) { Task { await cloud.removeKey(for: provider); removed() } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(CloudSettingsForm.removalMessage)
        }
        #else
        return confirmationDialog(title, isPresented: shown, titleVisibility: .visible, presenting: presenting) { provider in
            Button("Remove", role: .destructive) { Task { await cloud.removeKey(for: provider); removed() } }
        } message: { _ in
            Text(CloudSettingsForm.removalMessage)
        }
        #endif
    }
}
