#if DEBUG
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// Debug-only: where a summary runs, on screen without a job, a key, or the network
/// (docs/multipoint.md, "Where summaries run"):
///
///     --placement-demo countdown|cloud|colophon
///
/// - `countdown`: the conversation being processed counts down to summarizing on this Mac (30 s), with
///   Use the Cloud and Start Now. With `--library-demo` it's "Roadmap review"; with `--notes-demo
///   processing`, Floating Notes' conversation.
/// - `cloud`: the same conversation summarizing with Claude Sonnet 5.5.
/// - `colophon`: with `--library-demo`, the ready conversation's summary made in the cloud, and the
///   transcript-only one's summarized on another Mac.
///
/// The cloud is a stand-in that offers one model and never runs.
@MainActor
enum PlacementDemo {
    enum Scenario: String { case countdown, cloud, colophon }

    static let scenario = LaunchOptions.value(after: "--placement-demo").flatMap(Scenario.init(rawValue:))

    nonisolated static let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                   inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)

    /// A cloud that offers Claude Sonnet 5.5 and is never asked.
    struct StandIn: CloudSummarizing {
        func availableModels(refresh: Bool) async -> [CloudModel] { [PlacementDemo.sonnet] }
        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel, effort: CloudEffort,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
            throw CancellationError()
        }
    }

    /// Places the summary of `id`, the conversation this Mac is processing.
    static func apply(to state: AppState, processing id: UUID?) {
        guard let scenario else { return }
        state.cloudSummarizer = StandIn()
        state.cloudModels = [sonnet]
        var preferences = state.cloudPreferences
        preferences.countdownSeconds = 30
        state.cloudPreferences = preferences
        switch scenario {
        case .countdown, .cloud:
            guard let id else { return }
            state.update(id) { $0.status = .summarizing }
            state.processingID = id
            state.processingProgress = IntelligenceProgress(scenario == .cloud ? 0.35 : 0, "Summarizing")
            state.placements.begin(id)
            if scenario == .cloud { state.placements.perform(.useCloud, for: id) }
        case .colophon:
            let me = state.library.thisDevice
            if let ready = state.meetings.first(where: { $0.title == LibraryDemo.ready }), let summary = ready.summary {
                state.update(ready.id) { $0.setSummary(summary.placed(.cloud(sonnet), by: me, inputs: ready.modelsBehindTranscript)) }
            }
            if let older = state.meetings.first(where: { $0.title == LibraryDemo.older }), let summary = older.summary {
                let studio = ProcessingRequest.Device(id: "studio-mac", name: "Studio Mac")
                state.update(older.id) { $0.setSummary(summary.placed(.thisDevice, by: studio, inputs: older.modelsBehindTranscript)) }
            }
        }
    }
}
#endif
