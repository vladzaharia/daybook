import AVFoundation
import Foundation

/// Cutting a voice clip (`VoiceClips`) from a lossless original, and proving it holds the original's samples exactly.
public enum VoiceClipAudio {
    /// A clip made and checked, hidden in the folder it goes to under `VoiceClips.temporaryPrefix`.
    public struct Extracted: Sendable {
        public var url: URL
        public var sha256: String
        public var size: Int64
        public var sampleRate: Double
        public var channels: Int
        public var ranges: [VoiceClipRange]
    }

    /// Why a clip wasn't made. Any of them leaves the original as the only copy of that speech, so it's kept.
    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable
        case unsupportedLayout
        case nothingToCut
        case shortRead
        /// The clip read back isn't the original's samples, bit for bit.
        case differs

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The recording couldn't be read for its voice clip."
            case .unsupportedLayout: return "The recording has more channels than a voice clip keeps."
            case .nothingToCut: return "The speaker's passages aren't in the recording."
            case .shortRead: return "The recording ended before a passage of its voice clip."
            case .differs: return "The voice clip read back differs from the recording."
            }
        }
    }

    /// The frames of `spans` in a file of `length` frames at `rate`: each span's start rounded down and end rounded up to
    /// a frame, clamped to the file; spans that fall outside it, or come to nothing, are left out.
    public static func ranges(_ spans: [VoiceClipSpan], rate: Double, length: Int64) -> [VoiceClipRange] {
        spans.compactMap { span in
            let start = max(0, Int64((span.start * rate).rounded(.down)))
            let end = min(length, Int64((span.end * rate).rounded(.up)))
            return end > start ? VoiceClipRange(startFrame: start, endFrame: end) : nil
        }
    }

    /// Cuts `spans` of `original` into one clip in `folder` (Linear PCM, 32-bit float, the original's rate and channels,
    /// the passages back to back), flushes it, reads it back and compares every sample with the original's bit for bit,
    /// then hashes it. Every frame a span asks for must be delivered. Off the caller's actor; cancellable. Anything short
    /// of an exact clip throws, and leaves nothing behind.
    public static func extract(from original: URL, spans: [VoiceClipSpan], into folder: URL) async throws -> Extracted {
        let temporary = folder.appendingPathComponent("\(VoiceClips.temporaryPrefix)\(UUID().uuidString).caf")
        do {
            return try await BlockingFileWork.run { isCancelled in
                let (rate, channels, ranges) = try write(original, spans: spans, to: temporary, isCancelled: isCancelled)
                try DurableFiles.synchronize([temporary])
                try verify(clip: temporary, original: original, ranges: ranges, rate: rate, channels: channels, isCancelled: isCancelled)
                let digest = try AudioDigest.sha256(fileURL: temporary, isCancelled: isCancelled)
                let size = Int64((try? temporary.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                return Extracted(url: temporary, sha256: digest, size: size, sampleRate: rate, channels: channels, ranges: ranges)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static let chunkFrames: AVAudioFrameCount = 32_768

    private static func clipFormat(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)
    }

    private static func write(_ original: URL, spans: [VoiceClipSpan], to destination: URL,
                              isCancelled: () -> Bool) throws -> (Double, Int, [VoiceClipRange]) {
        let source: AVAudioFile
        do { source = try AVAudioFile(forReading: original, commonFormat: .pcmFormatFloat32, interleaved: false) } catch { throw Failure.unreadable }
        let rate = source.processingFormat.sampleRate, channels = source.processingFormat.channelCount
        guard channels >= 1, channels <= 2 else { throw Failure.unsupportedLayout }
        let ranges = ranges(spans, rate: rate, length: source.length)
        guard !ranges.isEmpty, let format = clipFormat(rate: rate, channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunkFrames) else { throw Failure.nothingToCut }
        // Closed (and its header written) at the end of this scope, before it's flushed.
        do {
            let clip = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try read(source, ranges: ranges, into: buffer, isCancelled: isCancelled) { try clip.write(from: $0) }
        }
        return (rate, Int(channels), ranges)
    }

    /// Reads each range of `file` in chunks into `buffer`, handing every chunk to `body`. A read may deliver fewer frames
    /// than asked (measured: 32,320 of 32,768 from a CAF), so each chunk is what it delivered; a read that fails or
    /// delivers nothing before the range ends is `shortRead`.
    private static func read(_ file: AVAudioFile, ranges: [VoiceClipRange], into buffer: AVAudioPCMBuffer, isCancelled: () -> Bool,
                             _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        for range in ranges {
            file.framePosition = range.startFrame
            var remaining = range.frames
            while remaining > 0 {
                if isCancelled() { throw CancellationError() }
                let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
                do { try autoreleasepool { try file.read(into: buffer, frameCount: count) } } catch { throw Failure.shortRead }
                guard buffer.frameLength > 0, buffer.frameLength <= count else { throw Failure.shortRead }
                try body(buffer)
                remaining -= Int64(buffer.frameLength)
            }
        }
    }

    /// Reads exactly `count` frames of `file` from where it is into `buffer` (at least that capacity), read by read.
    private static func readExactly(_ file: AVAudioFile, _ count: AVAudioFrameCount, into buffer: AVAudioPCMBuffer,
                                    scratch: AVAudioPCMBuffer) throws {
        guard let target = buffer.floatChannelData, let source = scratch.floatChannelData, buffer.frameCapacity >= count else { throw Failure.unreadable }
        let channels = Int(buffer.format.channelCount)
        var filled: AVAudioFrameCount = 0
        while filled < count {
            let want = min(count - filled, scratch.frameCapacity)
            do { try autoreleasepool { try file.read(into: scratch, frameCount: want) } } catch { throw Failure.shortRead }
            let got = scratch.frameLength
            guard got > 0, got <= want else { throw Failure.shortRead }
            for channel in 0..<channels { (target[channel] + Int(filled)).update(from: source[channel], count: Int(got)) }
            filled += got
        }
        buffer.frameLength = count
    }

    /// The clip opens as what was written (32-bit float Linear PCM, the original's rate and channels), holds exactly the
    /// ranges' frames, and each of its samples has the bit pattern of the original's.
    static func verify(clip url: URL, original: URL, ranges: [VoiceClipRange], rate: Double, channels: Int, isCancelled: () -> Bool) throws {
        let clip: AVAudioFile, source: AVAudioFile
        do {
            clip = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            source = try AVAudioFile(forReading: original, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { throw Failure.unreadable }
        let description = clip.fileFormat.streamDescription.pointee
        guard description.mFormatID == kAudioFormatLinearPCM, description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mBitsPerChannel == 32, clip.fileFormat.sampleRate == rate, Int(clip.fileFormat.channelCount) == channels,
              source.processingFormat.sampleRate == rate, Int(source.processingFormat.channelCount) == channels,
              clip.length == ranges.reduce(0, { $0 + $1.frames }) else { throw Failure.differs }
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunkFrames),
              let clipBuffer = AVAudioPCMBuffer(pcmFormat: clip.processingFormat, frameCapacity: chunkFrames),
              let scratch = AVAudioPCMBuffer(pcmFormat: clip.processingFormat, frameCapacity: chunkFrames) else { throw Failure.unreadable }
        clip.framePosition = 0
        try read(source, ranges: ranges, into: sourceBuffer, isCancelled: isCancelled) { chunk in
            let count = chunk.frameLength
            try readExactly(clip, count, into: clipBuffer, scratch: scratch)
            guard let a = chunk.floatChannelData, let b = clipBuffer.floatChannelData else { throw Failure.differs }
            for channel in 0..<channels {
                for index in 0..<Int(count) where a[channel][index].bitPattern != b[channel][index].bitPattern { throw Failure.differs }
            }
        }
        guard clip.framePosition == clip.length else { throw Failure.differs }
    }
}
