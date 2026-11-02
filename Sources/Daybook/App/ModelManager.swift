import AppKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation
import Observation

// The model manager (Settings › Models; docs/models.md, "The model manager"). Everything here is
// derived from the catalog, never from model IDs: roles from the catalog and the registered engines,
// models from `ModelCatalog.models(for:)`, availability from `CatalogModel.availability(engines:)`,
// labels from licenses and origins. A new engine, family, variant, or role appears without code here.

// MARK: - Roles

extension ModelRole {
    /// The roles in the pipeline's order, then any other role a newer manifest names.
    static func pipelineOrder(_ a: ModelRole, _ b: ModelRole) -> Bool {
        let oa = ModelManagerSnapshot.order(a), ob = ModelManagerSnapshot.order(b)
        return oa == ob ? a.rawValue < b.rawValue : oa < ob
    }
}

// MARK: - Rows

/// One model in the library.
struct ModelRow: Identifiable, Equatable {
    let model: CatalogModel
    let status: ModelStatus
    /// Roles whose current choice is this model.
    let selectedRoles: [ModelRole]
    /// Roles it could be chosen for here (roles Settings offers, not already choosing it).
    let usableRoles: [ModelRole]
    /// What it takes on disk now: installed revisions and any unfinished download.
    let bytesOnDisk: Int64
    let update: ModelUpdate?
    let labels: [String]

    var id: String { model.key }
    var name: String { model.name }
    var isAddedByYou: Bool { model.origin == .addedByYou }
    /// "OpenAI · 487 MB"; system models have no size.
    var subtitle: String {
        [model.maker, model.isSystemModel ? nil : ByteSize.format(model.approximateBytes)].compactMap { $0 }.joined(separator: " · ")
    }
    var canDownload: Bool { status.canDownload }
    var canRemove: Bool { !model.isSystemModel && bytesOnDisk > 0 && !status.isTransferring }
    var canUse: Bool { status.isReady && !usableRoles.isEmpty }
}

/// The models of one family, as the library groups them.
struct ModelFamilyGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let rows: [ModelRow]
}

/// Quick, Balanced, Detailed, or the person's own mix.
struct ModelPresetSummary: Identifiable, Equatable {
    /// Nil for Custom.
    let preset: ModelPreset?
    let isRecommended: Bool
    let isCurrent: Bool
    /// Its models, one per role, the ones that set the presets apart first (`ModelQualityOption.ordered`).
    let keys: [String]
    let names: [String]
    let bytes: Int64
    let memoryGB: Int
    /// What downloading it still takes on this Mac: its models that aren't here, less what unfinished downloads fetched.
    let missingBytes: Int64
    var id: String { preset?.rawValue ?? "custom" }
    var title: String { preset?.title ?? "Custom" }

    /// As DaybookUI's quality row draws it.
    var option: ModelQualityOption {
        ModelQualityOption(id: id, title: title, isCustom: preset == nil, isRecommended: isRecommended, isCurrent: isCurrent,
                           names: names, bytes: bytes, memoryGB: memoryGB)
    }
}

/// What the library takes on disk, and what can go.
struct ModelStorageSummary: Equatable {
    var total: Int64
    /// Revisions an update replaced that nothing protects any more.
    var removableRevisions: [ModelInstallKey]
    var removableRevisionBytes: Int64
    /// Folders from before the model system that couldn't be moved.
    var oldDownloadBytes: Int64
}

// MARK: - Snapshot

/// Everything the manager shows, computed from plain inputs: the catalog, the engines this build
/// registers, what's installed, the selections, and download and update state. No AppState, so
/// tests build it from a synthetic catalog.
struct ModelManagerSnapshot {
    var catalog: ModelCatalog
    var engines: [ModelEngineDescriptor]
    var appVersion: ModelVersion? = ModelVersion.app
    var platform: ModelPlatform = .current
    var tier: DeviceTier = .current
    /// Variant keys that can run now (verified installs, and system models this Mac has).
    var installed: Set<String> = []
    var inventory = ModelInventory(revisions: [])
    var diskUsage: ModelDiskUsage?
    var selections = ModelSelections()
    var speakerQuality: SpeakerQuality = .balanced
    /// The download in progress ("key" or "key@revision") and its fraction, and those waiting.
    var downloading: String?
    var downloadFraction: Double = 0
    var pending: [String] = []
    var updates: [ModelUpdate] = []
    /// Revisions nothing may remove: pinned, leased, or frozen by queued and running jobs.
    var protectedRevisions: Set<ModelInstallKey> = []
    var resultCounts: [String: Int] = [:]
    /// What's free where models go, as the system said at the last refresh.
    var freeSpace: ModelSpace = .unknown
    /// How far the download under way had got when `freeSpace` was read: what it had fetched by then is already out of it.
    var fetchedWhenRead: [String: Double] = [:]

    /// What's free for another download: `freeSpace`, less what the download under way and those waiting will still
    /// take. A download that wouldn't fit says so and waits.
    var space: ModelSpace { freeSpace.less(promisedBytes) }

    /// What the download under way and those waiting will still take.
    var promisedBytes: Int64 {
        Set(([downloading].compactMap { $0 } + pending).compactMap { catalog.model(ModelReference($0).id)?.key })
            .compactMap { catalog.model($0) }
            .reduce(0) { $0 + downloadBytes($1) }
    }

    /// Roles listed first, in the pipeline's order; any others after.
    static func order(_ role: ModelRole) -> Int { ModelRole.known.firstIndex(of: role) ?? ModelRole.known.count }

    private var downloadingKey: String? { downloading.map { ModelReference($0).id } }
    private var pendingKeys: Set<String> { Set(pending.map { ModelReference($0).id }) }

    func availability(_ model: CatalogModel) -> ModelAvailability {
        model.availability(engines: engines, appVersion: appVersion, platform: platform)
    }

    /// Updates found by the last check that aren't installed yet.
    var pendingUpdates: [ModelUpdate] {
        updates.filter { update in
            !inventory.revisions(of: update.model).contains { $0.key.revision == update.revision.id && $0.isReady }
        }
    }

    func update(for key: String) -> ModelUpdate? { pendingUpdates.first { $0.model == key } }

    func status(of model: CatalogModel) -> ModelStatus {
        let availability = availability(model)
        guard availability.isAvailable else { return .unavailable(availability.label ?? "Not available on this Mac") }
        let selected = selections.keys.values.contains(model.key)
        if model.isSystemModel {
            guard installed.contains(model.key) else { return .unavailable(ModelAvailability.unsupportedPlatform(platform).label ?? "") }
            return selected ? .inUse : .builtIn
        }
        if downloadingKey == model.key { return .downloading(downloadFraction) }
        if pendingKeys.contains(model.key) { return .waiting }
        if installed.contains(model.key) {
            if update(for: model.key) != nil { return .updateAvailable }
            return selected ? .inUse : .downloaded
        }
        if inventory.revisions(of: model.key).contains(where: { !$0.isReady }) { return .damaged }
        return .notDownloaded
    }

    /// "Non-commercial" and "Added by you", from the license and where the entry came from.
    func labels(_ model: CatalogModel) -> [String] { ModelLabels.of(model) }

    /// What downloading a model still takes: its size, less what an unfinished download had fetched when `freeSpace`
    /// was read.
    func downloadBytes(_ model: CatalogModel) -> Int64 {
        guard !model.isSystemModel else { return 0 }
        return ModelSpace.stillToFetch(model.approximateBytes, partial: diskUsage?.partial[model.key] ?? 0, fraction: fetchedWhenRead[model.key])
    }

    /// Why a model's Download waits, said in place of its state in the library and under it in Details: "Needs 632 MB ·
    /// 300 MB free". Nil when it fits, or there's nothing to download.
    func spaceNote(for model: CatalogModel) -> ModelLine? {
        guard status(of: model).canDownload else { return nil }
        return space.shortfall(downloadBytes(model)).map { ModelLine($0, needsAttention: true) }
    }

    /// What downloading these models still takes: those that aren't here or on their way (`promisedBytes` has those).
    func missingBytes(_ keys: [String]) -> Int64 {
        Set(keys).compactMap { catalog.model($0) }.filter { !installed.contains($0.key) && !status(of: $0).isTransferring }
            .reduce(0) { $0 + downloadBytes($1) }
    }

    // MARK: Role choices

    /// The roles Settings offers a choice for: the known roles, in order, then any other role a
    /// registered engine serves, each only when at least one model for it can run here (or is chosen).
    var choiceRoles: [ModelRole] {
        let served = Set(engines.flatMap(\.roles))
        let roles = Set(catalog.models.flatMap(\.roles)).filter { ModelRole.known.contains($0) || served.contains($0) }
        return roles.filter { role in
            let models = catalog.models(for: role)
            let runsHere = models.contains { status(of: $0).isAvailable }
            let chosen = selections[role] != nil && ModelRole.known.contains(role) && !models.isEmpty
            return runsHere || chosen
        }
        .sorted { Self.order($0) == Self.order($1) ? $0.displayName < $1.displayName : Self.order($0) < Self.order($1) }
    }

    var roleChoices: [ModelRoleChoice] { choiceRoles.map { choice(for: $0) } }

    /// `role`'s choice; `selection` for a choice that isn't the role's own (the model for other languages).
    func choice(for role: ModelRole, selection chosen: String? = nil, among models: [CatalogModel]? = nil) -> ModelRoleChoice {
        let selection = chosen ?? selections[role]
        var available: [ModelOption] = [], unavailable: [ModelOption] = []
        for model in models ?? catalog.models(for: role) {
            let status = status(of: model)
            let option = ModelOption(key: model.key, name: model.name, detail: ModelOption.detail(for: model, status: status),
                                     isEnabled: status.isAvailable)
            if status.isAvailable || model.key == selection { available.append(option) } else { unavailable.append(option) }
        }
        // A choice the catalog no longer lists stays visible, so nothing switches silently.
        if let selection, catalog.model(selection) == nil {
            available.insert(ModelOption(key: selection, name: catalog.name(for: selection), detail: "Not available", isEnabled: false), at: 0)
        }
        let model = selection.flatMap { catalog.model($0) }
        return ModelRoleChoice(role: role, selection: selection, options: available + unavailable, selectedModel: model,
                               status: model.map(status(of:)), downloadBytes: model.map(downloadBytes))
    }

    /// The models the processing choices download, each once, in the roles' order. Speaker detection's only while it's
    /// on; live captions' models are optional downloads, offered in their own rows; the system's own download nothing.
    func selectedModels(detectSpeakers: Bool) -> [CatalogModel] {
        var models: [CatalogModel] = []
        for role in choiceRoles where (role != .diarization || detectSpeakers) && !role.isLiveOnly {
            guard let key = selections[role], let model = catalog.model(key), !model.isSystemModel,
                  !models.contains(where: { $0.key == model.key }) else { continue }
            models.append(model)
        }
        return models
    }

    /// The models the choices need that aren't on this Mac and can be downloaded, in the roles' order.
    func missingSelected(detectSpeakers: Bool) -> [String] {
        selectedModels(detectSpeakers: detectSpeakers).filter { status(of: $0).canDownload }.map(\.key)
    }

    /// The models the choices need that are downloading or waiting their turn: what Processing's Cancel stops.
    func transferringSelected(detectSpeakers: Bool) -> [String] {
        selectedModels(detectSpeakers: detectSpeakers).filter { status(of: $0).isTransferring }.map(\.key)
    }

    /// What the processing choices still need: what to download, or, once all of it is asked for, how far it's got or
    /// that it waits its turn (DaybookKit's `ModelDownloadSummary`, as the iPhone's). Nil when it's all here.
    func downloadSummary(detectSpeakers: Bool) -> ModelDownloadSummary? {
        ModelDownloadSummary(chosen: selectedModels(detectSpeakers: detectSpeakers).map { model in
            ModelDownloadSummary.Item(name: ModelSize.shortName(model, in: catalog), status: status(of: model),
                                      bytes: model.approximateBytes, stillToFetch: downloadBytes(model))
        })
    }

    // MARK: Library

    /// Every model in the catalog, by family. Families follow the pipeline (the first role each
    /// serves), then their names; models keep their manifest order. A model that serves no role any
    /// more (Qwen 2.5 1.5B) is listed only while it's on this Mac, to be removed.
    var families: [ModelFamilyGroup] {
        var order: [String] = []
        var grouped: [String: [CatalogModel]] = [:]
        for model in catalog.models where !model.roles.isEmpty || bytesOnDisk(model) > 0 || status(of: model) != .notDownloaded {
            if grouped[model.familyID] == nil { order.append(model.familyID) }
            grouped[model.familyID, default: []].append(model)
        }
        func rank(_ id: String) -> Int { grouped[id]?.flatMap(\.roles).map(Self.order).min() ?? Int.max }
        let sorted = order.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b)
                : (grouped[a]?.first?.familyName ?? a).localizedCaseInsensitiveCompare(grouped[b]?.first?.familyName ?? b) == .orderedAscending
        }
        return sorted.map { id in
            ModelFamilyGroup(id: id, name: grouped[id]?.first?.familyName ?? id, rows: (grouped[id] ?? []).map(row))
        }
    }

    func row(_ model: CatalogModel) -> ModelRow {
        let status = status(of: model)
        let selected = selections.keys.filter { $0.value == model.key }.map { ModelRole($0.key) }
            .sorted { Self.order($0) == Self.order($1) ? $0.rawValue < $1.rawValue : Self.order($0) < Self.order($1) }
        let offered = Set(choiceRoles)
        let usable = model.roles.filter { offered.contains($0) && !selected.contains($0) }
        return ModelRow(model: model, status: status, selectedRoles: selected, usableRoles: usable,
                        bytesOnDisk: bytesOnDisk(model),
                        update: update(for: model.key), labels: labels(model))
    }

    func row(for key: String) -> ModelRow? { catalog.model(key).map(row) }

    /// What a model takes on disk: measured when known, else its size if it's installed.
    func bytesOnDisk(_ model: CatalogModel) -> Int64 {
        if model.isSystemModel { return 0 }
        let measured = diskUsage?.bytes(for: model.key) ?? 0
        return measured > 0 ? measured : (installed.contains(model.key) ? model.approximateBytes : 0)
    }

    // MARK: Presets

    /// Quick, Balanced, and Detailed, then Custom when the choices match none of them.
    var presets: [ModelPresetSummary] {
        let recommended = ModelPreset.recommended(tier: tier, catalog: catalog)
        let chosen = ModelPreset.allCases.map { $0.models(catalog: catalog, engines: engines) }
        // The roles whose model isn't the same in every preset: named first, so a row cut short still says what sets it apart.
        let roles = Set(chosen.flatMap(\.choices.keys))
        let differing = Set(roles.filter { role in Set(chosen.map { $0.model(for: role) ?? "" }).count > 1 })
        var summaries = zip(ModelPreset.allCases, chosen).map { preset, models -> ModelPresetSummary in
            summary(preset, choices: models.choices.keys.compactMap { role in models.model(for: role).map { (role, $0) } },
                    differing: differing, recommended: recommended,
                    current: preset.matches(selections, speakerQuality: speakerQuality, catalog: catalog, engines: engines))
        }
        if !summaries.contains(where: \.isCurrent) {
            // Live captions' models are optional downloads, not part of what processing needs.
            let choices = choiceRoles.filter { !$0.isLiveOnly }.compactMap { role in selections[role].map { (role, $0) } }
            summaries.append(summary(nil, choices: choices, differing: differing, recommended: recommended, current: true))
        }
        return summaries
    }

    private func summary(_ preset: ModelPreset?, choices: [(ModelRole, String)], differing: Set<ModelRole>, recommended: ModelPreset,
                         current: Bool) -> ModelPresetSummary {
        let byRole = Dictionary(choices, uniquingKeysWith: { first, _ in first })
        // A model with two roles (Community-1 finds speakers and makes voice profiles) is listed once.
        var seen = Set<String>()
        let keys = ModelQualityOption.ordered(Array(byRole.keys), differing: differing).compactMap { byRole[$0] }
            .filter { seen.insert($0).inserted }
        return ModelPresetSummary(preset: preset, isRecommended: preset == recommended, isCurrent: current, keys: keys,
                                  names: keys.map { key in catalog.model(key).map { ModelSize.shortName($0, in: catalog) } ?? catalog.name(for: key) },
                                  bytes: ModelSize.bytes(keys, in: catalog), memoryGB: ModelSize.recommendedMemoryGB(keys, in: catalog),
                                  missingBytes: missingBytes(keys))
    }

    // MARK: Storage

    var storage: ModelStorageSummary {
        let removable = inventory.replacedRevisions.filter { !protectedRevisions.contains($0.key) }
        let bytes = removable.reduce(Int64(0)) { $0 + (diskUsage?.installed[$1.key] ?? $1.bytes) }
        return ModelStorageSummary(total: diskUsage?.total ?? 0, removableRevisions: removable.map(\.key),
                                   removableRevisionBytes: bytes, oldDownloadBytes: diskUsage?.legacy.values.reduce(0, +) ?? 0)
    }

    // MARK: Removal

    /// The confirmation for removing a model's files (or, for one the person added, the model
    /// itself): what it frees, and what happens to each role that chose it.
    func removal(of model: CatalogModel, removesEntry: Bool, preset: ModelRecommendations.Preset) -> ModelRemoval {
        var result = selections.removing(model.key, preset: preset, installed: installed.subtracting([model.key]))
        var changes: [ModelRemovalWords.Change] = []
        for change in result.changes {
            switch change {
            case .switched(let role, _, let to):
                changes.append(.switched(role, to: catalog.name(for: to), onceDownloaded: false))
            case .needsDownload(let role, _):
                guard removesEntry else { changes.append(.waits(role)); continue }
                // A model that's no longer listed can't be downloaded again: the preset's model stands in.
                if let fallback = preset.choices[role]?.first(where: { $0 != model.key }) {
                    result.selections[role] = fallback
                    changes.append(.switched(role, to: catalog.name(for: fallback), onceDownloaded: !installed.contains(fallback)))
                } else {
                    result.selections[role] = nil
                    changes.append(.needsAnother(role))
                }
            }
        }
        return ModelRemoval(key: model.key, name: model.name, removesEntry: removesEntry,
                            title: ModelRemovalWords.title(model.name, removesEntry: removesEntry),
                            message: ModelRemovalWords.message(frees: bytesOnDisk(model), changes: changes, removesEntry: removesEntry),
                            selections: result.selections)
    }
}

/// A removal waiting for confirmation, with its consequence.
struct ModelRemoval: Identifiable, Equatable {
    let key: String
    let name: String
    /// Removes a model the person added from the catalog too, not only its files.
    let removesEntry: Bool
    let title: String
    let message: String
    /// The choices afterwards.
    let selections: ModelSelections
    var id: String { key + (removesEntry ? "|entry" : "") }
}

// MARK: - Capabilities in words

extension ModelCapabilities {
    /// "Word timings", "Up to 4 speakers", "25 languages": what a model can do, in plain words.
    var descriptions: [String] {
        var lines: [String] = []
        if wordTimestamps == true { lines.append("Word timings") }
        if wordConfidence == true { lines.append("Word confidence") }
        if let languages, !languages.isEmpty {
            if languages.contains("*") { lines.append("Many languages") }
            else if languages.count == 1 { lines.append(Locale.current.localizedString(forIdentifier: languages[0]) ?? languages[0]) }
            else { lines.append("\(languages.count) languages") }
        }
        if vocabularyPrompt == true { lines.append("Uses your vocabulary") }
        if let maxSpeakers { lines.append("Up to \(maxSpeakers) speakers") }
        if voiceEmbeddings != nil { lines.append("Voice profiles") }
        if expectedSpeakerCount == true { lines.append("Expected number of speakers") }
        if let contextLength { lines.append("\(contextLength >= 1024 ? "\(contextLength / 1024)K" : "\(contextLength)") context") }
        if structuredOutput == true { lines.append("Structured output") }
        if imageInput == true { lines.append("Reads photos") }
        if streaming == true { lines.append("Live") }
        if let memoryGB { lines.append("About \(memoryGB.formatted(.number.precision(.fractionLength(0...1)))) GB while running") }
        return lines
    }
}

// MARK: - Repository input

/// What someone types or pastes into Add Model: "owner/name", or a Hugging Face link, optionally to
/// a branch or folder ("https://huggingface.co/owner/name/tree/main/folder").
struct ModelRepositoryInput: Equatable {
    var repository: String
    var revision: String?
    var folder: String?

    init(repository: String, revision: String? = nil, folder: String? = nil) {
        self.repository = repository; self.revision = revision; self.folder = folder
    }

    /// Nil when it isn't a repository name or link.
    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)) }
        for host in ["www.huggingface.co/", "huggingface.co/", "hf.co/"] where value.lowercased().hasPrefix(host) { value = String(value.dropFirst(host.count)) }
        if let query = value.firstIndex(where: { $0 == "?" || $0 == "#" }) { value = String(value[..<query]) }
        var parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.first == "models" { parts.removeFirst() }
        guard parts.count >= 2, parts[0...1].allSatisfy(Self.isName) else { return nil }
        repository = "\(parts[0])/\(parts[1])"
        revision = nil; folder = nil
        if parts.count >= 4, ["tree", "blob", "resolve"].contains(parts[2]) {
            revision = parts[3]
            let rest = parts.dropFirst(4).joined(separator: "/")
            folder = rest.isEmpty ? nil : rest
        } else if parts.count > 2 {
            return nil
        }
    }

    private static func isName(_ part: String) -> Bool {
        !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    /// A readable default name: "Qwen2.5-0.5B-Instruct-4bit" → "Qwen2.5 0.5B Instruct 4bit".
    var suggestedName: String {
        let base = folder.flatMap { $0.split(separator: "/").last.map(String.init) } ?? String(repository.split(separator: "/").last ?? "")
        return base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".mlmodelc", with: "")
    }
}

// MARK: - Manager

/// Settings › Models' state and actions: what's on disk, update checks, adding, and removing. Reads
/// the app's choices and download queue from `AppState`; every model action goes through the
/// runtime (`LocalIntelligenceRuntime`) or the app's download queue, so processing waits for
/// downloads exactly as it does elsewhere.
@MainActor
@Observable
final class ModelManager {
    enum UpdateCheck: Equatable {
        case never, checking, checked(Date), failed(String)
    }

    let state: AppState
    /// Hugging Face's metadata API, read only when the person checks for updates or adds a model.
    @ObservationIgnored var hubClient: any ModelHubClient
    /// Queues downloads ("key" or "key@revision"); the app's queue, replaced in tests.
    @ObservationIgnored var requestDownload: ([String]) -> Void

    private(set) var inventory = ModelInventory(revisions: [])
    private(set) var diskUsage: ModelDiskUsage?
    private(set) var protectedRevisions: Set<ModelInstallKey> = []
    private(set) var updates: [ModelUpdate] = []
    private(set) var updateCheck = UpdateCheck.never
    private(set) var resultCounts: [String: Int] = [:]
    /// What's free where models go, as of the last refresh, and how far the download under way had got then.
    private(set) var freeSpace = ModelSpace.unknown
    private(set) var fetchedWhenRead: [String: Double] = [:]
    /// What's free for another download (`ModelManagerSnapshot.space`).
    var space: ModelSpace { snapshot.space }
    /// A problem to show: what couldn't be done, one sentence with its fix, and the system's words behind Details.
    var problem: AppProblem?
    private(set) var isWorking = false
    /// Reads what's free at a folder; replaced in tests.
    @ObservationIgnored var readSpace: (URL) -> ModelSpace = ModelSpace.available(at:)

    init(state: AppState, hubClient: (any ModelHubClient)? = nil, requestDownload: (([String]) -> Void)? = nil) {
        self.state = state
        self.hubClient = hubClient ?? ModelDemo.hubClient(catalog: state.modelCatalog) ?? HuggingFaceHubClient()
        self.requestDownload = requestDownload ?? { [weak state] in state?.downloadModels($0) }
    }

    var snapshot: ModelManagerSnapshot {
        ModelManagerSnapshot(catalog: state.modelCatalog, engines: state.runtime.engines, installed: state.installedModels,
                             inventory: inventory, diskUsage: diskUsage, selections: state.modelSelections,
                             speakerQuality: state.processingPreferences.speakerOptions.quality,
                             downloading: state.downloadingID, downloadFraction: state.downloadProgress.fraction,
                             pending: state.pendingDownloads, updates: updates, protectedRevisions: protectedRevisions,
                             resultCounts: resultCounts, freeSpace: freeSpace, fetchedWhenRead: fetchedWhenRead)
    }

    /// Removing and old-revision cleanup wait for processing and downloads (the app refuses them meanwhile).
    var canChangeFiles: Bool { state.processingID == nil && state.downloadingID == nil && !isWorking }

    /// Re-reads what's on disk and what protects it.
    func refresh() async {
        let runtime = state.runtime
        inventory = await runtime.inventory()
        diskUsage = await runtime.diskUsage()
        // Read with how far the download under way has got: what it has fetched is already out of what's free.
        freeSpace = readSpace(modelsFolder)
        fetchedWhenRead = state.downloadingID.flatMap { state.modelCatalog.model(ModelReference($0).id) }
            .map { [$0.key: state.downloadProgress.fraction] } ?? [:]
        let jobs = state.processingQueue + [state.runningJob].compactMap { $0 }
        var protected = await runtime.store.pinned.union(await runtime.store.leasedKeys)
        for reference in jobs.flatMap(\.modelReferences) {
            let key = state.modelCatalog.model(reference.id)?.key ?? reference.id
            if let revision = reference.revision {
                protected.formUnion(inventory.revisions(of: key).filter { $0.key.revision == revision }.map(\.key))
            } else if let resolved = inventory.resolve(key) {
                protected.insert(resolved.key)
            }
        }
        protectedRevisions = protected
        resultCounts = state.modelCatalog.resultCounts(in: state.meetings)
    }

    // MARK: Choosing and downloading

    /// Chooses `key` for `role`. A model that isn't downloaded is chosen anyway and shows
    /// "Not downloaded" with Download; processing waits for it rather than using another model.
    func use(_ key: String, for role: ModelRole) { state.modelSelections[role] = key }

    /// Downloads `key`, when there's room for it; a download that would fill the disk would stop recordings and sync too.
    func download(_ key: String) {
        let snapshot = snapshot
        guard let model = snapshot.catalog.model(key), snapshot.space.fits(snapshot.downloadBytes(model)) else { return }
        requestDownload([key])
    }

    /// Downloads whatever the current choices need, when there's room for all of it.
    func downloadSelected() {
        let snapshot = snapshot, missing = snapshot.missingSelected(detectSpeakers: state.detectSpeakers)
        guard !missing.isEmpty, snapshot.space.fits(snapshot.missingBytes(missing)) else { return }
        requestDownload(missing)
    }

    /// Selected models that aren't on this Mac yet and can be downloaded.
    var missingSelected: [String] { snapshot.missingSelected(detectSpeakers: state.detectSpeakers) }

    /// What the processing choices still need (Settings › Models' Processing).
    var downloadSummary: ModelDownloadSummary? { snapshot.downloadSummary(detectSpeakers: state.detectSpeakers) }

    func cancelDownloads() { state.cancelDownload() }

    /// Processing's Cancel: stops what the choices are downloading. While they only wait their turn, they leave the
    /// queue, and another model's download carries on.
    func cancelSelected() {
        let keys = snapshot.transferringSelected(detectSpeakers: state.detectSpeakers)
        if let current = state.downloadingID.map({ ModelReference($0).id }), keys.contains(current) { cancelDownloads() }
        else { keys.forEach(cancelWaiting) }
    }

    func cancelWaiting(_ key: String) { state.removePendingDownload(key) }

    /// Cancels `key`'s download: the one under way, or its place in the queue.
    func cancel(_ key: String) {
        if state.downloadingID.map({ ModelReference($0).id }) == key { cancelDownloads() } else { cancelWaiting(key) }
    }


    // MARK: Updates

    /// Opt-in and manual: asks Hugging Face for newer revisions of the installed models.
    func checkForUpdates() async {
        guard updateCheck != .checking else { return }
        updateCheck = .checking
        // The checker skips models it can't reach, so ask once first to tell "offline" from "up to date".
        if let repository = state.modelCatalog.models.first(where: { state.installedModels.contains($0.key) && !$0.isSystemModel })?
            .latestRevision?.artifacts.first?.repository {
            do { _ = try await hubClient.info(repository: repository) }
            catch where Self.isOffline(error) {
                updateCheck = .failed("Couldn’t reach Hugging Face. Check your connection and try again.")
                return
            } catch {}
        }
        updates = await state.runtime.checkForUpdates(client: hubClient)
        updateCheck = .checked(Date())
    }

    /// Records the update's revision and queues its download beside the current one. Selections
    /// switch once it's verified; queued jobs keep the revision they froze.
    func install(_ update: ModelUpdate) async {
        do {
            state.modelCatalog = try await state.runtime.recordUpdate(update)
            requestDownload(["\(update.model)@\(update.revision.id)"])
        } catch {
            problem = AppProblem(title: "Couldn’t Install the Update", fallback: "The update to \(update.name) couldn’t be installed. Try again.", error: error)
        }
    }

    // MARK: Removing

    /// The confirmation for removing `key`'s files, or the whole model when `removesEntry`.
    func removal(of key: String, removesEntry: Bool = false) -> ModelRemoval? {
        guard let model = state.modelCatalog.model(key) else { return nil }
        let quality = ModelPreset.current(in: state)?.quality ?? ModelRecommendations.recommendedQuality(catalog: state.modelCatalog)
        let preset = ModelRecommendations.preset(quality, catalog: state.modelCatalog, engines: state.runtime.engines)
        return snapshot.removal(of: model, removesEntry: removesEntry && model.origin == .addedByYou, preset: preset)
    }

    func confirm(_ removal: ModelRemoval) async {
        guard canChangeFiles else { problem = AppProblem(title: "Can’t Remove It Yet", message: "Try again when processing and downloads finish."); return }
        guard removal.removesEntry else {
            // The app removes the files and moves each role that chose it, as the confirmation said.
            state.removeModels([removal.key])
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await state.runtime.removeAddedModel(removal.key)
            state.modelCatalog = await state.runtime.catalog
            await state.refreshInstalledModels()
            state.modelSelections = removal.selections
            await refresh()
        } catch {
            problem = AppProblem(title: "Couldn’t Remove \(removal.name)", fallback: "\(removal.name) couldn’t be removed. Try again.", error: error)
        }
    }

    /// Removes revisions updates replaced that nothing selects, queues, runs, or pins.
    func removeOldRevisions() async {
        guard canChangeFiles else { return }
        isWorking = true
        defer { isWorking = false }
        let references = (state.processingQueue + [state.runningJob].compactMap { $0 }).flatMap(\.modelReferences)
            + state.modelSelections.allKeys.map { ModelReference($0) }
        await state.runtime.collectGarbage(protecting: references)
        await refresh()
    }

    /// Removes folders from before the model system that couldn't be moved into the store.
    func removeOldDownloads() async {
        guard canChangeFiles else { return }
        isWorking = true
        defer { isWorking = false }
        await state.runtime.store.removeLegacyLeftovers()
        await refresh()
    }

    /// The runtime's folder (`AppState` keeps it in the library as Models).
    var modelsFolder: URL { state.storageURL.appendingPathComponent("Models", isDirectory: true) }

    func showModelsFolder() {
        let folder = modelsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Adding

    /// What adding `input` would add. Nothing is written.
    func preview(_ input: ModelRepositoryInput) async throws -> ModelAdditionPreview {
        do {
            return try await state.runtime.previewAddition(repository: input.repository, revision: input.revision ?? "main",
                                                           options: input.folder.map { ["subdirectory": $0] } ?? [:], client: hubClient)
        } catch {
            throw ModelAdditionProblem(error, input: input)
        }
    }

    /// Adds the candidate exactly as previewed (its commit), labelled "Added by you", and queues its download.
    @discardableResult
    func add(_ candidate: ModelAdditionPreview.Candidate, from preview: ModelAdditionPreview, name: String,
             input: ModelRepositoryInput) async throws -> CatalogModel {
        do {
            let request = ModelAdditionRequest(
                repository: preview.repository, revision: preview.commit.id, role: candidate.role, engine: candidate.engine.id,
                variantName: name.trimmingCharacters(in: .whitespacesAndNewlines), familyID: candidate.familyID,
                familyName: candidate.familyName, options: input.folder.map { ["subdirectory": $0] } ?? [:])
            let added = try await state.runtime.addModel(request, client: hubClient)
            state.modelCatalog = await state.runtime.catalog
            requestDownload([added.key])
            await refresh()
            return added
        } catch {
            throw ModelAdditionProblem(error, input: input)
        }
    }

    nonisolated static func isOffline(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut,
                .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed].contains(url.code)
    }
}

/// Why adding a model didn't work, in one sentence with its fix; the system's own words, if any, behind Details.
struct ModelAdditionProblem: LocalizedError, Equatable {
    let message: String
    var details: String?

    init(message: String) { self.message = message }

    init(_ error: Error, input: ModelRepositoryInput) {
        if let problem = error as? ModelAdditionProblem { self = problem; return }
        if case .notFound? = error as? ModelHubError {
            message = input.revision.map { "Hugging Face has no “\(input.repository)” at “\($0)”. Check the name and revision." }
                ?? "Hugging Face has no “\(input.repository)”. Check the name, and that the repository is public."
        } else if ModelManager.isOffline(error) {
            message = "Couldn’t reach Hugging Face. Check your connection and try again."
        } else if error is ModelAdditionError || error is ModelHubError {
            // Daybook's own sentences, with what to do.
            message = error.localizedDescription
        } else {
            message = "Couldn’t add “\(input.repository)”. Try again."
            details = error.localizedDescription
        }
    }

    var errorDescription: String? { message }
}
