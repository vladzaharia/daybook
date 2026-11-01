#if DEBUG
import DaybookCore
import DaybookKit
import Foundation

/// Debug-only: "Upgrade" offers on the page, without another Mac, a key, or the network (docs/multipoint.md, "Upgrade"):
///
///     --upgrade-demo mac|here|cloud|waiting
///
/// With `--library-demo`, on "Offsite retro" (add `--select "Offsite retro"`):
///
/// - `mac`: its transcript was made with Parakeet Redux (as on a 4 GB iPhone), this Mac transcribes with Whisper Large
///   v3 Turbo, and Studio Mac, seen through sync a minute ago, has Parakeet Ultra: "Upgrade transcript on Studio Mac".
/// - `here`: the same transcript, and this Mac has Parakeet Ultra: "Upgrade transcript".
/// - `cloud`: an Anthropic key in memory (`CloudSetup.demo`, never reaching a provider or the keychain): "Upgrade
///   summary with Claude Sonnet 5.5" for its Gemma 4 E2B summary.
/// - `waiting`: `mac`, accepted: "Waiting for Studio Mac to upgrade the transcript".
///
/// Without `--upgrade-demo` the library demo offers no upgrades, so its other captures stay as they were.
@MainActor
enum UpgradeDemo {
    enum Scenario: String { case mac, here, cloud, waiting }

    static let scenario = LaunchOptions.value(after: "--upgrade-demo").flatMap(Scenario.init(rawValue:))

    /// Whether this launch shows offers: always, except a library demo that didn't ask for them.
    static var showsOffers: Bool { scenario != nil || !LibraryDemo.isRequested }

    static func apply(to state: AppState) {
        guard let scenario, let id = state.meetings.first(where: { $0.title == LibraryDemo.older })?.id else { return }
        switch scenario {
        case .mac, .here, .waiting:
            state.update(id) { meeting in
                for index in meeting.transcripts.indices {
                    meeting.transcripts[index].modelID = "parakeet/redux"
                    meeting.transcripts[index].processingSettings = ProcessingSettings(modelID: "parakeet/redux")
                }
            }
            state.transcriptionModel = scenario == .here ? "parakeet/ultra" : "whisper/large-v3-turbo"
            state.installedModels = Set(state.routedRequiredModelIDs)
            guard scenario != .here else { return }
            var studio = KnownSyncDevice(id: "demo-studio-mac", deviceClass: .mac, displayName: "Studio Mac", canProcess: true,
                                         lastSeen: Date().addingTimeInterval(-60))
            studio.capabilities = SyncDeviceCapabilities(transcribes: true, findsSpeakers: true, summarizes: true,
                                                         models: ["transcription": "parakeet/ultra", "diarization": "nemotron-3-diarization/offline",
                                                                  "summarization": "gemma-4/26b-a4b-qat-4bit"])
            state.syncDevices = [studio]
            if scenario == .waiting, let meeting = state.meetings.first(where: { $0.id == id }), let offer = state.upgradeOffer(for: meeting) {
                state.acceptUpgrade(offer, for: id)
            }
        case .cloud:
            state.cloud = CloudSetup.demo(providers: [.anthropic], defaults: LaunchOptions.defaults)
            state.cloudSummarizer = PlacementDemo.StandIn()
        }
    }
}
#endif
