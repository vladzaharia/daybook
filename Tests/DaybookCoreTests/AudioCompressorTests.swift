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
            ("echo-16k.caf", 16_000, 1, 48_000, false), ("soundcore-16k.wav", 16_000, 1, 48_000, false),
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
        XCTAssertEqual(try AudioCompressor.channelDifference(of: source), 0)
        let (plan, verification, _) = try roundTrip(source)
        XCTAssertEqual(plan, AudioCompressor.Plan(sampleRate: 48_000, channels: 1, bitRate: 64_000, downmixes: true))
        XCTAssertEqual(verification.lag, 0)
    }

    func testBehaviorStereoWithDifferentChannelsStaysStereo() throws {
        let source = try write("call-two.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 15, seed: 1),
                                                                         samples(rate: 48_000, seconds: 15, seed: 9, pitch: 220)])
        XCTAssertGreaterThan(try AudioCompressor.channelDifference(of: source), AudioCompressor.sameChannelsTolerance)
        let (plan, verification, _) = try roundTrip(source)
        XCTAssertEqual(plan, AudioCompressor.Plan(sampleRate: 48_000, channels: 2, bitRate: 96_000, downmixes: false))
        XCTAssertEqual(verification.lag, 0)
    }

    /// Two talkers hard-panned left and right (a call recorded with each side on its own channel).
    private func panned(seconds: Double) -> (left: [Float], right: [Float]) {
        let a = samples(rate: 48_000, seconds: seconds, seed: 1), b = samples(rate: 48_000, seconds: seconds, seed: 5, pitch: 230)
        var left = a, right = b
        // Taking turns: A in the first and third quarters, B in the second and fourth.
        for index in left.indices {
            let quarter = Int(Double(index) / Double(left.count) * 4)
            if quarter % 2 == 0 { right[index] = 0 } else { left[index] = 0 }
        }
        return (left, right)
    }

    private func rms(_ url: URL, from start: Double, to end: Double) throws -> Double {
        let values = try SyntheticAudio.read(url)
        let rate = try AVAudioFile(forReading: url).processingFormat.sampleRate
        let slice = values[Int(start * rate)..<min(values.count, Int(end * rate))]
        return 10 * log10(max(slice.reduce(0) { $0 + Double($1 * $1) } / Double(max(slice.count, 1)), 1e-16))
    }

    func testBehaviorTalkersPannedApartBothSurvive() throws {
        let (left, right) = panned(seconds: 16)
        let source = try write("panned.caf", rate: 48_000, channels: [left, right])
        // Kept as two channels: they aren't the same samples.
        XCTAssertEqual(try AudioCompressor.shape(of: source), .wideStereo)
        let (plan, _, _) = try roundTrip(source)
        XCTAssertEqual(plan.channels, 2)
        // Even averaged into one, both talkers are in it (an average, not the left channel alone).
        let mono = folder.appendingPathComponent("panned-mono.m4a")
        try AudioCompressor.encode(source, to: mono, plan: .init(sampleRate: 48_000, channels: 1, bitRate: 64_000, downmixes: true))
        XCTAssertGreaterThan(try rms(mono, from: 1, to: 3), -40, "the left talker")
        XCTAssertGreaterThan(try rms(mono, from: 5, to: 7), -40, "the right talker")
    }

    func testBehaviorADroppedOrSwappedChannelIsRefused() throws {
        let (left, right) = panned(seconds: 16)
        let source = try write("panned-source.caf", rate: 48_000, channels: [left, right])
        let stereo = AudioCompressor.Plan(sampleRate: 48_000, channels: 2, bitRate: 96_000, downmixes: false)
        for (name, channels) in [("dropped", [left, [Float](repeating: 0, count: right.count)]), ("swapped", [right, left])] {
            let pcm = try write("\(name).caf", rate: 48_000, channels: channels)
            let copy = folder.appendingPathComponent("\(name).m4a")
            try AudioCompressor.encode(pcm, to: copy, plan: stereo)
            XCTAssertThrowsError(try AudioCompressor.verify(source: source, copy: copy, plan: stereo), name)
        }
    }

    func testBehaviorChannelsAlikeButNotIdenticalStayStereo() throws {
        // Correlated above 0.99, with a small part out of phase that an average would erase.
        let sound = samples(rate: 48_000, seconds: 6), other = samples(rate: 48_000, seconds: 6, seed: 3, pitch: 310)
        let left = zip(sound, other).map { $0 + 0.02 * $1 }, right = zip(sound, other).map { $0 - 0.02 * $1 }
        let source = try write("phase.caf", rate: 48_000, channels: [left, right])
        XCTAssertEqual(try AudioCompressor.shape(of: source), .wideStereo)
    }

    func testBehaviorAFarTalkerSilencedBesideANearOneIsRefused() throws {
        // The reviewer's case, on window levels: a near talker at -12 dBFS in 8% of windows, far talkers at -46, and a
        // copy silent wherever the far talkers speak.
        let source = (0..<2_400).map { $0 % 25 < 2 ? -12.0 : -46.0 }
        let silent = source.map { $0 == -12 ? -12.0 : -120.0 }
        XCTAssertThrowsError(try AudioCompressor.judge(source, silent))
        // An honest copy, every window within 0.3 dB.
        var state: UInt32 = 7
        let honest = source.map { level -> Double in
            state = state &* 1_664_525 &+ 1_013_904_223
            return level + (Double(state) / Double(UInt32.max) - 0.5) * 0.6
        }
        XCTAssertNoThrow(try AudioCompressor.judge(source, honest))
    }

    func testBehaviorAQuietMinuteIsJudgedAgainstItself() throws {
        // A loud first minute, then a minute of speech at -70 dBFS: the file's bar alone would miss it.
        let loud = (0..<1_200).map { $0 % 3 == 0 ? -10.0 : -20.0 }, quiet = (0..<1_200).map { $0 % 3 == 0 ? -70.0 : -78.0 }
        let source = loud + quiet
        XCTAssertThrowsError(try AudioCompressor.judge(source, loud + quiet.map { _ in -120.0 }))
    }

    func testBehaviorAReaderThatStopsEarlyIsRefused() throws {
        // A CAF cut short: its header still declares every frame (measured), and reading it fails partway.
        let whole = try write("whole.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 10)])
        let (plan, _, copy) = try roundTrip(whole)
        var bytes = try Data(contentsOf: whole)
        bytes.removeLast(bytes.count / 3)
        let short = folder.appendingPathComponent("short.caf")
        try bytes.write(to: short)
        XCTAssertEqual(try AVAudioFile(forReading: short).length, try AVAudioFile(forReading: whole).length, "the header still says the whole length")
        func isShortRead(_ error: Error) -> Bool {
            if case .shortRead? = error as? AudioCompressor.Refusal { return true }
            return false
        }
        // Checked against a whole copy, it's refused as cut short (not passed, and not taken as a shorter recording).
        XCTAssertThrowsError(try AudioCompressor.verify(source: short, copy: copy, plan: plan)) { XCTAssertTrue(isShortRead($0), "\($0)") }
        // Encoded, it's refused, not padded out to its declared length.
        let padded = folder.appendingPathComponent("padded.m4a")
        XCTAssertThrowsError(try AudioCompressor.encode(short, to: padded, plan: plan)) { XCTAssertTrue(isShortRead($0), "\($0)") }
        // A copy cut short is refused the same way.
        var copyBytes = try Data(contentsOf: copy)
        copyBytes.removeLast(copyBytes.count / 3)
        let shortCopy = folder.appendingPathComponent("short-copy.m4a")
        try copyBytes.write(to: shortCopy)
        XCTAssertThrowsError(try AudioCompressor.verify(source: whole, copy: shortCopy, plan: plan))
    }

    func testBehaviorAudioPastAStaleHeaderIsRefusedAndMetadataChunksAreNot() async throws {
        func appending(_ name: String, to source: URL, _ bytes: Data) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try (Data(contentsOf: source) + bytes).write(to: url)
            return url
        }
        func chunk(_ type: String, _ body: Data, caf: Bool) -> Data {
            var header = Data(type.utf8)
            if caf { header += withUnsafeBytes(of: Int64(body.count).bigEndian) { Data($0) } } else {
                header += withUnsafeBytes(of: UInt32(body.count).littleEndian) { Data($0) }
            }
            return header + body + (caf || body.count % 2 == 0 ? Data() : Data([0]))
        }
        let caf = try write("written.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 3)])
        let wavSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let wav = try write("written.wav", rate: 16_000, channels: [samples(rate: 16_000, seconds: 3)], settings: wavSettings)
        XCTAssertEqual(try AudioCompressor.unaccountedBytes(caf), 0, "as AVAudioFile writes it")
        XCTAssertEqual(try AudioCompressor.unaccountedBytes(wav), 0)
        // A header never updated after a crash: audio past what it declares, which every reader skips.
        let audio = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        for source in [caf, wav] {
            let stale = try appending("stale-" + source.lastPathComponent, to: source, audio)
            XCTAssertEqual(try AVAudioFile(forReading: stale).length, try AVAudioFile(forReading: source).length, "the reader skips it")
            XCTAssertEqual(try AudioCompressor.unaccountedBytes(stale), Int64(audio.count))
            do {
                _ = try await AudioCompressor.prepareCopy(of: stale, expectedSHA256: try AudioDigest.sha256(fileURL: stale), in: folder)
                XCTFail("a stale header passed")
            } catch let refusal as AudioCompressor.Refusal {
                XCTAssertEqual(refusal, .trailingData(Int64(audio.count)))
                XCTAssertTrue(refusal.isVerdict, "the bytes won't change")
            }
        }
        // Chunks another app wrote after the data, however large, and a few stray bytes, are not audio.
        let metadata = try appending("tagged.wav", to: wav, chunk("LIST", Data(repeating: 1, count: 2_000_001), caf: false)
                                     + chunk("id3 ", Data(repeating: 2, count: 600_000), caf: false))
        XCTAssertEqual(try AudioCompressor.unaccountedBytes(metadata), 0)
        let cafInfo = try appending("tagged.caf", to: caf, chunk("info", Data(repeating: 3, count: 1_500_000), caf: true))
        XCTAssertEqual(try AudioCompressor.unaccountedBytes(cafInfo), 0)
        let stray = try appending("stray.caf", to: caf, Data(repeating: 9, count: 100))
        XCTAssertEqual(try AudioCompressor.unaccountedBytes(stray), 100)
        _ = try await AudioCompressor.prepareCopy(of: stray, expectedSHA256: try AudioDigest.sha256(fileURL: stray), in: folder)
        _ = try await AudioCompressor.prepareCopy(of: metadata, expectedSHA256: try AudioDigest.sha256(fileURL: metadata), in: folder)
        // What another try could change isn't a verdict.
        XCTAssertFalse(AudioCompressor.Refusal.shortRead(declared: 10, delivered: 5).isVerdict)
        XCTAssertFalse(AudioCompressor.Refusal.encodingFailed("disk full").isVerdict)
    }

    func testBehaviorEachPlannedRowKeepsItsRateAndALowerBitRateIsCaught() throws {
        for (rate, shape) in [(48_000.0, RecordingCompressionTable.Shape.wideMono), (44_100, .wideMono), (16_000, .narrowMono)] {
            let source = try write("row-\(Int(rate)).caf", rate: rate, channels: [samples(rate: rate, seconds: 4)])
            let (plan, _, copy) = try roundTrip(source)
            XCTAssertEqual(try AudioCompressor.shape(of: source), shape)
            XCTAssertEqual(try AVAudioFile(forReading: copy).fileFormat.sampleRate, rate, "the copy keeps the rate")
            XCTAssertEqual(plan.sampleRate, rate)
        }
        // A table edit to a bit rate the encoder takes only at a lower rate: through AVAudioFile, with the rate given, it
        // refuses the setting (measured) rather than lowering the rate, so no copy is made.
        let source = try write("low.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 4)])
        let low = AudioCompressor.Plan(sampleRate: 48_000, channels: 1, bitRate: 24_000, downmixes: false)
        let copy = folder.appendingPathComponent("low.m4a")
        if (try? AudioCompressor.encode(source, to: copy, plan: low)) != nil {
            XCTAssertEqual(try AVAudioFile(forReading: copy).fileFormat.sampleRate, 48_000, "kept the rate, or refused")
        }
        // A copy stored at a lower rate than the recording's (what other encoders pick at low bit rates: 32 kHz at 32
        // kbit/s) is refused for its format, however it sounds.
        let lowered = try write("lowered.caf", rate: 32_000, channels: [samples(rate: 32_000, seconds: 4)])
        let loweredCopy = folder.appendingPathComponent("lowered.m4a")
        try AudioCompressor.encode(lowered, to: loweredCopy, plan: .init(sampleRate: 32_000, channels: 1, bitRate: 32_000, downmixes: false))
        guard case .wrongFormat? = refusal(source: source, copy: loweredCopy) else { return XCTFail("a lowered rate passed") }
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
        guard case .dropout = refusal(source: source, copy: try encoded(silenced, name: "silenced")) else { return XCTFail("silenced") }
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

    // MARK: Sparse, quiet, and dropped-out sound

    private func silence(rate: Double, seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(rate * seconds)) }

    private func placing(_ sound: [Float], in seconds: Double, at start: Double, rate: Double) -> [Float] {
        var result = silence(rate: rate, seconds: seconds)
        let offset = Int(start * rate)
        for (index, sample) in sound.enumerated() where offset + index < result.count { result[offset + index] = sample }
        return result
    }

    func testBehaviorSparseSpeechAgainstASilentCopyIsRefused() throws {
        // Ten minutes with three seconds of speech: under 1% of the windows.
        let rate = 16_000.0
        let source = try write("sparse.caf", rate: rate, channels: [placing(samples(rate: rate, seconds: 3), in: 600, at: 300, rate: rate)])
        let found = refusal(source: source, copy: try encoded(silence(rate: rate, seconds: 600), rate: rate, name: "sparse-silent"))
        guard case .dropout = found else { return XCTFail("\(String(describing: found))") }
        // The honest copy passes.
        let (_, verification, _) = try roundTrip(source)
        XCTAssertGreaterThan(verification.audibleWindows, 0)
    }

    func testBehaviorQuietSpeechAgainstASilentCopyIsRefused() throws {
        // Speech at about -55 dBFS throughout.
        let quiet = samples(rate: 16_000, seconds: 30).map { $0 * 0.0125 }
        let source = try write("quiet.caf", rate: 16_000, channels: [quiet])
        let found = refusal(source: source, copy: try encoded(silence(rate: 16_000, seconds: 30), rate: 16_000, name: "quiet-silent"))
        guard case .dropout = found else { return XCTFail("\(String(describing: found))") }
        let (_, verification, _) = try roundTrip(source)
        XCTAssertGreaterThan(verification.audibleWindows, 0)
    }

    func testBehaviorADropoutIsRefusedWhereverItIs() throws {
        let rate = 16_000.0
        let sound = samples(rate: rate, seconds: 600)
        let source = try write("ten.caf", rate: rate, channels: [sound])
        for (name, start) in [("middle", 312.0), ("end", 597.5)] {
            var dropped = sound
            for index in Int(start * rate)..<min(dropped.count, Int((start + 2.5) * rate)) { dropped[index] = 0 }
            let found = refusal(source: source, copy: try encoded(dropped, rate: rate, name: "dropout-\(name)"))
            guard case .dropout = found else { return XCTFail("\(name): \(String(describing: found))") }
        }
    }

    func testBehaviorALocalEnvelopeFailureCantHideInALongFile() throws {
        // Twelve minutes; for 10 s in the middle the copy's loudness swings the other way. Over the whole file it still
        // correlates (about 0.97); the minute it's in doesn't.
        let rate = 16_000.0
        let sound = swinging(rate: rate, seconds: 720)
        var copy = sound
        let flipped = swinging(rate: rate, seconds: 10, phase: .pi)
        let start = Int(610 * rate)
        for index in flipped.indices { copy[start + index] = flipped[index] }
        let source = try write("long-source.caf", rate: rate, channels: [sound])
        let found = refusal(source: source, copy: try encoded(copy, rate: rate, name: "long-swing"))
        guard case .envelope = found else { return XCTFail("\(String(describing: found))") }
    }

    func testBehaviorFewAudibleWindowsAreComparedOneByOne() throws {
        // Half a second of sound in a minute: too few windows to correlate, so each is compared, and one 10 dB down
        // (short of the 12 dB quiet bar) is refused.
        let rate = 16_000.0
        let burst = samples(rate: rate, seconds: 0.5)
        let source = try write("burst.caf", rate: rate, channels: [placing(burst, in: 60, at: 30, rate: rate)])
        let softer = try encoded(placing(burst.map { $0 * 0.316 }, in: 60, at: 30, rate: rate), rate: rate, name: "burst-softer")
        let found = refusal(source: source, copy: softer)
        guard case .level = found else { return XCTFail("\(String(describing: found))") }
    }

    func testBehaviorDownsampledCopyVerifiesAgainstItsResampledLength() throws {
        let source = try write("wide.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 12.34567)])
        let plan = AudioCompressor.Plan(sampleRate: 16_000, sourceSampleRate: 48_000, channels: 1, bitRate: 32_000, downmixes: false)
        XCTAssertEqual(plan.method, "aac-lc-32-16k")
        let copy = folder.appendingPathComponent("narrow.m4a")
        try AudioCompressor.encode(source, to: copy, plan: plan)
        let verification = try AudioCompressor.verify(source: source, copy: copy, plan: plan)
        XCTAssertEqual(verification.frames, plan.expectedFrames(from: try AVAudioFile(forReading: source).length))
        XCTAssertEqual(verification.lag, 0)
        // Verified against the source's own length, it isn't.
        let same = AudioCompressor.Plan(sampleRate: 16_000, channels: 1, bitRate: 32_000, downmixes: false)
        XCTAssertThrowsError(try AudioCompressor.verify(source: source, copy: copy, plan: same))
    }

    func testBehaviorThePlanComesFromTheTable() throws {
        let source = try write("table.caf", rate: 48_000, channels: [samples(rate: 48_000, seconds: 2)])
        let plan = try AudioCompressor.plan(for: source)
        let row = RecordingCompressionTable.row(.wideMono)
        XCTAssertEqual(plan.bitRate, row.bitRate)
        XCTAssertEqual(plan.channels, row.channels)
        XCTAssertEqual(plan.rule, RecordingCompressionTable.rule)
        XCTAssertEqual(TrackEncoding.currentRule, RecordingCompressionTable.rule)
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
