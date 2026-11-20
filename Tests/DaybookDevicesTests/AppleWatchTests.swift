import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookDevices

/// Apple Watch as a recorder the iPhone manages (docs/devices.md, "Apple Watch"), against the simulated watch: record
/// control with the shared recording, a Start it can't hear and a Stop it can't hear yet, its own Record and Stop as
/// its button, a join it shouldn't have made, segments that arrive out of order, are acknowledged, asked for again when
/// lost, and import only once all have, into their conversation, what a relaunch and removing it keep, and its clock.
@MainActor
final class AppleWatchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var staging: URL!

    override func setUp() async throws {
        defaults = makeTestDefaults("local.daybook.tests.apple-watch")
        staging = makeTemporaryFolder("DaybookAppleWatch")
    }

    private struct Rig {
        let watch: SimulatedWatch
        let connection: WatchConnection
        let environment: DeviceEnvironment
        let device: ConfiguredDevice
        let joins: Joins
    }

    /// The parts each join was given.
    private final class Joins {
        var all: [[WatchStagedSegment]] = []
    }

    private func environment(_ watch: SimulatedWatch, joins: Joins) -> DeviceEnvironment {
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { XCTFail("No Bluetooth"); return InertSoundcoreTransport() }
        environment.watch.transport = watch
        environment.watch.requestTimeout = .seconds(2)
        // Asked for what's missing at once (the test of the wait at activation sets its own).
        environment.watch.asksForMissingAfter = 0
        // Joined by putting the parts' bytes one after another.
        environment.watch.join = { segments, output in
            joins.all.append(segments)
            var data = Data()
            for segment in segments { data.append(try Data(contentsOf: segment.url)) }
            try data.write(to: output)
        }
        return environment
    }

    private func connection(_ environment: DeviceEnvironment, device: ConfiguredDevice) throws -> WatchConnection {
        let made = AppleWatchIntegration().makeConnection(.direct, for: device, environment: environment)
        let connection = try XCTUnwrap(made as? WatchConnection)
        addTeardownBlock { connection.shutDown() }
        return connection
    }

    /// A watch with Daybook open, two-second segments, and the iPhone's connection to it, activated and listed. Without
    /// `recordsAlong`, what it records on its own is its own (the iPhone ignores its button).
    private func rig(recordsAlong: Bool = true, _ configure: (SimulatedWatch) -> Void = { _ in }) async throws -> Rig {
        let watch = SimulatedWatch(stagingDirectory: staging, watchID: "watch-install-1")
        watch.segmentLength = 2
        configure(watch)
        let joins = Joins()
        let environment = environment(watch, joins: joins)
        var device = ConfiguredDevice(id: "apple-watch", kind: AppleWatchIntegration().kind)
        device.alsoRecordsWithMac = recordsAlong
        let connection = try connection(environment, device: device)
        connection.activate()
        try await waitUntil("activated and listed") { connection.state == .connected && connection.isInventoryCurrent }
        return Rig(watch: watch, connection: connection, environment: environment, device: device, joins: joins)
    }

    private static func isStart(_ message: WatchMessage) -> Bool { if case .start = message { return true } else { return false } }

    /// The receipts the watch was sent that aren't imports, in order: told while it could hear, queued otherwise.
    private static func receipts(_ watch: SimulatedWatch) -> [WatchReceipt] {
        (watch.told + watch.queued).compactMap { message in
            if case .received(let receipt) = message, !receipt.imported { return receipt } else { return nil }
        }
    }

    /// Every stop the watch was sent, answered or queued.
    private static func stops(_ watch: SimulatedWatch) -> [WatchStop] {
        (watch.answered + watch.queued).compactMap { message in if case .stop(let stop) = message { return stop } else { return nil } }
    }

    private func share(_ rig: Rig, _ conversation: UUID, title: String = "Standup", at start: Date = Date()) {
        rig.environment.watch.sharedRecording = { WatchSharedRecording(conversationID: conversation, title: title, startedAt: start) }
    }

    // MARK: The kind

    func testTheKindIsKnownEverywhereButNeverOfferedInAddDevice() throws {
        let kind = try XCTUnwrap(DeviceCatalog.kind(AppleWatchIntegration.id))
        XCTAssertEqual(kind.id, "daybook.watch")
        XCTAssertEqual(kind.name, "Apple Watch")
        XCTAssertEqual(kind.shortName, "Watch")
        XCTAssertEqual(kind.vendor, "Apple")
        XCTAssertEqual(kind.systemImage, "applewatch")
        XCTAssertFalse(kind.allowsMultiple)
        XCTAssertEqual(kind.implementedMethods.map(\.kind), [.direct])
        XCTAssertFalse(kind.isAddedByHand)
        XCTAssertFalse(DeviceCatalog.kindsAddedByHand.contains(kind), "Added by itself, never in Add Device")
        XCTAssertTrue(DeviceCatalog.kindsAddedByHand.contains { $0.id == SoundcoreWorkIntegration.id })

        // Without a link to a watch (the Mac), there's no connection.
        let mac = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        XCTAssertNil(AppleWatchIntegration().makeConnection(.direct, for: ConfiguredDevice(kind: kind), environment: mac))
    }

    func testWithoutAPairedWatchOrDaybookOnItTheWatchIsUnavailableAndSaysWhy() async throws {
        let rig = try await rig()
        rig.watch.isWatchAppInstalled = false
        XCTAssertEqual(rig.connection.state, .unavailable)
        XCTAssertEqual(rig.connection.problem?.id, "watchAppMissing")
        XCTAssertEqual(rig.connection.problem?.message, "Install Daybook on your Apple Watch to record there.")
        XCTAssertFalse(rig.connection.canRecordAlong, "Shared recordings leave it out quietly")
        let outcome = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        XCTAssertEqual(outcome, .unavailable)

        rig.watch.isPaired = false
        XCTAssertEqual(rig.connection.problem?.id, "watchNotPaired")
        rig.watch.isPaired = true
        rig.watch.isWatchAppInstalled = true
        XCTAssertEqual(rig.connection.state, .connected)
        XCTAssertNil(rig.connection.problem)

        // Reachability isn't the connection: Daybook closed on the watch still has it connected.
        rig.watch.isReachable = false
        XCTAssertEqual(rig.connection.state, .connected)
    }

    // MARK: Record control

    func testStartAndStopAreConfirmedWithTheSharedRecording() async throws {
        let rig = try await rig()
        let conversation = UUID(), start = Date(timeIntervalSince1970: 1_800_000_000)
        share(rig, conversation, at: start)

        let started = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        XCTAssertEqual(started, .confirmed)
        XCTAssertTrue(rig.watch.answered.contains(.start(WatchStart(conversationID: conversation, title: "Standup", startedAt: start))))
        let recording = try XCTUnwrap(rig.watch.recording)
        XCTAssertEqual(recording.conversationID, conversation)
        XCTAssertEqual(rig.connection.status?.isRecording, true)
        XCTAssertEqual(rig.connection.status?.serial, "watch-install-1")
        XCTAssertEqual(rig.connection.recordings.first(where: \.isInProgress)?.id, recording.id, "listed as in progress at once")
        let state = try XCTUnwrap(rig.connection.recordingState(at: Date()))
        XCTAssertTrue(state.startedHere)
        XCTAssertTrue(state.isLive)

        rig.watch.record(3)
        let stopped = await rig.connection.recordCommand(.pause, deadline: .seconds(1))
        XCTAssertEqual(stopped, .confirmed)
        XCTAssertTrue(rig.watch.answered.contains(.stop(WatchStop(recordingID: recording.id, conversationID: conversation))))
        XCTAssertNil(rig.watch.recording)
        XCTAssertEqual(rig.connection.status?.isRecording, false)
        XCTAssertNil(rig.connection.recordingState(at: Date()))
        XCTAssertTrue(rig.watch.queued.isEmpty, "Heard at once: nothing owed")
        XCTAssertEqual(rig.connection.recordings.first?.isInProgress, false, "Every part is here")
        let complete = rig.connection.automaticImports(links: DeviceLibraryLinks(), since: .distantPast, excluding: [])
        XCTAssertEqual(complete.map(\.id), [recording.id], "Complete, it imports at once")
        let audio = try await rig.connection.transfer(try XCTUnwrap(complete.first)) { _, _ in }
        XCTAssertEqual(audio.conversationID, conversation, "Into the shared recording's conversation, whatever remembers it")
    }

    /// The device page's Record with nothing recording here: a recording of the watch's own, with no conversation.
    func testRecordWithNothingRecordingHereIsTheWatchsOwn() async throws {
        let rig = try await rig()
        let outcome = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(rig.watch.answered.filter(Self.isStart), [.start(WatchStart(conversationID: nil))])
        XCTAssertNotNil(rig.watch.recording)
        XCTAssertNil(rig.watch.recording?.conversationID)
    }

    /// Daybook closed on the watch: a Start can't reach it, so shared recordings leave it out, with nothing to say.
    func testAStartTheWatchCantHearIsUnavailableAndSharedRecordingsLeaveItOut() async throws {
        let rig = try await rig()
        share(rig, UUID())
        rig.watch.isReachable = false
        XCTAssertFalse(rig.connection.canRecordAlong)
        let outcome = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertNil(rig.connection.recordCommandIssue)
        XCTAssertFalse(rig.watch.answered.contains(where: Self.isStart))
        XCTAssertNil(rig.watch.recording)

        // Refused on the watch: its words.
        rig.watch.isReachable = true
        XCTAssertTrue(rig.connection.canRecordAlong)
        rig.watch.refusesStart = "Apple Watch storage is full."
        let refused = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        XCTAssertEqual(refused, .unavailable)
        XCTAssertEqual(rig.connection.recordCommandIssue, "Apple Watch storage is full.")

        // Recording already, out of reach, it's still part of one.
        rig.watch.refusesStart = nil
        _ = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        rig.watch.isReachable = false
        XCTAssertTrue(rig.connection.canRecordAlong)
    }

    /// A Start answered after the iPhone gave up: what it said ("didn't start") stays true.
    func testAStartConfirmedTooLateIsStoppedAgain() async throws {
        let rig = try await rig()
        rig.watch.answerDelay = .milliseconds(300)
        share(rig, UUID())
        let outcome = await rig.connection.recordCommand(.start, deadline: .milliseconds(100))
        XCTAssertEqual(outcome, .notConfirmed)
        try await waitUntil("the late start, stopped again") { rig.watch.answered.contains(where: Self.isStart) && rig.watch.recording == nil }
        XCTAssertEqual(Self.stops(rig.watch).count, 1)
        XCTAssertNotNil(Self.stops(rig.watch).first?.recordingID, "Only the recording it made")
        XCTAssertTrue(rig.watch.finished.isEmpty, "Nothing was recorded: nothing to import, and the watch forgets it")
    }

    /// Late, with the watch out of reach before the stop: what it recorded meanwhile imports into the conversation the
    /// Start was for, never one of its own.
    func testWhatAStartConfirmedTooLateRecordedKeepsItsConversation() async throws {
        let rig = try await rig()
        rig.watch.answerDelay = .milliseconds(300)
        let conversation = UUID()
        share(rig, conversation)
        let outcome = await rig.connection.recordCommand(.start, deadline: .milliseconds(100))
        XCTAssertEqual(outcome, .notConfirmed)
        rig.watch.isReachable = false
        let id = try await waitFor("the late start, its stop owed") { () -> String? in
            guard let recording = rig.watch.recording, rig.watch.queued.contains(.stop(WatchStop(recordingID: recording.id))) else { return nil }
            return recording.id
        }
        XCTAssertEqual(rig.watch.recording?.conversationID, conversation)
        rig.watch.record(3)
        rig.watch.isReachable = true
        XCTAssertNil(rig.watch.recording, "The owed stop ran")
        try await waitUntil("listed again, back in reach") { !rig.connection.isRefreshing && rig.connection.isInventoryCurrent }
        let complete = rig.connection.automaticImports(links: DeviceLibraryLinks(), since: .distantPast, excluding: [])
        XCTAssertEqual(complete.map(\.id), [id])
        let audio = try await rig.connection.transfer(try XCTUnwrap(complete.first)) { _, _ in }
        XCTAssertEqual(audio.conversationID, conversation)
    }

    func testAStopTheWatchCantHearIsQueuedAndOwed() async throws {
        let rig = try await rig()
        let conversation = UUID()
        share(rig, conversation)
        _ = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        let recording = try XCTUnwrap(rig.watch.recording)
        rig.watch.record(3)

        // Wrist down: Daybook on the watch can't answer.
        rig.watch.isReachable = false
        let outcome = await rig.connection.recordCommand(.pause, deadline: .seconds(1))
        XCTAssertEqual(outcome, .confirmed, "Owed and certain")
        XCTAssertEqual(rig.watch.queued, [.stop(WatchStop(recordingID: recording.id, conversationID: conversation))])
        XCTAssertNotNil(rig.watch.recording, "Not heard yet")
        XCTAssertEqual(rig.connection.status?.isRecording, false, "Said stopped here")
        XCTAssertNil(rig.connection.recordingState(at: Date()))
        XCTAssertEqual(rig.connection.recordings.first?.id, recording.id)
        XCTAssertEqual(rig.connection.recordings.first?.isInProgress, true, "Its audio is owed: nothing imports yet")
        XCTAssertTrue(rig.connection.technicalDetails.contains { $0.label == "Stop" })

        // Daybook opens on the watch: the stop runs, the last segment comes, and the recording is complete.
        rig.watch.isReachable = true
        XCTAssertNil(rig.watch.recording)
        try await waitUntil("complete") { rig.connection.recordings.first?.isInProgress == false }
        XCTAssertFalse(rig.connection.technicalDetails.contains { $0.label == "Stop" })
    }

    // MARK: Its button

    func testTheWatchsOwnRecordAndStopAreItsButton() async throws {
        let rig = try await rig()
        var pressed: [Bool] = []
        rig.connection.onButton = { pressed.append($0) }

        rig.watch.pressRecord()
        XCTAssertEqual(pressed, [true])
        XCTAssertEqual(rig.connection.status?.isRecording, true)
        XCTAssertEqual(rig.connection.recordings.first(where: \.isInProgress)?.id, rig.watch.recording?.id)
        XCTAssertEqual(rig.connection.recordingState(at: Date())?.startedHere, false)
        rig.watch.record(1)
        rig.watch.pressStop()
        XCTAssertEqual(pressed, [true, false])

        // This iPhone's own Start and Stop aren't the button.
        let conversation = UUID()
        share(rig, conversation)
        _ = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        _ = await rig.connection.recordCommand(.pause, deadline: .seconds(1))
        XCTAssertEqual(pressed, [true, false])

        // Joining the recording this iPhone records as Daybook opens on the watch is the button too.
        rig.watch.updateContext(PhoneContext(sharedRecording: WatchSharedRecording(conversationID: conversation, startedAt: Date())))
        rig.watch.pressRecord()
        XCTAssertEqual(pressed, [true, false, true])
    }

    /// A join from a context that waited while the watch was away names a recording this iPhone doesn't record now:
    /// nothing starts here, and only that recording stops (asked now, or owed).
    func testAJoinOfARecordingThisIPhoneDoesntRecordIsStoppedNotTheButton() async throws {
        let rig = try await rig()
        var pressed: [Bool] = []
        rig.connection.onButton = { pressed.append($0) }

        // Nothing records here.
        rig.watch.updateContext(PhoneContext(sharedRecording: WatchSharedRecording(conversationID: UUID(), startedAt: Date())))
        rig.watch.pressRecord()
        let stale = try XCTUnwrap(rig.watch.recording?.id)
        try await waitUntil("stopped") { rig.watch.recording == nil }
        XCTAssertEqual(pressed, [], "Not the button: nothing starts here")
        XCTAssertEqual(Self.stops(rig.watch), [WatchStop(recordingID: stale)])

        // Another recording here, and the watch out of reach: owed, still only that one.
        share(rig, UUID())
        rig.watch.updateContext(PhoneContext(sharedRecording: WatchSharedRecording(conversationID: UUID(), startedAt: Date())))
        rig.watch.isReachable = false
        rig.watch.pressRecord()
        let other = try XCTUnwrap(rig.watch.recording?.id)
        XCTAssertEqual(pressed, [])
        XCTAssertEqual(rig.watch.queued.last, .stop(WatchStop(recordingID: other)))
        XCTAssertEqual(rig.connection.status?.isRecording, false, "Said stopped here")
        rig.watch.isReachable = true
        XCTAssertNil(rig.watch.recording)
    }

    // MARK: Segments and import

    func testSegmentsOutOfOrderWaitUntilEveryOneHasArrivedThenJoinAndImport() async throws {
        let rig = try await rig(recordsAlong: false) { $0.deliversSegments = false }
        rig.watch.pressRecord()
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(5)
        rig.watch.pressStop()
        XCTAssertEqual(rig.watch.undelivered.map(\.index), [0, 1, 2], "2 s, 2 s, and the last 1 s")

        let links = DeviceLibraryLinks()
        rig.watch.deliver([2, 0])
        XCTAssertEqual(rig.connection.recordings.first?.id, id)
        XCTAssertEqual(rig.connection.recordings.first?.isInProgress, true, "Finished on the watch, but a part is missing")
        XCTAssertTrue(rig.connection.automaticImports(links: links, since: .distantPast, excluding: []).isEmpty)
        do {
            _ = try await rig.connection.transfer(DeviceRecording(id: id)) { _, _ in }
            XCTFail("Partial audio is never handed over")
        } catch let error as DeviceTransferError {
            if case .integrity = error {} else { XCTFail("\(error)") }
        }
        XCTAssertTrue(rig.connection.technicalDetails.contains { $0.label == "Waiting for audio" && $0.value.hasPrefix("1 part") })

        rig.watch.deliver([1])
        let ready = try XCTUnwrap(rig.connection.recordings.first)
        XCTAssertFalse(ready.isInProgress)
        XCTAssertEqual(ready.length, .exact(5))
        XCTAssertEqual(rig.connection.automaticImports(links: links, since: .distantPast, excluding: []).map(\.id), [id])
        XCTAssertTrue(rig.connection.automaticImports(links: links, since: .distantPast, excluding: [id]).isEmpty)

        let audio = try await rig.connection.transfer(ready) { _, _ in }
        XCTAssertTrue(audio.isStaged)
        XCTAssertEqual(audio.serial, "watch-install-1")
        XCTAssertEqual(rig.joins.all.count, 1)
        XCTAssertEqual(rig.joins.all.first?.map(\.segment.index), [0, 1, 2], "In order")
        XCTAssertEqual(rig.joins.all.first?.map(\.segment.startOffset), [0, 2, 4], "Each at its place")
        XCTAssertEqual(try String(contentsOf: audio.url, encoding: .utf8), "\(id) part 0\n\(id) part 1\n\(id) part 2\n")
        let folder = try XCTUnwrap(WatchStaging.recordingFolder(id, in: WatchStaging.folder(in: staging)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "Its parts stay until it's in the library")

        rig.connection.didImport(ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(rig.watch.queued.contains(.received(WatchReceipt(recordingID: id, segments: [0, 1, 2], imported: true))))
        XCTAssertTrue(rig.watch.finished.isEmpty, "The watch deleted its copies")
        XCTAssertFalse(rig.connection.recordings.contains { $0.id == id })
        XCTAssertTrue(rig.watch.resent.isEmpty, "What was on its way was never asked for again")
    }

    /// Each segment staged is acknowledged with every one held: the only proof of delivery the watch takes. What
    /// arrives together is one receipt.
    func testEachSegmentStagedIsAcknowledgedWithEveryOneHeld() async throws {
        let rig = try await rig(recordsAlong: false)
        rig.watch.pressRecord()
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(4)
        try await waitUntil("acknowledged") { !Self.receipts(rig.watch).isEmpty }
        XCTAssertEqual(Self.receipts(rig.watch), [WatchReceipt(recordingID: id, segments: [0, 1])], "Two parts at once, one receipt")
        XCTAssertEqual(rig.watch.told.count, 1, "Told now, while the watch can hear")

        // Out of reach, it's queued for the watch.
        rig.watch.isReachable = false
        rig.watch.record(1)
        rig.watch.pressStop()
        try await waitUntil("acknowledged again") { Self.receipts(rig.watch).count == 2 }
        XCTAssertEqual(Self.receipts(rig.watch).last, WatchReceipt(recordingID: id, segments: [0, 1, 2]))
        XCTAssertTrue(rig.watch.queued.contains(.received(WatchReceipt(recordingID: id, segments: [0, 1, 2]))))
        XCTAssertTrue(rig.watch.resent.isEmpty, "Nothing missing")
    }

    /// A segment that never reaches the ledger (staging failed) isn't in the receipts. The receipt as each part arrives
    /// asks for nothing (a later part may simply not have arrived yet): the ask (`requestsMissing`) comes on a refresh, at
    /// activation, or back within reach, at most once a minute, and the watch sends it again.
    func testASegmentLostOnThisIPhoneIsAskedForAgainAtMostOnceAMinute() async throws {
        let rig = try await rig(recordsAlong: false) { $0.losesOnArrival = [1, 1] }
        rig.watch.pressRecord()
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(5)
        rig.watch.pressStop()
        try await waitUntil("acknowledged as the last part arrived") { Self.receipts(rig.watch).last?.segments == [0, 2] }
        XCTAssertFalse(Self.receipts(rig.watch).contains(where: \.requestsMissing), "Acknowledging asks for nothing")
        XCTAssertTrue(rig.watch.resent.isEmpty)
        XCTAssertEqual(rig.connection.recordings.first?.isInProgress, true, "Still missing a part")

        rig.connection.refresh()
        try await waitUntil("asked on a refresh") { rig.watch.resent.count == 1 && !rig.connection.isRefreshing }
        XCTAssertEqual(Self.receipts(rig.watch).last, WatchReceipt(recordingID: id, segments: [0, 2], requestsMissing: true))
        XCTAssertEqual(rig.connection.recordings.first?.isInProgress, true, "Lost again: still missing a part")
        let asked = Self.receipts(rig.watch).count
        rig.connection.refresh()
        try await waitUntil("refreshed") { !rig.connection.isRefreshing && rig.connection.isInventoryCurrent }
        rig.watch.isReachable = false
        rig.watch.isReachable = true
        try await waitUntil("refreshed in reach") { !rig.connection.isRefreshing && rig.connection.isInventoryCurrent }
        XCTAssertEqual(Self.receipts(rig.watch).count, asked, "Not again within the minute")
        XCTAssertEqual(rig.watch.resent.count, 1)

        // Activation asks again (a relaunch), and this time it arrives.
        rig.connection.shutDown()
        let again = try connection(rig.environment, device: rig.device)
        again.activate()
        try await waitUntil("complete") { again.recordings.first?.isInProgress == false }
        XCTAssertEqual(rig.watch.resent.map(\.index), [1, 1])
        let audio = try await again.transfer(try XCTUnwrap(again.recordings.first)) { _, _ in }
        XCTAssertEqual(try String(contentsOf: audio.url, encoding: .utf8), "\(id) part 0\n\(id) part 1\n\(id) part 2\n")
    }

    /// At activation the ask waits a moment (`asksForMissingAfter`): WatchConnectivity hands over what waited for Daybook
    /// first, and an ask before it arrives would have the watch send it again.
    func testTheAskAtActivationWaitsForWhatWatchConnectivityHasPending() async throws {
        let rig = try await rig(recordsAlong: false) { $0.losesOnArrival = [1] }
        rig.watch.pressRecord()
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(5)
        rig.watch.pressStop()
        try await waitUntil("acknowledged") { Self.receipts(rig.watch).last?.segments == [0, 2] }

        // Launched again.
        rig.environment.watch.asksForMissingAfter = 1
        rig.connection.shutDown()
        let again = try connection(rig.environment, device: rig.device)
        again.activate()
        try await waitUntil("activated and listed") { again.isInventoryCurrent && !again.isRefreshing }
        XCTAssertFalse(Self.receipts(rig.watch).contains(where: \.requestsMissing), "Not at once")
        XCTAssertTrue(rig.watch.resent.isEmpty)
        try await waitUntil("asked once the moment has passed") { rig.watch.resent.map(\.index) == [1] }
        XCTAssertEqual(Self.receipts(rig.watch).filter(\.requestsMissing), [WatchReceipt(recordingID: id, segments: [0, 2], requestsMissing: true)])
        try await waitUntil("complete") { again.recordings.first?.isInProgress == false }
    }

    /// A recording made for a conversation the app holds (its own recording of it isn't filed yet) waits to import, and
    /// imports once the app lets it go; one with no conversation isn't held.
    func testARecordingForAConversationTheAppHoldsWaitsUntilItsLetGo() async throws {
        let rig = try await rig()
        var held = true
        let conversation = UUID()
        rig.environment.watch.holdsImport = { $0 == conversation && held }
        share(rig, conversation)
        let started = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        XCTAssertEqual(started, .confirmed)
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(3)
        let stopped = await rig.connection.recordCommand(.pause, deadline: .seconds(1))
        XCTAssertEqual(stopped, .confirmed)
        // The device page's Record with nothing recording here: the watch's own.
        rig.environment.watch.sharedRecording = { nil }
        let startedOwn = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        XCTAssertEqual(startedOwn, .confirmed)
        let own = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(1)
        let stoppedOwn = await rig.connection.recordCommand(.pause, deadline: .seconds(1))
        XCTAssertEqual(stoppedOwn, .confirmed)
        XCTAssertEqual(rig.connection.recordings.filter { !$0.isInProgress }.count, 2, "Both complete")
        XCTAssertEqual(rig.connection.automaticImports(links: DeviceLibraryLinks(), since: .distantPast, excluding: []).map(\.id), [own])

        var looked = 0
        rig.connection.onChange = { looked += 1 }
        held = false
        rig.environment.watch.importHoldChanged()
        XCTAssertEqual(looked, 1, "Its connection looks again")
        XCTAssertEqual(Set(rig.connection.automaticImports(links: DeviceLibraryLinks(), since: .distantPast, excluding: []).map(\.id)),
                       [id, own])
    }

    /// One whole part is the recording as it is, with no joining.
    func testARecordingOfOnePartIsImportedAsItIs() async throws {
        let rig = try await rig(recordsAlong: false)
        rig.watch.pressRecord()
        rig.watch.record(1.5)
        rig.watch.pressStop()
        let recording = try XCTUnwrap(rig.connection.recordings.first)
        XCTAssertFalse(recording.isInProgress)
        let links = DeviceLibraryLinks()
        XCTAssertEqual(rig.connection.automaticImports(links: links, since: .distantPast, excluding: []).map(\.id), [recording.id],
                       "Made on the watch alone, it still lands in Daybook")
        let audio = try await rig.connection.transfer(recording) { _, _ in }
        XCTAssertTrue(rig.joins.all.isEmpty)
        XCTAssertEqual(try String(contentsOf: audio.url, encoding: .utf8), "\(recording.id) part 0\n")

        // Imported elsewhere first (the app ended before it heard): finished all the same.
        var imported = DeviceLibraryLinks()
        imported.imported[recording.id] = UUID()
        XCTAssertTrue(rig.connection.automaticImports(links: imported, since: .distantPast, excluding: []).isEmpty)
        XCTAssertTrue(rig.watch.queued.contains(.received(WatchReceipt(recordingID: recording.id, segments: [0], imported: true))))
    }

    /// Removing the watch forgets what this iPhone knew of it, but not its recordings: added again under the same ID, it
    /// imports what wasn't in the library yet.
    func testRemovingTheWatchKeepsWhatItHasntImportedForWhenItsAddedAgain() async throws {
        let rig = try await rig(recordsAlong: false)
        rig.watch.pressRecord()
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(3)
        rig.watch.pressStop()
        XCTAssertEqual(rig.connection.recordings.first?.isInProgress, false)
        // As the hub removes a device: shut down, then forgotten.
        rig.connection.shutDown()
        rig.connection.forget()
        let folder = try XCTUnwrap(WatchStaging.recordingFolder(id, in: WatchStaging.folder(in: staging)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "Its parts stay")

        let again = try connection(rig.environment, device: rig.device)
        XCTAssertNil(again.status, "What it knew of the watch is gone")
        XCTAssertEqual(again.recordings.map(\.id), [id], "Its recordings aren't")
        again.activate()
        try await waitUntil("listed") { again.isInventoryCurrent && !again.isRefreshing }
        XCTAssertEqual(again.automaticImports(links: DeviceLibraryLinks(), since: .distantPast, excluding: []).map(\.id), [id])
        let audio = try await again.transfer(try XCTUnwrap(again.recordings.first)) { _, _ in }
        XCTAssertEqual(audio.serial, "watch-install-1")
        XCTAssertEqual(try String(contentsOf: audio.url, encoding: .utf8), "\(id) part 0\n\(id) part 1\n")
    }

    /// A complete recording is here already: it imports with the watch unpaired or without Daybook, by the watch that
    /// made it, whichever is paired now.
    func testACompleteRecordingImportsWhateverTheWatchIsNowByTheWatchThatMadeIt() async throws {
        let rig = try await rig(recordsAlong: false)
        rig.watch.pressRecord()
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(3)
        rig.watch.pressStop()
        // Daybook installed on the watch again: a new installation.
        rig.watch.watchID = "watch-install-2"
        rig.connection.refresh()
        try await waitUntil("heard") { rig.connection.status?.serial == "watch-install-2" && !rig.connection.isRefreshing }
        rig.watch.isWatchAppInstalled = false
        XCTAssertEqual(rig.connection.state, .unavailable)
        XCTAssertTrue(rig.connection.importsWithoutConnection)
        XCTAssertEqual(rig.connection.automaticImports(links: DeviceLibraryLinks(), since: .distantPast, excluding: []).map(\.id), [id])
        let audio = try await rig.connection.transfer(try XCTUnwrap(rig.connection.recordings.first)) { _, _ in }
        XCTAssertEqual(audio.serial, "watch-install-1")
        XCTAssertNil(audio.conversationID, "Made on the watch alone: a conversation of its own")
    }

    /// What a join or an import left in staging when the app was ended under it goes at the next activation; the
    /// recordings' parts stay.
    func testLeftoversOfAJoinTheAppWasEndedUnderGoAtActivation() async throws {
        let rig = try await rig(recordsAlong: false) { $0.deliversSegments = false }
        rig.watch.pressRecord()
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(3)
        rig.watch.pressStop()
        rig.watch.deliver()
        rig.connection.shutDown()
        let folder = WatchStaging.folder(in: staging)
        let links = folder.appendingPathComponent(".join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let part = try XCTUnwrap(WatchStaging.recordingFolder(id, in: folder)).appendingPathComponent("\(id)-0000.m4a")
        try FileManager.default.linkItem(at: part, to: links.appendingPathComponent(part.lastPathComponent))
        let leftovers = [folder.appendingPathComponent(".joining-x.m4a"), folder.appendingPathComponent(".silence-x.m4a"),
                         folder.appendingPathComponent("\(id).m4a")]
        for file in leftovers { try Data("x".utf8).write(to: file) }

        let again = try connection(rig.environment, device: rig.device)
        again.activate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: links.path))
        for file in leftovers { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        XCTAssertEqual(again.recordings.first?.isInProgress, false, "Every part is still here")
    }

    func testTheLedgerSurvivesANewConnection() async throws {
        let rig = try await rig { $0.deliversSegments = false }
        rig.watch.pressRecord()
        let id = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(5)
        rig.watch.pressStop()
        rig.watch.deliver([0])
        rig.connection.shutDown()

        // A part staged while nothing listened (the app ended between staging and recording it).
        rig.watch.deliver([1])
        let again = try connection(rig.environment, device: rig.device)
        XCTAssertEqual(again.recordings.map(\.id), [id], "What it had")
        XCTAssertEqual(again.recordings.first?.isInProgress, true)
        again.activate()
        try await waitUntil("listed") { again.isInventoryCurrent }
        rig.watch.deliver([2])
        XCTAssertEqual(again.recordings.first?.isInProgress, false, "Parts from before the relaunch count")
        let audio = try await again.transfer(try XCTUnwrap(again.recordings.first)) { _, _ in }
        XCTAssertEqual(try String(contentsOf: audio.url, encoding: .utf8), "\(id) part 0\n\(id) part 1\n\(id) part 2\n")
    }

    // MARK: Clock

    func testTheWatchsClockIsCorrectedToThisIPhones() async throws {
        let rig = try await rig { $0.clockOffset = 30 }
        rig.connection.refresh()
        try await waitUntil("refreshed") { !rig.connection.isRefreshing }
        share(rig, UUID())
        let asked = Date()
        _ = await rig.connection.recordCommand(.start, deadline: .seconds(1))
        let watchStart = try XCTUnwrap(rig.watch.recording?.startedAt)
        XCTAssertEqual(watchStart.timeIntervalSince(asked), 30, accuracy: 1, "The watch's own clock is 30 s ahead")
        let started = try XCTUnwrap(rig.connection.status?.recordingStartedAt)
        XCTAssertEqual(started.timeIntervalSince(asked), 0, accuracy: 0.5, "On this iPhone's clock")
        XCTAssertEqual(rig.connection.recordings.first?.startedAt?.timeIntervalSince(asked) ?? 99, 0, accuracy: 0.5)
        XCTAssertEqual(rig.connection.recordingState(at: Date())?.startedAt?.timeIntervalSince(asked) ?? 99, 0, accuracy: 0.5)
        let id = try XCTUnwrap(rig.watch.recording?.id)
        let dated = DeviceRecordingStart.date(of: DeviceRecordingIdentity(kind: AppleWatchIntegration.id, serial: nil, recordingID: id))
        XCTAssertEqual(dated?.timeIntervalSince(asked) ?? 99, 0, accuracy: 0.5, "Imports are dated by it")
    }
}
