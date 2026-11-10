import AVFoundation
import DaybookCore
import Foundation

/// One reading of the input level.
struct AudioLevel: Equatable, Sendable {
    /// Recent root-mean-square level, dBFS (−160 is silence).
    var rms: Float
    /// Peak since the previous reading, dBFS.
    var peak: Float
    /// 0…1 for a meter: −60 dBFS and below is empty, 0 dBFS is full.
    var meterValue: Double { Double(max(0, min(1, (rms + 60) / 60))) }
    static let silent = AudioLevel(rms: -160, peak: -160)
}

/// When the microphone last heard anything, on the host clock that stamps its buffers.
struct HeardTimes: Equatable, Sendable {
    /// The latest buffer with any non-zero sample; all-zero input is a muted, unplugged, or blocked microphone.
    var signal: TimeInterval?
    /// The latest buffer above `HearingCheck.floor`.
    var aboveFloor: TimeInterval?
}

/// The rolling hearing check, the Mac's rule (docs/capture.md, "Hearing"): the microphone isn't hearing when no
/// non-zero sample arrived in the last 5 s, or nothing above −90 dBFS for 20 s, counted from when it last started
/// listening (a start, a resume). Rolling, so a microphone that goes to digital zeros partway (a mute switch, a
/// dead headset) is said too, and it clears as soon as it hears again.
enum HearingCheck {
    static let silentSeconds: TimeInterval = 5
    static let belowFloorSeconds: TimeInterval = 20
    /// Below this a microphone hears nothing a person could have said (a quiet room is some 30 dB louder).
    static let floor: Float = -90

    static func isNotHearing(_ heard: HeardTimes, listeningSince: TimeInterval, now: TimeInterval) -> Bool {
        if now - max(heard.signal ?? listeningSince, listeningSince) > silentSeconds { return true }
        return now - max(heard.aboveFloor ?? listeningSince, listeningSince) > belowFloorSeconds
    }
}

/// Thread-safe level meter fed by the audio callback and read by the interface (the Mac's design).
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var level = AudioLevel.silent
    private var peakSinceRead: Float = -160
    private var times = HeardTimes()

    /// When it last heard anything, for the hearing check.
    var heard: HeardTimes { lock.withLock { times } }

    /// Measures a buffer whose first frame is at `hostTime`.
    func record(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        guard let measured = AudioBufferLevel.measure(buffer) else { return }
        lock.withLock {
            level.rms = measured.rms
            peakSinceRead = max(peakSinceRead, measured.peak)
            level.peak = peakSinceRead
            if measured.hasSignal { times.signal = hostTime }
            if measured.rms >= HearingCheck.floor { times.aboveFloor = hostTime }
        }
    }

    /// The current reading; resets the peak hold.
    func read() -> AudioLevel {
        lock.withLock {
            let value = level
            peakSinceRead = level.rms
            return value
        }
    }

    func reset() {
        lock.withLock { level = .silent; peakSinceRead = -160; times = HeardTimes() }
    }
}
