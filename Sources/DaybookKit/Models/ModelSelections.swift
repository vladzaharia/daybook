import Foundation

/// The chosen model per role, by family and variant ("whisper/base"), never a raw revision: a
/// selection resolves to the newest verified installed revision of its variant, so installing an
/// update switches it atomically and a removed revision never leaves it pointing at nothing.
public struct ModelSelections: Codable, Equatable, Sendable {
    /// Role → variant key. A key the catalog doesn't know is kept as is, so nothing switches silently.
    public private(set) var keys: [String: String]

    public init(_ keys: [ModelRole: String] = [:]) {
        self.keys = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value) })
    }

    public subscript(role: ModelRole) -> String? {
        get { keys[role.rawValue] }
        set { keys[role.rawValue] = newValue?.isEmpty == true ? nil : newValue }
    }

    /// Every selected variant key.
    public var allKeys: Set<String> { Set(keys.values) }

    /// Selections from before the model system, which stored catalog IDs ("whisper-base", "qwen-7b",
    /// "speaker-community-1"). Each maps through the catalog's migration table; a role with no
    /// stored value takes `defaults`; an ID the table doesn't know is kept so it can still be shown.
    public static func migrating(legacy: [ModelRole: String?], catalog: ModelCatalog, defaults: ModelSelections) -> ModelSelections {
        var result = defaults
        for (role, stored) in legacy {
            guard let stored, !stored.isEmpty else { continue }
            result[role] = catalog.model(stored)?.key ?? stored
        }
        return result
    }

    /// What happened to one role when a model was removed.
    public enum Fallback: Equatable, Sendable {
        /// The role now uses another installed model from the preset's list.
        case switched(role: ModelRole, from: String, to: String)
        /// Nothing installed can stand in: the role keeps its choice and waits for a download.
        case needsDownload(role: ModelRole, model: String)
    }

    /// After removing `removed` (a variant key), roles that selected it move to the preset's next
    /// installed choice, or keep it and need a download. Queued and running jobs aren't affected:
    /// they froze their models, so processing never silently switches.
    public func removing(_ removed: String, preset: ModelRecommendations.Preset, installed: Set<String>) -> (selections: ModelSelections, changes: [Fallback]) {
        var result = self
        var changes: [Fallback] = []
        for role in ModelRole.known where self[role] == removed {
            if let next = (preset.choices[role] ?? []).first(where: { $0 != removed && installed.contains($0) }) {
                result[role] = next
                changes.append(.switched(role: role, from: removed, to: next))
            } else {
                changes.append(.needsDownload(role: role, model: removed))
            }
        }
        return (result, changes)
    }

    /// Roles whose choice no longer serves them in the catalog (Qwen 2.5 1.5B stopped writing summaries: it
    /// missed most topics and commitments) move to the preset's first installed choice, or to its first
    /// choice, which then waits for a download like any choice. A key the catalog doesn't know is kept,
    /// so nothing switches silently.
    public func replacingRetired(catalog: ModelCatalog, preset: ModelRecommendations.Preset,
                                 installed: Set<String>) -> (selections: ModelSelections, changes: [Fallback]) {
        var result = self
        var changes: [Fallback] = []
        for role in ModelRole.known {
            guard let key = self[role], let model = catalog.model(key), !model.serves(role) else { continue }
            let choices = (preset.choices[role] ?? []).filter { catalog.model($0)?.serves(role) == true }
            guard let next = choices.first(where: installed.contains) ?? choices.first else { continue }
            result[role] = next
            changes.append(.switched(role: role, from: key, to: next))
        }
        return (result, changes)
    }
}

/// Decisions the pipeline makes from capabilities rather than model IDs.
public enum ModelRouting {
    /// The model to compute voice profiles with, when the diarizer doesn't produce them itself:
    /// the speakerEmbedding selection, if it serves that role and this build can run it. Nil when
    /// the diarizer already embeds voices (Community-1) or no embedder is selected.
    public static func voiceEmbedder(diarizer: String, selections: ModelSelections, catalog: ModelCatalog,
                                     engines: [ModelEngineDescriptor], appVersion: ModelVersion? = ModelVersion.app) -> String? {
        if let model = catalog.model(diarizer), model.capabilities.voiceEmbeddings != nil { return nil }
        guard let key = selections[.speakerEmbedding], key != diarizer, let embedder = catalog.model(key),
              embedder.serves(.speakerEmbedding), embedder.capabilities.voiceEmbeddings != nil,
              embedder.availability(engines: engines, appVersion: appVersion).isAvailable else { return nil }
        return embedder.key
    }

    /// Whether results from `model` can be matched to people across recordings.
    public static func supportsVoiceMatching(_ model: String, catalog: ModelCatalog) -> Bool {
        catalog.model(model)?.capabilities.voiceEmbeddings != nil
    }

    /// Whether `model` uses an expected speaker count.
    public static func supportsExpectedSpeakerCount(_ model: String, catalog: ModelCatalog) -> Bool {
        catalog.model(model)?.capabilities.expectedSpeakerCount == true
    }
}
