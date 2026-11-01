import DaybookCore
import Foundation

/// Summarizes one conversation with this device's own language model: the seam the summary step calls
/// when a summary is placed on this device (`SummaryPlace.thisDevice`; docs/multipoint.md, "Where summaries
/// run"). The iPhone's is `LocalSummarizer` in DaybookIntelligence (MLX, the Mac's summary pipeline); tests
/// use a fake.
///
/// A device offers one only when it can summarize (`ProcessingCapabilities.summarizes`): a summary model is
/// chosen, downloaded, and fits in memory. Until then it has none, and its summaries go to a Mac or the cloud.
public protocol LocalSummarizing: Sendable {
    /// The model it summarizes with (a catalog key), for provenance and for other devices.
    var model: String { get }
    /// Whether it can run now: its model is installed and this device has the memory for it. The planner
    /// counts down to this device only when it can.
    var canSummarize: Bool { get }
    /// The summary, with the terms it suggests for the vocabulary and anything worth a warning. `progress`
    /// is 0…1.
    func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                   progress: @escaping @Sendable (Double) -> Void) async throws -> SummaryProcessingOutput
}
