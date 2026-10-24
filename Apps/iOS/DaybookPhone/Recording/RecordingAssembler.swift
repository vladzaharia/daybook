import AVFoundation
import DaybookCore
import Foundation

/// Turns a recording's segments into the one M4A the library keeps, whose timeline is the
/// conversation's: notes, bookmarks, and multipoint alignment all use one clock.
///
/// - One cleanly finished segment that starts at zero (the usual recording) is moved into place
///   untouched: no second encode.
/// - Otherwise (an interruption, a media-services reset, or a crash) the segments are decoded,
///   placed at their offsets with silence in the gaps, and encoded once. The originals are kept
///   until the library has filed the result.
enum RecordingAssembler {
    struct Piece: Sendable {
        var url: URL
        var startOffset: TimeInterval
        var cleanlyClosed: Bool
    }

    struct Result: Sendable {
        var frames: Int64
        var joined: Bool
        var warnings: [String]
    }

    static func assemble(_ pieces: [Piece], into output: URL, format: RecordingFormat) throws -> Result {
        let sorted = pieces.sorted { $0.startOffset < $1.startOffset }
        var warnings: [String] = []
        // Keep only segments with readable audio. A crash before the first fragment leaves nothing.
        var readable: [(piece: Piece, file: AVAudioFile)] = []
        for piece in sorted {
            guard FileManager.default.fileExists(atPath: piece.url.path) else { continue }
            do {
                let file = try AVAudioFile(forReading: piece.url, commonFormat: .pcmFormatFloat32, interleaved: false)
                if file.length > 0 { readable.append((piece, file)) }
            } catch {
                warnings.append("Part of the recording couldn't be read and was left out (\(piece.url.lastPathComponent)).")
            }
        }
        guard !readable.isEmpty else { throw PhoneRecorderError.nothingRecorded }

        if readable.count == 1, let only = readable.first, only.piece.cleanlyClosed,
           abs(only.piece.startOffset) < 1 / format.sampleRate,
           only.file.processingFormat.sampleRate == format.sampleRate {
            let frames = only.file.length
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: only.piece.url, to: output)
            return Result(frames: frames, joined: false, warnings: warnings)
        }

        let staged = output.deletingLastPathComponent().appendingPathComponent(".joining-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: staged) }
        let writer = try AACSegmentWriter(url: staged, format: format, realTime: false, fragmented: false)
        let target = format.pcmFormat
        let chunk: AVAudioFrameCount = 48_000
        do {
            for (piece, file) in readable {
                let start = Int64((piece.startOffset * format.sampleRate).rounded())
                if start > writer.framesWritten { try writer.appendSilence(frames: start - writer.framesWritten) }
                // A segment can't overlap the previous one; if clocks disagree, the earlier audio wins.
                var skip = max(0, writer.framesWritten - start)
                let converter = file.processingFormat == target ? nil : AVAudioConverter(from: file.processingFormat, to: target)
                if converter == nil, file.processingFormat != target { throw PhoneRecorderError.encoderUnavailable("join format") }
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { continue }
                while file.framePosition < file.length {
                    try file.read(into: input, frameCount: chunk)
                    guard input.frameLength > 0 else { break }
                    var buffer = input
                    if let converter { buffer = try convert(input, with: converter, to: target) }
                    if skip > 0 {
                        let drop = min(skip, Int64(buffer.frameLength))
                        skip -= drop
                        guard drop < Int64(buffer.frameLength) else { continue }
                        buffer = try tail(of: buffer, dropping: AVAudioFrameCount(drop))
                    }
                    try writer.append(buffer)
                }
            }
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: staged, to: output)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return Result(frames: writer.framesWritten, joined: true, warnings: warnings)
    }

    private static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw PhoneRecorderError.encoderUnavailable("join buffer") }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? PhoneRecorderError.encoderUnavailable("join convert") }
        return output
    }

    private static func tail(of buffer: AVAudioPCMBuffer, dropping frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let count = buffer.frameLength - frames
        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let source = buffer.floatChannelData, let destination = output.floatChannelData else {
            throw PhoneRecorderError.encoderUnavailable("join trim")
        }
        output.frameLength = count
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + Int(frames), count: Int(count))
        }
        return output
    }
}

/// Builds the finished recording from its journal, after Stop or when recovering after a crash.
enum PhoneCaptureFinisher {
    static func finish(_ journal: inout PhoneCaptureJournal, in directory: URL, recovered: Bool) throws -> PhoneRecording {
        let output = directory.appendingPathComponent(PhoneCaptureJournal.finalFileName)
        let format = journal.format
        if journal.finalFile == nil {
            let pieces = journal.segments.map {
                RecordingAssembler.Piece(url: directory.appendingPathComponent($0.fileName), startOffset: $0.startOffset, cleanlyClosed: $0.closed)
            }
            let segmentsOnDisk = pieces.contains { FileManager.default.fileExists(atPath: $0.url.path) }
            if !segmentsOnDisk, let existing = try? AVAudioFile(forReading: output), existing.length > 0 {
                // Assembled before, but the journal didn't record it before Daybook quit.
                journal.finalFile = .init(fileName: output.lastPathComponent, frameCount: existing.length, joined: journal.segments.count > 1)
            } else {
                let result = try RecordingAssembler.assemble(pieces, into: output, format: format)
                journal.finalFile = .init(fileName: output.lastPathComponent, frameCount: result.frames, joined: result.joined)
                // Joined segments stay beside the result until the library files it and removes the folder.
                journal.warnings += result.warnings
            }
            if recovered {
                journal.warnings.append("Daybook quit while recording. The recording was recovered; the last seconds may be missing.")
            }
            journal.state = .stopped
            try journal.write(to: directory)
        }
        guard let final = journal.finalFile else { throw PhoneRecorderError.nothingRecorded }
        let duration = Double(final.frameCount) / format.sampleRate
        let startedAt = journal.startedAt ?? journal.createdAt
        return PhoneRecording(
            id: journal.id, title: journal.title, audioURL: directory.appendingPathComponent(final.fileName),
            startedAt: startedAt, endedAt: journal.endedAt ?? startedAt.addingTimeInterval(duration), duration: duration,
            hostTimeSeconds: journal.hostTimeSeconds, notes: journal.notes, timedNotes: journal.timedNotes,
            highlights: journal.highlights, capture: captureDetails(journal, joined: final.joined),
            warnings: journal.warnings.uniqued(),
            stagingDirectory: directory, recovered: recovered)
    }

    /// How the phone captured the track, in the library's terms.
    static func captureDetails(_ journal: PhoneCaptureJournal, joined: Bool) -> TrackCaptureDetails {
        var notes: [String] = []
        for route in journal.routes where route.reason != "start" {
            notes.append("At \(TimeLabel.short(route.time)) the microphone became \(route.input?.name ?? "unavailable") (\(route.reason)).")
        }
        for pause in journal.interruptions {
            let end = pause.resumed == true ? (journal.segments.first { $0.startOffset > pause.began }?.startOffset ?? pause.ended) : nil
            let span = end.map { "\(TimeLabel.short(pause.began))–\(TimeLabel.short($0))" } ?? "from \(TimeLabel.short(pause.began))"
            notes.append("Paused \(span)\(pause.reason.map { " (\($0))" } ?? ""); the gap is silent.")
        }
        notes += journal.segments.flatMap { $0.notes ?? [] }
        if joined { notes.append("Joined from \(journal.segments.count) parts.") }
        let start = journal.routes.first { $0.reason == "start" }?.input?.name
        return TrackCaptureDetails(method: "iphone-microphone", clockRate: clockRate(journal.segments.first, sampleRate: journal.sampleRate),
                                   outputRoute: nil, notes: ([start.map { "Recorded with \($0)." }].compactMap { $0 } + notes).nilIfEmpty)
    }

    /// Conversation seconds per track second, from the first segment's clock anchors, once there's
    /// enough of a run to measure (`meetingTime = offset + trackTime × clockRate`).
    static func clockRate(_ segment: CaptureSegment?, sampleRate: Double) -> Double? {
        guard let segment, let first = segment.clockAnchors.first, let last = segment.clockAnchors.last,
              last.hostTime - first.hostTime >= 30, !segment.clockAnchors.contains(where: { $0.resync == true }) else { return nil }
        let seconds = Double(last.frame - first.frame) / sampleRate
        let rate = (last.hostTime - first.hostTime) / seconds
        return rate.isFinite && abs(rate - 1) < 0.01 ? rate : nil
    }
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

extension Array where Element: Hashable {
    /// The elements in order, without repeats.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
