import AVFoundation
import DaybookKit
import XCTest
@testable import DaybookPhone

/// Apple Watch on this iPhone (docs/devices.md, "Apple Watch"): added by itself once the watch has Daybook, told what
/// this iPhone records, started and stopped with its recordings (or left out quietly when a Start can't reach it), its
/// parts joined as this iPhone joins its own, and its audio filed into the conversation it was recorded for, a relaunch
/// in between too. DaybookDevices' simulated watch stands in for WatchConnectivity, and synthetic audio for the
/// microphone.
@MainActor
final class PhoneWatchTests: XCTestCase {
    private struct Rig {
        let library: PhoneLibrary
        let settings: PhoneSettings
        let devices: PhoneDevices
        let watch: SimulatedWatch
        let devicesDefaults: UserDefaults
        let timing: PhoneDevices.Timing
    }

    private func rig(synced: Bool = false, _ configure: (SimulatedWatch) -> Void = { _ in }) throws -> Rig {
        let root = try temporaryDirectory("library")
        let sync = synced ? LibrarySyncController(localRoot: root, defaults: makeTestDefaults("PhoneWatchTests-sync")) : nil
        let library = PhoneLibrary(rootURL: root, sync: sync, installation: UUID().uuidString)
        let settings = PhoneSettings(defaults: makeTestDefaults("PhoneWatchTests"))
        // Where PhoneDevices stages what recorders bring.
        let watch = SimulatedWatch(stagingDirectory: library.importsURL.appendingPathComponent("Devices", isDirectory: true))
        watch.segmentLength = 2
        configure(watch)
        var timing = PhoneDevices.Timing()
        timing.cascade.poll = .milliseconds(20)
        let defaults = makeTestDefaults("PhoneWatchTests-devices")
        let devices = PhoneDevices(library: library, settings: settings, mode: .inert, defaults: defaults, timing: timing, watchTransport: watch)
        addTeardownBlock { devices.shutDown() }
        return Rig(library: library, settings: settings, devices: devices, watch: watch, devicesDefaults: defaults, timing: timing)
    }

    /// Segments with real audio, as the watch's, a tone of each recording's own: two recordings never have the same bytes
    /// (the library keeps one copy of the same audio).
    private static func writesAudio(_ watch: SimulatedWatch) {
        watch.writeSegment = { url, segment in
            _ = try CaptureFiles.writeClosedSegment(to: url, seconds: segment.duration, frequency: tone(segment.recordingID))
        }
    }

    private static func tone(_ id: String) -> Float { 300 + Float(id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 1_000 }) }

    /// Conversations holding a track from the watch.
    private static func withWatchTrack(_ library: PhoneLibrary) -> [Meeting] {
        library.controller.meetings.filter { $0.tracks.contains { $0.deviceKind == AppleWatchIntegration.id } }
    }

    /// This iPhone's recording of `conversation`, three seconds in, as a run ended mid-recording leaves it in staging.
    private static func endedMidRecording(_ conversation: UUID, title: String, in library: PhoneLibrary) async throws -> URL {
        let rig = RecorderRig()
        let recordingID = UUID()
        let folder = library.stagingURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try await rig.recorder.start(in: folder, id: conversation, recordingID: recordingID, title: title)
        rig.pump(3)
        await rig.recorder.flush()
        rig.recorder.prepareForTermination()   // the process ends here
        return folder
    }

    /// The watch records along with this iPhone's recording of a new conversation, and Daybook on this iPhone is ended
    /// mid-recording; then it's launched again, the devices first, as the app does, with the cascade new.
    private func relaunchMidRecording(_ rig: Rig, conversation: UUID) async throws -> (devices: PhoneDevices, folder: URL) {
        try await rig.library.reload()
        rig.devices.start()
        try await waitUntil("the watch, connected") { rig.devices.watch?.session?.direct?.state == .connected }
        let folder = try await Self.endedMidRecording(conversation, title: "Standup", in: rig.library)
        rig.devices.cascade.begin(conversation, title: "Standup", date: Date(), ledHere: true)
        await rig.devices.cascade.startRecorders()
        XCTAssertEqual(rig.watch.recording?.conversationID, conversation)
        rig.watch.record(3)
        XCTAssertNil(rig.library.controller.meeting(conversation))

        rig.devices.shutDown()
        let relaunched = PhoneDevices(library: rig.library, settings: rig.settings, mode: .inert, defaults: rig.devicesDefaults,
                                      timing: rig.timing, watchTransport: rig.watch)
        addTeardownBlock { relaunched.shutDown() }
        return (relaunched, folder)
    }

    func testTheWatchIsAddedByItselfAndHearsWhatThisIPhoneRecords() async throws {
        let rig = try rig { $0.isWatchAppInstalled = false }
        let phoneWatch = try XCTUnwrap(rig.devices.watch)
        rig.devices.start()
        XCTAssertTrue(rig.watch.isActivated, "Activated with the devices, at launch")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(phoneWatch.session, "Not until the watch has Daybook")

        rig.watch.isWatchAppInstalled = true
        try await waitUntil("added by itself") { phoneWatch.session != nil }
        let session = try XCTUnwrap(phoneWatch.session)
        XCTAssertEqual(session.kind.id, AppleWatchIntegration.id)
        XCTAssertEqual(session.device.name, "Apple Watch")
        XCTAssertEqual(rig.devices.hub.sessions.count, 1)
        XCTAssertTrue(session.direct is WatchConnection)
        try await waitUntil("connected") { session.direct?.state == .connected }
        try await waitUntil("told nothing records here") { rig.watch.contexts.last.map { $0.sharedRecording == nil && $0.recordsAlong } == true }

        // A shared recording begins (this iPhone's, or only its recorder's): the watch hears it.
        let conversation = UUID(), date = Date(timeIntervalSince1970: 1_800_000_000)
        rig.devices.cascade.begin(conversation, title: "Standup", date: date, ledHere: true)
        let shared = WatchSharedRecording(conversationID: conversation, title: "Standup", startedAt: date)
        try await waitUntil("told what this iPhone records") { rig.watch.contexts.last?.sharedRecording == shared }

        // Its own ask is answered the same way.
        var answer: WatchReply?
        rig.watch.onMessage?(.context, { answer = $0 })
        guard case .context(let context)? = answer else { return XCTFail("\(String(describing: answer))") }
        XCTAssertEqual(context.sharedRecording, shared)
        XCTAssertTrue(context.recordsAlong)

        // Its Record Along, on the iPhone.
        session.update { $0.alsoRecordsWithMac = false }
        try await waitUntil("told it doesn't record along") { rig.watch.contexts.last?.recordsAlong == false }

        await rig.devices.cascade.stop()
        try await waitUntil("told the recording ended") { rig.watch.contexts.last?.sharedRecording == nil }

        // Removed by the person, it stays removed while Daybook runs.
        rig.devices.remove(session)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(phoneWatch.session)
    }

    /// While the person has paused this iPhone's recording, the watch isn't told of it, so a Start there is its own.
    func testBehaviorThePersonsPauseKeepsTheRecordingFromTheWatch() async throws {
        let rig = try rig()
        let phoneWatch = try XCTUnwrap(rig.devices.watch)
        var paused = false
        phoneWatch.withholdsRecording = { paused }
        let conversation = UUID(), date = Date(timeIntervalSince1970: 1_800_000_000)
        rig.devices.cascade.begin(conversation, title: "Standup", date: date, ledHere: true)
        XCTAssertEqual(phoneWatch.context.sharedRecording?.conversationID, conversation)
        paused = true
        XCTAssertNil(phoneWatch.context.sharedRecording, "nothing to join while paused")
        XCTAssertNil(phoneWatch.phoneContext().sharedRecording, "nor in its answer")
        XCTAssertNil(rig.devices.hub.environment.watch.sharedRecording(), "nor with a Start from here")
        paused = false
        XCTAssertEqual(phoneWatch.sharedRecording?.conversationID, conversation, "after Resume, as before")
        await rig.devices.cascade.stop()
    }

    /// Recording here records on the watch too, with this conversation; stopping stops it, and its audio, in two parts,
    /// joins the conversation.
    func testRecordingHereRecordsOnTheWatchTooAndItsAudioJoinsTheConversation() async throws {
        let rig = try rig { watch in
            watch.writeSegment = { url, segment in
                _ = try CaptureFiles.writeClosedSegment(to: url, seconds: segment.duration, frequency: 440)
            }
        }
        let recorder = RecorderRig()
        let model = PhoneAppModel(recorder: recorder.recorder, library: rig.library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  settings: rig.settings, devices: rig.devices)
        rig.devices.start()
        try await waitUntil("the watch, connected") { rig.devices.watch?.session?.direct?.state == .connected }

        try await model.startRecording()
        recorder.pump(1)
        let id = try XCTUnwrap(model.recorder.captureID)
        try await waitUntil("the watch records along") { rig.watch.recording?.conversationID == id }
        try await waitUntil("the watch hears this recording") { rig.watch.contexts.last?.sharedRecording?.conversationID == id }
        let watchRecording = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(3)
        recorder.pump(1)

        try await model.stopRecording()
        try await waitUntil("the watch stops with it") { rig.watch.recording == nil }
        let session = try XCTUnwrap(rig.devices.watch?.session)
        try await waitUntil("its audio joins the conversation", timeout: 20, state: {
            let connection = session.direct as? WatchConnection
            return "listed \(connection?.recordings.map { "\($0.id.prefix(8)) \($0.isInProgress ? "in progress" : "complete")" } ?? []), "
                + "waiting \(session.adoptedImports.map { $0.recordingID.prefix(8) }), queued \(session.queue.total), "
                + "failures \(session.failures.map(\.message)), last problem \(connection?.lastTechnicalProblem ?? "none"), "
                + "library ready \(session.libraryReady), conversations with it \(rig.library.controller.meetings.filter { $0.tracks.contains { $0.deviceKind == AppleWatchIntegration.id } }.map(\.id))"
        }) {
            rig.library.controller.meeting(id)?.tracks.contains { $0.deviceKind == AppleWatchIntegration.id } == true
        }
        let track = try XCTUnwrap(rig.library.controller.meeting(id)?.tracks.first { $0.deviceKind == AppleWatchIntegration.id })
        XCTAssertEqual(track.deviceRecordingID, watchRecording)
        XCTAssertEqual(track.deviceSerial, rig.watch.watchID)
        XCTAssertEqual(track.source, .microphone)
        XCTAssertEqual(track.duration ?? 0, 3, accuracy: 0.05, "Both parts, joined")
        XCTAssertNotNil(track.startedAt, "Its start, on this iPhone's clock")
        try await waitUntil("the watch let go of its copies") { rig.watch.finished.isEmpty }
        XCTAssertNil(rig.watch.contexts.last?.sharedRecording)
    }

    func testTheWatchsPartsAreJoinedOnTheirTimelineAndKept() async throws {
        let folder = try temporaryDirectory()
        let info = WatchRecordingInfo(id: "rec", startedAt: Date(), duration: 5, segmentIndices: [0, 1], isFinished: true)
        func part(_ index: Int, at offset: TimeInterval, frequency: Float) throws -> WatchStagedSegment {
            let segment = WatchSegment(recordingID: "rec", index: index, startOffset: offset, duration: 2, recording: info)
            let url = folder.appendingPathComponent(segment.fileName)
            _ = try CaptureFiles.writeClosedSegment(to: url, seconds: 2, frequency: frequency)
            return WatchStagedSegment(url: url, segment: segment)
        }
        // A second's gap between them (a call on the watch).
        let parts = [try part(0, at: 0, frequency: 440), try part(1, at: 3, frequency: 660)]
        let output = folder.appendingPathComponent("rec.m4a")
        try await PhoneWatch.join(parts, into: output)
        let audio = try DecodedAudio(url: output)
        let frame = Double(RecordingAssembler.packetFrames) / 48_000
        XCTAssertEqual(audio.duration, 5, accuracy: frame)
        XCTAssertEqual(audio.frequency(0.3..<1.7), 440, accuracy: 3)
        XCTAssertLessThan(audio.rms(2.2..<2.8), 0.003, "The gap is silence")
        XCTAssertEqual(audio.frequency(3.3..<4.7), 660, accuracy: 3)
        XCTAssertTrue(parts.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }, "The parts stay until the import is done")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".join") }, "Its links go with it")

        // One part whole: the assembler's move takes a link, never the part.
        try await PhoneWatch.join([parts[0]], into: folder.appendingPathComponent("one.m4a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parts[0].url.path))

        // A part that can't be read fails the join: never part of the audio.
        var broken = parts[1]
        broken.url = folder.appendingPathComponent("broken.m4a")
        try Data("not audio".utf8).write(to: broken.url)
        let partial = folder.appendingPathComponent("partial.m4a")
        do {
            try await PhoneWatch.join([parts[0], broken], into: partial)
            XCTFail("Joined without a part")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    /// Parts as the watch writes them (`AVAudioFile` with SegmentWriter's settings: AAC-LC, mono, 48 kHz, about 64 kbps
    /// at a constrained variable rate), the third after a second's gap: joined by copying their packets, never encoded
    /// again, each where its offset says.
    func testTheWatchsOwnPartsJoinByCopyingPacketsAtTheirOffsets() async throws {
        let folder = try temporaryDirectory()
        let info = WatchRecordingInfo(id: "rec", startedAt: Date(), duration: 7, segmentIndices: [0, 1, 2], isFinished: true)
        // Apps/iOS/DaybookWatch/Recording/SegmentWriter.swift's `aacSettings`.
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                       AVSampleRateKey: WatchAudioFormat.speech.sampleRate,
                                       AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: WatchAudioFormat.speech.bitRate,
                                       AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained]
        func part(_ index: Int, at offset: TimeInterval, seconds: Double, frequency: Float) throws -> WatchStagedSegment {
            let segment = WatchSegment(recordingID: "rec", index: index, startOffset: offset, duration: seconds, recording: info)
            let url = folder.appendingPathComponent(segment.fileName)
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(seconds * format.sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![0][frame] = 0.3 * sin(Float(frame) * 2 * .pi * frequency / Float(format.sampleRate))
            }
            try file.write(from: buffer)
            file.close()
            return WatchStagedSegment(url: url, segment: segment)
        }
        let parts = [try part(0, at: 0, seconds: 2, frequency: 440), try part(1, at: 2, seconds: 2, frequency: 550),
                     try part(2, at: 5, seconds: 2, frequency: 660)]
        let output = folder.appendingPathComponent("rec.m4a")
        let result = try await PhoneWatch.join(parts, into: output)
        XCTAssertTrue(result.joined)
        XCTAssertFalse(result.reencoded, "Packets copied, never encoded again")
        XCTAssertTrue(result.warnings.isEmpty)

        let audio = try DecodedAudio(url: output)
        let frame = Double(RecordingAssembler.packetFrames) / 48_000
        XCTAssertEqual(audio.duration, 7, accuracy: 2 * frame)
        XCTAssertEqual(audio.frequency(0.3..<1.7), 440, accuracy: 3)
        XCTAssertEqual(audio.frequency(2.3..<3.7), 550, accuracy: 3)
        XCTAssertLessThan(audio.rms(4.2..<4.9), 0.003, "The gap is silence")
        XCTAssertEqual(audio.rms(5.05..<5.3), toneRMS, accuracy: 0.03, "The third starts at its offset")
        XCTAssertEqual(audio.frequency(5.3..<6.7), 660, accuracy: 3)
    }

    /// Daybook closed on the watch as this iPhone starts recording: a Start can't reach it, so it isn't part of the
    /// recording, and nothing says so: no chip, no line.
    func testAWatchAStartCantReachIsLeftOutOfTheRecordingQuietly() async throws {
        let rig = try rig()
        let recorder = RecorderRig()
        let model = PhoneAppModel(recorder: recorder.recorder, library: rig.library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  settings: rig.settings, devices: rig.devices)
        rig.devices.start()
        try await waitUntil("the watch, connected") { rig.devices.watch?.session?.direct?.state == .connected }
        rig.watch.isReachable = false

        try await model.startRecording()
        recorder.pump(1)
        let id = try XCTUnwrap(model.recorder.captureID)
        XCTAssertEqual(rig.devices.cascade.conversation?.id, id)
        // The same start the recording began: answered once it has run.
        await rig.devices.cascade.startRecorders()
        XCTAssertNil(rig.devices.cascade.member(PhoneWatch.deviceID))
        XCTAssertNil(rig.devices.cascade.status)
        XCTAssertFalse(PhoneRecorderStatus.inputs(model).recorders.contains { $0.id == PhoneWatch.deviceID }, "No chip")
        XCTAssertFalse(rig.watch.answered.contains { if case .start = $0 { return true } else { return false } })
        XCTAssertNil(rig.watch.recording)
        try await model.stopRecording()
    }

    /// The watch records along with a shared recording this library doesn't have (only a recorder's, or a Mac's), and
    /// this iPhone relaunches before it ends: nothing remembers the shared recording, yet the watch's audio files into
    /// that conversation, made for it, never one of its own.
    func testAfterARelaunchTheWatchsAudioFilesIntoTheConversationItWasRecordedFor() async throws {
        let rig = try rig(Self.writesAudio)
        // As the app's scene does at launch.
        try await rig.library.reload()
        rig.devices.start()
        try await waitUntil("the watch, connected") { rig.devices.watch?.session?.direct?.state == .connected }
        let conversation = UUID()
        rig.devices.cascade.begin(conversation, title: "Walk", date: Date(), ledHere: false)
        await rig.devices.cascade.startRecorders()
        XCTAssertEqual(rig.watch.recording?.conversationID, conversation)
        let recording = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(3)
        XCTAssertNil(rig.library.controller.meeting(conversation))

        // Launched again: the devices are made from what they stored, and the cascade is new.
        rig.devices.shutDown()
        let relaunched = PhoneDevices(library: rig.library, settings: rig.settings, mode: .inert, defaults: rig.devicesDefaults,
                                      timing: rig.timing, watchTransport: rig.watch)
        addTeardownBlock { relaunched.shutDown() }
        relaunched.start()
        // It shares nothing now: the watch follows and ends, and its last part arrives.
        try await waitUntil("the watch stops") { rig.watch.recording == nil }
        try await waitUntil("filed into its conversation", timeout: 20, state: {
            let session = relaunched.watch?.session
            let connection = session?.direct as? WatchConnection
            return "listed \(connection?.recordings.map { "\($0.id.prefix(8)) \($0.isInProgress ? "in progress" : "complete")" } ?? []), "
                + "state \(String(describing: connection?.state)), waiting \(session?.adoptedImports.map { $0.recordingID.prefix(8) } ?? []), "
                + "queued \(session?.queue.total ?? -1), failures \(session?.failures.map(\.message) ?? []), "
                + "last problem \(connection?.lastTechnicalProblem ?? "none"), library ready \(session?.libraryReady ?? false), "
                + "loaded \(rig.library.controller.isLoaded), managed elsewhere \(session?.managedElsewhere != nil), "
                + "watch finished \(rig.watch.finished.map { "\($0.id.prefix(8)) \($0.segmentIndices)" }), meetings \(rig.library.controller.meetings.count)"
        }) { !Self.withWatchTrack(rig.library).isEmpty }
        XCTAssertEqual(Self.withWatchTrack(rig.library).map(\.id), [conversation], "Never one of its own")
        let track = try XCTUnwrap(rig.library.controller.meeting(conversation)?.tracks.first { $0.deviceKind == AppleWatchIntegration.id })
        XCTAssertEqual(track.deviceRecordingID, recording)
        XCTAssertEqual(track.duration ?? 0, 3, accuracy: 0.05, "Both parts, joined")
    }

    /// Ended mid-recording with the watch recording along, Daybook is launched again: the watch's recording is complete
    /// before recovery has filed this iPhone's own. It waits, so this iPhone's recording makes the conversation (its
    /// title, its date, the timeline's origin) and the watch's joins it.
    func testAfterARelaunchTheWatchsAudioWaitsForThisIPhonesOwnRecordingOfTheConversation() async throws {
        let rig = try rig(Self.writesAudio)
        let conversation = UUID()
        let (relaunched, folder) = try await relaunchMidRecording(rig, conversation: conversation)
        let model = PhoneAppModel(recorder: RecorderRig().recorder, library: rig.library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  settings: rig.settings, devices: relaunched)
        relaunched.start()
        // It shares nothing now: the watch follows and ends, and its last part arrives.
        try await waitUntil("the watch stops") { rig.watch.recording == nil }
        try await waitUntil("its recording, complete") {
            (relaunched.watch?.session?.direct as? WatchConnection)?.recordings.first?.isInProgress == false
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(Self.withWatchTrack(rig.library).isEmpty, "It waits for this iPhone's recovery")
        XCTAssertNil(rig.library.controller.meeting(conversation))

        await model.recoverLeftovers()
        try await waitUntil("the watch's audio joins it", timeout: 20) { !Self.withWatchTrack(rig.library).isEmpty }
        XCTAssertEqual(rig.library.controller.meetings.map(\.id), [conversation], "One conversation")
        let meeting = try XCTUnwrap(rig.library.controller.meeting(conversation))
        XCTAssertEqual(meeting.title, "Standup")
        XCTAssertEqual(meeting.tracks.count, 2, "This iPhone's recording and the watch's")
        let phoneTrack = try XCTUnwrap(meeting.tracks.first { $0.deviceKind == PhoneDevice.kind })
        XCTAssertEqual(meeting.date.timeIntervalSince1970, try XCTUnwrap(phoneTrack.startedAt).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(phoneTrack.offset, 0, "This iPhone's recording is the timeline's origin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// The watch's audio was filed first after all (nothing held it: no recovery ran in this launch), so its import made
    /// the conversation, named for the watch. Filed into it, this iPhone's own recording gives it its title and date;
    /// the watch's recording stays the timeline's origin (docs/multipoint.md, "The timeline").
    func testAConversationTheWatchsImportMadeFirstTakesThisIPhonesTitleAndDate() async throws {
        let rig = try rig(Self.writesAudio)
        let conversation = UUID()
        let (relaunched, folder) = try await relaunchMidRecording(rig, conversation: conversation)
        relaunched.start()
        try await waitUntil("the watch's audio files first", timeout: 20) { !Self.withWatchTrack(rig.library).isEmpty }
        let placeholder = try XCTUnwrap(rig.library.controller.meeting(conversation))
        XCTAssertNotEqual(placeholder.title, "Standup")
        let watchStart = try XCTUnwrap(placeholder.tracks.first?.startedAt)

        var recording = try await PhoneRecorder.recover(in: folder)
        // The synthetic microphone's clock has its own start: this iPhone's recording began a moment before the watch's.
        recording.startedAt = watchStart.addingTimeInterval(-1)
        let filed = try await rig.library.fileRecording(recording)
        XCTAssertEqual(filed.meeting.id, conversation)
        XCTAssertEqual(filed.meeting.title, "Standup")
        XCTAssertEqual(filed.meeting.date.timeIntervalSince1970, recording.startedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(filed.meeting.tracks.count, 2)
        let phoneTrack = try XCTUnwrap(filed.meeting.tracks.first { $0.deviceKind == PhoneDevice.kind })
        XCTAssertNil(phoneTrack.offset, "Placed against the watch's recording")
        XCTAssertEqual(rig.library.controller.meetings.map(\.id), [conversation])
    }

    /// A conversation the watch began on its own that this iPhone records into later (Keep Recording) keeps its title
    /// and date: the watch's recording ended before this one began.
    func testOnlyAConversationTheWatchRecordedAlongWithIsThisIPhones() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func meeting(watchFrom began: TimeInterval, for seconds: TimeInterval) -> Meeting {
            var meeting = Meeting(id: UUID(), title: "Apple Watch at 10:02", date: start.addingTimeInterval(began), status: .draft)
            meeting.tracks = [RecordingTrack(source: .microphone, relativePath: "Audio/watch.m4a", fileName: "watch.m4a",
                                             duration: seconds, device: DeviceRecordingIdentity(kind: AppleWatchIntegration.id, serial: "w",
                                                                                                recordingID: "rec"),
                                             startedAt: start.addingTimeInterval(began))]
            return meeting
        }
        // This iPhone's recording: ten minutes from `start`.
        func placeholder(_ meeting: Meeting) -> Bool { PhoneLibrary.isWatchPlaceholder(meeting, along: start, duration: 600) }
        XCTAssertTrue(placeholder(meeting(watchFrom: 2, for: 590)), "Recorded along")
        XCTAssertTrue(placeholder(meeting(watchFrom: -3, for: 60)), "Its button began it")
        XCTAssertFalse(placeholder(meeting(watchFrom: -900, for: 300)), "Over before this began")
        var withMac = meeting(watchFrom: 2, for: 590)
        withMac.tracks.append(RecordingTrack(source: .microphone, relativePath: "Audio/mac.m4a", fileName: "mac.m4a", duration: 600))
        XCTAssertFalse(placeholder(withMac), "Another device's recording is in it")
    }

    // MARK: Keep Recording's later part

    /// A conversation this iPhone recorded, three seconds from `start`, filed as its own recording.
    private func conversation(_ id: UUID = UUID(), title: String = "Standup", start: Date, placement: LibraryPlacement? = nil,
                              in library: PhoneLibrary) async throws -> UUID {
        let url = try temporaryDirectory().appendingPathComponent("phone.m4a")
        _ = try CaptureFiles.writeClosedSegment(to: url, seconds: 3, frequency: Self.tone(id.uuidString))
        try await library.reload()
        var meeting = Meeting(id: id, title: title, date: start, status: .imported)
        meeting.placement = placement
        library.controller.add(meeting)
        await library.controller.acquireLock()
        defer { library.controller.releaseLock() }
        let identity = PhoneDevice.identity(recordingID: UUID(), installation: library.installationID)
        _ = try await library.controller.ingest(url, into: id, provenance: RecordingProvenance(source: .microphone, device: identity, offset: 0,
                                                                                             duration: 3, startedAt: start))
        return id
    }

    /// The devices started, with the watch connected and its clock sampled.
    private func started(_ rig: Rig) async throws {
        try await rig.library.reload()
        rig.devices.start()
        try await waitUntil("the watch, connected") { rig.devices.watch?.session?.direct?.state == .connected }
        try await waitUntil("the watch, listed") { (rig.devices.watch?.session?.direct as? WatchConnection)?.isRefreshing == false }
    }

    /// Keep Recording on the watch into `conversation`: `seconds` of audio, a bookmark `at` seconds in when asked, then Stop.
    /// Returns the watch recording and its bookmark.
    @discardableResult
    private func keepRecording(_ rig: Rig, into conversation: UUID, seconds: TimeInterval = 3,
                               bookmarkAt: TimeInterval? = nil) throws -> (recording: String, bookmark: WatchBookmark?) {
        rig.watch.pressKeepRecording(into: conversation)
        let recording = try XCTUnwrap(rig.watch.recording?.id)
        XCTAssertEqual(rig.watch.recording?.isContinuation, true)
        rig.watch.record(seconds)
        let mark = bookmarkAt.flatMap { rig.watch.pressBookmark(at: $0) }
        rig.watch.pressStop()
        return (recording, mark)
    }

    /// The conversation the watch's recording went into, once its import has finished (its bookmarks and request filed).
    private func imported(_ recording: String, in rig: Rig) async throws -> Meeting {
        try await waitUntil("the watch's recording imported", timeout: 20) {
            rig.devices.lastImported?.meeting.tracks.contains { $0.deviceRecordingID == recording } == true
        }
        return try XCTUnwrap(rig.devices.lastImported.flatMap { rig.library.controller.meeting($0.meeting.id) })
    }

    /// The later part lands in the same conversation as a further track, at its own start on this iPhone's clock (the
    /// ten minutes between stay a gap), with its bookmark on its track, and asks for its new audio to be processed. The
    /// conversation keeps its title, date, and timeline.
    func testKeepRecordingFilesTheLaterPartIntoTheSameConversationAfterItsGap() async throws {
        let rig = try rig(Self.writesAudio)
        let start = Date().addingTimeInterval(-600)
        let id = try await conversation(start: start, in: rig.library)
        try await started(rig)
        let before = try XCTUnwrap(rig.library.controller.meeting(id))

        let (recording, mark) = try keepRecording(rig, into: id, bookmarkAt: 1.5)
        let meeting = try await imported(recording, in: rig)
        XCTAssertEqual(meeting.id, id)
        XCTAssertEqual(rig.library.controller.meetings.count, 1, "No conversation of its own")
        XCTAssertEqual(meeting.title, "Standup")
        XCTAssertEqual(meeting.date, before.date)
        XCTAssertEqual(meeting.tracks.count, 2)
        let phone = try XCTUnwrap(meeting.tracks.first { $0.deviceKind == PhoneDevice.kind })
        XCTAssertEqual(phone.offset, 0, "This iPhone's recording stays the timeline's origin")
        let later = try XCTUnwrap(meeting.tracks.first { $0.deviceRecordingID == recording })
        XCTAssertEqual(later.duration ?? 0, 3, accuracy: 0.05)
        let begun = try XCTUnwrap(later.startedAt)
        XCTAssertEqual(begun.timeIntervalSinceNow, 0, accuracy: 10, "Its own start, on this iPhone's clock")
        XCTAssertGreaterThan(begun.timeIntervalSince(try XCTUnwrap(phone.startedAt).addingTimeInterval(3)), 590, "The time between is a gap")
        XCTAssertTrue(meeting.openProcessingRequests.contains { $0.mode == .newAudio }, "Its new audio is asked for")
        let bookmark = try XCTUnwrap(meeting.highlights.first)
        XCTAssertEqual(meeting.highlights.count, 1)
        XCTAssertEqual(bookmark.id, mark?.id)
        XCTAssertEqual(bookmark.trackID, later.id, "On the later part, so it follows its placement")
        XCTAssertEqual(bookmark.time, 1.5, accuracy: 0.001, "At its moment in the later part")
    }

    /// The conversation went to the Trash during the five minutes: the later part gets a conversation of its own, named
    /// as any of the watch's recordings, and the one in the Trash keeps its ID, so Restore brings it back as it was.
    func testALaterPartWhoseConversationIsInTheTrashGetsOneOfItsOwn() async throws {
        let rig = try rig(Self.writesAudio)
        let id = try await conversation(start: Date().addingTimeInterval(-300), in: rig.library)
        try await started(rig)
        let trashed = try await rig.library.controller.moveToTrash(id)
        XCTAssertTrue(trashed)

        let (recording, mark) = try keepRecording(rig, into: id, bookmarkAt: 1)
        let meeting = try await imported(recording, in: rig)
        XCTAssertNotEqual(meeting.id, id, "Never under the trashed conversation's ID")
        XCTAssertTrue(meeting.title.hasPrefix("Apple Watch at "), meeting.title)
        XCTAssertEqual(meeting.tracks.count, 1)
        XCTAssertEqual(meeting.highlights.map(\.id), [try XCTUnwrap(mark).id], "Its bookmark goes with it")
        XCTAssertNil(rig.library.controller.meeting(id))
        XCTAssertTrue(rig.library.controller.trashedMeetingIDs().contains(id))

        let restored = try await rig.library.controller.restoreFromTrash(id)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.title, "Standup")
        XCTAssertEqual(restored.tracks.count, 1, "As it was")
        XCTAssertEqual(Set(rig.library.controller.meetings.map(\.id)), [id, meeting.id])
    }

    /// Its deletion went out through sync (or it was deleted outright): the later part never brings that ID back, where
    /// the next pass would delete it again, audio and all. It gets a conversation of its own.
    func testALaterPartWhoseConversationWasDeletedGetsOneOfItsOwn() async throws {
        let rig = try rig(synced: true, Self.writesAudio)
        let synced = try await conversation(start: Date().addingTimeInterval(-300), in: rig.library)
        let outright = try await conversation(title: "Retro", start: Date().addingTimeInterval(-200), in: rig.library)
        try await started(rig)
        for id in [synced, outright] {
            let trashed = try await rig.library.controller.moveToTrash(id)
            XCTAssertTrue(trashed)
            try FileManager.default.removeItem(at: rig.library.rootURL.appendingPathComponent("Trash/\(id.uuidString)"))
        }
        // This device's sync checkpoint records the deletion, as a pass that published it leaves it.
        let sync = try XCTUnwrap(rig.library.controller.sync)
        let folder = rig.library.rootURL.appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let checkpoint = folder.appendingPathComponent("\(UUID().uuidString)-\(AudioDigest.sha256(data: Data(sync.deviceID.utf8)).prefix(16)).json")
        try JSONEncoder().encode(["deletedIDs": [synced]]).write(to: checkpoint)
        XCTAssertTrue(sync.isSyncedDeletion(synced))

        for id in [synced, outright] {
            let (recording, _) = try keepRecording(rig, into: id)
            let meeting = try await imported(recording, in: rig)
            XCTAssertNotEqual(meeting.id, id)
            XCTAssertTrue(meeting.title.hasPrefix("Apple Watch at "), meeting.title)
            XCTAssertNil(rig.library.controller.meeting(id))
        }
        XCTAssertEqual(rig.library.controller.meetings.count, 2, "Two conversations of their own, nothing under the old IDs")
    }

    /// The conversation was merged into another during the five minutes: the later part goes where the rest of it went.
    func testALaterPartWhoseConversationWasMergedAwayJoinsTheOneItWentInto() async throws {
        let rig = try rig(Self.writesAudio)
        let survivor = try await conversation(title: "Planning", start: Date().addingTimeInterval(-900), in: rig.library)
        let merged = try await conversation(title: "Planning, part two", start: Date().addingTimeInterval(-300), in: rig.library)
        try await started(rig)
        let controller = rig.library.controller
        let kept = try await controller.mergeConversations([survivor, merged], audio: { track, id in try await controller.audioURL(for: track, in: id) },
                                                           photo: { _, _ in throw DaybookError.libraryUnavailable },
                                                           context: { PhoneActions.mergeContext($0, recordingOnMac: []) })
        XCTAssertEqual(kept, survivor)
        XCTAssertNil(controller.meeting(merged))

        let (recording, mark) = try keepRecording(rig, into: merged, bookmarkAt: 2)
        let meeting = try await imported(recording, in: rig)
        XCTAssertEqual(meeting.id, survivor)
        XCTAssertEqual(controller.meetings.map(\.id), [survivor], "Nothing made for it")
        XCTAssertEqual(meeting.tracks.filter { !$0.isMovedOut }.count, 3, "Both recordings merged, and the later part")
        XCTAssertTrue(meeting.highlights.contains { $0.id == mark?.id })
        XCTAssertNil(controller.meeting(merged))
    }

    /// A Personal conversation with the lock on: the later part's audio is kept, in that conversation, and nothing about the
    /// import names it. While the lock hides it, the watch isn't offered Keep Recording for it.
    func testALaterPartOfALockedPersonalConversationIsKeptThere() async throws {
        let rig = try rig(Self.writesAudio)
        let personal = try await conversation(title: "Session with Dr. Lee", start: Date().addingTimeInterval(-300), placement: .personal,
                                              in: rig.library)
        let work = try await conversation(title: "Weekly product sync", start: Date().addingTimeInterval(-200), placement: .work, in: rig.library)
        let lock = PersonalLock(defaults: makeTestDefaults("PhoneWatchTests-lock"), platform: .iPhone,
                                authenticator: FakePersonalLockAuthenticator(method: .faceID, answers: false))
        lock.lookup = { [library = rig.library] id in library.controller.meeting(id) }
        await lock.setRequired(true)
        let previous = ReadingSession.appLock
        ReadingSession.appLock = lock
        defer { ReadingSession.appLock = previous }
        XCTAssertTrue(lock.hides(personal))
        let model = PhoneAppModel(recorder: RecorderRig().recorder, library: rig.library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  settings: rig.settings, devices: rig.devices)
        XCTAssertFalse(model.canAppendRecording(to: personal), "Hidden by the lock: not offered")
        XCTAssertTrue(model.canAppendRecording(to: work))
        try await started(rig)

        // Kept Recording before the lock came on: its audio is the conversation's.
        let (recording, _) = try keepRecording(rig, into: personal)
        let meeting = try await imported(recording, in: rig)
        XCTAssertEqual(meeting.id, personal)
        XCTAssertEqual(meeting.title, "Session with Dr. Lee")
        XCTAssertEqual(meeting.effectivePlacement, .personal)
        XCTAssertEqual(rig.library.controller.meetings.count, 2, "No copy of it, under any name")
        let text = DeviceNotifications.batchText(count: 1, device: "Apple Watch")
        XCTAssertFalse((text.title + text.body).contains("Dr. Lee"), "What the import says names no conversation")
    }

    /// The first part's import still waits (a segment missing) when the later part arrives: the later part goes in first,
    /// into the same conversation, and the first part joins it once complete. Nothing makes a second conversation, and
    /// each keeps its own start.
    func testALaterPartThatArrivesBeforeTheFirstPartBothJoinTheConversation() async throws {
        let rig = try rig(Self.writesAudio)
        let id = try await conversation(start: Date().addingTimeInterval(-120), in: rig.library)
        try await started(rig)
        // The first part, recorded along with the conversation, its segments held back on the way.
        rig.watch.deliversSegments = false
        rig.devices.cascade.begin(id, title: "Standup", date: Date(), ledHere: true)
        await rig.devices.cascade.startRecorders()
        let first = try XCTUnwrap(rig.watch.recording?.id)
        XCTAssertEqual(rig.watch.recording?.conversationID, id)
        rig.watch.record(3)
        await rig.devices.cascade.stop()
        try await waitUntil("the first part stops") { rig.watch.recording == nil }
        rig.watch.deliversSegments = true

        let (later, _) = try keepRecording(rig, into: id)
        let meeting = try await imported(later, in: rig)
        XCTAssertEqual(meeting.id, id)
        XCTAssertFalse(meeting.tracks.contains { $0.deviceRecordingID == first }, "The first part still waits")

        rig.watch.deliver()
        let whole = try await imported(first, in: rig)
        XCTAssertEqual(whole.id, id)
        XCTAssertEqual(rig.library.controller.meetings.map(\.id), [id])
        let watchTracks = whole.tracks.filter { $0.deviceKind == AppleWatchIntegration.id }
        XCTAssertEqual(watchTracks.count, 2)
        let firstStart = try XCTUnwrap(watchTracks.first { $0.deviceRecordingID == first }?.startedAt)
        let laterStart = try XCTUnwrap(watchTracks.first { $0.deviceRecordingID == later }?.startedAt)
        XCTAssertLessThanOrEqual(firstStart, laterStart, "Each at its own start")
    }

    /// A bookmark on the watch goes to the conversation the watch's recording is for, not whatever this iPhone records:
    /// with this iPhone recording another conversation, it isn't put there, and it arrives with the watch's recording.
    /// With this iPhone recording the same one, it shows at once in that recording, and the watch's import adds no second.
    func testAWatchBookmarkGoesToTheWatchsConversationOnly() async throws {
        let rig = try rig(Self.writesAudio)
        let recorder = RecorderRig()
        let model = PhoneAppModel(recorder: recorder.recorder, library: rig.library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  settings: rig.settings, devices: rig.devices)
        let earlier = try await conversation(start: Date().addingTimeInterval(-300), in: rig.library)
        try await started(rig)
        let session = try XCTUnwrap(rig.devices.watch?.session)

        // Kept Recording into an earlier conversation while this iPhone records a new one, the watch not along with it.
        session.update { $0.alsoRecordsWithMac = false }
        rig.watch.pressKeepRecording(into: earlier)
        rig.watch.record(2)
        try await model.startRecording()
        recorder.pump(1)
        let current = try XCTUnwrap(model.recorder.captureID)
        XCTAssertNotEqual(current, earlier)
        let elsewhere = try XCTUnwrap(rig.watch.pressBookmark(at: 1))
        XCTAssertFalse(model.recorder.highlights.contains { $0.id == elsewhere.id }, "Not in this iPhone's recording of another conversation")
        rig.watch.pressStop()
        let kept = try await imported(try XCTUnwrap(rig.watch.finished.last?.id), in: rig)
        XCTAssertEqual(kept.id, earlier)
        XCTAssertEqual(kept.highlights.map(\.id), [elsewhere.id], "It arrived with the watch's recording")
        try await model.stopRecording()
        XCTAssertFalse(rig.library.controller.meeting(current)?.highlights.contains { $0.id == elsewhere.id } ?? false)

        // Recording along with this iPhone: shown at once, and one bookmark once both recordings are in.
        session.update { $0.alsoRecordsWithMac = true }
        try await model.startRecording()
        recorder.pump(1)
        let shared = try XCTUnwrap(model.recorder.captureID)
        try await waitUntil("the watch records along") { rig.watch.recording?.conversationID == shared }
        let watchRecording = try XCTUnwrap(rig.watch.recording?.id)
        rig.watch.record(2)
        let along = try XCTUnwrap(rig.watch.pressBookmark(at: 1))
        XCTAssertTrue(model.recorder.highlights.contains { $0.id == along.id }, "Shown at once in this iPhone's recording")
        recorder.pump(1)
        try await model.stopRecording()
        try await waitUntil("the watch stops with it") { rig.watch.recording == nil }
        let both = try await imported(watchRecording, in: rig)
        XCTAssertEqual(both.id, shared)
        XCTAssertEqual(both.highlights.filter { $0.id == along.id }.count, 1, "One bookmark, not one per recording")
    }
}
