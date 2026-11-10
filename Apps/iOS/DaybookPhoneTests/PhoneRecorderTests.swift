import AVFoundation
import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// The recording engine, driven by synthetic PCM and a manual clock. No microphone is opened.
@MainActor
final class PhoneRecorderTests: XCTestCase {
    func testRecordingProducesAValidAACM4AOfTheRightDuration() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Standup")
        XCTAssertEqual(rig.recorder.state, .recording)
        XCTAssertTrue(rig.session.isActive)
        rig.pump(5)

        let recording = try await rig.stop()
        XCTAssertEqual(rig.recorder.state, .idle)
        XCTAssertFalse(rig.session.isActive)
        XCTAssertEqual(recording.audioURL.pathExtension, "m4a")
        XCTAssertEqual(recording.duration, 5, accuracy: 0.001)
        XCTAssertEqual(recording.title, "Standup")
        XCTAssertFalse(recording.recovered)

        let file = try AVAudioFile(forReading: recording.audioURL)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 240_000, "AVAudioFile reads the file sample-accurately, priming trimmed")
        // An MPEG-4 audio file: an ftyp box with the M4A brand.
        let header = try Data(contentsOf: recording.audioURL).prefix(12)
        XCTAssertEqual(String(decoding: header[4..<12], as: UTF8.self), "ftypM4A ")
        // At most about 64 kbps (constrained VBR; a steady tone needs less): 5 s is under ~40 KB plus the container.
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: recording.audioURL.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 5_000)
        XCTAssertLessThan(size, 50_000)

        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.rms(0.5..<4.5), toneRMS, accuracy: 0.02)
        XCTAssertEqual(audio.frequency(1..<4), 440, accuracy: 3)

        let journal = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(journal.state, .stopped)
        XCTAssertEqual(journal.segments.count, 1)
        XCTAssertEqual(journal.finalFile?.joined, false, "one clean segment is kept as it was encoded")
        XCTAssertEqual(journal.startedAt, rig.clock.now().addingTimeInterval(-5))
        XCTAssertEqual(recording.startedAt, journal.startedAt)
        XCTAssertEqual(recording.hostTimeSeconds, 1_000)
        XCTAssertEqual(recording.capture.method, "iphone-microphone")
    }

    func testOtherInputFormatsAreConvertedTo48kMono() async throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let rig = RecorderRig(inputFormat: stereo)
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "AirPods")
        rig.pump(4)
        let recording = try await rig.stop()

        let file = try AVAudioFile(forReading: recording.audioURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(recording.duration, 4, accuracy: 0.01)
        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.frequency(1..<3), 440, accuracy: 3)
        XCTAssertTrue(recording.capture.notes?.contains { $0.contains("44100 Hz, 2 ch") } == true)
    }

    func testInterruptionPausesWithACompleteFileAndResumesIntoOneRecording() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Call")
        rig.pump(3)

        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("the segment to close") {
            rig.recorder.isPaused && ((try? PhoneCaptureJournal.load(from: folder))?.segments.first?.closed == true)
        }
        XCTAssertEqual(rig.recorder.state, .paused(.interruption))
        XCTAssertEqual(rig.recorder.pausedAt ?? 0, 3, accuracy: 1e-6)
        // What was recorded before the call is a complete file on disk during the call.
        let firstPart = try AVAudioFile(forReading: folder.appendingPathComponent("segment-000.m4a"))
        XCTAssertEqual(firstPart.length, 3 * 48_000)

        rig.clock.advance(2)  // the call
        rig.recorder.editNotes("Written during the call")
        rig.session.send(.interruptionEnded(shouldResume: true))
        try await waitUntil("recording to resume") { rig.recorder.state == .recording }
        XCTAssertEqual(rig.inputs.all.count, 2)
        XCTAssertEqual(rig.session.activations, 2)
        rig.pump(2)

        let recording = try await rig.stop()
        XCTAssertEqual(recording.duration, 7, accuracy: 0.01, "3 s, a 2 s silent gap, 2 s")
        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.duration, 7, accuracy: 0.01)
        XCTAssertEqual(audio.rms(0.3..<2.8), toneRMS, accuracy: 0.02)
        XCTAssertLessThan(audio.rms(3.2..<4.8), 0.003, "the interruption is silence")
        XCTAssertEqual(audio.rms(5.2..<6.8), toneRMS, accuracy: 0.02)
        XCTAssertEqual(audio.frequency(5.2..<6.8), 440, accuracy: 3)
        XCTAssertEqual(recording.timedNotes.first?.time ?? 0, 5, accuracy: 1e-6)

        let journal = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(journal.segments.map(\.startOffset), [0, 5])
        XCTAssertEqual(journal.interruptions.count, 1)
        XCTAssertEqual(journal.interruptions.first?.resumed, true)
        XCTAssertEqual(journal.finalFile?.joined, true)
        XCTAssertTrue(recording.capture.notes?.contains { $0.hasPrefix("Paused 0:03–0:05") } == true)
    }

    func testInterruptionWithoutResumeRecommendationOffersResume() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Siri")
        rig.pump(2)
        rig.session.send(.interruptionBegan(reason: "Siri"))
        try await waitUntil("pause") { rig.recorder.isPaused }
        rig.session.send(.interruptionEnded(shouldResume: false))
        XCTAssertTrue(rig.recorder.canResume)
        XCTAssertTrue(rig.recorder.isPaused, "stays paused until the person resumes")
        XCTAssertEqual(rig.recorder.pauseMessage, "Siri")

        rig.clock.advance(1)
        try await rig.recorder.resume()
        XCTAssertEqual(rig.recorder.state, .recording)
        XCTAssertFalse(rig.recorder.canResume)
        rig.pump(1)
        let recording = try await rig.stop()
        XCTAssertEqual(recording.duration, 4, accuracy: 0.01)
    }

    func testStopWhilePausedEndsAtThePause() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Alarm")
        rig.pump(2)
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("pause") { rig.recorder.isPaused }
        rig.clock.advance(30)
        let recording = try await rig.stop()
        XCTAssertEqual(recording.duration, 2, accuracy: 0.001, "no trailing silence for the time spent paused")
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).finalFile?.joined, false)
    }

    func testAudioArrivingAfterInputStopsIsDropped() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Late buffers")
        rig.inputs.current.deliversAfterStop = true
        rig.pump(2)
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("pause") { rig.recorder.isPaused }
        rig.pump(0.3)   // in flight when the interruption stopped input
        await rig.recorder.flush()
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).segments.count, 1, "no stray segment while paused")

        try await rig.recorder.resume()
        rig.inputs.current.deliversAfterStop = true
        rig.pump(1)
        let late = rig.inputs.current
        let recording = try await rig.stop()
        late.pump(seconds: 0.2)  // after Stop
        XCTAssertEqual(recording.duration, 3.3, accuracy: 0.01)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("segment-") }
        XCTAssertEqual(files.sorted(), ["segment-000.m4a", "segment-001.m4a"])
    }

    func testSleepDuringAnInterruptionStillPlacesTheNextPartCorrectly() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Long call")
        rig.pump(2)
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("pause") { rig.recorder.isPaused }
        rig.clock.sleep(5)    // the phone slept: the host clock stood still
        rig.clock.advance(1)
        rig.session.send(.interruptionEnded(shouldResume: true))
        try await waitUntil("resume") { rig.recorder.state == .recording }
        rig.pump(1)
        let recording = try await rig.stop()
        XCTAssertEqual(recording.duration, 9, accuracy: 0.01, "2 s + 6 s away (5 asleep) + 1 s")
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).segments.last?.startOffset ?? 0, 8, accuracy: 1e-6)
    }

    func testMediaServicesResetContinuesInANewPart() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Reset")
        rig.pump(2)
        rig.session.send(.mediaServicesReset)
        try await waitUntil("a new input") { rig.inputs.all.count == 2 && rig.recorder.state == .recording }
        rig.pump(2)
        let recording = try await rig.stop()
        XCTAssertEqual(recording.duration, 4, accuracy: 0.01)
        let journal = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(journal.segments.count, 2)
        XCTAssertTrue(recording.warnings.contains { $0.contains("Audio services restarted") })
    }

    func testStopDuringMediaServicesRecoveryCannotRestartTheMicrophone() async throws {
        let clock = ManualRecorderClock()
        let session = ScriptedAudioSession()
        let probe = ResetStopProbe()
        let inputs = InputBox()
        let environment = PhoneRecorderEnvironment(session: session, makeInput: {
            let input = SyntheticAudioInput(clock: clock)
            inputs.all.append(input)
            return StopObservedInput(input: input) {
                Task { @MainActor in
                    probe.recording = await probe.recorder.stop()
                    probe.finished = true
                }
            }
        }, clock: clock, realTimeEncoding: false)
        probe.recorder = PhoneRecorder(environment: environment)
        try await probe.recorder.start(in: try temporaryDirectory().appendingPathComponent("capture"), title: "Reset and stop")
        inputs.current.pump(seconds: 2)
        session.send(.mediaServicesReset)
        try await waitUntil("stop during reset") { probe.finished }
        XCTAssertNotNil(probe.recording)
        XCTAssertEqual(probe.recorder.state, .idle)
        XCTAssertEqual(inputs.all.count, 1, "Recovery must not create a replacement microphone after Stop")
        XCTAssertFalse(inputs.all.contains(where: \.isRunning))
        XCTAssertFalse(session.isActive)
    }

    func testRouteChangesAreRecorded() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "AirPods")
        rig.pump(1)
        let airPods = AudioInputRoute(name: "AirPods Pro", portType: "BluetoothHFP")
        rig.session.send(.routeChanged(reason: "new-device", input: airPods))
        XCTAssertEqual(rig.recorder.inputRoute, airPods)
        rig.pump(1)
        let recording = try await rig.stop()
        let notes = recording.capture.notes ?? []
        XCTAssertTrue(notes.contains("Recorded with Synthetic Microphone."))
        XCTAssertTrue(notes.contains { $0.contains("became AirPods Pro (new-device)") })
    }

    // MARK: The input

    private static let builtIn = AudioInputPort(id: "Built-In Microphone", name: "iPhone Microphone", portType: AVAudioSession.Port.builtInMic.rawValue)
    private static let airPods = AudioInputPort(id: "AC:90:85:AA:BB:CC-tsco", name: "AirPods Pro", portType: AVAudioSession.Port.bluetoothHFP.rawValue,
                                                supportsFarField: true)
    private static let olderAirPods = AudioInputPort(id: "F4:2B:11:AA:BB:CC-tsco", name: "AirPods", portType: AVAudioSession.Port.bluetoothHFP.rawValue)
    private static let usb = AudioInputPort(id: "AppleUSBAudioEngine:Shure:MV7", name: "Shure MV7", portType: AVAudioSession.Port.usbAudio.rawValue)

    /// A table recording with AirPods in someone's ears: iOS would record them, so the built-in microphone is preferred
    /// before the session starts, without far-field. The recording says it used the iPhone's microphone.
    func testBehaviorAutomaticRecordsTheIPhoneMicrophoneWithAirPodsIn() async throws {
        let rig = RecorderRig()
        rig.session.availableInputs = [Self.builtIn, Self.airPods]
        rig.session.currentInput = AudioInputRoute(name: "AirPods Pro", portType: AVAudioSession.Port.bluetoothHFP.rawValue)
        try await rig.recorder.start(in: try temporaryDirectory().appendingPathComponent("capture"), title: "Table")
        XCTAssertEqual(rig.session.plans, [AudioInputPlan(preferredInput: Self.builtIn.id, farField: false)])
        if #available(iOS 26.2, *) { XCTAssertFalse(rig.session.categoryOptions.contains(.farFieldInput)) }
        XCTAssertTrue(rig.session.categoryOptions.isSuperset(of: [.allowBluetoothHFP, .bluetoothHighQualityRecording, .defaultToSpeaker]))
        XCTAssertEqual(rig.recorder.inputRoute?.name, "iPhone Microphone")
        rig.pump(1)
        let recording = try await rig.stop()
        XCTAssertTrue(recording.capture.notes?.contains("Recorded with iPhone Microphone.") == true, "\(recording.capture.notes ?? [])")
    }

    /// AirPods connecting mid-recording don't take over: the session is asked again, and records the iPhone's microphone.
    func testBehaviorAirPodsConnectingMidRecordingDontTakeOver() async throws {
        let rig = RecorderRig()
        rig.session.availableInputs = [Self.builtIn]
        rig.session.currentInput = AudioInputRoute(name: "iPhone Microphone", portType: AVAudioSession.Port.builtInMic.rawValue)
        try await rig.recorder.start(in: try temporaryDirectory().appendingPathComponent("capture"), title: "Table")
        rig.pump(1)
        rig.session.availableInputs = [Self.builtIn, Self.airPods]
        rig.session.send(.routeChanged(reason: "new-device", input: AudioInputRoute(name: "AirPods Pro", portType: AVAudioSession.Port.bluetoothHFP.rawValue)))
        XCTAssertEqual(rig.session.plans.last, AudioInputPlan(preferredInput: Self.builtIn.id, farField: false))
        XCTAssertEqual(rig.recorder.inputRoute?.name, "iPhone Microphone")
        rig.pump(1)
        _ = try await rig.stop()
    }

    /// The person picks AirPods that can hear the room: they're recorded with far-field capture (iOS 26.2), and the
    /// choice is remembered, so the next recording uses them from its start. Without far-field on this iOS, or on older
    /// AirPods, they're recorded as they are.
    func testBehaviorPickingAirPodsRecordsTheRoomAndIsRemembered() async throws {
        let rig = RecorderRig()
        rig.session.availableInputs = [Self.builtIn, Self.airPods]
        try await rig.recorder.start(in: try temporaryDirectory().appendingPathComponent("capture"), title: "Table")
        rig.pump(1)
        rig.session.pick(Self.airPods)
        rig.recorder.inputChosen()
        XCTAssertEqual(rig.session.preference, .device(Self.airPods.device))
        XCTAssertEqual(rig.session.plans.last, AudioInputPlan(preferredInput: Self.airPods.id, farField: true))
        if #available(iOS 26.2, *) { XCTAssertTrue(rig.session.categoryOptions.contains(.farFieldInput)) }
        XCTAssertEqual(rig.recorder.inputRoute?.name, "AirPods Pro")
        rig.pump(1)
        let recording = try await rig.stop()
        XCTAssertTrue(recording.capture.notes?.contains { $0.contains("became AirPods Pro") } == true)

        // The next recording starts on them.
        rig.session.currentInput = AudioInputRoute(name: "iPhone Microphone", portType: AVAudioSession.Port.builtInMic.rawValue)
        try await rig.recorder.start(in: try temporaryDirectory().appendingPathComponent("capture-2"), title: "Next")
        XCTAssertEqual(rig.recorder.inputRoute?.name, "AirPods Pro")
        rig.pump(1)
        _ = try await rig.stop()

        XCTAssertEqual(AudioInputPlan.make(inputs: [Self.builtIn, Self.airPods], currentInput: nil, preference: .device(Self.airPods.device),
                                           farFieldAvailable: false),
                       AudioInputPlan(preferredInput: Self.airPods.id, farField: false), "iOS 26.0 and 26.1")
        XCTAssertEqual(AudioInputPlan.make(inputs: [Self.builtIn, Self.olderAirPods], currentInput: nil, preference: .device(Self.airPods.device),
                                           farFieldAvailable: true),
                       AudioInputPlan(preferredInput: Self.olderAirPods.id, farField: false), "another headset stands in, as it can")
    }

    /// Opening the picker and leaving the input as it was chooses nothing: Automatic stays Automatic.
    func testBehaviorLeavingThePickerAsItWasChoosesNothing() async throws {
        let rig = RecorderRig()
        rig.session.availableInputs = [Self.builtIn, Self.airPods]
        try await rig.recorder.start(in: try temporaryDirectory().appendingPathComponent("capture"), title: "Table")
        rig.recorder.inputChosen()
        XCTAssertEqual(rig.session.preference, .automatic)
        rig.pump(1)
        _ = try await rig.stop()
    }

    /// A USB microphone is what iOS records by default, and Automatic keeps it.
    func testBehaviorAutomaticKeepsAWiredMicrophone() {
        XCTAssertEqual(AudioInputPlan.make(inputs: [Self.builtIn, Self.usb], currentInput: nil, preference: .automatic, farFieldAvailable: true),
                       AudioInputPlan(preferredInput: Self.usb.id, farField: false))
        XCTAssertEqual(AudioInputPlan.make(inputs: [Self.builtIn, Self.usb, Self.airPods], currentInput: Self.airPods.id, preference: .automatic,
                                           farFieldAvailable: true),
                       AudioInputPlan(preferredInput: Self.builtIn.id, farField: false))
        XCTAssertEqual(AudioInputPort.kind(AVAudioSession.Port.headsetMic.rawValue), .wired)
        XCTAssertEqual(AudioInputPort.kind(AVAudioSession.Port.carAudio.rawValue), .other)
    }

    /// What a killed app leaves on disk depends on AVAssetWriter writing a movie fragment each time the
    /// audio passes a fragment boundary. In the recorder's real-time mode it does, promptly, whether
    /// the audio is loud or silent (VBR silence is tiny); in non-real-time mode it held back the first
    /// 3 s or more, which made the crash-recovery test depend on the runtime.
    func testRealTimeSegmentsReachTheDiskAtEachFragmentInterval() async throws {
        var format = RecordingFormat.speech
        format.fragmentInterval = 1
        for amplitude: Float in [0.3, 0] {
            let url = try temporaryDirectory().appendingPathComponent("segment.m4a")
            let writer = try AACSegmentWriter(url: url, format: format, realTime: true)
            defer { writer.cancel() }
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format.pcmFormat, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            for index in 0..<4_800 { buffer.floatChannelData![0][index] = amplitude * sin(Float(index) * 2 * .pi * 440 / 48_000) }
            for _ in 0..<25 { try writer.append(buffer) }   // 2.5 s, faster than real time
            let copy = url.deletingLastPathComponent().appendingPathComponent("copy.m4a")
            var seconds = 0.0
            try await waitUntil("amplitude \(amplitude): every fragment the audio has passed on disk", timeout: 30, poll: .milliseconds(100),
                                state: { "\(seconds) s readable" }) {
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: url, to: copy)
                seconds = (try? AVAudioFile(forReading: copy)).map { Double($0.length) / format.sampleRate } ?? 0
                return seconds >= 2
            }
        }
    }

    func testCrashRecoveryProducesAudioNotesAndBookmarks() async throws {
        // The recorder's real-time mode, as on a phone: fragments land as the audio passes each interval.
        let rig = RecorderRig(fragmentInterval: 1, realTimeEncoding: true)
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Crash")
        rig.pump(1)
        rig.recorder.editNotes("Before the crash")
        rig.pump(2)
        rig.recorder.addBookmark()
        rig.pump(4)
        await rig.recorder.flush()

        // Copy the folder as it is on disk mid-recording: that is what a killed app leaves behind.
        let crashed = try temporaryDirectory().appendingPathComponent("crashed")
        var readable: Int64 = 0
        let snapshot = try await waitFor("fragments with 4 s of audio on disk while recording", timeout: 30, poll: .milliseconds(100),
                                         state: { "\(readable) frames readable" }) { () -> URL? in
            try? FileManager.default.removeItem(at: crashed)
            // A journal write can rename its temporary file mid-copy; copy again, as for short audio.
            guard (try? FileManager.default.copyItem(at: folder, to: crashed)) != nil else { return nil }
            readable = (try? AVAudioFile(forReading: crashed.appendingPathComponent("segment-000.m4a")))?.length ?? 0
            return readable >= 4 * 48_000 ? crashed : nil
        }
        XCTAssertNil(try PhoneCaptureJournal.load(from: snapshot).finalFile)

        let recording = try await PhoneRecorder.recover(in: snapshot)
        XCTAssertTrue(recording.recovered)
        XCTAssertGreaterThanOrEqual(recording.duration, 4)
        XCTAssertLessThanOrEqual(recording.duration, 7.01)
        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.rms(0.5..<3.5), toneRMS, accuracy: 0.02)
        XCTAssertEqual(audio.frequency(0.5..<3.5), 440, accuracy: 3)
        XCTAssertEqual(recording.notes, "Before the crash")
        XCTAssertEqual(recording.timedNotes.first?.time ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(recording.highlights.map(\.time), [3])
        XCTAssertTrue(recording.warnings.contains { $0.contains("Daybook quit while recording") })
        XCTAssertEqual(try PhoneCaptureJournal.load(from: snapshot).state, .stopped)

        // Recovering again (filing failed the first time) reuses the built file.
        let again = try await PhoneRecorder.recover(in: snapshot)
        XCTAssertEqual(again.duration, recording.duration)

        _ = await rig.recorder.stop()
    }

    func testRecoveryPicksUpAFolderLeftPausedAfterTermination() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Terminated")
        rig.pump(3)
        rig.recorder.addBookmark()
        await rig.recorder.flush()
        rig.recorder.prepareForTermination()

        XCTAssertEqual(PhoneRecorder.pendingCaptures(in: folder.deletingLastPathComponent()).map(\.lastPathComponent), ["capture"])
        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertEqual(recording.duration, 3, accuracy: 0.001)
        XCTAssertEqual(recording.highlights.count, 1)
        XCTAssertEqual(recording.endedAt.timeIntervalSince(recording.startedAt), recording.duration, accuracy: 0.001)
    }

    func testARecoveredRecordingEndsWhereItsAudioDoesWithASegmentTheJournalMissed() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Orphan")
        rig.pump(3)
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("paused") { rig.recorder.isPaused && ((try? PhoneCaptureJournal.load(from: folder))?.segments.first?.closed == true) }
        rig.session.send(.interruptionEnded(shouldResume: true))
        try await waitUntil("resumed") { rig.recorder.state == .recording }
        rig.pump(3)
        await rig.recorder.flush()
        rig.recorder.prepareForTermination()
        // The app died right after opening the second part: the journal never heard of it.
        var journal = try PhoneCaptureJournal.load(from: folder)
        journal.segments.removeAll { $0.index > 0 }
        try journal.write(to: folder)
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).segments.count, 1)

        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertGreaterThan(recording.duration, 5.9, "both parts")
        XCTAssertEqual(recording.endedAt.timeIntervalSince(recording.startedAt), recording.duration, accuracy: 0.001,
                       "it ended where its audio does, not where the counted frames did")
    }

    func testPhotosAreKeptAtTheirShutterTimeAndSurviveAQuit() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Whiteboard")
        rig.pump(5)
        // Accepted two seconds after the shutter: the camera's review step.
        let shutter = rig.clock.now().addingTimeInterval(-2)
        let keptPhoto = try await rig.recorder.addPhoto(syntheticCameraPhoto(capturedAt: shutter))
        let kept = try XCTUnwrap(keptPhoto)
        XCTAssertEqual(kept.time, 3, accuracy: 1e-6)
        XCTAssertEqual(kept.capturedAt, shutter)
        XCTAssertEqual(rig.recorder.photos, [kept])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(kept.fileName).path))
        // A clock that disagrees by more than a slow review places the photo at the moment it arrived.
        let strayPhoto = try await rig.recorder.addPhoto(syntheticCameraPhoto(capturedAt: shutter.addingTimeInterval(-3_600)))
        let stray = try XCTUnwrap(strayPhoto)
        XCTAssertEqual(stray.time, 0, accuracy: 1e-6)
        rig.pump(1)
        await rig.recorder.flush()
        rig.recorder.prepareForTermination()

        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).photos, [kept, stray])
        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertEqual(recording.photos, [kept, stray])
    }

    func testAPhotoArrivingAfterStopIsNotKeptWithTheRecording() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Late")
        rig.pump(2)
        let recording = try await rig.stop()
        let late = try await rig.recorder.addPhoto(syntheticCameraPhoto(capturedAt: rig.clock.now()))
        XCTAssertNil(late)
        XCTAssertEqual(recording.photos, [])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains { $0.hasPrefix("photo-") })
    }

    func testTheCameraKeepsItsShutterMomentAndOrientation() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 20)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 20))
        }
        let rotated = try XCTUnwrap(image.cgImage.map { UIImage(cgImage: $0, scale: 1, orientation: .right) })
        let exif: [String: Any] = [kCGImagePropertyExifDateTimeOriginal as String: "2026:10:24 14:03:12",
                                   kCGImagePropertyExifOffsetTimeOriginal as String: "+00:00",
                                   kCGImagePropertyExifSubsecTimeOriginal as String: "250"]
        let accepted = Date(timeIntervalSince1970: 1_900_000_000)
        let photo = try XCTUnwrap(CameraPhoto.encode(rotated, metadata: [kCGImagePropertyExifDictionary as String: exif], fallback: accepted))
        XCTAssertTrue(["heic", "jpg"].contains(photo.fileExtension))
        XCTAssertEqual(photo.capturedAt.timeIntervalSince1970, 1_792_850_592.25, accuracy: 0.001)
        let metadata = PhotoMetadata.read(photo.data)
        XCTAssertEqual(metadata.pixelWidth, 20 * Int(image.scale), "upright: the orientation tag turns it")
        XCTAssertEqual(metadata.pixelHeight, 60 * Int(image.scale))

        let plain = try XCTUnwrap(CameraPhoto.encode(image, metadata: nil, fallback: accepted))
        XCTAssertEqual(plain.capturedAt, accepted, "no EXIF: the moment it was accepted")
    }

    func testTimedNotesAndBookmarksUseTheConversationClockAsOnTheMac() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Notes")
        rig.pump(2)
        rig.recorder.editNotes("First point")
        XCTAssertEqual(rig.recorder.timedNotes.map(\.time), [2])
        rig.pump(3)
        rig.recorder.editNotes("First point\nSecond point")
        XCTAssertEqual(rig.recorder.timedNotes.map(\.time), [2, 5])
        rig.recorder.editNotes("First point, revised\nSecond point")
        XCTAssertEqual(rig.recorder.timedNotes.map(\.time), [2, 5], "editing never moves a paragraph's time")

        let mark = try XCTUnwrap(rig.recorder.addBookmark())
        XCTAssertEqual(mark.time, 5)
        XCTAssertNil(mark.trackID)
        XCTAssertEqual(mark.text, "")
        rig.pump(1)
        rig.recorder.addBookmark()

        let recording = try await rig.stop()
        XCTAssertEqual(recording.notes, "First point, revised\nSecond point")
        XCTAssertEqual(NoteTimeline.paragraphTimes(anchors: recording.timedNotes, text: recording.notes), [2, 5])
        XCTAssertEqual(recording.highlights.map(\.time), [5, 6])
        // The same rule the Mac applies (AppState.editNotes): reconcile with the recorder's elapsed time.
        let mac = NoteTimeline.reconcile(previous: NoteTimeline.reconcile(previous: [], text: "First point", captureTime: 2),
                                         text: "First point\nSecond point", captureTime: 5)
        XCTAssertEqual(mac.map(\.time), [2, 5])
    }

    func testAJournalThatCantBeWrittenIsReportedOnceAndRecordingContinues() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Full disk")
        rig.pump(2)
        // The audio file exists before the folder fills: on a busy machine the encoder may not have
        // opened it yet, and a recording that can't write its audio stops, which isn't this test's case.
        await rig.recorder.flush()
        // Counts reports of the problem, not every change: a route change on a busy simulator also calls onChange.
        var reports = 0, shown: String?
        rig.recorder.onChange = {
            if let error = rig.recorder.lastError, error != shown { reports += 1; shown = error }
        }
        // The folder can't take another file, as when the iPhone is full.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        rig.recorder.editNotes("A note the journal can't hold")
        await rig.recorder.flush()
        await rig.recorder.flush()
        let reported = try XCTUnwrap(rig.recorder.lastError)
        XCTAssertTrue(reported.hasPrefix("Notes and bookmarks couldn’t be saved"), reported)
        XCTAssertEqual(reports, 1, "Said once, not at every write")
        XCTAssertEqual(rig.recorder.state, .recording)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let recording = try await rig.stop()
        XCTAssertEqual(recording.notes, "A note the journal can't hold")
    }

    func testNotesOutsideARecordingHaveNoTime() {
        let rig = RecorderRig()
        rig.recorder.editNotes("Agenda")
        XCTAssertEqual(rig.recorder.timedNotes.map(\.time), [nil])
        XCTAssertNil(rig.recorder.addBookmark())
    }

    func testStartFailsCleanlyWithoutMicrophonePermission() async throws {
        let rig = RecorderRig()
        rig.session.permission = false
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        do {
            try await rig.recorder.start(in: folder, title: "Denied")
            XCTFail("expected a permission error")
        } catch {
            XCTAssertEqual(error as? PhoneRecorderError, .microphoneDenied)
        }
        XCTAssertEqual(rig.recorder.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testLevelsFollowTheInput() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Levels")
        rig.pump(1)
        rig.recorder.updateLevels()
        // 0.3 amplitude sine: about −13.5 dBFS RMS.
        XCTAssertEqual(rig.recorder.level.rms, 20 * log10(toneRMS), accuracy: 0.5)
        XCTAssertGreaterThan(rig.recorder.level.meterValue, 0.7)
        XCTAssertFalse(rig.recorder.isMicrophoneSilent)
        XCTAssertNotNil(rig.recorder.startedAt)
        _ = await rig.recorder.stop()
    }

    // MARK: Joining by copying packets

    /// An interrupted recording is joined by copying each part's AAC packets, byte for byte, into one file: the second part
    /// keeps its encoder priming inside the gap, lands within one AAC frame (21 ms) of where it was recorded, and the
    /// notes and bookmarks keep their times.
    func testAnInterruptedRecordingIsJoinedByCopyingEachPartsPackets() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Call")
        rig.pump(1)
        rig.recorder.editNotes("Before the call")
        rig.recorder.addBookmark()
        rig.pump(2)
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("the first part is closed") {
            rig.recorder.isPaused && ((try? PhoneCaptureJournal.load(from: folder))?.segments.first?.closed == true)
        }
        rig.clock.advance(2.5)   // the call: not a whole number of AAC frames
        rig.recorder.editNotes("Before the call\nDuring the call")
        rig.session.send(.interruptionEnded(shouldResume: true))
        try await waitUntil("recording to resume") { rig.recorder.state == .recording }
        // Another voice after the call, so the parts' packets differ.
        rig.inputs.current.signal = .tone(frequency: 660, amplitude: 0.3)
        rig.pump(2)
        rig.recorder.addBookmark()
        rig.pump(1)

        let recording = try await rig.stop()
        let joined = try await Self.packets(of: recording.audioURL)
        let first = try await Self.packets(of: folder.appendingPathComponent("segment-000.m4a"))
        let second = try await Self.packets(of: folder.appendingPathComponent("segment-001.m4a"))
        XCTAssertEqual(Array(joined.prefix(first.count)), first, "the first part's packets open the file, untouched")
        let at = try XCTUnwrap(Self.firstIndex(of: second, in: joined), "the second part's packets are in the file, untouched and in order")
        XCTAssertGreaterThan(at, first.count, "silence between them")
        XCTAssertEqual(at + second.count, joined.count, "and nothing after the second part")
        let silence = Set(joined[first.count..<at])
        XCTAssertEqual(silence.count, 1, "the gap is one packet of silence, again and again")

        let frame = Double(RecordingAssembler.packetFrames) / 48_000
        XCTAssertEqual(recording.duration, 8.5, accuracy: frame, "3 s, the 2.5 s call, 3 s: within one AAC frame")
        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.duration, recording.duration, accuracy: 1e-9)
        XCTAssertEqual(audio.rms(0.3..<2.8), toneRMS, accuracy: 0.02)
        XCTAssertLessThan(audio.rms(3.2..<5.3), 0.003, "the call is silence")
        XCTAssertEqual(audio.rms(5.8..<8.2), toneRMS, accuracy: 0.02)
        XCTAssertEqual(audio.frequency(0.3..<2.8), 440, accuracy: 3)
        XCTAssertEqual(audio.frequency(5.8..<8.2), 660, accuracy: 3)
        let onset = try XCTUnwrap(audio.samples.indices.dropFirst(Int(4.5 * 48_000)).first { abs(audio.samples[$0]) > 0.05 })
        XCTAssertEqual(Double(onset) / 48_000, 5.5, accuracy: frame, "the second part starts where it was recorded")

        XCTAssertEqual(recording.timedNotes.map(\.time), [1, 5.5], "note times are the conversation's, unchanged")
        XCTAssertEqual(recording.highlights.map(\.time), [1, 7.5])
        let journal = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(journal.finalFile?.joined, true)
        XCTAssertNil(journal.finalFile?.reencoded)
        XCTAssertEqual(journal.finalFile?.frameCount, Int64(audio.samples.count))
        XCTAssertTrue(recording.capture.notes?.contains("Joined from 2 parts.") == true, "\(recording.capture.notes ?? [])")
    }

    /// Parts in another format (none are written so today) can't share a file's packets: they're decoded and encoded
    /// once, exactly placed, and say so. Only a long one asks for time to finish in the background.
    func testPartsInDifferentFormatsAreEncodedAgain() async throws {
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var other = RecordingFormat.speech
        other.sampleRate = 44_100
        _ = try CaptureFiles.writeClosedSegment(to: folder.appendingPathComponent("segment-000.m4a"), seconds: 2, frequency: 440)
        _ = try CaptureFiles.writeClosedSegment(to: folder.appendingPathComponent("segment-001.m4a"), seconds: 2, frequency: 660, format: other)
        var journal = PhoneCaptureJournal(id: UUID(), title: "Two formats", createdAt: Date(timeIntervalSince1970: 1_800_000_000), format: .speech)
        journal.startedAt = journal.createdAt
        journal.segments = [
            CaptureSegment(index: 0, fileName: "segment-000.m4a", startOffset: 0, frameCount: 96_000, closed: true,
                           firstSampleHostTime: 1_000, clockAnchors: [], notes: nil),
            CaptureSegment(index: 1, fileName: "segment-001.m4a", startOffset: 3, frameCount: 88_200, closed: true,
                           firstSampleHostTime: 1_003, clockAnchors: [], notes: nil),
        ]
        journal.state = .stopped
        try journal.write(to: folder)
        let pieces = PhoneCaptureFinisher.pieces(journal, in: folder)
        XCTAssertFalse(RecordingAssembler.expectsLongJoin(pieces, format: .speech), "five seconds is quick to encode")
        XCTAssertTrue(RecordingAssembler.expectsLongJoin(pieces, format: .speech, longerThan: 4))

        let recording = try await PhoneRecorder.recover(in: folder)
        let after = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(after.finalFile?.reencoded, true)
        XCTAssertEqual(Double(after.finalFile?.frameCount ?? 0), 5 * 48_000, accuracy: 64, "placed at its offset, at 48 kHz")
        XCTAssertTrue(recording.capture.notes?.contains("Joined from 2 parts and encoded again.") == true, "\(recording.capture.notes ?? [])")
        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.frequency(0.3..<1.7), 440, accuracy: 3)
        XCTAssertEqual(audio.frequency(3.3..<4.7), 660, accuracy: 3)
    }

    /// Stop ends the capture first: every part closed and the journal saying it's being saved, before the audio session
    /// is given back, and before anything is joined.
    func testStopSaysItsSavingBeforeTheSessionGoes() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Two steps")
        rig.pump(2)
        var atCaptureEnd: (journal: PhoneCaptureJournal, sessionActive: Bool, joined: Bool)?
        let recording = await rig.recorder.stop(PhoneRecorder.StopEvents(captureEnded: {
            atCaptureEnd = ((try? PhoneCaptureJournal.load(from: folder))!, rig.session.isActive,
                            FileManager.default.fileExists(atPath: folder.appendingPathComponent(PhoneCaptureJournal.finalFileName).path))
        }))
        let ended = try XCTUnwrap(atCaptureEnd)
        XCTAssertEqual(ended.journal.state, .stopping)
        XCTAssertNotNil(ended.journal.endedAt)
        XCTAssertEqual(ended.journal.segments.map(\.closed), [true])
        XCTAssertFalse(ended.sessionActive, "the session is given back once the journal says so")
        XCTAssertFalse(ended.joined, "joining comes after")
        XCTAssertNotNil(recording)
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).state, .stopped)
    }

    /// Locked (its parts kept until unlock can't be read back), Stop ends the capture and leaves the join
    /// (`waitingCapture`), the journal saying `stopping`: never a failure, nothing joined. `finish` joins it once
    /// they can be read, as Stop would have.
    func testStopWhileLockedLeavesTheJoinForTheUnlock() async throws {
        let rig = RecorderRig()
        var locked = false
        rig.recorder.protectedDataAvailable = { !locked }
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Locked")
        rig.pump(2)
        locked = true
        var captureEnded = false
        let stopped = await rig.recorder.stop(PhoneRecorder.StopEvents(captureEnded: { captureEnded = true }))
        XCTAssertNil(stopped)
        XCTAssertTrue(captureEnded)
        XCTAssertEqual(rig.recorder.state, .idle, "free to record again")
        XCTAssertFalse(rig.session.isActive)
        XCTAssertNil(rig.recorder.lastFailure, "never a failure")
        XCTAssertNil(rig.recorder.unfinishedFolder)
        let waiting = try XCTUnwrap(rig.recorder.waitingCapture)
        XCTAssertEqual(waiting.directory, folder)
        XCTAssertEqual(waiting.journal.state, .stopping)
        XCTAssertEqual(waiting.duration, 2, accuracy: 0.05)
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).state, .stopping)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PhoneCaptureJournal.finalFileName).path))

        let recording = try await PhoneRecorder.finish(waiting)
        XCTAssertEqual(recording.duration, 2, accuracy: 0.001)
        XCTAssertNil(recording.recovery, "saved by Stop, not recovered")
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).state, .stopped)

        // The next recording starts clean.
        try await rig.recorder.start(in: try temporaryDirectory().appendingPathComponent("next"), title: "Next")
        XCTAssertNil(rig.recorder.waitingCapture)
        _ = await rig.recorder.stop()
    }

    // MARK: Hearing

    /// The hearing check is rolling: digital zeros for 5 s, or nothing above −90 dBFS for 20 s, is "Microphone silent",
    /// and sound clears it at once. A pause doesn't count against it.
    func testTheHearingCheckFlipsAfterZerosAndClearsWhenSoundComesBack() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Hearing")
        rig.pump(2)
        rig.recorder.updateLevels()
        XCTAssertFalse(rig.recorder.isMicrophoneSilent)

        // A mute switch: digital zeros.
        rig.inputs.current.signal = .silence
        rig.pump(4.5)
        rig.recorder.updateLevels()
        XCTAssertFalse(rig.recorder.isMicrophoneSilent, "under five seconds")
        rig.pump(0.6)
        rig.recorder.updateLevels()
        XCTAssertTrue(rig.recorder.isMicrophoneSilent, "five seconds of zeros")

        rig.inputs.current.signal = .tone(frequency: 440, amplitude: 0.3)
        rig.pump(0.2)
        rig.recorder.updateLevels()
        XCTAssertFalse(rig.recorder.isMicrophoneSilent, "it clears as soon as it hears")

        // Something, but nothing a person could have said: about −103 dBFS.
        rig.inputs.current.signal = .tone(frequency: 440, amplitude: 0.000_01)
        rig.pump(19.5)
        rig.recorder.updateLevels()
        XCTAssertFalse(rig.recorder.isMicrophoneSilent)
        rig.pump(0.6)
        rig.recorder.updateLevels()
        XCTAssertTrue(rig.recorder.isMicrophoneSilent, "twenty seconds under −90 dBFS")

        // A long pause, then the microphone again: not silent for the time it was paused.
        rig.inputs.current.signal = .tone(frequency: 440, amplitude: 0.3)
        rig.pump(0.2)
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("paused") { rig.recorder.isPaused }
        rig.clock.advance(60)
        rig.session.send(.interruptionEnded(shouldResume: true))
        try await waitUntil("resumed") { rig.recorder.state == .recording }
        rig.pump(0.3)
        rig.recorder.updateLevels()
        XCTAssertFalse(rig.recorder.isMicrophoneSilent)
        _ = await rig.recorder.stop()
    }

    // MARK: Helpers

    /// A file's AAC packets, as they're stored.
    static func packets(of url: URL) async throws -> [Data] {
        let reader = try await PacketReader(url: url, matching: nil)
        var packets: [Data] = []
        while let run = try reader.next() { packets += run.packets }
        return packets
    }

    /// Where `part` starts in `whole`, as one unbroken run.
    static func firstIndex(of part: [Data], in whole: [Data]) -> Int? {
        guard let head = part.first, part.count <= whole.count else { return nil }
        return (0...(whole.count - part.count)).first { whole[$0] == head && Array(whole[$0..<$0 + part.count]) == part }
    }
}

@MainActor
private final class ResetStopProbe {
    var recorder: PhoneRecorder!
    var recording: PhoneRecording?
    var finished = false
}

private final class StopObservedInput: AudioInputSource {
    let input: SyntheticAudioInput
    private var stopped: (() -> Void)?
    init(input: SyntheticAudioInput, stopped: @escaping () -> Void) {
        self.input = input
        self.stopped = stopped
    }
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void,
               onEvent: @escaping @Sendable (AudioInputEvent) -> Void) throws {
        try input.start(onBuffer: onBuffer, onEvent: onEvent)
    }
    func stop() {
        input.stop()
        let callback = stopped
        stopped = nil
        callback?()
    }
}
