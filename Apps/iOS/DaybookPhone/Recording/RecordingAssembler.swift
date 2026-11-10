import AVFoundation
import CoreMedia
import DaybookCore
import DaybookKit
import Foundation

/// Turns a recording's segments into the one M4A the library keeps, whose timeline is the
/// conversation's: notes, bookmarks, and multipoint alignment all use one clock. The audio stays as it
/// was captured (AGENTS.md, "Preserve originals"):
///
/// - One cleanly finished segment that starts at zero (the usual recording) is moved into place
///   untouched.
/// - Otherwise (an interruption, a media-services reset, or a crash) the segments' AAC packets are
///   copied into one file, byte for byte (`passthrough`): each segment at its offset, with AAC silence,
///   encoded once, in the gaps. A later segment keeps its encoder priming (2,112 frames), which plays
///   inside the gap before it, so that silence is shorter by as much and every part lands within one
///   AAC frame (21 ms) of where it was recorded. Joining is a copy: seconds for hours of audio.
/// - Segments in different formats (none are written so today) are decoded, placed, and encoded once
///   instead (`reencode`), which takes a while for a long recording (`expectsLongJoin`).
///
/// The segments are kept until the library has filed the result.
enum RecordingAssembler {
    struct Piece: Sendable {
        var url: URL
        var startOffset: TimeInterval
        var cleanlyClosed: Bool
    }

    struct Result: Sendable {
        var frames: Int64
        var joined: Bool
        /// Decoded and encoded again, because the segments' formats differed.
        var reencoded = false
        var warnings: [String]
    }

    /// An AAC-LC packet's frames.
    static let packetFrames: Int64 = 1024
    /// A join that must encode again is long from this much audio: past what a background task's
    /// time is sure to cover.
    static let longJoin: TimeInterval = 600

    /// Throws `PhoneRecorderError.locked` when a segment is there but can't be read until the iPhone is unlocked
    /// (`StagingProtection`), or it locked as they were joined: never `nothingRecorded` for audio it couldn't open.
    static func assemble(_ pieces: [Piece], into output: URL, format: RecordingFormat,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let (readable, warnings) = try readablePieces(pieces)
        guard !readable.isEmpty else { throw PhoneRecorderError.nothingRecorded }

        if readable.count == 1, let only = readable.first, only.piece.cleanlyClosed,
           abs(only.piece.startOffset) < 1 / format.sampleRate,
           only.file.processingFormat.sampleRate == format.sampleRate {
            let frames = only.file.length
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: only.piece.url, to: output)
            return Result(frames: frames, joined: false, warnings: warnings)
        }

        // Locked partway, a join stops rather than encode again what it couldn't copy.
        let folder = output.deletingLastPathComponent()
        if copiesPackets(readable.map(\.file), format: format) {
            do {
                let frames = try await passthrough(readable.map(\.piece), into: output, format: format)
                return Result(frames: frames, joined: true, warnings: warnings)
            } catch {
                if !StagingProtection.canReadAll(in: folder) { throw PhoneRecorderError.locked }
            }
        }
        do {
            let frames = try reencode(readable, into: output, format: format, progress: progress)
            return Result(frames: frames, joined: true, reencoded: true, warnings: warnings)
        } catch {
            throw StagingProtection.canReadAll(in: folder) ? error : PhoneRecorderError.locked
        }
    }

    /// Whether joining `pieces` will decode and encode them again (their formats differ) with more than
    /// `longJoin` of audio: Stop then asks iOS for time to finish it in the background.
    static func expectsLongJoin(_ pieces: [Piece], format: RecordingFormat, longerThan long: TimeInterval = longJoin) -> Bool {
        guard let (readable, _) = try? readablePieces(pieces),
              readable.count > 1 || readable.first?.piece.cleanlyClosed == false, !copiesPackets(readable.map(\.file), format: format),
              let last = readable.last else { return false }
        return last.piece.startOffset + Double(last.file.length) / format.sampleRate > long
    }

    /// The segments with readable audio, in order. A crash before the first fragment leaves nothing. Throws
    /// `PhoneRecorderError.locked` when one is there but can't be opened now: none is left out for that.
    private static func readablePieces(_ pieces: [Piece]) throws -> ([(piece: Piece, file: AVAudioFile)], [String]) {
        var readable: [(piece: Piece, file: AVAudioFile)] = []
        var warnings: [String] = []
        for piece in pieces.sorted(by: { $0.startOffset < $1.startOffset }) {
            guard FileManager.default.fileExists(atPath: piece.url.path) else { continue }
            if StagingProtection.cannotOpen(piece.url) { throw PhoneRecorderError.locked }
            do {
                let file = try AVAudioFile(forReading: piece.url, commonFormat: .pcmFormatFloat32, interleaved: false)
                if file.length > 0 { readable.append((piece, file)) }
            } catch {
                warnings.append("Part of the recording couldn’t be read and was left out (\(piece.url.lastPathComponent)).")
            }
        }
        return (readable, warnings)
    }

    /// Every segment is the recording's AAC, so their packets go into one file as they are.
    private static func copiesPackets(_ files: [AVAudioFile], format: RecordingFormat) -> Bool {
        files.allSatisfy { file in
            let description = file.fileFormat.streamDescription.pointee
            return description.mFormatID == kAudioFormatMPEG4AAC && Int64(description.mFramesPerPacket) == packetFrames
                && description.mSampleRate == format.sampleRate && description.mChannelsPerFrame == 1
        }
    }

    // MARK: Passthrough

    /// Copies each segment's packets into `output` in order, at its offset, with encoded silence between them, and
    /// returns the file's frames. Throws (and the join encodes again instead) when a segment can't be read as packets or
    /// isn't in the recording's format.
    ///
    /// The file's stream is whole packets. The first segment's priming is trimmed (the edit list), so stream frame
    /// `t + priming` is conversation frame `t`. A later segment's first packet goes where its own priming ends at its
    /// offset: silence packets fill up to there, rounded to the nearest packet; a segment that starts before the stream
    /// has reached it (clocks that disagree) loses as many of its first packets, and the earlier audio wins. Only the
    /// last segment's remainder (the frames padding its last packet) is trimmed.
    private static func passthrough(_ pieces: [Piece], into output: URL, format: RecordingFormat) async throws -> Int64 {
        let folder = output.deletingLastPathComponent()
        let silence = try await silencePacket(format: format, in: folder)
        let staged = folder.appendingPathComponent(".joining-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: staged) }
        let writer = try AVAssetWriter(outputURL: staged, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: silence.format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw PhoneRecorderError.encoderUnavailable("join input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PhoneRecorderError.encoderUnavailable("join start") }
        writer.startSession(atSourceTime: .zero)
        var stream = PacketStream(writer: writer, input: input, format: silence.format, sampleRate: format.sampleRate)
        do {
            for (index, piece) in pieces.enumerated() {
                let reader = try await PacketReader(url: piece.url, matching: silence.format)
                let priming = reader.priming
                if index == 0 { stream.trim = priming }
                let start = Int64((piece.startOffset * format.sampleRate).rounded())
                let ahead = start + stream.trim - priming - stream.frames
                var drop = 0
                if ahead >= 0 {
                    try await stream.appendSilence(silence.packet, count: Int((Double(ahead) / Double(packetFrames)).rounded()))
                } else {
                    drop = Int((Double(-ahead) / Double(packetFrames)).rounded())
                }
                let last = index == pieces.count - 1
                while let run = try reader.next() {
                    let kept = Array(run.packets.dropFirst(drop))
                    drop = max(0, drop - run.packets.count)
                    guard !kept.isEmpty else { continue }
                    try await stream.append(kept, trimmingEnd: last ? run.remainder : 0)
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? PhoneRecorderError.encoderUnavailable("join finish") }
        } catch {
            writer.cancelWriting()
            throw error
        }
        // What the file holds, as the library reads it: priming and remainder trimmed.
        let frames = try AVAudioFile(forReading: staged).length
        guard frames > 0 else { throw PhoneRecorderError.nothingRecorded }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: staged, to: output)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return frames
    }

    /// One packet of digital silence in the recording's format, encoded once (a moment of it, its middle packet,
    /// clear of the encoder's start and end), with the format the joined file is written in.
    private static func silencePacket(format: RecordingFormat, in folder: URL) async throws -> (packet: Data, format: CMAudioFormatDescription) {
        let url = folder.appendingPathComponent(".silence-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AACSegmentWriter(url: url, format: format, realTime: false, fragmented: false)
        do {
            try writer.appendSilence(frames: Int64(format.sampleRate / 2))
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        let reader = try await PacketReader(url: url, matching: nil)
        var packets: [Data] = []
        while let run = try reader.next() { packets += run.packets }
        guard packets.count > 4 else { throw PhoneRecorderError.encoderUnavailable("silence") }
        return (packets[packets.count / 2], reader.format)
    }

    /// The joined file's packets as they're appended: positions on the stream, the first segment's priming trimmed
    /// at its start, and each buffer's timestamp where the stream has got to.
    private struct PacketStream {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let format: CMAudioFormatDescription
        let sampleRate: Double
        /// Frames appended so far, in whole packets.
        var frames: Int64 = 0
        /// The first segment's priming, trimmed from the start of the file.
        var trim: Int64 = 0
        /// Priming still to trim from the next buffers.
        private var trimLeft: Int64?

        init(writer: AVAssetWriter, input: AVAssetWriterInput, format: CMAudioFormatDescription, sampleRate: Double) {
            self.writer = writer; self.input = input; self.format = format; self.sampleRate = sampleRate
        }

        /// `count` silence packets, in buffers of up to a second's.
        mutating func appendSilence(_ packet: Data, count: Int) async throws {
            var left = count
            let batch = Int(sampleRate / Double(packetFrames))
            while left > 0 {
                let size = min(batch, left)
                try await append(Array(repeating: packet, count: size), trimmingEnd: 0)
                left -= size
            }
        }

        mutating func append(_ packets: [Data], trimmingEnd remainder: Int64) async throws {
            guard !packets.isEmpty else { return }
            let length = Int64(packets.count) * RecordingAssembler.packetFrames
            // Output timestamps start at zero once the priming is trimmed (AVAssetWriterInput's rule for trimmed audio).
            let buffer = try Self.buffer(packets, format: format, at: CMTime(value: frames - trim, timescale: CMTimeScale(sampleRate)))
            let left = trimLeft ?? trim
            if left > 0 { Self.attach(kCMSampleBufferAttachmentKey_TrimDurationAtStart, min(left, length), to: buffer, sampleRate: sampleRate) }
            trimLeft = max(0, left - length)
            if remainder > 0 { Self.attach(kCMSampleBufferAttachmentKey_TrimDurationAtEnd, min(remainder, length), to: buffer, sampleRate: sampleRate) }
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? PhoneRecorderError.encoderUnavailable("join writer") }
                guard Date() < deadline else { throw PhoneRecorderError.diskBacklog }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard input.append(buffer) else { throw writer.error ?? PhoneRecorderError.encoderUnavailable("join append") }
            frames += length
        }

        private static func attach(_ key: CFString, _ frames: Int64, to buffer: CMSampleBuffer, sampleRate: Double) {
            let duration = CMTimeCopyAsDictionary(CMTime(value: frames, timescale: CMTimeScale(sampleRate)), allocator: kCFAllocatorDefault)
            CMSetAttachment(buffer, key: key, value: duration, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        }

        /// A buffer of `packets`, one after another in one block.
        private static func buffer(_ packets: [Data], format: CMAudioFormatDescription, at time: CMTime) throws -> CMSampleBuffer {
            var bytes = Data()
            var descriptions: [AudioStreamPacketDescription] = []
            descriptions.reserveCapacity(packets.count)
            for packet in packets {
                descriptions.append(AudioStreamPacketDescription(mStartOffset: Int64(bytes.count), mVariableFramesInPacket: 0,
                                                                 mDataByteSize: UInt32(packet.count)))
                bytes.append(packet)
            }
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                                            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                            blockBufferOut: &block)
            guard status == noErr, let block else { throw PhoneRecorderError.encoderUnavailable("join block \(status)") }
            status = bytes.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count)
            }
            guard status == noErr else { throw PhoneRecorderError.encoderUnavailable("join bytes \(status)") }
            var buffer: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                         formatDescription: format, sampleCount: packets.count,
                                                                         presentationTimeStamp: time, packetDescriptions: descriptions,
                                                                         sampleBufferOut: &buffer)
            guard status == noErr, let buffer else { throw PhoneRecorderError.encoderUnavailable("join buffer \(status)") }
            return buffer
        }
    }

    // MARK: Decoding and encoding again

    /// Decodes the segments, places them at their offsets with silence in the gaps, and encodes them once: for
    /// segments whose formats differ. Returns the frames written.
    private static func reencode(_ readable: [(piece: Piece, file: AVAudioFile)], into output: URL, format: RecordingFormat,
                                 progress: @Sendable (Double) -> Void) throws -> Int64 {
        let staged = output.deletingLastPathComponent().appendingPathComponent(".joining-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: staged) }
        let writer = try AACSegmentWriter(url: staged, format: format, realTime: false, fragmented: false)
        let target = format.pcmFormat
        let chunk: AVAudioFrameCount = 48_000
        let total = readable.last.map { Double($0.piece.startOffset) * format.sampleRate + Double($0.file.length) } ?? 1
        var reported = -1
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
                    let percent = Int(Double(writer.framesWritten) / max(1, total) * 100)
                    if percent != reported {
                        reported = percent
                        progress(min(1, Double(percent) / 100))
                    }
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
        return writer.framesWritten
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

/// A segment's AAC packets as AVAssetReader hands them over, untouched (`outputSettings: nil`), with the frames its
/// encoder primed at the start and padded at the end (the file's edit list, as trim attachments).
final class PacketReader {
    /// Packets from one sample buffer, and the frames padding the last of them (`TrimDurationAtEnd`).
    struct Run {
        var packets: [Data]
        var remainder: Int64
    }

    let format: CMAudioFormatDescription
    /// The encoder's priming: frames at the start that aren't the recording's.
    private(set) var priming: Int64 = 0
    private let sampleRate: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var held: [Run] = []

    /// Opens `url` for its packets. With `matching`, a file in another format is refused (it can't share a file's
    /// packets with it).
    init(url: URL, matching expected: CMAudioFormatDescription?) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let format = try await track.load(.formatDescriptions).first else { throw PhoneRecorderError.nothingRecorded }
        if let expected, !CMAudioFormatDescriptionEqual(format, otherFormatDescription: expected,
                                                         equalityMask: kCMAudioFormatDescriptionMask_StreamBasicDescription
                                                             | kCMAudioFormatDescriptionMask_ChannelLayout, equalityMaskOut: nil) {
            throw PhoneRecorderError.encoderUnavailable("join format")
        }
        self.format = format
        sampleRate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate ?? 48_000
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PhoneRecorderError.encoderUnavailable("join reader") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? PhoneRecorderError.encoderUnavailable("join reader") }
        // The priming is marked on the first buffers: read up to the first that isn't all priming.
        while let run = try read(countingPriming: true) {
            held.append(run.run)
            if !run.primed { break }
        }
    }

    /// The next buffer's packets; nil at the end.
    func next() throws -> Run? {
        if !held.isEmpty { return held.removeFirst() }
        return try read(countingPriming: false)?.run
    }

    private func read(countingPriming: Bool) throws -> (run: Run, primed: Bool)? {
        while let buffer = output.copyNextSampleBuffer() {
            // Markers between fragments carry no audio.
            guard CMSampleBufferGetNumSamples(buffer) > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var primed = false
            if countingPriming, let start = trim(kCMSampleBufferAttachmentKey_TrimDurationAtStart, of: buffer) {
                priming += start
                primed = start >= Int64(CMSampleBufferGetNumSamples(buffer)) * RecordingAssembler.packetFrames
            }
            var pointer: UnsafePointer<AudioStreamPacketDescription>?
            var size = 0
            let status = CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer, packetDescriptionsPointerOut: &pointer, sizeOut: &size)
            guard status == noErr, let pointer else { throw PhoneRecorderError.encoderUnavailable("join packets \(status)") }
            let descriptions = UnsafeBufferPointer(start: pointer, count: size / MemoryLayout<AudioStreamPacketDescription>.stride)
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let copied = bytes.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            guard copied == noErr else { throw PhoneRecorderError.encoderUnavailable("join bytes \(copied)") }
            let packets = descriptions.map { bytes.subdata(in: Int($0.mStartOffset)..<Int($0.mStartOffset) + Int($0.mDataByteSize)) }
            let remainder = trim(kCMSampleBufferAttachmentKey_TrimDurationAtEnd, of: buffer) ?? 0
            return (Run(packets: packets, remainder: remainder), primed)
        }
        if reader.status == .failed { throw reader.error ?? PhoneRecorderError.encoderUnavailable("join read") }
        return nil
    }

    /// A trim attachment, in frames.
    private func trim(_ key: CFString, of buffer: CMSampleBuffer) -> Int64? {
        guard let value = CMGetAttachment(buffer, key: key, attachmentModeOut: nil) as? NSDictionary else { return nil }
        let time = CMTimeMakeFromDictionary(value)
        guard time.isValid, time.timescale > 0 else { return nil }
        return CMTimeConvertScale(time, timescale: CMTimeScale(sampleRate), method: .roundHalfAwayFromZero).value
    }
}

/// Builds the finished recording from its journal, after Stop or when recovering after a crash.
enum PhoneCaptureFinisher {
    /// The journal's segments, as the assembler takes them.
    static func pieces(_ journal: PhoneCaptureJournal, in directory: URL) -> [RecordingAssembler.Piece] {
        journal.segments.map {
            RecordingAssembler.Piece(url: directory.appendingPathComponent($0.fileName), startOffset: $0.startOffset, cleanlyClosed: $0.closed)
        }
    }

    /// `recovery`: how the run that made it ended, for a recording rebuilt at launch; nil after Stop. `progress` hears
    /// how far a join that encodes again has got.
    static func finish(_ journal: inout PhoneCaptureJournal, in directory: URL, recovery: PhoneRecording.Recovery?,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> PhoneRecording {
        let output = directory.appendingPathComponent(PhoneCaptureJournal.finalFileName)
        let format = journal.format
        if journal.finalFile == nil {
            let pieces = pieces(journal, in: directory)
            let segmentsOnDisk = pieces.contains { FileManager.default.fileExists(atPath: $0.url.path) }
            // Assembled before (a lone part moved into place), and unreadable until the iPhone is unlocked.
            if !segmentsOnDisk, StagingProtection.cannotOpen(output) { throw PhoneRecorderError.locked }
            if !segmentsOnDisk, let existing = try? AVAudioFile(forReading: output), existing.length > 0 {
                // Assembled before, but the journal didn't record it before Daybook quit.
                journal.finalFile = .init(fileName: output.lastPathComponent, frameCount: existing.length, joined: journal.segments.count > 1)
            } else {
                let result = try await RecordingAssembler.assemble(pieces, into: output, format: format, progress: progress)
                journal.finalFile = .init(fileName: output.lastPathComponent, frameCount: result.frames, joined: result.joined,
                                          reencoded: result.reencoded ? true : nil)
                // Joined segments stay beside the result until the library files it and removes the folder.
                journal.warnings += result.warnings
            }
            switch recovery {
            case .quitWhileRecording?: journal.warnings.append(RecordingWords.recoveredAfterQuit)
            case .interruptedWhileSaving?: journal.warnings.append(RecordingWords.savedAfterInterruptedSave)
            case nil: break
            }
            journal.state = .stopped
            try journal.write(to: directory)
        }
        guard let final = journal.finalFile else { throw PhoneRecorderError.nothingRecorded }
        let duration = Double(final.frameCount) / format.sampleRate
        let startedAt = journal.startedAt ?? journal.createdAt
        return PhoneRecording(
            id: journal.id, recordingID: journal.recordingID ?? journal.id, title: journal.title,
            audioURL: directory.appendingPathComponent(final.fileName),
            startedAt: startedAt, endedAt: journal.endedAt ?? startedAt.addingTimeInterval(duration), duration: duration,
            hostTimeSeconds: journal.hostTimeSeconds, notes: journal.notes, timedNotes: journal.timedNotes,
            highlights: journal.highlights, capture: captureDetails(journal, final: final),
            warnings: journal.warnings.uniqued(),
            stagingDirectory: directory, recovery: recovery, photos: journal.photos ?? [], ink: journal.ink ?? [], multipoint: journal.multipoint,
            sharedNotes: journal.sharedNotes ?? [], sharedBookmarks: journal.sharedBookmarks ?? [])
    }

    /// How the phone captured the track, in the library's terms.
    static func captureDetails(_ journal: PhoneCaptureJournal, final: PhoneCaptureJournal.FinalFile) -> TrackCaptureDetails {
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
        if final.joined {
            notes.append(final.reencoded == true ? "Joined from \(journal.segments.count) parts and encoded again."
                                                 : "Joined from \(journal.segments.count) parts.")
        }
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
