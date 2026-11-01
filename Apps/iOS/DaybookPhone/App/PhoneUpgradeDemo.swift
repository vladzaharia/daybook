#if DEBUG
import DaybookKit
import DaybookLink
import Foundation

/// Debug only: "Upgrade" offers on the conversation page, without a Mac, a key, models, or the network
/// (docs/multipoint.md, "Upgrade"). With `--demo-library`, on "Weekly product sync" (add `--select "Weekly product sync"`):
///
///     --upgrade-demo mac|here|cloud|waiting
///
/// - `mac`: Vlad's MacBook Pro is connected and transcribes with Parakeet Ultra, better than the Whisper Small that made the
///   transcript: "Upgrade transcript on Vlad's MacBook Pro".
/// - `here`: this iPhone has Parakeet Ultra itself, and the recordings are its own: "Upgrade transcript".
/// - `cloud`: its summary was made here with Gemma 4 E2B, and Settings › Cloud has an in-memory Anthropic key
///   (`CloudSetup.demo`): "Upgrade summary with Claude Sonnet 5.5".
/// - `waiting`: `mac`, accepted: "Waiting for Vlad's MacBook Pro to upgrade the transcript".
@MainActor
enum PhoneUpgradeDemo {
    static let scenario = LaunchOptions.value(after: "--upgrade-demo", in: CommandLine.arguments)
    static let title = "Weekly product sync"

    static func apply(to model: PhoneAppModel) async {
        guard let scenario else { return }
        let library = model.library.controller
        // The demo library is seeded once the library screen appears.
        for _ in 0..<100 where library.meetings.first(where: { $0.title == title }) == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let meeting = library.meetings.first(where: { $0.title == title }) else { return }
        let upgrades = model.upgrades
        switch scenario {
        case "mac", "waiting":
            var mac = PhoneLink.Mac(id: UUID(), name: "Vlad's MacBook Pro", pairedAt: Date().addingTimeInterval(-86_400 * 12), state: .connected,
                                    canProcess: true, appVersion: "1.0", lastConnectedAt: Date())
            mac.processing = ProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: true,
                                                    models: ["transcription": "parakeet/ultra", "diarization": "nemotron-3-diarization/offline",
                                                             "summarization": "gemma-4/26b-a4b-qat-4bit"])
            model.link.applyDemo(macs: [mac])
            if scenario == "waiting", let offer = upgrades.offer(for: meeting) { await upgrades.accept(offer, for: meeting.id) }
        case "here":
            upgrades.capabilities = {
                ProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: false,
                                       models: ["transcription": "parakeet/ultra", "diarization": "nemotron-3-diarization/offline"])
            }
            upgrades.owns = { { _ in true } }
            upgrades.pickUp = {}
        case "cloud":
            // Made on this iPhone with Gemma 4 E2B, as the processor applies one.
            guard var summary = meeting.summary else { return }
            summary.modelID = "gemma-4/e2b-4bit"
            summary.processingSettings = ProcessingSettings(modelID: "gemma-4/e2b-4bit")
            library.update(meeting.id) { $0.summary = summary.placed(.thisDevice, by: library.thisDevice, inputs: $0.modelsBehindTranscript) }
            model.cloudSummaries = CloudSetup.demo(providers: [.anthropic], defaults: .standard)
            model.placement.cloud = model.cloudSummaries
            model.placement.cloudSummarizer = PhonePlacementDemo.StandIn()
        default:
            break
        }
    }
}
#endif
