#if DEBUG
import DaybookCore
import DaybookKit
import DaybookLink
import Foundation

/// Debug-only states for Daybook on iPhone's surfaces, without an iPhone or the network:
///
///     --device-demo none --phone-demo connected|recording|not-connected|pairing --library <folder>
///
/// The link runs on loopback with keys in memory (never Bonjour or the keychain), and a phone
/// in this process connects to it. It works only alongside a device demo, whose hub saves nothing,
/// so the demo phone never reaches real preferences.
@MainActor
enum PhoneDemo {
    enum Scenario: String { case connected, recording, notConnected = "not-connected", pairing }

    static let scenario: Scenario? = LaunchOptions.value(after: "--phone-demo").flatMap(Scenario.init(rawValue:))
    static var isActive: Bool { scenario != nil && DeviceDemo.isRequested }

    private static let phoneID = UUID(uuidString: "D0A1F0E5-0000-4000-8000-0000000F0E15")!
    private static let phoneName = "Alex’s iPhone"
    /// The phone in this process, kept for the life of the demo.
    private static var client: LinkClient?

    static func apply(to state: AppState) {
        guard let scenario, isActive else { return }
        Task { await run(scenario, state: state) }
    }

    private static func run(_ scenario: Scenario, state: AppState) async {
        // With `--library-demo`, its conversations and selection land first (it's applied in the
        // same launch step, before this task runs), then the phone's page opens.
        await LibraryDemo.seeding?.value
        let macID = state.phoneLink.identity.deviceID
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let psk = Data((0..<16).map { _ in UInt8.random(in: 1...255) })
        let paired = scenario != .pairing
        let macStore = MemoryLinkKeyStore(paired ? [LinkPairingRecord(deviceID: phoneID, name: phoneName, deviceClass: .iPhone,
                                                                      pairedAt: Date().addingTimeInterval(-9 * 86_400), linkKey: key, pskIdentity: psk)] : [])
        state.phoneLink.environment = .init { identity in
            LinkService(identity: identity, keyStore: macStore, configuration: .loopback())
        }
        if scenario == .pairing {
            state.requestAddDevice(kind: DaybookPhoneIntegration.id)
            return
        }
        state.devices.add(ConfiguredDevice(id: phoneID.uuidString, kind: DaybookPhoneIntegration().kind, name: phoneName,
                                           addedAt: Date().addingTimeInterval(-9 * 86_400)))
        addRecordings(to: state)
        await state.startPhoneLinkIfPaired()
        state.place = .device(phoneID.uuidString)
        guard scenario != .notConnected, let port = await state.phoneLink.port else { return }
        let phoneStore = MemoryLinkKeyStore([LinkPairingRecord(deviceID: macID, name: state.phoneLink.identity.name, deviceClass: .mac,
                                                               pairedAt: Date(), linkKey: key, pskIdentity: psk)])
        let client = LinkClient(identity: LinkIdentity(deviceID: phoneID, name: phoneName, deviceClass: .iPhone, appVersion: "1.0"),
                                keyStore: phoneStore, configuration: .loopback())
        self.client = client
        try? await client.connect(to: macID, via: LinkEndpoint(host: "127.0.0.1", port: port))
        guard scenario == .recording else { return }
        for _ in 0..<50 where state.phoneLink.peers[phoneID] == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let conversation = state.meetings.first { $0.title == "Walk with Priya" }?.id
        try? await client.send(.recordingState(LinkRecordingState(phase: .recording, conversationID: conversation,
                                                                  startedAt: Date().addingTimeInterval(-754), elapsed: 754)))
    }

    /// A few conversations the phone recorded, as they look once they've synced (no audio files).
    private static func addRecordings(to state: AppState) {
        let titles = [("Walk with Priya", 0.2), ("Kitchen planning", 26.0), ("Voice memo", 74.0)]
        for (title, hoursAgo) in titles where !state.meetings.contains(where: { $0.title == title }) {
            let start = Date().addingTimeInterval(-hoursAgo * 3600)
            let recording = UUID()
            let track = RecordingTrack(source: .microphone, relativePath: "Originals/\(recording.uuidString).m4a", fileName: "\(recording.uuidString).m4a",
                                       createdAt: start, duration: 1_840,
                                       device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: phoneID.uuidString,
                                                                       recordingID: recording.uuidString),
                                       startedAt: start)
            state.library.add(Meeting(title: title, date: start, tracks: [track], status: .imported))
        }
    }
}
#endif
