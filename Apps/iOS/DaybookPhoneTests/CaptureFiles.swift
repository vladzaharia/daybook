import AVFoundation
import XCTest
@testable import DaybookPhone

/// Segment files as a crash leaves them, built on purpose: a part an interruption closed, and the
/// bytes of a part the recorder's encoder was still writing. Synthetic tones only.
@MainActor
enum CaptureFiles {
    /// The recorder's format with a fragment every second, so a few seconds of audio make several.
    static var format: RecordingFormat {
        var format = RecordingFormat.speech
        format.fragmentInterval = 1
        return format
    }

    /// One top-level MP4 box.
    struct Box: Equatable {
        var type: String
        var offset: Int
        var size: Int
        var end: Int { offset + size }
    }

    /// The top-level boxes of an MP4 file, in order; the last can run past the end of `data` when
    /// the file was cut while it was being written.
    static func boxes(_ data: Data) -> [Box] {
        let bytes = [UInt8](data)
        var boxes: [Box] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            var size = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            if size == 1, offset + 16 <= bytes.count { size = bytes[offset + 8..<offset + 16].reduce(0) { $0 << 8 | Int($1) } }
            if size == 0 { size = bytes.count - offset }
            guard size >= 8 else { break }
            boxes.append(Box(type: type, offset: offset, size: size))
            offset += size
        }
        return boxes
    }

    /// A tone, encoded and finished as a part an interruption closed. Returns its frames.
    @discardableResult
    static func writeClosedSegment(to url: URL, seconds: Double, frequency: Float) throws -> Int64 {
        let writer = try AACSegmentWriter(url: url, format: format, realTime: false)
        try append(tone: frequency, seconds: seconds, to: writer)
        return try writer.finish()
    }

    /// The bytes of a part still being written when the app was killed: `seconds` of a tone fed to the
    /// recorder's real-time encoder, read from disk once `fragments` movie fragments after the first
    /// are complete there. Its end is whatever the encoder was writing at that moment.
    static func inProgressSegment(seconds: Double, frequency: Float, fragments: Int = 2,
                                  in scratch: URL, test: XCTestCase) async throws -> Data {
        let url = scratch.appendingPathComponent("writing-\(UUID().uuidString).m4a")
        let writer = try AACSegmentWriter(url: url, format: format, realTime: true)
        defer { writer.cancel() }
        try append(tone: frequency, seconds: seconds, to: writer)
        var seen: [Box] = []
        return try await test.waitFor("\(fragments) movie fragments on disk", timeout: 30, poll: .milliseconds(20),
                                      state: { seen.map { "\($0.type)@\($0.offset)+\($0.size)" }.joined(separator: " ") }) { () -> Data? in
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            seen = boxes(bytes)
            return seen.filter { $0.type == "moof" && $0.end <= bytes.count }.count >= fragments ? bytes : nil
        }
    }

    /// Frames AVFoundation reads from these bytes as an M4A file (0 when it can't open them).
    static func readableFrames(_ bytes: Data, scratch: URL) throws -> Int64 {
        let url = scratch.appendingPathComponent("probe-\(UUID().uuidString).m4a")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? AVAudioFile(forReading: url))?.length ?? 0
    }

    private static func append(tone frequency: Float, seconds: Double, to writer: AACSegmentWriter) throws {
        let chunk: AVAudioFrameCount = 4_800
        let total = Int((seconds * format.sampleRate).rounded())
        var written = 0
        while written < total {
            let count = min(Int(chunk), total - written)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format.pcmFormat, frameCapacity: chunk))
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                buffer.floatChannelData![0][index] = 0.3 * sin(Float(written + index) * 2 * .pi * frequency / Float(format.sampleRate))
            }
            try writer.append(buffer)
            written += count
        }
    }
}
