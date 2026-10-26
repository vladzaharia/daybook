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

// Waiting for something to happen, as the package's tests do (Tests/DaybookTestSupport/Waiting.swift):
// a timeout always fails the test by throwing, which also stops it, and says what it waited for,
// where, and what it last saw. Every timeout stretches by DAYBOOK_TEST_TIMEOUT_SCALE; xcodebuild
// hands the test runner its TEST_RUNNER_-prefixed variables with the prefix removed, so CI sets
// TEST_RUNNER_DAYBOOK_TEST_TIMEOUT_SCALE.

/// Timeouts in tests, stretched on slow machines.
enum TestTiming {
    /// `DAYBOOK_TEST_TIMEOUT_SCALE` (1 when unset or not a number of at least 1). Nothing ever waits
    /// less than its nominal timeout.
    static let scale: Double = {
        guard let raw = ProcessInfo.processInfo.environment["DAYBOOK_TEST_TIMEOUT_SCALE"], let value = Double(raw),
              value.isFinite else { return 1 }
        return max(1, value)
    }()

    /// `seconds`, stretched by `scale`.
    static func scaled(_ seconds: TimeInterval) -> TimeInterval { seconds * scale }
}

/// A wait that ran out of time. Thrown, so the test fails with this description.
struct WaitTimeout: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }

    init(_ what: String, after seconds: TimeInterval, file: StaticString, line: UInt, lastState: String?) {
        var text = "Timed out after \(String(format: "%.1f", seconds)) s waiting for \(what) (\(file):\(line))"
        if let lastState { text += ". Last seen: \(lastState)" }
        description = text
    }
}

extension XCTestCase {
    /// Polls on the main actor until `condition` holds. Throws `WaitTimeout` after `timeout` seconds
    /// (stretched by `TestTiming.scale`), with `state()` describing what it last saw.
    @MainActor
    func waitUntil(_ description: String, timeout: TimeInterval = 10, poll: Duration = .milliseconds(10),
                   file: StaticString = #filePath, line: UInt = #line,
                   state: (@MainActor () -> String)? = nil, _ condition: @MainActor () throws -> Bool) async throws {
        _ = try await waitFor(description, timeout: timeout, poll: poll, file: file, line: line, state: state) { try condition() ? true : nil }
    }

    /// Polls on the main actor until `value` returns something, and returns that. Throws
    /// `WaitTimeout` after `timeout` seconds (stretched by `TestTiming.scale`).
    @MainActor
    func waitFor<T>(_ description: String, timeout: TimeInterval = 10, poll: Duration = .milliseconds(10),
                    file: StaticString = #filePath, line: UInt = #line,
                    state: (@MainActor () -> String)? = nil, _ value: @MainActor () throws -> T?) async throws -> T {
        let limit = TestTiming.scaled(timeout)
        let deadline = ContinuousClock.now + .seconds(limit)
        while true {
            if let found = try value() { return found }
            guard ContinuousClock.now < deadline else {
                let timeout = WaitTimeout(description, after: limit, file: file, line: line, lastState: state?())
                print("error: \(timeout)")
                throw timeout
            }
            try await Task.sleep(for: poll)
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

/// A small solid image, as a camera photo taken at `capturedAt`.
@MainActor
func syntheticCameraPhoto(capturedAt: Date, size: CGSize = CGSize(width: 80, height: 40)) -> CameraPhoto {
    let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { context in
        UIColor.orange.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    return CameraPhoto(data: data, fileExtension: "jpg", capturedAt: capturedAt)
}
