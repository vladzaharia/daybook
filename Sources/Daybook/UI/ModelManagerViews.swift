import AppKit
import DaybookIntelligence
import DaybookKit
import DaybookUI
import SwiftUI

// The Mac model manager's own parts: a library row's actions, an update, removal, and a model's details. The rows both
// apps draw (a role's model, a model in the library, the download row, a quality preset) are DaybookUI's, and
// everything reads `ModelManagerSnapshot`, so new engines, families, and roles render here as is.

/// DaybookUI's, for Welcome, Cloud, and Acknowledgements.
typealias ModelLabelChip = DaybookUI.ModelLabelChip
typealias PresetRadio = DaybookUI.PresetRadio

extension ModelManager {
    /// What a role's row does here: choose through the app's selections, download through its queue, cancel either.
    func rowActions(for role: ModelRole) -> ModelRowActions {
        ModelRowActions(select: { [weak self] key in self?.use(key, for: role) },
                        download: { [weak self] in self?.download($0) },
                        cancel: { [weak self] in self?.cancel($0) })
    }
}

// MARK: - Library

/// One model in the library (DaybookUI's `ModelListRow`), with what the Mac can do with it: Download, Use, Update, and
/// More (Details, Use for a role, Remove).
struct ModelLibraryRow: View {
    let manager: ModelManager
    let row: ModelRow
    let showDetails: () -> Void
    let remove: (ModelRemoval) -> Void

    var body: some View {
        ModelListRow(name: row.name, labels: row.labels, detail: row.subtitle, status: row.status, note: spaceNote) {
            HStack(spacing: Space.s2) {
                primaryAction
                moreMenu
            }
        }
        .contextMenu { menuItems }
    }

    /// Why Download waits, where the state would be: "Needs 1.6 GB · 300 MB free".
    private var spaceNote: ModelLine? { manager.snapshot.spaceNote(for: row.model) }

    @ViewBuilder private var primaryAction: some View {
        switch row.status {
        case .downloading:
            Button { manager.cancelDownloads() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel Download")
                .accessibilityLabel("Cancel download")
        case .waiting, .waitingForWiFi:
            Button("Cancel") { manager.cancelWaiting(row.id) }
        case .notDownloaded, .damaged, .failed:
            Button("Download") { manager.download(row.id) }
                .disabled(spaceNote != nil)
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
                .help("Use for \(role.displayName)")
        } else {
            Menu("Use") {
                ForEach(row.usableRoles, id: \.self) { role in
                    Button("For \(role.displayName)") { manager.use(row.id, for: role) }
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
                Button("Use for \(role.displayName)") { manager.use(row.id, for: role) }
            }
        }
        if row.canDownload {
            Button("Download") { manager.download(row.id) }
                .disabled(spaceNote != nil)
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
    let manager: ModelManager
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
    let state: AppState
    let manager: ModelManager
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
            LabeledContent("Used for", value: model.roles.isEmpty ? "Nothing" : model.roles.map(\.displayName).joined(separator: ", "))
            LabeledContent("Size", value: model.isSystemModel ? ModelStatus.builtIn.label : ModelSize.format(model.approximateBytes))
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
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.status.label).monospacedDigit()
                    // Why Download waits.
                    if let note = snapshot.spaceNote(for: model) {
                        Text(note.text).foregroundStyle(Ink.warning).monospacedDigit()
                    }
                }
            }
            if !row.selectedRoles.isEmpty {
                LabeledContent("Chosen for", value: row.selectedRoles.map(\.displayName).joined(separator: ", "))
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
                if row.canDownload {
                    Button("Download") { manager.download(row.id) }
                        .disabled(manager.snapshot.spaceNote(for: row.model) != nil)
                }
                if row.canUse, let role = row.usableRoles.first {
                    Button(row.usableRoles.count == 1 ? "Use" : "Use for \(role.displayName)") { manager.use(row.id, for: role) }
                }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s4)
        .background {
            // Esc closes it, as Cancel would: a sheet with only a Return button stays open otherwise.
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
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
        parser.timeZone = TimeZone.gmt
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: text) else { return text }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone.gmt))
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
