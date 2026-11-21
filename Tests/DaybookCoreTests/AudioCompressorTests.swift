import AVFoundation
import DaybookCore
import DaybookTestSupport
import XCTest

/// Making and checking the AAC copy that replaces an older recording, on synthetic audio: every check a copy must pass,
/// and each way a copy is refused.
final class AudioCompressorTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = makeTemporaryFolder("DaybookCompressor")
    }

    /// Speech-like sound: voiced bursts with pauses between them, a gliding pitch with harmonics, and a little noise.
    private func samples(rate: Double, seconds: Double, seed: UInt32 = 1, pitch: Double = 140) -> [Float] {
        var state = seed
        return (0..<Int(rate * seconds)).map { index in
            let t = Double(index) / rate
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = (Double(state) / Double(UInt32.max) - 0.5) * 0.01
            let burst = sin(2 * .pi * 1.7 * t + Double(seed)) > -0.2 ? 1.0 : 0.0
            let f0 = pitch + 30 * sin(2 * .pi * 0.3 * t)
            var voiced = 0.0
            for harmonic in 1...6 { voiced += sin(2 * .pi * f0 * Double(harmonic) * t) / Double(harmonic) }
            return Float(0.15 * burst * voiced * (0.6 + 0.4 * sin(2 * .pi * 4 * t)) + noise)
        }
    }

    @discardableResult
    private func write(_ name: String, rate: Double, channels: [[Float]], settings: [String: Any]? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let format = channels.count > 2
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false,
                            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_3_0_A)!)
            : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels.count), interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: channel.count) }
        }
        try file.write(from: buffer)
        return url
    }

    private func roundTrip(_ source: URL) throws -> (AudioCompressor.Plan, AudioCompressor.Verification, URL) {
        let plan = try AudioCompressor.plan(for: source)
        let copy = folder.appendingPathComponent(UUID().uuidString + ".m4a")
        try AudioCompressor.encode(source, to: copy, plan: plan)
        return (plan, try AudioCompressor.verify(source: source, copy: copy, plan: plan), copy)
    }

    // MARK: Copies that pass

    func testBehaviorEachRecordingLayoutEncodesAndVerifies() throws {
        let cases: [(String, Double, Int, Int, Bool)] = [
            ("mic-48k.caf", 48_000, 1, 64_000, false), ("mic-44k.caf", 44_100, 1, 64_000, false),
            ("echo-16k.caf", 16_000, 1, 32_000, false), ("soundcore-16k.wav", 16_000, 1, 32_000, false),
        ]
        for (name, rate, channels, bitRate, downmixes) in cases {
            let settings: [String: Any]? = name.hasSuffix(".wav")
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                   AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
                : nil
            let source = try write(name, rate: rate, channels: [samples(rate: rate, seconds: 20)], settings: settings)
            XCTAssertEqual(AudioCompressor.storage(of: source), .lossless, name)
            let (plan, verification, copy) = try roundTrip(source)
            XCTAssertEqual(plan, AudioCompressor.Plan(sampleRate: rate, channels: channels, bitRate: bitRate, downmixes: downmixes), name)
            XCTAssertEqual(verification.frames, try AVAudioFile(forReading: source).length, name)
            XCTAssertEqual(verification.lag, 0, name)
            XCTAssertGreaterThan(try XCTUnwrap(verification.envelopeCorrelation), 0.99, name)
            XCTAssertEqual(AudioCompressor.storage(of: copy), .lossy, "a copy is never compressed again")
        }
    }

    func testBehaviorStereoWithTheSameSoundInBothChannelsBecomesMono() throws {
        let sound = samples(rate: 48_000, seconds: 15)
        let source = try write("call.caf", rate: 48_000, channels: [sound, sound])
        let similarity = try AudioCompressor.channelSimilarity(of: source)
        XCTAssertEqual(similarity.correlation, 1, accuracy: 1e-9)
        let (plan, verification, _) = try roundTrip(source)
        XCTAssertEqual(plan, AudioCompressor.Plan(sampleRate: 48_000, channels: 1, bitRate: 64_000, downmixes: true))
        XCTAssertEqual(verification.lag, 0)
    }

    func testBehaviorStereoWithDifferentChannelsStaysStereo() throws {
        let source = try write("call-two.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 15, seed: 1),
                                                                         samples(rate: 48_000, seconds: 15, seed: 9, pitch: 220)])
        XCTAssertLessThan(try AudioCompressor.channelSimilarity(of: source).correlation, AudioCompressor.sameChannelsCorrelation)
        let (plan, verification, _) = try roundTrip(source)
        XCTAssertEqual(plan, AudioCompressor.Plan(sampleRate: 48_000, channels: 2, bitRate: 96_000, downmixes: false))
        XCTAssertEqual(verification.lag, 0)
    }

    func testBehaviorSilentRecordingNeedsOnlyASilentCopy() throws {
        let source = try write("silent.caf", rate: 48_000, channels: [[Float](repeating: 0, count: 48_000 * 10)])
        let (_, verification, _) = try roundTrip(source)
        XCTAssertNil(verification.lag)
    }

    // MARK: Copies and recordings refused

    func testBehaviorLossyAndUnusualRecordingsAreNotCompressed() throws {
        let source = try write("speech.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 6)])
        let aac = folder.appendingPathComponent("phone.m4a")
        try AudioCompressor.encode(source, to: aac, plan: .init(sampleRate: 48_000, channels: 1, bitRate: 64_000, downmixes: false))
        XCTAssertEqual(AudioCompressor.storage(of: aac), .lossy)
        let odd = try write("odd.caf", rate: 22_050, channels: [samples(rate: 22_050, seconds: 6)])
        XCTAssertEqual(AudioCompressor.storage(of: odd), .unsupported)
        let three = try write("three.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 3), samples(rate: 48_000, seconds: 3),
                                                                     samples(rate: 48_000, seconds: 3)])
        XCTAssertEqual(AudioCompressor.storage(of: three), .unsupported)
        let text = folder.appendingPathComponent("notes.caf")
        try Data("not audio".utf8).write(to: text)
        XCTAssertEqual(AudioCompressor.storage(of: text), .unsupported)
    }

    private func refusal(source: URL, copy: URL) -> AudioCompressor.Refusal? {
        do {
            try AudioCompressor.verify(source: source, copy: copy, plan: try AudioCompressor.plan(for: source))
            return nil
        } catch let refusal as AudioCompressor.Refusal { return refusal } catch { XCTFail("\(error)"); return nil }
    }

    private func encoded(_ channel: [Float], rate: Double = 48_000, name: String) throws -> URL {
        let pcm = try write(name + ".caf", rate: rate, channels: [channel])
        let copy = folder.appendingPathComponent(name + ".m4a")
        try AudioCompressor.encode(pcm, to: copy, plan: .init(sampleRate: rate, channels: 1, bitRate: rate == 16_000 ? 32_000 : 64_000, downmixes: false))
        return copy
    }

    func testBehaviorEachDamagedCopyIsRefused() throws {
        let sound = samples(rate: 48_000, seconds: 20)
        let source = try write("source.caf", rate: 48_000, channels: [sound])
        // Truncated: a frame short.
        guard case .frameCount = refusal(source: source, copy: try encoded(Array(sound.dropLast()), name: "short")) else { return XCTFail("truncated") }
        // Silent where the recording isn't.
        var silenced = sound
        for index in 48_000 * 5..<48_000 * 12 { silenced[index] = 0 }
        guard case .quiet = refusal(source: source, copy: try encoded(silenced, name: "silenced")) else { return XCTFail("silenced") }
        // Another recording of the same length.
        guard case .some = refusal(source: source, copy: try encoded(samples(rate: 48_000, seconds: 20, seed: 7, pitch: 300), name: "other")) else {
            return XCTFail("another recording")
        }
        // Shifted by 120 ms, the same length.
        let shift = 48_000 * 12 / 100
        let shifted = [Float](repeating: 0, count: shift) + sound.dropLast(shift)
        let shiftedRefusal = refusal(source: source, copy: try encoded(shifted, name: "shifted"))
        XCTAssertNotNil(shiftedRefusal, "a shifted copy")
        // Not AAC.
        guard case .wrongFormat = refusal(source: source, copy: source) else { return XCTFail("not AAC") }
        // A copy at another rate.
        guard case .wrongFormat = refusal(source: source, copy: try encoded(samples(rate: 16_000, seconds: 20), rate: 16_000, name: "rate")) else {
            return XCTFail("another rate")
        }
    }

    /// Continuous sound whose loudness swings between half and full at 3 Hz, so it's never quiet anywhere.
    private func swinging(rate: Double, seconds: Double, phase: Double = 0, delay: Double = 0) -> [Float] {
        (0..<Int(rate * seconds)).map { index in
            let t = max(0, Double(index) / rate - delay)
            let envelope = 0.75 + 0.25 * (sin(2 * .pi * 3 * t + phase) > 0 ? 1.0 : -1.0)
            var voiced = 0.0
            for harmonic in 1...5 { voiced += sin(2 * .pi * 150 * Double(harmonic) * t) / Double(harmonic) }
            return Float(0.12 * envelope * voiced)
        }
    }

    func testBehaviorCopyWhoseLoudnessDoesNotFollowIsRefused() throws {
        let source = try write("swing.caf", rate: 48_000, channels: [swinging(rate: 48_000, seconds: 20)])
        let opposite = try encoded(swinging(rate: 48_000, seconds: 20, phase: .pi), name: "opposite")
        guard case .envelope = refusal(source: source, copy: opposite) else { return XCTFail("loudness the other way round") }
    }

    /// Slowly swelling sound whose pitch steps every 0.3 s: its onsets are in the pitch, not the loudness.
    private func stepping(rate: Double, seconds: Double, delay: Double = 0) -> [Float] {
        let pitches = [150.0, 210, 180, 260, 140, 230, 195, 170]
        return (0..<Int(rate * seconds)).map { index in
            let t = max(0, Double(index) / rate - delay)
            let pitch = pitches[Int(t / 0.3) % pitches.count]
            var voiced = 0.0
            for harmonic in 1...5 { voiced += sin(2 * .pi * pitch * Double(harmonic) * t) / Double(harmonic) }
            return Float(0.12 * (0.75 + 0.25 * sin(2 * .pi * 0.5 * t)) * voiced)
        }
    }

    func testBehaviorCopyOffsetByAFewHundredthsIsRefused() throws {
        let source = try write("steps.caf", rate: 48_000, channels: [stepping(rate: 48_000, seconds: 20)])
        let late = try encoded(stepping(rate: 48_000, seconds: 20, delay: 0.04), name: "late")
        let found = refusal(source: source, copy: late)
        guard case .lag = found else { return XCTFail("40 ms late: \(String(describing: found))") }
    }

    func testBehaviorPrepareCopyRefusesChangedBytesAndLeavesNothing() async throws {
        let source = try write("source.caf", rate: 16_000, channels: [samples(rate: 16_000, seconds: 8)])
        let digest = try AudioDigest.sha256(fileURL: source)
        do {
            _ = try await AudioCompressor.prepareCopy(of: source, expectedSHA256: String(repeating: "0", count: 64), in: folder)
            XCTFail("changed bytes")
        } catch is AudioCompressor.SourceChanged {}
        XCTAssertFalse(try hiddenCopies())
        let prepared = try await AudioCompressor.prepareCopy(of: source, expectedSHA256: digest, in: folder)
        XCTAssertEqual(prepared.sha256, try AudioDigest.sha256(fileURL: prepared.url))
        XCTAssertTrue(prepared.url.lastPathComponent.hasPrefix(RecordingCompression.temporaryPrefix))
        XCTAssertLessThan(prepared.size * 5, prepared.sourceSize)
        XCTAssertEqual(try AudioDigest.sha256(fileURL: source), digest, "the recording is only read")
    }

    func testBehaviorCancelledCopyLeavesNothing() async throws {
        let source = try write("long.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 120)])
        let digest = try AudioDigest.sha256(fileURL: source)
        let task = Task { try await AudioCompressor.prepareCopy(of: source, expectedSHA256: digest, in: folder) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError {}
        XCTAssertFalse(try hiddenCopies())
    }

    private func hiddenCopies() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(RecordingCompression.temporaryPrefix) }
    }

    /// Sizes per hour, measured on synthetic audio (docs/capture.md): printed, and bounded loosely.
    func testBehaviorCopiesAreAboutTheirBitRate() throws {
        let source = try write("hour-sample.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 60)])
        let (_, _, copy) = try roundTrip(source)
        let bytes = Double(try XCTUnwrap(copy.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        let perHour = bytes * 60 / 1_000_000
        XCTAssertLessThan(perHour, 40, "about 29 MB an hour at 64 kbit/s")
    }
}
