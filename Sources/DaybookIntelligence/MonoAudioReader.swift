import AVFoundation
import Foundation

/// Reads a whole recording as 16 kHz mono, block by block, through one converter, so blocks join
/// exactly (no seams, unlike independent slabs) while memory stays bounded. Channels are mixed down.
enum MonoAudioReader {
    static let sampleRate = 16_000.0

    /// Calls `body` with consecutive blocks of about `blockSeconds`; returns the total sample count.
    @discardableResult
    static func read(url: URL, blockSeconds: Double = 30, _ body: ([Float]) throws -> Void) throws -> Int {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw LocalIntelligenceError.invalidAudio
        }
        converter.downmix = true
        let blockSize = max(1_600, Int(blockSeconds * sampleRate))
        var block: [Float] = []
        block.reserveCapacity(blockSize)
        var total = 0
        var finished = false
        var readError: Error?
        while true {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_000) else { throw LocalIntelligenceError.invalidAudio }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard !finished, readError == nil else { inputStatus.pointee = .endOfStream; return nil }
                let count = AVAudioFrameCount(min(Int64(requested), 32_768, max(0, file.length - file.framePosition)))
                guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                    finished = true; inputStatus.pointee = .endOfStream; return nil
                }
                do {
                    try file.read(into: input, frameCount: count)
                    if input.frameLength == 0 { finished = true; inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return input
                } catch {
                    readError = error; inputStatus.pointee = .endOfStream; return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if status == .error { throw LocalIntelligenceError.invalidAudio }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                block.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
                if block.count >= blockSize {
                    total += block.count
                    try body(block)
                    block.removeAll(keepingCapacity: true)
                }
            }
            if status == .endOfStream || (status == .inputRanDry && finished) { break }
        }
        if !block.isEmpty { total += block.count; try body(block) }
        return total
    }

    /// Writes `url` as a 16 kHz mono file at `destination` (for decoders that read only one channel).
    static func writeMonoCopy(of url: URL, to destination: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw LocalIntelligenceError.invalidAudio
        }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try read(url: url) { samples in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw LocalIntelligenceError.invalidAudio
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            try output.write(from: buffer)
        }
    }

    /// The recording's length in seconds and channel count, without decoding it.
    static func describe(_ url: URL) throws -> (duration: Double, channels: Int) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { throw LocalIntelligenceError.invalidAudio }
        return (Double(file.length) / rate, Int(file.processingFormat.channelCount))
    }
}
