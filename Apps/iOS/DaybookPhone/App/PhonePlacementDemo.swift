#if DEBUG
import DaybookKit
import DaybookLink
import Foundation

/// Debug only: where a summary runs, on screen without a key, a Mac, or the network
/// (docs/multipoint.md, "Where summaries run"). With `--demo-library`, on "Weekly product sync":
///
///     --placement-demo countdown|waiting|cloud|mac-countdown|colophon|colophon-local
///
/// - `countdown`: this iPhone counts down to sending it to Studio Mac (use with `--demo-link`, whose
///   Studio Mac is connected and summarizes).
/// - `waiting`: no Mac is reachable: "Waiting for a Mac to summarize" with Use the Cloud.
/// - `cloud`: summarizing with Claude Sonnet 5.5 (a summarizer that never finishes).
/// - `mac-countdown`: Studio Mac counts down to summarizing it, with Use the Cloud and Start Now here
///   (use with `--demo-link`).
/// - `colophon`: its summary made in the cloud by this iPhone; `colophon-local`: made on this iPhone, as the
///   processor applies one.
///
/// The cloud is Settings › Cloud's own `CloudSetup`, with an in-memory Anthropic key and the catalog's models
/// (`CloudSetup.demo`: no provider, no keychain). Add `--status-detent medium` (without `--select`) for the
/// status sheet's Macs card.
@MainActor
enum PhonePlacementDemo {
    static let scenario = LaunchOptions.value(after: "--placement-demo", in: CommandLine.arguments)
    static let title = "Weekly product sync"

    /// A summarizer that never finishes: the cloud at work is only shown.
    struct StandIn: CloudSummarizing {
        func availableModels(refresh: Bool) async -> [CloudModel] { [] }
        func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String], model: CloudModel, effort: CloudEffort,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingSummary {
            try await Task.sleep(for: .seconds(86_400))
            throw CancellationError()
        }
    }

    static func apply(to model: PhoneAppModel) async {
        guard let scenario else { return }
        let library = model.library.controller
        // The demo library is seeded once the library screen appears.
        for _ in 0..<100 where library.meetings.first(where: { $0.title == title }) == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let meeting = library.meetings.first(where: { $0.title == title }) else { return }
        var preferences = CloudSummaryPreferences()
        preferences.countdownSeconds = 30
        model.cloudSummaries = CloudSetup.demo(providers: [.anthropic], preferences: preferences, defaults: .standard)
        let placement = model.placement
        placement.cloud = model.cloudSummaries
        placement.cloudSummarizer = StandIn()
        switch scenario {
        case "countdown", "waiting":
            await placement.summaryIsDue(meeting.id)
        case "cloud":
            await placement.summaryIsDue(meeting.id)
            placement.perform(.useCloud, for: meeting.id)
        case "mac-countdown":
            guard let studio = model.link.macs.first else { return }
            let live = LiveProgress(LinkProcessingProgress(meetingID: meeting.id, phase: .summaryCountdown, macName: studio.name,
                                                           countdown: LinkSummaryCountdown(secondsLeft: 30, cloudOffered: true)), from: studio.id)
            model.link.applyDemo(macs: model.link.macs, progress: [live])
        case "colophon":
            guard let summary = meeting.summary, let sonnet = placement.cloudOffer else { return }
            library.update(meeting.id) { $0.setSummary(summary.placed(.cloud(sonnet), by: library.thisDevice, inputs: meeting.modelsBehindTranscript)) }
        case "colophon-local":
            // As the processor applies a summary placed here (Gemma 4 E2B on this iPhone).
            guard var summary = meeting.summary else { return }
            summary.modelID = "gemma-4/e2b-4bit"
            summary.processingSettings = ProcessingSettings(modelID: "gemma-4/e2b-4bit")
            library.applyPlacedSummary(summary, to: meeting.id, place: .thisDevice, started: .distantPast)
        default:
            break
        }
    }
}
#endif
