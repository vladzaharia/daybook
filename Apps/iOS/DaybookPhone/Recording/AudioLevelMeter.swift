import Accelerate
import AVFoundation
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
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.format.channelCount)
        let lanes = buffer.format.isInterleaved ? 1 : count
        let perLane = vDSP_Length(Int(buffer.frameLength) * (buffer.format.isInterleaved ? count : 1))
        var sumSquares: Float = 0, peak: Float = 0
        for lane in 0..<lanes {
            var squares: Float = 0, magnitude: Float = 0
            vDSP_svesq(channels[lane], 1, &squares, perLane)
            vDSP_maxmgv(channels[lane], 1, &magnitude, perLane)
            sumSquares += squares
            peak = max(peak, magnitude)
        }
        let samples = Float(buffer.frameLength) * Float(count)
        let rms = 10 * log10(max(sumSquares / max(samples, 1), 1e-16))
        let peakDB = 20 * log10(max(peak, 1e-8))
        lock.withLock {
            level.rms = rms
            peakSinceRead = max(peakSinceRead, peakDB)
            level.peak = peakSinceRead
            if peak > 0 { signal = true }
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
