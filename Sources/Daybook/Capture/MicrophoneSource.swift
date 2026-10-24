import AVFoundation
import CoreMedia
import Foundation

/// The default input device through AVAudioEngine, without Apple voice processing.
///
/// Voice processing (`setVoiceProcessingEnabled`) is deliberately off: it ducks other audio
/// (including the call the person is listening to), applies gain control and noise suppression
/// that cannot be undone, and cancels echo against its own output path rather than against the
/// call track Daybook records. Daybook keeps the raw microphone as the original and removes the
/// call's echo offline from the recorded call track instead.
///
/// When the input device or its format changes (AirPods connecting, or switching to the hands-free
/// profile when an app opens their microphone), the engine stops. This source reinstalls its tap on
/// the new input and continues; the writer converts the new format to the file's.
final class MicrophoneSource: CaptureAudioSource, @unchecked Sendable {
    let method = "microphone"
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var observer: NSObjectProtocol?
    private var onBuffer: CaptureBufferHandler?
    private var onEvent: CaptureEventHandler?
    private var restarts = 0
    static let maximumRestarts = 20

    func start(onBuffer: @escaping CaptureBufferHandler, onEvent: @escaping CaptureEventHandler) async throws {
        self.onBuffer = onBuffer
        self.onEvent = onEvent
        let engine = AVAudioEngine()
        self.engine = engine
        try installAndStart(engine)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    func stop() async {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine = nil
        onBuffer = nil
    }

    private func installAndStart(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { throw RecordingError.noMicrophone }
        let deliver = onBuffer
        let report = onEvent
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let copied = PCMTrackWriter.copy(buffer) else {
                report?(.failed(RecordingError.invalidAudio))
                return
            }
            let hostSeconds = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            deliver?(copied, hostSeconds)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    /// Follows the new input device instead of ending the recording.
    private func configurationChanged() {
        guard let engine else { return }
        restarts += 1
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        guard restarts <= Self.maximumRestarts else {
            onEvent?(.failed(RecordingError.audioFormatChanged))
            return
        }
        do {
            try installAndStart(engine)
            let format = engine.inputNode.outputFormat(forBus: 0)
            onEvent?(.deviceChanged("The microphone changed (now \(Int(format.sampleRate)) Hz, \(format.channelCount) ch); recording continued."))
        } catch {
            onEvent?(.failed(error))
        }
    }
}
