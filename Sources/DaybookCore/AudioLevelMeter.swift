import AVFoundation
import Foundation
import Synchronization

/// How loud an input is now, for a meter: what both apps' recorders show as "You" and "Call".
public struct AudioLevel: Equatable, Sendable {
    /// Root-mean-square level, smoothed over about 300 ms, in dBFS (−160 is silence).
    public var rms: Float
    /// The highest sample magnitude in the last second, in dBFS.
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    /// 0…1 for a meter: −60 dBFS and below is empty, 0 dBFS is full.
    public var meterValue: Double { Double(max(0, min(1, (rms + 60) / 60))) }

    public static let silent = AudioLevel(rms: -160, peak: -160)
}

/// The level meter both apps' capture feeds from its audio callbacks and their interfaces read about fifteen times a
/// second.
///
/// Every source moves alike, whatever its buffer size (a tap's 10 ms, the Mac's microphone's 85 ms, the iPhone's): the
/// level is RMS smoothed with a 300 ms time constant, and the peak holds for a second. It also keeps when it last heard
/// anything, for the rolling hearing check (`HearingCheck`), and when it last heard something as loud as speech.
public final class AudioLevelMeter: Sendable {
    public struct Reading: Equatable, Sendable {
        /// Root-mean-square level, smoothed over about 300 ms, in dBFS.
        public var rms: Float
        /// The highest sample magnitude in the last second, in dBFS.
        public var peak: Float
        /// Host time of the most recent buffer whose level reached `audibleThreshold`.
        public var lastAudibleHostTime: TimeInterval?
        /// Host time of the most recent buffer with any non-zero sample; all-zero input usually means a muted,
        /// unplugged, or denied device (or a MacBook's microphone with its lid closed).
        public var lastSignalHostTime: TimeInterval?
        /// Host time of the most recent buffer above `hearingFloor`.
        public var lastHeardHostTime: TimeInterval?

        public init(rms: Float, peak: Float, lastAudibleHostTime: TimeInterval? = nil, lastSignalHostTime: TimeInterval? = nil,
                    lastHeardHostTime: TimeInterval? = nil) {
            self.rms = rms
            self.peak = peak
            self.lastAudibleHostTime = lastAudibleHostTime
            self.lastSignalHostTime = lastSignalHostTime
            self.lastHeardHostTime = lastHeardHostTime
        }

        /// The level alone, for a meter.
        public var level: AudioLevel { AudioLevel(rms: rms, peak: peak) }

        public static let silent = Reading(rms: -160, peak: -160)
    }

    /// At or above this, dBFS, a buffer is as loud as speech.
    public static let audibleThreshold: Float = -50
    /// Below this a microphone hears nothing a person could have said (a quiet room is some 30 dB louder).
    public static let hearingFloor: Float = -90
    public static let timeConstant: TimeInterval = 0.3
    public static let peakHold: TimeInterval = 1

    private struct State {
        var reading = Reading.silent
        var meanSquare: Float = 0
        var peakHeldUntil: TimeInterval = -.infinity
    }

    private let state = Mutex(State())

    public init() {}

    /// Measures a buffer whose first frame is at `hostTime`.
    public func record(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        guard let level = AudioBufferLevel.measure(buffer), buffer.format.sampleRate > 0 else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let weight = Float(1 - exp(-duration / Self.timeConstant))
        let power = level.rms <= -160 ? 0 : pow(10, level.rms / 10)
        state.withLock { state in
            state.meanSquare += weight * (power - state.meanSquare)
            state.reading.rms = max(-160, 10 * log10(max(state.meanSquare, 1e-16)))
            if level.peak >= state.reading.peak || hostTime >= state.peakHeldUntil {
                state.reading.peak = level.peak
                state.peakHeldUntil = hostTime + Self.peakHold
            }
            if level.hasSignal { state.reading.lastSignalHostTime = hostTime }
            if level.rms >= Self.hearingFloor { state.reading.lastHeardHostTime = hostTime }
            if level.rms >= Self.audibleThreshold { state.reading.lastAudibleHostTime = hostTime }
        }
    }

    public func read() -> Reading {
        state.withLock { $0.reading }
    }

    public func reset() {
        state.withLock { $0 = State() }
    }
}

/// The rolling hearing check both apps make (docs/capture.md, "When the world misbehaves"): the microphone isn't hearing
/// when no non-zero sample arrived in the last 5 s, or nothing above −90 dBFS (`AudioLevelMeter.hearingFloor`) for 20 s,
/// counted from when it last started listening (a start, a resume), so a check never says so before it could know. It's
/// rolling, so a microphone that goes to digital zeros partway (a mute switch, a dead headset, a MacBook's lid closed)
/// is said too, and it clears as soon as it hears again.
public enum HearingCheck {
    /// No non-zero sample for this long is not hearing.
    public static let silentSeconds: TimeInterval = 5
    /// Nothing above `AudioLevelMeter.hearingFloor` for this long is not hearing either.
    public static let belowFloorSeconds: TimeInterval = 20

    public static func isNotHearing(_ reading: AudioLevelMeter.Reading?, listeningSince: TimeInterval, now: TimeInterval) -> Bool {
        let signal = max(reading?.lastSignalHostTime ?? listeningSince, listeningSince)
        if now - signal > silentSeconds { return true }
        let heard = max(reading?.lastHeardHostTime ?? listeningSince, listeningSince)
        return now - heard > belowFloorSeconds
    }
}
