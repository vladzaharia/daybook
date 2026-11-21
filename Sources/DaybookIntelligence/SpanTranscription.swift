import AVFoundation
import DaybookCore
import DaybookKit
import Foundation

/// Transcribes stretches of a recording the way processing hears it: the recording through `LevelledAudio` (its 16 kHz
/// mono rendering raised to a normal level when it's far quieter, as processing does), cut to each span, through the
/// same model. For Compress Older Recordings' transcript quality bar (`TranscriptAgreement`), which compares an original
/// with its copy span by span.
public enum SpanTranscription {
    /// One transcript per span, in order. The recording is only read; everything made for this goes with it. Cancellable.
    public static func transcribe(_ url: URL, spans: [ClosedRange<TimeInterval>], inference: any MeetingInference,
                                  model: ModelReference, language: String?) async throws -> [String] {
        let audio = try await detachedWork(priority: .utility) { try LevelledAudio.prepare(url) }
        defer { audio.remove() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("daybook-spans-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var texts: [String] = []
        for (index, span) in spans.enumerated() {
            try Task.checkCancellation()
            let slice = folder.appendingPathComponent("span-\(index).caf")
            let source = audio.url
            try await detachedWork(priority: .utility) { try cut(source, span, to: slice) }
            let result = try await inference.transcribe(url: slice, model: model, glossary: [], language: language) { _ in }
            texts.append(result.segments.map(\.text).joined(separator: " "))
            try? FileManager.default.removeItem(at: slice)
        }
        return texts
    }

    /// Writes `span` of `url` to `destination` in the file's own processing format.
    static func cut(_ url: URL, _ span: ClosedRange<TimeInterval>, to destination: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, span.lowerBound) * rate)
        let end = min(file.length, AVAudioFramePosition(span.upperBound * rate))
        guard end > start else { throw CocoaError(.fileReadCorruptFile) }
        file.framePosition = start
        let output = try AVAudioFile(forWriting: destination, settings: file.processingFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768) else { throw CocoaError(.fileReadCorruptFile) }
        var remaining = end - start
        while remaining > 0 {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining)))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }
}
