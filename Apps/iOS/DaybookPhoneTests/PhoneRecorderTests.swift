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
