import AVFoundation
import Foundation

/// Sequential access to deinterleaved float PCM, from a file or memory.
public protocol PCMSampleSource: AnyObject {
    var sampleRate: Double { get }
    var channelCount: Int { get }
    var frameCount: Int64 { get }
    /// Reads up to `frames` frames from the current position into one pointer per channel.
    /// Returns the number read; 0 means the end.
    func read(frames: Int, into channels: [UnsafeMutablePointer<Float>]) throws -> Int
    func seek(toFrame frame: Int64) throws
}

/// In-memory source, used for synthetic signals and tests.
public final class ArraySampleSource: PCMSampleSource {
    public let sampleRate: Double
    public let channels: [[Float]]
    private var position = 0
    public var channelCount: Int { channels.count }
    public var frameCount: Int64 { Int64(channels.first?.count ?? 0) }

    public init(sampleRate: Double, channels: [[Float]]) {
        precondition(!channels.isEmpty && Set(channels.map(\.count)).count == 1)
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public convenience init(sampleRate: Double, mono: [Float]) { self.init(sampleRate: sampleRate, channels: [mono]) }

    public func read(frames: Int, into destination: [UnsafeMutablePointer<Float>]) throws -> Int {
        let count = max(0, min(frames, channels[0].count - position))
        guard count > 0 else { return 0 }
        for (index, channel) in channels.enumerated() where index < destination.count {
            channel.withUnsafeBufferPointer { source in
                destination[index].update(from: source.baseAddress! + position, count: count)
            }
        }
        position += count
        return count
    }

    public func seek(toFrame frame: Int64) throws { position = Int(max(0, min(frame, frameCount))) }
}

/// Reads an audio file through AVAudioFile as deinterleaved Float32. The file is opened read-only.
public final class AudioFileSampleSource: PCMSampleSource {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int64

    public init(url: URL, chunkFrames: AVAudioFrameCount = 16_384) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        frameCount = file.length
        guard sampleRate > 0, channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.buffer = buffer
    }

    public func read(frames: Int, into destination: [UnsafeMutablePointer<Float>]) throws -> Int {
        var total = 0
        while total < frames {
            let request = AVAudioFrameCount(min(frames - total, Int(buffer.frameCapacity)))
            buffer.frameLength = 0
            guard file.framePosition < file.length else { break }
            try file.read(into: buffer, frameCount: request)
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            for channel in 0..<min(channelCount, destination.count) {
                (destination[channel] + total).update(from: data[channel], count: count)
            }
            total += count
        }
        return total
    }

    public func seek(toFrame frame: Int64) throws { file.framePosition = max(0, min(frame, file.length)) }
}
