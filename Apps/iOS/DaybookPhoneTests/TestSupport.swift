import AVFoundation
import DaybookCore
import XCTest
@testable import DaybookPhone

/// Every synthetic input a recorder made (resuming makes a new one), so a test can feed the latest.
final class InputBox {
    var all: [SyntheticAudioInput] = []
    var current: SyntheticAudioInput { all[all.count - 1] }
}

/// A recorder wired to synthetic audio, a scripted audio session, and a manual clock. Nothing here
/// touches a microphone.
@MainActor
struct RecorderRig {
    let recorder: PhoneRecorder
    let session: ScriptedAudioSession
    let clock: ManualRecorderClock
    let inputs: InputBox

    /// `realTimeEncoding` is the recorder's own mode. Off (the default) lets tests deliver audio
    /// faster than real time, but AVAssetWriter then holds back its first movie fragments (about 3 s
    /// of audio here, more on some runtimes), so tests of what reaches the disk mid-recording use it on.
    init(inputFormat: AVAudioFormat = RecordingFormat.speech.pcmFormat,
         signal: SyntheticAudioInput.Signal = .tone(frequency: 440, amplitude: 0.3),
         fragmentInterval: TimeInterval = 2, realTimeEncoding: Bool = false) {
        let clock = ManualRecorderClock()
        let session = ScriptedAudioSession()
        let inputs = InputBox()
        var format = RecordingFormat.speech
        format.fragmentInterval = fragmentInterval
        let environment = PhoneRecorderEnvironment(
            session: session,
            makeInput: {
                let input = SyntheticAudioInput(format: inputFormat, signal: signal, clock: clock)
                inputs.all.append(input)
                return input
            },
            clock: clock, format: format, realTimeEncoding: realTimeEncoding)
        self.recorder = PhoneRecorder(environment: environment)
        self.session = session
        self.clock = clock
        self.inputs = inputs
    }

    /// Delivers audio to the current input, advancing the clock with it.
    func pump(_ seconds: TimeInterval) { inputs.current.pump(seconds: seconds) }

    /// Stops and returns the finished recording.
    func stop() async throws -> PhoneRecording {
        let recording = await recorder.stop()
        return try XCTUnwrap(recording, recorder.lastError ?? "no recording")
    }
}

/// Decoded audio, for checking what a file holds.
struct DecodedAudio {
    let samples: [Float]
    let sampleRate: Double
    var duration: TimeInterval { Double(samples.count) / sampleRate }

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        sampleRate = file.processingFormat.sampleRate
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func slice(_ range: Range<TimeInterval>) -> ArraySlice<Float> {
        let start = max(0, min(samples.count, Int(range.lowerBound * sampleRate)))
        let end = max(start, min(samples.count, Int(range.upperBound * sampleRate)))
        return samples[start..<end]
    }

    func rms(_ range: Range<TimeInterval>) -> Float {
        let part = slice(range)
        guard !part.isEmpty else { return 0 }
        return (part.reduce(0) { $0 + $1 * $1 } / Float(part.count)).squareRoot()
    }

    /// Dominant frequency from zero crossings, for a pure tone.
    func frequency(_ range: Range<TimeInterval>) -> Double {
        let part = Array(slice(range))
        guard part.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<part.count where (part[index - 1] < 0) != (part[index] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(part.count) / sampleRate)
    }
}

/// A 440 Hz tone at amplitude 0.3 has an RMS of 0.3 / √2.
let toneRMS: Float = 0.3 / Float(2).squareRoot()

extension XCTestCase {
    /// Polls (on the main actor) until `condition` holds.
    @MainActor
    func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out waiting for \(description)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func temporaryDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaybookPhoneTests", isDirectory: true)
            .appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
