import DaybookCore
import Foundation
import Observation

/// Live levels for a recording view: "You" (microphone) and "Call" (call audio).
///
/// The levels change about 15 times a second: read `microphone` and `call` only in what draws a
/// meter (Floating Notes samples them on its own timer). The flags change rarely and any view may read them.
@MainActor
@Observable
final class CaptureLevelMonitor {
    private(set) var microphone = AudioLevel.silent
    private(set) var call = AudioLevel.silent
    /// The call track carried audible sound within the last few seconds.
    private(set) var isCallAudioDetected = false
    /// The microphone isn't hearing anything now (`HearingCheck`): muted in hardware, unplugged, blocked by
    /// permission, or a MacBook's microphone with its lid closed. Rolling, so a microphone that goes quiet
    /// partway through is said too.
    private(set) var isMicrophoneSilent = false
    /// True while call audio is part of the recording.
    private(set) var isCapturingCall = false
    /// When the microphone last heard something as loud as speech (`AudioLevelMeter.audibleThreshold`): a follower
    /// that can't reach its leader stops only in a quiet room (`LeaderWatch`). Changes with every word, so unobserved.
    @ObservationIgnored private(set) var microphoneLastAudibleAt: Date?

    static let callHoldSeconds: TimeInterval = 4

    static func callAudioDetected(lastAudible: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastAudible else { return false }
        return now - lastAudible <= callHoldSeconds
    }

    func update(microphone mic: AudioLevelMeter.Reading?, call callReading: AudioLevelMeter.Reading?,
                hostTime: TimeInterval, elapsed: TimeInterval) {
        set(\.microphone, mic?.level ?? .silent)
        set(\.call, callReading?.level ?? .silent)
        let detected = Self.callAudioDetected(lastAudible: callReading?.lastAudibleHostTime, now: hostTime)
        if detected != isCallAudioDetected { isCallAudioDetected = detected }
        let capturing = callReading != nil
        if capturing != isCapturingCall { isCapturingCall = capturing }
        // Listening since the recording started: the Mac's recordings don't pause.
        let silent = HearingCheck.isNotHearing(mic, listeningSince: hostTime - elapsed, now: hostTime)
        if silent != isMicrophoneSilent { isMicrophoneSilent = silent }
        if let audible = mic?.lastAudibleHostTime { microphoneLastAudibleAt = Date().addingTimeInterval(-max(0, hostTime - audible)) }
    }

    func reset() {
        microphone = .silent; call = .silent
        isCallAudioDetected = false; isMicrophoneSilent = false; isCapturingCall = false
        microphoneLastAudibleAt = nil
    }

    /// Publishes only visible changes (half a decibel), keeping redraws cheap.
    private func set(_ keyPath: ReferenceWritableKeyPath<CaptureLevelMonitor, AudioLevel>, _ value: AudioLevel) {
        let current = self[keyPath: keyPath]
        if abs(current.rms - value.rms) >= 0.5 || abs(current.peak - value.peak) >= 0.5 { self[keyPath: keyPath] = value }
    }
}
