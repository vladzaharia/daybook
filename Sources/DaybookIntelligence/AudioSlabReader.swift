import AVFoundation
import Foundation

/// Converts a bounded time range to 16 kHz mono using small streaming buffers.
/// Keeps the source frame count as Int64, including for recordings beyond the
/// UInt32 frame limit used by WhisperKit's convenience file loader.
public enum AudioSlabReader {
    public static func samples(url: URL, from start: Double, to end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard start.isFinite, end.isFinite, start >= 0, end > start, rate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw LocalIntelligenceError.invalidAudio
        }
        converter.downmix = true
        file.framePosition = min(file.length, AVAudioFramePosition(start * rate))
        var remaining = max(0, min(file.length, AVAudioFramePosition(end * rate)) - file.framePosition)
        var readError: Error?
        var samples: [Float] = []
        samples.reserveCapacity(Int((end - start) * 16_000) + 512)
        while true {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_000) else {
                throw LocalIntelligenceError.invalidAudio
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard remaining > 0, readError == nil else { inputStatus.pointee = .endOfStream; return nil }
                let count = AVAudioFrameCount(min(remaining, Int64(min(requested, 32_768))))
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                    readError = LocalIntelligenceError.invalidAudio; inputStatus.pointee = .endOfStream; return nil
                }
                do {
                    try file.read(into: input, frameCount: count)
                    remaining -= Int64(input.frameLength)
                    if input.frameLength == 0 { remaining = 0; inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return input
                } catch {
                    readError = error; inputStatus.pointee = .endOfStream; return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream || (status == .inputRanDry && remaining == 0) { break }
            if status == .error { throw LocalIntelligenceError.invalidAudio }
        }
        return samples
    }
}
