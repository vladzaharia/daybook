import AVFoundation
import DaybookCore
import Foundation

/// The audio the speech models hear for one recording (docs/architecture.md, "Input levels"): the stored file itself, or,
/// when its speech is far quieter than a normal level (`SpeechLevel`), a copy raised by one constant gain. The copy keeps
/// the recording's sample rate, channels, and length, so every model reads, converts, and times it as it would the
/// original. It's the conversation's audio, so it's made where processing keeps such copies (`ProcessingScratch`) and is
/// removed when the work ends, however it ends (`remove()`). The stored recording is only read.
struct LevelledAudio: Sendable {
    /// What the models read.
    let url: URL
    /// What was measured and done; nil when the recording couldn't be measured or copied (the models then read it as is).
    let adjustment: LevelAdjustment?
    /// The copy made for the models, which `remove()` deletes.
    let copy: URL?

    /// The recording as it is, unmeasured.
    static func unchanged(_ url: URL) -> LevelledAudio { LevelledAudio(url: url, adjustment: nil, copy: nil) }

    func remove() {
        if let copy { try? FileManager.default.removeItem(at: copy) }
    }

    /// Measures `url` and, when the rule calls for a gain, writes the raised copy into `directory`'s processing scratch.
    /// A cancellation is passed on, any copy begun removed first; any other failure leaves the recording as it is, so
    /// levels never stop a recording from being processed.
    static func prepare(_ url: URL, policy: SpeechLevel.Policy = .standard,
                        in directory: URL = FileManager.default.temporaryDirectory) throws -> LevelledAudio {
        let adjustment: LevelAdjustment
        do {
            adjustment = SpeechLevel.adjustment(for: try measure(url, policy: policy), policy: policy)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return unchanged(url)
        }
        guard adjustment.gain > 0 else { return LevelledAudio(url: url, adjustment: adjustment, copy: nil) }
        var copy: URL?
        do {
            let destination = try ProcessingScratch.file(extension: "caf", in: directory)
            copy = destination
            try writeCopy(of: url, factor: adjustment.factor, to: destination)
            return LevelledAudio(url: destination, adjustment: adjustment, copy: destination)
        } catch {
            if let copy { try? FileManager.default.removeItem(at: copy) }
            if error is CancellationError { throw error }
            return unchanged(url)
        }
    }

    /// The recording's speech level and peak at its own sample rate, block by block, so memory stays bounded.
    static func measure(_ url: URL, policy: SpeechLevel.Policy = .standard) throws -> SpeechLevel.Measurement {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        var meter = SpeechLevel.Meter(sampleRate: file.processingFormat.sampleRate, policy: policy)
        try blocks(of: file) { buffer in
            let frames = Int(buffer.frameLength)
            meter.add((0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: frames)) })
        }
        return meter.measurement()
    }

    /// Writes `url` multiplied by `factor` to `destination`: 32-bit float in the recording's own rate and channels,
    /// frame for frame.
    static func writeCopy(of url: URL, factor: Float, to destination: URL) throws {
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let output = try AVAudioFile(forWriting: destination, settings: source.processingFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try blocks(of: source) { buffer in
            let frames = Int(buffer.frameLength)
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = buffer.floatChannelData![channel]
                for index in 0..<frames { samples[index] *= factor }
            }
            try output.write(from: buffer)
        }
    }

    /// Calls `body` with consecutive blocks of `file` in its processing format, from its start to its end.
    private static func blocks(of file: AVAudioFile, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw LocalIntelligenceError.invalidAudio }
        file.framePosition = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition)))
            guard buffer.frameLength > 0 else { break }
            try body(buffer)
        }
    }
}
