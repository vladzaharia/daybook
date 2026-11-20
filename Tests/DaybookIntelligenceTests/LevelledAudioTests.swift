import AVFoundation
import DaybookCore
import DaybookKit
import DaybookTestSupport
import FluidAudio
import Foundation
import XCTest
@testable import DaybookIntelligence

/// What the speech models hear of a recording (`LevelledAudio`): a quiet recording raised in a 16 kHz mono copy timed as
/// the readers time the original, made only with room for it and under a WAV file's size, with the recording's protection
/// class, removed when the run ends however it ends; the stored file only read; the gain recorded with the run. Synthetic speech-like sound only; the models are faked.
final class LevelledAudioTests: XCTestCase {
    /// A 32-bit float CAF: `samples` in the first channel, at half level in a second when `stereo`.
    private func recording(_ samples: [Float], rate: Double, stereo: Bool = false, in folder: URL, name: String = "a.caf") throws -> URL {
        let url = folder.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: stereo ? 2 : 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            buffer.floatChannelData![0][index] = samples[index]
            if stereo { buffer.floatChannelData![1][index] = samples[index] / 2 }
        }
        try file.write(from: buffer)
        return url
    }

    /// Every channel of `url`, its rate, and its length.
    private func contents(_ url: URL) throws -> (channels: [[Float]], rate: Double, length: Int64) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
        return (channels, file.processingFormat.sampleRate, file.length)
    }

    /// Every file left in this run's processing folder under `base`, at any depth.
    private func copies(in base: URL) -> [URL] {
        let folder = ProcessingScratch.root(in: base).appendingPathComponent(String(getpid()))
        let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        return found.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// The folders made for copies in this run's processing folder under `base`.
    private func copyFolders(in base: URL) -> [URL] {
        let folder = ProcessingScratch.root(in: base).appendingPathComponent(String(getpid()))
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// An AAC recording at 48 kHz, mono, as the iPhone records.
    private func aacRecording(_ samples: [Float], in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("iphone.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
        return url
    }

    /// The 16 kHz mono rendering the readers make of `url` (`MonoAudioReader`, as Nemotron 3 reads).
    private func rendering(_ url: URL) throws -> [Float] {
        var samples: [Float] = []
        try MonoAudioReader.read(url: url) { samples += $0 }
        return samples
    }

    /// The largest difference between two renderings of the same length.
    private func largestDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    /// One step of 16-bit PCM, as a reader turns it into a float.
    private let step: Float = 1 / 32_768

    /// The copy made of `original` against what each reader would have read of the original: the rendering's samples
    /// times the gain, its length, and its duration within one 16 kHz sample.
    private func checkTimedAsTheReaders(_ original: URL, _ levelled: LevelledAudio, _ name: String) throws {
        let adjustment = try XCTUnwrap(levelled.adjustment, name)
        let mono = try rendering(original)
        var meter = SpeechLevel.Meter(sampleRate: 16_000)
        meter.add(mono)
        XCTAssertEqual(adjustment, SpeechLevel.adjustment(for: meter.measurement()), "\(name): measured on the rendering the models hear")
        XCTAssertGreaterThan(adjustment.gain, 20, "\(name): speech under −50 dBFS raised toward −23")
        let copy = try XCTUnwrap(levelled.copy, name)
        XCTAssertEqual(levelled.url, copy)
        XCTAssertEqual(copy.pathExtension, "wav")

        // 16 kHz mono 16-bit: a sixth of a 48 kHz stereo float original, a third of a float copy at 16 kHz.
        let file = try AVAudioFile(forReading: copy)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        let source = try AVAudioFile(forReading: original)
        let duration = Double(source.length) / source.processingFormat.sampleRate
        let raised = try contents(copy)
        XCTAssertEqual(Double(raised.length), Double(mono.count), "\(name): the rendering's length, sample for sample")
        XCTAssertEqual(Double(raised.length) / 16_000, duration, accuracy: 1 / 16_000, "\(name): the duration readers time words and turns against")
        XCTAssertEqual(try MonoAudioReader.describe(copy).duration, try MonoAudioReader.describe(original).duration, accuracy: 1 / 16_000)
        XCTAssertLessThanOrEqual(largestDifference(raised.channels[0], mono.map { $0 * adjustment.factor }), step,
                                 "\(name): the gain times the rendering Nemotron 3 (and Parakeet and Apple Speech for several channels) read")
        XCTAssertLessThan(raised.channels[0].map(abs).max() ?? 1, Float(pow(10, -1.0 / 20)) + step, "\(name): the peak at −1 dBFS: nothing clips")

        // The readers that convert slab by slab (WhisperKit, Sortformer, voice profiles) render the whole file the same way.
        let slab = try AudioSlabReader.samples(url: original, from: 0, to: duration)
        XCTAssertEqual(slab.count, mono.count, name)
        XCTAssertLessThanOrEqual(largestDifference(raised.channels[0], slab.map { $0 * adjustment.factor }), step, name)
        // FluidAudio (Parakeet over 30 s, Community-1) maps the copy as it is, without converting it again.
        let mapped = try AudioSourceFactory().makeDiskBackedSource(from: copy, targetSampleRate: 16_000).source
        defer { mapped.cleanup() }
        XCTAssertEqual(mapped.sampleCount, raised.channels[0].count)
        var samples = [Float](repeating: 0, count: mapped.sampleCount)
        try samples.withUnsafeMutableBufferPointer { try mapped.copySamples(into: $0.baseAddress!, offset: 0, count: $0.count) }
        XCTAssertTrue(samples == raised.channels[0], name)
        // FluidAudio's own conversion of the original (another filter; a stereo file's first channel) is timed the same.
        let converted = try AudioSourceFactory().makeDiskBackedSource(from: original, targetSampleRate: 16_000).source
        defer { converted.cleanup() }
        XCTAssertEqual(Double(converted.sampleCount), Double(mono.count), accuracy: 1, name)
    }

    // MARK: The copy

    func testBehaviorQuietSpeechIsRaisedInA16kHzMonoCopyTimedAsTheReadersTimeTheOriginal() throws {
        let folder = makeTemporaryFolder(), scratch = makeTemporaryFolder()
        // The Mac's computer audio (48 kHz stereo float) and an iPhone's recording (48 kHz mono AAC).
        let mac = try recording(SyntheticAudio.syllables(level: -50, seconds: 10, rate: 48_000, floor: -85), rate: 48_000, stereo: true, in: folder)
        let phone = try aacRecording(SyntheticAudio.syllables(level: -52, seconds: 10, rate: 48_000, floor: -85), in: folder)
        for (name, url) in [("48 kHz stereo float", mac), ("48 kHz mono AAC", phone)] {
            let stored = try Data(contentsOf: url)
            let levelled = try LevelledAudio.prepare(url, in: scratch)
            try checkTimedAsTheReaders(url, levelled, name)
            let copy = try XCTUnwrap(levelled.copy)
            XCTAssertEqual(copies(in: scratch).map { $0.resolvingSymlinksInPath().path }, [copy.resolvingSymlinksInPath().path],
                           "\(name): made where processing keeps its copies")
            XCTAssertEqual(try Data(contentsOf: url), stored, "\(name): the stored recording is only read")
            levelled.remove()
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
            XCTAssertTrue(copyFolders(in: scratch).isEmpty, "\(name): the copy's folder goes with it")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testBehaviorWithoutRoomForTheCopyTheRecordingIsHeardAsStoredWithItsLevelRecorded() throws {
        let folder = makeTemporaryFolder(), scratch = makeTemporaryFolder()
        let url = try recording(SyntheticAudio.syllables(level: -50, seconds: 4, floor: -85), rate: 16_000, in: folder)
        var asked: [URL] = []
        let short = try LevelledAudio.prepare(url, in: scratch) { asked.append($0); return LevelledAudio.spareBytes + 100_000 }
        XCTAssertEqual(short.url, url)
        XCTAssertNil(short.copy)
        let recorded = try XCTUnwrap(short.adjustment)
        XCTAssertEqual(recorded.gain, 0, "the models heard it as stored")
        XCTAssertEqual(try XCTUnwrap(recorded.speechLevel), -50, accuracy: 0.3, "and its level and peak are recorded")
        XCTAssertNotNil(recorded.peak)
        XCTAssertTrue(copies(in: scratch).isEmpty)
        XCTAssertEqual(asked.map(\.path), [ProcessingScratch.root(in: scratch).path], "the room asked for is where the copy goes")

        // 4 s is 128 kB at 16 kHz in 16 bits: with that and the spare room free, it's made; when the system doesn't say, too.
        for free in [LevelledAudio.spareBytes + 200_000, nil] {
            let made = try LevelledAudio.prepare(url, in: scratch) { _ in free }
            XCTAssertNotNil(made.copy, "\(String(describing: free)) bytes free")
            made.remove()
        }
    }

    func testBehaviorACopyTooLongForAWAVFileIsNotMade() {
        // 34 hours and more at 16 kHz in 16 bits is past what a WAV file holds (4,294,967,295 bytes) less its header room.
        XCTAssertEqual(LevelledAudio.declined(frames: 2_147_483_647, free: nil), .tooLong)
        XCTAssertEqual(LevelledAudio.declined(frames: 2_000_000_000, free: nil), .tooLong)
        XCTAssertNil(LevelledAudio.declined(frames: 1_999_000_000, free: nil), "just under: made")
        XCTAssertEqual(LevelledAudio.declined(frames: 2_100_000_000, free: Int64.max), .tooLong, "however much room there is")
        XCTAssertEqual(LevelledAudio.declined(frames: 16_000 * 3_600, free: 1_000_000_000), .noRoom, "an hour, 115 MB, with less than 1 GB spare")
        XCTAssertNil(LevelledAudio.declined(frames: 16_000 * 3_600, free: 2_000_000_000))
    }

    func testBehaviorTheCopyKeepsTheRecordingsProtectionClass() throws {
        let folder = makeTemporaryFolder(), scratch = makeTemporaryFolder()
        let url = try recording(SyntheticAudio.syllables(level: -50, seconds: 2, rate: 48_000, floor: -85), rate: 48_000, stereo: true, in: folder)
        // Where the file system keeps classes (a Mac with FileVault, the simulators, every iPhone; `FileProtectionClasses`).
        try XCTSkipUnless(FileProtectionClasses.areKept, "This file system doesn't keep protection classes.")
        for wanted in [FileProtectionType.completeUnlessOpen, .completeUntilFirstUserAuthentication] {
            try FileManager.default.setAttributes([.protectionKey: wanted], ofItemAtPath: url.path)
            XCTAssertEqual(LevelledAudio.protection(of: url), wanted)
            let levelled = try LevelledAudio.prepare(url, in: scratch)
            let copy = try XCTUnwrap(levelled.copy)
            XCTAssertEqual(FileProtectionClasses.of(copy), wanted, "a copy of a \(wanted.rawValue) recording")
            XCTAssertEqual(FileProtectionClasses.of(copy.deletingLastPathComponent()), wanted, "made in a folder of that class")
            XCTAssertEqual(copy.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path,
                           ProcessingScratch.root(in: scratch).appendingPathComponent(String(getpid())).resolvingSymlinksInPath().path)
            levelled.remove()
            XCTAssertTrue(copyFolders(in: scratch).isEmpty)
        }
        // A class that can't be read leaves the folder as this run's is: what's made in it has the class the run's own
        // copies have (Parakeet's mono copy).
        XCTAssertNil(LevelledAudio.protection(of: folder.appendingPathComponent("missing.caf")))
        let plain = try ProcessingScratch.folder(protection: nil, in: scratch).appendingPathComponent("a.caf")
        try MonoAudioReader.writeMonoCopy(of: url, to: plain)
        let mono = try ProcessingScratch.file(extension: "caf", in: scratch)
        try MonoAudioReader.writeMonoCopy(of: url, to: mono)
        XCTAssertNotNil(FileProtectionClasses.of(plain))
        XCTAssertEqual(FileProtectionClasses.of(plain), FileProtectionClasses.of(mono))
    }

    func testBehaviorACancelledWriteLeavesNoPartialCopy() async throws {
        let folder = makeTemporaryFolder(), scratch = makeTemporaryFolder()
        let url = try recording(SyntheticAudio.syllables(level: -50, seconds: 10, floor: -85), rate: 16_000, in: folder)
        // Cancelled as the copy is about to be written (the room is asked for last): the WAV file is made, then the
        // first block read sees the cancellation.
        let task = Task { () throws -> LevelledAudio in
            try LevelledAudio.prepare(url, in: scratch) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return nil
            }
        }
        do {
            let levelled = try await task.value
            levelled.remove()
            XCTFail("prepared after being cancelled")
        } catch is CancellationError {}
        XCTAssertTrue(copies(in: scratch).isEmpty, "no partial copy")
        XCTAssertTrue(copyFolders(in: scratch).isEmpty, "nor its folder")
    }

    func testBehaviorNormalSpeechSilenceAndUnreadableAudioAreReadAsStored() throws {
        let folder = makeTemporaryFolder(), scratch = makeTemporaryFolder()
        let normal = try recording(SyntheticAudio.syllables(level: -20, seconds: 4, floor: -70), rate: 16_000, in: folder, name: "normal.caf")
        let levelled = try LevelledAudio.prepare(normal, in: scratch)
        XCTAssertEqual(levelled.url, normal)
        XCTAssertNil(levelled.copy)
        XCTAssertEqual(levelled.adjustment?.gain, 0)
        XCTAssertEqual(try XCTUnwrap(levelled.adjustment?.speechLevel), -20, accuracy: 0.3)

        let silent = try recording([Float](repeating: 0, count: 64_000), rate: 16_000, in: folder, name: "silent.caf")
        XCTAssertEqual(try LevelledAudio.prepare(silent, in: scratch).adjustment, LevelAdjustment(speechLevel: nil, peak: nil, gain: 0))

        let missing = folder.appendingPathComponent("missing.caf")
        let unread = try LevelledAudio.prepare(missing, in: scratch)
        XCTAssertEqual(unread.url, missing)
        XCTAssertNil(unread.adjustment, "levels never stop a recording from being processed")
        XCTAssertTrue(copies(in: scratch).isEmpty)
    }

    func testBehaviorTheSameRecordingGetsTheSameGainEachTime() throws {
        let folder = makeTemporaryFolder(), scratch = makeTemporaryFolder()
        let url = try recording(SyntheticAudio.syllables(level: -47, seconds: 3, floor: -65, seed: 9), rate: 16_000, in: folder)
        let first = try LevelledAudio.prepare(url, in: scratch), second = try LevelledAudio.prepare(url, in: scratch)
        defer { first.remove(); second.remove() }
        XCTAssertEqual(first.adjustment, second.adjustment)
        XCTAssertEqual(try contents(XCTUnwrap(first.copy)).channels, try contents(XCTUnwrap(second.copy)).channels)
    }

    // MARK: Through the engine

    /// Models that note which file they were given, and can fail.
    private final class Heard: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [String: URL] = [:]
        var failure: (any Error)?
        var urls: [String: URL] { lock.withLock { _urls } }
        private func heard(_ step: String, _ url: URL) {
            lock.withLock { _urls[step] = url }
        }

        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            heard("transcribe", url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the copy is there while the model reads it")
            if let failure { throw failure }
            let words = [RecognizedWord(text: " Ship", start: 0, end: 0.4, confidence: 0.9)]
            return RecognitionResult(segments: [RecognizedSegment(start: 0, end: 0.4, text: " Ship", confidence: 0.9, words: words)],
                                     language: "en", duration: 4)
        }

        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            heard("diarize", url)
            if let failure { throw failure }
            return SpeakerAnalysis(turns: [SpeakerTurn(speakerID: "0", start: 0, end: 4, confidence: 1)], embeddings: ["0": [1, 0]],
                                   embeddingModelID: "community-1", warnings: [])
        }

        func classifySound(url: URL, progress: @escaping IntelligenceProgressHandler) async throws -> BackgroundAudioAnalysis? {
            heard("classifySound", url)
            return nil
        }

        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            throw CancellationError()
        }
    }

    private let configuration = InferenceProcessingEngine.Configuration(
        transcriptionModel: "parakeet/ultra", summaryModel: "gemma-4/e2b-4bit", detectSpeakers: true,
        speakerModel: "community-1/offline", speakerOptions: SpeakerAnalysisOptions(), fingerprint: "levels",
        speakerMatchThreshold: 0.82, speakerMatchMargin: 0.06)

    private func input(_ url: URL, mode: ProcessingRequest.Mode = .newAudio, previous: TrackTranscript? = nil) -> TrackProcessingInput {
        let track = RecordingTrack(source: .systemAudio, relativePath: "Originals/call.caf", fileName: "call.caf", duration: 4, offset: 0, sha256: "c")
        return TrackProcessingInput(meetingID: UUID(), track: track, audioURL: url, mode: mode, previousTranscript: previous)
    }

    func testBehaviorTheModelsHearTheRaisedCopyAndTheRunRecordsTheGain() async throws {
        let url = try recording(SyntheticAudio.syllables(level: -48, seconds: 4, floor: -80), rate: 16_000, in: makeTemporaryFolder())
        let stored = try Data(contentsOf: url)
        let inference = Heard()
        let output = try await InferenceProcessingEngine(inference: inference, configuration: configuration).transcribe(input(url), progress: { _ in })

        let heard = try XCTUnwrap(inference.urls["transcribe"])
        XCTAssertNotEqual(heard, url, "the transcriber hears the raised copy")
        XCTAssertEqual(inference.urls["diarize"], heard, "and so do the speaker models")
        XCTAssertEqual(inference.urls["classifySound"], url, "background audio is measured on the recording as stored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: heard.path), "the copy is gone when the run ends")
        XCTAssertEqual(try Data(contentsOf: url), stored)

        let adjustment = try XCTUnwrap(output.transcript.processingSettings?.levelAdjustment)
        XCTAssertEqual(adjustment.gain, 25, accuracy: 0.3)
        XCTAssertEqual(output.speakers.first?.analysisSettings?.levelAdjustment, adjustment)
        XCTAssertEqual(output.transcript.segments.map(\.text), ["Ship"], "timings and words as the models gave them")
    }

    func testBehaviorTheCopyIsRemovedWhenTheRunFailsOrIsCancelled() async throws {
        let url = try recording(SyntheticAudio.syllables(level: -50, seconds: 4, floor: -80), rate: 16_000, in: makeTemporaryFolder())
        struct Failure: Error {}
        for failure in [Failure() as any Error, CancellationError()] {
            let inference = Heard()
            inference.failure = failure
            do {
                _ = try await InferenceProcessingEngine(inference: inference, configuration: configuration).transcribe(input(url), progress: { _ in })
                XCTFail("the run fails with its model")
            } catch {}
            let heard = try XCTUnwrap(inference.urls["transcribe"])
            XCTAssertNotEqual(heard, url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: heard.path), "removed after \(failure)")
        }
    }

    func testBehaviorIdentifyingSpeakersAgainRaisesTheirAudioAndKeepsTheWordsOwnLevel() async throws {
        let url = try recording(SyntheticAudio.syllables(level: -48, seconds: 4, floor: -80), rate: 16_000, in: makeTemporaryFolder())
        let earlier = LevelAdjustment(speechLevel: -48, peak: -40, gain: 0)
        let previous = TrackTranscript(trackID: UUID(), segments: [], language: "en", modelID: "parakeet/ultra",
                                       processingSettings: ProcessingSettings(modelID: "parakeet/ultra", levelAdjustment: earlier),
                                       words: [TranscriptWord(text: " Hello", start: 0, end: 0.5, confidence: 0.9)])
        let inference = Heard()
        let output = try await InferenceProcessingEngine(inference: inference, configuration: configuration)
            .transcribe(input(url, mode: .speakerRefresh, previous: previous), progress: { _ in })
        XCTAssertNil(inference.urls["transcribe"])
        let heard = try XCTUnwrap(inference.urls["diarize"])
        XCTAssertNotEqual(heard, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heard.path))
        XCTAssertEqual(output.transcript.processingSettings?.levelAdjustment, earlier, "the words were heard as that run heard them")
        XCTAssertEqual(try XCTUnwrap(output.speakers.first?.analysisSettings?.levelAdjustment?.gain), 25, accuracy: 0.3)
    }
}
