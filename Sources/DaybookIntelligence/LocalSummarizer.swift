import DaybookCore
import DaybookKit
import Foundation

/// Summaries on this device with its own language model (`LocalSummarizing`): the Mac's summary
/// pipeline, `InferenceProcessingEngine.summarize` (MLX, with Apple Foundation Models choosing the
/// title where it's selected and available), so a summary made on an iPhone reads like one made on a
/// Mac and records the same provenance (docs/iphone.md, "Processing on this iPhone").
public struct LocalSummarizer: LocalSummarizing {
    public let engine: InferenceProcessingEngine
    /// Whether it can run now: whoever made it says (the iPhone makes one only once its summary model is
    /// downloaded and fits).
    public let canSummarize: Bool

    /// `engine` is configured with the summary model (`Configuration.summaryModel`).
    public init(engine: InferenceProcessingEngine, canSummarize: Bool = true) {
        self.engine = engine
        self.canSummarize = canSummarize
    }

    public var model: String { engine.configuration.summaryModel.id }

    public func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                          progress: @escaping @Sendable (Double) -> Void) async throws -> SummaryProcessingOutput {
        try await engine.summarize(meeting, template: template, vocabulary: vocabulary) { progress(min(1, max(0, $0.fraction))) }
    }
}
