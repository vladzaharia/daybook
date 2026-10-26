import Accelerate
import AVFoundation
import Foundation

// The capture code both apps share: how loud a buffer is, for the level meters, and converting
// buffers a device delivers in another format to the recording's. Each app keeps its own meter state
// (the Mac also tracks when it last heard something) and its own writer.

/// How loud a buffer of float PCM is.
public enum AudioBufferLevel {
    /// The level of every sample of every channel: root-mean-square and peak in dBFS (each at least
    /// −160), and whether any sample wasn't zero (all-zero input usually means a muted or blocked
    /// microphone). Nil for an empty buffer or one that isn't float PCM.
    public static func measure(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float, hasSignal: Bool)? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let count = Int(buffer.format.channelCount)
        // Interleaved audio is one run of frames × channels; otherwise one run per channel.
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
        return (rms, 20 * log10(max(peak, 1e-8)), peak > 0)
    }
}

/// Converts buffers from the format a device delivers (AirPods at 16 kHz, a stereo USB microphone)
/// to a recording's, keeping one `AVAudioConverter` per input format so resampling state carries
/// across buffers. When the format changes, or the device returns to the recording's own, `drain()`
/// first gives back what the converter still holds (its look-ahead).
public final class PCMFormatConverter {
    public enum Failure: Error {
        /// No converter between the two formats.
        case unsupported
        /// No buffer for the output.
        case buffer
        /// The conversion failed (with the converter's error, when it gave one).
        case conversion(Error?)
    }

    private var converter: AVAudioConverter?

    public init() {}

    /// The format being converted from, while there's a converter.
    public var inputFormat: AVAudioFormat? { converter?.inputFormat }

    /// Readies a converter from `inputFormat` to `format`, downmixing extra channels. True when that
    /// took a new one (the recording notes the change, and its clock resynchronizes). Call `drain()`
    /// first when the input format changes, to keep what the previous converter held.
    @discardableResult
    public func prepare(from inputFormat: AVAudioFormat, to format: AVAudioFormat) throws -> Bool {
        guard converter?.inputFormat != inputFormat || converter?.outputFormat != format else { return false }
        guard let created = AVAudioConverter(from: inputFormat, to: format) else { throw Failure.unsupported }
        if inputFormat.channelCount > format.channelCount { created.downmix = true }
        converter = created
        return true
    }

    /// `input` in the format `prepare` readied.
    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter else { throw Failure.unsupported }
        let format = converter.outputFormat
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw Failure.buffer }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw Failure.conversion(error) }
        return output
    }

    /// What the converter still holds, in its output format, and retires it. Nil when there's no
    /// converter or it holds nothing.
    public func drain() -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        self.converter = nil
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 8_192) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Retires the converter without keeping what it holds.
    public func discard() { converter = nil }
}
