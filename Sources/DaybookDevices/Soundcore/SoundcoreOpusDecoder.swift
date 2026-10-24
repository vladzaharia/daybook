import AVFoundation
import AudioToolbox
import Foundation

/// D3200's documented transport carries one padded 20 ms Opus packet per
/// 160-byte audio slice. Decode with the macOS codec directly into a local WAV.
public final class SoundcoreOpusDecoder {
    private let converter: AVAudioConverter
    private let compressedFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var file: AVAudioFile?
    public private(set) var sampleCount: Int64 = 0
    public var onPCM: ((AVAudioPCMBuffer) -> Void)?

    public init(outputURL: URL) throws {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let compressed = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: compressed, to: pcm) else { throw SoundcoreError.codecUnavailable }
        self.converter = converter; self.compressedFormat = compressed; self.outputFormat = pcm
        file = try AVAudioFile(forWriting: outputURL, settings: pcm.settings)
    }

    public func append(_ paddedPacket: Data) throws {
        guard paddedPacket.count == 160, file != nil else { throw SoundcoreError.corruptAudio }
        var packet = paddedPacket
        while packet.count > 1 && packet.last == 0 { packet.removeLast() }
        let compressed = AVAudioCompressedBuffer(format: compressedFormat, packetCapacity: 1, maximumPacketSize: 160)
        packet.withUnsafeBytes { bytes in compressed.data.copyMemory(from: bytes.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0,
            mVariableFramesInPacket: 960, mDataByteSize: UInt32(packet.count))
        var supplied = false
        var rounds = 0
        repeat {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1_920) else { throw SoundcoreError.corruptAudio }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return compressed
            }
            if let conversionError { throw conversionError }
            if status == .error { throw SoundcoreError.corruptAudio }
            if output.frameLength > 0 {
                guard let floats = output.floatChannelData?[0],
                      UnsafeBufferPointer(start: floats, count: Int(output.frameLength)).allSatisfy(\.isFinite) else {
                    throw SoundcoreError.corruptAudio
                }
                try file?.write(from: output)
                sampleCount += Int64(output.frameLength)
                onPCM?(output)
            }
            if status == .inputRanDry || status == .endOfStream { return }
            rounds += 1
        } while rounds < 8
        throw SoundcoreError.corruptAudio
    }

    public func finish() throws {
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1_920) else { throw SoundcoreError.corruptAudio }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream; return nil
            }
            if let error { throw error }
            if status == .error { throw SoundcoreError.corruptAudio }
            if output.frameLength > 0 { try file?.write(from: output); sampleCount += Int64(output.frameLength) }
            if status == .endOfStream { file = nil; return }
        }
        throw SoundcoreError.corruptAudio
    }
}
