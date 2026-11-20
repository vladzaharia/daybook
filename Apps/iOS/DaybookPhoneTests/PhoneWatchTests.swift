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

    private func rig(_ configure: (SimulatedWatch) -> Void = { _ in }) throws -> Rig {
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: UUID().uuidString)
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

    /// Segments with real audio, as the watch's.
    private static func writesAudio(_ watch: SimulatedWatch) {
        watch.writeSegment = { url, segment in
            _ = try CaptureFiles.writeClosedSegment(to: url, seconds: segment.duration, frequency: 440)
        }
    }

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
}
