import AVFoundation
import CoreMedia
import Foundation

/// Encodes PCM to one AAC-LC M4A file with `AVAssetWriter`. Not thread-safe: one queue owns it.
///
/// **Crash safety.** With `movieFragmentInterval` set, the writer appends a self-describing movie
/// fragment every interval, so if the app is killed the file on disk opens and plays up to the
/// last fragment, with nothing to repair. A finished file is an ordinary M4A that `AVAudioFile`
/// reads sample-accurately (encoder priming is trimmed), which is how the Mac reads audio.
final class AACSegmentWriter {
    let url: URL
    let format: RecordingFormat
    /// Frames handed to the encoder so far (the file's duration once finished).
    private(set) var framesWritten: Int64 = 0
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let description: CMAudioFormatDescription
    private var pending: [CMSampleBuffer] = []
    private var finished = false
    private static let maxPending = 64

    init(url: URL, format: RecordingFormat, realTime: Bool, fragmented: Bool = true) throws {
        self.url = url
        self.format = format
        let pcm = format.pcmFormat
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: pcm.streamDescription, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else { throw PhoneRecorderError.encoderUnavailable("format \(status)") }
        self.description = description
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        if fragmented, format.fragmentInterval > 0 {
            writer.movieFragmentInterval = CMTime(seconds: format.fragmentInterval, preferredTimescale: 600)
        }
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: format.aacSettings)
        input.expectsMediaDataInRealTime = realTime
        guard writer.canAdd(input) else { throw PhoneRecorderError.encoderUnavailable("input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? PhoneRecorderError.encoderUnavailable("start")
        }
        writer.startSession(atSourceTime: .zero)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Appends audio in `format.pcmFormat`.
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard !finished, buffer.frameLength > 0 else { return }
        let sample = try sampleBuffer(buffer, at: framesWritten)
        framesWritten += Int64(buffer.frameLength)
        pending.append(sample)
        try drain()
        // The encoder fell behind (or this is an offline join running faster than real time):
        // wait for it on this queue rather than growing without bound.
        let deadline = Date().addingTimeInterval(10)
        while pending.count > Self.maxPending {
            guard Date() < deadline else { throw PhoneRecorderError.diskBacklog }
            usleep(1_000)
            try drain()
        }
    }

    /// Appends digital silence, used to keep the file's timeline equal to the conversation's.
    func appendSilence(frames: Int64) throws {
        var remaining = frames
        let chunk = Int64(format.sampleRate)
        while remaining > 0 {
            let count = min(chunk, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format.pcmFormat, frameCapacity: AVAudioFrameCount(count)) else {
                throw PhoneRecorderError.encoderUnavailable("silence")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let data = buffer.floatChannelData?[0] { data.update(repeating: 0, count: Int(count)) }
            try append(buffer)
            remaining -= count
        }
    }

    /// Writes everything and closes the file. Blocks the calling queue until the file is complete.
    @discardableResult
    func finish(timeout: TimeInterval = 20) throws -> Int64 {
        guard !finished else { return framesWritten }
        finished = true
        let deadline = Date().addingTimeInterval(timeout)
        while !pending.isEmpty {
            try drain()
            if pending.isEmpty { break }
            guard Date() < deadline else { throw PhoneRecorderError.diskBacklog }
            usleep(2_000)
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + timeout) == .success else { throw PhoneRecorderError.diskBacklog }
        if writer.status != .completed { throw writer.error ?? PhoneRecorderError.encoderUnavailable("finish") }
        return framesWritten
    }

    /// Stops without finalizing. The file keeps whatever fragments reached disk.
    func cancel() {
        guard !finished else { return }
        finished = true
        pending.removeAll()
        writer.cancelWriting()
    }

    private func drain() throws {
        if writer.status == .failed { throw writer.error ?? PhoneRecorderError.encoderUnavailable("writer") }
        while let first = pending.first, input.isReadyForMoreMediaData {
            guard input.append(first) else { throw writer.error ?? PhoneRecorderError.encoderUnavailable("append") }
            pending.removeFirst()
        }
    }

    private func sampleBuffer(_ buffer: AVAudioPCMBuffer, at frame: Int64) throws -> CMSampleBuffer {
        let rate = CMTimeScale(format.sampleRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
                                        presentationTimeStamp: CMTime(value: frame, timescale: rate),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var status = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: description, sampleCount: CMItemCount(buffer.frameLength),
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw PhoneRecorderError.encoderUnavailable("sample \(status)") }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                flags: 0, bufferList: buffer.audioBufferList)
        guard status == noErr else { throw PhoneRecorderError.encoderUnavailable("data \(status)") }
        return sample
    }
}
