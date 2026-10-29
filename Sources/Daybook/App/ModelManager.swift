import AppKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

// The model manager (Settings › Models; docs/models.md, "The model manager"). Everything here is
// derived from the catalog, never from model IDs: roles from the catalog and the registered engines,
// models from `ModelCatalog.models(for:)`, availability from `CatalogModel.availability(engines:)`,
// labels from licenses and origins. A new engine, family, variant, or role appears without code here.

// MARK: - Roles

extension ModelRole {
    /// What Settings calls the role. A role a newer manifest names reads as its identifier in words.
    var title: String {
        switch self {
        case .transcription: return "Transcription"
        case .diarization: return "Speakers"
        case .speakerEmbedding: return "Voice profiles"
        case .summarization: return "Summaries"
        case .smallTasks: return "Titles and tags"
        case .imageDescription: return "Photos"
        case .liveTranscription: return "Live transcription"
        case .liveDiarization: return "Live speakers"
        default: return Self.words(rawValue)
        }
    }

    /// The role as the subject of a sentence: "Speaker detection will use Sortformer 2.1."
    var subject: String { self == .diarization ? "Speaker detection" : title }

    /// "imageCaptions" or "image_captions" → "Image captions".
    static func words(_ identifier: String) -> String {
        var result = ""
        for character in identifier {
            if character == "_" || character == "-" { result += " "; continue }
            if character.isUppercase, !result.isEmpty, result.last != " " { result += " " }
            result.append(contentsOf: result.isEmpty ? character.uppercased() : character.lowercased())
        }
        return result.isEmpty ? identifier : result
    }
}

// MARK: - Status

/// A model's state on this Mac, as the library, the role menus, and details show it.
enum ModelStatus: Equatable {
    /// This build or this Mac can't run it ("Needs a newer Daybook", "Not available on this Mac").
    case unavailable(String)
    case notDownloaded
    /// Files went missing or changed size since they were checked.
    case damaged
    case waiting
    case downloading(Double)
    case updateAvailable
    case downloaded
    case inUse
    /// Provided by macOS: nothing to download.
    case builtIn

    var label: String {
        switch self {
        case .unavailable(let reason): return reason
        case .notDownloaded: return "Not downloaded"
        case .damaged: return "Needs downloading again"
        case .waiting: return "Waiting to download"
        case .downloading(let fraction): return "Downloading · \(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
        case .updateAvailable: return "Update available"
        case .downloaded: return "Downloaded"
        case .inUse: return "In use"
        case .builtIn: return "Included with macOS"
        }
    }

    /// It can run now.
    var isReady: Bool { [.downloaded, .inUse, .updateAvailable, .builtIn].contains(self) }
    var isAvailable: Bool { if case .unavailable = self { return false }; return true }
    var isTransferring: Bool { if case .downloading = self { return true }; return self == .waiting }
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
        [model.maker, model.isSystemModel ? nil : ModelSize.format(model.approximateBytes)].compactMap { $0 }.joined(separator: " · ")
    }
    var canDownload: Bool { status == .notDownloaded || status == .damaged }
    var canRemove: Bool { !model.isSystemModel && bytesOnDisk > 0 && !status.isTransferring }
    var canUse: Bool { status.isReady && !usableRoles.isEmpty }
}

/// The models of one family, as the library groups them.
struct ModelFamilyGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let rows: [ModelRow]
}

/// One choice in a role's menu.
struct ModelOption: Identifiable, Equatable {
    let key: String
    let name: String
    /// "Downloaded", "1.6 GB", "Needs a newer Daybook", with " · Non-commercial" where it applies.
    let detail: String
    let isEnabled: Bool
    var id: String { key }
}

/// A role's choice: what's selected, what else it could be, and how the selected model stands.
struct ModelRoleChoice: Identifiable, Equatable {
    let role: ModelRole
    let selection: String?
    let options: [ModelOption]
    let selectedModel: CatalogModel?
    let status: ModelStatus?
    var id: String { role.rawValue }
    var title: String { role.title }
}

/// Quick, Balanced, Detailed, or the person's own mix.
struct ModelPresetSummary: Identifiable, Equatable {
    /// Nil for Custom.
    let preset: ModelPreset?
    let isRecommended: Bool
    let isCurrent: Bool
    let keys: [String]
    let names: [String]
    let bytes: Int64
    let memoryGB: Int
    var id: String { preset?.rawValue ?? "custom" }
    var title: String { preset?.title ?? "Custom" }
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
    func labels(_ model: CatalogModel) -> [String] {
        var labels: [String] = []
        if let license = model.license, !license.allowsCommercialUse { labels.append("Non-commercial") }
        if model.license == nil { labels.append("Non-commercial") }
        if let origin = model.origin.label { labels.append(origin) }
        return labels
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
        .sorted { Self.order($0) == Self.order($1) ? $0.title < $1.title : Self.order($0) < Self.order($1) }
    }

    var roleChoices: [ModelRoleChoice] { choiceRoles.map(choice(for:)) }

    func choice(for role: ModelRole) -> ModelRoleChoice {
        let selection = selections[role]
        var available: [ModelOption] = [], unavailable: [ModelOption] = []
        for model in catalog.models(for: role) {
            let status = status(of: model)
            let option = ModelOption(key: model.key, name: model.name, detail: optionDetail(model, status), isEnabled: status.isAvailable)
            if status.isAvailable || model.key == selection { available.append(option) } else { unavailable.append(option) }
        }
        // A choice the catalog no longer lists stays visible, so nothing switches silently.
        if let selection, catalog.model(selection) == nil {
            available.insert(ModelOption(key: selection, name: catalog.name(for: selection), detail: "Not available", isEnabled: false), at: 0)
        }
        let model = selection.flatMap { catalog.model($0) }
        return ModelRoleChoice(role: role, selection: selection, options: available + unavailable, selectedModel: model,
                               status: model.map(status(of:)))
    }

    func optionDetail(_ model: CatalogModel, _ status: ModelStatus) -> String {
        let state: String
        switch status {
        case .downloaded, .inUse, .updateAvailable: state = "Downloaded"
        case .notDownloaded, .damaged: state = ModelSize.format(model.approximateBytes)
        default: state = status.label
        }
        return ([state] + labels(model).filter { $0 == "Non-commercial" }).joined(separator: " · ")
    }

    // MARK: Library

    /// Every model in the catalog, by family. Families follow the pipeline (the first role each
    /// serves), then their names; models keep their manifest order.
    var families: [ModelFamilyGroup] {
        var order: [String] = []
        var grouped: [String: [CatalogModel]] = [:]
        for model in catalog.models {
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
        var summaries = ModelPreset.allCases.map { preset -> ModelPresetSummary in
            let models = preset.models(catalog: catalog, engines: engines)
            let keys = ModelPreset.keys(models)
            return summary(preset, keys: keys, recommended: recommended,
                           current: preset.matches(selections, speakerQuality: speakerQuality, catalog: catalog, engines: engines))
        }
        if !summaries.contains(where: \.isCurrent) {
            // Live captions' models are optional downloads, not part of what processing needs.
            let keys = choiceRoles.filter { !$0.isLiveOnly }.compactMap { selections[$0] }
            summaries.append(summary(nil, keys: keys, recommended: recommended, current: true))
        }
        return summaries
    }

    private func summary(_ preset: ModelPreset?, keys: [String], recommended: ModelPreset, current: Bool) -> ModelPresetSummary {
        // A model with two roles (Community-1 finds speakers and makes voice profiles) is listed once.
        var seen = Set<String>()
        let keys = keys.filter { seen.insert($0).inserted }
        return ModelPresetSummary(preset: preset, isRecommended: preset == recommended, isCurrent: current, keys: keys,
                                  names: keys.map { key in catalog.model(key).map { ModelSize.shortName($0, in: catalog) } ?? catalog.name(for: key) },
                                  bytes: ModelSize.bytes(keys, in: catalog), memoryGB: ModelSize.recommendedMemoryGB(keys, in: catalog))
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
        let bytes = bytesOnDisk(model)
        var result = selections.removing(model.key, preset: preset, installed: installed.subtracting([model.key]))
        var sentences: [String] = bytes > 0 ? ["Frees \(ModelSize.format(bytes))."] : []
        for change in result.changes {
            switch change {
            case .switched(let role, _, let to):
                sentences.append("\(role.subject) will use \(catalog.name(for: to)).")
            case .needsDownload(let role, _):
                guard removesEntry else { sentences.append("\(role.subject) will wait until you download it again."); continue }
                // A model that's no longer listed can't be downloaded again: the preset's model stands in.
                if let fallback = preset.choices[role]?.first(where: { $0 != model.key }) {
                    result.selections[role] = fallback
                    sentences.append("\(role.subject) will use \(catalog.name(for: fallback))\(installed.contains(fallback) ? "" : ", once it’s downloaded").")
                } else {
                    result.selections[role] = nil
                    sentences.append("\(role.subject) will need another model.")
                }
            }
        }
        if result.changes.isEmpty { sentences.append(removesEntry ? "You can add it again later." : "You can download it again at any time.") }
        return ModelRemoval(key: model.key, name: model.name, removesEntry: removesEntry,
                            title: removesEntry ? "Remove \(model.name) from Daybook?" : "Remove \(model.name)?",
                            message: sentences.joined(separator: " "), selections: result.selections)
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
final class ModelManager: ObservableObject {
    enum UpdateCheck: Equatable {
        case never, checking, checked(Date), failed(String)
    }

    let state: AppState
    /// Hugging Face's metadata API, read only when the person checks for updates or adds a model.
    var hubClient: any ModelHubClient
    /// Queues downloads ("key" or "key@revision"); the app's queue, replaced in tests.
    var requestDownload: ([String]) -> Void

    @Published private(set) var inventory = ModelInventory(revisions: [])
    @Published private(set) var diskUsage: ModelDiskUsage?
    @Published private(set) var protectedRevisions: Set<ModelInstallKey> = []
    @Published private(set) var updates: [ModelUpdate] = []
    @Published private(set) var updateCheck = UpdateCheck.never
    @Published private(set) var resultCounts: [String: Int] = [:]
    /// A problem to show: what couldn't be done, one sentence with its fix, and the system's words behind Details.
    @Published var problem: AppProblem?
    @Published private(set) var isWorking = false

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
                             resultCounts: resultCounts)
    }

    /// Removing and old-revision cleanup wait for processing and downloads (the app refuses them meanwhile).
    var canChangeFiles: Bool { state.processingID == nil && state.downloadingID == nil && !isWorking }

    /// Re-reads what's on disk and what protects it.
    func refresh() async {
        let runtime = state.runtime
        inventory = await runtime.inventory()
        diskUsage = await runtime.diskUsage()
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

    func download(_ key: String) { requestDownload([key]) }

    /// Downloads whatever the current choices need.
    func downloadSelected() { requestDownload(missingSelected) }

    /// Selected models that aren't on this Mac yet and can be downloaded.
    var missingSelected: [String] {
        let snapshot = snapshot
        var keys: [String] = []
        // Live captions' models are optional downloads, offered in their own rows.
        for role in snapshot.choiceRoles where (role != .diarization || state.detectSpeakers) && !role.isLiveOnly {
            guard let key = state.modelSelections[role], let model = state.modelCatalog.model(key), !keys.contains(model.key) else { continue }
            if [.notDownloaded, .damaged].contains(snapshot.status(of: model)) { keys.append(model.key) }
        }
        return keys
    }

    func cancelDownloads() { state.cancelDownload() }

    func cancelWaiting(_ key: String) { state.removePendingDownload(key) }

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
