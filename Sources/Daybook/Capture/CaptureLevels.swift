import Foundation
import Observation

/// Live levels for a recording view: "You" (microphone) and "Call" (call audio).
///
/// The levels change about 15 times a second: read `microphone` and `call` only in what draws a
/// meter (Floating Notes samples them on its own timer). The flags change rarely and any view may read them.
@MainActor
@Observable
final class CaptureLevelMonitor {
    struct Level: Equatable {
        /// Recent root-mean-square level, dBFS (−160 is silence).
        var rms: Float
        /// Peak since the previous update, dBFS.
        var peak: Float
        /// 0…1 for a meter: −60 dBFS and below is empty, 0 dBFS is full.
        var meterValue: Float { max(0, min(1, (rms + 60) / 60)) }
        static let silent = Level(rms: -160, peak: -160)
    }

    private(set) var microphone = Level.silent
    private(set) var call = Level.silent
    /// The call track carried audible sound within the last few seconds.
    private(set) var isCallAudioDetected = false
    /// The microphone isn't hearing anything now (`isNotHearing`): muted in hardware, unplugged, blocked by
    /// permission, or a MacBook's microphone with its lid closed. Rolling, so a microphone that goes quiet
    /// partway through is said too.
    private(set) var isMicrophoneSilent = false
    /// True while call audio is part of the recording.
    private(set) var isCapturingCall = false
    /// When the microphone last heard something as loud as speech (`AudioLevelMeter.audibleThreshold`): a follower
    /// that can't reach its leader stops only in a quiet room (`LeaderWatch`). Changes with every word, so unobserved.
    @ObservationIgnored private(set) var microphoneLastAudibleAt: Date?

    static let callHoldSeconds: TimeInterval = 4
    /// No non-zero sample for this long is not hearing.
    static let silentMicrophoneSeconds: TimeInterval = 5
    /// Nothing above `AudioLevelMeter.hearingFloor` (−90 dBFS) for this long is not hearing either.
    static let belowFloorSeconds: TimeInterval = 20

    static func callAudioDetected(lastAudible: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastAudible else { return false }
        return now - lastAudible <= callHoldSeconds
    }

    /// The rolling hearing check: no non-zero sample in the last 5 s, or nothing above −90 dBFS for 20 s. `elapsed` is
    /// how long the recording has run; a check never says so before it could know.
    static func isNotHearing(_ reading: AudioLevelMeter.Reading?, now: TimeInterval, elapsed: TimeInterval) -> Bool {
        let started = now - elapsed
        let signal = reading?.lastSignalHostTime ?? started
        if now - signal > silentMicrophoneSeconds { return true }
        let heard = reading?.lastHeardHostTime ?? started
        return now - heard > belowFloorSeconds
    }

    func update(microphone mic: AudioLevelMeter.Reading?, call callReading: AudioLevelMeter.Reading?,
                hostTime: TimeInterval, elapsed: TimeInterval) {
        set(\.microphone, mic.map { Level(rms: $0.rms, peak: $0.peak) } ?? .silent)
        set(\.call, callReading.map { Level(rms: $0.rms, peak: $0.peak) } ?? .silent)
        let detected = Self.callAudioDetected(lastAudible: callReading?.lastAudibleHostTime, now: hostTime)
        if detected != isCallAudioDetected { isCallAudioDetected = detected }
        let capturing = callReading != nil
        if capturing != isCapturingCall { isCapturingCall = capturing }
        let silent = Self.isNotHearing(mic, now: hostTime, elapsed: elapsed)
        if silent != isMicrophoneSilent { isMicrophoneSilent = silent }
        if let audible = mic?.lastAudibleHostTime { microphoneLastAudibleAt = Date().addingTimeInterval(-max(0, hostTime - audible)) }
    }

    func reset() {
        microphone = .silent; call = .silent
        isCallAudioDetected = false; isMicrophoneSilent = false; isCapturingCall = false
        microphoneLastAudibleAt = nil
    }

    /// Publishes only visible changes (half a decibel), keeping redraws cheap.
    private func set(_ keyPath: ReferenceWritableKeyPath<CaptureLevelMonitor, Level>, _ value: Level) {
        let current = self[keyPath: keyPath]
        if abs(current.rms - value.rms) >= 0.5 || abs(current.peak - value.peak) >= 0.5 { self[keyPath: keyPath] = value }
    }
}
