import Foundation

/// Live levels for a recording view: "You" (microphone) and "Call" (call audio).
///
/// Observe this object directly (`recorder.levels`), not through AppState: it updates about 15
/// times a second, and forwarding that through AppState would redraw unrelated views.
@MainActor
final class CaptureLevelMonitor: ObservableObject {
    struct Level: Equatable {
        /// Recent root-mean-square level, dBFS (−160 is silence).
        var rms: Float
        /// Peak since the previous update, dBFS.
        var peak: Float
        /// 0…1 for a meter: −60 dBFS and below is empty, 0 dBFS is full.
        var meterValue: Float { max(0, min(1, (rms + 60) / 60)) }
        static let silent = Level(rms: -160, peak: -160)
    }

    @Published private(set) var microphone = Level.silent
    @Published private(set) var call = Level.silent
    /// The call track carried audible sound within the last few seconds.
    @Published private(set) var isCallAudioDetected = false
    /// No non-zero microphone sample arrived for several seconds: the input is muted in hardware,
    /// unplugged, or blocked by permission.
    @Published private(set) var isMicrophoneSilent = false
    /// True while call audio is part of the recording.
    @Published private(set) var isCapturingCall = false

    static let callHoldSeconds: TimeInterval = 4
    static let silentMicrophoneSeconds: TimeInterval = 3

    static func callAudioDetected(lastAudible: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastAudible else { return false }
        return now - lastAudible <= callHoldSeconds
    }

    func update(microphone mic: AudioLevelMeter.Reading?, call callReading: AudioLevelMeter.Reading?,
                hostTime: TimeInterval, elapsed: TimeInterval) {
        set(\.microphone, mic.map { Level(rms: $0.rms, peak: $0.peak) } ?? .silent)
        set(\.call, callReading.map { Level(rms: $0.rms, peak: $0.peak) } ?? .silent)
        let detected = Self.callAudioDetected(lastAudible: callReading?.lastAudibleHostTime, now: hostTime)
        if detected != isCallAudioDetected { isCallAudioDetected = detected }
        let capturing = callReading != nil
        if capturing != isCapturingCall { isCapturingCall = capturing }
        let silent = elapsed >= Self.silentMicrophoneSeconds && mic?.receivedSignal != true
        if silent != isMicrophoneSilent { isMicrophoneSilent = silent }
    }

    func reset() {
        microphone = .silent; call = .silent
        isCallAudioDetected = false; isMicrophoneSilent = false; isCapturingCall = false
    }

    /// Publishes only visible changes (half a decibel), keeping redraws cheap.
    private func set(_ keyPath: ReferenceWritableKeyPath<CaptureLevelMonitor, Level>, _ value: Level) {
        let current = self[keyPath: keyPath]
        if abs(current.rms - value.rms) >= 0.5 || abs(current.peak - value.peak) >= 0.5 { self[keyPath: keyPath] = value }
    }
}
