#if DEBUG
import DaybookKit
import DaybookLink
import Foundation

/// Debug only: where a summary runs, on screen without a key, a Mac, or the network
/// (docs/multipoint.md, "Where summaries run"). With `--demo-library`, on "Weekly product sync":
///
///     --placement-demo countdown|waiting|cloud|mac-countdown|colophon
///
/// - `countdown`: this iPhone counts down to sending it to Studio Mac (use with `--demo-link`, whose
///   Studio Mac is connected and summarizes).
/// - `waiting`: no Mac is reachable: "Waiting for a Mac to summarize" with Use the Cloud.
/// - `cloud`: summarizing with Claude Sonnet 5.5 (a stand-in that never finishes).
/// - `mac-countdown`: Studio Mac counts down to summarizing it, with Use the Cloud and Start Now here
///   (use with `--demo-link`).
/// - `colophon`: its summary made in the cloud by this iPhone.
///
/// Add `--status-detent medium` (without `--select`) for the status sheet's Macs card.
@MainActor
enum PhonePlacementDemo {
    static let scenario = LaunchOptions.value(after: "--placement-demo", in: CommandLine.arguments)
    static let title = "Weekly product sync"
    static let sonnet = CloudModel(provider: .anthropic, id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", tier: .balanced,
                                   inputPrice: 2, outputPrice: 10, priceIsEstimated: false, contextTokens: 200_000, rank: 1)

    /// A cloud that offers Claude Sonnet 5.5 and never finishes.
    struct StandIn: CloudSummarizing {
        func availableModels(refresh: Bool) async -> [CloudModel] { [PhonePlacementDemo.sonnet] }
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
        let placement = model.placement
        var preferences = placement.preferences
        preferences.countdownSeconds = 30
        placement.preferences = preferences
        placement.cloudSummarizer = StandIn()
        await placement.refreshCloudModels()
        switch scenario {
        case "countdown", "waiting":
            placement.summaryIsDue(meeting.id)
        case "cloud":
            placement.summaryIsDue(meeting.id)
            placement.perform(.useCloud, for: meeting.id)
        case "mac-countdown":
            guard let studio = model.link.macs.first else { return }
            let live = LiveProgress(LinkProcessingProgress(meetingID: meeting.id, phase: .summaryCountdown, macName: studio.name,
                                                           countdown: LinkSummaryCountdown(secondsLeft: 30, cloudOffered: true)), from: studio.id)
            model.link.applyDemo(macs: model.link.macs, progress: [live])
        case "colophon":
            guard let summary = meeting.summary else { return }
            library.update(meeting.id) { $0.setSummary(summary.placed(.cloud(sonnet), by: library.thisDevice, inputs: meeting.modelsBehindTranscript)) }
        default:
            break
        }
    }
}
#endif
