import AppKit
import DaybookIntelligence
import DaybookKit
import SwiftUI

// The model manager's parts: preset rows, role choices, library rows, and a model's details.
// Everything reads `ModelManagerSnapshot`, so new engines, families, and roles render here as is.

// MARK: - Small parts

/// A fact about a model in a quiet capsule: "Non-commercial", "Added by you", "Recommended".
struct ModelLabelChip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(DaybookStyle.quietFill, in: Capsule())
    }
}

/// The radio Welcome and Settings draw for Quick, Balanced, and Detailed.
struct PresetRadio: View {
    let isOn: Bool
    var body: some View {
        ZStack {
            Circle().fill(isOn ? DaybookStyle.prominentFill : Color(nsColor: .controlColor))
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

/// A pop-up of models: each item's title is the model, its subtitle the state ("Downloaded",
/// "1.6 GB", "Needs a newer Daybook"); models that can't run here are listed last, disabled.
struct ModelPopUpButton: NSViewRepresentable {
    let options: [ModelOption]
    let selection: String?
    let title: String
    let select: (String) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.select = select
        // Items are updated in place when the same models are listed, so an open menu isn't
        // replaced while a download's progress changes their state.
        let keys = options.map(\.key)
        if context.coordinator.keys == keys, let menu = button.menu {
            for item in menu.items {
                guard let key = item.representedObject as? String, let option = options.first(where: { $0.key == key }) else { continue }
                if item.title != option.name { item.title = option.name }
                if item.subtitle != option.detail { item.subtitle = option.detail }
                if item.isEnabled != option.isEnabled { item.isEnabled = option.isEnabled }
            }
        } else {
            let menu = NSMenu()
            menu.autoenablesItems = false
            var separated = false
            for option in options {
                if !option.isEnabled, !separated, option.key != selection, menu.items.contains(where: \.isEnabled) {
                    menu.addItem(.separator())
                    separated = true
                }
                let item = NSMenuItem(title: option.name, action: nil, keyEquivalent: "")
                item.subtitle = option.detail
                item.representedObject = option.key
                item.isEnabled = option.isEnabled
                menu.addItem(item)
            }
            button.menu = menu
            context.coordinator.keys = keys
        }
        button.isEnabled = isEnabled
        if let item = button.menu?.items.first(where: { ($0.representedObject as? String) == selection }), button.selectedItem !== item {
            button.select(item)
        }
        button.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    final class Coordinator: NSObject {
        var select: (String) -> Void = { _ in }
        var keys: [String] = []
        @objc func changed(_ sender: NSPopUpButton) {
            if let key = sender.selectedItem?.representedObject as? String { select(key) }
        }
    }
}

// MARK: - Presets

/// Quick, Balanced, or Detailed: its models, total download, and memory, with this Mac's recommendation.
struct ModelPresetRow: View {
    let summary: ModelPresetSummary
    let choose: () -> Void

    var body: some View {
        // Custom isn't something to choose: it's what the choices below add up to.
        if summary.preset == nil {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: choose) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(summary.isCurrent ? [.isSelected, .isButton] : .isButton)
                .accessibilityHint(summary.isRecommended ? "Recommended for this Mac" : "")
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: Space.s3) {
            PresetRadio(isOn: summary.isCurrent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.title).foregroundStyle(.primary)
                    if summary.isRecommended { ModelLabelChip("Recommended") }
                }
                Text(summary.names.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Space.s2)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ModelSize.format(summary.bytes)).monospacedDigit()
                Text("\(summary.memoryGB) GB memory").font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }
}

// MARK: - Role choices

/// One role's model: a pop-up, and, when the chosen model isn't ready, its state and what to do.
struct ModelChoiceRow: View {
    @ObservedObject var manager: ModelManager
    let choice: ModelRoleChoice
    let label: String

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.s2) {
                action
                ModelPopUpButton(options: choice.options, selection: choice.selection, title: "\(choice.title) model") { key in
                    manager.use(key, for: choice.role)
                }
                .fixedSize()
            }
        } label: {
            Text(label)
            if let line { Text(line).foregroundStyle(isWarning ? Ink.warning : .secondary) }
        }
    }

    /// Silent when the chosen model is ready.
    private var line: String? {
        guard let status = choice.status else { return choice.selection == nil ? "Choose a model" : "No longer available" }
        switch status {
        case .notDownloaded: return "Not downloaded · \(ModelSize.format(choice.selectedModel?.approximateBytes ?? 0))"
        case .damaged, .waiting, .downloading, .unavailable: return status.label
        default: return nil
        }
    }

    private var isWarning: Bool {
        switch choice.status {
        case .damaged?, .unavailable?: return true
        default: return choice.status == nil && choice.selection != nil
        }
    }

    @ViewBuilder private var action: some View {
        if let key = choice.selectedModel?.key {
            switch choice.status {
            case .notDownloaded?, .damaged?:
                Button("Download") { manager.download(key) }
            case .downloading?:
                Button("Cancel") { manager.cancelDownloads() }
            case .waiting?:
                Button("Cancel") { manager.cancelWaiting(key) }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Library

/// One model in the library: name and labels, maker, size and state, and what can be done.
struct ModelLibraryRow: View {
    @ObservedObject var manager: ModelManager
    let row: ModelRow
    let showDetails: () -> Void
    let remove: (ModelRemoval) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1).truncationMode(.tail)
                    ForEach(row.labels, id: \.self) { ModelLabelChip($0) }
                }
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            primaryAction
            moreMenu
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
    }

    private var statusLine: some View {
        HStack(spacing: 0) {
            Text(row.subtitle.isEmpty ? "" : row.subtitle + " · ").foregroundStyle(.secondary)
            if row.status == .inUse {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.link).imageScale(.small).padding(.trailing, 3)
            }
            Text(row.status.label)
                .foregroundStyle(statusColor)
                .monospacedDigit()
        }
        .font(.subheadline)
        .lineLimit(1)
    }

    private var statusColor: Color {
        switch row.status {
        case .inUse, .updateAvailable: return Ink.link
        case .damaged: return Ink.warning
        default: return .secondary
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch row.status {
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.brand(width: 72))
                .accessibilityLabel("Downloading \(row.name)")
            Button { manager.cancelDownloads() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel Download")
                .accessibilityLabel("Cancel download")
        case .waiting:
            Button("Cancel") { manager.cancelWaiting(row.id) }
        case .notDownloaded, .damaged:
            Button("Download") { manager.download(row.id) }
        case .updateAvailable:
            if let update = row.update { Button("Update") { Task { await manager.install(update) } } }
        case .downloaded, .builtIn:
            if row.canUse { useButton }
        case .inUse, .unavailable:
            EmptyView()
        }
    }

    @ViewBuilder private var useButton: some View {
        if row.usableRoles.count == 1, let role = row.usableRoles.first {
            Button("Use") { manager.use(row.id, for: role) }
                .help("Use for \(role.title)")
        } else {
            Menu("Use") {
                ForEach(row.usableRoles, id: \.self) { role in
                    Button("For \(role.title)") { manager.use(row.id, for: role) }
                }
            }
            .fixedSize()
        }
    }

    private var moreMenu: some View {
        Menu { menuItems } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More for \(row.name)")
    }

    @ViewBuilder private var menuItems: some View {
        Button("Details…", action: showDetails)
        if row.canUse {
            Divider()
            ForEach(row.usableRoles, id: \.self) { role in
                Button("Use for \(role.title)") { manager.use(row.id, for: role) }
            }
        }
        if row.canDownload {
            Button("Download") { manager.download(row.id) }
        }
        if let update = row.update, row.status == .updateAvailable {
            Button("Install Update") { Task { await manager.install(update) } }
        }
        if row.canRemove || row.isAddedByYou {
            Divider()
            if row.canRemove {
                Button(row.isAddedByYou ? "Remove Download…" : "Remove…") {
                    if let removal = manager.removal(of: row.id) { remove(removal) }
                }
                .disabled(!manager.canChangeFiles)
            }
            if row.isAddedByYou {
                Button("Remove from Daybook…") {
                    if let removal = manager.removal(of: row.id, removesEntry: true) { remove(removal) }
                }
                .disabled(!manager.canChangeFiles)
            }
        }
    }
}

/// An update the last check found: what changed, its size and date, and Install.
struct ModelUpdateRow: View {
    @ObservedObject var manager: ModelManager
    let update: ModelUpdate

    var body: some View {
        LabeledContent {
            Button("Install") { Task { await manager.install(update) } }
        } label: {
            Text(update.name)
            Text(Self.detail(update)).monospacedDigit()
        }
    }

    /// "489 MB · Oct 20, 2026 · 3 files changed".
    static func detail(_ update: ModelUpdate) -> String {
        let changed = update.changedFiles.count == 1 ? "1 file changed" : "\(update.changedFiles.count) files changed"
        return [ModelSize.format(update.downloadBytes), update.publishedAt.map { $0.formatted(date: .abbreviated, time: .omitted) }, changed]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Removal

extension View {
    /// Confirms a removal with its consequence, then carries it out.
    func modelRemovalAlert(_ removal: Binding<ModelRemoval?>, manager: ModelManager) -> some View {
        alert(removal.wrappedValue?.title ?? "", isPresented: Binding(get: { removal.wrappedValue != nil }, set: { if !$0 { removal.wrappedValue = nil } }),
              presenting: removal.wrappedValue) { value in
            Button("Remove", role: .destructive) { Task { await manager.confirm(value) } }
            Button("Cancel", role: .cancel) {}
        } message: { value in
            Text(value.message)
        }
    }
}

// MARK: - Details

/// A model's details: what it is, its license and credit, what it can do, what's on this Mac, and
/// how many conversations it made results for.
struct ModelDetailsSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject var manager: ModelManager
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var removal: ModelRemoval?

    var body: some View {
        let snapshot = manager.snapshot
        VStack(spacing: 0) {
            if let model = snapshot.catalog.model(key) {
                let row = snapshot.row(model)
                header(model, row: row)
                // What it is and its terms, then what's on this Mac, which the buttons below act on.
                Form {
                    about(model, row: row, snapshot: snapshot)
                    license(model)
                    onThisMac(model, row: row, snapshot: snapshot)
                }
                .formStyle(.grouped)
                footer(row)
            } else {
                Text("This model is no longer listed.").foregroundStyle(.secondary).padding(Space.s6)
                footer(nil)
            }
        }
        .frame(width: 500)
        .frame(minHeight: 420, idealHeight: 720, maxHeight: 760)
        .modelRemovalAlert($removal, manager: manager)
        .onChange(of: state.modelCatalog.model(key) == nil) { _, gone in if gone { dismiss() } }
    }

    private func header(_ model: CatalogModel, row: ModelRow) -> some View {
        HStack(alignment: .top, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(model.name).font(.title3.weight(.semibold))
                if let maker = model.maker { Text(maker).foregroundStyle(.secondary) }
            }
            Spacer(minLength: Space.s3)
            HStack(spacing: 6) { ForEach(row.labels, id: \.self) { ModelLabelChip($0) } }
                .padding(.top, 3)
        }
        .padding(.horizontal, Space.s5)
        .padding(.top, Space.s5)
        .padding(.bottom, Space.s1)
    }

    @ViewBuilder private func about(_ model: CatalogModel, row: ModelRow, snapshot: ModelManagerSnapshot) -> some View {
        Section {
            if let family = Self.unnamedFamily(model) { LabeledContent("Family", value: family) }
            if let released = Self.date(model.variant.releaseDate) { LabeledContent("Released", value: released) }
            LabeledContent("Used for", value: model.roles.isEmpty ? "Nothing" : model.roles.map(\.title).joined(separator: ", "))
            LabeledContent("Size", value: model.isSystemModel ? "Included with macOS" : ModelSize.format(model.approximateBytes))
            LabeledContent("Memory", value: "\(model.recommendedMemoryGB) GB or more")
            if !model.capabilities.descriptions.isEmpty {
                LabeledContent("Capabilities") {
                    Text(model.capabilities.descriptions.joined(separator: ", ")).multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Results", value: Self.results(snapshot.resultCounts[model.key] ?? 0))
        }
    }

    /// The license, its credit, and where the model comes from. "Non-commercial" is the chip in the header.
    @ViewBuilder private func license(_ model: CatalogModel) -> some View {
        Section {
            if let license = model.license {
                LabeledContent("License") {
                    if let url = URL(string: license.url), !license.url.isEmpty {
                        Link(license.name, destination: url).buttonStyle(.daybookLink)
                    } else {
                        Text(license.name)
                    }
                }
                if let attribution = license.attribution {
                    Text(attribution)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LabeledContent("License", value: "Not stated")
            }
            if let homepage = model.homepage, let url = URL(string: homepage) {
                LabeledContent("Source") { Link(Self.host(homepage), destination: url).buttonStyle(.daybookLink) }
            } else if let repository = model.latestRevision?.artifacts.first?.repository,
                      let url = URL(string: "https://huggingface.co/\(repository)") {
                LabeledContent("Source") { Link(repository, destination: url).buttonStyle(.daybookLink) }
            }
        }
    }

    @ViewBuilder private func onThisMac(_ model: CatalogModel, row: ModelRow, snapshot: ModelManagerSnapshot) -> some View {
        let installed = model.isSystemModel ? [] : snapshot.inventory.revisions(of: model.key)
        let current = snapshot.inventory.resolve(model.key)?.key
        Section("On This Mac") {
            LabeledContent("Status") {
                Text(row.status.label).monospacedDigit()
            }
            if !row.selectedRoles.isEmpty {
                LabeledContent("Chosen for", value: row.selectedRoles.map(\.title).joined(separator: ", "))
            }
            ForEach(installed, id: \.key) { revision in
                LabeledContent {
                    Text(ModelSize.format(snapshot.diskUsage?.installed[revision.key] ?? revision.bytes)).monospacedDigit()
                } label: {
                    Text("Revision \(revision.key.revision.prefix(7))").monospacedDigit()
                    Text(Self.revisionDetail(revision, current: revision.key == current))
                }
            }
            if let update = row.update {
                LabeledContent {
                    Button("Install") { Task { await manager.install(update) } }
                } label: {
                    Text("Revision \(update.revision.id.prefix(7))").monospacedDigit()
                    Text("Update · \(ModelUpdateRow.detail(update))").monospacedDigit()
                }
            }
        }
    }

    private func footer(_ row: ModelRow?) -> some View {
        HStack(spacing: Space.s2) {
            if let row, row.canRemove {
                Button(row.isAddedByYou ? "Remove Download…" : "Remove…", role: .destructive) { removal = manager.removal(of: row.id) }
                    .disabled(!manager.canChangeFiles)
                    .help(manager.canChangeFiles ? "" : ModelSettings.busyHelp)
            }
            if let row, row.isAddedByYou {
                Button("Remove from Daybook…", role: .destructive) { removal = manager.removal(of: row.id, removesEntry: true) }
                    .disabled(!manager.canChangeFiles)
                    .help(manager.canChangeFiles ? "" : ModelSettings.busyHelp)
            }
            Spacer()
            if let row {
                if row.canDownload { Button("Download") { manager.download(row.id) } }
                if row.canUse, let role = row.usableRoles.first {
                    Button(row.usableRoles.count == 1 ? "Use" : "Use for \(role.title)") { manager.use(row.id, for: role) }
                }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s4)
    }

    // MARK: Words

    /// The family, when the title doesn't already say it: nothing for "Parakeet Ultra" or "Qwen 2.5 · 7B", but
    /// "Nemotron 3 Diarization" for "Nemotron 3 Speaker Detection". The title says the variant either way.
    static func unnamedFamily(_ model: CatalogModel) -> String? {
        model.name.hasPrefix(model.familyName) ? nil : model.familyName
    }

    static func date(_ text: String?) -> String? {
        guard let text else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: text) else { return text }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!))
    }

    static func results(_ count: Int) -> String {
        switch count {
        case 0: return "No conversations yet"
        case 1: return "1 conversation"
        default: return "\(count) conversations"
        }
    }

    static func host(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host() else { return link }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host.replacingOccurrences(of: "www.", with: ""))/\(path)"
    }

    /// "Published Aug 19, 2026 · downloaded Oct 2, 2026 · in use".
    static func revisionDetail(_ revision: InstalledModelRevision, current: Bool) -> String {
        var parts: [String] = []
        if let published = date(revision.installation.receipt.releaseDate) { parts.append("Published \(published)") }
        if revision.installation.receipt.installedAt > .distantPast.addingTimeInterval(86_400) {
            parts.append("downloaded \(revision.installation.receipt.installedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        if !revision.isReady { parts.append("needs downloading again") }
        else if current { parts.append("current") }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
