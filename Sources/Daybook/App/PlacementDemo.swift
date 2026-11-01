#if DEBUG
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// Debug-only: where a summary runs, on screen without a job, a key, or the network
/// (docs/multipoint.md, "Where summaries run"):
///
///     --placement-demo countdown|cloud|colophon|colophon-mac
///
/// - `countdown`: the conversation being processed counts down to summarizing on this Mac (30 s), with
///   Use the Cloud and Start Now. With `--library-demo` it's "Roadmap review"; with `--notes-demo
///   processing`, Floating Notes' conversation.
/// - `cloud`: the same conversation summarizing with Claude Sonnet 5.5.
/// - `colophon`, `colophon-mac`: with `--library-demo`, "Offsite retro"'s summary made in the cloud, or on
///   another Mac.
///
/// The cloud is the real `CloudSetup` with an in-memory Anthropic key and the catalog's models (`CloudSetup.demo`,
/// never reaching a provider or the keychain), and a summarizer that never runs.
@MainActor
enum PlacementDemo {
    enum Scenario: String { case countdown, cloud, colophon, colophonMac = "colophon-mac" }

    static let scenario = LaunchOptions.value(after: "--placement-demo").flatMap(Scenario.init(rawValue:))

    /// A summarizer that's never asked: the countdown and the cloud at work are only shown.
    struct StandIn: CloudSummarizing {
        func availableModels(refresh: Bool) async -> [CloudModel] { [] }
        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel, effort: CloudEffort,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
            throw CancellationError()
        }
    }

    /// Places the summary of `id`, the conversation this Mac is processing.
    static func apply(to state: AppState, processing id: UUID?) {
        guard let scenario else { return }
        var preferences = CloudSummaryPreferences()
        preferences.countdownSeconds = 30
        state.cloud = CloudSetup.demo(providers: [.anthropic], preferences: preferences, defaults: LaunchOptions.defaults)
        state.cloudSummarizer = StandIn()
        guard let sonnet = state.cloud.resolved?.model else { return }
        switch scenario {
        case .countdown, .cloud:
            guard let id else { return }
            state.update(id) { $0.status = .summarizing }
            state.processingID = id
            state.processingProgress = IntelligenceProgress(scenario == .cloud ? 0.35 : 0, "Summarizing")
            state.placements.begin(id)
            if scenario == .cloud { state.placements.perform(.useCloud, for: id) }
        case .colophon, .colophonMac:
            guard let older = state.meetings.first(where: { $0.title == LibraryDemo.older }), var summary = older.summary else { return }
            // Its own model again, so the demo's earlier runs don't leave the cloud's behind.
            summary.modelID = "gemma-4/e2b-4bit"
            summary.processingSettings = nil
            let placed = scenario == .colophon
                ? summary.placed(.cloud(sonnet), by: state.library.thisDevice, inputs: older.modelsBehindTranscript)
                : summary.placed(.thisDevice, by: ProcessingRequest.Device(id: "studio-mac", name: "Studio Mac"), inputs: older.modelsBehindTranscript)
            state.update(older.id) { $0.setSummary(placed) }
        }
    }
}
#endif
