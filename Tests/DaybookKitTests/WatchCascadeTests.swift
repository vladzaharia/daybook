import DaybookCore
@testable import DaybookDevices
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest

/// Apple Watch in a shared recording (docs/multipoint.md, "Starting anywhere"): the cascade starts it with the shared
/// recording, or leaves it out quietly when a Start can't reach it, stops it with it (heard at once, or owed until
/// Daybook runs on the watch), and its audio joins the conversation it was recorded for once every segment has
/// arrived, whatever the cascade still remembers and whatever the watch is now. Against the simulated watch: no
/// WatchConnectivity.
@MainActor
final class WatchCascadeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var staging: URL!

    override func setUp() async throws {
        defaults = makeTestDefaults("local.daybook.tests.watch-cascade")
        staging = makeTemporaryFolder("DaybookWatchCascade")
    }

    private struct Rig {
        let session: DeviceSession
        let connection: WatchConnection
        let watch: SimulatedWatch
        let cascade: RecorderCascade
        let imports: Imports
        let environment: DeviceEnvironment
    }

    private final class Imports {
        var all: [(identity: DeviceRecordingIdentity, attachTo: UUID?, source: AudioSource, audio: String)] = []
        var meetings: [Meeting] = []
    }

    private func rig() async throws -> Rig {
        let watch = SimulatedWatch(stagingDirectory: staging, watchID: "watch-install-1")
        watch.segmentLength = 2
        watch.deliversSegments = false
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { XCTFail("No Bluetooth"); return InertSoundcoreTransport() }
        environment.watch.transport = watch
        environment.watch.join = { segments, output in
            var data = Data()
            for segment in segments { data.append(try Data(contentsOf: segment.url)) }
            try data.write(to: output)
        }
        let imports = Imports()
        let (session, connection) = try await launch(environment, imports: imports)
        let cascade = RecorderCascade(sessions: { [session] })
        cascade.timing.connect = .seconds(2)
        cascade.timing.confirm = .seconds(2)
        cascade.timing.inventory = .seconds(2)
        cascade.timing.poll = .milliseconds(20)
        // What the iPhone app does: a Start carries the cascade's shared recording.
        environment.watch.sharedRecording = { [weak cascade] in
            cascade?.conversation.map { WatchSharedRecording(conversationID: $0.id, title: $0.title, startedAt: $0.date ?? Date()) }
        }
        return Rig(session: session, connection: connection, watch: watch, cascade: cascade, imports: imports, environment: environment)
    }

    /// The watch's device as the iPhone app makes it at launch: its session, connected and listed, importing into
    /// `imports` (the conversation it's given, else a new one).
    private func launch(_ environment: DeviceEnvironment, imports: Imports) async throws -> (DeviceSession, WatchConnection) {
        let kind = AppleWatchIntegration().kind
        let device = ConfiguredDevice(id: "apple-watch", kind: kind)
        let connection = try XCTUnwrap(AppleWatchIntegration().makeConnection(.direct, for: device, environment: environment) as? WatchConnection)
        let session = DeviceSession(device: device, kind: kind, connections: [connection], defaults: defaults)
        session.importer = { [weak session] url, identity, attachTo, source in
            let audio = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            imports.all.append((identity, attachTo, source, audio))
            let meeting = Meeting(id: attachTo ?? UUID(), title: "Imported",
                                  tracks: [RecordingTrack(source: source, relativePath: "x", fileName: "x", device: identity)])
            imports.meetings.append(meeting)
            session?.libraryChanged(imports.meetings, ready: true)
            return meeting.id
        }
        session.activate()
        session.libraryChanged(imports.meetings, ready: true)
        addTeardownBlock { session.shutDown() }
        try await waitUntil("connected and listed") { connection.state == .connected && connection.isInventoryCurrent && !connection.isRefreshing }
        return (session, connection)
    }

    private func starts(_ watch: SimulatedWatch) -> [WatchStart] {
        watch.answered.compactMap { if case .start(let start) = $0 { return start } else { return nil } }
    }

    /// Waits for the session to look again at what it has (an automatic-import pass) after `change`: whatever it decided
    /// to import is queued by then.
    private func afterAPass(_ session: DeviceSession, _ change: () async -> Void) async throws {
        let passes = session.evaluations
        await change()
        try await waitUntil("a pass over what changed") { session.evaluations > passes }
    }

    func testTheCascadeStartsTheWatchWithTheSharedRecordingAndItsAudioJoinsTheConversation() async throws {
        let rig = try await rig()
        let conversation = UUID(), date = Date(timeIntervalSince1970: 1_800_000_000)
        rig.cascade.begin(conversation, title: "Design review", date: date, ledHere: true)
        await rig.cascade.startRecorders()

        XCTAssertEqual(starts(rig.watch), [WatchStart(conversationID: conversation, title: "Design review", startedAt: date)])
        let recording = try XCTUnwrap(rig.watch.recording)
        let member = try XCTUnwrap(rig.cascade.member("apple-watch"))
        XCTAssertEqual(member.state, .recording)
        XCTAssertEqual(member.role, .started)
        XCTAssertEqual(member.recordingID, recording.id)
        XCTAssertEqual(rig.cascade.status, "Also recording on Apple Watch.")

        rig.watch.record(5)
        await rig.cascade.stop()
        XCTAssertEqual(rig.cascade.member("apple-watch")?.state, nil, "The conversation ended")
        XCTAssertNil(rig.watch.recording, "Stopped with it")
        XCTAssertEqual(rig.session.conversationWaiting(for: recording.id), conversation, "Its audio is waited for")

        // Its parts arrive out of order: nothing imports until the last one is here.
        try await afterAPass(rig.session) { rig.watch.deliver([2, 1]) }
        XCTAssertTrue(rig.imports.all.isEmpty)
        XCTAssertFalse(rig.session.queue.isActive, "Nothing queued: a part is missing")
        rig.watch.deliver([0])
        try await waitUntil("imported into the conversation") { !rig.imports.all.isEmpty }
        let imported = try XCTUnwrap(rig.imports.all.first)
        XCTAssertEqual(imported.attachTo, conversation)
        XCTAssertEqual(imported.identity, DeviceRecordingIdentity(kind: AppleWatchIntegration.id, serial: "watch-install-1", recordingID: recording.id))
        XCTAssertEqual(imported.source, .microphone)
        XCTAssertEqual(imported.audio, "\(recording.id) part 0\n\(recording.id) part 1\n\(recording.id) part 2\n")
        try await waitUntil("the watch let go of its copies") { rig.watch.finished.isEmpty }
        XCTAssertEqual(rig.imports.all.count, 1, "Once")
        XCTAssertNil(rig.session.conversationWaiting(for: recording.id))
    }

    /// Wrist down, Daybook on the watch can't hear the Stop: it's owed, the cascade says it stopped, and the audio joins
    /// the conversation once Daybook runs on the watch and sends it.
    func testAStopTheWatchCantHearStillBringsItsAudioIntoTheConversation() async throws {
        let rig = try await rig()
        rig.watch.deliversSegments = true
        let conversation = UUID()
        rig.cascade.begin(conversation, title: "Walk", date: Date(), ledHere: true)
        await rig.cascade.startRecorders()
        let recording = try XCTUnwrap(rig.watch.recording)
        rig.watch.record(3)
        rig.watch.isReachable = false

        try await afterAPass(rig.session) { await rig.cascade.stop() }
        XCTAssertNotNil(rig.watch.recording, "Not heard yet")
        XCTAssertTrue(rig.watch.queued.contains(.stop(WatchStop(recordingID: recording.id, conversationID: conversation))))
        XCTAssertNotEqual(rig.cascade.status, "Apple Watch didn’t confirm it stopped. Stop it on the recorder.")
        XCTAssertEqual(rig.session.conversationWaiting(for: recording.id), conversation)
        XCTAssertTrue(rig.imports.all.isEmpty, "Only the first part has arrived")
        XCTAssertFalse(rig.session.queue.isActive)

        rig.watch.isReachable = true
        try await waitUntil("imported into the conversation") { !rig.imports.all.isEmpty }
        XCTAssertEqual(rig.imports.all.first?.attachTo, conversation)
        XCTAssertEqual(rig.imports.all.first?.audio, "\(recording.id) part 0\n\(recording.id) part 1\n")
    }

    /// Its microphone track is the watch's wherever a recording is named, never this Mac's.
    func testAWatchsTrackIsNamedAppleWatch() {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/r.m4a", fileName: "r.m4a",
                                   device: DeviceRecordingIdentity(kind: AppleWatchIntegration.id, serial: "watch-install-1", recordingID: "r"))
        let meeting = Meeting(title: "Walk", tracks: [track])
        XCTAssertEqual(RecordingWords.name(track, in: meeting), "Apple Watch")
        XCTAssertNil(RecordingWords.place(track, in: meeting, mac: "This Mac"))
        XCTAssertEqual(MeetingExport.sourceName(of: track, in: meeting), "Apple Watch")
    }

    /// The watch follows the iPhone's context and ends its recording, every part here, before the cascade's own Stop
    /// reaches it: it imports into its conversation at once, never one of its own, and the Stop adds nothing.
    func testARecordingTheWatchEndsByItselfStillJoinsTheConversationOnce() async throws {
        let rig = try await rig()
        rig.watch.deliversSegments = true
        let conversation = UUID()
        rig.cascade.begin(conversation, title: "Walk", date: Date(), ledHere: true)
        await rig.cascade.startRecorders()
        let recording = try XCTUnwrap(rig.watch.recording)
        rig.watch.record(3)

        // What the iPhone app publishes as the shared recording ends.
        rig.watch.updateContext(PhoneContext(sharedRecording: nil))
        XCTAssertNil(rig.watch.recording, "Ended by itself")
        try await waitUntil("imported into the conversation") { !rig.imports.all.isEmpty }
        XCTAssertEqual(rig.imports.all.map(\.attachTo), [conversation], "Never a conversation of its own")
        XCTAssertEqual(rig.imports.all.first?.identity.recordingID, recording.id)

        try await afterAPass(rig.session) { await rig.cascade.stop() }
        XCTAssertFalse(rig.session.queue.isActive)
        XCTAssertEqual(rig.imports.all.count, 1, "Once")
    }

    /// This iPhone relaunches while the watch records along: nothing remembers the shared recording, yet the watch's
    /// audio goes into the conversation it was recorded for.
    func testARecordingAlongImportsIntoItsConversationAfterThisIPhoneRelaunches() async throws {
        let rig = try await rig()
        rig.watch.deliversSegments = true
        let conversation = UUID()
        rig.cascade.begin(conversation, title: "Walk", date: Date(), ledHere: true)
        await rig.cascade.startRecorders()
        let recording = try XCTUnwrap(rig.watch.recording)
        rig.watch.record(3)

        rig.session.shutDown()
        _ = try await launch(rig.environment, imports: rig.imports)
        // Launched again, this iPhone shares nothing: the watch follows, and ends.
        rig.watch.updateContext(PhoneContext(sharedRecording: nil))
        try await waitUntil("imported") { !rig.imports.all.isEmpty }
        XCTAssertEqual(rig.imports.all.map(\.attachTo), [conversation])
        XCTAssertEqual(rig.imports.all.first?.identity.recordingID, recording.id)
        XCTAssertEqual(rig.imports.all.first?.audio, "\(recording.id) part 0\n\(recording.id) part 1\n")
    }

    /// Unpaired, or Daybook deleted from it: what's complete here imports all the same, by the watch that made it.
    func testACompleteRecordingImportsWhileTheWatchIsUnavailable() async throws {
        let rig = try await rig()
        rig.watch.pressRecord()
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(3)
        rig.watch.pressStop()
        rig.watch.isPaired = false
        XCTAssertEqual(rig.connection.state, .unavailable)

        rig.watch.deliver()
        try await waitUntil("imported") { !rig.imports.all.isEmpty }
        XCTAssertEqual(rig.imports.all.first?.identity, DeviceRecordingIdentity(kind: AppleWatchIntegration.id, serial: "watch-install-1", recordingID: id))
        XCTAssertNil(rig.imports.all.first?.attachTo, "Made on the watch alone: a conversation of its own")
    }

    /// Daybook closed on the watch (or the watch unavailable): a Start can't reach it, so it isn't part of the shared
    /// recording, and nothing says so: no member, no line, no Start.
    func testAWatchAStartCantReachIsLeftOutQuietly() async throws {
        let rig = try await rig()
        rig.watch.isReachable = false
        rig.cascade.begin(UUID(), title: "Standup", date: Date(), ledHere: true)
        await rig.cascade.startRecorders()
        XCTAssertNil(rig.cascade.member("apple-watch"))
        XCTAssertNil(rig.cascade.status)
        XCTAssertTrue(starts(rig.watch).isEmpty)

        rig.watch.isReachable = true
        rig.watch.isWatchAppInstalled = false
        await rig.cascade.startRecorders()
        XCTAssertNil(rig.cascade.member("apple-watch"))
        XCTAssertNil(rig.cascade.status)
        XCTAssertTrue(starts(rig.watch).isEmpty)
    }
}
