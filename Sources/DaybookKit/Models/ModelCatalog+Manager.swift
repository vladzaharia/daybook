import Foundation

// What the model manager (Mac) and Acknowledgements (Mac and iPhone) read from the library: which
// models produced the results people already have. Results name their model through recorded
// provenance (`ProcessingSettings.model`), or, from before the model system, through a legacy ID
// the catalog's migration table resolves.

extension ModelCatalog {
    /// The variant keys behind one conversation's transcripts, speaker runs, and summary.
    public func resultModelKeys(in meeting: Meeting) -> Set<String> {
        var keys = Set<String>()
        func add(_ settings: ProcessingSettings?, _ modelID: String) {
            guard let provenance = provenance(of: settings, modelID: modelID) else {
                // A key this catalog no longer lists still names its variant.
                let id = settings?.model?.variantKey ?? settings?.modelID ?? modelID
                if id.contains("/") { keys.insert(ModelReference(id).id) }
                return
            }
            keys.insert(provenance.variantKey)
        }
        for transcript in meeting.transcripts { add(transcript.processingSettings, transcript.modelID) }
        for speaker in meeting.speakers where speaker.analysisSettings != nil {
            add(speaker.analysisSettings, speaker.analysisSettings?.modelID ?? "")
        }
        if let summary = meeting.summary { add(summary.processingSettings, summary.modelID) }
        return keys
    }

    /// Variant key → how many conversations have at least one result from it.
    public func resultCounts(in meetings: [Meeting]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for meeting in meetings {
            for key in resultModelKeys(in: meeting) { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// Every variant key with a result anywhere in `meetings`.
    public func resultModelKeys(in meetings: [Meeting]) -> Set<String> {
        meetings.reduce(into: Set<String>()) { $0.formUnion(resultModelKeys(in: $1)) }
    }
}
