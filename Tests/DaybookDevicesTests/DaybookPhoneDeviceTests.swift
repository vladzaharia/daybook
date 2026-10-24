import DaybookCore
import Foundation
import XCTest
@testable import DaybookDevices

/// Daybook on iPhone as a device kind: its two methods, a paired phone joining the hub under its own
/// ID, and its recordings, which are listed from the library because they arrive through sync.
@MainActor
final class DaybookPhoneDeviceTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "local.daybook.tests.phone-device.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func environment(syncs: @escaping () -> Bool = { true }, paired: Set<String> = []) -> DeviceEnvironment {
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: FileManager.default.temporaryDirectory)
        environment.soundcoreTransport = { XCTFail("No Bluetooth"); return InertSoundcoreTransport() }
        environment.phone.syncIsOn = syncs
        environment.phone.pairedPhoneIDs = { paired }
        return environment
    }

    private func track(_ kind: String, serial: String?, recording: String, start: Date) -> RecordingTrack {
        RecordingTrack(source: .microphone, relativePath: "Originals/\(recording).m4a", fileName: "\(recording).m4a", createdAt: start,
                       duration: 60, device: DeviceRecordingIdentity(kind: kind, serial: serial, recordingID: recording), startedAt: start)
    }

    func testThePhoneIsAKindWithSyncedRecordingsAndADirectLink() {
        let kind = try? XCTUnwrap(DeviceCatalog.kind(DaybookPhoneIntegration.id))
        XCTAssertEqual(kind?.name, "Daybook on iPhone")
        XCTAssertEqual(kind?.implementedMethods.map(\.kind), [.files, .direct], "Recordings arrive through sync; the link adds control")
        XCTAssertEqual(kind?.method(.direct)?.transport, .localNetwork)
        XCTAssertEqual(kind?.allowsMultiple, true, "One per paired phone")
        XCTAssertTrue(DeviceCatalog.kinds.contains { $0.id == DaybookPhoneIntegration.id }, "Offered in Add Device")
    }

    func testAPairedPhoneJoinsTheHubUnderItsIDAndListsOnlyItsOwnRecordings() throws {
        let phone = UUID().uuidString, other = UUID().uuidString
        var syncs = true
        let hub = DeviceHub(environment: environment(syncs: { syncs }, paired: [phone, other]))
        let kind = DaybookPhoneIntegration().kind
        let session = try XCTUnwrap(hub.add(ConfiguredDevice(id: phone, kind: kind, name: "Alex’s iPhone")))
        XCTAssertTrue(hub.add(ConfiguredDevice(id: phone, kind: kind)) === session, "Adding it again finds it")
        XCTAssertEqual(hub.sessions.count, 1)
        XCTAssertNil(session.files, "No watched folder")
        XCTAssertNil(session.direct, "The app supplies the link; without it there's no direct method")
        let synced = try XCTUnwrap(session.connection(.files) as? SyncedPhoneRecordings)
        hub.start()
        XCTAssertEqual(synced.state, .connected)
        XCTAssertTrue(synced.isSetUp)

        let now = Date()
        let mine = Meeting(title: "Walk", tracks: [track(DaybookPhoneIntegration.id, serial: phone, recording: "A", start: now)])
        let theirs = Meeting(title: "Theirs", tracks: [track(DaybookPhoneIntegration.id, serial: other, recording: "B", start: now)])
        let unknown = Meeting(title: "Unaligned ID", tracks: [track(DaybookPhoneIntegration.id, serial: "install-1", recording: "C", start: now.addingTimeInterval(-60))])
        let recorder = Meeting(title: "Soundcore", tracks: [track(SoundcoreWorkIntegration.id, serial: "S1", recording: "1729000000", start: now)])
        hub.libraryChanged([mine, theirs, unknown, recorder], ready: true)
        XCTAssertEqual(synced.recordings.map(\.id), ["A", "C"], "Its own, newest first; another paired phone's stay with that phone")
        XCTAssertEqual(synced.recordings.first?.length, .exact(60))
        XCTAssertEqual(session.split.imported.map(\.id), ["A", "C"], "Already in Daybook: nothing to import")
        XCTAssertTrue(session.split.new.isEmpty)
        XCTAssertEqual(session.links.imported["A"], mine.id)

        syncs = false
        synced.refresh()
        XCTAssertEqual(synced.state, .unavailable)
        XCTAssertEqual(synced.problem?.id, "syncOff")
        XCTAssertEqual(session.problem?.id, "syncOff")

        // Remembered like any device.
        let again = DeviceHub(environment: environment())
        XCTAssertEqual(again.session(phone)?.kind.id, DaybookPhoneIntegration.id)
        XCTAssertEqual(again.session(phone)?.device.name, "Alex’s iPhone")
    }

    func testTheAppSuppliesTheLinkAsTheDirectMethod() throws {
        var environment = environment()
        let link = InertConnection()
        environment.phone.makeLinkConnection = { _ in link }
        let hub = DeviceHub(environment: environment)
        let session = try XCTUnwrap(hub.add(ConfiguredDevice(id: UUID().uuidString, kind: DaybookPhoneIntegration().kind)))
        XCTAssertTrue(session.direct === link)
        XCTAssertEqual(session.setUpMethods, [.files, .direct])
    }
}

/// A direct method that does nothing, standing in for the app's link adapter.
@MainActor
private final class InertConnection: ObservableObject, DeviceConnection {
    let method = ConnectionMethodKind.direct
    let capabilities: DeviceCapabilities = [.recordControl]
    var state: ConnectionState = .notConnected
    var recordings: [DeviceRecording] = []
    var inventoryUpdatedAt: Date?
    var isRefreshing = false
    var status: DeviceStatus?
    var problem: DeviceProblem?
    var lastConnectedAt: Date?
    var summary = ""
    var isSetUp = true
    var onChange: (() -> Void)?
    func activate() {}
    func connect() {}
    func disconnect() {}
    func refresh() {}
    func dismissProblem() {}
    func forget() {}
    func transfer(_ recording: DeviceRecording, progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio {
        throw DeviceTransferError.notConnected
    }
    func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording] { [] }
}
