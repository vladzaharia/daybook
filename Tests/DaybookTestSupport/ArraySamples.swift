import DaybookCore
import Foundation

/// Samples in memory, read as a file would be: synthetic signals for the echo remover's tests.
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

/// Samples written to memory.
public final class ArraySampleSink: PCMSampleSink {
    public private(set) var samples: [Float] = []
    public init() {}
    public func write(_ samples: UnsafePointer<Float>, count: Int) throws {
        self.samples.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
    }
}
