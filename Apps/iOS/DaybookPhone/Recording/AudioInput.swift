import AVFoundation
import Foundation

/// How a phone recording is stored.
///
/// **AAC-LC, mono, 48 kHz, 64 kbps (constrained VBR), in M4A.** Transcription and speaker models read speech at
/// 16 kHz, and speech carries almost nothing useful above 8 kHz, so 64 kbps mono AAC-LC is
/// effectively transparent for them while still keeping the full band for listening. 96 kbps
/// would cost 50% more storage and upload for no difference in transcripts. 64 kbps is about
/// 29 MB an hour, so a full working day of meetings stays under a quarter of a gigabyte.
/// 48 kHz matches the iPhone's microphone hardware, so the usual path never resamples.
struct RecordingFormat: Equatable, Sendable {
    var sampleRate: Double = 48_000
    var bitRate: Int = 64_000
    /// How often the file being written is made readable on disk (movie fragments). In real-time
    /// mode AVAssetWriter writes a fragment once the audio passes each interval, so a crash loses at
    /// most about two intervals. (Non-real-time mode, used only to feed tests fast, holds back the
    /// first fragments longer; see PhoneRecorderTests.)
    var fragmentInterval: TimeInterval = 2

    static let speech = RecordingFormat()

    /// The PCM every buffer is converted to before encoding.
    var pcmFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Variable bit rate capped near `bitRate`: speech gets about 64 kbps, and silence (such as
    /// an interruption's gap) costs almost nothing.
    var aacSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC,
         AVSampleRateKey: sampleRate,
         AVNumberOfChannelsKey: 1,
         AVEncoderBitRateKey: bitRate,
         AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained]
    }
}

enum AudioInputEvent: Sendable {
    /// The input restarted on a new device or format; the next buffers start a new clock run.
    case restarted(String)
    case failed(String)
}

/// Where audio comes from: the microphone through `AVAudioEngine`, or synthetic audio in tests and
/// simulator demos.
protocol AudioInputSource: AnyObject {
    /// Starts delivering audio. `onBuffer` runs on a background thread with a buffer the receiver
    /// may keep, stamped with the host time (seconds) of its first frame.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void,
               onEvent: @escaping @Sendable (AudioInputEvent) -> Void) throws
    func stop()
}

/// The microphone through `AVAudioEngine`'s input node. The tap delivers the hardware format;
/// the writer converts it, so a route change (AirPods at 16 or 24 kHz) never ends the recording.
final class EngineMicrophoneInput: AudioInputSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let control = DispatchQueue(label: "local.daybook.phone.microphone")
    private var observer: NSObjectProtocol?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)?
    private var onEvent: (@Sendable (AudioInputEvent) -> Void)?
    private var running = false

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void,
               onEvent: @escaping @Sendable (AudioInputEvent) -> Void) throws {
        try control.sync {
            self.onBuffer = onBuffer
            self.onEvent = onEvent
            try installAndStart()
            running = true
            // Route and format changes stop the engine; restart it on the new hardware format.
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.control.async { self?.restart() }
            }
        }
    }

    func stop() {
        control.sync {
            running = false
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private func installAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PhoneRecorderError.noMicrophone }
        input.removeTap(onBus: 0)
        let deliver = onBuffer
        input.installTap(onBus: 0, bufferSize: 4_800, format: format) { buffer, when in
            let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime)
                                            : AVAudioTime.seconds(forHostTime: mach_absolute_time())
            // The engine reuses its buffer; the writer keeps a copy.
            guard let copy = buffer.copied() else { return }
            deliver?(copy, host)
        }
        engine.prepare()
        try engine.start()
    }

    private func restart() {
        guard running else { return }
        engine.stop()
        do {
            try installAndStart()
            let format = engine.inputNode.outputFormat(forBus: 0)
            onEvent?(.restarted("The microphone changed to \(Int(format.sampleRate)) Hz, \(format.channelCount) ch."))
        } catch {
            onEvent?(.failed("The microphone stopped: \(error.localizedDescription)"))
        }
    }
}

/// Audio made up on the spot: a tone or a speech-like signal, in any format.
///
/// In tests it delivers on demand (`pump`) and advances a `ManualRecorderClock`, so a ten-second
/// recording takes milliseconds. In a simulator demo it runs in real time on a timer. Either way
/// it never opens the microphone.
final class SyntheticAudioInput: AudioInputSource, @unchecked Sendable {
    enum Signal: Sendable {
        case tone(frequency: Double, amplitude: Float)
        /// Voiced syllables with pauses, so the level meter moves like speech.
        case speechLike
        case silence
    }

    let format: AVAudioFormat
    var signal: Signal
    /// Tests: keep delivering after `stop()`, like a microphone tap with a buffer already in flight.
    var deliversAfterStop = false
    private let clock: any RecorderClock
    private let realTime: Bool
    private let lock = NSLock()
    private var frame: Int64 = 0
    private var onBuffer: (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)?
    private var onEvent: (@Sendable (AudioInputEvent) -> Void)?
    private var timer: DispatchSourceTimer?
    private var nextHostTime: TimeInterval = 0
    private(set) var isRunning = false

    init(format: AVAudioFormat = RecordingFormat.speech.pcmFormat, signal: Signal = .tone(frequency: 440, amplitude: 0.3),
         clock: any RecorderClock, realTime: Bool = false) {
        self.format = format
        self.signal = signal
        self.clock = clock
        self.realTime = realTime
    }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void,
               onEvent: @escaping @Sendable (AudioInputEvent) -> Void) throws {
        lock.withLock {
            self.onBuffer = onBuffer
            self.onEvent = onEvent
            isRunning = true
            nextHostTime = clock.hostTime()
        }
        guard realTime else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "local.daybook.phone.synthetic-input"))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.deliverDue() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        guard !deliversAfterStop else { return }
        lock.withLock { isRunning = false; onBuffer = nil }
    }

    /// Delivers `seconds` of audio now in `chunk`-second buffers. With a manual clock, the clock
    /// advances with the audio, as it would in real time.
    func pump(seconds: TimeInterval, chunk: TimeInterval = 0.1) {
        var remaining = Int64((seconds * format.sampleRate).rounded())
        let chunkFrames = max(1, Int64((chunk * format.sampleRate).rounded()))
        while remaining > 0 {
            let count = min(chunkFrames, remaining)
            let host = clock.hostTime()
            deliver(frames: count, hostTime: host)
            (clock as? ManualRecorderClock)?.advance(Double(count) / format.sampleRate)
            remaining -= count
        }
    }

    /// Real-time delivery: everything due by now, stamped where it falls.
    private func deliverDue() {
        let now = clock.hostTime()
        let chunk: TimeInterval = 0.1
        while true {
            let host: TimeInterval? = lock.withLock { nextHostTime + chunk <= now ? nextHostTime : nil }
            guard let host else { return }
            let frames = Int64((chunk * format.sampleRate).rounded())
            deliver(frames: frames, hostTime: host)
            lock.withLock { nextHostTime += chunk }
        }
    }

    private func deliver(frames: Int64, hostTime: TimeInterval) {
        let (handler, start, running) = lock.withLock { () -> ((@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)?, Int64, Bool) in
            let start = frame
            frame += frames
            return (onBuffer, start, isRunning)
        }
        guard running, let handler, let buffer = makeBuffer(frames: frames, startFrame: start) else { return }
        handler(buffer, hostTime)
    }

    private func makeBuffer(frames: Int64, startFrame: Int64) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let rate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let stride = format.isInterleaved ? channelCount : 1
        let lanes = format.isInterleaved ? 1 : channelCount
        for index in 0..<Int(frames) {
            let t = Double(startFrame + Int64(index)) / rate
            let value = sample(at: t)
            for lane in 0..<lanes {
                for channel in 0..<stride { channels[lane][index * stride + channel] = value }
            }
        }
        return buffer
    }

    private func sample(at t: Double) -> Float {
        switch signal {
        case .silence:
            return 0
        case .tone(let frequency, let amplitude):
            return amplitude * Float(sin(2 * .pi * frequency * t))
        case .speechLike:
            // About four syllables a second, phrases of ~2.5 s with short pauses, a gliding pitch.
            let phrase = t.truncatingRemainder(dividingBy: 3.2)
            guard phrase < 2.5 else { return 0 }
            let syllable = max(0, sin(2 * .pi * 4 * t))
            let pitch = 140 + 30 * sin(2 * .pi * 0.3 * t)
            let voice = sin(2 * .pi * pitch * t) + 0.5 * sin(4 * .pi * pitch * t) + 0.25 * sin(6 * .pi * pitch * t)
            return Float(0.18 * syllable * voice)
        }
    }
}

extension AVAudioPCMBuffer {
    /// A copy the caller owns.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let input = source[index].mData, let output = destination[index].mData else { return nil }
            memcpy(output, input, Int(min(source[index].mDataByteSize, destination[index].mDataByteSize)))
        }
        return copy
    }
}
