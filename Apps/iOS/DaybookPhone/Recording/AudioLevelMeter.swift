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

/// Thread-safe level meter fed by the audio callback and read by the interface (the Mac's design).
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var level = AudioLevel.silent
    private var peakSinceRead: Float = -160
    private var signal = false

    /// True once any non-zero sample arrived; all-zero input usually means a muted or blocked microphone.
    var receivedSignal: Bool { lock.withLock { signal } }

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let measured = AudioBufferLevel.measure(buffer) else { return }
        lock.withLock {
            level.rms = measured.rms
            peakSinceRead = max(peakSinceRead, measured.peak)
            level.peak = peakSinceRead
            if measured.hasSignal { signal = true }
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
        lock.withLock { level = .silent; peakSinceRead = -160; signal = false }
    }
}
