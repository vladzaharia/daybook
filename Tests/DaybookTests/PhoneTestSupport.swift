import AVFoundation
import DaybookCore
@testable import DaybookKit
import DaybookLink
import Foundation
import XCTest
@testable import Daybook

// Daybook on iPhone without an iPhone: a `LinkClient` over loopback stands in for the phone's link,
// and a DaybookKit library on its own sync replica stands in for its library. Nothing is
// advertised, nothing touches the keychain, the microphone, or a model.

/// A clock running ahead of this Mac's, like a phone whose clock is off.
struct SkewedClock: LinkClock {
    let offset: TimeInterval
    func now() -> Date { Date().addingTimeInterval(offset) }
}

/// Collects a link's events so tests can wait for them.
final class LinkEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LinkEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<LinkEvent>) {
        task = Task { [weak self] in for await event in stream { self?.append(event) } }
    }
    deinit { task?.cancel() }
    private func append(_ event: LinkEvent) { lock.withLock { events.append(event) } }
    var all: [LinkEvent] { lock.withLock { events } }

    var progress: [LinkProcessingProgress] {
        all.compactMap { if case .received(.processingProgress(let progress), _) = $0 { return progress }; return nil }
    }
    var unpaired: Bool { all.contains { if case .unpaired = $0 { return true }; return false } }
    /// What the Mac said about its own recorder, in order.
    var states: [LinkRecordingState] {
        all.compactMap { if case .received(.recordingState(let state), _) = $0 { return state }; return nil }
    }
}

/// What the phone's record-control handler was asked, and how it answers.
final class PhoneRecorderScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [LinkRecordRequest] = []
    private var _delays: [LinkRecordRequest.Action: Duration] = [:]
    var requests: [LinkRecordRequest] { lock.withLock { _requests } }
    /// Answers each request; the default acknowledges with a recording ID.
    var answer: @Sendable (LinkRecordRequest) -> LinkRecordReply.Outcome = { request in
        .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "R-\(request.conversationID)"))
    }
    /// How long the phone takes to answer (a microphone prompt, say).
    func delay(_ action: LinkRecordRequest.Action, by delay: Duration?) { lock.withLock { _delays[action] = delay } }

    func record(_ request: LinkRecordRequest) async -> LinkRecordReply.Outcome {
        let delay = lock.withLock { () -> Duration? in _requests.append(request); return _delays[request.action] }
        if let delay { try? await Task.sleep(for: delay) }
        return answer(request)
    }
}

/// A paired phone, connected to the Mac over loopback.
@MainActor
struct PhoneLinkRig {
    let phoneID: UUID
    let macID: UUID
    let client: LinkClient
    let events: LinkEvents
    let recorder = PhoneRecorderScript()
    let endpoint: LinkEndpoint

    nonisolated static let phoneName = "Pocket iPhone"

    /// Loopback services with memory key stores for this Mac's link. Call before anything starts it.
    static func useLoopback(_ state: AppState, keyStore: MemoryLinkKeyStore) {
        state.phoneLink.environment = .init { identity in
            LinkService(identity: identity, keyStore: keyStore, configuration: .loopback())
        }
    }

    /// Pairs a phone without the code (as if it had paired before), adds it as a device, starts the
    /// Mac's link, and connects the phone. `clockOffset` is how far the phone's clock is ahead.
    static func connect(_ state: AppState, clockOffset: TimeInterval = 0) async throws -> PhoneLinkRig {
        let phoneID = UUID(), macID = state.phoneLink.identity.deviceID
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let psk = Data((0..<16).map { _ in UInt8.random(in: 1...255) })
        let macStore = MemoryLinkKeyStore([LinkPairingRecord(deviceID: phoneID, name: phoneName, deviceClass: .iPhone, pairedAt: Date(),
                                                             linkKey: key, pskIdentity: psk)])
        let phoneStore = MemoryLinkKeyStore([LinkPairingRecord(deviceID: macID, name: state.phoneLink.identity.name, deviceClass: .mac,
                                                               pairedAt: Date(), linkKey: key, pskIdentity: psk)])
        useLoopback(state, keyStore: macStore)
        state.devices.add(ConfiguredDevice(id: phoneID.uuidString, kind: DaybookPhoneIntegration().kind, name: phoneName))
        await state.startPhoneLinkIfPaired()
        let listening = await state.phoneLink.port
        let port = try XCTUnwrap(listening)
        var configuration = LinkConfiguration.loopback()
        configuration.clock = SkewedClock(offset: clockOffset)
        let client = LinkClient(identity: LinkIdentity(deviceID: phoneID, name: phoneName, deviceClass: .iPhone, appVersion: "2.0"),
                                keyStore: phoneStore, configuration: configuration)
        let rig = PhoneLinkRig(phoneID: phoneID, macID: macID, client: client, events: LinkEvents(client.events()),
                               endpoint: LinkEndpoint(host: "127.0.0.1", port: port))
        let script = rig.recorder
        await client.setRecordControlHandler { _, request in await script.record(request) }
        try await client.connect(to: macID, via: rig.endpoint)
        try await waitFor("the phone to connect, with a clock estimate") { state.phoneLink.peers[phoneID]?.clock != nil }
        return rig
    }

    func tearDown(_ state: AppState) async {
        await client.disconnect(from: macID)
        await state.phoneLink.shutDown()
    }
}

/// The iPhone's library: DaybookKit on an on-demand phone replica of the same sync folder, filing
/// recordings the way the iPhone app does (`PhoneLibrary.file`).
@MainActor
struct PhoneLibrarySide {
    let library: LibraryController
    let sync: LibrarySyncController
    let defaults: UserDefaults
    let suite: String
    let phoneID: UUID

    static func make(root: URL, cloud: URL, phoneID: UUID) async throws -> PhoneLibrarySide {
        // A suite named by a path inside the test's folder keeps its plist there, not in ~/Library/Preferences.
        let suite = root.appendingPathComponent("Preferences").path
        let defaults = UserDefaults(suiteName: suite)!
        let local = root.appendingPathComponent("Phone", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let sync = LibrarySyncController(localRoot: local, defaults: defaults)
        sync.replica = .phone(displayName: PhoneLinkRig.phoneName)
        try sync.connect(to: cloud, monitorChanges: false)
        sync.onSyncRequested = nil
        let library = LibraryController(rootURL: local, sync: sync)
        try await library.load()
        return PhoneLibrarySide(library: library, sync: sync, defaults: defaults, suite: suite, phoneID: phoneID)
    }

    var device: ProcessingRequest.Device { ProcessingRequest.Device(id: sync.deviceID, name: PhoneLinkRig.phoneName) }

    /// Files a phone recording as the iPhone app does (`PhoneLibrary.fileRecording`): on its own, a
    /// conversation whose ID is the recording's, with one microphone track tagged as Daybook on iPhone
    /// at offset 0; into a conversation a Mac leads (`into`), a track still to be placed, with its
    /// bookmarks on it and its notes held by it (`Meeting.addRecordingWork`). Then a Transcribe
    /// request for a Mac. `start` is by the phone's clock.
    @discardableResult
    func file(_ audio: URL, recordingID: UUID, into conversation: UUID? = nil, start: Date, duration: TimeInterval,
              title: String = "iPhone recording", notes: [TimedNote] = [], bookmarks: [Highlight] = [],
              shift: TimeInterval = 0, peerClocks: [CapturePeerClock]? = nil) async throws -> UUID {
        let id = conversation ?? recordingID
        let joining = conversation != nil
        if library.meeting(id) == nil { library.add(Meeting(id: id, title: title, date: start, status: joining ? .draft : .imported)) }
        let identity = DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: phoneID.uuidString, recordingID: recordingID.uuidString)
        await library.acquireLock()
        var provenance = RecordingProvenance(source: .microphone, device: identity, offset: joining ? nil : 0, duration: duration,
                                             startedAt: start, capture: TrackCaptureDetails(method: "iphone-microphone", peerClocks: peerClocks))
        provenance.joinsConversation = joining
        let ingested = try await library.ingest(audio, into: id, provenance: provenance)
        library.releaseLock()
        let track = try XCTUnwrap(ingested.track?.id)
        library.update(id) { $0.addRecordingWork(trackID: track, notes: notes, bookmarks: bookmarks, joining: joining, shift: shift) }
        library.requestProcessing(id, mode: .newAudio, by: device)
        await library.flush()
        return id
    }

    /// A recorder's recording the phone imported (it manages the recorder now), into a conversation
    /// of its own, with a Transcribe request for a Mac, as the phone's device hub files it.
    @discardableResult
    func fileFromRecorder(_ audio: URL, identity: DeviceRecordingIdentity, start: Date) async throws -> UUID {
        let id = library.newMeeting(title: "Soundcore Work at \(start.formatted(date: .omitted, time: .shortened))", date: start)
        await library.acquireLock()
        _ = try await library.ingest(audio, into: id, provenance: .file(source: .soundcore, device: identity, duration: 0.5))
        library.releaseLock()
        library.requestProcessing(id, mode: .newAudio, by: device)
        await library.flush()
        return id
    }

    func synchronize() async { _ = await library.synchronize() }

    func tearDown() {
        sync.disconnect()
        defaults.removePersistentDomain(forName: suite)
    }
}

extension MultiSourceRig {
    /// Connects the library to a shared sync folder. Passes run only when a test (or a phone's
    /// nudge) asks, never on the debounce timer, so the order of passes is the test's.
    func connectSync(_ cloud: URL) throws {
        try state.sync.connect(to: cloud, monitorChanges: false)
        state.sync.onSyncRequested = nil
    }

    /// A conversation whose recording is in, waiting: imported while models are missing, then
    /// models restored without queueing it.
    func waitingConversation(_ title: String, audio: URL, script: [(Double, String)]) async throws -> UUID {
        try inference.script(audio, script)
        let id = try await macConversation(title, at: Date().addingTimeInterval(-120), seconds: 0.5, audio: audio)
        state.awaitingModels.remove(id)
        return id
    }
}

extension XCTestCase {
    /// A folder outside every library (a sync folder can't overlap one), removed after the test.
    func temporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Daybook\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// Waits on the main actor until `condition` holds.
@MainActor
func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

extension ProcessingRequest.Device {
    static let phone = ProcessingRequest.Device(id: "phone-replica", name: PhoneLinkRig.phoneName)
}
