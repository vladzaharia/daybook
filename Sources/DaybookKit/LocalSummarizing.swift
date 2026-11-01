import DaybookCore
import Foundation

/// Summarizes one conversation with this device's own language model: the seam the summary step calls
/// when a summary is placed on this device (`SummaryPlace.thisDevice`). The iPhone's is
/// `LocalSummarizer` in DaybookIntelligence (MLX, the Mac's summary pipeline); tests use a fake.
///
/// A device offers one only when it can summarize now (`ProcessingCapabilities.summarizes`): a summary
/// model is chosen, downloaded, and fits in memory.
public protocol LocalSummarizing: Sendable {
    /// The model it summarizes with (a catalog key), for provenance and for other devices.
    var model: String { get }
    /// The summary, with the terms it suggests for the vocabulary. `progress` is 0…1.
    func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                   progress: @escaping @Sendable (Double) -> Void) async throws -> SummaryProcessingOutput
}
