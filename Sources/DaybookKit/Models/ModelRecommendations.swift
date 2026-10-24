import Foundation

/// How much model a Mac (or, later, an iPhone) can comfortably run, from its memory.
public enum DeviceTier: String, CaseIterable, Codable, Sendable {
    /// Under 16 GB, and iPhones.
    case compact
    /// 16–31 GB: a typical MacBook Air or Pro.
    case standard
    /// 32–63 GB.
    case large
    /// 64 GB and more: Max and Ultra Macs.
    case workstation

    public init(memoryGB: Int) {
        switch memoryGB {
        case ..<16: self = .compact
        case ..<32: self = .standard
        case ..<64: self = .large
        default: self = .workstation
        }
    }

    public static var current: DeviceTier {
        DeviceTier(memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    }
}

/// The Quick / Balanced / Detailed choice in Settings › Models.
public enum ModelQuality: String, CaseIterable, Codable, Sendable {
    case quick, balanced, detailed
}

/// Presets and first-launch choices, read from the catalog's manifest (`presets`,
/// `recommendedPreset`, `initialSelection`), so a new model becomes a preset's choice by editing
/// the catalog's Catalog.json. Each role lists choices best first; the first one this build can run is the
/// preset's model, and the rest are the fallbacks when a model is removed.
public enum ModelRecommendations {
    /// A preset's models on one tier.
    public struct Preset: Equatable, Sendable {
        public var quality: ModelQuality
        /// The speaker-analysis effort it uses ("fast", "balanced", "accurate").
        public var speakerQuality: String?
        /// Role → variant keys, best first.
        public var choices: [ModelRole: [String]]

        /// The preset's model for `role`.
        public func model(for role: ModelRole) -> String? { choices[role]?.first }

        /// The preset's model for every role it names.
        public var selections: ModelSelections {
            ModelSelections(Dictionary(uniqueKeysWithValues: choices.compactMap { role, keys in keys.first.map { (role, $0) } }))
        }
    }

    public struct Speech: Equatable, Sendable {
        public var transcription: String
        public var diarization: String
        public init(transcription: String, diarization: String) {
            self.transcription = transcription; self.diarization = diarization
        }
    }

    /// `quality`'s preset on `tier`. With `engines`, choices this build can't run are left out.
    public static func preset(_ quality: ModelQuality, tier: DeviceTier = .current, catalog: ModelCatalog = .builtIn,
                              engines: [ModelEngineDescriptor]? = nil, appVersion: ModelVersion? = ModelVersion.app) -> Preset {
        let entry = catalog.presets.first { $0.id == quality.rawValue }
        var choices: [ModelRole: [String]] = [:]
        for role in ModelRole.known {
            let keys = runnable(entry?.choices.choices(for: role, tier: tier.rawValue) ?? [], catalog: catalog,
                                engines: engines, appVersion: appVersion)
            if !keys.isEmpty { choices[role] = keys }
        }
        return Preset(quality: quality, speakerQuality: entry?.speakerQuality, choices: choices)
    }

    /// The preset a tier starts with.
    public static func recommendedQuality(for tier: DeviceTier = .current, catalog: ModelCatalog = .builtIn) -> ModelQuality {
        let id = catalog.recommendedPreset.map { $0.tiers[tier.rawValue] ?? $0.default }
        return id.flatMap(ModelQuality.init(rawValue:)) ?? .balanced
    }

    /// What a new installation selects before anyone chooses.
    public static func initialSelections(for tier: DeviceTier = .current, catalog: ModelCatalog = .builtIn,
                                         engines: [ModelEngineDescriptor]? = nil) -> ModelSelections {
        guard let table = catalog.initialSelection else { return preset(recommendedQuality(for: tier, catalog: catalog), tier: tier, catalog: catalog).selections }
        var keys: [ModelRole: String] = [:]
        for role in ModelRole.known {
            if let first = runnable(table.choices(for: role, tier: tier.rawValue), catalog: catalog, engines: engines, appVersion: ModelVersion.app).first {
                keys[role] = first
            }
        }
        return ModelSelections(keys)
    }

    /// Transcription and speaker models for a tier and quality.
    public static func speech(for tier: DeviceTier, quality: ModelQuality, catalog: ModelCatalog = .builtIn) -> Speech {
        let preset = preset(quality, tier: tier, catalog: catalog)
        return Speech(transcription: preset.model(for: .transcription) ?? "", diarization: preset.model(for: .diarization) ?? "")
    }

    /// The summary model for a tier and quality.
    public static func summary(for tier: DeviceTier, quality: ModelQuality, catalog: ModelCatalog = .builtIn) -> String {
        preset(quality, tier: tier, catalog: catalog).model(for: .summarization) ?? ""
    }

    /// Keys the catalog knows and, given engines, this build can run.
    private static func runnable(_ keys: [String], catalog: ModelCatalog, engines: [ModelEngineDescriptor]?, appVersion: ModelVersion?) -> [String] {
        keys.filter { key in
            guard let model = catalog.model(key) else { return false }
            guard let engines else { return true }
            return model.availability(engines: engines, appVersion: appVersion).isAvailable
        }
    }
}
