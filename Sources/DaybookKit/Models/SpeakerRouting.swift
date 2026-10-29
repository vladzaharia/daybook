import Foundation

// Speaker routing (docs/models.md, "Routing"): which speaker model a job runs, and which model makes
// its voice profiles, read from capabilities.
extension ModelRouting {
    /// The speaker model a job runs: `selected`, unless the expected number of speakers is more than
    /// it can tell apart (`maxSpeakers`); then an installed speaker model with no such limit (or a
    /// high enough one), preferring one that takes an expected count. Keeps `selected` when nothing
    /// installed can.
    public static func diarizer(selected: String, expectedSpeakers: Int?, catalog: ModelCatalog,
                                engines: [ModelEngineDescriptor]? = nil, installed: Set<String>,
                                appVersion: ModelVersion? = ModelVersion.app) -> String {
        guard let count = expectedSpeakers, let model = catalog.model(selected), let limit = model.capabilities.maxSpeakers,
              count > limit else { return selected }
        let candidates = catalog.models(for: .diarization).filter { candidate in
            candidate.key != model.key && installed.contains(candidate.key)
                && (candidate.capabilities.maxSpeakers.map { $0 >= count } ?? true)
                && (engines.map { candidate.availability(engines: $0, appVersion: appVersion).isAvailable } ?? true)
        }
        return (candidates.first { $0.capabilities.expectedSpeakerCount == true } ?? candidates.first)?.key ?? selected
    }

    /// Whether speakers found with `diarizer` get voice profiles, from the speaker model itself
    /// (Community-1) or from the voice-profile model it's routed to (Nemotron 3 with Community-1), so
    /// they can be matched across recordings and conversations.
    public static func makesVoiceProfiles(diarizer: String, selections: ModelSelections, catalog: ModelCatalog,
                                          engines: [ModelEngineDescriptor], appVersion: ModelVersion? = ModelVersion.app) -> Bool {
        if supportsVoiceMatching(diarizer, catalog: catalog) { return true }
        let routed = withDefaultVoiceEmbedder(selections, catalog: catalog, engines: engines)
        return voiceEmbedder(diarizer: diarizer, selections: routed, catalog: catalog, engines: engines, appVersion: appVersion) != nil
    }

    /// `selections` with the catalog's first-launch voice-profile model standing in when none is
    /// stored, as for selections saved before the role had a built-in model.
    public static func withDefaultVoiceEmbedder(_ selections: ModelSelections, catalog: ModelCatalog,
                                                engines: [ModelEngineDescriptor]? = nil, tier: DeviceTier = .current) -> ModelSelections {
        guard selections[.speakerEmbedding] == nil else { return selections }
        var result = selections
        result[.speakerEmbedding] = ModelRecommendations.initialSelections(for: tier, catalog: catalog, engines: engines)[.speakerEmbedding]
        return result
    }
}
