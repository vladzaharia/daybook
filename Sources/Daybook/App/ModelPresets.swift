import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// The quality presets shared by Settings › Models and the Welcome window. Their models come from
/// the catalog's manifest (`ModelRecommendations`), per device tier, for every role a preset names,
/// so a new default model or a new role is a manifest edit.
enum ModelPreset: String, CaseIterable, Identifiable {
    case quick, balanced, detailed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .quick: return "Quick"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }
    var quality: ModelQuality { ModelQuality(rawValue: rawValue) ?? .balanced }

    /// The preset's models in `catalog`. With `engines`, choices this build can't run are left out.
    func models(catalog: ModelCatalog = .builtIn, engines: [ModelEngineDescriptor]? = nil) -> ModelRecommendations.Preset {
        ModelRecommendations.preset(quality, catalog: catalog, engines: engines)
    }
    /// The preset's models as this Mac can run them: the app's catalog and engines.
    @MainActor func models(in state: AppState) -> ModelRecommendations.Preset {
        models(catalog: state.modelCatalog, engines: state.runtime.engines)
    }
    var models: ModelRecommendations.Preset { models() }

    /// Every model the preset chooses, one per role: transcription, summaries, and speakers first
    /// (the order Daybook always listed them), then any other role the preset names.
    var modelIDs: [String] {
        let preset = models
        let leading: [ModelRole] = [.transcription, .summarization, .diarization]
        let others = preset.choices.keys.filter { !leading.contains($0) }
            .sorted { ModelManagerSnapshot.order($0) == ModelManagerSnapshot.order($1) ? $0.rawValue < $1.rawValue
                : ModelManagerSnapshot.order($0) < ModelManagerSnapshot.order($1) }
        return (leading + others).compactMap { preset.model(for: $0) }
    }
    /// The preset's models this Mac would download (system models need none).
    @MainActor func downloadKeys(in state: AppState) -> [String] {
        Self.keys(models(in: state)).filter { state.modelCatalog.model($0)?.isSystemModel != true }
    }
    @MainActor func bytes(in state: AppState) -> Int64 { ModelSize.bytes(Self.keys(models(in: state)), in: state.modelCatalog) }
    @MainActor func recommendedMemoryGB(in state: AppState) -> Int {
        ModelSize.recommendedMemoryGB(Self.keys(models(in: state)), in: state.modelCatalog)
    }
    var bytes: Int64 { ModelSize.bytes(modelIDs) }
    var recommendedMemoryGB: Int { ModelSize.recommendedMemoryGB(modelIDs) }

    var transcriptionModel: String { models.model(for: .transcription) ?? "" }
    var summaryModel: String { models.model(for: .summarization) ?? "" }
    var speakerModel: String { models.model(for: .diarization) ?? "" }

    func speakerQuality(_ preset: ModelRecommendations.Preset) -> SpeakerQuality {
        preset.speakerQuality.flatMap(SpeakerQuality.init(rawValue:)) ?? {
            switch self {
            case .quick: return .fast
            case .balanced: return .balanced
            case .detailed: return .accurate
            }
        }()
    }
    var speakerQuality: SpeakerQuality { speakerQuality(models) }

    /// The preset recommended for this Mac's memory (the catalog's `recommendedPreset`).
    static var recommended: ModelPreset { recommended(tier: .current) }
    static func recommended(tier: DeviceTier, catalog: ModelCatalog = .builtIn) -> ModelPreset {
        ModelPreset(rawValue: ModelRecommendations.recommendedQuality(for: tier, catalog: catalog).rawValue) ?? .balanced
    }

    /// The preset matching the current choices, or nil ("Custom").
    @MainActor static func current(in state: AppState) -> ModelPreset? {
        allCases.first { preset in
            preset.matches(state.modelSelections, speakerQuality: state.processingPreferences.speakerOptions.quality,
                           catalog: state.modelCatalog, engines: state.runtime.engines)
        }
    }

    /// Whether `selections` choose exactly this preset's model for every role it names, with its
    /// speaker effort. Roles the preset doesn't name don't matter.
    func matches(_ selections: ModelSelections, speakerQuality: SpeakerQuality, catalog: ModelCatalog = .builtIn,
                 engines: [ModelEngineDescriptor]? = nil) -> Bool {
        let preset = models(catalog: catalog, engines: engines)
        guard !preset.choices.isEmpty else { return false }
        for role in preset.choices.keys where selections[role] != preset.model(for: role) { return false }
        return speakerQuality == self.speakerQuality(preset)
    }

    /// Chooses the preset's model for every role it names, and its speaker effort.
    @MainActor func apply(to state: AppState) {
        let preset = models(in: state)
        var selections = state.modelSelections
        for (role, keys) in preset.choices { if let key = keys.first { selections[role] = key } }
        state.modelSelections = selections
        var preferences = state.processingPreferences
        preferences.speakerModelID = selections[.diarization] ?? preferences.speakerModelID
        preferences.speakerOptions.quality = speakerQuality(preset)
        state.processingPreferences = preferences
    }

    /// A preset's model keys, one per role, in the pipeline's order (`ModelRole.known`, then others).
    static func keys(_ preset: ModelRecommendations.Preset) -> [String] {
        let roles = preset.choices.keys.sorted {
            ModelManagerSnapshot.order($0) == ModelManagerSnapshot.order($1) ? $0.rawValue < $1.rawValue
                : ModelManagerSnapshot.order($0) < ModelManagerSnapshot.order($1)
        }
        return roles.compactMap { preset.model(for: $0) }
    }
}

/// Model sizes and download progress, in the units people read ("2.4 GB", "1.2 of 2.4 GB").
enum ModelSize {
    static let physicalMemoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())

    /// Presets name built-in models; Settings passes the app's catalog, which adds the person's own.
    static func model(_ id: String, in catalog: ModelCatalog = .builtIn) -> CatalogModel? { catalog.model(id) }
    /// Download size: nothing for models the system provides.
    static func bytes(_ ids: [String], in catalog: ModelCatalog = .builtIn) -> Int64 {
        Set(ids).compactMap { model($0, in: catalog) }.reduce(0) { $0 + ($1.isSystemModel ? 0 : $1.approximateBytes) }
    }
    static func recommendedMemoryGB(_ ids: [String], in catalog: ModelCatalog = .builtIn) -> Int {
        ids.compactMap { model($0, in: catalog) }.map(\.recommendedMemoryGB).max() ?? 8
    }

    static func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        return bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(max(1, Int((Double(bytes) / 1e6).rounded()))) MB"
    }

    static func progress(_ done: Int64, of total: Int64) -> String {
        guard total >= 1_000_000_000 else { return "\(format(done).replacingOccurrences(of: " MB", with: "")) of \(format(total))" }
        return String(format: "%.1f of %.1f GB", Double(done) / 1e9, Double(total) / 1e9)
    }

    /// Bytes of these models already on this Mac, counting the current download's progress.
    @MainActor static func downloaded(_ ids: [String], in state: AppState) -> Int64 {
        Set(ids).compactMap { model($0, in: state.modelCatalog) }.reduce(0) { total, model in
            if model.isSystemModel { return total }
            if state.installedModels.contains(model.key) { return total + model.approximateBytes }
            if state.downloadingID.map({ ModelReference($0).id }) == model.key {
                return total + Int64(Double(model.approximateBytes) * state.downloadProgress.fraction)
            }
            return total
        }
    }

    @MainActor static func isDownloading(_ ids: [String], in state: AppState) -> Bool {
        let busy = Set(([state.downloadingID].compactMap { $0 } + state.pendingDownloads).map { ModelReference($0).id })
        return ids.contains { busy.contains($0) }
    }

    /// A short name for lists of several models: the family's name when it has one model ("Community-1"),
    /// else the model's ("Whisper Small", "Qwen 2.5 7B").
    static func shortName(_ model: CatalogModel, in catalog: ModelCatalog = .builtIn) -> String {
        if catalog.models.filter({ $0.familyID == model.familyID }).count == 1 { return model.familyName }
        return model.name.replacingOccurrences(of: " · ", with: " ")
    }
}
