import DaybookCore
import DaybookTestSupport
import Foundation
import Observation
import XCTest
@testable import DaybookDevices

/// The session and the hub reach a recorder's optional abilities through their protocols, never a kind's concrete
/// type: a second kind with Listen Live, its button, Fast Transfer, or automatic import gets the same behaviour as
/// Soundcore Work. No Bluetooth: a fake recorder of a kind of its own.
@MainActor
final class DeviceCapabilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var staging: URL!

    override func setUp() async throws {
        defaults = makeTestDefaults("local.daybook.tests.capabilities")
        staging = makeTemporaryFolder("DaybookCapabilities")
    }

    private static let kind = DeviceKind(id: "test.live", name: "Test Recorder", shortName: "Test", vendor: nil, systemImage: "mic",
                                         summary: "A recorder for tests.",
                                         methods: [ConnectionMethod(kind: .direct, transport: .bluetoothLE, title: "Directly",
                                                                    summary: "", systemImage: "antenna.radiowaves.left.and.right",
                                                                    setupAction: "Continue…")],
                                         audioSource: .imported, allowsMultiple: false)

    private struct Integration: DeviceIntegration {
        let recorder: FakeRecorder
        var kind: DeviceKind { DeviceCapabilityTests.kind }
        func makeConnection(_ method: ConnectionMethodKind, for device: ConfiguredDevice, environment: DeviceEnvironment) -> (any DeviceConnection)? {
            method == .direct ? recorder : nil
        }
    }

    func testBehaviorAnotherKindWithTheSameAbilitiesGetsTheSameBehaviour() async throws {
        let recorder = FakeRecorder(staging: staging)
        let session = DeviceSession(device: ConfiguredDevice(id: "fake", kind: Self.kind), kind: Self.kind, connections: [recorder],
                                    defaults: defaults)
        let conversation = UUID()
        var saved: [(identity: DeviceRecordingIdentity, attachTo: UUID?)] = []
        session.importer = { url, identity, attachTo, _ in
            saved.append((identity, attachTo))
            try? FileManager.default.removeItem(at: url)
            return attachTo ?? UUID()
        }

        // Live audio into a shared recording, metered, and saved when it ends.
        XCTAssertTrue(session.captureLive(into: conversation))
        XCTAssertEqual(session.liveCaptureConversation, conversation)
        XCTAssertTrue(session.isListeningLive)
        XCTAssertFalse(session.captureLive(into: UUID()), "one shared recording at a time")
        recorder.live.heard(rms: -6)
        XCTAssertNotNil(session.liveLevel(into: conversation))
        let ended = await session.endLiveCapture(within: .seconds(30))
        XCTAssertEqual(ended?.meetingID, conversation)
        XCTAssertEqual(saved.first?.identity.recordingID, DeviceLibraryLinks.partialID("42"))
        XCTAssertEqual(saved.first?.attachTo, conversation)
        XCTAssertFalse(session.isListeningLive)

        // Its button.
        var presses: [Bool] = []
        session.onRecorderButton = { _, on in presses.append(on) }
        recorder.onButton?(true)
        XCTAssertEqual(presses, [true])

        // Fast Transfer: offered, asked for by the person, and their No turns it off for this recorder.
        XCTAssertTrue(session.offersFastTransfer)
        XCTAssertTrue(session.hasFastTransfer)
        XCTAssertEqual(session.fastTransferStage, .connecting)
        session.importRecordings([DeviceRecording(id: "7")], overWiFi: true)
        XCTAssertEqual(recorder.requested, ["7"])
        XCTAssertEqual(recorder.hasMoreQueued?(), true, "the session says what's waiting")
        recorder.onFastTransferDeclined?()
        XCTAssertEqual(session.device.fastTransferForLongRecordings, false)
        XCTAssertEqual(recorder.preferences.last?.usesFastTransfer, false, "the preference reaches the connection")

        // Another app on its link, and the remembered serial for the library's links.
        recorder.isWaitingForOtherApp = true
        XCTAssertEqual(session.otherAppWait, "Waiting for the Test app to finish")
        XCTAssertEqual(session.recorderSerial, "FAKE1")
        session.stopAll()
    }

    /// A background wake reaches every recorder that schedules its own automatic imports.
    func testBehaviorABackgroundWakeReachesAnyKindThatImportsOnItsOwn() throws {
        let recorder = FakeRecorder(staging: staging)
        let saved = DeviceCatalog.integrations
        DeviceCatalog.integrations = saved + [Integration(recorder: recorder)]
        defer { DeviceCatalog.integrations = saved }
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { XCTFail("No Bluetooth"); return InertSoundcoreTransport() }
        let hub = DeviceHub(environment: environment)
        _ = try XCTUnwrap(hub.add(ConfiguredDevice(id: "fake", kind: Self.kind)))
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        hub.resumeAutomaticImportsIfDue(now: now)
        XCTAssertEqual(recorder.resumed, [now])
        hub.shutDown()
    }
}

/// A recorder with every optional ability, which records what it's asked.
@MainActor
@Observable
private final class FakeRecorder: LiveListeningConnection, RecordingStateConnection, ManagedConnection, FastTransferConnection,
                                  AutomaticImportScheduling {
    let method = ConnectionMethodKind.direct
    var state: ConnectionState = .connected
    let capabilities: DeviceCapabilities = [.liveListening, .recordControl]
    var recordings: [DeviceRecording] = []
    var inventoryUpdatedAt: Date? = Date()
    var isRefreshing = false
    var status: DeviceStatus?
    var problem: DeviceProblem?
    var lastConnectedAt: Date?
    var summary = "Connected"
    var isSetUp = true
    var isWaitingForOtherApp = false
    @ObservationIgnored var onChange: (() -> Void)?
    private(set) var preferences: [ConfiguredDevice] = []

    private let staging: URL

    init(staging: URL) { self.staging = staging }

    func activate() {}
    func connect() {}
    func disconnect() {}
    func refresh() {}
    func dismissProblem() {}
    func forget() {}
    func preferencesChanged(_ device: ConfiguredDevice) { preferences.append(device) }
    func transfer(_ recording: DeviceRecording, progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio {
        throw DeviceTransferError.notConnected
    }
    func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording] { [] }

    // Listening
    let live = LiveCapture()
    private(set) var liveConversation: UUID?
    private(set) var listeningTask: Task<Void, Never>?
    @ObservationIgnored var onLiveSaved: ((URL, String, TimeInterval, UUID?) -> Void)?
    @ObservationIgnored private var stop: AsyncStream<Void>.Continuation?

    func startListening() { startListening(into: nil, captions: true) }

    @discardableResult
    func startListening(into conversation: UUID?, captions: Bool) -> Bool {
        guard !live.isListening else { return false }
        live.isListening = true
        liveConversation = conversation
        let (stopped, stop) = AsyncStream<Void>.makeStream()
        self.stop = stop
        let file = staging.appendingPathComponent("live-\(UUID().uuidString).wav")
        listeningTask = Task {
            for await _ in stopped {}
            try? Data([0]).write(to: file)
            self.onLiveSaved?(file, "42", 1.5, self.liveConversation)
            self.live.isListening = false
            self.live.clearLevel()
            self.liveConversation = nil
        }
        return true
    }

    func stopListening() { stop?.finish() }

    // Record control and what it's recording
    var recordCommandPending = false
    func startRecording() {}
    func pauseRecording() {}
    func recordingState(at now: Date) -> RecorderRecordingState? { nil }
    @ObservationIgnored var onButton: ((Bool) -> Void)?
    @ObservationIgnored var expectsRecording: ((String) -> Bool)?
    var staysConnected = false

    // One owner
    var recorderSerial: String? { "FAKE1" }
    var managedElsewhere: RecorderOwnership?

    // Fast Transfer
    var joinsRecorderWiFi: Bool { true }
    var offersFastTransfer: Bool { true }
    var fastTransferStage: FastTransferStage? { .connecting }
    private(set) var requested: [String] = []
    func requestFastTransfer(_ ids: [String]) { requested += ids }
    @ObservationIgnored var hasMoreQueued: (() -> Bool)?
    @ObservationIgnored var onFastTransferDeclined: (() -> Void)?

    // Automatic import
    var automaticDueAt: Date?
    private(set) var resumed: [Date] = []
    func resumeAutomaticImportIfDue(now: Date) { resumed.append(now) }
}
